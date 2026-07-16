import CoreGraphics
import simd

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
    static let vhsWarpAmount: Float = 0.14
    /// Speed of the drifting tracking band.
    static let vhsTrackingBandSpeed: Float = 0.28
    /// Per-scanline random jitter amount.
    static let vhsJitterAmount: Float = 0.016
    /// Head-switch tear strength at bottom of frame.
    static let headSwitchNoise: Float = 0.7

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

    // MARK: - Camera (live + strided decay trail underlay)

    /// How hard a strided sample stamps into the decay trail (lower = gentler ghosts).
    static let cameraEMAAlpha: Float = 0.14
    /// Only stamp a new camera sample into the trail every N frames.
    static let cameraEMAStride: Int = 10
    /// Per-frame multiply on trail history when not striding (lower = faster fade / less decay linger).
    static let cameraEMAIdleDecay: Float = 0.78
    /// Live camera underlay strength (0…1+). Composited after warp.
    static let vhsCameraStrength: Float = 0.55
    /// How much warped VHS video covers the (unwarped) camera (0 = only cam, 1 = only video).
    static let vhsVideoOverCamera: Float = 0.78
    /// Gentle overlay of the strided decay trail relative to the live frame (0…1).
    static let cameraTrailStrength: Float = 0.18
    /// Minimum margin on every side for the square camera crop (0…0.49).
    static let cameraSquareMargin: Float = 0.20
    /// Camera square side as a fraction of min(width, height); < (1−2×margin) so it can move.
    static let cameraSquareSize: Float = 0.50
    /// How long the camera stays visible when it appears (seconds).
    static let cameraPresenceMinDuration: Float = 3.5
    static let cameraPresenceMaxDuration: Float = 6.5
    /// Long gaps between appearances — with the durations above, on-time ≈ 1/4 of the cycle.
    static let cameraPresenceMinGap: Float = 12.0
    static let cameraPresenceMaxGap: Float = 22.0
    /// Fade in/out duration (seconds).
    static let cameraPresenceFade: Float = 0.4

    // MARK: - VHS Y2K GIF overlays (from giphy.com/explore/y2k)

    /// Seconds between overlays (min…max random gap after one ends).
    static let gifOverlayMinGap: Float = 2.5
    static let gifOverlayMaxGap: Float = 7.5
    /// Sticker lifetime: end after this many kick onsets, or max duration — whichever first.
    static let gifOverlayBeatCount: Int = 16
    /// Hard cap on how long a sticker stays on screen (seconds).
    static let gifOverlayMaxDuration: Float = 10.0
    /// Fade in/out duration (seconds).
    static let gifOverlayFade: Float = 0.25
    /// Peak opacity of the sticker.
    static let gifOverlayOpacity: Float = 0.92
    /// Size as fraction of viewport height.
    static let gifOverlayMinScale: Float = 0.22
    static let gifOverlayMaxScale: Float = 0.42
    /// Onset threshold for counting a beat against GIF lifetime.
    static let gifOverlayBeatThreshold: Float = 0.32

    // MARK: - VHS video presence (GIF-like schedule, ~2× on-time, independent phase/RNG)

    /// Seconds between video appearances (own random draws; slightly wider than GIFs).
    static let videoPresenceMinGap: Float = 3.0
    static let videoPresenceMaxGap: Float = 9.0
    /// End after this many kick onsets, or max duration — whichever first (2× GIF).
    static let videoPresenceBeatCount: Int = 32
    /// Hard cap on how long the MP4 stays visible (seconds; 2× GIF).
    static let videoPresenceMaxDuration: Float = 20.0
    /// Fade in/out duration (seconds).
    static let videoPresenceFade: Float = 0.35
    /// Onset threshold for counting a beat against video lifetime.
    static let videoPresenceBeatThreshold: Float = 0.32

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
    /// Soft Gaussian glow strength around DSNK (additive; lower = more transparent).
    static let logoGlowIntensity: Float = 0.38
    /// Gaussian σ in logo UV space (mild bloom).
    static let logoGlowRadius: Float = 0.028
    /// Grain amount mixed into the logo Gaussian glow (0…1).
    static let logoGlowNoise: Float = 0.45
    /// Mild scale-up of DSNK on kick (0…0.2).
    static let logoBeatZoom: Float = 0.07
    /// Radial zoom-blur amount on kick (logo UV units).
    static let logoZoomBlur: Float = 0.035
    /// VHS: horizontal tracking / shear on DSNK (boosted further by kick).
    static let vhsLogoBeatWarp: Float = 0.55
    /// Gentle GIF-style per-scanline horizontal jitter on DSNK (UV units × kick).
    static let logoScanJitter: Float = 0.006

    // MARK: - Logo vertical roll (old TV hold)

    /// Mass of the logo in the roll spring-mass sim (higher = heavier / slower).
    static let logoRollMass: Float = 1.35
    /// Spring stiffness pulling the logo back to upright / center.
    static let logoRollSpring: Float = 9.5
    /// Velocity damping (friction).
    static let logoRollDamping: Float = 2.8
    /// Upward impulse magnitude on a strong kick (logo-heights / sec).
    static let logoRollImpulse: Float = 13.6
    /// Minimum seconds between roll impulses (~1 min).
    static let logoRollMinGap: Float = 55.0
    static let logoRollMaxGap: Float = 70.0
    /// Kick pulse must exceed this to trigger a roll (after the gap).
    static let logoRollKickThreshold: Float = 0.72
    /// Vertical motion-blur amount scaled by |roll velocity|.
    static let logoRollMotionBlur: Float = 0.045

    // MARK: - Performance

    /// Cap the Metal drawable long-edge (pixels). Fullscreen Retina otherwise
    /// runs chroma×bloom×degrade at 5K+ and tanks the frame rate.
    static let maxRenderLongEdge: CGFloat = 1920

    // MARK: - Beat

    /// How easily onsets trigger (higher = more sensitive).
    static let beatSensitivity: Float = 1.75
    /// Per-frame exponential decay of beat pulse (closer to 1 = longer).
    static let beatDecay: Float = 0.90
    /// Kick spike multiplier for VHS shear / tracking / head-switch warp.
    static let beatWarpBoost: Float = 6.5
    /// Packed into the `beatDistortionBoost` uniform (VHS warp uses this).
    static let beatDistortionBoost: Float = beatWarpBoost
    /// Brightness spike on beat.
    static let beatBrightnessBoost: Float = 0.65
}
