#include <metal_stdlib>
using namespace metal;

// Living-energy border for the Advanced Console "command run finished" moment.
// Three layers compose a dynamic, real-world discharge instead of a clean drawn
// outline — the goal is organic, not digital:
//
//  * PLASMA RIM (`hexConsoleBorder`, colorEffect) — a white-hot outline whose
//    distance field is domain-warped by fbm so the rim undulates like an aurora
//    or flame, with bright hotspots that drift around the perimeter and a
//    chromatic-aberration fringe. Nothing is a perfect contour.
//  * LIQUID LIGHT (same colorEffect, inside the contour) — turbulent colour
//    blooms from the edge and diffuses inward as a soft front, then disperses —
//    like luminous dye dropped into dark water.
//  * HEAT HAZE (`hexConsoleHaze`, distortionEffect) — an fbm shimmer, biased
//    vertically (rising heat), applied to the energy overlay so the rim/liquid
//    ripple like a mirage. It deliberately does NOT distort the log: the log is
//    a ScrollView, and a Metal distortion/color effect on a ScrollView blanks
//    its content, so the shimmer rides the energy instead.
//
// `time` (seconds) animates the noise so it flows and churns; the wall-clock
// feel is independent of the pulse duration. Colours are procedural — no
// brand-token colour is imported. Helpers are `cb_`-prefixed and shared by both
// stitchable entry points (Common.metal is intentionally not #included).

// HSV→RGB, `h` in turns (0..1). Smoothed hue ramp for a full, vivid spectrum.
inline float3 cb_hsv(float h, float s, float v) {
    float3 p = abs(fract(float3(h) + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    float3 rgb = clamp(p - 1.0, 0.0, 1.0);
    rgb = rgb * rgb * (3.0 - 2.0 * rgb);          // smoothstep the ramp
    return v * mix(float3(1.0), rgb, s);
}

// Value-noise + fbm for organic turbulence/flow.
inline float cb_hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
inline float cb_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = cb_hash21(i);
    float b = cb_hash21(i + float2(1.0, 0.0));
    float c = cb_hash21(i + float2(0.0, 1.0));
    float d = cb_hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
inline float cb_fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * cb_noise(p);
        p *= 2.02;
        a *= 0.5;
    }
    return v;                                     // ~0..0.94
}

// Signed distance to a rounded box centred at the origin, half-extents `b`,
// corner radius `r`. Negative inside, 0 on the contour, positive outside.
inline float cb_sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

[[stitchable]] half4 hexConsoleBorder(
    float2 position,
    half4 color,
    float2 size,
    float cornerRadius,
    float pad,
    float intensity,
    float contract,
    float bleed,
    float time
) {
    float gain = clamp(intensity, 0.0, 1.0);
    float bl = clamp(bleed, 0.0, 1.0);
    if (gain < 0.001) { return half4(0.0h); }     // liquid light is gated by gain too

    // Canvas padded by `pad` per side so the rim's halo spills outside the log.
    float2 sz = max(size, float2(1.0));
    float2 canvas = sz + 2.0 * max(pad, 0.0);
    float2 p = position - canvas * 0.5;
    float2 uv = position / canvas;

    // --- Domain warp: push the sample point by a low-freq flowing fbm field so
    // the rim undulates like a flame/aurora instead of tracing a perfect rect.
    float warpAmp = 7.0 * (0.4 + 0.6 * gain);
    float2 w = float2(cb_fbm(uv * 3.0 + float2(0.0, time * 0.6)),
                      cb_fbm(uv * 3.0 + float2(5.7, -time * 0.5))) - 0.5;
    float2 pw = p + w * (2.0 * warpAmp);

    // Contour contracts inward by up to 10% per side on release.
    float c = clamp(contract, 0.0, 1.0);
    float2 b = sz * 0.5 - sz * (0.10 * c);
    float rr = min(cornerRadius, min(b.x, b.y));
    b = max(b, float2(rr));

    float d = cb_sdRoundBox(pw, b, rr);
    float ad = fabs(d);
    float ang = atan2(p.y, p.x) / (2.0 * 3.14159265) + 0.5;   // 0..1 around rim

    // --- Plasma rim: flowing hotspots modulate brightness + halo thickness so
    // the glow is uneven and alive along the perimeter.
    float rim = cb_fbm(float2(ang * 7.0, time * 1.6));         // 0..1, flows
    float hot = 0.45 + 1.1 * rim;

    const float coreHalf = 1.5;                                // white-hot line (pt)
    const float glowHalf = 5.0;                                // tight halo base (pt)
    float haloW = glowHalf * (0.5 + 0.5 * gain) * (1.0 - 0.4 * c) * (0.55 + 0.9 * rim);
    float ca = 0.6 + 2.0 * gain;                               // chromatic split
    float hR = exp(-pow((d - ca) / haloW, 2.0));
    float hG = exp(-pow( d       / haloW, 2.0));
    float hB = exp(-pow((d + ca) / haloW, 2.0));
    float core = smoothstep(coreHalf, 0.0, ad) * (0.65 + 0.7 * rim);

    float hue = fract(ang + 0.08 * rim);
    float3 rainbow = cb_hsv(hue, 0.9, 1.0);
    float3 tint = mix(rainbow, float3(1.0), smoothstep(0.4, 1.0, core));

    float3 lit = float3(hR, hG, hB) * tint * hot * gain * 1.5;
    lit += float3(core) * gain * 1.6;

    // --- Liquid light: a turbulent front blooms from the edge and travels
    // inward as `bleed` ramps, dispersing as the pulse fades.
    if (d < 0.0) {
        float inDist = -d;
        float maxDepth = min(sz.x, sz.y) * 0.5;
        float front = bl * maxDepth;
        float nz = cb_fbm(uv * 5.0 + float2(time * 0.7, time * 0.4));
        float band = exp(-pow((inDist - front) / (maxDepth * 0.55), 2.0));
        float edgeWash = exp(-inDist / (maxDepth * 0.45));
        float amt = (band * 0.7 + edgeWash * 0.45) * nz * gain * (1.0 - 0.25 * bl);
        float lhue = fract(ang * 0.5 + nz * 0.35);
        lit += cb_hsv(lhue, 0.8, 1.0) * amt * 1.1;
    }

    float a = saturate(max(lit.r, max(lit.g, lit.b)));
    return half4(half3(saturate(lit)), half(a));
}

[[stitchable]] float2 hexConsoleHaze(
    float2 position,
    float2 size,
    float amplitude,
    float time
) {
    float amp = clamp(amplitude, 0.0, 1.0);
    if (amp < 0.001) { return position; }

    float2 sz = max(size, float2(1.0));
    float2 uv = position / sz;

    // Energy radiates from the rim: shimmer strongest near the edges, calm in
    // the centre.
    float2 e = min(uv, 1.0 - uv);                 // 0 at edge .. 0.5 at centre
    float edge = 1.0 - smoothstep(0.0, 0.5, min(e.x, e.y));

    // fbm heat shimmer, biased vertically so it reads as rising heat.
    float n1 = cb_fbm(uv * 6.0 + float2(0.0, time * 2.2));
    float n2 = cb_fbm(uv * 6.0 + float2(4.3, time * 1.6));
    float2 disp = float2(n1 - 0.5, (n2 - 0.5) * 1.6);

    return position + disp * (amp * 10.0 * (0.35 + 0.65 * edge));
}
