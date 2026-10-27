import AppKit
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case dashboard, weather, screenTime, clipboard, files, media, calendar, tools, usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return L("Dashboard")
        case .weather: return L("Weather")
        case .screenTime: return L("Screen Time")
        case .tools: return L("Tools")
        case .clipboard: return L("Clipboard")
        case .files: return L("Files")
        case .media: return L("Media")
        case .calendar: return L("Calendar")
        case .usage: return L("Usage")
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .weather: return "cloud.sun"
        case .screenTime: return "hourglass"
        case .tools: return "timer"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "tray.full"
        case .media: return "music.note"
        case .calendar: return "calendar"
        case .usage: return "chart.bar.xaxis"
        }
    }
}

struct HUDEvent: Equatable {
    enum Kind { case volume, brightness }
    let kind: Kind
    let level: Double      // 0...1
    let muted: Bool
    let id = UUID()
}

enum Prefs {
    static let volumeHUD = "hud.volume"
    static let brightnessHUD = "hud.brightness"
    static let ignorePasswordManagers = "clipboard.ignorePasswordManagers"
    static let pasteDirectly = "clipboard.pasteDirectly"
    static let realEqualizer = "media.realEqualizer"
    static let displayMode = "display.mode"          // all | builtin | main
    static let dashboardHidden = "dashboard.hiddenSections"
}

/// The eight sections of the Dashboard grid, in display order.
enum DashboardSection: String, CaseIterable, Identifiable {
    case upNext, nowPlaying, focus, weather, clipboard, screenTime, dayProgress, quickControls
    var id: String { rawValue }

    var title: String {
        switch self {
        case .upNext: return L("Up Next")
        case .nowPlaying: return L("Now Playing")
        case .focus: return L("Focus")
        case .weather: return L("Weather")
        case .clipboard: return L("Clipboard")
        case .screenTime: return L("Screen Time")
        case .dayProgress: return L("Day Progress")
        case .quickControls: return L("Quick controls")
        }
    }

    var symbol: String {
        switch self {
        case .upNext: return "calendar"
        case .nowPlaying: return "music.note"
        case .focus: return "timer"
        case .weather: return "cloud.sun.fill"
        case .clipboard: return "doc.on.clipboard"
        case .screenTime: return "hourglass"
        case .dayProgress: return "sunrise.fill"
        case .quickControls: return "switch.2"
        }
    }
}

/// Which Dashboard sections are visible (Settings → Dashboard). Focus is hidden by default.
@MainActor
final class DashboardLayout: ObservableObject {
    static let shared = DashboardLayout()

    @Published private(set) var hidden: Set<DashboardSection>

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.stringArray(forKey: Prefs.dashboardHidden) {
            hidden = Set(stored.compactMap(DashboardSection.init(rawValue:)))
        } else {
            var initial: Set<DashboardSection> = [.focus]
            // Carry over the old "Show widget on Dashboard" switch from the Screen Time settings.
            if defaults.object(forKey: "screentime.dashboard") as? Bool == false { initial.insert(.screenTime) }
            hidden = initial
        }
    }

    var visible: [DashboardSection] { DashboardSection.allCases.filter { !hidden.contains($0) } }

    func isVisible(_ section: DashboardSection) -> Bool { !hidden.contains(section) }

    func setVisible(_ section: DashboardSection, _ visible: Bool) {
        if visible { hidden.remove(section) } else { hidden.insert(section) }
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: Prefs.dashboardHidden)
    }
}

/// All sizes of the notch shape in one place.
enum NotchMetrics {
    static let collapsedTopRadius: CGFloat = 6      // small "shoulders" flowing into the menu bar
    static let collapsedBottomRadius: CGFloat = 10
    static let expandedTopRadius: CGFloat = 18
    static let expandedBottomRadius: CGFloat = 38
    static let expandedWidth: CGFloat = 920
    static let expandedHeight: CGFloat = 300
    static let hudWing: CGFloat = 64                // extra width left/right of the notch for the HUD
    static let liveWing: CGFloat = 44               // closed notch while music plays (art | notch | bars)
    static let meetingWing: CGFloat = 112           // closed notch before a meeting (title | notch | countdown)
    static let shadowPad: CGFloat = 30              // window margin so the shadow is not cut off
    static let contentInset: CGFloat = expandedTopRadius + 16
    static let dockHeight: CGFloat = 46             // floating section dock under the panel
    static let dockGap: CGFloat = 10

