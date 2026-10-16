#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Per-channel UV offset. Triggered once on tag detection — `progress` runs
// 0→1 over ~300ms (sampled with ease-out from the Swift side).

[[stitchable]] half4 hexChromaticAberration(
    float2 position,
    SwiftUI::Layer layer,
    float progress,
    float amount
) {
    float p = clamp(progress, 0.0, 1.0);
    float falloff = 1.0 - p;
    float k = amount * falloff;
    half4 r = layer.sample(position + float2(-k, 0.0));
    half4 g = layer.sample(position);
    half4 b = layer.sample(position + float2( k, 0.0));
    return half4(r.r, g.g, b.b, g.a);
}
