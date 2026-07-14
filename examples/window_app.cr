# Exemple : fenêtre + caméra 2D + quelques sprites colorés, via l'API App/plugins.
#   crystal run examples/window_app.cr
#   WGPU_FRAMES=5 crystal run examples/window_app.cr   # headless smoke
require "../src/flock/gpu"

app = Flock::App.new
app.add_plugin(Flock::WindowPlugin.new("Flock — window", 800, 600))
app.add_plugin(Flock::RenderPlugin.new)

app.add_startup do |_world, cmd|
  # Caméra plein écran centrée sur l'origine (le monde est en pixels, origine = centre).
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.08, 0.09, 0.13)))

  cmd.spawn(
    Flock::Transform2D.at(0, 0),
    Flock::Sprite.new(Flock::Vec2.new(220, 140), Flock::Color::RED),
  )
  cmd.spawn(
    Flock::Transform2D.new(Flock::Vec2.new(180, 90), rotation: 0.3f32),
    Flock::Sprite.new(Flock::Vec2.new(90, 90), Flock::Color.new(0.2, 0.8, 0.35)),
  )
  cmd.spawn(
    Flock::Transform2D.at(-200, -120),
    Flock::Sprite.new(Flock::Vec2.new(120, 120), Flock::Color.new(0.3, 0.5, 1.0)),
  )
end

app.run
