import AppKit
import AudioToolbox
import Combine
import CoreAudio

/// Observes output volume (CoreAudio, public API) and built-in display brightness
/// (DisplayServices, PRIVATE API – loaded dynamically, silently disabled if unavailable).
/// It also lets the notch sliders set volume and brightness.
/// The system's own volume/brightness overlay is not hidden.
@MainActor
final class SystemHUDMonitor: ObservableObject {
    var onEvent: ((HUDEvent) -> Void)?

    // Current levels for the sliders (0...1).
    @Published private(set) var volume: Double = 0
    @Published private(set) var muted = false
    @Published private(set) var volumeAvailable = false
    @Published private(set) var brightness: Double = 0
    @Published private(set) var brightnessAvailable = false

    private let unknownID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var lastVolume: Float32 = -1
    private var lastMuted = false

    private typealias GetBrightnessFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (UInt32, Float) -> Int32
    private var getBrightness: GetBrightnessFn?
    private var setBrightnessFn: SetBrightnessFn?
    private var brightnessTimer: Timer?
    private var lastBrightness: Float = -1

    func start() {
        listenForDefaultDeviceChanges()
        attachToDefaultDevice()
        startBrightnessPolling()
    }

    // MARK: Volume (CoreAudio)

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func listenForDefaultDeviceChanges() {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attachToDefaultDevice() }
        }
        defaultDeviceListener = block
        _ = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }

    private func attachToDefaultDevice() {
        detachFromDevice()

        var id = unknownID
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != unknownID else { return }
        deviceID = id
        lastVolume = readVolume() ?? -1
        lastMuted = readMuted()
        volumeAvailable = lastVolume >= 0
        volume = Double(max(lastVolume, 0))
        muted = lastMuted

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.audioChanged() }
        }
        volumeListener = block
        var vAddr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(id, &vAddr) {
            _ = AudioObjectAddPropertyListenerBlock(id, &vAddr, .main, block)
        }
        var mAddr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectHasProperty(id, &mAddr) {
            _ = AudioObjectAddPropertyListenerBlock(id, &mAddr, .main, block)
        }
    }

    private func detachFromDevice() {
        guard deviceID != unknownID, let block = volumeListener else { return }
        var vAddr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &vAddr, .main, block)
        var mAddr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &mAddr, .main, block)
        volumeListener = nil
        deviceID = unknownID
    }

    private func readVolume() -> Float32? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(deviceID, &addr),
              AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func readMuted() -> Bool {
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(deviceID, &addr),
              AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private func audioChanged() {
        guard let volume = readVolume() else { return }
        let muted = readMuted()
        guard abs(volume - lastVolume) > 0.001 || muted != lastMuted else { return }
        lastVolume = volume
        lastMuted = muted
        self.volume = Double(volume)
        self.muted = muted
        onEvent?(HUDEvent(kind: .volume, level: Double(volume), muted: muted))
    }

    /// Sets the output volume (0...1) of the default device; unmutes when raised above 0.
    func setVolume(_ value: Double) {
        guard deviceID != unknownID else { return }
        var level = Float32(min(max(value, 0), 1))
        var vAddr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(deviceID, &vAddr) else { return }
        _ = AudioObjectSetPropertyData(deviceID, &vAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)

        if lastMuted && level > 0 {
            var mAddr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
            var off: UInt32 = 0
            if AudioObjectHasProperty(deviceID, &mAddr) {
                _ = AudioObjectSetPropertyData(deviceID, &mAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
            }
        }
        // Update immediately so the slider feels instant; the listener confirms it.
        lastVolume = level
        lastMuted = lastMuted && level == 0
        volume = Double(level)
        muted = lastMuted
    }

    // MARK: Brightness (private DisplayServices API)

    private func startBrightnessPolling() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return }
        getBrightness = unsafeBitCast(symbol, to: GetBrightnessFn.self)
        if let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightnessFn = unsafeBitCast(setSymbol, to: SetBrightnessFn.self)
        }
        lastBrightness = readBrightness() ?? -1
        brightnessAvailable = lastBrightness >= 0 && setBrightnessFn != nil
        brightness = Double(max(lastBrightness, 0))

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkBrightness() }
        }
        t.tolerance = 0.1
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cachedDisplayID = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        brightnessTimer = t
    }

    private var cachedDisplayID: CGDirectDisplayID?

    private var builtInDisplayID: CGDirectDisplayID? {
        if let cachedDisplayID { return cachedDisplayID }
        cachedDisplayID = findBuiltInDisplay()
        return cachedDisplayID
    }

    private func findBuiltInDisplay() -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            if CGDisplayIsBuiltin(id) != 0 { return id }
        }
        return nil
    }

    private func readBrightness() -> Float? {
        guard let fn = getBrightness, let display = builtInDisplayID else { return nil }
        var value: Float = 0
        return fn(display, &value) == 0 ? value : nil
    }

    private func checkBrightness() {
        guard let value = readBrightness() else { return }
        if lastBrightness < 0 { lastBrightness = value; return }
        guard abs(value - lastBrightness) >= 0.01 else { return }
        lastBrightness = value
        brightness = Double(value)
        onEvent?(HUDEvent(kind: .brightness, level: Double(value), muted: false))
    }

    /// Sets the built-in display brightness (0...1) via the private DisplayServices API.
    func setBrightness(_ value: Double) {
        guard let fn = setBrightnessFn, let display = builtInDisplayID else { return }
        let level = Float(min(max(value, 0), 1))
        guard fn(display, level) == 0 else { return }
        lastBrightness = level          // prevents the poller from treating this as an external change
        brightness = Double(level)
    }
}
