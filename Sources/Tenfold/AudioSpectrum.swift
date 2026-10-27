import AppKit
import Accelerate
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import QuartzCore
import SwiftUI

/// Real-time spectrum of everything the Mac plays, via a Core Audio process tap (macOS 14.2+).
/// Needs the "System Audio Recording" permission (NSAudioCaptureUsageDescription). Audio is analysed
/// in memory only – nothing is recorded or stored.
@MainActor
final class AudioSpectrum: ObservableObject {
    static let shared = AudioSpectrum()
    nonisolated static let bandCount = 32

    /// 0…1 per band, low → high frequencies. Deliberately NOT @Published: 20 updates/s would make
    /// SwiftUI re-layout the whole panel each time. Bar views listen to `bandsDidChange` and update
    /// Core Animation layers directly (GPU), bypassing SwiftUI.
    private(set) var bands = [Float](repeating: 0, count: AudioSpectrum.bandCount)
    let bandsDidChange = PassthroughSubject<Void, Never>()
    /// True while non-silent audio arrives (false if permission is missing → views fall back to animation).
    @Published private(set) var isLive = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "de.woit.tenfold.spectrum", qos: .userInteractive)
    private var analyzer: SpectrumAnalyzer?
    private(set) var isRunning = false

    /// Resamples the bands to `count` bars (e.g. 4 for the mini equalizer, 36 for the large one).
    func levels(count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let n = bands.count
        return (0..<count).map { i in
            let lo = i * n / count
            let hi = max(lo + 1, (i + 1) * n / count)
            let slice = bands[lo..<min(hi, n)]
            return CGFloat(slice.reduce(0, +) / Float(slice.count))
        }
    }

    func start() {
        guard !isRunning else { return }
        guard #available(macOS 14.2, *) else { return }

        // 1. Global stereo tap of all apps (we exclude nobody); audio keeps playing normally.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return }
        tapID = tap

        // 2. Private aggregate device = default output + our tap.
        guard let outputUID = Self.defaultOutputUID() else { teardown(); return }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tenfold Equalizer",
            kAudioAggregateDeviceUIDKey: "de.woit.tenfold.equalizer.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else { teardown(); return }
        aggregateID = device

        // 3. IO proc on a background queue → FFT → bands.
        let analyzer = Self.makeAnalyzer(sampleRate: Self.sampleRate(ofTap: tap) ?? 48_000, owner: self)
        self.analyzer = analyzer
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue, Self.makeIOBlock(analyzer)) == noErr,
              let proc else { teardown(); return }
        procID = proc
        guard AudioDeviceStart(device, proc) == noErr else { teardown(); return }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        teardown()
    }

    private func teardown() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown), #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        analyzer = nil
        isRunning = false
        bands = [Float](repeating: 0, count: Self.bandCount)
        bandsDidChange.send()
        isLive = false
    }

    fileprivate func publish(_ newBands: [Float], live: Bool) {
        guard isRunning else { return }
        bands = newBands
        bandsDidChange.send()
        if live != isLive { isLive = live }
    }

    // MARK: Helpers (nonisolated so the closures don't inherit main-actor isolation)

    private nonisolated static func makeAnalyzer(sampleRate: Double, owner: AudioSpectrum) -> SpectrumAnalyzer {
        SpectrumAnalyzer(sampleRate: sampleRate, bandCount: bandCount) { [weak owner] bands, live in
            guard let target = owner else { return }
            Task { @MainActor in target.publish(bands, live: live) }
        }
    }

    private nonisolated static func makeIOBlock(_ analyzer: SpectrumAnalyzer) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in analyzer.process(input) }
    }

    private nonisolated static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr
        else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private nonisolated static func sampleRate(ofTap tap: AudioObjectID) -> Double? {
        guard #available(macOS 14.2, *) else { return nil }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format) == noErr, format.mSampleRate > 0
        else { return nil }
        return format.mSampleRate
    }
}

/// FFT analysis on the audio queue (not main actor). 1024-point FFT, 50 % overlap, Hann window,
/// 32 log-spaced bands 40 Hz – 16 kHz, fast attack / slow release, ~30 updates per second.
final class SpectrumAnalyzer: @unchecked Sendable {
    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let setup: FFTSetup
    private var window: [Float]
    private var buffer: [Float]
    private var fill = 0
    private var smoothed: [Float]
    private let bandBins: [(Int, Int)]
    private let bandGain: [Float]
    private var lastPublish: CFTimeInterval = 0
    private var lastSent: [Float] = []
    private var lastLive = false
    private var windowed = [Float](repeating: 0, count: 1024)
    private var real = [Float](repeating: 0, count: 512)
    private var imag = [Float](repeating: 0, count: 512)
    private var magnitudes = [Float](repeating: 0, count: 512)
    private let onBands: ([Float], Bool) -> Void

    init(sampleRate: Double, bandCount: Int, onBands: @escaping ([Float], Bool) -> Void) {
        self.onBands = onBands
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        var hann = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&hann, vDSP_Length(1024), Int32(vDSP_HANN_NORM))
        window = hann
        buffer = [Float](repeating: 0, count: 1024)
        smoothed = [Float](repeating: 0, count: bandCount)

