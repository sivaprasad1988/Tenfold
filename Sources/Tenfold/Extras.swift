import AppKit
@preconcurrency import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI

// MARK: - Focus timer (Pomodoro)

@MainActor
final class FocusTimer: ObservableObject {
    enum Phase: String { case focus, rest }

    struct Preset: Identifiable, Equatable {
        let focus: Int
        let rest: Int
        var id: String { "\(focus)/\(rest)" }
    }

    static let presets = [Preset(focus: 25, rest: 5), Preset(focus: 50, rest: 10), Preset(focus: 15, rest: 3)]

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var isRunning = false
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval
    @Published private(set) var sessionsToday: Int
    @Published private(set) var preset: Preset

    private var timer: Timer?
    private let defaults = UserDefaults.standard

    init() {
        let stored = UserDefaults.standard
        let focus = stored.object(forKey: "focus.minutes") as? Int ?? 25
        let rest = stored.object(forKey: "focus.break") as? Int ?? 5
        preset = Preset(focus: focus, rest: rest)
        pausedRemaining = Double(focus) * 60
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        sessionsToday = stored.double(forKey: "focus.day") == day ? stored.integer(forKey: "focus.sessions") : 0
    }

    var duration: TimeInterval { Double(phase == .focus ? preset.focus : preset.rest) * 60 }

    /// True while a session is running or paused part-way.
    var isActive: Bool { isRunning || pausedRemaining < duration - 0.5 }

    func remaining(at date: Date = Date()) -> TimeInterval {
        guard isRunning, let endDate else { return pausedRemaining }
        return max(endDate.timeIntervalSince(date), 0)
    }

    func progress(at date: Date = Date()) -> Double {
        duration > 0 ? 1 - remaining(at: date) / duration : 0
    }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        let end = Date().addingTimeInterval(pausedRemaining)
        endDate = end
        isRunning = true
        schedule(at: end)
    }

    func pause() {
        guard isRunning else { return }
        pausedRemaining = remaining()
        isRunning = false
        endDate = nil
        timer?.invalidate()
    }

    func reset() {
        pause()
        phase = .focus
        pausedRemaining = duration
    }

    func skip() { advance(countSession: false, autoStart: isRunning) }

    func choose(_ preset: Preset) {
        self.preset = preset
        defaults.set(preset.focus, forKey: "focus.minutes")
        defaults.set(preset.rest, forKey: "focus.break")
        reset()
    }

    private func schedule(at date: Date) {
        timer?.invalidate()
        let t = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finished() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func finished() {
        NSSound(named: phase == .focus ? "Glass" : "Hero")?.play()
        // After focus → break starts automatically; after a break we wait for the user.
        advance(countSession: phase == .focus, autoStart: phase == .focus)
    }

    private func advance(countSession: Bool, autoStart: Bool) {
        timer?.invalidate()
        if countSession {
            let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            if defaults.double(forKey: "focus.day") != day { sessionsToday = 0 }
            sessionsToday += 1
            defaults.set(day, forKey: "focus.day")
            defaults.set(sessionsToday, forKey: "focus.sessions")
        }
        phase = phase == .focus ? .rest : .focus
        isRunning = false
        endDate = nil
        pausedRemaining = duration
        if autoStart { start() }
    }
}

// MARK: - Quick notes

@MainActor
final class NotesStore: ObservableObject {
    @Published var text: String {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tenfold", isDirectory: true)
            .appendingPathComponent("notes.txt")
    }

    init() {
        text = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled else { return }
            self.save()
        }
    }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Screenshot shelf

/// Latest screenshots (last 24 h). Two sources, merged:
/// 1. the screenshot folder itself (com.apple.screencapture "location", default Desktop), scanned every 2 s –
///    files are recognised by the `kMDItemIsScreenCapture` extended attribute macOS writes on screenshots;
/// 2. Spotlight (`kMDItemIsScreenCapture == 1`) for screenshots saved elsewhere.
@MainActor
final class ScreenshotStore: ObservableObject {
    struct Shot: Identifiable, Equatable {
        let id: URL
        let date: Date
    }

