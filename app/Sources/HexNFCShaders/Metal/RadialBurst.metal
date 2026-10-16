#include <metal_stdlib>
using namespace metal;

// Expanding rainbow ring + soft rippling inner trail, bursting from `origin`.
// A hard white-hot ring edge wrapped in a vivid procedural-HSV rainbow rim with
// chromatic-aberration fringing (the same idiom as the scan grid), trailing a
// gentle interior wash that ripples outward and fades. Drives the write-success
// moment. Applied via `colorEffect` to an opaque full-bleed layer; returns
// transparent off the contributing regions so the host blooms it additively
// (`plusLighter`) over the screen without the fill ever showing through.
//
//  * `ringRadius` / `ringWidth` — the expanding crest, in points.
//  * `trail`     — master gain for the inner wash (its own keyframe, fades slow).
//  * `hueShift`  — advances over the burst for a flowing spectrum + moving ripple.
//  * `intensity` — master gain for the ring itself.

// HSV→RGB, `h` in turns. Local copy — shaders don't #include `Common.metal`.
inline float3 rd_hsv(float h, float s, float v) {
    float3 p = abs(fract(float3(h) + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    float3 rgb = clamp(p - 1.0, 0.0, 1.0);
    rgb = rgb * rgb * (3.0 - 2.0 * rgb);
    return v * mix(float3(1.0), rgb, s);
}

[[stitchable]] half4 hexRadialBurst(
    float2 position,
    half4 color,
    float2 size,
    float2 origin,
    float ringRadius,
    float ringWidth,
    float trail,
    float hueShift,
    float intensity
) {
    float gain = clamp(intensity, 0.0, 1.0);
    float tg   = clamp(trail, 0.0, 1.0);

    float2 delta = position - origin;
    float r = length(delta);
    float ang = atan2(delta.y, delta.x) / (2.0 * 3.14159265) + 0.5;   // 0..1
    float w = max(ringWidth, 1.0);
    float hue = fract(ang + hueShift);

    // --- Expanding ring: hard white core + rainbow rim with CA fringes ---
    float coreHalf = max(w * 0.10, 1.2);
    float core = smoothstep(coreHalf, 0.0, abs(r - ringRadius));      // white edge

    float ca = w * 0.35;                                             // radial split
    float rimR = smoothstep(w, 0.0, abs(r - ringRadius + ca));
    float rimG = smoothstep(w, 0.0, abs(r - ringRadius));
    float rimB = smoothstep(w, 0.0, abs(r - ringRadius - ca));
    float3 rainbow = rd_hsv(hue, 0.95, 1.0);
    float3 rim = float3(rimR, rimG, rimB) * rainbow;

    // --- Inner rippling trail: illuminate the disc behind the crest ---
    // Brightest just behind the ring, decaying inward proportional to the ring
    // size (so the trail "fills" as the ring grows); a low-frequency radial
    // ripple, advanced by `hueShift`, flows the wash outward.
    float td = ringRadius - r;                                       // >0 inside
    float behind = td > 0.0 ? exp(-td / max(ringRadius * 0.6, w * 2.0)) : 0.0;
    float ripple = 0.65 + 0.35 * sin(r * 0.045 - hueShift * 12.566371);
    float trailGlow = tg * behind * ripple * 0.9;
    float3 trailRGB = rd_hsv(fract(hue + 0.5), 0.7, 1.0) * trailGlow;

    // Compose — rim × tint × gain, white-hot core pushed bright, trail on its
    // own gain. Straight colour + coverage alpha.
    float3 lit = rim * gain * 1.5;
    lit += float3(core) * gain * 1.7;
    lit += trailRGB * 1.2;

    float a = saturate(max(lit.r, max(lit.g, lit.b)));
    return half4(half3(saturate(lit)), half(a));
}
