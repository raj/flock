# Custom "wgpu-style" shader: a fullscreen plasma effect driven by a
# uniform (time + aspect), via Flock::Shader + Flock::Material.
#   crystal run examples/custom_shader.cr
#   WGPU_FRAMES=5 crystal run examples/custom_shader.cr
require "../src/flock/gpu"

WGSL = <<-SHADER
@group(0) @binding(0) var<uniform> u : vec4<f32>; // x=time, y=aspect

@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> @builtin(position) vec4<f32> {
  var p = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
  return vec4<f32>(p[vi], 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) frag : vec4<f32>) -> @location(0) vec4<f32> {
  let t = u.x;
  let uv = frag.xy / 300.0;
  let c = 0.5 + 0.5 * sin(vec3<f32>(
    uv.x * 3.0 + t,
    uv.y * 3.0 + t * 1.3,
    (uv.x + uv.y) * 3.0 + t * 0.7));
  return vec4<f32>(c, 1.0);
}
SHADER

app = Flock::App.new
app.add_plugin(Flock::WindowPlugin.new("Flock — custom shader", 800, 600))

app.add_startup do |world, _cmd|
  gpu = world.resource(Flock::GpuContext)
  world.insert_resource(Flock::Material.new(gpu, Flock::Shader.from_source(gpu, WGSL)))
end

app.add_system(Flock::Schedule::Render) do |world, _cmd|
  gpu = world.resource(Flock::GpuContext)
  mat = world.resource(Flock::Material)
  t = world.resource(Flock::Time).elapsed.to_f32
  mat.set_uniform([t, gpu.aspect, 0.0f32, 0.0f32])
  mat.render(gpu)
end

app.run
