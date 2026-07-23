// disc — an antialiased filled circle (turns a quad sprite into a clean dot).
float d = length(vUv - vec2(0.5)) * 2.0;
float a = (1.0 - smoothstep(0.96, 1.0, d)) * vColor.a;
vec3 rgb = vColor.rgb;
