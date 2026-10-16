#include <metal_stdlib>
using namespace metal;

// Diagonal anisotropic shimmer crossing the records list. Looks like sunlight
// on brushed metal. Runs only during the verify phase.

[[stitchable]] half4 hexVerifyShimmer(
    float2 position,
    half4 color,
    float2 size,
    float time,
    half4 shimmerColor
) {
    float2 uv = position / max(size, float2(1.0));
    float band = uv.x + uv.y;
    float sweep = fract(time * 0.55 + 0.5);
    float a = smoothstep(0.08, 0.0, abs(band - sweep * 2.0));
    half4 s = shimmerColor;
    s.a *= half(a * 0.55);
    return half4(
        color.rgb * (1.0 - s.a) + s.rgb * s.a,
        max(color.a, s.a)
    );
}
