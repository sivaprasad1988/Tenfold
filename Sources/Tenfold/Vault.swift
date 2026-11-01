import AppKit
import Combine
import CommonCrypto
import CryptoKit

struct VaultEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var label: String
    var secret: String
}

/// Personal clipboard for secrets, unlocked with a PIN or password.
/// Entries are AES-GCM encrypted with a key derived from the passcode (PBKDF2-SHA256) and stored in
/// `~/Library/Application Support/Tenfold/vault.json` (0600). The key exists in memory only while unlocked.
/// ponytail: a stolen vault file can be brute-forced offline – PBKDF2 makes each guess slow, so a short PIN
/// still falls in hours. Upgrade path: mix in a random key kept in the keychain / Secure Enclave, or Touch ID.
@MainActor
final class VaultStore: ObservableObject {
    static let minPasscode = 6
    static let iterations = 600_000                      // OWASP 2023 for PBKDF2-HMAC-SHA256
    static let autoLock: TimeInterval = 5 * 60
    static let clipboardClear: TimeInterval = 30
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    enum Phase { case setup, locked, unlocked }

    @Published private(set) var phase: Phase
    @Published private(set) var entries: [VaultEntry] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var copiedID: UUID?
    // View state (no @State without full Xcode – see CLAUDE.md).
    @Published var showing = false
    @Published var passcode = ""
    @Published var confirm = ""
    @Published var draftLabel = ""
    @Published var draftSecret = ""
    @Published private(set) var revealed: Set<UUID> = []
    @Published var confirmErase = false

    private var key: SymmetricKey?
    private var salt = Data()
    private var fileIterations = VaultStore.iterations
    private var failures = 0
    private var retryAt = Date.distantPast
    private var lockTask: Task<Void, Never>?
    /// Clipboard text waiting to be named and added (`moveIn`); leaves the history only once saved.
    private var pendingMove: (text: String, onMoved: () -> Void)?
    @Published private(set) var hasPendingMove = false

