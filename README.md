# DSNK Wall

A macOS Metal app that renders an animated technicolor TV-static / Liquid VHS (pink–white) background with a beat-reactive **DSNK** logo — built for DJ videowalls.

Everything runs on the GPU in a single Metal fragment pass.

## Build & run

```bash
./build.sh
open "DSNK Wall.app"
```

macOS will ask for microphone access so the visuals can react to the beat. If you deny it, the app still runs without beat reactivity.

### Controls

| Key / Menu | Action |
|------------|--------|
| **Visual → VHS** (`1`) | VHS test card + noise + bloom + chroma (default) |
| **Visual → Liquid Metal** (`2`) | Full-frame pink/white Liquid VHS |
| `F` / `Cmd+F` | Toggle fullscreen |
| `Esc` | Quit |

## Tuning

All visual/audio constants live in [`Sources/DSNKWall/Config.swift`](Sources/DSNKWall/Config.swift). Tweak and rebuild.

### Blocks
- `blockGridScale` — macroblock size in UV space
- `blockReseedRate` — how often blocks re-randomize (Hz)
- `blockDensity` — fraction of cells that are colored vs dark
- `blockPaletteSaturation` — color saturation of blocks

### Shards
- `shardDensity` / `shardAspect` / `shardFlashRate` — dash-glyph overlays

### Mega-pixel distortion
- `megaPixelSize` / `megaDistortStrength` / `megaDistortSpeed`

### VHS warp
- `vhsWarpAmount` / `vhsTrackingBandSpeed` / `vhsJitterAmount` / `headSwitchNoise`

### Pixel noise (kept minor)
- `pixelNoiseAmount` / `rippleFrequency` / `rippleAxisTilt` / `blobScale` / `blobSpeed`

### Liquid VHS (pink / white)
- `flowSpeed` — animation speed
- `liquidDark` / `liquidPink` / `liquidWhite` — palette constants (pink→white only)

### Global
- `stability` — `0` = chaotic, `1` = slow/stately (scales reseed/flash rates)

### Logo
- `logoMaxFraction` — max size as fraction of `min(width, height)` (default `0.5`)
- `distortionStrength` / `distortionScale` / `distortionSpeed`
- `logoGlowIntensity` / `logoGlowRadius`

### Beat
- `beatSensitivity` / `beatDecay` / `beatDistortionBoost` / `beatBrightnessBoost`
