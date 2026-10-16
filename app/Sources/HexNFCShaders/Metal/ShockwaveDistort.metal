#include <metal_stdlib>
using namespace metal;

// Invisible radial shockwave. A single ring expands from `origin` and refracts
// whatever is beneath it (the scan UI + the rainbow grid) — it adds no colour
// of its own, so it reads purely as a pressure wave punching outward on a
// successful scan. Applied via `distortionEffect`: the function returns the
// source position to sample, so a positive radial push pulls neighbouring
// pixels along the wavefront.
//
// `amplitude` is a master gain (1.0 = full); the internal scale maps it to the
// host's `maxSampleOffset` budget. Energy dissipates as the ring grows, so the
// displacement is gone by the time the ring reaches the edge.

[[stitchable]] float2 hexShockwaveDistort(
    float2 position,
    float2 size,
    float2 origin,
    float progress,
    float amplitude
) {
    float p = clamp(progress, 0.0, 1.0);
    float2 sz = max(size, float2(1.0));
    float maxR = length(sz) * 0.62;               // reach just past the far edge

    float2 delta = position - origin;
    float d = length(delta);
    if (d < 0.0001) { return position; }
    float2 dir = delta / d;

    float ringR = p * maxR;
    float ringWidth = maxR * 0.16;

    // A single signed sine lobe localised to the expanding ring: pixels just
    // inside/outside the crest are pushed in opposite directions, so the ring
    // both compresses and stretches the scene as it passes.
    float x = (d - ringR) / ringWidth;            // 0 at the crest
    float window = exp(-x * x);                   // soft falloff around the ring
    float wave = sin(x * 3.14159265) * window;

    float decay = 1.0 - p;                        // strong early, gone by the end
    float push = wave * amplitude * 26.0 * decay;

    return position + dir * push;
}
