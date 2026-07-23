// glow — radial core + ring glow. Sets `rgb`/`a`; the backend wrapper adds the return.
// Inputs: i.uv (0..1 across the quad), i.color (tint; alpha drives intensity).
let d = length(i.uv - vec2<f32>(0.5, 0.5)) * 2.0;
let glow_core = smoothstep(1.0, 0.0, d);
let glow_ring = smoothstep(0.35, 0.0, abs(d - 0.72));
let a = clamp(glow_core * 0.5 + glow_ring, 0.0, 1.0) * i.color.a;
let rgb = i.color.rgb;
