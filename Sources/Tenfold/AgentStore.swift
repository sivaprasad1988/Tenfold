import AppKit
import Foundation

/// Agent Inbox: live state of Claude Code sessions, fed by Claude Code hooks.
///
/// The hook script (installed from Settings) writes one small `*.event` file per hook call into
/// `~/Library/Application Support/Tenfold/agents/`. It copies only ids and paths (event, session id,
/// cwd, transcript path, notification type, terminal) – never prompt, message or tool text.
/// Tenfold watches the folder (no polling), reads each file once and deletes it.
@MainActor
final class AgentStore: ObservableObject {
    enum Status: Equatable { case running, waiting, done }

    struct Session: Identifiable, Equatable {
        let id: String              // session_id (Claude Code or Codex)
        var tool: AgentHooks.Tool
        var cwd: String
        var transcript: String?
        var terminalApp: String?    // bundle id of the terminal it runs in
        var terminalProgram: String?
        var status: Status
        var changed: Date

        var project: String {
            let name = (cwd as NSString).lastPathComponent
            return name.isEmpty ? tool.title : name
        }
    }

    /// What the closed notch shows: waiting sessions win; a finished one shows for a few seconds.
    struct Attention: Equatable {
        let project: String
        let status: Status          // .waiting or .done
        let count: Int              // number of waiting sessions
    }

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var attention: Attention?

    private var dirSource: DispatchSourceFileSystemObject?
    private var transcriptSources: [String: DispatchSourceFileSystemObject] = [:]
    private var doneFlash: (id: String, until: Date)?
    private var flashTask: Task<Void, Never>?

    /// Sessions without any event for this long are dropped (terminal closed without SessionEnd).
    private let staleAfter: TimeInterval = 3 * 3600
    /// Transcript writes right after a state change belong to that change, not to new activity.
    private let grace: TimeInterval = 2

    func start() {
        guard dirSource == nil else { return }
        let dir = AgentHooks.eventsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
        drain()
    }

    func dismiss(_ id: String) {
        remove(id)
        publish()
    }

