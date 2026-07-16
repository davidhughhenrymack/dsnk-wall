import Foundation
import Metal
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Headless offscreen renderer that writes PNG frames for A/B against reference.
enum FrameDump {

    /// When true, fragment still runs full shader but we also write a logo-mask debug PNG.
    static var dumpLogoMask = false

    static func run(
        outputDir: URL,
        width: Int = 1280,
        height: Int = 720,
        count: Int = 4,
        hideLogo: Bool = true
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("FrameDump: no Metal device\n", stderr)
            exit(1)
        }
        guard let queue = device.makeCommandQueue() else { exit(1) }
        guard let library = makeLibrary(device: device) else {
            fputs("FrameDump: shader compile failed\n", stderr)
            exit(1)
        }
        guard let vfn = library.makeFunction(name: "vertex_main"),
              let ffn = library.makeFunction(name: "fragment_main"),
              let dfn = library.makeFunction(name: "fragment_vhs_degrade") else { exit(1) }

        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction = vfn
        pdesc.fragmentFunction = ffn
        pdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let ddesc = MTLRenderPipelineDescriptor()
        ddesc.vertexFunction = vfn
        ddesc.fragmentFunction = dfn
        ddesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline: MTLRenderPipelineState
        let degradePipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pdesc)
            degradePipeline = try device.makeRenderPipelineState(descriptor: ddesc)
        } catch {
            fputs("FrameDump: pipeline \(error)\n", stderr)
            exit(1)
        }

        guard let logo = LogoTexture.make(device: device) else {
            fputs("FrameDump: logo failed\n", stderr)
            exit(1)
        }
        guard let video = VideoTexture(device: device) else {
            fputs("FrameDump: video failed\n", stderr)
            exit(1)
        }

        // Write the raw logo mask for orientation checks (independent of the glitch field).
        writeMaskPNG(texture: logo, to: outputDir.appendingPathComponent("logo-mask.png"))
        fputs("wrote \(outputDir.appendingPathComponent("logo-mask.png").path)\n", stderr)

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.mipFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sampDesc) else { exit(1) }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: texDesc),
              let scene = device.makeTexture(descriptor: texDesc) else { exit(1) }

        // 1×1 black stand-in for camera EMA (no live camera in dump mode).
        let camDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
        )
        camDesc.usage = [.shaderRead]
        guard let camEMA = device.makeTexture(descriptor: camDesc) else { exit(1) }
        var black: [UInt8] = [0, 0, 0, 255]
        camEMA.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &black, bytesPerRow: 4)

        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let times: [Float] = (0..<count).map { Float($0) * 0.37 + 0.15 }

        for (i, time) in times.enumerated() {
            video.copyFrame(at: Double(time))

            var uniforms = makeUniforms(
                time: time,
                width: Float(width),
                height: Float(height),
                hideLogo: hideLogo
            )

            guard let cmd = queue.makeCommandBuffer() else { continue }

            // Pass 1: scene without logo (GIFs would bind on tex2; dump uses empty cam stand-in)
            var sceneUniforms = uniforms
            sceneUniforms.logoSize = .zero
            sceneUniforms.logoOrigin = .zero

            let scenePass = MTLRenderPassDescriptor()
            scenePass.colorAttachments[0].texture = scene
            scenePass.colorAttachments[0].loadAction = .clear
            scenePass.colorAttachments[0].storeAction = .store
            scenePass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            guard let enc1 = cmd.makeRenderCommandEncoder(descriptor: scenePass) else { continue }
            enc1.setRenderPipelineState(pipeline)
            enc1.setFragmentBytes(&sceneUniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
            enc1.setFragmentTexture(logo, index: 0)
            enc1.setFragmentSamplerState(sampler, index: 0)
            enc1.setFragmentTexture(video.texture, index: 1)
            enc1.setFragmentSamplerState(sampler, index: 1)
            enc1.setFragmentTexture(camEMA, index: 2) // unused gif stand-in
            enc1.setFragmentSamplerState(sampler, index: 2)
            enc1.setFragmentTexture(camEMA, index: 3)
            enc1.setFragmentSamplerState(sampler, index: 3)
            enc1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc1.endEncoding()

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            guard let enc2 = cmd.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            enc2.setRenderPipelineState(degradePipeline)
            enc2.setFragmentBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
            enc2.setFragmentTexture(scene, index: 0)
            enc2.setFragmentSamplerState(sampler, index: 0)
            enc2.setFragmentTexture(logo, index: 1)
            enc2.setFragmentSamplerState(sampler, index: 1)
            enc2.setFragmentTexture(camEMA, index: 2) // live stand-in for dump
            enc2.setFragmentSamplerState(sampler, index: 2)
            enc2.setFragmentTexture(camEMA, index: 3) // trail
            enc2.setFragmentSamplerState(sampler, index: 3)
            enc2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc2.endEncoding()

            cmd.commit()
            cmd.waitUntilCompleted()

            let url = outputDir.appendingPathComponent(String(format: "frame_%02d.png", i))
            writePNG(texture: target, to: url)
            fputs("wrote \(url.path)\n", stderr)
        }
    }

    private static func makeUniforms(
        time: Float,
        width: Float,
        height: Float,
        hideLogo: Bool
    ) -> GPUUniforms {
        let side: Float = hideLogo ? 0 : Config.logoMaxFraction * min(width, height)
        let logoOrigin = SIMD2<Float>((width - side) * 0.5, (height - side) * 0.5)
        return GPUUniforms(
            time: time,
            beatPulse: 0,
            beatLevel: 0,
            visualMode: 0,
            resolution: SIMD2<Float>(width, height),
            logoOrigin: logoOrigin,
            logoSize: SIMD2<Float>(side, side),
            blockGridScale: Config.blockGridScale,
            blockReseedRate: Config.blockReseedRate,
            blockDensity: Config.blockDensity,
            blockPaletteSaturation: Config.blockPaletteSaturation,
            shardDensity: Config.shardDensity,
            shardAspect: Config.shardAspect,
            shardFlashRate: Config.shardFlashRate,
            megaPixelSize: Config.megaPixelSize,
            megaDistortStrength: Config.megaDistortStrength,
            megaDistortSpeed: Config.megaDistortSpeed,
            vhsWarpAmount: Config.vhsWarpAmount,
            vhsTrackingBandSpeed: Config.vhsTrackingBandSpeed,
            vhsJitterAmount: Config.vhsJitterAmount,
            headSwitchNoise: Config.headSwitchNoise,
            pixelNoiseAmount: Config.pixelNoiseAmount,
            rippleFrequency: Config.rippleFrequency,
            rippleAxisTilt: Config.rippleAxisTilt,
            blobScale: Config.blobScale,
            blobSpeed: Config.blobSpeed,
            flowSpeed: 0,
            warpAmount: 0,
            specularPower: 0,
            specularIntensity: 0,
            fresnelStrength: 0,
            lavaGlowStrength: 0,
            distortionStrength: Config.logoZoomBlur,
            distortionScale: Config.logoBeatZoom,
            distortionSpeed: Config.logoRollMotionBlur,
            logoGlowIntensity: Config.logoGlowIntensity,
            logoGlowRadius: Config.logoGlowRadius,
            beatDistortionBoost: Config.beatDistortionBoost,
            beatBrightnessBoost: Config.beatBrightnessBoost,
            lavaTrough: SIMD4<Float>(0, 0, 0.25, Config.vhsLogoBeatWarp),
            lavaMid: SIMD4<Float>(Config.logoGlowNoise, 1, 0.25, Config.vhsVideoOverCamera),
            lavaHot: SIMD4<Float>(
                Config.logoScanJitter,
                Config.cameraSquareMargin,
                Config.cameraTrailStrength,
                Config.vhsCameraStrength
            ),
            vhsDegrade: SIMD4<Float>(
                Config.vhsDegradeIntensity,
                Config.vhsDegradeBeatBoost,
                Config.vhsGlowIntensity,
                Config.vhsGlowRadius
            ),
            liquidCam: SIMD4<Float>(
                Config.cameraEMAAlpha,
                0,
                Config.cameraSquareSize,
                0
            ),
            gifOverlay: SIMD4<Float>.zero
        )
    }

    private static func writeMaskPNG(texture: MTLTexture, to url: URL) {
        let w = texture.width
        let h = texture.height
        var r8 = [UInt8](repeating: 0, count: w * h)
        texture.getBytes(&r8, bytesPerRow: w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = r8[i]
            rgba[i * 4 + 0] = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
            rgba[i * 4 + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func writePNG(texture: MTLTexture, to url: URL) {
        let w = texture.width
        let h = texture.height
        let bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        texture.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        // BGRA → RGBA
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let b = bytes[i], r = bytes[i + 2]
            bytes[i] = r
            bytes[i + 2] = b
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage() else {
            fputs("FrameDump: CGContext failed\n", stderr)
            return
        }

        // Flip vertically — Metal texture top row is first; CG wants bottom-up for some writers,
        // but CGImageDestination typically expects top-down from makeImage of a top-down buffer.
        // Our getBytes row 0 = Metal top = screen top. Write as-is.
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func makeLibrary(device: MTLDevice) -> MTLLibrary? {
        let candidates: [URL?] = [
            Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
            Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
            Bundle.main.resourceURL?.appendingPathComponent("Shaders.metal"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/Shaders.metal")
        ]
        for url in candidates {
            guard let url, let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            do {
                return try device.makeLibrary(source: source, options: nil)
            } catch {
                fputs("FrameDump: Metal error \(url.path):\n\(error)\n", stderr)
            }
        }
        return nil
    }
}
