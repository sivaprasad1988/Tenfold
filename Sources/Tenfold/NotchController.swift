import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click on an item work even though the app is not active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the borderless panel on the notch and morphs it between collapsed, HUD and expanded.
@MainActor
final class NotchController {
    enum Mode { case collapsed, live, hud, expanded }
    private typealias M = NotchMetrics

    let state = NotchState()
    private let files: FileTrayStore
    private let calendar: CalendarStore
    private let media: MediaController
    private let weather: WeatherStore
    private let extras: Extras
    private let clipboard: ClipboardStore
    private var previousApp: NSRunningApplication?
    private var meetingTimer: Timer?
    private let panel: NotchPanel
    private var mode: Mode = .collapsed
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var closeTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// The display this notch lives on (one controller per display).
    let displayID: CGDirectDisplayID
    private var observers: [NSObjectProtocol] = []

    init(displayID: CGDirectDisplayID,
         clipboard: ClipboardStore, files: FileTrayStore, calendar: CalendarStore, media: MediaController,
         controls: SystemHUDMonitor, weather: WeatherStore, screenTime: ScreenTimeStore,
         extras: Extras) {
        self.displayID = displayID
        self.files = files
        self.extras = extras
        self.clipboard = clipboard
        self.weather = weather
        self.calendar = calendar
        self.media = media
        panel = NotchPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false       // we own the panel; avoid double release on close()
        panel.acceptsMouseMovedEvents = true

        let root = NotchView(state: state, clipboard: clipboard, files: files, calendar: calendar, media: media,
                             controls: controls, weather: weather, screenTime: screenTime, extras: extras)
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        snap(to: .collapsed)
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.snap(to: self.mode)
            }
        }

        // Dragging a file onto the (collapsed) notch opens the Files tab.
        state.$isDropTargeted
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] targeted in
                guard targeted, let self else { return }
                self.state.selectedTab = .files
                self.setExpanded(true)
            }
            .store(in: &cancellables)

        // Closed notch "live activity": meeting > focus timer > music.
        media.$nowPlaying.map { _ in () }
            .merge(with: extras.focus.objectWillChange.map { _ in () },
                   calendar.$entries.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateLiveItem() }
            .store(in: &cancellables)
        media.startPolling()
        let meetingTick = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.calendar.refreshUpcoming()
                self?.updateLiveItem()
            }
        }
        RunLoop.main.add(meetingTick, forMode: .common)
        meetingTimer = meetingTick

        // Keyboard mode (⌃⌥V): 1–0 paste, Esc closes; clicking elsewhere ends it.
        if let k = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.state.keyboardMode, self.state.isExpanded else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }) { monitors.append(k) }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.keyboardMode else { return }
                self.endKeyboardMode(paste: false)
            }
        })

        // Taller panel while the Screen Time tab is shown (if enabled in Settings).
        state.$selectedTab
            .combineLatest(screenTime.$expandedHeight)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab, tallEnabled in
                guard let self else { return }
                let tall = tab == .screenTime && tallEnabled
                guard tall != self.state.isTall else { return }
                self.state.isTall = tall
                if self.mode == .expanded { self.morph(to: .expanded) }
            }
            .store(in: &cancellables)

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Monitors are delivered on the main thread – handle synchronously (no Task per mouse event).
        if let g = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) { monitors.append(l) }
    }

    // MARK: Geometry

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    /// True if the mouse pointer is on this controller's display.
    var containsMouse: Bool {
        screen.map { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? false
    }

    /// Removes the panel and all observers (display unplugged or setting changed).
    func shutdown() {
        closeTask?.cancel(); hudTask?.cancel(); frameTask?.cancel()
        meetingTimer?.invalidate()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        cancellables.removeAll()
        panel.orderOut(nil)
        panel.close()
    }

    /// Size of the hardware notch (or a fake one on screens without a notch).
    private func notchSize(on screen: NSScreen) -> CGSize {
        var width: CGFloat = 200
        var height: CGFloat = NSStatusBar.system.thickness
        if screen.safeAreaInsets.top > 0 {
            height = screen.safeAreaInsets.top
            if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                width = screen.frame.width - l.width - r.width
            }
        }
        return CGSize(width: width, height: height)
    }

    private func shape(for mode: Mode, notch: CGSize) -> (size: CGSize, top: CGFloat, bottom: CGFloat) {
        switch mode {
        case .collapsed:
            return (CGSize(width: notch.width + 2 * M.collapsedTopRadius, height: notch.height),
                    M.collapsedTopRadius, M.collapsedBottomRadius)
        case .live:
            return (CGSize(width: notch.width + 2 * ((state.liveItem?.wing ?? M.liveWing) + M.collapsedTopRadius),
                           height: notch.height),
                    M.collapsedTopRadius, M.collapsedBottomRadius)
        case .hud:
            return (CGSize(width: notch.width + 2 * (M.hudWing + M.collapsedTopRadius), height: notch.height),
                    M.collapsedTopRadius, M.collapsedBottomRadius)
        case .expanded:
            return (M.expandedShapeSize(notchWidth: notch.width, tall: state.isTall),
                    M.expandedTopRadius, M.expandedBottomRadius)
        }
    }

    private func windowFrame(for mode: Mode, on screen: NSScreen, notch: CGSize) -> NSRect {
        let s = shape(for: mode, notch: notch).size
        guard mode == .expanded else { return topCentered(width: s.width, height: s.height, on: screen) }
        let pad = M.shadowPad
        return topCentered(width: s.width + 2 * pad,
                           height: s.height + M.dockGap + M.dockHeight + pad, on: screen)
    }

    private func topCentered(width: CGFloat, height: CGFloat, on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// Current black shape in screen coordinates (used for hover detection).
    private func shapeRect(on screen: NSScreen) -> NSRect {
        topCentered(width: state.shapeSize.width, height: state.shapeSize.height, on: screen)
    }

    /// Jump to a mode without animation.
    private func snap(to newMode: Mode) {
        guard let screen else { return }
        let notch = notchSize(on: screen)
        let target = shape(for: newMode, notch: notch)
        mode = newMode
        state.notchSize = notch
        state.shapeSize = target.size
        state.topRadius = target.top
        state.bottomRadius = target.bottom
        state.isExpanded = newMode == .expanded
        panel.setFrame(windowFrame(for: newMode, on: screen, notch: notch), display: true)
    }

    /// Morph to a mode: grow the window first, animate the shape, then trim the window.
    private func morph(to newMode: Mode) {
        guard let screen else { return }
        let notch = notchSize(on: screen)
        let target = shape(for: newMode, notch: notch)
        let finalFrame = windowFrame(for: newMode, on: screen, notch: notch)
        mode = newMode
        state.notchSize = notch

        // 1) Grow the window WITHOUT animation and lay the content out at the new size.
        //    Previously this happened inside the animation transaction, so SwiftUI animated the
        //    shape's position from the window's left edge to the centre ("starts from the left").
        let current = panel.frame
        let grown = topCentered(width: max(current.width, finalFrame.width),
                                height: max(current.height, finalFrame.height), on: screen)
        let needsGrow = grown != current
        if needsGrow {
            panel.setFrame(grown, display: false)
            panel.contentView?.layoutSubtreeIfNeeded()
        }

        // 2) Animate the shape in the next run-loop turn, symmetrically from the centre.
        let animation: Animation = newMode == .expanded
            ? .spring(response: 0.46, dampingFraction: 0.86)
            : .spring(response: 0.36, dampingFraction: 1.0)
        if needsGrow {
            Task { @MainActor [weak self] in
                self?.animateShape(to: newMode, size: target.size, top: target.top,
                                   bottom: target.bottom, animation: animation)
            }
        } else {
            animateShape(to: newMode, size: target.size, top: target.top,
                         bottom: target.bottom, animation: animation)
        }

        // 3) Trim the window to the final size once the animation is done.
        frameTask?.cancel()
        frameTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard let self, !Task.isCancelled, self.mode == newMode else { return }
            self.panel.setFrame(finalFrame, display: false)
            self.panel.contentView?.layoutSubtreeIfNeeded()
            self.panel.display()
        }
    }

    private func animateShape(to newMode: Mode, size: CGSize, top: CGFloat, bottom: CGFloat,
                              animation: Animation) {
        guard mode == newMode else { return }   // a newer transition already started
        withAnimation(animation) {
            state.isExpanded = newMode == .expanded
            state.shapeSize = size
            state.topRadius = top
            state.bottomRadius = bottom
        }
    }

    // MARK: Hover

    private func mouseMoved() {
        guard let screen else { return }
        let p = NSEvent.mouseLocation
        if state.isExpanded {
            let panelArea = topCentered(width: state.shapeSize.width,
                                        height: state.shapeSize.height + M.dockGap + M.dockHeight, on: screen)
            let inside = panelArea.insetBy(dx: -8, dy: -8).contains(p)
            let editing = panel.isKeyWindow && panel.firstResponder is NSTextView
            let busy = state.isDropTargeted || (NSEvent.pressedMouseButtons & 1) != 0
                || state.keyboardMode || editing
            if inside || busy {
                closeTask?.cancel(); closeTask = nil
            } else if closeTask == nil {
                closeTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard !Task.isCancelled else { return }
                    self?.setExpanded(false)
                }
            }
        } else if shapeRect(on: screen).insetBy(dx: -4, dy: -2).contains(p) {
            setExpanded(true)
        }
    }

    func setExpanded(_ expanded: Bool) {
        closeTask?.cancel(); closeTask = nil
        guard expanded != state.isExpanded else { return }
        if expanded {
            hudTask?.cancel(); hudTask = nil
            state.hud = nil
            morph(to: .expanded)
            media.setFastPolling(true)
            if !UserDefaults.standard.bool(forKey: Localization.promptedKey) {
                UserDefaults.standard.set(true, forKey: Localization.promptedKey)
                state.showLanguagePrompt = true
            }
            // Data work after the opening animation, so it can't cause a hitch.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 480_000_000)
                guard let self, self.state.isExpanded else { return }
                self.files.pruneMissing()
                self.calendar.reload()
                self.media.refresh()
                self.updateLiveItem()
                self.weather.refreshIfStale()
            }
        } else {
            morph(to: restingMode)
            media.setFastPolling(false)
        }
    }

    /// Closed state: "live" while something is happening, otherwise the plain notch.
    private var restingMode: Mode {
        state.liveItem != nil ? .live : .collapsed
    }

    private func updateLiveItem() {
        let focus = extras.focus
        let item: LiveItem?
        if let meeting = calendar.upcomingMeeting {
            item = .meeting(title: meeting.title, start: meeting.start)
        } else if focus.isActive {
            item = .focus(phase: focus.phase, isRunning: focus.isRunning, endDate: focus.endDate,
                          remaining: focus.remaining(), duration: focus.duration)
        } else if let track = media.nowPlaying, track.isPlaying {
            // Ignore position/timestamp-only changes (every poll) – they don't change the closed notch.
            if case .music(let old) = state.liveItem, old.title == track.title, old.artist == track.artist,
               old.artworkURL == track.artworkURL, old.isPlaying == track.isPlaying {
                return
            }
            item = .music(track)
        } else {
            item = nil
        }
        guard item != state.liveItem else { return }
        let widthChanged = item?.wing != state.liveItem?.wing
        state.liveItem = item
        if mode == .live && widthChanged && item != nil { morph(to: .live) }
        settleToRestingMode()
    }

    // MARK: Keyboard mode (⌃⌥V)

    func openClipboardFromKeyboard() {
        if state.keyboardMode { endKeyboardMode(paste: false); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        state.selectedTab = .clipboard
        state.keyboardMode = true
        setExpanded(true)
        panel.makeKeyAndOrderFront(nil)      // non-activating: the other app stays active
    }

    /// Returns true if the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {                                   // Esc
            endKeyboardMode(paste: false)
            return true
        }
        guard let char = event.charactersIgnoringModifiers?.first, let digit = char.wholeNumberValue else { return false }
        let index = digit == 0 ? 9 : digit - 1
        guard index < clipboard.items.count else { return true }
        clipboard.copy(clipboard.items[index])
        endKeyboardMode(paste: true)
        return true
    }

    private func endKeyboardMode(paste: Bool) {
        state.keyboardMode = false
        setExpanded(false)
        previousApp?.activate()
        previousApp = nil
        guard paste, UserDefaults.standard.bool(forKey: Prefs.pasteDirectly), AXIsProcessTrusted() else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            Self.postCommandV()
        }
    }

    /// Simulates ⌘V in the front app (needs Accessibility permission).
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func settleToRestingMode() {
        guard !state.isExpanded, state.hud == nil else { return }
        let target = restingMode
        if mode != target { morph(to: target) }
    }

    // MARK: HUD

    func showHUD(_ event: HUDEvent) {
        guard !state.isExpanded else { return }
        hudTask?.cancel()
        if mode != .hud { morph(to: .hud) }
        withAnimation(.easeOut(duration: 0.15)) { state.hud = event }
        hudTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, !Task.isCancelled, !self.state.isExpanded else { return }
            withAnimation(.easeIn(duration: 0.12)) { self.state.hud = nil }
            self.morph(to: self.restingMode)
        }
    }
}
