# Multi-window demo (native): two OS windows sharing one GPU device. A camera bound to each
# window shows the SAME world from a different zoom/clear color — one device, two swapchains.
#
#   crystal run examples/multi_window.cr
#   WGPU_FRAMES=30 crystal run examples/multi_window.cr   # headless smoke (both windows)
#
# Close the second window on its own to close just it (the app keeps running); close the main
# window to quit.
require "../src/flock/gpu"

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — main window", 640, 480))
app.add_plugin(Flock::MultiWindowPlugin.new) # after the render plugin

app.add_startup do |world, cmd|
  win2 = world.resource(Flock::Windows).open("Flock — second window", 420, 420)

  # Primary camera (window 0).
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.05, 0.06, 0.10)))
  # Secondary camera → second window: zoomed in, different clear color.
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.10, 0.05, 0.05),
    zoom: 2.0f32, window: win2.slot))

  # One sprite, seen in BOTH windows.
  cmd.spawn(Flock::Transform2D.at(0, 0), Flock::Sprite.new(Flock::Vec2.new(90, 90), Flock::Color::WHITE))
end

# Spin the sprite so both windows show live, independent frames.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  t = world.resource(Flock::Time).elapsed.to_f32
  world.query(Flock::Transform2D, Flock::Sprite) do |_e, tf, _sp|
    tf.value.position = Flock::Vec2.new(Math.cos(t) * 120.0f32, Math.sin(t) * 80.0f32)
  end
end

app.run
