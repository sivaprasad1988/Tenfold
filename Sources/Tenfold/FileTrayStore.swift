import AppKit
import Combine

struct TrayFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// Files dropped onto the notch. Only references are kept – the originals are not copied or moved.
@MainActor
final class FileTrayStore: ObservableObject {
    @Published private(set) var files: [TrayFile] = []

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && !files.contains(where: { $0.url == url }) {
            files.append(TrayFile(url: url))
        }
    }

    func remove(_ file: TrayFile) { files.removeAll { $0.id == file.id } }
    func clear() { files.removeAll() }

    /// Drops entries whose file was moved or deleted in the meantime.
    func pruneMissing() {
        files.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func open(_ file: TrayFile) { NSWorkspace.shared.open(file.url) }
    func reveal(_ file: TrayFile) { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }

    func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls) else {
            NSSound.beep()
            return
        }
        NSApp.activate()          // accessory app: bring the AirDrop window to the front
        service.perform(withItems: urls)
    }
}
