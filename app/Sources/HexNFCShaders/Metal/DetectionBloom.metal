#include <metal_stdlib>
using namespace metal;

// Radial bloom + ghost outline from a tap point.

[[stitchable]] half4 hexDetectionBloom(
    float2 position,
    half4 color,
    float2 origin,
    float radius,
    float progress,
    half4 bloomColor
) {
    float p = clamp(progress, 0.0, 1.0);
    float d = distance(position, origin);

    float core   = smoothstep(radius * 0.65, 0.0, d) * (1.0 - p);
    float halo   = smoothstep(radius, radius * 0.55, d) * (1.0 - p) * 0.5;
    float ghostT = smoothstep(0.45, 1.0, p);
    float ghost  = smoothstep(radius * 1.05, radius * 0.95, d) *
                   smoothstep(radius * 0.85, radius * 0.95, d) *
                   0.6 * (1.0 - ghostT);

    float a = clamp(core + halo + ghost, 0.0, 1.0);
    half4 bloom = bloomColor;
    bloom.a *= half(a);
    return half4(
        color.rgb * (1.0 - bloom.a) + bloom.rgb * bloom.a,
        max(color.a, bloom.a)
    );
}
