import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by the notch (gear button) to open the Settings window.
    static let tenfoldOpenSettings = Notification.Name("de.woit.tenfold.openSettings")
}

/// Settings window (menu bar → Settings…): Weather and Screen Time.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let weather: WeatherStore
    private let screenTime: ScreenTimeStore

    init(weather: WeatherStore, screenTime: ScreenTimeStore) {
        self.weather = weather
        self.screenTime = screenTime
    }

    func show() {
        if window == nil {
            let host = NSHostingView(rootView: SettingsView(weather: weather, screenTime: screenTime))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = L("Tenfold Settings")
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let weather: WeatherStore
    let screenTime: ScreenTimeStore

    var body: some View {
        TabView {
            GeneralSettings(language: LanguageSettings.shared)
                .tabItem { Label(L("General"), systemImage: "gearshape") }
            DashboardSettings(layout: DashboardLayout.shared)
                .tabItem { Label(L("Dashboard"), systemImage: "square.grid.2x2") }
            WeatherSettings(weather: weather)
                .tabItem { Label(L("Weather"), systemImage: "cloud.sun") }
            ScreenTimeSettings(store: screenTime)
                .tabItem { Label(L("Screen Time"), systemImage: "hourglass") }
        }
        .frame(width: 560, height: 520)
    }
}

/// Holds the language picker selection; writes through to `Localization.selected`.
@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    @Published var selection: AppLanguage = Localization.selected {
        didSet { Localization.selected = selection }
    }

    /// Which displays show a notch (applies immediately).
    @Published var displayMode: DisplayMode = DisplayMode.current {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: Prefs.displayMode)
            NotificationCenter.default.post(name: .tenfoldDisplaysChanged, object: nil)
        }
    }
}

/// Settings → Dashboard: one switch per Dashboard section.
struct DashboardSettings: View {
    @ObservedObject var layout: DashboardLayout

    var body: some View {
        Form {
            Section {
                ForEach(DashboardSection.allCases) { section in
                    Toggle(isOn: Binding(get: { layout.isVisible(section) },
                                         set: { layout.setVisible(section, $0) })) {
                        Label(section.title, systemImage: section.symbol)
                    }
                }
            } header: {
                Text(L("Sections on the Dashboard"))
            } footer: {
                Text(L("Hidden sections make room for the others."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralSettings: View {
    @ObservedObject var language: LanguageSettings

    var body: some View {
        Form {
            Section(L("Language")) {
                Picker(L("App language"), selection: $language.selection) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName).tag(lang)
                    }
                }
                Text(L("The new language is used after relaunching."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("Relaunch Tenfold")) { Localization.relaunch() }
            }
            Section(L("Displays")) {
                Picker(L("Show notch on"), selection: $language.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            Section(L("Clipboard shortcut")) {
                Text(L("⌃⌥V opens the clipboard, keys 1–0 paste an item."))
                Button(L("Open Accessibility Settings…")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section(L("About")) {
                LabeledContent("Tenfold") {
                    Text(LF("Version %@", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"))
                        .foregroundStyle(.secondary)
                }
                Picker(L("Language"), selection: $language.selection) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.nativeName).tag(lang)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct WeatherSettings: View {
    @ObservedObject var weather: WeatherStore

    var body: some View {
        Form {
            Section(L("Weather")) {
                Picker(L("Units"), selection: $weather.unit) {
                    Text("°C").tag(WeatherStore.Unit.celsius)
                    Text("°F").tag(WeatherStore.Unit.fahrenheit)
                }
                .pickerStyle(.segmented)

                Picker(L("Location"), selection: $weather.locationMode) {
                    Text(L("Use my location")).tag(WeatherStore.LocationMode.automatic)
                    Text(L("Choose a city")).tag(WeatherStore.LocationMode.city)
                }
                .pickerStyle(.radioGroup)

                if weather.locationMode == .city {
                    HStack {
                        TextField(L("City"), text: $weather.cityQuery, prompt: Text(L("e.g. Braunschweig")))
                            .onSubmit { weather.applyCity() }
                        Button(L("Apply")) { weather.applyCity() }
                    }
                } else {
                    Button(L("Open Location Privacy Settings…")) { weather.openLocationSettings() }
                }

                LabeledContent(L("Current place")) {
                    Text(weather.placeName.isEmpty ? "—" : weather.placeName)
                        .foregroundStyle(.secondary)
                }
                if case .failed(let message) = weather.status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(L("Forecast data: Open-Meteo.com (free for non-commercial use)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ScreenTimeSettings: View {
    @ObservedObject var store: ScreenTimeStore

    var body: some View {
        Form {
            Section(L("General")) {
                Picker(L("New day starts at"), selection: $store.resetHour) {
                    ForEach(0..<7, id: \.self) { hour in
                        Text(String(format: "%02d:00", hour)).tag(hour)
                    }
                }
                Toggle(L("Show insights sidebar"), isOn: $store.showInsights)
                Toggle(L("Expanded height (taller panel on the Screen Time tab)"), isOn: $store.expandedHeight)
                Text(L("Usage follows the frontmost app, pauses after 5 min without input or while the Mac sleeps, and is stored only on this Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("Reset today's data"), role: .destructive) { store.resetToday() }
            }

            Section(L("Category colours")) {
                ForEach(AppCategory.allCases) { category in
                    HStack {
                        Label(category.title, systemImage: category.symbol)
                        Spacer()
                        ForEach(ScreenTimePalette.swatches, id: \.self) { hex in
                            Button { store.setColor(hex, for: category) } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(
                                        (store.categoryColors[category.rawValue] ?? category.defaultColor) == hex ? 0.9 : 0),
                                        lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Section(L("Apps – category & exclusion")) {
                if store.knownApps.isEmpty {
                    Text(L("No apps recorded yet.")).foregroundStyle(.secondary)
                }
                ForEach(store.knownApps) { app in
                    HStack(spacing: 8) {
                        AppIconView(bundleID: app.id, size: 18)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Menu {
                            ForEach(AppCategory.allCases) { category in
                                Button(category.title) { store.setCategory(category, for: app.id) }
                            }
                        } label: {
                            Label(app.category.title, systemImage: app.category.symbol)
                        }
                        .fixedSize()
                        Button {
                            store.toggleExcluded(app.id)
                        } label: {
                            Image(systemName: store.excluded.contains(app.id) ? "eye.slash.fill" : "eye")
                                .foregroundStyle(store.excluded.contains(app.id) ? Color.red : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(store.excluded.contains(app.id) ? L("Excluded – click to include") : L("Click to exclude"))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// App icon for a bundle identifier.
struct AppIconView: View {
    let bundleID: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: Self.icon(for: bundleID))
            .resizable()
            .frame(width: size, height: size)
    }

    static func icon(for bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}
