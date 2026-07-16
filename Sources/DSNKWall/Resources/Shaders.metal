#include <metal_stdlib>
using namespace metal;

// Pipeline (VHS):
//   1) Looping VHS test-screen video + noise + bloom
//   2) Y2K GIF stickers (under distortion)
//   3) Chroma blur
//   4) VHS degradation layer (Shadertoy 7clXDX) — second pass
//   5) Sharp DSNK logo on top (light shear only)

struct Uniforms {
    float time;
    float beatPulse;
    float beatLevel;
    float visualMode; // unused (ABI padding)

    float2 resolution;
    float2 logoOrigin;
    float2 logoSize;

    float blockGridScale;
    float blockReseedRate;
    float blockDensity;
    float blockPaletteSaturation;

    float shardDensity;
    float shardAspect;
    float shardFlashRate;
    float megaPixelSize;

    float megaDistortStrength;
    float megaDistortSpeed;
    float vhsWarpAmount;
    float vhsTrackingBandSpeed;

    float vhsJitterAmount;
    float headSwitchNoise;
    float pixelNoiseAmount;
    float rippleFrequency;

    float rippleAxisTilt;
    float blobScale;
    float blobSpeed;
    float flowSpeed;

    float warpAmount;
    float specularPower;
    float specularIntensity;
    float fresnelStrength;

    float lavaGlowStrength;
    float distortionStrength;
    float distortionScale;
    float distortionSpeed;

    float logoGlowIntensity;
    float logoGlowRadius;
    float beatDistortionBoost;
    float beatBrightnessBoost;

    // .x = logo roll offset (0…1), .y = roll velocity, .w = vhsLogoBeatWarp
    float4 lavaTrough;
    // .x = logoGlowNoise, .w = vhsVideoOverCamera
    float4 lavaMid;
    // .x = logoScanJitter, .w = vhsCameraStrength
    float4 lavaHot;

    // .x = degrade intensity, .y = beat boost, .z = glow intensity, .w = glow radius (UV)
    float4 vhsDegrade;

    // .x = camera EMA alpha, .y = idle decay (EMA pass), .z unused, .w = gif opacity
    float4 liquidCam;

    // VHS Y2K GIF sticker: xy = top-left UV (Y-down), zw = size UV
    float4 gifOverlay;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vertex_main(uint vid [[vertex_id]]) {
    VertexOut out;
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    float2 pos = positions[vid];
    out.position = float4(pos, 0, 1);
    out.uv = float2(pos.x * 0.5 + 0.5, 0.5 - pos.y * 0.5); // Y-down
    return out;
}

float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float2 hash22(float2 p) {
    float n = hash21(p);
    return float2(n, hash21(p + n + 17.13));
}

float3 hash23(float2 p) {
    return float3(hash21(p), hash21(p + 19.19), hash21(p + 47.47));
}

float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), u.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * valueNoise(p);
        p *= 2.03;
        a *= 0.5;
    }
    return v;
}

float3 neon(float t) {
    float3 cols[7] = {
        float3(1.00, 0.02, 0.78), // magenta
        float3(0.10, 0.95, 0.25), // lime
        float3(1.00, 0.08, 0.12), // red
        float3(0.05, 0.92, 1.00), // cyan
        float3(1.00, 0.92, 0.12), // yellow
        float3(0.25, 0.20, 1.00), // blue
        float3(1.00, 0.45, 0.05)  // orange
    };
    return cols[int(floor(fract(t) * 6.999))];
}

// ------------------------------------------------------------
// Stratum map: which band type at this Y (stable-ish, animates slowly)
// 0 = solid block zone, 1 = dark dash zone, 2 = liquid vertical zone
// ------------------------------------------------------------
struct Stratum {
    float id;
    float localY;   // 0..1 within band
    float type;     // 0 / 1 / 2
    float xShift;   // wrap offset
};

Stratum stratumAt(float2 uv, float time, float stability, float warpAmt, float beat) {
    Stratum s;
    float rate = mix(1.8, 0.35, stability);
    float frame = floor(time * 0.9 * rate + beat);

    // Reference anatomy (with slow animated seam jitter):
    //   0.00–0.28  solid neon slabs
    //   0.28–0.55  dark + white dashes
    //   0.55–1.00  liquid vertical melt
    float seamJitter = (hash21(float2(floor(frame * 0.25), 1.0)) - 0.5) * 0.06;
    float y1 = 0.28 + seamJitter;
    float y2 = 0.52 + seamJitter * 0.7 + (hash21(float2(frame, 2.0)) - 0.5) * 0.04;

    // Subdivide into ~6 wrap bands for independent X shifts
    float bandCount = 6.0;
    float warpedY = uv.y + (fbm(float2(uv.y * 5.0, floor(time * 0.12 * rate))) - 0.5) * 0.04;
    s.id = floor(saturate(warpedY) * (bandCount - 0.001));
    s.localY = fract(saturate(warpedY) * bandCount);

    float baseType = 0.0;
    if (uv.y < y1) baseType = 0.0;
    else if (uv.y < y2) baseType = 1.0;
    else baseType = 2.0;

    // Occasional thin dark intrusion into liquid / block zones
    float thinDark = smoothstep(0.012, 0.0, abs(uv.y - (y1 + y2) * 0.5 + sin(time) * 0.02));
    if (thinDark > 0.5 && hash21(float2(s.id, frame)) > 0.4) baseType = 1.0;

    s.type = baseType;

    // Dramatic horizontal wrap per sub-band
    float shift = (hash21(float2(s.id * 2.7, frame)) - 0.5) * warpAmt * 5.5;
    float scan = floor(uv.y * 180.0);
    shift += (hash21(float2(scan, frame * 3.0)) - 0.5) * warpAmt * 0.3;
    shift += sin(uv.y * 55.0 + time * 2.5) * warpAmt * 0.12;
    s.xShift = shift;
    return s;
}

