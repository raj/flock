# 3D: a spinning lit cube viewed through a Camera3D (perspective + depth buffer).
#   crystal run examples/cube3d.cr
#   WGPU_FRAMES=5 crystal run examples/cube3d.cr   # headless smoke
require "../src/flock/gpu"

struct Spin
  include Flock::Component
  property speed : Flock::Vec3

  def initialize(@speed : Flock::Vec3)
  end
end

app = Flock::App.new
app.add_plugin(Flock::WindowPlugin.new("Flock — 3D cube", 800, 600))

app.add_startup do |world, cmd|
  gpu = world.resource(Flock::GpuContext)
  world.insert_resource(Flock::Renderer3D.new(gpu))
  cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.9, 0.5, 0.2))

  cmd.spawn(Flock::Camera3D.new(
    position: Flock::Vec3.new(2.5, 2.0, 3.0),
    clear_color: Flock::Color.new(0.05, 0.06, 0.10)))
  cmd.spawn(Flock::Transform3D.new, Flock::MeshRenderer.new(cube), Spin.new(Flock::Vec3.new(0.6, 1.0, 0.0)))
end

# Spin the cubes.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  dt = world.resource(Flock::Time).delta.to_f32
  world.query(Flock::Transform3D, Spin) do |_e, tf, sp|
    r = tf.value.rotation
    s = sp.value.speed
    tf.value.rotation = Flock::Vec3.new(r.x + s.x * dt, r.y + s.y * dt, r.z + s.z * dt)
  end
end

app.add_system(Flock::Schedule::Render) do |world, _cmd|
  world.resource(Flock::Renderer3D).render(world)
end

app.run
