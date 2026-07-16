import Foundation
import Metal
import MetalKit
import simd

/// Must match Uniforms in Shaders.metal (float4-aligned).
struct GPUUniforms {
    var time: Float
    var beatPulse: Float
    var beatLevel: Float
    /// Unused (kept for ABI layout compatibility with Shaders.metal).
    var visualMode: Float

    var resolution: SIMD2<Float>
    var logoOrigin: SIMD2<Float>   // top-left of logo rect in framebuffer pixels (Y-down)
    var logoSize: SIMD2<Float>     // size in pixels

    var blockGridScale: Float
    var blockReseedRate: Float
    var blockDensity: Float
    var blockPaletteSaturation: Float

    var shardDensity: Float
    var shardAspect: Float
    var shardFlashRate: Float
    var megaPixelSize: Float

    var megaDistortStrength: Float
    var megaDistortSpeed: Float
    var vhsWarpAmount: Float
    var vhsTrackingBandSpeed: Float

    var vhsJitterAmount: Float
    var headSwitchNoise: Float
    var pixelNoiseAmount: Float
    var rippleFrequency: Float

    var rippleAxisTilt: Float
    var blobScale: Float
    var blobSpeed: Float
    /// Unused padding (layout match with Metal Uniforms).
    var flowSpeed: Float

    var warpAmount: Float
    var specularPower: Float
    var specularIntensity: Float
    var fresnelStrength: Float

    var lavaGlowStrength: Float
    var distortionStrength: Float
    var distortionScale: Float
    var distortionSpeed: Float

    var logoGlowIntensity: Float
    var logoGlowRadius: Float
    var beatDistortionBoost: Float
    var beatBrightnessBoost: Float

    // float4 in Metal. Packed VHS extras in components.
    /// .x = logo roll offset, .y = roll velocity, .z = cameraOriginV, .w = vhsLogoBeatWarp
    var lavaTrough: SIMD4<Float>
    /// .x = logoGlowNoise, .y = vhsVideoOpacity, .z = cameraOriginU, .w = vhsVideoOverCamera
    var lavaMid: SIMD4<Float>
    /// .x = logoScanJitter, .y = cameraSquareMargin, .z = cameraTrailStrength, .w = vhsCameraStrength
    /// camera square size fraction is packed in liquidCam.z (main/degrade passes).
    var lavaHot: SIMD4<Float>

    /// .x = degrade intensity, .y = beat boost, .z = glow intensity, .w = glow radius
    var vhsDegrade: SIMD4<Float>

    /// .x = camera EMA alpha, .y = idle decay (EMA pass), .z = cameraSquareSize (main/degrade), .w = gif opacity
    var liquidCam: SIMD4<Float>