// ------------------------------------------------------------
// B) Large solid neon blocks
// ------------------------------------------------------------
float3 solidBlocks(float2 uv, float time, float stability, float beat, float density) {
    float rate = mix(2.2, 0.4, stability);
    float frame = floor(time * 1.7 * rate + beat * 2.0);

    // Chunky slabs like reference (large green/magenta/red rectangles)
    float2 cell = float2(0.22, 0.095);
    float row = floor(uv.y / cell.y);
    float rowR = hash21(float2(row, floor(frame * 0.4)));
    // Many rows become very wide solid slabs
    if (rowR > 0.35) cell.x = mix(0.28, 0.70, hash21(float2(row, 3.0)));
    if (rowR < 0.18) cell.y *= 2.2;
    // Occasional thin strip rows
    if (rowR > 0.85) cell.y *= 0.45;

    float2 id = floor(uv / cell);
    float rnd = hash21(id + frame * 5.3);

    // Higher fill — reference top is mostly saturated slabs, not sparse
    if (rnd > mix(0.92, density, 0.5) + 0.05) {
        return float3(0.0);
    }

    float3 col = neon(hash21(id + float2(frame, 1.7)));
    if (hash21(id + 90.0) > 0.90) col = float3(0.95, 0.95, 0.9);

    float2 f = fract(uv / cell);
    float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
    // Jagged torn edges (mega-pixel)
    float jag = hash21(floor(uv * float2(70.0, 260.0)) + frame);
    if (edge < 0.06 + jag * 0.05) {
        float3 neighbor = neon(hash21(id + float2(1.0, frame)));
        col = mix(col, mix(neighbor, float3(0.0), step(0.5, jag)), 0.85);
    }

    // Internal grain — crunchy, not flat fill
    float3 grain = hash23(floor(uv * float2(280.0, 200.0)) + frame) - 0.5;
    col += grain * 0.18;
    // Horizontal sub-tear inside block
    float tear = step(0.97, hash21(float2(floor(uv.y * 140.0), frame)));
    col = mix(col, float3(0.0), tear * 0.7);
    return saturate(col);
}

// ------------------------------------------------------------
// C) Dark band + white/colored horizontal dashes
// ------------------------------------------------------------
float3 darkDashBand(float2 uv, float2 res, float time, float stability, float shardDensity) {
    float rate = mix(2.8, 0.4, stability);
    float3 col = float3(0.01, 0.0, 0.02);

    // Sparse colored speckles in the black
    float2 pix = floor(uv * res);
    float3 speck = hash23(pix + floor(time * 20.0 * rate));
    float on = step(0.97, hash21(pix + floor(time * 18.0)));
    col += speck * on * 0.85;

    // Horizontal dashes (shards) — varying length
    float dashRow = floor(uv.y * res.y / 2.0);
    float dashCellW = mix(4.0, 18.0, hash21(float2(dashRow, floor(time * 3.0))));
    float dashCol = floor(uv.x * res.x / dashCellW);
    float2 did = float2(dashCol, dashRow);
    float frame = floor(time * 12.0 * rate);
    float alive = step(1.0 - shardDensity * 1.4, hash21(did + frame));
    float3 dashCol3 = hash21(did + 40.0) > 0.35 ? float3(1.0) : neon(hash21(did));
    // Only draw in left portion of cell → short dashes
    float localX = fract(uv.x * res.x / dashCellW);
    float dashMask = alive * step(localX, mix(0.35, 0.9, hash21(did + 2.0)));
    col = mix(col, dashCol3, dashMask);

    return col;
}

float2 aspectFillUV(float2 uv, float2 texSize, float2 viewSize) {
    if (texSize.x < 2.0 || texSize.y < 2.0) return uv;
    float va = texSize.x / max(texSize.y, 1.0);
    float ra = viewSize.x / max(viewSize.y, 1.0);
    float2 suv = uv;
    if (ra > va) {
        suv.y = (uv.y - 0.5) * (va / ra) + 0.5;
    } else {
        suv.x = (uv.x - 0.5) * (ra / va) + 0.5;
    }
    return clamp(suv, float2(0.001), float2(0.999));
}

// ------------------------------------------------------------
// VHS test-screen video + noise pass + bloom
// ------------------------------------------------------------

#define sat(a) clamp((a), 0.0, 1.0)
constant float kPI = 3.141592653;

float hash11(float p) {
    return fract(sin(p * 114.514) * 1919.810);
}

float randSeed(thread float &seed) {
    seed += 1.0;
    return hash11(seed);
}

/// Procedural stand-in for iChannel1 (colorful noise).
float3 noiseCh1(float2 uv) {
    float2 p = uv * float2(48.0, 36.0);
    float3 c = float3(
        valueNoise(p),
        valueNoise(p + float2(17.1, 9.3)),
        valueNoise(p + float2(3.7, 31.2))
    );
    // Chunkier glyphs
    float2 id = floor(uv * float2(90.0, 60.0));
    c = mix(c, hash23(id), 0.55);
    return c;
}

/// Procedural stand-in for iChannel2 (grayscale noise).
float noiseCh2(float2 uv) {
    return valueNoise(uv * float2(64.0, 96.0));
}

