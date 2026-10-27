import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let clipboard = ClipboardStore()
    private let files = FileTrayStore()
    private let calendar = CalendarStore()
    private let media = MediaController()
    private let hudMonitor = SystemHUDMonitor()
    private let weather = WeatherStore()
    private let screenTime = ScreenTimeStore()
    private let extras = Extras()
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()
    private lazy var settings = SettingsWindowController(weather: weather, screenTime: screenTime)
    private var settingsObserver: NSObjectProtocol?
    private var notches: [CGDirectDisplayID: NotchController] = [:]
    private var screenRebuildTask: Task<Void, Never>?
    private var displayObservers: [NSObjectProtocol] = []
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Prefs.volumeHUD: true, Prefs.brightnessHUD: true,
                                                  Prefs.ignorePasswordManagers: true, Prefs.pasteDirectly: true,
                                                  Prefs.realEqualizer: true])

        clipboard.start()
        rebuildNotches()
        for name in [NSApplication.didChangeScreenParametersNotification, .tenfoldDisplaysChanged] {
            displayObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRebuild() }
            })
        }

        hudMonitor.onEvent = { [weak self] event in
            let key = event.kind == .volume ? Prefs.volumeHUD : Prefs.brightnessHUD
            guard UserDefaults.standard.bool(forKey: key) else { return }
            guard let self else { return }
            for (displayID, notch) in self.notches {
                // Brightness only refers to the built-in display – don't show it on external monitors.
                if event.kind == .brightness && CGDisplayIsBuiltin(displayID) == 0 { continue }
                notch.showHUD(event)
            }
        }
        hudMonitor.start()
        weather.start()
        screenTime.start()
        extras.screenshots.start()
        extras.usage.preload()

        // Real equalizer: analyse system audio only while music plays (and the option is on).
        media.$nowPlaying
            .map { $0?.isPlaying == true }
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSpectrum() }
            .store(in: &cancellables)
        hotKey = GlobalHotKey { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Open on the display the mouse is on.
                let target = self.notches.values.first { $0.containsMouse } ?? self.notches.values.first
                target?.openClipboardFromKeyboard()
            }
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .tenfoldOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        }

        setupStatusItem()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Tenfold")

        let menu = NSMenu()
        menu.addItem(action(L("Clear Clipboard History"), #selector(clearHistory)))
        menu.addItem(action(L("Clear File Tray"), #selector(clearTray)))
        menu.addItem(.separator())
        menu.addItem(toggle(L("Ignore Password Manager Copies (Enpass …)"), key: Prefs.ignorePasswordManagers))
        menu.addItem(toggle(L("Paste Directly with ⌃⌥V (needs Accessibility)"), key: Prefs.pasteDirectly))
        menu.addItem(.separator())
        menu.addItem(toggle(L("Real Equalizer (System Audio)"), key: Prefs.realEqualizer))
        menu.addItem(toggle(L("Show Volume HUD"), key: Prefs.volumeHUD))
        menu.addItem(toggle(L("Show Brightness HUD"), key: Prefs.brightnessHUD))
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit Tenfold"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func toggle(_ title: String, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(togglePref(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        return item
    }

    // MARK: Displays

    /// Creates a notch for every display that should have one and removes the others.
    private func rebuildNotches() {
        let wanted = DisplayMode.current.screens().compactMap(\.displayID)
        for (id, controller) in notches where !wanted.contains(id) {
            controller.shutdown()
            notches[id] = nil
        }
        for id in wanted where notches[id] == nil {
            notches[id] = NotchController(displayID: id, clipboard: clipboard, files: files, calendar: calendar,
                                          media: media, controls: hudMonitor, weather: weather,
                                          screenTime: screenTime, extras: extras)
        }
    }

    /// Displays often report several changes in a row when plugged in – wait a moment.
    private func scheduleRebuild() {
        screenRebuildTask?.cancel()
        screenRebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.rebuildNotches()
        }
    }

    private func updateSpectrum() {
        let playing = media.nowPlaying?.isPlaying == true
        if playing && UserDefaults.standard.bool(forKey: Prefs.realEqualizer) {
            AudioSpectrum.shared.start()
        } else {
            AudioSpectrum.shared.stop()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioSpectrum.shared.stop()
        screenTime.save()
        extras.notes.save()
    }

    @objc private func clearHistory() { clipboard.clear() }
    @objc private func openSettings() { settings.show() }
    @objc private func clearTray() { files.clear() }

    @objc private func togglePref(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let value = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(value, forKey: key)
        sender.state = value ? .on : .off
        if key == Prefs.realEqualizer { updateSpectrum() }
    }
}
