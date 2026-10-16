#include <metal_stdlib>
using namespace metal;

// The signature 3-slice hexagon mask reveal used by HexTransition. Three
// independent stage values 0→1 reveal the outer frame, caret, and inverted
// caret in turn.

inline float hs_hex_sdf(float2 p, float r) {
    p = abs(p);
    return max(dot(p, normalize(float2(0.866025, 0.5))), p.y) - r;
}

[[stitchable]] half4 hexSliceMask(
    float2 position,
    half4 color,
    float2 origin,
    float radius,
    float stageFrame,
    float stageCaret,
    float stageInvCaret
) {
    float2 p = position - origin;
    float frame = step(hs_hex_sdf(p, radius), 0.0);
    // bool isUpper = p.y >= 0.0;
    float caret    = step(0.0, p.y) * frame;
    float invCaret = step(0.0, -p.y) * frame;

    float reveal =
        frame    * clamp(stageFrame,    0.0, 1.0) +
        caret    * clamp(stageCaret,    0.0, 1.0) +
        invCaret * clamp(stageInvCaret, 0.0, 1.0);
    reveal = clamp(reveal, 0.0, 1.0);

    return half4(color.rgb, color.a * half(reveal));
}