/// Sample looping VHS test-screen video with aspect-fill (cover).
/// `uvYDown` is Metal framebuffer UV (0 = top).
float3 sampleVHSVideo(float2 uvYDown,
                      texture2d<float> videoTex,
                      sampler videoSamp,
                      float2 viewSize) {
    float2 texSize = float2(videoTex.get_width(), videoTex.get_height());
    if (texSize.x < 2.0 || texSize.y < 2.0) {
        return float3(0.05, 0.05, 0.08);
    }
    float va = texSize.x / max(texSize.y, 1.0);
    float ra = viewSize.x / max(viewSize.y, 1.0);
    float2 suv = uvYDown;
    if (ra > va) {
        suv.y = (uvYDown.y - 0.5) * (va / ra) + 0.5;
    } else {
        suv.x = (uvYDown.x - 0.5) * (ra / va) + 0.5;
    }
    suv = clamp(suv, float2(0.001), float2(0.999));
    return videoTex.sample(videoSamp, suv).rgb;
}

/// VHS noise compositing (Shadertoy rdr), using procedural channels.
float3 vhsNoiseRdr(float2 uv, float2 ouv, float3 orig, float time, thread float &seed) {
    float3 grey = float3((orig.r + orig.g + orig.b) / 3.0);
    // Keep most of the source video; desaturate lightly
    float3 col = mix(orig, grey, 0.22);

    float2 j1 = (float2(randSeed(seed), randSeed(seed)) - 0.5) * 0.07
              + 0.2 * float2(fmod(time, 2.3 * sat(sin(time + uv.y * 15.0) * 0.5)), 0.0);
    float2 j2 = (float2(randSeed(seed), randSeed(seed)) - 0.5) * 0.07
              + 0.2 * float2(fmod(-time, 2.3 * sat(sin(-time + uv.y * 15.0) * 10.0)), 0.0);

    col += pow(noiseCh1(uv + j1) * 0.81, float3(2.0)) * 0.35;
    col *= sat(pow(noiseCh1(uv + j2) * 0.81, float3(1.0)) + 0.72);

    float nA1 = pow(noiseCh2(ouv * float2(1.0, 3.0) * 0.2 - float2(time, sin(time))), 3.0);
    float nA2 = pow(noiseCh2(ouv * float2(1.0, 3.0) * 0.1 + float2(time, 0.0)), 3.0);
    float3 noiseA = nA1 * nA2 * float3(1.0);
    col += noiseA * sat(sin(uv.y * 8.0)) * sat(sin(time) * 5.0) * 0.9;

    float nB1 = pow(noiseCh2(ouv * float2(1.0, 3.0) * 0.2 - float2(time, sin(time))), 3.0);
    float nB2 = pow(noiseCh2(ouv * float2(1.0, 3.0) * 0.1 + float2(time, 0.0)), 3.0);
    float3 noiseB = nB1 * nB2 * float3(1.0);
    col += noiseB * sat(sin(uv.y * 15.0 + time * 10.0) - 0.8) * sat(sin(time * 0.33) * 5.0) * 1.4;

    float nC1 = pow(noiseCh2(ouv * float2(1.0, 3.0) * 0.2 - float2(time, sin(time))), 3.0);
    float nC2 = pow(noiseCh2(ouv * float2(1.0, 3.0) * 0.1 + float2(time, 0.0)), 3.0);
    float3 noiseC = nC1 * nC2 * float3(1.0);
    col += noiseC * sat(sin(uv.y * 15.0 + sin(time * 2.0)) - 0.8) * 2.2;
    // Soften the crush so the looping test-screen video stays readable
    col *= sat(noiseC + 0.98 + noiseB * 0.25);
    col = mix(orig, col, 0.72);

    return col;
}

/// Kick energy 0…1 from onset pulse + sustained bass level.
float kickAmount(constant Uniforms &u) {
    return saturate(u.beatPulse + u.beatLevel * 0.45);
}

/// Horizontal VHS shear / tracking / head-switch tear. `ouv` is Y-up.
float2 applyVHSShear(float2 ouv, float2 uv, float2 res, constant Uniforms &u) {
    float t = u.time;
    float kick = kickAmount(u);
    float warpMul = 1.0 + kick * u.beatDistortionBoost;
    float shear = u.vhsWarpAmount * warpMul;
    float jitter = u.vhsJitterAmount * (1.0 + kick * 6.0);

    float stppx = 0.0015;
    float2 qouv = floor(ouv / stppx) * stppx;
    float2 quv = floor(uv / stppx) * stppx;

    // Primary scanline shear (kicks punch this hard)
    qouv.x += sin(fmod(quv.y + t, 0.2) / 0.2) * 0.003 * (1.0 + shear * 10.0);
    qouv.x += sin(fmod(quv.x * 10.0 + t, 1.0) * 10.0) * 0.0005 * warpMul;

    // Drifting tracking band
    float bandY = ouv.y * 28.0 + t * u.vhsTrackingBandSpeed * 12.0;
    qouv.x += sin(bandY) * 0.01 * shear * (0.35 + kick * 1.4);
    qouv.x += sin(bandY * 2.7 + 1.7) * 0.004 * shear * kick;

    // Per-scanline jitter
    float scan = floor(ouv.y * res.y);
    qouv.x += (hash21(float2(scan, floor(t * 48.0))) - 0.5) * jitter;

    // Head-switch tear at bottom of frame (low ouv.y)
    float head = smoothstep(0.14, 0.0, ouv.y) * u.headSwitchNoise * (0.25 + kick * 1.8);
    qouv.x += (hash21(float2(floor(ouv.y * 90.0), floor(t * 22.0))) - 0.5) * head * 0.1;
    qouv.x += sin(ouv.y * 120.0 + t * 30.0) * head * 0.02;

    return fract(qouv);
}

