#include <metal_stdlib>
using namespace metal;

// Vivid rainbow chromatic-aberration grid that sweeps top→bottom on a
// successful scan. This is deliberately *brilliant* — high saturation, white-
// hot line cores, strong soft glow, and per-channel (R/G/B) fringing that reads
// as chromatic aberration on the line edges. It is a distinct, intentional
// flourish for the signature scan moment and is NOT the gentle, desaturated
// donation-bar rainbow (`HexTokens.Gradient.rainbow`).
//
// Applied via `colorEffect` to a transparent full-bleed overlay; the host view
// stacks a blurred copy beneath a crisp copy for bloom (the same glow idiom as
// `DonationProgressBar`). Colours are generated procedurally, so no brand-token
// colour is imported here — consistent with the rest of the shader library.

// HSV→RGB. `h` in turns (0..1). Smoothed hue ramp for a full, vivid spectrum.
inline float3 rs_hsv(float h, float s, float v) {
    float3 p = abs(fract(float3(h) + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    float3 rgb = clamp(p - 1.0, 0.0, 1.0);
    rgb = rgb * rgb * (3.0 - 2.0 * rgb);          // smoothstep the ramp
    return v * mix(float3(1.0), rgb, s);
}

// Glow profile for one axis: distance (points) to the nearest gridline →
// a thin white-hot core plus a wide soft halo.
inline float rs_line(float coord, float cell, float coreHalf, float glowHalf) {
    float m = fmod(coord, cell);
    float d = min(m, cell - m);                   // distance to nearest line
    float core = smoothstep(coreHalf, 0.0, d);
    float glow = smoothstep(glowHalf, 0.0, d);
    return core + glow * 0.45;
}

[[stitchable]] half4 hexRainbowSweepGrid(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float intensity
) {
    float2 sz = max(size, float2(1.0));
    float2 uv = position / sz;
    float p = clamp(progress, 0.0, 1.0);

    // Moving sweep band: a soft Gaussian window centred at y = p·H gliding
    // top→bottom, multiplied by a sin() envelope so the whole sweep fades in
    // near the top and out near the bottom.
    float bandY = p * sz.y;
    float bandWidth = sz.y * 0.11;
    float band = exp(-pow((position.y - bandY) / bandWidth, 2.0));
    float env = sin(3.14159265 * p);              // 0 → 1 → 0
    float sweep = band * env * clamp(intensity, 0.0, 1.0);
    // Output is independent of the (opaque) source pixel: fully transparent
    // where the sweep isn't, so the host's solid fill never shows through.
    if (sweep < 0.001) {
        return half4(0.0h);
    }

    // Grid geometry (points).
    const float cell = 46.0;
    const float coreHalf = 1.3;
    const float glowHalf = 9.0;

    // Chromatic aberration: sample the vertical-line mask at three x-offsets,
    // one per colour channel. The split widens inside the band so the fringes
    // bloom where the sweep is brightest. Horizontal lines stay aligned, so the
    // aberration reads as a clean left/right colour separation.
    float ca = 2.2 + 5.0 * sweep;
    float vR = rs_line(position.x - ca, cell, coreHalf, glowHalf);
    float vG = rs_line(position.x,      cell, coreHalf, glowHalf);
    float vB = rs_line(position.x + ca, cell, coreHalf, glowHalf);
    float h  = rs_line(position.y,      cell, coreHalf, glowHalf);

    // Per-channel line presence (split vertical fringe + shared horizontals).
    float3 lineRGB = float3(max(vR, h), max(vG, h), max(vB, h));

    // Base hue drifts across the grid and shifts as the sweep travels.
    float hue = uv.x * 0.9 + uv.y * 0.35 + p * 0.6;
    float3 rainbow = rs_hsv(fract(hue), 0.95, 1.0);

    // White-hot cores: where the line is strongest, push the tint toward white.
    float coreWhite = smoothstep(0.55, 1.0, vG + h);
    float3 tint = mix(rainbow, float3(1.0), coreWhite);

    // Compose: coloured line presence × tint × sweep, plus extra bloom from
    // the brightest cores. The overall gain is pushed past 1 so the cores
    // clip to white-hot and the colours stay vivid under additive compositing.
    float3 lit = lineRGB * tint * sweep * 1.6;
    lit += float3(coreWhite) * sweep * 1.0;

    // Straight colour + coverage alpha — transparent where there's no line, so
    // the host can additively (`plusLighter`) bloom it over the scan UI without
    // the solid fill ever showing through.
    float a = saturate(max(lit.r, max(lit.g, lit.b)));
    return half4(half3(saturate(lit)), half(a));
}
