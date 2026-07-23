// ring — a thin antialiased ring (great for shockwaves on a growing quad).
float d = length(vUv - vec2(0.5)) * 2.0;
float a = smoothstep(0.10, 0.0, abs(d - 0.85)) * vColor.a;
vec3 rgb = vColor.rgb;
