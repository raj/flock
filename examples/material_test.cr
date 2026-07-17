# Per-sprite material test (headless, readback).
#
# Renders two sprites: one with the default material (red tint) and one with a
# custom SpriteMaterial whose fragment shader forces blue. Reads back both regions
# and asserts they differ — proving per-sprite material dispatch works.
#
#   crystal run examples/material_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64

# Custom sprite material: same instancing convention (group0 = view-proj + instances),
# but the fragment ignores the texture/tint and outputs a constant blue.
CUSTOM_WGSL = <<-SHADER
struct Instance { model : mat4x4<f32>, color : vec4<f32>, uv : vec4<f32> };
@group(0) @binding(0) var<uniform> u_vp : mat4x4<f32>;
@group(0) @binding(1) var<storage, read> instances : array<Instance>;
const QUAD = array<vec2<f32>, 6>(
  vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, -0.5), vec2<f32>(0.5, 0.5),
  vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, 0.5), vec2<f32>(-0.5, 0.5));
@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> @builtin(position) vec4<f32> {
  return u_vp * instances[ii].model * vec4<f32>(QUAD[vi], 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4<f32> {
  return vec4<f32>(0.2, 0.4, 1.0, 1.0);
}
SHADER

gpu = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer2D.new(gpu)
blue_material = renderer.build_material(CUSTOM_WGSL)

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))

# Left: default material, red tint.
a = world.spawn
world.add(a, Flock::Transform2D.at(-16, 0))
world.add(a, Flock::Sprite.new(Flock::Vec2.new(24, 24), Flock::Color::RED))

# Right: custom material (forces blue).
b = world.spawn
world.add(b, Flock::Transform2D.at(16, 0))
world.add(b, Flock::Sprite.new(Flock::Vec2.new(24, 24), Flock::Color::WHITE, material: blue_material))

# --- Offscreen target + render ---
target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(target.view, SIZE.to_u32, SIZE.to_u32, world)
px = target.read

left = px.rgb(16, 32)  # default sprite (red)
right = px.rgb(48, 32) # custom material (blue)

puts "left (default) = #{left}"
puts "right (custom) = #{right}"

ok = left[0] > 200 && left[2] < 60 && # left red
     right[2] > 200 && right[0] < 90  # right blue (custom shader)

Flock.release_all(target, renderer, gpu)

puts ok ? "✅ per-sprite material OK" : "❌ materials not applied as expected"
exit(ok ? 0 : 1)
