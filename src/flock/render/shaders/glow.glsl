// glow — radial core + ring glow. Sets `rgb`/`a`; the backend wrapper adds the output.
// Inputs: vUv (0..1 across the quad), vColor (tint; alpha drives intensity).
float d = length(vUv - vec2(0.5)) * 2.0;
float glowCore = smoothstep(1.0, 0.0, d);
float glowRing = smoothstep(0.35, 0.0, abs(d - 0.72));
float a = clamp(glowCore * 0.5 + glowRing, 0.0, 1.0) * vColor.a;
vec3 rgb = vColor.rgb;
