#include <metal_stdlib>
using namespace metal;

// Passport-unlock reveal. A field of bright vertical lines climbs from the
// bottom of the screen; as the leading front passes ~60% of the way up it
// diverges into concentric rainbow circles that ring the Hex logo. The field
// brightens as the build nears completion, flares in a white-hot burst, then
// slides down and fades away, the same recede feel as the scan-success sweep
// grid (`hexRainbowSweepGrid`).
//
// Applied via `colorEffect` to an opaque full-bleed layer; the shader returns
// transparent off its contributing regions so the host can bloom it additively
// (`plusLighter`) over the result sheet without the fill ever showing through.
// Colours are generated procedurally, so no brand-token colour is imported here,
// consistent with the rest of the shader library.
//
//  * `front`:     leading edge rising from the bottom to the logo line, 0..1.
//  * `intensity`: master gain, grows as the unlock nears completion, 0..1.
//  * `burst`:     white-hot flash from the logo at the crescendo, 0..1.
//  * `recede`:    collapse: slides the field down and fades it, 0..1.
//  * `logoY`:     y (points) of the divergence / logo-ring centre.
//  * `flow`:      advances continuously; flows the spectrum and expands the rings.

constant float PR_TAU = 6.28318530718;

// HSV->RGB, `h` in turns. Local copy: shaders don't #include `Common.metal`.
inline float3 pr_hsv(float h, float s, float v) {
    float3 p = abs(fract(float3(h) + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
    float3 rgb = clamp(p - 1.0, 0.0, 1.0);
    rgb = rgb * rgb * (3.0 - 2.0 * rgb);          // smoothstep the ramp
    return v * mix(float3(1.0), rgb, s);
}

// Distance-to-nearest-gridline glow along one coordinate: a thin white-hot core
// plus a soft wide halo. Callers offset `coord` by a large positive constant so
// `fmod` stays well-defined for slightly-negative inputs (chromatic-aberration
// splits and the ring-phase subtraction can push it just under zero).
inline float pr_stripe(float coord, float cell, float coreHalf, float glowHalf) {
    float m = fmod(coord, cell);
    float d = min(m, cell - m);                   // distance to nearest line
    float core = smoothstep(coreHalf, 0.0, d);
    float glow = smoothstep(glowHalf, 0.0, d);
    return core + glow * 0.4;
}

[[stitchable]] half4 hexPassportReveal(
    float2 position,
    half4 color,
    float2 size,
    float front,
    float intensity,
    float burst,
    float recede,
    float logoY,
    float flow
) {
    float2 sz  = max(size, float2(1.0));
    float gain = clamp(intensity, 0.0, 1.0);
    float b    = clamp(burst, 0.0, 1.0);
    float rec  = clamp(recede, 0.0, 1.0);
    float f    = clamp(front, 0.0, 1.0);

    // Recede: sample the pattern shifted up by `slide`, so its features travel
    // down and off the bottom edge as `rec` -> 1, then fade out.
    float slide = rec * (sz.y * 1.2);
    float2 pos = float2(position.x, position.y - slide);
    float recFade = 1.0 - smoothstep(0.0, 0.9, rec);
    if (recFade < 0.001) { return half4(0.0h); }

    float ly = clamp(logoY, 1.0, sz.y);

    // Leading front rising from the bottom edge (f=0) to the logo line (f=1).
    float frontY = mix(sz.y, ly, f);
    // Everything below the front is "revealed"; a bright crest rides the front.
    float revealed = smoothstep(frontY - 4.0, frontY + 20.0, pos.y);
    float crest = exp(-pow((pos.y - frontY) / 15.0, 2.0));

    // Divergence weight: below the logo line the field reads as vertical lines;
    // above it, as concentric circles. A soft band centred on the logo line does
    // the hand-off ("diverge ~60% of the way up").
    float toRing = 1.0 - smoothstep(ly - 46.0, ly + 46.0, pos.y);

    // Vertical lines (lower field).
    const float cell = 40.0;
    float ca = 2.0 + 5.0 * gain;                  // chromatic-aberration split (px)
    float vR = pr_stripe(pos.x - ca + 4096.0, cell, 1.3, 8.5);
    float vG = pr_stripe(pos.x      + 4096.0, cell, 1.3, 8.5);
    float vB = pr_stripe(pos.x + ca + 4096.0, cell, 1.3, 8.5);

    float lineHue = fract(pos.x / sz.x * 0.85 + flow * 0.5);
    float3 lineTint = pr_hsv(lineHue, 0.95, 1.0);
    float lineCore = smoothstep(0.55, 1.0, vG);
    float3 lineRGB = float3(vR, vG, vB) * mix(lineTint, float3(1.0), lineCore);
    float lineMask = revealed * (1.0 - toRing);
    float3 lineCol = lineRGB * lineMask;
    lineCol += float3(1.0) * crest * revealed * (1.0 - toRing) * 0.7;   // white-hot crest

    // Concentric rings (around the logo).
    float2 d = pos - float2(sz.x * 0.5, ly);
    float r = length(d);
    float ang = atan2(d.y, d.x) / PR_TAU + 0.5;   // 0..1

    float ringGate = smoothstep(0.5, 1.0, f);      // emerge once the front passes ~60%
    const float ringSpacing = 30.0;
    float ringPhase = flow * 60.0;                 // shells expand outward
    float caR = 2.0 + 5.0 * gain;
    float sR = pr_stripe(r - ringPhase - caR + 4096.0, ringSpacing, 1.4, 8.0);
    float sG = pr_stripe(r - ringPhase       + 4096.0, ringSpacing, 1.4, 8.0);
    float sB = pr_stripe(r - ringPhase + caR + 4096.0, ringSpacing, 1.4, 8.0);
    float ringHue = fract(ang + r / sz.y * 0.5 + flow * 0.5);
    float3 ringTint = pr_hsv(ringHue, 0.95, 1.0);
    float ringCore = smoothstep(0.55, 1.0, sG);
    float3 ringRGB = float3(sR, sG, sB) * mix(ringTint, float3(1.0), ringCore);
    // Localise the rings around the logo so they "ring" it rather than tile the
    // whole screen, and bias them toward / above the logo line.
    float ringFalloff = exp(-r / (sz.y * 0.34));
    float3 ringCol = ringRGB * ringGate * ringFalloff * (0.35 + 0.65 * toRing);

    // Compose.
    float3 lit = (lineCol + ringCol) * (0.35 + 0.75 * gain);

    // Burst: a white-hot flash blooming from the logo plus an overall lift.
    float flash = b * exp(-r / (sz.y * (0.16 + 0.5 * b)));
    lit += float3(1.0) * flash * 1.8;
    lit *= (1.0 + 1.3 * b);

    lit *= recFade;

    // Straight colour + coverage alpha: transparent where dark, so the host can
    // additively (`plusLighter`) bloom it over the sheet without the fill showing.
    float a = saturate(max(lit.r, max(lit.g, lit.b)));
    return half4(half3(saturate(lit)), half(a));
}
