// disc — an antialiased filled circle (turns a quad sprite into a clean dot).
let d = length(i.uv - vec2<f32>(0.5, 0.5)) * 2.0;
let a = (1.0 - smoothstep(0.96, 1.0, d)) * i.color.a;
let rgb = i.color.rgb;
