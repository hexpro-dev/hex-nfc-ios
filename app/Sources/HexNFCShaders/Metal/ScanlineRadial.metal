#include <metal_stdlib>
using namespace metal;

// Radial scanline emanating from a tap zone. Sweeps inward; antialiased ring
// with 32px fall-off tail. `radius` is the current ring radius in points.

[[stitchable]] half4 hexScanlineRadial(
    float2 position,
    half4 color,
    float2 size,
    float2 origin,
    float radius,
    float thickness,
    half4 ringColor
) {
    float d = distance(position, origin);
    float band = smoothstep(thickness, 0.0, abs(d - radius));
    float tail = smoothstep(thickness + 32.0, 0.0, (d - radius));
    float a = max(band, tail * 0.35);
    half4 ring = ringColor;
    ring.a *= half(a);
    return half4(
        color.rgb * (1.0 - ring.a) + ring.rgb * ring.a,
        max(color.a, ring.a)
    );
}
