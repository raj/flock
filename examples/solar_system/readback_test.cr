# Headless readback test for the solar-system 3D path: renders the sun sphere with
# a custom Material3D (emissive shader using the shared globals binding) into an
# offscreen target and asserts the center is warm (non-black, red>blue) while a
# corner stays background. Proves Renderer3D custom materials + sphere mesh work.
#
#   crystal run examples/solar_system/readback_test.cr   # exit 0 if OK
require "../../src/flock/gpu"

SIZE = 128

SUN_WGSL = <<-WGSL
struct Camera { view_proj : mat4x4<f32> };
struct Globals { time : f32 };
@group(0) @binding(0) var<uniform> cam : Camera;
@group(0) @binding(1) var<storage, read> models : array<mat4x4<f32>>;
@group(0) @binding(2) var<uniform> globals : Globals;
struct VSOut { @builtin(position) clip : vec4<f32>, @location(0) lpos : vec3<f32> };
@vertex
fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
           @location(2) col : vec3<f32>, @builtin(instance_index) ii : u32) -> VSOut {
  var out : VSOut;
  out.clip = cam.view_proj * models[ii] * vec4<f32>(pos, 1.0);
  out.lpos = pos;
  return out;
}
@fragment
fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
  // globals.time is 0 here; produce a stable warm color.
  let flick = 0.5 + 0.5 * sin(in.lpos.x * 7.0 + globals.time);
  return vec4<f32>(mix(vec3<f32>(0.95,0.35,0.05), vec3<f32>(1.0,0.9,0.4), flick), 1.0);
}
WGSL

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
sun_mat = renderer.build_material(SUN_WGSL)
sun = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 32, rings: 16, color: Flock::Color.new(1.0, 0.8, 0.3))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(0.0, 0.0, 3.0), clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sun, sun_mat))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
px = target.read

center = px.rgb(SIZE // 2, SIZE // 2)
corner = px.rgb(2, 2)

puts "center = #{center}"
puts "corner = #{corner}"

# Center: emissive sun (warm, red>blue, bright). Corner: black background.
ok = center[0] > 80 && center[0] > center[2] &&
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20

target.release
sun.release
renderer.release
gpu.release

puts ok ? "✅ solar-system 3D material OK" : "❌ sun not rendered as expected"
exit(ok ? 0 : 1)