    /// VHS GIF sticker: xy origin, zw size (UV Y-down)
    var gifOverlay: SIMD4<Float>
}

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let degradePipelineState: MTLRenderPipelineState
    let emaPipelineState: MTLRenderPipelineState
    let samplerState: MTLSamplerState
    let logoTexture: MTLTexture
    let videoTexture: VideoTexture
    let cameraCapture: CameraCapture
    let gifOverlay: GifOverlay
    let videoPresence: VideoPresence
    let cameraPlacement: CameraPlacement
    let audioBeat: AudioBeat
    let logoRoll: LogoRollPhysics

    private var startTime: CFTimeInterval
    private var viewportSize = SIMD2<Float>(1, 1)
    private var sceneTexture: MTLTexture?
    private var emaTextures: [MTLTexture?] = [nil, nil]
    private var emaIndex = 0
    private var emaFrameCounter = 0
    private let fallbackCamTexture: MTLTexture

    init?(metalView: MTKView, audioBeat: AudioBeat) {
        guard let device = metalView.device ?? MTLCreateSystemDefaultDevice() else {
            fputs("Renderer: no Metal device\n", stderr)
            return nil
        }
        self.device = device
        metalView.device = device
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        // We size the drawable ourselves so fullscreen Retina doesn't go 5K native.
        metalView.autoResizeDrawable = false
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        Self.syncDrawableSize(metalView)

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.audioBeat = audioBeat

        guard let logo = LogoTexture.make(device: device) else {
            fputs("Renderer: failed to create logo texture\n", stderr)
            return nil
        }
        self.logoTexture = logo

        guard let video = VideoTexture(device: device) else {
            fputs("Renderer: failed to load VHS test-screen video\n", stderr)
            return nil
        }
        self.videoTexture = video

        guard let camera = CameraCapture(device: device) else {
            fputs("Renderer: failed to create camera capture\n", stderr)
            return nil
        }
        self.cameraCapture = camera

        guard let gifs = GifOverlay(device: device) else {
            fputs("Renderer: failed to create GIF overlay\n", stderr)
            return nil
        }
        self.gifOverlay = gifs
        self.videoPresence = VideoPresence()
        self.cameraPlacement = CameraPlacement()
        self.logoRoll = LogoRollPhysics()

        guard let fallbackCam = Self.makeSolidTexture(device: device) else { return nil }
        self.fallbackCamTexture = fallbackCam

        guard let library = Self.makeLibrary(device: device) else {
            fputs("Renderer: failed to compile Metal shaders\n", stderr)
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "vertex_main"),
              let fragmentFn = library.makeFunction(name: "fragment_main"),
              let degradeFn = library.makeFunction(name: "fragment_vhs_degrade"),
              let emaFn = library.makeFunction(name: "fragment_camera_ema") else {
            fputs("Renderer: missing shader functions\n", stderr)
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = metalView.colorPixelFormat

        let degradeDesc = MTLRenderPipelineDescriptor()
        degradeDesc.vertexFunction = vertexFn
        degradeDesc.fragmentFunction = degradeFn
        degradeDesc.colorAttachments[0].pixelFormat = metalView.colorPixelFormat

        let emaDesc = MTLRenderPipelineDescriptor()
        emaDesc.vertexFunction = vertexFn
        emaDesc.fragmentFunction = emaFn
        emaDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            self.degradePipelineState = try device.makeRenderPipelineState(descriptor: degradeDesc)
            self.emaPipelineState = try device.makeRenderPipelineState(descriptor: emaDesc)
        } catch {
            fputs("Renderer: pipeline error: \(error)\n", stderr)
            return nil
        }

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.mipFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sampDesc) else { return nil }
        self.samplerState = sampler

        self.startTime = CACurrentMediaTime()
        // MTKView may not call drawableSizeWillChange until a resize — seed from current size.
        let ds = metalView.drawableSize
        self.viewportSize = SIMD2<Float>(Float(max(ds.width, 1)), Float(max(ds.height, 1)))
        super.init()
        metalView.delegate = self
        // Apply again after delegate set (drawableSize can still be zero during init).
        if metalView.drawableSize.width > 1 {
            self.viewportSize = SIMD2<Float>(
                Float(metalView.drawableSize.width),
                Float(metalView.drawableSize.height)
            )
        }
        ensureSceneTexture(width: Int(viewportSize.x), height: Int(viewportSize.y))
        ensureEMATextures(width: Int(viewportSize.x), height: Int(viewportSize.y))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportSize = SIMD2<Float>(Float(max(size.width, 1)), Float(max(size.height, 1)))
        ensureSceneTexture(width: Int(viewportSize.x), height: Int(viewportSize.y))
        ensureEMATextures(width: Int(viewportSize.x), height: Int(viewportSize.y))
    }

    /// Cap render resolution so expensive per-pixel passes stay interactive fullscreen.
    static func syncDrawableSize(_ view: MTKView) {
        let scale: CGFloat
        if let window = view.window {
            scale = window.backingScaleFactor
        } else if let layer = view.layer {
            scale = layer.contentsScale
        } else {
            scale = 2
        }
        var w = max(view.bounds.width, 1) * scale
        var h = max(view.bounds.height, 1) * scale
        let longEdge = max(w, h)
        let maxEdge = Config.maxRenderLongEdge
        if longEdge > maxEdge {
            let s = maxEdge / longEdge
            w *= s
            h *= s
        }
        let newSize = CGSize(width: max(1, floor(w)), height: max(1, floor(h)))
        if view.drawableSize != newSize {
            view.drawableSize = newSize
        }
    }

    private func ensureSceneTexture(width: Int, height: Int) {
        let w = max(width, 1)
        let h = max(height, 1)
        if let t = sceneTexture, t.width == w, t.height == h { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        sceneTexture = device.makeTexture(descriptor: desc)
    }

    private func ensureEMATextures(width: Int, height: Int) {
        let w = max(width, 1)
        let h = max(height, 1)
        if let t0 = emaTextures[0], t0.width == w, t0.height == h { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        emaTextures[0] = device.makeTexture(descriptor: desc)
        emaTextures[1] = device.makeTexture(descriptor: desc)
        emaIndex = 0
        // Clear history so the first EMA frames aren't uninitialized GPU memory.
        if let q = commandQueue.makeCommandBuffer() {
            for tex in emaTextures {
                guard let tex else { continue }
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = tex
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].storeAction = .store
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                if let enc = q.makeRenderCommandEncoder(descriptor: rpd) {
                    enc.endEncoding()
                }
            }
            q.commit()
        }
    }

    private static func makeSolidTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false
        )
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var px: [UInt8] = [0, 0, 0, 255]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return tex
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer() else { return }

        audioBeat.tick()
        videoTexture.update()

        // Keep drawable capped (bounds change on green-button fullscreen).
        Self.syncDrawableSize(view)

        let ds = view.drawableSize
        if ds.width > 1, ds.height > 1 {
            viewportSize = SIMD2<Float>(Float(ds.width), Float(ds.height))
            ensureSceneTexture(width: Int(ds.width), height: Int(ds.height))
            ensureEMATextures(width: Int(ds.width), height: Int(ds.height))
        }

        let now = CACurrentMediaTime()
        let time = Float(now - startTime)
        let w = viewportSize.x
        let h = viewportSize.y
        gifOverlay.update(time: now, viewport: viewportSize, beatPulse: audioBeat.beatPulse)
        videoPresence.update(time: now, beatPulse: audioBeat.beatPulse)
        cameraPlacement.update(time: now, viewport: viewportSize)
        let roll = logoRoll.update(now: now, beatPulse: audioBeat.beatPulse)
        // Logo rect in framebuffer pixels, origin = top-left (Metal Y-down).
        let side = Config.logoMaxFraction * min(w, h)
        let logoOrigin = SIMD2<Float>((w - side) * 0.5, (h - side) * 0.5)
        let logoSize = SIMD2<Float>(side, side)

        var uniforms = GPUUniforms(
            time: time,
            beatPulse: audioBeat.beatPulse,
            beatLevel: audioBeat.level,
            visualMode: 0,
            resolution: viewportSize,
            logoOrigin: logoOrigin,
            logoSize: logoSize,
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
            lavaTrough: SIMD4<Float>(
                roll.offset,
                roll.velocity,
                cameraPlacement.originUV.y,
                Config.vhsLogoBeatWarp
            ),
            lavaMid: SIMD4<Float>(
                Config.logoGlowNoise,
                videoPresence.opacity,
                cameraPlacement.originUV.x,
                Config.vhsVideoOverCamera
            ),
            lavaHot: SIMD4<Float>(
                Config.logoScanJitter,
                Config.cameraSquareMargin,
                Config.cameraTrailStrength,
                Config.vhsCameraStrength * cameraPlacement.opacity
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
                cameraPlacement.sizeFrac,
                gifOverlay.currentOpacity
            ),
            gifOverlay: gifOverlay.rect
        )

        let camLive = cameraCapture.currentTexture()
        let camEMARead: MTLTexture
        if let prev = emaTextures[emaIndex],
           let next = emaTextures[1 - emaIndex] {
            // Stride: stamp only while camera is present; otherwise just fade the trail.
            let camOn = cameraPlacement.opacity > 0.02
            let stride = camOn && (emaFrameCounter % Config.cameraEMAStride) == 0
            emaFrameCounter &+= 1

            var emaUniforms = uniforms
            // Trail pass packs: .x stamp alpha, .y idle decay, .w stride flag
            emaUniforms.liquidCam = SIMD4<Float>(
                Config.cameraEMAAlpha,
                Config.cameraEMAIdleDecay,
                cameraPlacement.sizeFrac,
                stride ? 1 : 0
            )

            let emaPass = MTLRenderPassDescriptor()
            emaPass.colorAttachments[0].texture = next
            emaPass.colorAttachments[0].loadAction = .dontCare
            emaPass.colorAttachments[0].storeAction = .store
            if let encEMA = cmd.makeRenderCommandEncoder(descriptor: emaPass) {
                encEMA.setRenderPipelineState(emaPipelineState)
                encEMA.setFragmentBytes(&emaUniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
                encEMA.setFragmentTexture(prev, index: 0)
                encEMA.setFragmentSamplerState(samplerState, index: 0)
                encEMA.setFragmentTexture(camLive, index: 1)
                encEMA.setFragmentSamplerState(samplerState, index: 1)
                encEMA.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encEMA.endEncoding()
            }
            emaIndex = 1 - emaIndex
            camEMARead = next
        } else {
            camEMARead = fallbackCamTexture
        }

        guard let scene = sceneTexture else { return }

        // Pass 1: warped VHS video + GIFs (no camera, no logo) → offscreen
        var sceneUniforms = uniforms
        sceneUniforms.logoSize = .zero
        sceneUniforms.logoOrigin = .zero

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = scene
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let enc1 = cmd.makeRenderCommandEncoder(descriptor: scenePass) else { return }
        enc1.setRenderPipelineState(pipelineState)
        enc1.setFragmentBytes(&sceneUniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
        enc1.setFragmentTexture(logoTexture, index: 0)
        enc1.setFragmentSamplerState(samplerState, index: 0)
        enc1.setFragmentTexture(videoTexture.texture, index: 1)
        enc1.setFragmentSamplerState(samplerState, index: 1)
        enc1.setFragmentTexture(gifOverlay.texture, index: 2)
        enc1.setFragmentSamplerState(samplerState, index: 2)
        enc1.setFragmentTexture(camEMARead, index: 3) // unused in pass 1; camera composites after warp
        enc1.setFragmentSamplerState(samplerState, index: 3)
        enc1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc1.endEncoding()

        // Pass 2: VHS degrade → unwarped camera under → DSNK logo on top → drawable
        guard let enc2 = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc2.setRenderPipelineState(degradePipelineState)
        enc2.setFragmentBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
        enc2.setFragmentTexture(scene, index: 0)
        enc2.setFragmentSamplerState(samplerState, index: 0)
        enc2.setFragmentTexture(logoTexture, index: 1)
        enc2.setFragmentSamplerState(samplerState, index: 1)
        enc2.setFragmentTexture(camLive, index: 2)
        enc2.setFragmentSamplerState(samplerState, index: 2)
        enc2.setFragmentTexture(camEMARead, index: 3)
        enc2.setFragmentSamplerState(samplerState, index: 3)
        enc2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc2.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: - Shader loading

    private static func makeLibrary(device: MTLDevice) -> MTLLibrary? {
        // Prefer SPM resource bundle, then app Resources, then source-relative path.
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
                fputs("Renderer: Metal compile error from \(url.path):\n\(error)\n", stderr)
            }
        }
        return nil
    }
}
