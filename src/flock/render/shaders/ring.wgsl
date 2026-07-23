// ring — a thin antialiased ring (great for shockwaves on a growing quad).
let d = length(i.uv - vec2<f32>(0.5, 0.5)) * 2.0;
let a = smoothstep(0.10, 0.0, abs(d - 0.85)) * i.color.a;
let rgb = i.color.rgb;
