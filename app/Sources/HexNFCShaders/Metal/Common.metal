#include <metal_stdlib>
using namespace metal;

// Shared helpers reused across the Hex NFC shader library.

inline float hex_hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

inline float hex_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hex_hash21(i);
    float b = hex_hash21(i + float2(1.0, 0.0));
    float c = hex_hash21(i + float2(0.0, 1.0));
    float d = hex_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// Distance from `p` to the centre of a regular hexagon of half-width `r`.
inline float hex_sdf(float2 p, float r) {
    p = abs(p);
    return max(dot(p, normalize(float2(0.866025, 0.5))), p.y) - r;
}
