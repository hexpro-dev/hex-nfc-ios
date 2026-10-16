#include <metal_stdlib>
using namespace metal;

// Concentric hex-shaped rings exploding outward from each record row on the
// `.done` state. Per-row stagger is encoded via `phase`.

inline float lr_hex_sdf(float2 p, float r) {
    p = abs(p);
    return max(dot(p, normalize(float2(0.866025, 0.5))), p.y) - r;
}

[[stitchable]] half4 hexLockInRing(
    float2 position,
    half4 color,
    float2 origin,
    float phase,
    float maxRadius,
    half4 ringColor
) {
    float t = clamp(phase, 0.0, 1.0);
    float r = mix(0.0, maxRadius, t);
    float d = abs(lr_hex_sdf(position - origin, r));
    float a = smoothstep(2.0, 0.0, d) * (1.0 - t);
    half4 ring = ringColor;
    ring.a *= half(a);
    return half4(
        color.rgb * (1.0 - ring.a) + ring.rgb * ring.a,
        max(color.a, ring.a)
    );
}
