// invader_a — classic 11x8 space-invader silhouette (frame A). See the .wgsl twin.
vec2 cell = floor(vUv * vec2(11.0, 8.0));
int col = int(clamp(cell.x, 0.0, 10.0));
int row = int(clamp(cell.y, 0.0, 7.0));
uint mask[8] = uint[8](
  0x104u, 0x088u, 0x1FCu, 0x376u, 0x7FFu, 0x5FDu, 0x505u, 0x0D8u
);
uint on = (mask[row] >> uint(10 - col)) & 1u;
float a = float(on) * vColor.a;
vec3 rgb = vColor.rgb;
