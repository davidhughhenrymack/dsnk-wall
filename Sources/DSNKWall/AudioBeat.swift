import Foundation
import AVFoundation
import Accelerate
import QuartzCore

/// Microphone tap + bass energy onset detection.
/// Publishes a smoothed `level` and decaying `beatPulse` (0…1) for the renderer.
final class AudioBeat {
    private let engine = AVAudioEngine()
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    private var real: [Float] = []
    private var imag: [Float] = []
    private var magnitudes: [Float] = []

    private let lock = NSLock()
    private var _level: Float = 0
    private var _beatPulse: Float = 0
    private var runningAverage: Float = 0.02
    private var lastOnsetTime: CFTimeInterval = 0

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
    }

    deinit {
        stop()
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    func start() {
        guard !isRunning else { return }

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
            fputs("AudioBeat: microphone unavailable — beat reactivity disabled\n", stderr)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Call once per frame to decay the beat pulse.
    func tick() {
        lock.lock()
        _beatPulse *= Config.beatDecay
        if _beatPulse < 0.001 { _beatPulse = 0 }
        lock.unlock()
    }

    private func beginEngine() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fputs("AudioBeat: no valid input format\n", stderr)
            return
        }

        let bufferSize = AVAudioFrameCount(fftSize)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            fputs("AudioBeat: failed to start engine: \(error)\n", stderr)
            input.removeTap(onBus: 0)
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let setup = fftSetup,
              let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize else { return }

        var samples = [Float](repeating: 0, count: fftSize)
        // Mix down to mono if needed.
        let channels = Int(buffer.format.channelCount)
        for c in 0..<channels {
            vDSP_vadd(samples, 1, channelData[c], 1, &samples, 1, vDSP_Length(fftSize))
        }
        if channels > 1 {
            var scale = 1.0 / Float(channels)
            vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(fftSize))
        }
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        // FFT
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

        // Kick-focused energy: skip DC, use ~40–220 Hz (bins 1…5 at 44.1k / 1024).
        let kickStart = 1
        let kickBins = 5
        var bass: Float = 0
        magnitudes.withUnsafeBufferPointer { buf in
            vDSP_sve(buf.baseAddress! + kickStart, 1, &bass, vDSP_Length(kickBins))
        }
        bass = sqrt(max(bass / Float(kickBins), 0)) / Float(fftSize)

        // Smooth level
        let smoothed = runningAverage * 0.85 + bass * 0.15
        runningAverage = runningAverage * 0.98 + bass * 0.02

        let ratio = bass / max(runningAverage, 1e-6)
        let now = CACurrentMediaTime()
        var pulseBoost: Float = 0
        // Slightly snappier onset window so kicks punch the warp.
        if ratio > (1.45 / Config.beatSensitivity) && (now - lastOnsetTime) > 0.10 {
            lastOnsetTime = now
            pulseBoost = min(1.0, (ratio - 1.0) * 0.55 * Config.beatSensitivity)
        }

        lock.lock()
        _level = min(1.0, smoothed * 8.0)
        if pulseBoost > _beatPulse {
            _beatPulse = pulseBoost
        }
        lock.unlock()
    }
}
