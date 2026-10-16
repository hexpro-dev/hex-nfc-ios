#include <metal_stdlib>
using namespace metal;

// Animated mesh-gradient background. Four control colors blend across the
// frame; their effective positions are jittered by low-freq noise driven by
// `time`. Colors are passed in from Swift so the shader stays brand-token-free.

inline float mf_hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

inline float mf_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = mf_hash(i);
    float b = mf_hash(i + float2(1.0, 0.0));
    float c = mf_hash(i + float2(0.0, 1.0));
    float d = mf_hash(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

[[stitchable]] half4 hexMeshField(
    float2 position,
    half4 color,
    float2 size,
    float time,
    half4 c0,
    half4 c1,
    half4 c2,
    half4 c3
) {
    float2 uv = position / size;

    float t = time * 0.18;
    float2 j0 = float2(mf_noise(uv * 1.3 + t),       mf_noise(uv * 1.7 - t)) * 0.30;
    float2 j1 = float2(mf_noise(uv * 1.1 - t),       mf_noise(uv * 1.5 + t)) * 0.30;
    float2 j2 = float2(mf_noise(uv * 1.9 + t * 0.5), mf_noise(uv * 1.4 - t * 0.5)) * 0.30;
    float2 j3 = float2(mf_noise(uv * 1.6 - t * 0.5), mf_noise(uv * 1.8 + t * 0.5)) * 0.30;

    float2 p0 = float2(0.15, 0.15) + j0;
    float2 p1 = float2(0.85, 0.20) + j1;
    float2 p2 = float2(0.20, 0.85) + j2;
    float2 p3 = float2(0.85, 0.85) + j3;

    float w0 = 1.0 / (0.001 + distance(uv, p0));
    float w1 = 1.0 / (0.001 + distance(uv, p1));
    float w2 = 1.0 / (0.001 + distance(uv, p2));
    float w3 = 1.0 / (0.001 + distance(uv, p3));
    float ws = w0 + w1 + w2 + w3;

    half4 blended =
        (c0 * half(w0) + c1 * half(w1) + c2 * half(w2) + c3 * half(w3)) / half(ws);

    return half4(blended.rgb, color.a);
}
