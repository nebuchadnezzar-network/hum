/// The visualiser shader, compiled at runtime.
///
/// Kept as a string rather than a `.metal` file so the package needs no resource
/// bundle: a bare SwiftPM executable can then be copied anywhere and still work,
/// which matters for `brew install`. One-off compile cost is a few tens of ms,
/// paid only when the window is first opened.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float barCount;
    float time;
    float level;
    float padding;
};

struct VertexOut {
    float4 position [[position]];
    float2 local;
    float magnitude;
    float alpha;
};

// One quad per bar, drawn twice: upright, then mirrored below the baseline as a
// dimmer reflection. Instances [0, barCount) are the bars; the rest are the
// reflection, which is why instanceCount is doubled at the draw call.
vertex VertexOut barVertex(uint vertexID [[vertex_id]],
                           uint instanceID [[instance_id]],
                           constant float *magnitudes [[buffer(0)]],
                           constant Uniforms &uniforms [[buffer(1)]])
{
    const float2 corners[6] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
        float2(1.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0)
    };
    float2 corner = corners[vertexID];

    uint count = uint(uniforms.barCount);
    bool isReflection = instanceID >= count;
    uint bar = isReflection ? instanceID - count : instanceID;

    float slot = 2.0 / uniforms.barCount;
    float gap = slot * 0.22;
    float width = slot - gap;
    float x = -1.0 + float(bar) * slot + gap * 0.5;

    float magnitude = magnitudes[bar];
    // Floor the height so an idle bar still shows a baseline glow rather than
    // disappearing — a row of nothing reads as "broken", not "quiet".
    float height = max(magnitude, 0.006) * 1.28;
    float baseline = -0.30;

    VertexOut out;
    float y = isReflection
        ? baseline - corner.y * height * 0.45
        : baseline + corner.y * height;
    out.position = float4(x + corner.x * width, y, 0.0, 1.0);
    out.local = corner;
    out.magnitude = magnitude;
    out.alpha = isReflection ? 0.22 : 1.0;
    return out;
}

fragment float4 barFragment(VertexOut in [[stage_in]])
{
    // hum palette: amber-dark at the base, amber at the peak.
    const float3 amberDark = float3(0.722, 0.439, 0.039);
    const float3 amber = float3(0.949, 0.663, 0.231);
    const float3 hot = float3(1.0, 0.85, 0.55);

    float t = in.local.y;
    float3 color = mix(amberDark, amber, t);
    // Loud bars bloom towards white at the tip; quiet ones stay amber.
    color = mix(color, hot, smoothstep(0.75, 1.0, t) * in.magnitude);

    // Soft vertical edges so bars glow instead of looking like a bar chart.
    float edge = smoothstep(0.0, 0.16, in.local.x) * smoothstep(0.0, 0.16, 1.0 - in.local.x);
    float alpha = in.alpha * (0.45 + 0.55 * edge);

    return float4(color * alpha, alpha);
}

// Full-screen pass: a faint amber wash at the bottom that breathes with the
// overall level, so the window feels alive during quiet passages.
vertex float4 backdropVertex(uint vertexID [[vertex_id]])
{
    const float2 corners[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0)
    };
    return float4(corners[vertexID], 0.0, 1.0);
}

fragment float4 backdropFragment(float4 position [[position]],
                                 constant Uniforms &uniforms [[buffer(1)]],
                                 constant float2 &resolution [[buffer(2)]])
{
    float2 uv = position.xy / resolution;
    float fromBottom = 1.0 - uv.y;
    float glow = pow(max(fromBottom - 0.25, 0.0) / 0.75, 2.2);
    float amount = glow * (0.05 + 0.13 * uniforms.level);
    const float3 amber = float3(0.949, 0.663, 0.231);
    return float4(amber * amount, amount);
}
"""