float3 sampleNoisedScene(float2 ouv, float2 uv, float2 res,
                         constant Uniforms &u,
                         texture2d<float> videoTex, sampler videoSamp) {
    float2 qouv = applyVHSShear(ouv, uv, res, u);
    float2 quv = floor(uv / 0.0015) * 0.0015;
    float seed = noiseCh2(quv) + fract(u.time);
    float2 metalUV = float2(qouv.x, 1.0 - qouv.y);
    float3 orig = sampleVHSVideo(metalUV, videoTex, videoSamp, res);
    return vhsNoiseRdr(quv, qouv, orig, u.time, seed);
}

/// Approximate doBloom by re-sampling the noised video (cheaper sample count).
float3 doBloom(float2 uv, float2 res, float blur, float threshold,
               constant Uniforms &u,
               texture2d<float> videoTex, sampler videoSamp) {
    float3 col = float3(0.0);
    const int cnt = 24;
    float fcnt = float(cnt);
    for (int i = 0; i < cnt; ++i) {
        float fi = float(i);
        float samplePerTurn = 5.0;
        float an = (fi / (fcnt / samplePerTurn)) * kPI;
        float2 p = uv - float2(sin(an), cos(an)) * blur;
        p = clamp(p, float2(0.001), float2(0.999));
        // centered uv for noise pass
        float2 frag = p * res;
        float2 nuv = (frag - 0.5 * res) / max(res.x, 1.0);
        float3 smple = sampleNoisedScene(p, nuv, res, u, videoTex, videoSamp);
        if (length(smple) > threshold) {
            col += smple;
        }
    }
    return col / fcnt;
}

float sampleLogo(float2 logoUV, texture2d<float> logoTex, sampler logoSamp, float mipLevel) {
    if (logoUV.x < 0.0 || logoUV.x > 1.0 || logoUV.y < 0.0 || logoUV.y > 1.0) return 0.0;
    return logoTex.sample(logoSamp, logoUV, level(mipLevel)).r;
}

/// Like sampleLogo but clamps UVs so soft mip / glow taps can bleed at the rect edge.
float sampleLogoGlow(float2 logoUV, texture2d<float> logoTex, sampler logoSamp, float mipLevel) {
    return logoTex.sample(logoSamp, clamp(logoUV, 0.0, 1.0), level(mipLevel)).r;
}

float3 rgb2yuv(float3 rgb) {
    return float3(
        0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b,
        -0.147 * rgb.r - 0.289 * rgb.g + 0.436 * rgb.b,
        0.615 * rgb.r - 0.515 * rgb.g - 0.100 * rgb.b
    );
}

float3 yuv2rgb(float3 yuv) {
    return float3(
        yuv.r + 1.140 * yuv.b,
        yuv.r - 0.395 * yuv.g - 0.581 * yuv.b,
        yuv.r + 2.032 * yuv.g
    );
}

/// Black→red remap of camera luminance (VHS underlay).
float3 cameraBlackRed(float2 uvScreen, float2 res,
                      texture2d<float> camEMA, sampler camSamp) {
    float2 camSize = float2(camEMA.get_width(), camEMA.get_height());
    if (camSize.x < 2.0 || camSize.y < 2.0) return float3(0.0);
    float2 camUV = aspectFillUV(uvScreen, camSize, res);
    float3 cam = camEMA.sample(camSamp, camUV).rgb;
    float lum = saturate(dot(cam, float3(0.299, 0.587, 0.114)));
    lum = pow(lum, 0.9);
    return float3(lum, lum * 0.04, lum * 0.02); // black → deep red
}

/// VHS background: black→red camera underlay + video + noise + bloom. No logo.
float3 renderBackground(float2 uvScreen, constant Uniforms &u, bool withBloom,
                        texture2d<float> videoTex, sampler videoSamp,
                        texture2d<float> camEMA, sampler camSamp) {
    float2 res = max(u.resolution, float2(1.0));
    float t = u.time;

    // lavaHot.w = camera strength, lavaMid.w = video cover over camera.
    float3 under = cameraBlackRed(uvScreen, res, camEMA, camSamp)
                 * saturate(u.lavaHot.w > 0.001 ? u.lavaHot.w : 0.9);

    float2 ouv = float2(uvScreen.x, 1.0 - uvScreen.y);
    float2 frag = ouv * res;
    float2 uv = (frag - 0.5 * res) / max(res.x, 1.0);

    float2 qouv = applyVHSShear(ouv, uv, res, u);
    float2 quv = floor(uv / 0.0015) * 0.0015;
    float seed = noiseCh2(quv) + fract(t);
    float2 metalUV = float2(qouv.x, 1.0 - qouv.y);
    float3 orig = sampleVHSVideo(metalUV, videoTex, videoSamp, res);
    float3 col = vhsNoiseRdr(quv, qouv, orig, t, seed);

    if (withBloom) {
        float bloomIntensity = 624.0 / 640.0;
        float3 bloomSample = doBloom(ouv, res, 2.0 / 360.0, 117.0 / 640.0, u, videoTex, videoSamp);
        bloomSample = pow(max(bloomSample, float3(0.0)), float3(0.5));
        col = (col + bloomSample * bloomIntensity) * 0.5;
    }

    // Kick lifts background video brightness from 0.8 → 1.0
    float kick = kickAmount(u);
    col *= mix(0.8, 1.0, kick);

    float cover = saturate(u.lavaMid.w > 0.001 ? u.lavaMid.w : 0.72);
    col = mix(under, col, cover);
    // Extra camera presence in dark regions so the underlay reads as the bottom layer
    float vL = saturate(dot(col, float3(0.299, 0.587, 0.114)));
    col = mix(max(col, under), col, smoothstep(0.0, 0.28, vL));
    return saturate(col);
}

