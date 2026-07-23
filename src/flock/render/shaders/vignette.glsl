// vignette — darkens toward the edges (draw as a fullscreen tinted overlay).
float d = length(vUv - vec2(0.5));
float a = smoothstep(0.35, 0.75, d) * vColor.a;
vec3 rgb = vColor.rgb;
