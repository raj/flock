// invader_a — classic 11x8 space-invader silhouette (frame A). The quad UV is diced
// into an 11x8 grid; each row is an 11-bit mask (MSB = leftmost column). Lit cells take
// the tint color, empty cells are transparent.
let cell = floor(i.uv * vec2<f32>(11.0, 8.0));
let col = u32(clamp(cell.x, 0.0, 10.0));
let row = u32(clamp(cell.y, 0.0, 7.0));
var mask = array<u32, 8>(
  0x104u, 0x088u, 0x1FCu, 0x376u, 0x7FFu, 0x5FDu, 0x505u, 0x0D8u
);
let on = (mask[row] >> (10u - col)) & 1u;
let a = f32(on) * i.color.a;
let rgb = i.color.rgb;
