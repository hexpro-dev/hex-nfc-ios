#include <metal_stdlib>
using namespace metal;

// Rainbow rounded-rectangle border glow. A white-hot line traces the rounded
// outline, wrapped in a vivid procedural-HSV rainbow halo with per-channel
// chromatic-aberration fringing — the same brilliant idiom as the scan grid
// (`hexRainbowSweepGrid`), but following a rectangular perimeter instead of a
// grid. Applied via `colorEffect` to an opaque full-bleed layer; returns
// transparent everywhere off the outline so the host can bloom it additively
// (`plusLighter`) over the UI without the solid fill ever showing through.
//
// One shader, two moments:
//  * Advanced-console pulse — `shrink` ramps 0→~0.10 so the outline contracts
//    inward off the log's edge while `intensity` decays; `shudder` makes the
//    whole rim tremble and shimmer for an unstable, high-energy discharge.
//  * Write-success edge glow — `shrink≈0` so it rims the screen, `hueShift`
//    advances for a flowing spectrum, `intensity` rides the edge keyframe,
//    `shudder == 0` so it stays smooth.
//
// `time` is a phase in seconds, driving the shudder/shimmer frequencies (so the
// feel is independent of the pulse's wall-clock duration). Colours are
// generated procedurally — no brand-token colour is imported.

// HSV→RGB, `h` in turns (0..1). Smoothed hue ramp for a full, vivid spectrum.
// Local copy — `Common.metal` is intentionally not #included across shaders.
inline float3 rb_hsv(float h, float s, float v) {
    float3 p = abs(fract(float3(h) + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    float3 rgb = clamp(p - 1.0, 0.0, 1.0);
    rgb = rgb * rgb * (3.0 - 2.0 * rgb);          // smoothstep the ramp
    return v * mix(float3(1.0), rgb, s);
}

// Cheap hashes for the shudder's stepped random tremor + shimmer sparkle.
inline float rb_hash11(float n) {
    return fract(sin(n * 12.9898) * 43758.5453123);
}
inline float2 rb_hash22(float2 p) {
    float n = sin(dot(p, float2(41.0, 289.0)));
    return fract(float2(262144.0, 32768.0) * n) * 2.0 - 1.0;   // -1..1
}

// Signed distance to a rounded box centred at the origin, half-extents `b`,
// corner radius `r`. Negative inside, 0 on the contour, positive outside.
inline float rb_sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

[[stitchable]] half4 hexRainbowBorder(
    float2 position,
    half4 color,
    float2 size,
    float cornerRadius,
    float shrink,
    float hueShift,
    float intensity,
    float time,
    float shudder,
    float radial,
    float pad
) {
    float gain = clamp(intensity, 0.0, 1.0);
    if (gain < 0.001) { return half4(0.0h); }

    // `size` is the log; the layer is drawn on a canvas padded by `pad` on every
    // side so the outline's halo can spill *outside* the log edge as well as in.
    // Centre on the canvas; the contour sits at the log edge (`pad` in from the
    // canvas rim).
    float2 sz = max(size, float2(1.0));
    float2 canvas = sz + 2.0 * max(pad, 0.0);
    float2 p = position - canvas * 0.5;
    float sh = clamp(shudder, 0.0, 1.0);

    // --- Shudder: a *rigid* tremor — one stepped random vector (direction
    // jumps ~28×/s) translates the whole outline as a unit, so every edge shakes
    // but stays a straight line. No per-pixel crackle (that would bend each edge
    // into a wave); the instability comes from this jitter + the shimmer below.
    if (sh > 0.0) {
        float st = floor(time * 28.0);
        float2 tremor = rb_hash22(float2(st, st * 1.7 + 3.0)) * 2.6
                      + rb_hash22(float2(st * 2.3 + 7.0, st)) * 1.2;
        p += tremor * sh;
    }

    // Contour half-extents: pull inward by `shrink` of each dimension per side,
    // keeping the corner radius valid as the box shrinks.
    float s = clamp(shrink, 0.0, 0.45);
    float2 b = sz * 0.5 - sz * s;
    float r = min(cornerRadius, min(b.x, b.y));
    b = max(b, float2(r));

    // Signed distance to the outline; the geometry is shared by all three
    // colour channels — the fringe comes from offsetting the sampled band
    // position per channel below (clean radial chromatic aberration).
    float d = rb_sdRoundBox(p, b, r);
    float ad = abs(d);

    const float coreHalf = 1.6;                   // white-hot line core (pt)
    const float glowHalf = 11.0;                  // soft rainbow halo (pt)

    // The split widens with intensity (and a little with the shudder) so the
    // fringe blooms hardest at the peak.
    float ca = 1.4 + 4.0 * gain + 2.5 * sh;
    float cR = smoothstep(glowHalf, 0.0, abs(d - ca));
    float cG = smoothstep(glowHalf, 0.0, ad);
    float cB = smoothstep(glowHalf, 0.0, abs(d + ca));
    float core = smoothstep(coreHalf, 0.0, ad);

    // Hue mode. The write rim (`radial≈0`) flows around the perimeter for a
    // rainbow that travels along the edge; the console pulse (`radial≈1`) bands
    // the spectrum *across* the border thickness (a fixed concentric gradient),
    // so its colour never chases around the loop.
    float ang = atan2(p.y, p.x) / (2.0 * 3.14159265) + 0.5;   // 0..1 around rim
    float angularHue = ang + hueShift;
    float radialHue  = 0.62 + d * 0.02;                       // across thickness
    float hue = fract(mix(angularHue, radialHue, radial));
    float3 rainbow = rb_hsv(hue, 0.95, 1.0);

    // White-hot core dominates; the rainbow reads as the chromatic fringe and a
    // softer outward halo tint — matching the scan grid's colouring rather than
    // a saturated wash. Near the core the tint goes white; out in the halo it
    // stays rainbow.
    float coreWhite = smoothstep(0.4, 1.0, core);
    float3 tint = mix(rainbow, float3(1.0), coreWhite);
    float3 lit = float3(cR, cG, cB) * tint * gain;
    lit += float3(core) * gain * 1.5;

    // --- Radial pulse (console): a bright lobe born at the border sweeps
    // *inward* across the band as `hueShift` advances 0→1 — an outward→inward
    // energy pulse, not a chase around the rim.
    if (radial > 0.5) {
        float sweep = clamp(hueShift, 0.0, 1.0);
        float lobe = mix(coreHalf, -glowHalf, sweep);
        float pulse = exp(-pow((d - lobe) / (glowHalf * 0.5), 2.0));
        lit += tint * pulse * gain * 0.7;
    }

    // --- Shimmer: whole-rim brightness flicker + random sparkle (no spatial
    // travel), so the energy pulses unstably without circulating.
    if (sh > 0.0) {
        float spark = rb_hash11(floor(time * 38.0));
        float flick = 0.42 * sin(time * 34.0) + 0.30 * (spark - 0.5);
        lit *= 1.0 + sh * flick;
    }

    float a = saturate(max(lit.r, max(lit.g, lit.b)));
    return half4(half3(saturate(lit)), half(a));
}
