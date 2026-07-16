import Foundation
import AVFoundation
import Accelerate
import QuartzCore

/// System-default microphone tap + bass onset detection.
/// Publishes smoothed `level` and decaying `beatPulse` (0…1) for the renderer.
final class AudioBeat {
    private let engine = AVAudioEngine()
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var real: [Float] = []
    private var imag: [Float] = []
    private var magnitudes: [Float] = []

    /// Accumulates mono samples until we have a full FFT window (taps often deliver <1024).
    private var ring: [Float] = []
    private var ringWrite = 0
    private var ringFilled = 0
    private var samplesSinceAnalyze = 0

    private let lock = NSLock()
    private var _level: Float = 0
    private var _beatPulse: Float = 0
    private var runningAverage: Float = 0.02
    private var lastOnsetTime: CFTimeInterval = 0
    private var sampleRate: Double = 44_100

    private(set) var isRunning = false

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    var beatPulse: Float {
        lock.lock(); defer { lock.unlock() }
        return _beatPulse
    }

    init() {
        let n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        ring = [Float](repeating: 0, count: fftSize)
    }

    deinit {
        stop()
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginEngine()
                    } else {
                        fputs("AudioBeat: microphone permission denied — beat reactivity disabled\n", stderr)
                    }
                }
            }
        default:
            fputs("AudioBeat: microphone permission denied — beat reactivity disabled\n", stderr)
            fputs("AudioBeat: enable Mic access for DSNK Wall in System Settings → Privacy & Security → Microphone\n", stderr)
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        isRunning = false
        ringWrite = 0
        ringFilled = 0
        samplesSinceAnalyze = 0
    }

    /// Call once per frame to decay the beat pulse.
    func tick() {
        lock.lock()
        _beatPulse *= Config.beatDecay
        if _beatPulse < 0.001 { _beatPulse = 0 }
        lock.unlock()
    }

    // MARK: - Engine (system default input)

    private func beginEngine() {
        stop()

        let input = engine.inputNode
        // Use whatever macOS has as the default input (same as other apps).
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate > 0 ? format.sampleRate : 44_100
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fputs("AudioBeat: no valid default input format\n", stderr)
            return
        }

        input.removeTap(onBus: 0)
        let bufferSize = AVAudioFrameCount(min(fftSize, 512))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
            self?.ingest(buffer: buffer)
        }

        do {
            try engine.start()
            isRunning = true
            fputs(
                String(format: "AudioBeat: listening on system default input (%.0f Hz, %d ch)\n",
                       sampleRate, Int(format.channelCount)),
                stderr
            )
        } catch {
            fputs("AudioBeat: failed to start engine: \(error)\n", stderr)
            input.removeTap(onBus: 0)
            isRunning = false
        }
    }

    // MARK: - Analysis

    private func ingest(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        for c in 0..<channels {
            vDSP_vadd(mono, 1, channelData[c], 1, &mono, 1, vDSP_Length(frameCount))
        }
        if channels > 1 {
            var scale = 1.0 / Float(channels)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frameCount))
        }

        for s in mono {
            ring[ringWrite] = s
            ringWrite = (ringWrite + 1) % fftSize
            if ringFilled < fftSize { ringFilled += 1 }
        }
        samplesSinceAnalyze += frameCount

        if ringFilled >= fftSize, samplesSinceAnalyze >= fftSize / 2 {
            samplesSinceAnalyze = 0
            analyzeRing()
        }
    }

    private func analyzeRing() {
        guard let setup = fftSetup else { return }

        var samples = [Float](repeating: 0, count: fftSize)
        let start = ringWrite
        for i in 0..<fftSize {
            samples[i] = ring[(start + i) % fftSize]
        }
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                samples.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        let hzPerBin = Float(sampleRate) / Float(fftSize)
        let kickStart = max(1, Int(40.0 / hzPerBin))
        let kickEnd = min(magnitudes.count - 1, Int(220.0 / hzPerBin))
        let kickBins = max(1, kickEnd - kickStart + 1)
        var bass: Float = 0
        magnitudes.withUnsafeBufferPointer { buf in
            vDSP_sve(buf.baseAddress! + kickStart, 1, &bass, vDSP_Length(kickBins))
        }
        bass = sqrt(max(bass / Float(kickBins), 0)) / Float(fftSize)

        let midEnd = min(magnitudes.count - 1, Int(400.0 / hzPerBin))
        var mid: Float = 0
        let midBins = max(1, midEnd - kickStart + 1)
        magnitudes.withUnsafeBufferPointer { buf in
            vDSP_sve(buf.baseAddress! + kickStart, 1, &mid, vDSP_Length(midBins))
        }
        mid = sqrt(max(mid / Float(midBins), 0)) / Float(fftSize)
        let energy = max(bass, mid * 0.65)

        let smoothed = runningAverage * 0.85 + energy * 0.15
        runningAverage = runningAverage * 0.98 + energy * 0.02

        let ratio = energy / max(runningAverage, 1e-6)
        let now = CACurrentMediaTime()
        var pulseBoost: Float = 0
        let thresh = 1.35 / Config.beatSensitivity
        if ratio > thresh && (now - lastOnsetTime) > 0.09 {
            lastOnsetTime = now
            pulseBoost = min(1.0, (ratio - 1.0) * 0.65 * Config.beatSensitivity)
        }

        lock.lock()
        _level = min(1.0, smoothed * 10.0)
        if pulseBoost > _beatPulse {
            _beatPulse = pulseBoost
        }
        lock.unlock()
    }
}
