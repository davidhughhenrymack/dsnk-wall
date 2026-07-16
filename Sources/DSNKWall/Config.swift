import simd

/// Runtime visual pipeline (selected from the Visual menu).
enum VisualMode: Int {
    case vhs = 0
    case liquidMetal = 1

    var title: String {
        switch self {
        case .vhs: return "VHS"
        case .liquidMetal: return "Liquid Metal"
        }
    }
}

/// All visual / audio tuning constants. Tweak and rebuild.
enum Config {

    // MARK: - Blocks (technicolor macroblocks)

    /// Macroblock size in UV space (larger = bigger blocks).
    static let blockGridScale: Float = 0.05
    /// How often blocks re-randomize, in Hz.
    static let blockReseedRate: Float = 2.2
    /// Fraction of cells that are colored vs near-black (0…1).
    static let blockDensity: Float = 0.78
    /// Color saturation of block palette (0…1+).
    static let blockPaletteSaturation: Float = 1.25

    // MARK: - Shards (dash / glyph overlays)

    /// Probability a shard cell lights up (0…1).
    static let shardDensity: Float = 0.38
    /// Horizontal stretch of shard cells (higher = more dash-like).
    static let shardAspect: Float = 6.0
    /// How often shards flicker, in Hz.
    static let shardFlashRate: Float = 10.0

    // MARK: - Mega-pixel distortion

    /// Quantization cell size of the displacement field (UV).
    static let megaPixelSize: Float = 0.028
    /// Displacement strength (UV units).
    static let megaDistortStrength: Float = 0.02
    /// How fast mega-pixel vectors reseed, in Hz.
    static let megaDistortSpeed: Float = 1.6

    // MARK: - VHS warp

    /// Overall horizontal wrap-warp amount.
    static let vhsWarpAmount: Float = 0.10
    /// Speed of the drifting tracking band.
    static let vhsTrackingBandSpeed: Float = 0.22
    /// Per-scanline random jitter amount.
    static let vhsJitterAmount: Float = 0.012
    /// Head-switch tear strength at bottom of frame.
    static let headSwitchNoise: Float = 0.55

    // MARK: - VHS degradation layer (Shadertoy 7clXDX Image + Buffer D)

    /// Strength of the post VHS degradation layer (0…1.5+, matches shadertoy intensity).
    static let vhsDegradeIntensity: Float = 0.55
    /// How much kick pulse boosts degradation / shear intensity.
    static let vhsDegradeBeatBoost: Float = 0.85
    /// Soft full-frame glow on top of the VHS buffer (0…1).
    static let vhsGlowIntensity: Float = 0.32
    /// Glow radius in UV space (small = tight halo).
    static let vhsGlowRadius: Float = 0.03

    // MARK: - Pixel noise (kept minor)

    /// Overall intensity of structured pixel noise (keep small).
    static let pixelNoiseAmount: Float = 0.16
    /// Ripple frequency along the off-horizontal axis.
    static let rippleFrequency: Float = 40.0
    /// Ripple axis tilt in degrees off horizontal.
    static let rippleAxisTilt: Float = 8.0
    /// Spatial scale of noise intensity blobs.
    static let blobScale: Float = 2.8
    /// Speed of blob undulation.
    static let blobSpeed: Float = 0.3

    // MARK: - Liquid VHS (Leon Denise) — pink / white only

    /// Animation speed multiplier for the liquid field.
    static let flowSpeed: Float = 1.0
    /// Kept for uniform layout / light zone warp (secondary).
    static let warpAmount: Float = 0.35
    static let specularPower: Float = 48.0
    static let specularIntensity: Float = 0.85
    static let fresnelStrength: Float = 0.55
    static let lavaGlowStrength: Float = 1.4

    /// Liquid Metal palette (pink → white only, no blacks). Mapped to lavaTrough / lavaMid / lavaHot.
    static let liquidDark = SIMD3<Float>(1.0, 0.28, 0.68)        // saturated pink (field floor)
    static let liquidPink = SIMD3<Float>(1.0, 0.42, 0.78)        // mid pink
    static let liquidWhite = SIMD3<Float>(1.0, 0.97, 0.99)       // soft white

    // Uniform aliases (Renderer still packs lavaTrough/Mid/Hot).
    static let lavaTrough = liquidDark
    static let lavaMid = liquidPink
    static let lavaHot = liquidWhite

    /// EMA blend toward each new inverted camera frame (higher = less trail / snappier).
    static let cameraEMAAlpha: Float = 0.10
    /// How strongly the inverted camera lightens the under-glass layer (0…1).
    static let cameraLightenStrength: Float = 0.9
    /// Extra beat / level drive for liquid motion and glass (1 = baseline).
    static let liquidSoundDrive: Float = 2.2

    // MARK: - VHS Y2K GIF overlays (from giphy.com/explore/y2k)

    /// Seconds between overlays (min…max random gap after one ends).
    static let gifOverlayMinGap: Float = 2.5
    static let gifOverlayMaxGap: Float = 7.5
    /// How long a sticker stays on screen.
    static let gifOverlayMinDuration: Float = 1.4
    static let gifOverlayMaxDuration: Float = 3.2
    /// Fade in/out duration (seconds).
    static let gifOverlayFade: Float = 0.18
    /// Peak opacity of the sticker.
    static let gifOverlayOpacity: Float = 0.92
    /// Size as fraction of viewport height.
    static let gifOverlayMinScale: Float = 0.22
    static let gifOverlayMaxScale: Float = 0.42

    // MARK: - Global

    /// 0 = chaotic (fast reseeds), 1 = slow/stately evolution.
    static let stability: Float = 0.35

    // MARK: - Logo

    /// Max logo size as fraction of min(width, height).
    static let logoMaxFraction: Float = 0.5
    /// Logo UV distortion (0 = sharp / unperturbed).
    static let distortionStrength: Float = 0
    static let distortionScale: Float = 3.5
    static let distortionSpeed: Float = 0.6
    /// Subtle glow intensity (additive halo).
    static let logoGlowIntensity: Float = 0.22
    /// Glow radius in logo UV space.
    static let logoGlowRadius: Float = 0.04

    // MARK: - Beat

    /// How easily onsets trigger (higher = more sensitive).
    static let beatSensitivity: Float = 1.4
    /// Per-frame exponential decay of beat pulse (closer to 1 = longer).
    static let beatDecay: Float = 0.88
    /// Kick spike multiplier for VHS shear / tracking / head-switch warp.
    static let beatWarpBoost: Float = 5.0
    /// Packed into the `beatDistortionBoost` uniform (VHS warp uses this).
    static let beatDistortionBoost: Float = beatWarpBoost
    /// Brightness spike on beat.
    static let beatBrightnessBoost: Float = 0.45
}
