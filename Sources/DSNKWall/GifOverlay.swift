import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore

/// Occasional animated Y2K GIF stickers for VHS mode.
final class GifOverlay {
    struct Clip {
        let frames: [MTLTexture]
        let delays: [Double] // seconds per frame
        let aspect: Float    // width / height
    }

    private let device: MTLDevice
    private let clips: [Clip]
    private let emptyTexture: MTLTexture

    private var nextShowAt: CFTimeInterval = 0
    private var hideAt: CFTimeInterval = 0
    private var activeClip: Clip?
    private var clipStart: CFTimeInterval = 0
    private var beatsSeen = 0
    private var prevBeatPulse: Float = 0
    private var originUV = SIMD2<Float>(0.1, 0.1)
    private var sizeUV = SIMD2<Float>(0.3, 0.3)
    private var opacity: Float = 0

    /// Current frame texture (1×1 clear when inactive).
    private(set) var texture: MTLTexture
    /// xy = top-left UV (Y-down), zw = size in UV.
    private(set) var rect = SIMD4<Float>(0, 0, 0, 0)
    private(set) var currentOpacity: Float = 0

    init?(device: MTLDevice) {
        self.device = device
        guard let empty = Self.makeEmpty(device: device) else { return nil }
        self.emptyTexture = empty
        self.texture = empty

        let urls = Self.resolveGifURLs()
        var loaded: [Clip] = []
        for url in urls {
            if let clip = Self.loadClip(url: url, device: device) {
                loaded.append(clip)
            }
        }
        self.clips = loaded
        if loaded.isEmpty {
            fputs("GifOverlay: no GIFs found in assets/gifs\n", stderr)
        } else {
            fputs("GifOverlay: loaded \(loaded.count) Y2K GIFs\n", stderr)
        }
        // Stagger first appearance
        nextShowAt = CACurrentMediaTime() + Double.random(in: 1.5...4.0)
    }

    func update(time now: CFTimeInterval, viewport: SIMD2<Float>, beatPulse: Float) {
        guard !clips.isEmpty else {
            currentOpacity = 0
            texture = emptyTexture
            rect = .zero
            return
        }

        if let clip = activeClip {
            // Count kick onsets toward the 16-beat lifetime.
            let thresh = Config.gifOverlayBeatThreshold
            if beatPulse > thresh && prevBeatPulse <= thresh {
                beatsSeen += 1
                if beatsSeen >= Config.gifOverlayBeatCount {
                    let fade = Double(Config.gifOverlayFade)
                    hideAt = min(hideAt, now + fade)
                }
            }
            prevBeatPulse = beatPulse

            if now >= hideAt {
                activeClip = nil
                opacity = 0
                currentOpacity = 0
                texture = emptyTexture
                rect = .zero
                beatsSeen = 0
                prevBeatPulse = 0
                nextShowAt = now + Double.random(in: Double(Config.gifOverlayMinGap)...Double(Config.gifOverlayMaxGap))
                return
            }
            // Fade in/out
            let showDur = hideAt - clipStart
            let local = now - clipStart
            let fade = Double(Config.gifOverlayFade)
            var o = 1.0
            if local < fade { o = local / max(fade, 0.001) }
            else if local > showDur - fade { o = (hideAt - now) / max(fade, 0.001) }
            // Occasional flicker
            if Int(now * 18.0) % 17 == 0 { o *= 0.35 }
            opacity = Float(max(0, min(1, o))) * Config.gifOverlayOpacity
            currentOpacity = opacity
            texture = frameTexture(for: clip, at: now)
            rect = SIMD4<Float>(originUV.x, originUV.y, sizeUV.x, sizeUV.y)
            return
        }

        currentOpacity = 0
        texture = emptyTexture
        rect = .zero
        prevBeatPulse = beatPulse
        guard now >= nextShowAt else { return }

        // Start a new sticker — up to 16 beats or 10s, whichever comes first.
        let clip = clips.randomElement()!
        activeClip = clip
        clipStart = now
        hideAt = now + Double(Config.gifOverlayMaxDuration)
        beatsSeen = 0
        prevBeatPulse = beatPulse

        let scale = Float.random(in: Config.gifOverlayMinScale...Config.gifOverlayMaxScale)
        let hUV = scale
        let wUV = scale * clip.aspect * (viewport.y / max(viewport.x, 1))
        // Keep on screen with margin
        let maxX = max(0.02, 1.0 - wUV - 0.02)
        let maxY = max(0.02, 1.0 - hUV - 0.02)
        originUV = SIMD2<Float>(Float.random(in: 0.02...maxX), Float.random(in: 0.02...maxY))
        sizeUV = SIMD2<Float>(wUV, hUV)
        opacity = 0
        currentOpacity = 0
        texture = clip.frames[0]
        rect = SIMD4<Float>(originUV.x, originUV.y, sizeUV.x, sizeUV.y)
    }

    private func frameTexture(for clip: Clip, at now: CFTimeInterval) -> MTLTexture {
        let elapsed = now - clipStart
        var t = elapsed.truncatingRemainder(dividingBy: max(clip.delays.reduce(0, +), 0.001))
        for (i, d) in clip.delays.enumerated() {
            if t <= d { return clip.frames[i] }
            t -= d
        }
        return clip.frames.last ?? emptyTexture
    }

    // MARK: - Loading

    private static func resolveGifURLs() -> [URL] {
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("gifs"),
            Bundle.module.resourceURL?.appendingPathComponent("gifs"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("assets/gifs")
        ].compactMap { $0 }

        for dir in candidates {
            if let files = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil
            ) {
                let gifs = files.filter { $0.pathExtension.lowercased() == "gif" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                if !gifs.isEmpty { return gifs }
            }
        }
        return []
    }

    private static func loadClip(url: URL, device: MTLDevice) -> Clip? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }

        var frames: [MTLTexture] = []
        var delays: [Double] = []
        let maxFrames = 48 // cap memory for large GIFs

        for i in 0..<min(count, maxFrames) {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil),
                  let tex = makeTexture(from: cg, device: device) else { continue }
            frames.append(tex)
            delays.append(frameDelay(source: src, index: i))
        }
        guard !frames.isEmpty else { return nil }

        let w = Float(frames[0].width)
        let h = Float(max(frames[0].height, 1))
        return Clip(frames: frames, delays: delays, aspect: w / h)
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let unclamped = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif?[kCGImagePropertyGIFDelayTime] as? Double
        let d = unclamped ?? clamped ?? 0.1
        return max(d, 0.04)
    }

    private static func makeTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let w = image.width
        let h = image.height
        let bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Bitmap row 0 = top (matches Metal UV)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: bpr
        )
        return tex
    }

    private static func makeEmpty(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var px: [UInt8] = [0, 0, 0, 0]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return tex
    }
}
