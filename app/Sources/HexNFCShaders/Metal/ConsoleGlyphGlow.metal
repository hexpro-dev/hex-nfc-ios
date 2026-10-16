#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// CRT-style glyph bloom on the APDU console. `freshness` 1.0 = brand-new
// byte, 0.0 = cold.

[[stitchable]] half4 hexConsoleGlow(
    float2 position,
    SwiftUI::Layer layer,
    float freshness,
    half4 glowColor
) {
    half4 base = layer.sample(position);
    float f = clamp(freshness, 0.0, 1.0);
    half4 right = layer.sample(position + float2(0.6, 0.0));
    half4 left  = layer.sample(position + float2(-0.6, 0.0));
    half lum = (right.a + left.a) * half(0.5);
    half4 glow = half4(glowColor.rgb, glowColor.a * lum * half(f * 0.55));
    return half4(
        base.rgb + glow.rgb * glow.a,
        max(base.a, glow.a)
    );
}