float3 applyGifSticker(float3 col, float2 metalUV, float2 res, constant Uniforms &u,
                       texture2d<float> gifTex, sampler gifSamp) {
    float gifOp = u.liquidCam.w;
    float2 gifOrigin = u.gifOverlay.xy;
    float2 gifSize = u.gifOverlay.zw;
    if (gifOp <= 0.001 || gifSize.x <= 0.001 || gifSize.y <= 0.001) return col;

    float kick = kickAmount(u);
    float2 guv = (metalUV - gifOrigin) / gifSize;
    // Mild VHS jitter on the sticker UVs (still under the heavy degrade pass)
    guv.x += (hash21(float2(floor(metalUV.y * res.y), floor(u.time * 20.0))) - 0.5) * 0.02 * kick;
    if (guv.x < 0.0 || guv.x > 1.0 || guv.y < 0.0 || guv.y > 1.0) return col;

    float4 g = gifTex.sample(gifSamp, clamp(guv, 0.0, 1.0));
    float a = saturate(g.a) * gifOp;
    float3 screened = 1.0 - (1.0 - col) * (1.0 - g.rgb);
    return mix(col, mix(g.rgb, screened, 0.45), a);
}

/// Wrap logo V so top/bottom edges connect (old TV vertical roll).
float2 logoRollUV(float2 logoUV, float rollOffset) {
    float2 uv = logoUV;
    uv.y = fract(uv.y + rollOffset);
    return uv;
}

float sampleLogoWrapped(float2 logoUV, texture2d<float> logoTex, sampler logoSamp,
                        float mipLevel, float rollOffset) {
    // X still hard-clipped; Y wraps through the roll
    if (logoUV.x < 0.0 || logoUV.x > 1.0) return 0.0;
    float2 uv = logoRollUV(logoUV, rollOffset);
    return logoTex.sample(logoSamp, uv, level(mipLevel)).r;
}

/// Mild 2D Gaussian of the logo mask in logo-UV space (σ = logoGlowRadius),
/// with per-tap jitter so the bloom reads as noisy / taped.
float logoGaussian(float2 logoUV, texture2d<float> logoTex, sampler logoSamp,
                   float sigma, float rollOffset, float time, float noiseAmt) {
    sigma = max(sigma, 0.004);
    // 9×9 kernel, sample spacing ≈ σ/2 → ~±2σ coverage
    const int R = 4;
    float stepUV = sigma * 0.5;
    float inv2s2 = 1.0 / (2.0 * sigma * sigma);
    float sum = 0.0;
    float wsum = 0.0;
    float tFrame = floor(time * 24.0);
    for (int y = -R; y <= R; ++y) {
        for (int x = -R; x <= R; ++x) {
            float2 d = float2(float(x), float(y)) * stepUV;
            // Jitter sample positions with animated grain
            float2 j = float2(
                hash21(float2(logoUV.x * 90.0 + float(x), tFrame + float(y) * 3.1)),
                hash21(float2(logoUV.y * 90.0 + float(y), tFrame * 1.7 + float(x) * 5.3))
            ) - 0.5;
            d += j * stepUV * 1.4 * noiseAmt;
            float w = exp(-dot(d, d) * inv2s2);
            // Per-tap weight noise (film grain in the bloom)
            float nw = 1.0 + (hash21(float2(float(x) + tFrame, float(y) * 7.0 + logoUV.x * 40.0)) - 0.5) * 1.6 * noiseAmt;
            w *= max(nw, 0.05);
            sum += sampleLogoWrapped(logoUV + d, logoTex, logoSamp, 0.0, rollOffset) * w;
            wsum += w;
        }
    }
    return sum / max(wsum, 1e-4);
}

