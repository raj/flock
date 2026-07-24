# Post-processing demo (windowed): a few bright neon quads on a dark background with a Bloom
# + Vignette stack, so the shapes glow and the frame edges darken.
#
#   crystal run examples/postfx_demo.cr
#   WGPU_FRAMES=120 crystal run examples/postfx_demo.cr   # headless smoke
require "../src/flock/gpu"

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — post-fx (bloom + vignette)", 900, 600))
app.add_plugin(Flock::PostProcessPlugin.new(
  Flock::Bloom.new(threshold: 0.6f32, intensity: 1.3f32),
  Flock::Vignette.new(intensity: 0.55f32, radius: 0.85f32),
))

app.add_startup do |_world, cmd|
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.02, 0.02, 0.05)))
  neon = [
    Flock::Color.new(1.0, 0.2, 0.6),
    Flock::Color.new(0.2, 1.0, 0.8),
    Flock::Color.new(1.0, 0.9, 0.2),
    Flock::Color.new(0.4, 0.6, 1.0),
  ]
  neon.each_with_index do |c, i|
    x = (i - 1.5f32) * 150.0f32
    cmd.spawn(Flock::Transform2D.at(x, 0.0f32), Flock::Sprite.new(Flock::Vec2.new(70, 70), c))
  end
end

# Gently orbit the quads so the glow moves.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  t = world.resource(Flock::Time).elapsed.to_f32
  i = 0
  world.query(Flock::Transform2D, Flock::Sprite) do |_e, tf, _sp|
    ang = t + i.to_f32 * 1.5f32
    tf.value.position = Flock::Vec2.new((i - 1.5f32) * 150.0f32, Math.sin(ang) * 90.0f32)
    i += 1
  end
end

app.run
