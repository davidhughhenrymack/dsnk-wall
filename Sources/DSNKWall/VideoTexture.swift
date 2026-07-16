import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Looping VHS test-screen video decoded into a Metal texture each frame.
final class VideoTexture {
    private let device: MTLDevice
    private let player: AVPlayer
    private let videoOutput: AVPlayerItemVideoOutput
    private var textureCache: CVMetalTextureCache?
    /// Retains the CVMetalTexture so the underlying MTLTexture stays valid.
    private var cvTexture: CVMetalTexture?
    private let fallbackTexture: MTLTexture
    private(set) var texture: MTLTexture
    private var endObserver: NSObjectProtocol?

    static let resourceName = "vhs-test-screen"
    static let resourceExtension = "mp4"

    init?(device: MTLDevice) {
        self.device = device

        guard let url = Self.resolveURL() else {
            fputs("VideoTexture: missing \(Self.resourceName).\(Self.resourceExtension)\n", stderr)
            return nil
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        item.add(output)

        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.isMuted = true
        avPlayer.actionAtItemEnd = .none

        var cache: CVMetalTextureCache?
        let cacheResult = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard cacheResult == kCVReturnSuccess, let cache else {
            fputs("VideoTexture: CVMetalTextureCacheCreate failed (\(cacheResult))\n", stderr)
            return nil
        }

        guard let fallback = Self.makeSolidTexture(device: device, color: (0.05, 0.05, 0.08)) else {
            return nil
        }

        self.player = avPlayer
        self.videoOutput = output
        self.textureCache = cache
        self.fallbackTexture = fallback
        self.texture = fallback

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }

        avPlayer.play()
        // Prime first frame for dump / first draw
        copyFrame(at: 0.05)
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    /// Pull the latest decoded frame into `texture` (no-op if nothing new).
    func update() {
        let host = CACurrentMediaTime()
        let itemTime = videoOutput.itemTime(forHostTime: host)
        guard itemTime.isValid, itemTime.isNumeric else { return }
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var displayTime = CMTime.zero
        guard let pixelBuffer = videoOutput.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &displayTime
        ) else { return }
        ingest(pixelBuffer)
    }

    /// Seek and grab a frame (for `--dump-frames`).
    func copyFrame(at seconds: Double) {
        if let url = Self.resolveURL() {
            let asset = AVURLAsset(url: url)
            let duration = asset.duration.seconds
            let t: Double
            if duration.isFinite, duration > 0 {
                var x = seconds.truncatingRemainder(dividingBy: duration)
                if x < 0 { x += duration }
                t = x
            } else {
                t = max(0, seconds)
            }
            let cm = CMTime(seconds: t, preferredTimescale: 600)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            if let cg = try? gen.copyCGImage(at: cm, actualTime: nil) {
                ingest(cgImage: cg)
                return
            }
        }

        let cm = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
            if videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                ingest(pb)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func ingest(_ pixelBuffer: CVPixelBuffer) {
        guard let cache = textureCache else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex,
              let mtl = CVMetalTextureGetTexture(cvTex) else { return }
        self.cvTexture = cvTex
        texture = mtl
    }

    private func ingest(cgImage: CGImage) {
        let w = cgImage.width
        let h = cgImage.height
        let bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // Bitmap row 0 = top (matches Metal UV / CVPixelBuffer video frames).
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        tex.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: bpr
        )
        cvTexture = nil
        texture = tex
    }

    private static func makeSolidTexture(device: MTLDevice, color: (Float, Float, Float)) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        let b = UInt8(max(0, min(255, Int(color.2 * 255))))
        let g = UInt8(max(0, min(255, Int(color.1 * 255))))
        let r = UInt8(max(0, min(255, Int(color.0 * 255))))
        var px: [UInt8] = [b, g, r, 255]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return tex
    }

    static func resolveURL() -> URL? {
        let name = resourceName
        let ext = resourceExtension
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Sources/DSNKWall
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // project root
        let candidates: [URL?] = [
            Bundle.module.url(forResource: name, withExtension: ext),
            Bundle.main.url(forResource: name, withExtension: ext),
            Bundle.main.resourceURL?.appendingPathComponent("\(name).\(ext)"),
            projectRoot.appendingPathComponent("assets/\(name).\(ext)")
        ]
        for url in candidates {
            if let url, FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