    @Published private(set) var shots: [Shot] = []

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var thumbnails: [URL: NSImage] = [:]
    private var spotlightShots: [Shot] = []
    private var folderShots: [Shot] = []
    private var folderTimer: Timer?

    /// Folder macOS saves screenshots to (⌘⇧5 → Options can change it).
    static var screenshotFolder: URL {
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    func start() {
        scanFolder()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanFolder() }
        }
        RunLoop.main.add(t, forMode: .common)
        folderTimer = t

        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@",
                                      Date().addingTimeInterval(-86_400) as NSDate)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSCreationDateKey, ascending: false)]
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            })
        }
        query.start()
    }

    private func reload() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var result: [Shot] = []
        for index in 0..<min(query.resultCount, 12) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let date = item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? Date()
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) { result.append(Shot(id: url, date: date)) }
        }
        spotlightShots = result
        publish()
    }

    private var lastFolderDate: Date?
    private var lastFolderPath = ""

    private func scanFolder() {
        let folder = Self.screenshotFolder
        // Cheap check first: skip the scan if the folder's modification date is unchanged.
        let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if folder.path == lastFolderPath, let modified, modified == lastFolderDate { return }
        lastFolderPath = folder.path
        lastFolderDate = modified
        let cutoff = Date().addingTimeInterval(-86_400)
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return }
        var result: [Shot] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let created = values.creationDate, created >= cutoff, Self.isScreenCapture(url) else { continue }
            result.append(Shot(id: url, date: created))
        }
        folderShots = result
        publish()
    }

    /// macOS marks screenshots with this extended attribute (independent of file name / language).
    private static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
    }

    private func publish() {
        var byURL: [URL: Shot] = [:]
        for shot in spotlightShots + folderShots { byURL[shot.id] = shot }
        let merged = Array(byURL.values.filter { FileManager.default.fileExists(atPath: $0.id.path) }
            .sorted { $0.date > $1.date }
            .prefix(12))
        if merged != shots { shots = merged }
    }

    func thumbnail(for shot: Shot) -> NSImage {
        if let cached = thumbnails[shot.id] { return cached }
        let image = NSImage(contentsOf: shot.id) ?? NSWorkspace.shared.icon(forFile: shot.id.path)
        thumbnails[shot.id] = image
        return image
    }

    func copy(_ shot: Shot) {
        guard let image = NSImage(contentsOf: shot.id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    func reveal(_ shot: Shot) { NSWorkspace.shared.activateFileViewerSelecting([shot.id]) }

    func trash(_ shot: Shot) {
        NSWorkspace.shared.recycle([shot.id]) { _, _ in }
        spotlightShots.removeAll { $0.id == shot.id }
        folderShots.removeAll { $0.id == shot.id }
        shots.removeAll { $0.id == shot.id }
    }
}

// MARK: - Camera mirror

@MainActor
final class CameraController: ObservableObject {
    enum Status { case off, running, denied }

    @Published private(set) var status: Status = .off
    let session = AVCaptureSession()

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.run() } else { self?.status = .denied }
                }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        guard status == .running else { return }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        status = .off
    }

    private func run() {
        if session.inputs.isEmpty,
           let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        status = .running
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Mirrored live camera preview.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))   // mirror like a real mirror
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Global hot key (Carbon – works without Accessibility permission)


final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Default: ⌃⌥V (⌥⌘V is taken by Finder's "Move item here").
    init(keyCode: UInt32 = UInt32(kVK_ANSI_V), modifiers: UInt32 = UInt32(controlKey | optionKey), action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, userData, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x54_4E_46_44), id: 1)   // 'TNFD'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

// MARK: - Container passed to the notch

@MainActor
final class Extras {
    let focus = FocusTimer()
    let notes = NotesStore()
    let screenshots = ScreenshotStore()
    let camera = CameraController()
    let usage = UsageStore()
}
