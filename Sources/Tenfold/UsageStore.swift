import Foundation

/// Token usage of Claude Code and Codex, read from their local session logs
/// (`~/.claude/projects`, `~/.codex/sessions`). Only usage numbers are read; nothing leaves the Mac.
@MainActor
final class UsageStore: ObservableObject {
    struct Totals {
        var input = 0, cacheWrite = 0, output = 0, cacheRead = 0
        /// What the screenshot calls "fresh": everything except context re-read from the cache.
        var fresh: Int { input + cacheWrite + output }
        var processed: Int { fresh + cacheRead }

        static func += (lhs: inout Totals, rhs: Totals) {
            lhs.input += rhs.input; lhs.cacheWrite += rhs.cacheWrite
            lhs.output += rhs.output; lhs.cacheRead += rhs.cacheRead
        }
    }

    struct Limit {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: Date
    }

    struct ToolSummary {
        var installed = false
        var today = Totals()
        var sessionsToday = 0
        var lastModel: String?
        var lastProject: String?
        var plan: String?
        var primary: Limit?          // 5-hour window (Codex only)
        var secondary: Limit?        // weekly window (Codex only)
    }

    /// Which tool the activity heatmap shows.
    enum HeatmapSource: CaseIterable { case all, claude, codex }

    @Published private(set) var claude = ToolSummary()
    @Published private(set) var codex = ToolSummary()
    /// Fresh tokens per day and tool, keyed by start of day.
    @Published private(set) var dailyClaude: [Date: Int] = [:]
    @Published private(set) var dailyCodex: [Date: Int] = [:]
    @Published var heatmapSource: HeatmapSource = .all

    /// Fresh tokens per day for the selected heatmap source.
    var daily: [Date: Int] {
        switch heatmapSource {
        case .claude: return dailyClaude
        case .codex: return dailyCodex
        case .all: return dailyClaude.merging(dailyCodex, uniquingKeysWith: +)
        }
    }
    @Published private(set) var isLoading = true

    private let scanner = UsageScanner()
    private var timer: Timer?
    private var scanning = false

    /// Starts on first use of the Usage tab – the initial scan reads every log once (can be hundreds of MB).
    func activate() {
        guard timer == nil else { refresh(); return }
        refresh()
        let t = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One background scan shortly after launch, so the tab opens with data (no timer started).
    func preload(after delay: TimeInterval = 30) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.isLoading else { return }
            self.refresh()
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let scanner = scanner
        Task.detached(priority: .utility) {
            let result = await scanner.scan()
            await MainActor.run {
                self.claude = result.claude
                self.codex = result.codex
                self.dailyClaude = result.dailyClaude
                self.dailyCodex = result.dailyCodex
                self.isLoading = false
                self.scanning = false
            }
        }
    }
}

// MARK: - Scanner (background, incremental)

struct UsageScanResult: Sendable {
    let claude: UsageStore.ToolSummary
    let codex: UsageStore.ToolSummary
    let dailyClaude: [Date: Int]
    let dailyCodex: [Date: Int]
}

extension UsageStore.Totals: Sendable {}
extension UsageStore.Limit: Sendable {}
extension UsageStore.ToolSummary: Sendable {}

