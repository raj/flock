# Diagnostics overlay demo: drop Flock::DiagnosticsPlugin into any project to monitor it.
# It prints FPS / frame time / sprite & triangle counts to the console, and (with overlay: true)
# draws them in the top-left corner. Read Flock::Diagnostics yourself for a custom HUD.
#
#   crystal run examples/diagnostics_demo.cr
#   WGPU_FRAMES=200 crystal run examples/diagnostics_demo.cr   # headless smoke
require "../src/flock/gpu"

def setup(world : Flock::World, cmd : Flock::Commands)
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.08, 0.09, 0.12)))
  # A field of drifting sprites to give the monitor something to count.
  20.times do |i|
    x = (i % 5) * 120.0f32 - 240.0f32
    y = (i // 5) * 120.0f32 - 180.0f32
    cmd.spawn(
      Flock::Transform2D.new(position: Flock::Vec2.new(x, y)),
      Flock::Sprite.new(Flock::Vec2.new(80, 80),
        Flock::Color.new(0.3 + 0.03 * i, 0.5, 0.9 - 0.02 * i)))
  end
end

app = Flock::App.new
app.add_plugin(Flock::WindowPlugin.new("Flock — Diagnostics", 800, 600))
app.add_plugin(Flock::InputPlugin.new)
app.add_plugin(Flock::RenderPlugin.new)
# The monitor. `interval` is small here so the headless smoke run prints a line or two.
app.add_plugin(Flock::DiagnosticsPlugin.new(overlay: true, interval: 0.1))

app.add_startup(&->setup(Flock::World, Flock::Commands))
app.run