    /// Brings the terminal the session runs in to the front.
    func reveal(_ session: Session) {
        let ids = [session.terminalApp, AgentHooks.bundleID(forTermProgram: session.terminalProgram),
                   session.tool == .codex ? "com.openai.codex" : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
                return
            }
        }
    }

    // MARK: Events

    private func drain() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: AgentHooks.eventsDir, includingPropertiesForKeys: nil) else { return }
        let events = files.filter { $0.pathExtension == "event" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }   // "<epoch>-<pid>": oldest first
        guard !events.isEmpty else { return }
        for url in events {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? fm.removeItem(at: url)
            let stamp = Double(url.lastPathComponent.split(separator: "-").first ?? "") ?? Date().timeIntervalSince1970
            let date = Date(timeIntervalSince1970: stamp)
            guard Date().timeIntervalSince(date) < staleAfter else { continue }   // left over while Tenfold was off
            apply(parse(text), at: date)
        }
        prune()
        publish()
    }

    private func parse(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return fields
    }

    private func apply(_ f: [String: String], at date: Date) {
        guard let id = f["session"], !id.isEmpty, let event = f["event"] else { return }
        if event == "SessionEnd" { remove(id); return }

        let newStatus: Status
        switch event {
        case "SessionStart", "UserPromptSubmit":
            newStatus = .running
        case "PermissionRequest":
            newStatus = .waiting
        case "Stop":
            newStatus = .done
        case "Notification":
            switch f["type"] ?? "" {
            case "permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog":
                newStatus = .waiting
            case "agent_completed":
                newStatus = .done
            case "idle_prompt":
                // Repeats "waiting for your input" after a finished turn – keep "done".
                if let s = sessions.first(where: { $0.id == id }), s.status == .done { return }
                newStatus = .waiting
            default:
                return
            }
        default:
            return
        }

        var session = sessions.first { $0.id == id }
            ?? Session(id: id, tool: AgentHooks.Tool(rawValue: f["tool"] ?? "") ?? .claude, cwd: f["cwd"] ?? "", transcript: nil, terminalApp: nil, terminalProgram: nil,
                       status: newStatus, changed: date)
        if let cwd = f["cwd"], !cwd.isEmpty { session.cwd = cwd }
        if let t = f["transcript"], !t.isEmpty { session.transcript = t }
        if let app = f["app"], !app.isEmpty { session.terminalApp = app }
        if let term = f["term"], !term.isEmpty { session.terminalProgram = term }
        session.status = newStatus
        session.changed = date
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i] = session } else { sessions.append(session) }

        if newStatus == .done { flashDone(id) }
        // Waiting/done end when the transcript changes again (permission answered, new prompt).
        if newStatus == .running { unwatch(id) } else { watchTranscript(of: session) }
    }

    private func remove(_ id: String) {
        sessions.removeAll { $0.id == id }
        unwatch(id)
        if doneFlash?.id == id { doneFlash = nil }
    }

    private func prune() {
        let now = Date()
        for s in sessions where now.timeIntervalSince(s.changed) > staleAfter { remove(s.id) }
    }

    // MARK: Transcript watch (file writes only, the content is never read)

    private func watchTranscript(of session: Session) {
        guard transcriptSources[session.id] == nil, let path = session.transcript else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let id = session.id
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.transcriptChanged(id) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        transcriptSources[id] = source
    }

    private func unwatch(_ id: String) {
        transcriptSources.removeValue(forKey: id)?.cancel()
    }

    private func transcriptChanged(_ id: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].status != .running,
              Date().timeIntervalSince(sessions[i].changed) > grace else { return }
        sessions[i].status = .running
        sessions[i].changed = Date()
        unwatch(id)
        publish()
    }

    // MARK: Closed-notch attention

    private func flashDone(_ id: String) {
        doneFlash = (id, Date().addingTimeInterval(6))
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.doneFlash = nil
            self.publish()
        }
    }

    private func publish() {
        let waiting = sessions.filter { $0.status == .waiting }.sorted { $0.changed > $1.changed }
        let next: Attention?
        if let first = waiting.first {
            next = Attention(project: first.project, status: .waiting, count: waiting.count)
        } else if let flash = doneFlash, flash.until > Date(),
                  let s = sessions.first(where: { $0.id == flash.id }), s.status == .done {
            next = Attention(project: s.project, status: .done, count: 0)
        } else {
            next = nil
        }
        if next != attention { attention = next }
    }
}

// MARK: - Hook installation (~/.claude/settings.json)