float3 applyLogo(float3 col, float2 fragPx, constant Uniforms &u,
                 texture2d<float> logoTex, sampler logoSamp,
                 float logoWarpScale) {
    if (u.logoSize.x <= 2.0 || u.logoSize.y <= 2.0) return col;

    float kick = kickAmount(u);
    float rollOffset = u.lavaTrough.x;
    float rollVel = u.lavaTrough.y;
    // distortionScale = beat zoom, distortionStrength = zoom-blur amount
    float beatZoom = 1.0 - kick * saturate(u.distortionScale);
    float2 logoUV = (fragPx - u.logoOrigin) / u.logoSize;
    logoUV = (logoUV - 0.5) / max(beatZoom, 0.75) + 0.5;

    // Very gentle GIF-style per-scanline horizontal jitter (lavaHot.x = logoScanJitter)
    float scanJitter = u.lavaHot.x > 0.0 ? u.lavaHot.x : 0.006;
    logoUV.x += (hash21(float2(floor(fragPx.y), floor(u.time * 20.0))) - 0.5)
              * scanJitter * (0.35 + kick * 0.9);

    float sigma = max(u.logoGlowRadius, 0.004);
    float zoomBlurAmt = max(u.distortionStrength, 0.0) * (0.25 + kick * 0.9);
    // distortionSpeed packs logoRollMotionBlur scale
    float rollBlur = abs(rollVel) * max(u.distortionSpeed, 0.0);
    float margin = sigma * 3.0 + zoomBlurAmt * 1.5 + 0.04;
    // Y wraps, so only cull on X (plus a little margin for glow/zoom)
    if (logoUV.x < -margin || logoUV.x > 1.0 + margin) {
        return col;
    }
    if (logoUV.y < -0.15 || logoUV.y > 1.15) {
        return col;
    }

    // Soft noisy Gaussian bloom behind the sharp glyph (rolls with the logo).
    // lavaMid.x packs logoGlowNoise when set; fall back to a mild default.
    float glowNoise = u.lavaMid.x > 0.001 ? u.lavaMid.x : 0.45;
    float blurred = logoGaussian(logoUV, logoTex, logoSamp, sigma, rollOffset, u.time, glowNoise);
    float sharpRef = sampleLogoWrapped(logoUV, logoTex, logoSamp, 0.0, rollOffset);
    float halo = saturate(blurred - sharpRef * 0.85);
    // Spatial grain on the halo itself
    float grain = hash21(floor(logoUV * 220.0) + floor(u.time * 18.0));
    halo *= mix(1.0, 0.55 + grain * 0.9, glowNoise);
    halo *= u.logoGlowIntensity * (0.75 + kick * 0.2);
    col += float3(1.05, 1.0, 1.08) * halo;

    // Mild radial zoom blur on kick + vertical motion blur from roll velocity
    float2 dir = logoUV - 0.5;
    float m = 0.0;
    float wsum = 0.0;
    const int zTaps = 5;
    for (int i = 0; i < zTaps; ++i) {
        float f = (float(i) / float(zTaps - 1)) * 2.0 - 1.0; // -1…1
        float w = 1.0 - abs(f);
        w *= w;
        float2 suv = logoUV + dir * (f * zoomBlurAmt);
        suv.y += f * rollBlur * sign(rollVel + 1e-5);
        m += sampleLogoWrapped(suv, logoTex, logoSamp, abs(f) * 0.8, rollOffset) * w;
        wsum += w;
    }
    m /= max(wsum, 1e-4);

    // Extra horizontal tracking / shear on the hard glyph
    if (logoWarpScale > 0.001) {
        float2 px = fragPx;
        float t = u.time;
        float2 res = max(u.resolution, float2(1.0));
        float ny = px.y / res.y;
        float warp = logoWarpScale * (0.2 + kick * (1.4 + u.beatDistortionBoost * 0.15));
        px.x += sin(ny * 28.0 + t * 1.8) * 2.8 * warp;
        px.x += sin(ny * 70.0 + t * 6.0) * 1.4 * warp;
        px.x += sin(ny * 120.0 + t * 14.0 + kick * 4.0) * 0.9 * warp * kick;
        px.x += (hash21(float2(floor(px.y), floor(t * 36.0))) - 0.5) * 2.4 * warp;
        px.x += (hash21(float2(floor(px.y * 0.5), floor(t * 12.0))) - 0.5) * 3.5 * warp * kick;
        float2 warpedUV = (px - u.logoOrigin) / u.logoSize;
        warpedUV = (warpedUV - 0.5) / max(beatZoom, 0.75) + 0.5;
        float sharp = sampleLogoWrapped(warpedUV, logoTex, logoSamp, 0.0, rollOffset);
        // Prefer sheared sample for solid fill; keep zoom-blur soft edges
        m = max(m * (0.55 + kick * 0.35), sharp);
    } else {
        m = max(m, sampleLogoWrapped(logoUV, logoTex, logoSamp, 0.0, rollOffset));
    }

    float mask = smoothstep(0.32, 0.52, m);
    col = mix(col, float3(1.0), mask);
    return saturate(col);
}

/// Full frame at a screen UV (Y-down). Neighbors skip bloom for performance.
/// texture2 = GIF sticker; texture3 = camera EMA. Logo is applied in the degrade pass.
float3 renderEverything(float2 uvScreen, float2 fragPx, constant Uniforms &u,
                        texture2d<float> logoTex, sampler logoSamp,
                        texture2d<float> videoTex, sampler videoSamp,
                        texture2d<float> gifTex, sampler gifSamp,
                        texture2d<float> camEMA, sampler camSamp,
                        bool withBloom) {
    float3 col = renderBackground(uvScreen, u, withBloom, videoTex, videoSamp, camEMA, camSamp);
    // GIFs sit under chroma / degrade; logo is applied in the degrade pass.
    return applyGifSticker(col, uvScreen, max(u.resolution, float2(1.0)), u, gifTex, gifSamp);
}

/// Chroma blur / smear (YUV horizontal accumulate) — applied on top of everything.
float3 chromaBlur(float2 fragCoord, float2 res, float time,
                  constant Uniforms &u,
                  texture2d<float> logoTex, sampler logoSamp,
                  texture2d<float> videoTex, sampler videoSamp,
                  texture2d<float> gifTex, sampler gifSamp,
                  texture2d<float> camEMA, sampler camSamp) {
    float color_resX = 7.0;
    float chromaBias = 30.0;
    // Kicks widen the chroma smear
    float kick = kickAmount(u);
    chromaBias += kick * 18.0;

    int color_res = int((sin(time + fragCoord.y / 10.0) + 1.1) * color_resX + chromaBias);
    color_res = clamp(color_res, 1, 48);

    float2 uv = fragCoord / res;
    // fragCoord is Y-down framebuffer space matching in.position
    float3 center = renderEverything(uv, fragCoord, u, logoTex, logoSamp, videoTex, videoSamp, gifTex, gifSamp, camEMA, camSamp, true);
    float Y = 0.299 * center.r + 0.587 * center.g + 0.114 * center.b;

    float2 colorData = float2(0.0);
    int samples = 10;
    for (int i = 0; i < 48; ++i) {
        if (i >= color_res) break;
        if (int(fragCoord.x) - i > 0) {
            float2 fragI = float2(fragCoord.x - float(i), fragCoord.y);
            float2 uvI = fragI / res;
            float3 sampled = rgb2yuv(renderEverything(uvI, fragI, u, logoTex, logoSamp, videoTex, videoSamp, gifTex, gifSamp, camEMA, camSamp, false));
            if (length(sampled.yz) > 0.02) {
                colorData += sampled.yz;
                samples += 1;
            }
        }
    }
    colorData = sin(colorData / float(samples) * 1.2);
    return saturate(yuv2rgb(float3(Y, colorData.x, colorData.y)));
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              constant Uniforms &u [[buffer(0)]],
                              texture2d<float> logoTex [[texture(0)]],
                              sampler logoSamp [[sampler(0)]],
                              texture2d<float> videoTex [[texture(1)]],
                              sampler videoSamp [[sampler(1)]],
                              texture2d<float> gifTex [[texture(2)]],
                              sampler gifSamp [[sampler(2)]],
                              texture2d<float> camEMA [[texture(3)]],
                              sampler camSamp [[sampler(3)]]) {
    float2 res = max(u.resolution, float2(1.0));
    float2 fragCoord = in.position.xy;
    // Camera underlay + video + GIFs + chroma (degrade is a second pass)
    float3 col = chromaBlur(fragCoord, res, u.time, u, logoTex, logoSamp, videoTex, videoSamp, gifTex, gifSamp, camEMA, camSamp);
    return float4(col, 1.0);
}

