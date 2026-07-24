# Mouse cursor control demo (native): relative mode (FPS mouse-look), cursor hide/show, and
# window grab/capture. Space toggles relative mode (hide + deltas); G toggles grab (confine).
# The square follows accumulated mouse motion.
#
#   crystal run examples/mouse_cursor.cr
#   WGPU_FRAMES=30 crystal run examples/mouse_cursor.cr   # headless smoke (exercises the API)
require "../src/flock/gpu"

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — mouse cursor", 640, 480))

app.add_startup do |world, cmd|
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.05, 0.06, 0.10)))
  cmd.spawn(Flock::Transform2D.at(0, 0), Flock::Sprite.new(Flock::Vec2.new(40, 40), Flock::Color.new(0.3, 0.9, 1.0)))
  inp = world.resource(Flock::Input)
  inp.relative_mouse_mode = true # start in mouse-look (hides + grabs + delta motion)
end

app.add_system(Flock::Schedule::Update) do |world, _cmd|
  inp = world.resource(Flock::Input)

  # Space: toggle relative (mouse-look) mode. G: toggle plain grab (confine, cursor visible).
  inp.relative_mouse_mode = !inp.relative_mouse_mode? if inp.just_pressed?(Flock::Key::Space)
  if inp.just_pressed?(Flock::Key::G)
    grab = !inp.grab_mouse?
    inp.grab_mouse = grab
    grab ? inp.hide_cursor : inp.show_cursor
  end

  # Mouse-look: move the square by accumulated relative motion.
  d = inp.mouse_delta
  world.query(Flock::Transform2D, Flock::Sprite) do |_e, tf, _sp|
    p = tf.value.position
    tf.value.position = Flock::Vec2.new((p.x + d.x).clamp(-300.0f32, 300.0f32),
      (p.y - d.y).clamp(-200.0f32, 200.0f32))
  end
end

app.run
