#include <metal_stdlib>
using namespace metal;

// Iridescent caustic ripple sampled inside the hexagon logo region. Intensity
// is driven by ScanFlowModel state — idle (0.0), polling (0.4), reading (0.7),
// success-bloom (1.0).

inline float hc_hash(float2 p) {
    p = fract(p * float2(127.1, 311.7));
    return fract(sin(dot(p, float2(269.5, 183.3))) * 43758.5453);
}

inline float hc_voronoi(float2 uv) {
    float2 g = floor(uv);
    float2 f = fract(uv);
    float minDist = 1.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 cell = float2(i, j);
            float2 c = cell + float2(hc_hash(g + cell), hc_hash(g + cell + 7.7));
            float d = distance(c, f);
            minDist = min(minDist, d);
        }
    }
    return minDist;
}

[[stitchable]] half4 hexCaustics(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float intensity,
    half4 tintCool,
    half4 tintWarm
) {
    float2 uv = position / size;
    float2 p = uv * 4.5 + time * 0.35;
    float v = hc_voronoi(p);
    float band = smoothstep(0.0, 0.45, 1.0 - v);
    float shimmer = sin(time * 1.3 + uv.x * 11.0 + uv.y * 9.0) * 0.5 + 0.5;
    half4 cool = mix(tintCool, tintWarm, half(shimmer));
    half4 hit = mix(color, cool, half(band * 0.85));
    return mix(color, hit, half(clamp(intensity, 0.0, 1.0)));
}
