# Gizmos debug-draw demo (windowed): immediate-mode lines/shapes re-issued each frame.
#   crystal run examples/gizmos_demo.cr
#   WGPU_FRAMES=60 crystal run examples/gizmos_demo.cr
require "../src/flock/gpu"

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — gizmos", 640, 480))
app.add_plugin(Flock::GizmosPlugin.new) # after the render plugin

app.add_startup do |_world, cmd|
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.05, 0.06, 0.10)))
end

app.add_system(Flock::Schedule::Update) do |world, _cmd|
  g = world.resource(Flock::Gizmos)
  t = world.resource(Flock::Time).elapsed.to_f32
  # A spinning ray, a pulsing circle, a static rect + origin cross — all redrawn each frame.
  g.ray(Flock::Vec2.new(0, 0), Flock::Vec2.new(Math.cos(t) * 150.0f32, Math.sin(t) * 150.0f32), Flock::Color.new(1.0, 0.9, 0.2))
  g.circle(Flock::Vec2.new(0, 0), 60.0f32 + Math.sin(t * 2.0f32) * 20.0f32, Flock::Color.new(0.3, 0.9, 1.0))
  g.rect(Flock::Vec2.new(0, 0), Flock::Vec2.new(260, 200), Flock::Color.new(0.6, 0.6, 0.7))
  g.cross(Flock::Vec2.new(0, 0), 16.0, Flock::Color::RED)
end

app.run
