// invader_b — classic space-invader silhouette (frame B: legs/arms in the other pose).
// Toggle between _a and _b each march step for the iconic 2-frame wiggle.
let cell = floor(i.uv * vec2<f32>(11.0, 8.0));
let col = u32(clamp(cell.x, 0.0, 10.0));
let row = u32(clamp(cell.y, 0.0, 7.0));
var mask = array<u32, 8>(
  0x104u, 0x489u, 0x5FDu, 0x777u, 0x7FFu, 0x3FEu, 0x104u, 0x202u
);
let on = (mask[row] >> (10u - col)) & 1u;
let a = f32(on) * i.color.a;
let rgb = i.color.rgb;
