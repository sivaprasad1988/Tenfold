import AppKit
import Combine
import SwiftUI

// MARK: - Categories

enum AppCategory: String, CaseIterable, Codable, Identifiable {
    case productivity, development, communication, browsing, entertainment, creativity, utilities, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .productivity: return L("Productivity")
        case .development: return L("Development")
        case .communication: return L("Communication")
        case .browsing: return L("Browsing")
        case .entertainment: return L("Entertainment")
        case .creativity: return L("Creativity")
        case .utilities: return L("Utilities")
        case .other: return L("Other")
        }
    }

    var symbol: String {
        switch self {
        case .productivity: return "briefcase.fill"
        case .development: return "chevron.left.forwardslash.chevron.right"
        case .communication: return "bubble.left.and.bubble.right.fill"
        case .browsing: return "safari.fill"
        case .entertainment: return "play.rectangle.fill"
        case .creativity: return "paintbrush.pointed.fill"
        case .utilities: return "wrench.and.screwdriver.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }

    var defaultColor: String {
        switch self {
        case .productivity: return "#5B9DFF"
        case .development: return "#B48CFF"
        case .communication: return "#4CD98C"
        case .browsing: return "#FFB84D"
        case .entertainment: return "#FF6B8A"
        case .creativity: return "#FF8A5B"
        case .utilities: return "#7FD3E6"
        case .other: return "#9A9AA5"
        }
    }
}

/// Swatches offered in Settings for category colours.
enum ScreenTimePalette {
    static let swatches = ["#5B9DFF", "#B48CFF", "#4CD98C", "#FFB84D", "#FF6B8A",
                           "#FF8A5B", "#7FD3E6", "#F2D16B", "#E07BE0", "#9A9AA5"]
}

extension Color {
    /// "#RRGGBB" → Color (falls back to grey).
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = Color.gray
            return
        }
        self = Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Data

struct DayUsage: Codable, Equatable {
    var apps: [String: Double] = [:]                         // bundle ID → seconds
    var switches: Int = 0
    var hourly: [Double] = Array(repeating: 0, count: 24)    // seconds per clock hour

    var total: Double { apps.values.reduce(0, +) }
}

private struct ScreenTimeFile: Codable {
    var days: [String: DayUsage] = [:]
    var names: [String: String] = [:]
}

struct AppUsage: Identifiable, Equatable {
    let id: String          // bundle ID
    let name: String
    let seconds: Double
    let category: AppCategory
}

struct CategoryUsage: Identifiable, Equatable {
    let id: AppCategory
    let seconds: Double
}

// MARK: - Store

/// Tracks time per frontmost app. Everything is stored locally in
/// ~/Library/Application Support/Tenfold/screentime.json – nothing leaves the Mac.
@MainActor
final class ScreenTimeStore: ObservableObject {
    static let idleLimit: TimeInterval = 5 * 60        // no input for 5 min → not counted
    private static let tickInterval: TimeInterval = 5
    private static let keepDays = 35

    @Published private(set) var today = DayUsage()
    @Published private(set) var yesterday = DayUsage()
    @Published private(set) var currentApp: String?

    // Settings
    @Published var resetHour: Int { didSet { defaults.set(resetHour, forKey: Keys.resetHour); publishToday() } }
    @Published var showInsights: Bool { didSet { defaults.set(showInsights, forKey: Keys.insights) } }
    @Published var showOnDashboard: Bool { didSet { defaults.set(showOnDashboard, forKey: Keys.dashboard) } }
    @Published var expandedHeight: Bool { didSet { defaults.set(expandedHeight, forKey: Keys.expandedHeight) } }
    @Published private(set) var categoryOverrides: [String: AppCategory]
    @Published private(set) var categoryColors: [String: String]          // category rawValue → hex
    @Published private(set) var excluded: Set<String>

    private let defaults = UserDefaults.standard
    private var file = ScreenTimeFile()
    private var detectedCategories: [String: AppCategory] = [:]
    private var lastTick = Date()
    private var isAsleep = false
    private var timer: Timer?
    private var saveCounter = 0
    private var observers: [NSObjectProtocol] = []

    private enum Keys {
        static let resetHour = "screentime.resetHour"
        static let insights = "screentime.insights"
        static let dashboard = "screentime.dashboard"
        static let expandedHeight = "screentime.expandedHeight"
        static let overrides = "screentime.categoryOverrides"
        static let colors = "screentime.colors"
        static let excluded = "screentime.excluded"
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tenfold", isDirectory: true).appendingPathComponent("screentime.json")
    }

    init() {
        let stored = UserDefaults.standard
        resetHour = stored.object(forKey: Keys.resetHour) as? Int ?? 4
        showInsights = stored.object(forKey: Keys.insights) as? Bool ?? true
        showOnDashboard = stored.object(forKey: Keys.dashboard) as? Bool ?? true
        expandedHeight = stored.object(forKey: Keys.expandedHeight) as? Bool ?? false
        let rawOverrides = stored.dictionary(forKey: Keys.overrides) as? [String: String] ?? [:]
        categoryOverrides = rawOverrides.compactMapValues { AppCategory(rawValue: $0) }
        categoryColors = stored.dictionary(forKey: Keys.colors) as? [String: String] ?? [:]
        excluded = Set(stored.stringArray(forKey: Keys.excluded) ?? [])
    }

    func start() {
        load()
        if let app = NSWorkspace.shared.frontmostApplication { noteActivation(app, countSwitch: false) }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            let name = app?.localizedName
            Task { @MainActor in self?.handleActivation(bundleID: id, name: name, countSwitch: true) }
        })
        for (name, asleep) in [(NSWorkspace.willSleepNotification, true),
                               (NSWorkspace.screensDidSleepNotification, true),
                               (NSWorkspace.didWakeNotification, false),
                               (NSWorkspace.screensDidWakeNotification, false)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.tick()                    // book time up to now first
                    self?.isAsleep = asleep
                    self?.lastTick = Date()
                }
            })
        }

        lastTick = Date()
        let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        publishToday()
    }

    func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Tenfold: could not save screen time – \(error.localizedDescription)")
        }
    }

    // MARK: Queries

    var todayApps: [AppUsage] {
        today.apps.filter { !excluded.contains($0.key) }
            .map { AppUsage(id: $0.key, name: name(for: $0.key), seconds: $0.value, category: category(for: $0.key)) }
            .sorted { $0.seconds > $1.seconds }
    }

    var todayCategories: [CategoryUsage] {
        var sums: [AppCategory: Double] = [:]
        for app in todayApps { sums[app.category, default: 0] += app.seconds }
        return sums.map { CategoryUsage(id: $0.key, seconds: $0.value) }
            .filter { $0.seconds > 0 }
            .sorted { $0.seconds > $1.seconds }
    }

    var todayTotal: Double { todayApps.reduce(0) { $0 + $1.seconds } }

    var yesterdayTotal: Double {
        yesterday.apps.filter { !excluded.contains($0.key) }.values.reduce(0, +)
    }

    /// All apps seen in the stored history, most used (last 7 days) first – for Settings.
    var knownApps: [AppUsage] {
        var sums: [String: Double] = [:]
        let keys = (0..<7).map { dayKey(for: Date().addingTimeInterval(Double(-$0) * 86_400)) }
        for key in keys { for (id, s) in file.days[key]?.apps ?? [:] { sums[id, default: 0] += s } }
        for id in file.names.keys where sums[id] == nil { sums[id] = 0 }
        return sums.map { AppUsage(id: $0.key, name: name(for: $0.key), seconds: $0.value, category: category(for: $0.key)) }
            .sorted { $0.seconds == $1.seconds ? $0.name < $1.name : $0.seconds > $1.seconds }
    }

    func name(for bundleID: String) -> String {
        file.names[bundleID] ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    func color(for category: AppCategory) -> Color {
        Color(hex: categoryColors[category.rawValue] ?? category.defaultColor)
    }

    func category(for bundleID: String) -> AppCategory {
        if let manual = categoryOverrides[bundleID] { return manual }
        if let cached = detectedCategories[bundleID] { return cached }
        let detected = Self.detectCategory(bundleID)
        detectedCategories[bundleID] = detected
        return detected
    }

    // MARK: Settings actions

    func setCategory(_ category: AppCategory, for bundleID: String) {
        categoryOverrides[bundleID] = category
        defaults.set(categoryOverrides.mapValues(\.rawValue), forKey: Keys.overrides)
        publishToday()
    }

    func setColor(_ hex: String, for category: AppCategory) {
        categoryColors[category.rawValue] = hex
        defaults.set(categoryColors, forKey: Keys.colors)
    }

    func toggleExcluded(_ bundleID: String) {
        if excluded.contains(bundleID) { excluded.remove(bundleID) } else { excluded.insert(bundleID) }
        defaults.set(Array(excluded), forKey: Keys.excluded)
        publishToday()
    }

    func resetToday() {
        file.days[dayKey(for: Date())] = DayUsage()
        publishToday()
        save()
    }

    // MARK: Tracking

    private func handleActivation(bundleID: String?, name: String?, countSwitch: Bool) {
        tick()                                   // book time for the previous app first
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        if let name { file.names[bundleID] = name }
        currentApp = bundleID
        if countSwitch && !excluded.contains(bundleID) {
            file.days[dayKey(for: Date()), default: DayUsage()].switches += 1
            publishToday()
        }
    }

    private func noteActivation(_ app: NSRunningApplication, countSwitch: Bool) {
        handleActivation(bundleID: app.bundleIdentifier, name: app.localizedName, countSwitch: countSwitch)
    }

    private func tick() {
        let now = Date()
        let elapsed = min(max(now.timeIntervalSince(lastTick), 0), Self.tickInterval * 2)
        lastTick = now
        guard !isAsleep, Self.idleSeconds() < Self.idleLimit,
              let id = currentApp, !excluded.contains(id) else { return }
        let key = dayKey(for: now)
        file.days[key, default: DayUsage()].apps[id, default: 0] += elapsed
        let hour = Calendar.current.component(.hour, from: now)
        file.days[key, default: DayUsage()].hourly[hour] += elapsed

        publishToday()
        saveCounter += 1
        if saveCounter >= 12 {                  // ~ once a minute
            saveCounter = 0
            save()
        }
    }

    private func publishToday() {
        let now = Date()
        let todayKey = dayKey(for: now)
        let yesterdayKey = dayKey(for: now.addingTimeInterval(-86_400))
        let newToday = file.days[todayKey] ?? DayUsage()
        let newYesterday = file.days[yesterdayKey] ?? DayUsage()
        if newToday != today { today = newToday }
        if newYesterday != yesterday { yesterday = newYesterday }
    }

    /// Day key with configurable reset hour (e.g. 4 → usage until 03:59 counts for the previous day).
    private func dayKey(for date: Date) -> String {
        let shifted = date.addingTimeInterval(Double(-resetHour) * 3600)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode(ScreenTimeFile.self, from: data) else { return }
        file = decoded
        // Drop old days
        let cutoff = dayKey(for: Date().addingTimeInterval(Double(-Self.keepDays) * 86_400))
        file.days = file.days.filter { $0.key >= cutoff }
    }

    /// Seconds since the last keyboard / mouse input (public CoreGraphics API).
    private static func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    private static func detectCategory(_ id: String) -> AppCategory {
        let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
                                     "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
                                     "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]
        let communication: Set<String> = ["com.apple.mail", "com.apple.MobileSMS", "com.microsoft.Outlook",
                                          "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
                                          "us.zoom.xos", "com.apple.FaceTime", "ru.keepcoder.Telegram",
                                          "net.whatsapp.WhatsApp", "com.hnc.Discord"]
        let development: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
                                        "com.microsoft.VSCode", "com.anthropic.claudefordesktop"]
        if browsers.contains(id) { return .browsing }
        if communication.contains(id) { return .communication }
        if development.contains(id) || id.hasPrefix("com.jetbrains.") { return .development }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
              let type = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        else { return .other }

        let t = type.replacingOccurrences(of: "public.app-category.", with: "")
        switch t {
        case "developer-tools": return .development
        case "productivity", "business", "education", "reference", "finance", "medical": return .productivity
        case "social-networking": return .communication
        case "entertainment", "music", "video", "sports", "news": return .entertainment
        case "graphics-design", "photography", "lifestyle": return .creativity
        case "utilities", "weather": return .utilities
        default: return t.hasSuffix("games") ? .entertainment : .other
        }
    }
}

/// "2h 05m", "12m", "<1m"
func formatDuration(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "<1m" }
    if minutes < 60 { return "\(minutes)m" }
    return String(format: "%dh %02dm", minutes / 60, minutes % 60)
}