    private struct VaultFile: Codable {
        var version = 1
        var salt: Data
        var iterations: Int
        var sealed: Data                                  // AES-GCM combined: nonce + ciphertext + tag
    }

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tenfold", isDirectory: true)
            .appendingPathComponent("vault.json")
    }

    init() {
        phase = FileManager.default.fileExists(atPath: Self.fileURL.path) ? .locked : .setup
        assert(Self.selfCheck(), "Vault crypto self-check failed")
        // Lock when the Mac sleeps or the screen locks.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            _ = ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
        }
        _ = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
    }

    // MARK: Lock / unlock

    func create() {
        guard phase == .setup, !busy else { return }
        guard passcode.count >= Self.minPasscode else { error = LF("Use at least %d characters", Self.minPasscode); return }
        guard passcode == confirm else { error = L("The two entries don't match"); return }
        let pass = passcode, salt = Self.randomBytes(16)
        busy = true
        Task {
            let key = await Self.deriveKey(pass, salt: salt, iterations: Self.iterations)
            busy = false
            guard let key else { error = L("Could not save the vault"); return }
            self.key = key
            self.salt = salt
            fileIterations = Self.iterations
            entries = []
            guard save() else { self.key = nil; return }
            didUnlock()
        }
    }

    func unlock() {
        guard phase == .locked, !busy, !passcode.isEmpty else { return }
        let wait = retryAt.timeIntervalSinceNow
        guard wait <= 0 else { error = LF("Too many attempts – try again in %d s", Int(wait.rounded(.up))); return }
        let pass = passcode
        let file = (try? Data(contentsOf: Self.fileURL)).flatMap { try? JSONDecoder().decode(VaultFile.self, from: $0) }
        busy = true
        Task {
            var opened: [VaultEntry]?
            var key: SymmetricKey?
            if let file {
                key = await Self.deriveKey(pass, salt: file.salt, iterations: min(file.iterations, 10_000_000))
                opened = key.flatMap { Self.open(file.sealed, with: $0) }
            }
            busy = false
            guard let file, let key, let opened else {
                failures += 1
                passcode = ""
                // 3 free tries, then 5 s, 10 s, 20 s … up to 5 min between attempts.
                if failures >= 3 {
                    let delay = min(5 * pow(2, Double(failures - 3)), 300)
                    retryAt = Date().addingTimeInterval(delay)
                    error = LF("Too many attempts – try again in %d s", Int(delay))
                } else {
                    error = L("Wrong PIN or password")
                }
                return
            }
            self.key = key
            salt = file.salt
            fileIterations = file.iterations
            entries = opened
            didUnlock()
        }
    }

    func lock() {
        guard phase == .unlocked else { return }
        lockTask?.cancel()
        key = nil
        entries = []
        revealed = []
        draftLabel = ""
        draftSecret = ""
        copiedID = nil
        pendingMove = nil                                 // history item stays where it was
        hasPendingMove = false
        phase = .locked
    }

    /// Forgotten passcode: deletes the vault file and every secret in it.
    func erase() {
        try? FileManager.default.removeItem(at: Self.fileURL)
        lock()
        failures = 0
        retryAt = .distantPast
        confirmErase = false
        clearInputs()
        phase = .setup
    }

    private func didUnlock() {
        failures = 0
        retryAt = .distantPast
        clearInputs()
        if let pendingMove { draftSecret = pendingMove.text }
        phase = .unlocked
        touch()
    }

    private func clearInputs() {
        passcode = ""
        confirm = ""
        error = nil
    }

    /// Restarts the auto-lock countdown (every interaction).
    private func touch() {
        lockTask?.cancel()
        lockTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoLock * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    // MARK: Entries

    /// "Move to Vault" from the clipboard history: prefills the secret (after unlock if needed);
    /// `onMoved` removes it from the history once it is saved here.
    func moveIn(_ text: String, onMoved: @escaping () -> Void) {
        pendingMove = (text, onMoved)
        hasPendingMove = true
        showing = true
        if phase == .unlocked {
            draftSecret = text
            touch()
        }
    }

    func add() {
        guard phase == .unlocked, !draftSecret.isEmpty else { return }
        let label = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = entries
        let secret = draftSecret
        entries.insert(VaultEntry(label: label.isEmpty ? L("Secret") : label, secret: secret), at: 0)
        if save() {
            draftLabel = ""
            draftSecret = ""
            if let move = pendingMove, move.text == secret {
                move.onMoved()
                let pb = NSPasteboard.general                 // don't leave the moved secret on the clipboard
                if pb.string(forType: .string) == secret { pb.clearContents() }
            }
            pendingMove = nil
            hasPendingMove = false
        } else {
            entries = previous
        }
        touch()
    }

    func remove(_ entry: VaultEntry) {
        let previous = entries
        entries.removeAll { $0.id == entry.id }
        if !save() { entries = previous }
        touch()
    }

    func toggleReveal(_ entry: VaultEntry) {
        if revealed.contains(entry.id) { revealed.remove(entry.id) } else { revealed.insert(entry.id) }
        touch()
    }

    /// Copies the secret marked as concealed (Tenfold's history and other clipboard managers skip it)
    /// and clears the clipboard after 30 s unless something else was copied meanwhile.
    func copy(_ entry: VaultEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, Self.concealed], owner: nil)
        pb.setString(entry.secret, forType: .string)
        pb.setData(Data(), forType: Self.concealed)
        let count = pb.changeCount
        copiedID = entry.id
        touch()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.clipboardClear * 1_000_000_000))
            if pb.changeCount == count { pb.clearContents() }
            if self?.copiedID == entry.id { self?.copiedID = nil }
        }
    }

    // MARK: Storage & crypto

    @discardableResult
    private func save() -> Bool {
        guard let key else { return false }
        do {
            let plain = try JSONEncoder().encode(entries)
            guard let sealed = try AES.GCM.seal(plain, using: key).combined else { throw CocoaError(.fileWriteUnknown) }
            let data = try JSONEncoder().encode(VaultFile(salt: salt, iterations: fileIterations, sealed: sealed))
            let url = Self.fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            error = nil
            return true
        } catch {
            self.error = L("Could not save the vault")
            return false
        }
    }

    private nonisolated static func open(_ sealed: Data, with key: SymmetricKey) -> [VaultEntry]? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }   // wrong key fails the GCM tag
        return try? JSONDecoder().decode([VaultEntry].self, from: plain)
    }

    /// PBKDF2 off the main thread (~0.3 s at 600k iterations).
    private nonisolated static func deriveKey(_ passcode: String, salt: Data, iterations: Int) async -> SymmetricKey? {
        await Task.detached(priority: .userInitiated) { pbkdf2(passcode, salt: salt, iterations: iterations) }.value
    }

    private nonisolated static func pbkdf2(_ passcode: String, salt: Data, iterations: Int) -> SymmetricKey? {
        let password = Array(passcode.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { pw in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                     pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &derived, derived.count)
            }
        }
        return status == kCCSuccess ? SymmetricKey(data: derived) : nil
    }

    private nonisolated static func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()           // CSPRNG on Apple platforms
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }

    /// Debug builds: round trip with the right passcode opens, a wrong one does not.
    private nonisolated static func selfCheck() -> Bool {
        let salt = randomBytes(16)
        guard let key = pbkdf2("123456", salt: salt, iterations: 1_000),
              let wrong = pbkdf2("123457", salt: salt, iterations: 1_000),
              let plain = try? JSONEncoder().encode([VaultEntry(label: "a", secret: "s3cret")]),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return false }
        return open(sealed, with: key)?.first?.secret == "s3cret" && open(sealed, with: wrong) == nil
    }
}