    /// Final size of the open panel. The content is laid out once at this size,
    /// so it never re-flows while the shape animates (that caused the "squishy" look).
    static let tallExtraHeight: CGFloat = 120       // "expanded height" option (Screen Time)

    static func expandedShapeSize(notchWidth: CGFloat, tall: Bool = false) -> CGSize {
        CGSize(width: max(expandedWidth, notchWidth + 380),
               height: expandedHeight + (tall ? tallExtraHeight : 0))
    }
}

/// What the closed notch shows ("live activity"), by priority: meeting > focus > music.
enum LiveItem: Equatable {
    case meeting(title: String, start: Date)
    case focus(phase: FocusTimer.Phase, isRunning: Bool, endDate: Date?, remaining: TimeInterval, duration: TimeInterval)
    case music(MediaController.NowPlaying)

    var wing: CGFloat {
        if case .meeting = self { return NotchMetrics.meetingWing }
        return NotchMetrics.liveWing
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var isExpanded = false
    @Published var notchSize = CGSize(width: 200, height: 32)
    @Published var shapeSize = CGSize(width: 212, height: 32)
    @Published var topRadius: CGFloat = NotchMetrics.collapsedTopRadius
    @Published var bottomRadius: CGFloat = NotchMetrics.collapsedBottomRadius
    @Published var selectedTab: NotchTab = .dashboard
    @Published var hud: HUDEvent?
    @Published var liveItem: LiveItem?
    @Published var keyboardMode = false          // opened with ⌃⌥V – keys 1–0 paste, Esc closes
    @Published var isDropTargeted = false
    @Published var isTall = false
    @Published var showLanguagePrompt = false   // first-expand "Choose your language"               // taller panel (Screen Time → expanded height)
}

/// Per-cell hover flag. Used instead of `@State`: with only the Command Line Tools,
/// the SwiftUIMacros plugin (needed for `@State` on the macOS 27 SDK) is missing.
@MainActor
final class HoverState: ObservableObject {
    @Published var isHovering = false
}

/// Shared hover state for all cards/buttons.
/// Replaces SwiftUI `@State`, which is a macro in the macOS 27 SDK and fails to build
/// with the Command Line Tools ("plugin for module 'SwiftUIMacros' not found").
@MainActor
final class HoverTracker: ObservableObject {
    static let shared = HoverTracker()
    @Published private(set) var hoveredID: String?

    func isHovered(_ id: String) -> Bool { hoveredID == id }

    func update(_ id: String, inside: Bool) {
        if inside {
            hoveredID = id
        } else if hoveredID == id {
            hoveredID = nil
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    var isBuiltIn: Bool {
        displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
    }
}

extension Notification.Name {
    static let tenfoldDisplaysChanged = Notification.Name("de.woit.tenfold.displaysChanged")
}

/// Which displays get a notch (Settings → General → Displays).
enum DisplayMode: String, CaseIterable, Identifiable {
    case all, builtin, main
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L("All displays")
        case .builtin: return L("Built-in display only")
        case .main: return L("Main display only")
        }
    }

    static var current: DisplayMode {
        DisplayMode(rawValue: UserDefaults.standard.string(forKey: Prefs.displayMode) ?? "") ?? .all
    }

    /// Screens that should show a notch right now.
    func screens() -> [NSScreen] {
        let all = NSScreen.screens
        switch self {
        case .all: return all
        case .main: return Array(all.prefix(1))                       // display with the menu bar
        case .builtin:
            let builtIn = all.filter(\.isBuiltIn)
            return builtIn.isEmpty ? Array(all.prefix(1)) : builtIn     // lid closed → main display
        }
    }
}
