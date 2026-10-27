import AppKit
import Combine

/// Now-playing info + transport controls for Spotify and Apple Music.
/// Scripts run out-of-process via /usr/bin/osascript, so the UI never blocks.
/// (Apple's private MediaRemote framework is restricted for third-party apps since macOS 15.4.)
@MainActor
final class MediaController: ObservableObject {
    enum Player: String {
        case spotify = "Spotify"
        case music = "Music"

        var bundleID: String {
            switch self {
            case .spotify: return "com.spotify.client"
            case .music: return "com.apple.Music"
            }
        }
    }

    struct NowPlaying: Equatable {
        let player: Player
        let title: String
        let artist: String
        let album: String
        let isPlaying: Bool
        let artworkURL: URL?
        let duration: Double       // seconds
        let position: Double       // seconds, at `fetchedAt`
        let shuffle: Bool
        let repeatOn: Bool
        let fetchedAt: Date

        /// Playback position extrapolated to `date` (smooth progress between polls).
        func elapsed(at date: Date) -> Double {
            let value = isPlaying ? position + date.timeIntervalSince(fetchedAt) : position
            return duration > 0 ? min(max(value, 0), duration) : max(value, 0)
        }
    }

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var automationDenied = false
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private var refreshing = false

    private var interval: TimeInterval = 5

    func startPolling() {
        guard timer == nil else { return }
        refresh()
        scheduleTimer()
    }

    /// 2 s while a panel is open, 5 s otherwise (each poll launches a short osascript process).
    func setFastPolling(_ fast: Bool) {
        let wanted: TimeInterval = fast ? 2 : 5
        guard wanted != interval else { return }
        interval = wanted
        if timer != nil { scheduleTimer() }
        if fast { refresh() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !refreshing else { return }
        let players = [Player.spotify, .music].filter { isRunning($0) }
        guard !players.isEmpty else {
            nowPlaying = nil
            lastError = nil
            return
        }
        refreshing = true
        Task { @MainActor in
            var found: [NowPlaying] = []
            var error: String?
            var denied = false
            for player in players {
                let result = await Self.osascript(Self.statusScript(for: player))
                if result.status == 0 {
                    if let np = Self.parse(result.output, player: player) { found.append(np) }
                } else {
                    error = "\(player.rawValue): \(result.error)"
                    if result.error.contains("-1743") { denied = true }
                }
            }
            nowPlaying = found.first(where: { $0.isPlaying }) ?? found.first
            automationDenied = denied && found.isEmpty
            lastError = found.isEmpty ? error : nil
            refreshing = false
        }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        send("set player position to \(String(format: "%.1f", max(seconds, 0)))")
    }

    func toggleShuffle() {
        guard let player = nowPlaying?.player else { return }
        send(player == .spotify ? "set shuffling to not shuffling"
                                : "set shuffle enabled to not shuffle enabled")
    }

    func toggleRepeat() {
        guard let player = nowPlaying?.player else { return }
        send(player == .spotify ? "set repeating to not repeating"
                                : "if song repeat is off then set song repeat to all else set song repeat to off")
    }

    /// Brings Spotify / Music to the front.
    func openPlayer() {
        guard let player = nowPlaying?.player,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Private

    private func isRunning(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
    }

    private func send(_ command: String) {
        guard let player = nowPlaying?.player else { return }
        let source = "tell application \"\(player.rawValue)\"\n\(command)\nend tell"
        Task { @MainActor in
            _ = await Self.osascript(source)
            try? await Task.sleep(nanoseconds: 250_000_000)
            refresh()
        }
    }

    private static func statusScript(for player: Player) -> String {
        let spotify = player == .spotify
        let artwork = spotify ? "set u to artwork url of current track" : "set u to \"\""
        let duration = spotify ? "set d to (duration of current track) / 1000" : "set d to duration of current track"
        let shuffle = spotify ? "set sh to shuffling as string" : "set sh to shuffle enabled as string"
        let repeatLine = spotify ? "set rp to repeating as string" : "set rp to (song repeat is not off) as string"
        return """
        tell application "\(player.rawValue)"
            if player state is stopped then return "stopped"
            set p to (player state is playing) as string
            set t to name of current track
            set a to artist of current track
            set al to ""
            set d to 0
            set pos to 0
            set sh to "false"
            set rp to "false"
            set u to ""
            try
                set al to album of current track
            end try
            try
                \(duration)
            end try
            try
                set pos to player position
            end try
            try
                \(shuffle)
            end try
            try
                \(repeatLine)
            end try
            try
                \(artwork)
            end try
            return p & "||" & t & "||" & a & "||" & u & "||" & al & "||" & d & "||" & pos & "||" & sh & "||" & rp
        end tell
        """
    }

    private static func parse(_ output: String, player: Player) -> NowPlaying? {
        guard output != "stopped" else { return nil }
        let parts = output.components(separatedBy: "||")
        guard parts.count == 9 else { return nil }
        // Numbers may use a decimal comma on German systems.
        func number(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return NowPlaying(player: player,
                          title: parts[1],
                          artist: parts[2],
                          album: parts[4],
                          isPlaying: parts[0] == "true",
                          artworkURL: parts[3].isEmpty ? nil : URL(string: parts[3]),
                          duration: number(parts[5]),
                          position: number(parts[6]),
                          shuffle: parts[7] == "true",
                          repeatOn: parts[8] == "true",
                          fetchedAt: Date())
    }

    private nonisolated static func osascript(_ source: String) async -> (output: String, error: String, status: Int32) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (out.trimmingCharacters(in: .whitespacesAndNewlines),
                                                err.trimmingCharacters(in: .whitespacesAndNewlines),
                                                proc.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: ("", error.localizedDescription, -1))
            }
        }
    }
}