/// Camera EMA: sample every stride frame; idle frames decay history faster.
/// liquidCam.x = alpha, .y = idle decay (EMA pass only), .w = stride flag (0/1).
fragment float4 fragment_camera_ema(VertexOut in [[stage_in]],
                                    constant Uniforms &u [[buffer(0)]],
                                    texture2d<float> prevEMA [[texture(0)]],
                                    sampler prevSamp [[sampler(0)]],
                                    texture2d<float> cameraTex [[texture(1)]],
                                    sampler cameraSamp [[sampler(1)]]) {
    float2 uv = in.uv;
    float2 res = max(u.resolution, float2(1.0));
    float3 prev = prevEMA.sample(prevSamp, uv).rgb;
    float idleDecay = saturate(u.liquidCam.y);
    float stride = u.liquidCam.w; // 1 = pull new camera sample this frame

    if (stride < 0.5) {
        return float4(prev * idleDecay, 1.0);
    }

    float2 camSize = float2(cameraTex.get_width(), cameraTex.get_height());
    float2 camUV = aspectFillUV(uv, camSize, res);
    float3 cam = cameraTex.sample(cameraSamp, camUV).rgb; // store non-inverted
    float a = saturate(u.liquidCam.x);
    // Kick briefly pulls EMA toward the new frame
    a = saturate(a + kickAmount(u) * 0.12);
    float3 decayed = prev * idleDecay;
    return float4(mix(decayed, cam, a), 1.0);
}

// -----------------------------------------------------------------------------
// VHS degradation layer — Shadertoy https://www.shadertoy.com/view/7clXDX
// Image pass (glitch / scratch / whiteout) + soft Buffer D (vignette / smear).
// Procedural noise replaces the two Shadertoy input textures.
// -----------------------------------------------------------------------------

float degradeNoiseOrganic(float2 uv) {
    // Stand-in for iChannel2 (cellular / organic noise)
    float n = valueNoise(uv * float2(3.1, 7.7));
    n = mix(n, valueNoise(uv * float2(11.0, 19.0) + 17.0), 0.45);
    return n;
}

float degradeNoiseFiber(float2 uv) {
    // Stand-in for iChannel3 (woven / fiber texture)
    float a = valueNoise(uv * float2(48.0, 2.5));
    float b = valueNoise(uv * float2(2.5, 48.0) + 9.0);
    return mix(a, b, 0.55);
}

float3 degradeTint(float brightness) {
    float3 a = float3(0.9, 1.1, 0.9) * brightness;
    float3 b = float3(0.9, 0.9, 1.2) * (1.0 - brightness);
    return a + b;
}

float3 degradeSaturate(float3 col, float amount) {
    return col * amount + 0.5 * (1.0 - amount);
}

float3 softBufferD(texture2d<float> src, sampler srcSamp, float2 uv, float intensity) {
    // Cheap stand-in for Buffer D blur/sharpen/vignette (full conv is impractical).
    float2 px = 1.0 / max(float2(src.get_width(), src.get_height()), float2(1.0));
    float skips = max(intensity * 2.0, 0.15);
    float3 total = float3(0.0);
    float wsum = 0.0;
    for (int y = -2; y <= 2; ++y) {
        for (int x = -4; x <= 4; ++x) {
            float2 off = float2(float(x), float(y) * 0.35) * skips * px * 8.0;
            float2 p = clamp(uv + off, float2(0.001), float2(0.999));
            float3 s = src.sample(srcSamp, p).rgb;
            float dist = length(float2(float(x) / 4.0, float(y) / 2.0));
            float w = max(1.0 - dist, 0.0);
            w = w * w;
            float g = (s.r + s.g + s.b) * (1.0 / 3.0);
            float3 t = degradeTint(g) * min(intensity, 1.0) + (1.0 - min(intensity, 1.0));
            total += s * w * max(g, 0.05) * t;
            wsum += w * max(g, 0.05);
        }
    }
    float3 blurred = total / max(wsum, 1e-4);
    float3 base = src.sample(srcSamp, uv).rgb;
    float vig = length((uv * 2.0 - 1.0) * 0.5);
    vig = cos(clamp(vig, 0.0, 1.0) * (kPI * 0.5));
    vig = vig * vig + 0.2;
    vig = mix(1.0, vig, min(intensity, 1.0));
    float3 col = mix(base, blurred, saturate(intensity * 0.65));
    col *= vig;
    float g = (col.r + col.g + col.b) * (1.0 / 3.0) + 0.15;
    col = degradeSaturate(col * g, mix(1.0, 0.9, min(intensity, 1.0)));
    col += (hash21(floor(uv * 80.0) + floor(uv.yx * 13.0)) - 0.5) * 0.025 * intensity;
    return saturate(col);
}