        let minF = 40.0, maxF = min(16_000.0, sampleRate / 2 - 1)
        var bins: [(Int, Int)] = []
        var gains: [Float] = []
        for i in 0..<bandCount {
            let f0 = minF * pow(maxF / minF, Double(i) / Double(bandCount))
            let f1 = minF * pow(maxF / minF, Double(i + 1) / Double(bandCount))
            let lo = max(1, Int(f0 * 1024 / sampleRate))
            let hi = max(lo + 1, Int(f1 * 1024 / sampleRate))
            bins.append((lo, min(hi, 512)))
            gains.append(Float(i) / Float(max(bandCount - 1, 1)) * 12)   // +0…12 dB tilt for highs
        }
        bandBins = bins
        bandGain = gains
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Called from the Core Audio IO thread with the tap's Float32 samples.
    func process(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = list.first, let data = first.mData else { return }
        let p0 = data.assumingMemoryBound(to: Float.self)
        if list.count == 1 {
            let channels = max(Int(first.mNumberChannels), 1)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += p0[f * channels + c] }
                push(sum / Float(channels))
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let p1 = list[1].mData?.assumingMemoryBound(to: Float.self)
            for f in 0..<frames { push((p0[f] + (p1?[f] ?? p0[f])) * 0.5) }
        }
    }

    private func push(_ sample: Float) {
        buffer[fill] = sample
        fill += 1
        if fill == n {
            analyze()        // ~47 analyses/s at 48 kHz – plenty for 20 UI updates/s
            fill = 0
        }
    }

    private func analyze() {
        var rms: Float = 0
        vDSP_rmsqv(buffer, 1, &rms, vDSP_Length(n))

        vDSP_vmul(buffer, 1, window, 1, &windowed, 1, vDSP_Length(n))
        let half = n / 2, log2n = self.log2n, setup = self.setup
        let windowedCopy = windowed
        var magnitudes: [Float] = []
        swap(&magnitudes, &self.magnitudes)          // borrow the buffer without copying
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowedCopy.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        defer { swap(&magnitudes, &self.magnitudes) }   // give the buffer back after use
        let live = rms > 0.0003
        for (i, (lo, hi)) in bandBins.enumerated() {
            var sum: Float = 0
            for bin in lo..<max(hi, lo + 1) where bin < magnitudes.count { sum += magnitudes[bin] }
            let mean = sum / Float(max(hi - lo, 1))
            let amplitude = sqrt(mean) / Float(n)
            let db = 20 * log10(amplitude + 1e-9) + bandGain[i]
            let target = live ? min(max((db + 70) / 60, 0), 1) : 0       // −70 dB … −10 dB → 0 … 1
            let previous = smoothed[i]
            smoothed[i] = target > previous ? previous + (target - previous) * 0.6
                                            : previous + (target - previous) * 0.18
        }

        // 20 updates/s are plenty for the eye; skip frames where nothing visibly changed.
        let now = CACurrentMediaTime()
        guard now - lastPublish >= 1.0 / 20.0 else { return }
        var maxDelta: Float = lastSent.count == smoothed.count ? 0 : 1
        if lastSent.count == smoothed.count {
            for i in 0..<smoothed.count { maxDelta = max(maxDelta, abs(smoothed[i] - lastSent[i])) }
        }
        guard maxDelta > 0.015 || live != lastLive else { return }
        lastPublish = now
        lastSent = smoothed
        lastLive = live
        onBands(smoothed, live)
    }
}

// MARK: - Layer-backed bars (no SwiftUI work per frame)


/// Equalizer bars drawn with plain CALayers; heights change via Core Animation (render server / GPU).
final class SpectrumBarsNSView: NSView {
    var barCount: Int { didSet { if barCount != oldValue { rebuild() } } }
    var spacing: CGFloat { didSet { needsLayout = true } }
    var color: NSColor { didSet { barLayers.forEach { $0.backgroundColor = color.cgColor } } }

    private var barLayers: [CALayer] = []
    private var subscription: AnyCancellable?

    init(barCount: Int, spacing: CGFloat, color: NSColor) {
        self.barCount = barCount
        self.spacing = spacing
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        rebuild()
        subscription = AudioSpectrum.shared.bandsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateBars(animated: true) }
    }

    required init?(coder: NSCoder) { nil }

    private func rebuild() {
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers = (0..<max(barCount, 1)).map { _ in
            let bar = CALayer()
            bar.backgroundColor = color.cgColor
            layer?.addSublayer(bar)
            return bar
        }
        updateBars(animated: false)
    }

    override func layout() {
        super.layout()
        updateBars(animated: false)
    }

    private func updateBars(animated: Bool) {
        let levels = AudioSpectrum.shared.levels(count: barLayers.count)
        let count = CGFloat(barLayers.count)
        let width = max((bounds.width - spacing * (count - 1)) / count, 1)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.08)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        } else {
            CATransaction.setDisableActions(true)
        }
        for (i, bar) in barLayers.enumerated() {
            let level = min(max(i < levels.count ? levels[i] : 0, 0.08), 1)
            let height = max(width, bounds.height * level)
            bar.frame = CGRect(x: CGFloat(i) * (width + spacing), y: (bounds.height - height) / 2,
                               width: width, height: height)
            bar.cornerRadius = width / 2
            bar.opacity = Float(0.5 + 0.5 * level)
        }
        CATransaction.commit()
    }
}

struct SpectrumBars: NSViewRepresentable {
    let bars: Int
    let color: Color
    let spacing: CGFloat

    func makeNSView(context: Context) -> SpectrumBarsNSView {
        SpectrumBarsNSView(barCount: bars, spacing: spacing, color: NSColor(color))
    }

    func updateNSView(_ view: SpectrumBarsNSView, context: Context) {
        view.barCount = bars
        view.spacing = spacing
        view.color = NSColor(color)
    }
}
