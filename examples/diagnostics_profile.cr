# Diagnostics with per-system timings + frame-time sparkline (console).
#   crystal run examples/diagnostics_profile.cr
#   WGPU_FRAMES=40 crystal run examples/diagnostics_profile.cr   # headless smoke
require "../src/flock/gpu"

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — diagnostics", 320, 240))
app.add_plugin(Flock::DiagnosticsPlugin.new(profile: true, interval: 0.05)) # per-system + sparkline

app.add_startup do |_world, cmd|
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.05, 0.06, 0.10)))
  cmd.spawn(Flock::Transform2D.at(0, 0), Flock::Sprite.new(Flock::Vec2.new(30, 30), Flock::Color::WHITE))
end

app.add_system(Flock::Schedule::Update, label: :spin) do |world, _cmd|
  t = world.resource(Flock::Time).elapsed.to_f32
  world.query(Flock::Transform2D, Flock::Sprite) do |_e, tf, _sp|
    tf.value.position = Flock::Vec2.new(Math.cos(t) * 60.0f32, Math.sin(t) * 40.0f32)
  end
end

# A deliberately heavier system so the per-system report has an obvious hot spot.
app.add_system(Flock::Schedule::Update, label: :busy) do |_world, _cmd|
  s = 0.0
  60_000.times { |i| s += Math.sqrt(i.to_f + 1.0) }
end

app.run