/// Second pass: read scene (bg + GIFs), apply 7clXDX degradation, then DSNK logo on top.
fragment float4 fragment_vhs_degrade(VertexOut in [[stage_in]],
                                     constant Uniforms &u [[buffer(0)]],
                                     texture2d<float> sceneTex [[texture(0)]],
                                     sampler sceneSamp [[sampler(0)]],
                                     texture2d<float> logoTex [[texture(1)]],
                                     sampler logoSamp [[sampler(1)]]) {
    float2 res = max(u.resolution, float2(1.0));
    float2 fragCoord = in.position.xy;
    // Shadertoy Y-up for Image math
    float2 stUV = float2(fragCoord.x / res.x, 1.0 - fragCoord.y / res.y);
    float2 metalUV = fragCoord / res;

    // Buffer B idle animation: ((cos(t)+1)/2)*1.5+0.01, scaled by Config + kick
    float kick = kickAmount(u);
    float intensity = ((cos(u.time) + 1.0) * 0.5) * 1.5 + 0.01;
    intensity *= u.vhsDegrade.x;
    intensity += kick * u.vhsDegrade.y * (1.0 + u.beatDistortionBoost * 0.15);

    float x_scroll = u.time * 50000.0;
    float y_scroll = u.time * 150.0;

    float2 uvread = float2((fragCoord.x + x_scroll) / 500.0, (fragCoord.y + y_scroll) / 6.0);
    float glitch = degradeNoiseOrganic(uvread / res);
    float glitch_mask = round(clamp(glitch, 0.0, 1.0));

    float2 uvread2 = float2((fragCoord.x + x_scroll) / 200.0, (fragCoord.y + y_scroll) * 1.0);
    float scratch = degradeNoiseOrganic(uvread2 / res);
    scratch = smoothstep(0.45, 0.55, scratch);
    float whiteout = glitch_mask * (scratch + glitch);

    float2 uvread3 = float2((fragCoord.x + x_scroll) / 10.0, (fragCoord.y + y_scroll) * 1.0);
    whiteout += whiteout * degradeNoiseFiber(uvread3 / res);
    whiteout *= whiteout;

    float corona = abs(stUV.y * 2.0 - 1.0);
    corona *= corona;
    float bottom_deggredation = -((stUV.y * 2.0 - 1.0) + 0.7) * 5.0;
    bottom_deggredation = clamp(bottom_deggredation, 0.0, 1.0) * 2.0;
    // Kicks emphasize bottom tear / tracking trash
    bottom_deggredation *= 1.0 + kick * 1.6;
    whiteout = whiteout * 0.5 * corona + bottom_deggredation * (glitch + scratch);
    float3 deggredation = 1.0 - degradeTint(whiteout);

    float2 sampleUV = metalUV;
    float shearMul = intensity * (1.0 + kick * u.beatDistortionBoost * 0.4);
    sampleUV.x -= (whiteout / 10.0) * shearMul;
    // Extra kick-driven scanline tear on top of whiteout shear
    float scan = floor(metalUV.y * res.y);
    sampleUV.x += (hash21(float2(scan, floor(u.time * 36.0))) - 0.5) * kick * 0.055;
    sampleUV.x += sin(metalUV.y * 70.0 + u.time * 14.0) * kick * 0.025 * (1.0 + u.vhsWarpAmount * 8.0);
    sampleUV = clamp(sampleUV, float2(0.001), float2(0.999));

    // Buffer D soft pass, then Image glitch/tint (reads degraded scene like iChannel0)
    float3 col = softBufferD(sceneTex, sceneSamp, sampleUV, intensity);
    col = degradeSaturate(col, mix(1.0, (1.0 - clamp(scratch / 10.0, 0.0, 1.0)), intensity));
    col = clamp(col, 0.0, 1.0);
    col += deggredation * intensity;
    col += (whiteout / 3.0) * intensity;

    // Small soft glow over the whole buffer (final VHS top layer)
    float glowAmt = u.vhsDegrade.z;
    float glowRad = max(u.vhsDegrade.w, 0.001);
    if (glowAmt > 0.001) {
        float3 glow = float3(0.0);
        float wsum = 0.0;
        const int rings = 2;
        const int spokes = 8;
        for (int r = 1; r <= rings; ++r) {
            float rr = glowRad * (float(r) / float(rings));
            float rw = 1.0 / float(r);
            for (int i = 0; i < spokes; ++i) {
                float a = (float(i) / float(spokes)) * kPI * 2.0;
                float2 p = clamp(metalUV + float2(cos(a), sin(a)) * rr, float2(0.001), float2(0.999));
                float3 s = sceneTex.sample(sceneSamp, p).rgb;
                float lum = dot(s, float3(0.299, 0.587, 0.114));
                glow += s * rw * (0.55 + 0.45 * smoothstep(0.2, 0.75, lum));
                wsum += rw;
            }
        }
        // Center contribution keeps the haze tied to local brightness
        float3 c = sceneTex.sample(sceneSamp, metalUV).rgb;
        glow += c * 1.5;
        wsum += 1.5;
        glow /= max(wsum, 1e-4);
        // Soft additive haze that lifts dark areas without crushing highlights
        col += glow * glowAmt * (0.65 + 0.35 * (1.0 - saturate(col)));
    }

    // DSNK on top — light base tracking, stronger kick shear (lavaTrough.w = vhsLogoBeatWarp).
    float logoWarp = u.lavaTrough.w > 0.001 ? u.lavaTrough.w : 0.55;
    col = applyLogo(col, fragCoord, u, logoTex, logoSamp, logoWarp);

    return float4(saturate(col), 1.0);
}
