#include <metal_stdlib>
using namespace metal;

// Vertical wavefront sweeping the records list during a write. `progress` is
// the 0→1 byte progress through the NDEF message.

[[stitchable]] half4 hexWriteWavefront(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    half4 crestColor
) {
    float y = position.y / max(size.y, 1.0);
    float p = clamp(progress, 0.0, 1.0);
    float crest = smoothstep(0.012, 0.0, abs(y - p));
    float wake  = smoothstep(0.18, 0.0, max(0.0, y - p)) * 0.4;
    float a = clamp(crest + wake, 0.0, 1.0);
    half4 e = crestColor;
    e.a *= half(a);
    return half4(
        color.rgb * (1.0 - e.a) + e.rgb * e.a,
        max(color.a, e.a)
    );
}