actor UsageScanner {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var claudeRoot: URL { home.appendingPathComponent(".claude/projects") }
    private var codexRoot: URL { home.appendingPathComponent(".codex/sessions") }

    /// Bytes already consumed per file (only complete lines).
    private var offsets: [String: UInt64] = [:]

    // Claude Code: the same message is logged on several lines (one per content block) → dedupe.
    private var seenClaude = Set<String>()
    private var claudeDays: [Date: UsageStore.Totals] = [:]
    private var claudeSessions: [Date: Set<String>] = [:]
    private var claudeLast: (date: Date, model: String?, project: String?)?

    // Codex: token_count carries cumulative totals per session → count the deltas.
    private var codexPrev: [String: UsageStore.Totals] = [:]
    private var codexDays: [Date: UsageStore.Totals] = [:]
    private var codexSessions: [Date: Set<String>] = [:]
    private var codexLast: (date: Date, model: String?, project: String?)?
    private var codexLimits: (date: Date, plan: String?, primary: UsageStore.Limit?, secondary: UsageStore.Limit?)?

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    func scan() -> UsageScanResult {
        let fm = FileManager.default
        let claudeInstalled = fm.fileExists(atPath: claudeRoot.path)
        let codexInstalled = fm.fileExists(atPath: codexRoot.path)
        if claudeInstalled { for url in jsonlFiles(in: claudeRoot) { read(url) { self.claudeLine($0) } } }
        if codexInstalled {
            for url in jsonlFiles(in: codexRoot) {
                let key = url.path
                read(url, onReset: { self.codexPrev[key] = nil }) { self.codexLine($0, session: key) }
            }
        }

        let today = Calendar.current.startOfDay(for: Date())
        var claude = UsageStore.ToolSummary()
        claude.installed = claudeInstalled
        claude.today = claudeDays[today] ?? .init()
        claude.sessionsToday = claudeSessions[today]?.count ?? 0
        claude.lastModel = claudeLast?.model
        claude.lastProject = claudeLast?.project

        var codex = UsageStore.ToolSummary()
        codex.installed = codexInstalled
        codex.today = codexDays[today] ?? .init()
        codex.sessionsToday = codexSessions[today]?.count ?? 0
        codex.lastModel = codexLast?.model
        codex.lastProject = codexLast?.project
        codex.plan = codexLimits?.plan
        codex.primary = codexLimits?.primary
        codex.secondary = codexLimits?.secondary

        return UsageScanResult(claude: claude, codex: codex,
                               dailyClaude: claudeDays.mapValues(\.fresh),
                               dailyCodex: codexDays.mapValues(\.fresh))
    }

    // MARK: Files

    private func jsonlFiles(in root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    /// Reads the complete lines appended since the last scan.
    private func read(_ url: URL, onReset: () -> Void = {}, line handle: (Data) -> Void) {
        let key = url.path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: key))?[.size] as? UInt64 else { return }
        var offset = offsets[key] ?? 0
        if size < offset { offset = 0; onReset() }          // file was rewritten
        guard size > offset, let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)

        var pending = Data()
        while let chunk = try? fh.read(upToCount: 4 << 20), !chunk.isEmpty {
            pending.append(chunk)
            var start = pending.startIndex
            while let nl = pending[start...].firstIndex(of: 0x0A) {
                handle(pending[start..<nl])
                offset += UInt64(nl - start + 1)
                start = pending.index(after: nl)
            }
            pending = Data(pending[start...])                // keep an unfinished last line for next time
        }
        offsets[key] = offset
    }

    private func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let turnContextMarker = Data("\"turn_context\"".utf8)

    // MARK: Claude Code

    private func claudeLine(_ data: Data) {
        guard data.range(of: Self.usageMarker) != nil,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let when = date(obj["timestamp"]) else { return }

        let id = "\(message["id"] as? String ?? obj["uuid"] as? String ?? "")|\(obj["requestId"] as? String ?? "")"
        guard seenClaude.insert(id).inserted else { return }

        var t = UsageStore.Totals()
        t.input = usage["input_tokens"] as? Int ?? 0
        t.cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        t.output = usage["output_tokens"] as? Int ?? 0
        t.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0

        let day = Calendar.current.startOfDay(for: when)
        claudeDays[day, default: .init()] += t
        if let session = obj["sessionId"] as? String { claudeSessions[day, default: []].insert(session) }

        let model = message["model"] as? String
        if claudeLast == nil || when >= claudeLast!.date, model != "<synthetic>" {
            claudeLast = (when, model, (obj["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent })
        }
    }

    // MARK: Codex

    private func codexLine(_ data: Data, session: String) {
        let isTokens = data.range(of: Self.tokenCountMarker) != nil
        let isContext = !isTokens && data.range(of: Self.turnContextMarker) != nil
        guard isTokens || isContext,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any],
              let when = date(obj["timestamp"]) else { return }

        if isContext {
            guard obj["type"] as? String == "turn_context" else { return }
            if codexLast == nil || when >= codexLast!.date {
                codexLast = (when, payload["model"] as? String,
                             (payload["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent })
            }
            return
        }
        guard payload["type"] as? String == "token_count" else { return }

        if let info = payload["info"] as? [String: Any],
           let total = info["total_token_usage"] as? [String: Any] {
            let input = total["input_tokens"] as? Int ?? 0
            let cached = total["cached_input_tokens"] as? Int ?? 0
            var now = UsageStore.Totals()
            now.input = max(0, input - cached)            // cached input is part of input_tokens
            now.cacheRead = cached
            now.cacheWrite = total["cache_write_input_tokens"] as? Int ?? 0
            now.output = total["output_tokens"] as? Int ?? 0

            let prev = codexPrev[session] ?? .init()
            var delta = UsageStore.Totals()
            if now.processed < prev.processed {
                delta = now                                  // counter restarted
            } else {
                delta.input = max(0, now.input - prev.input)
                delta.cacheRead = max(0, now.cacheRead - prev.cacheRead)
                delta.cacheWrite = max(0, now.cacheWrite - prev.cacheWrite)
                delta.output = max(0, now.output - prev.output)
            }
            codexPrev[session] = now
            if delta.processed > 0 {
                let day = Calendar.current.startOfDay(for: when)
                codexDays[day, default: .init()] += delta
                codexSessions[day, default: []].insert(session)
            }
        }

        if let limits = payload["rate_limits"] as? [String: Any],
           codexLimits == nil || when >= codexLimits!.date {
            func limit(_ key: String) -> UsageStore.Limit? {
                guard let l = limits[key] as? [String: Any],
                      let used = (l["used_percent"] as? NSNumber)?.doubleValue,
                      let resets = (l["resets_at"] as? NSNumber)?.doubleValue else { return nil }
                return UsageStore.Limit(usedPercent: used, windowMinutes: l["window_minutes"] as? Int ?? 0,
                                        resetsAt: Date(timeIntervalSince1970: resets))
            }
            codexLimits = (when, limits["plan_type"] as? String, limit("primary"), limit("secondary"))
        }
    }
}
