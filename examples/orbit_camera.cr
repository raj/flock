# Orbit-camera demo: drag the left mouse button to orbit a small scene, scroll to zoom.
# Shows Flock::OrbitCamera driving a Camera3D from mouse input. A FlyCamera is wired the
# same way (WASD + mouse look) — see the commented block at the bottom.
#
#   crystal run examples/orbit_camera.cr
#   WGPU_FRAMES=120 crystal run examples/orbit_camera.cr   # headless smoke
require "../src/flock/gpu"

app = Flock::App.new
app.add_plugin(Flock::WindowPlugin.new("Flock — Orbit Camera", 900, 650))
app.add_plugin(Flock::InputPlugin.new)
app.add_plugin(Flock::Render3DPlugin.new) # MSAA 4x by default

orbit = Flock::OrbitCamera.new(target: Flock::Vec3.new(0, 0, 0), distance: 8.0f32, yaw: 0.5f32, pitch: 0.4f32)
last_mouse = Flock::Vec2.new

app.add_startup do |world, cmd|
  # A ground slab + a few cubes to look at.
  gpu = world.resource(Flock::GpuContext)
  ground = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.4, 0.42, 0.5))
  cube = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.8, 0.5, 0.3))
  cmd.spawn(Flock::Transform3D.new(position: Flock::Vec3.new(0, -1, 0), scale: Flock::Vec3.new(10, 0.4, 10)),
    Flock::MeshRenderer.new(ground))
  {-2.5f32, 0.0f32, 2.5f32}.each do |x|
    cmd.spawn(Flock::Transform3D.new(position: Flock::Vec3.new(x, 0, 0)), Flock::MeshRenderer.new(cube))
  end
  # A shadow-casting directional light.
  cmd.spawn(Flock::Transform3D.new,
    Flock::Light.directional(Flock::Vec3.new(-0.5, -1.0, -0.3), Flock::Color::WHITE, 1.4, casts_shadows: true))
  cmd.spawn(Flock::Camera3D.new(clear_color: Flock::Color.new(0.05, 0.06, 0.09)))
end

app.add_system(Flock::Schedule::Update) do |world, _cmd|
  input = world.resource(Flock::Input)
  m = input.mouse_position
  if input.mouse_pressed?(Flock::MouseButton::Left)
    orbit.rotate((m.x - last_mouse.x) * 0.008, (m.y - last_mouse.y) * 0.008)
  end
  last_mouse = m
  wheel = input.mouse_wheel.y
  orbit.dolly(1.0f32 - wheel * 0.1f32) if wheel != 0.0f32
  world.query(Flock::Camera3D) { |_e, cam| orbit.apply(cam) }
end

app.run

# FlyCamera variant (first-person WASD + mouse look):
#
#   fly = Flock::FlyCamera.new(position: Flock::Vec3.new(0, 1, 8))
#   app.add_system(Flock::Schedule::Update) do |world, _cmd|
#     input = world.resource(Flock::Input)
#     dt = world.resource(Flock::Time).delta.to_f32
#     fwd = (input.pressed?(Flock::Key::W) ? 1.0f32 : 0.0f32) - (input.pressed?(Flock::Key::S) ? 1.0f32 : 0.0f32)
#     rgt = (input.pressed?(Flock::Key::D) ? 1.0f32 : 0.0f32) - (input.pressed?(Flock::Key::A) ? 1.0f32 : 0.0f32)
#     fly.move(fwd, rgt, 0.0, dt)
#     world.query(Flock::Camera3D) { |_e, cam| fly.apply(cam) }
#   end