enum AgentHooks {
    enum HookError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            guard case .unreadable(let path) = self else { return nil }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return LF("%@ could not be read as JSON. Nothing was changed.", path.replacingOccurrences(of: home, with: "~"))
        }
    }

    enum Tool: String, CaseIterable {
        case claude, codex

        var title: String { self == .claude ? "Claude Code" : "Codex" }

        /// Claude Code: `~/.claude/settings.json`; Codex: `~/.codex/hooks.json` (same three-level shape).
        var configURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return self == .claude ? home.appendingPathComponent(".claude/settings.json")
                                   : home.appendingPathComponent(".codex/hooks.json")
        }
        var backupURL: URL { configURL.appendingPathExtension("tenfold-backup") }

        /// Codex has no Notification event; PermissionRequest covers "waiting".
        var events: [String] {
            self == .claude ? ["SessionStart", "PermissionRequest", "Notification", "Stop", "SessionEnd"]
                            : ["SessionStart", "PermissionRequest", "Stop", "SessionEnd"]
        }

        /// The tool name is passed as argument so the event file says where it came from.
        var command: String { "\"\(AgentHooks.scriptURL.path)\" \(rawValue)" }
    }

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tenfold", isDirectory: true)
    }
    static var eventsDir: URL { supportDir.appendingPathComponent("agents", isDirectory: true) }
    static var scriptURL: URL { supportDir.appendingPathComponent("agent-hook.sh") }

    /// Marker to find our entries again – every Tenfold hook command contains it.
    private static let marker = "Tenfold/agent-hook.sh"

    /// Copies only ids and paths out of the hook input – never prompt, message or tool text.
    private static let script = #"""
    #!/bin/sh
    # Tenfold Agent Inbox hook. Writes only ids and paths, never prompt, message or tool text.
    umask 077
    dir="$HOME/Library/Application Support/Tenfold/agents"
    [ -d "$dir" ] || mkdir -p "$dir"
    input=$(cat)
    field() {
      printf '%s' "$input" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 \
        | sed 's/^[^:]*:[[:space:]]*"//; s/"$//'
    }
    f="$dir/$(date +%s)-$$"
    {
      printf 'event=%s\n' "$(field hook_event_name)"
      printf 'session=%s\n' "$(field session_id)"
      printf 'cwd=%s\n' "$(field cwd)"
      printf 'transcript=%s\n' "$(field transcript_path)"
      printf 'type=%s\n' "$(field notification_type)"
      printf 'app=%s\n' "${__CFBundleIdentifier:-}"
      printf 'term=%s\n' "${TERM_PROGRAM:-}"
      printf 'tool=%s\n' "${1:-claude}"
    } > "$f.tmp" && mv "$f.tmp" "$f.event"
    exit 0
    """#

    static func isInstalled(_ tool: Tool) -> Bool {
        guard let root = try? readSettings(tool), let hooks = root["hooks"] as? [String: Any] else { return false }
        return tool.events.allSatisfy { containsMarker(hooks[$0]) }
    }

    static func install(_ tool: Tool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: eventsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        var root = try readSettings(tool) ?? [:]
        var hooks = stripped(root["hooks"] as? [String: Any] ?? [:])
        let entry: [String: Any] = ["hooks": [["type": "command", "command": tool.command, "timeout": 5]]]
        for event in tool.events {
            var groups = hooks[event] as? [Any] ?? []
            groups.append(entry)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeSettings(root, tool)
    }

    static func uninstall(_ tool: Tool) throws {
        guard var root = try readSettings(tool) else { return }
        let hooks = stripped(root["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeSettings(root, tool)
        // The script is shared – keep it while the other tool still uses it.
        if Tool.allCases.allSatisfy({ !isInstalled($0) }) { try? FileManager.default.removeItem(at: scriptURL) }
    }

    static func bundleID(forTermProgram term: String?) -> String? {
        switch term {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "vscode": return "com.microsoft.VSCode"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        default: return nil
        }
    }

    // MARK: Private

    /// nil = file missing (fine); throws = file exists but is not a JSON object (don't touch it).
    private static func readSettings(_ tool: Tool) throws -> [String: Any]? {
        guard let data = try? Data(contentsOf: tool.configURL) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.unreadable(tool.configURL.path)
        }
        return root
    }

    private static func writeSettings(_ root: [String: Any], _ tool: Tool) throws {
        let fm = FileManager.default
        let url = tool.configURL
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: tool.backupURL)
            try fm.copyItem(at: url, to: tool.backupURL)
        } else {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Removes every Tenfold handler; drops groups and events that become empty.
    private static func stripped(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [Any] else { result[event] = value; continue }
            var kept: [Any] = []
            for group in groups {
                guard var g = group as? [String: Any], let handlers = g["hooks"] as? [Any] else { kept.append(group); continue }
                let others = handlers.filter { !isOurs($0) }
                if others.isEmpty { continue }
                g["hooks"] = others
                kept.append(g)
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func containsMarker(_ value: Any?) -> Bool {
        guard let groups = value as? [Any] else { return false }
        return groups.contains { group in
            ((group as? [String: Any])?["hooks"] as? [Any])?.contains(where: isOurs) ?? false
        }
    }

    private static func isOurs(_ handler: Any) -> Bool {
        ((handler as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }
}

/// Settings state for the hook installer (shared object instead of @State – see CLAUDE.md).
@MainActor
final class AgentHooksModel: ObservableObject {
    static let shared = AgentHooksModel()
    @Published private(set) var installed: Set<AgentHooks.Tool> = AgentHooksModel.current()
    @Published private(set) var error: String?

    func toggle(_ tool: AgentHooks.Tool) {
        do {
            if installed.contains(tool) { try AgentHooks.uninstall(tool) } else { try AgentHooks.install(tool) }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        installed = Self.current()
    }

    func refresh() { installed = Self.current() }

    private static func current() -> Set<AgentHooks.Tool> {
        Set(AgentHooks.Tool.allCases.filter { AgentHooks.isInstalled($0) })
    }
}
