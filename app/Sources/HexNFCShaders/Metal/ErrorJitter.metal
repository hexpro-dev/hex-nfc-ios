#include <metal_stdlib>
using namespace metal;

// High-frequency UV jitter that decays from full intensity to nothing over
// ~180ms (Swift drives `intensity` 1→0).

inline float ej_hash(float2 p) {
    p = fract(p * float2(443.897, 441.423));
    p += dot(p, p.yx + 19.19);
    return fract((p.x + p.y) * p.x);
}

[[stitchable]] float2 hexErrorJitter(
    float2 position,
    float intensity,
    float time
) {
    float i = clamp(intensity, 0.0, 1.0);
    float2 seed = position * 0.10 + time * 47.0;
    float jx = (ej_hash(seed) - 0.5);
    float jy = (ej_hash(seed.yx + 13.0) - 0.5);
    return position + float2(jx, jy) * (i * 6.0);
}
