# Custom "wgpu-style" shader: a fullscreen plasma effect driven by a
# uniform (time + aspect), via Flock::Shader + Flock::Material.
#   crystal run examples/custom_shader.cr
#   WGPU_FRAMES=5 crystal run examples/custom_shader.cr
require "../src/flock/gpu"

def setup(world : Flock::World, cmd : Flock::Commands)
  gpu = world.resource(Flock::GpuContext)
  shader = Flock::Shader.from_file(gpu, "examples/assets/shaders/plasma.wgsl")
  world.insert_resource(Flock::Material.new(gpu, shader))
end

def render_plasma(world : Flock::World, cmd : Flock::Commands)
  gpu = world.resource(Flock::GpuContext)
  mat = world.resource(Flock::Material)
  t = world.resource(Flock::Time).elapsed.to_f32
  mat.set_uniform([t, gpu.aspect, 0.0f32, 0.0f32])
  mat.render(gpu)
end

app = Flock::App.new
app.add_plugin(Flock::WindowPlugin.new("Flock — custom shader", 800, 600))

app.add_startup(&->setup(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Render, &->render_plasma(Flock::World, Flock::Commands))

app.run
