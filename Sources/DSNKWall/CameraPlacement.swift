import Foundation
import QuartzCore
import simd

/// Camera square: ~25% on-time with long gaps; repositions only when reappearing.
final class CameraPlacement {
    /// Top-left of the camera square in UV (Y-down).
    private(set) var originUV = SIMD2<Float>(0.2, 0.2)
    /// Side length as fraction of min(viewport) — mirrored to GPU.
    private(set) var sizeFrac: Float = 0.5
    /// 0…1 fade-aware presence for the camera plate.
    private(set) var opacity: Float = 0

    private var nextShowAt: CFTimeInterval = 0
    private var hideAt: CFTimeInterval = 0
    private var showStart: CFTimeInterval = 0
    private var active = false
    private var viewport = SIMD2<Float>(1, 1)

    init() {
        sizeFrac = Config.cameraSquareSize
        // Start gone; first appear after a longer off-phase break.
        nextShowAt = CACurrentMediaTime() + Double.random(in: 4.0...10.0)
    }

    func update(time now: CFTimeInterval, viewport: SIMD2<Float>) {
        if viewport.x > 1, viewport.y > 1 {
            self.viewport = viewport
        }

        if active {
            if now >= hideAt {
                active = false
                opacity = 0
                // Long break so on-time ≈ 1/4 of the cycle.
                nextShowAt = now + Double.random(
                    in: Double(Config.cameraPresenceMinGap)...Double(Config.cameraPresenceMaxGap)
                )
                return
            }

            let showDur = hideAt - showStart
            let local = now - showStart
            let fade = Double(Config.cameraPresenceFade)
            var o = 1.0
            if local < fade { o = local / max(fade, 0.001) }
            else if local > showDur - fade { o = (hideAt - now) / max(fade, 0.001) }
            opacity = Float(max(0, min(1, o)))
            return
        }

        opacity = 0
        guard now >= nextShowAt else { return }

        active = true
        showStart = now
        hideAt = now + Double.random(
            in: Double(Config.cameraPresenceMinDuration)...Double(Config.cameraPresenceMaxDuration)
        )
        relocate()
        opacity = 0
    }

    /// Pick a new inset-square origin (only called on appear).
    private func relocate() {
        let margin = Config.cameraSquareMargin
        let sideFrac = Config.cameraSquareSize
        sizeFrac = sideFrac

        let minSide = min(viewport.x, viewport.y)
        let inset = margin * minSide
        let side = sideFrac * minSide

        let x0 = inset
        let y0 = inset
        let x1 = max(viewport.x - inset - side, x0)
        let y1 = max(viewport.y - inset - side, y0)

        let ox = Float.random(in: x0...x1)
        let oy = Float.random(in: y0...y1)
        originUV = SIMD2<Float>(ox / viewport.x, oy / viewport.y)
    }
}
