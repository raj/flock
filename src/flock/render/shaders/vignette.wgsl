// vignette — darkens toward the edges (draw as a fullscreen tinted overlay).
let d = length(i.uv - vec2<f32>(0.5, 0.5));
let a = smoothstep(0.35, 0.75, d) * i.color.a;
let rgb = i.color.rgb;
