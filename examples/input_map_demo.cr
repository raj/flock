# InputMap demo (windowed): a square driven by logical actions instead of raw keys — arrows
# (or WASD) move it, Space toggles its color. Same map/query code runs on native + web.
#   crystal run examples/input_map_demo.cr
#   WGPU_FRAMES=120 crystal run examples/input_map_demo.cr
require "../src/flock/gpu"

enum Act
  MoveX
  MoveY
  Toggle
end

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — input action-mapping", 800, 600))

app.add_startup do |world, cmd|
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.05, 0.06, 0.09)))
  cmd.spawn(Flock::Transform2D.at(0, 0), Flock::Sprite.new(Flock::Vec2.new(60, 60), Flock::Color::WHITE))

  map = Flock::InputMap(Act).new
  map.bind_axis(Act::MoveX, Flock::Key::Left, Flock::Key::Right)
  map.bind_axis(Act::MoveY, Flock::Key::Down, Flock::Key::Up)
  map.bind(Act::MoveX, Flock::Key::A) # extra WASD binds are harmless alongside the axis
  map.bind(Act::Toggle, Flock::Key::Space)
  world.insert_resource(map)
end

# Feed the map once per frame from the unified Flock::Input (this is the only backend touch).
app.add_system(Flock::Schedule::First) do |world, _cmd|
  world.resource(Flock::InputMap(Act)).update(world.resource(Flock::Input))
end

app.add_system(Flock::Schedule::Update) do |world, _cmd|
  map = world.resource(Flock::InputMap(Act))
  dt = world.resource(Flock::Time).delta.to_f32
  speed = 260.0f32
  world.query(Flock::Transform2D, Flock::Sprite) do |_e, tf, sp|
    p = tf.value.position
    tf.value.position = Flock::Vec2.new(p.x + map.axis(Act::MoveX) * speed * dt,
      p.y + map.axis(Act::MoveY) * speed * dt)
    if map.just_pressed?(Act::Toggle)
      c = sp.value.color
      sp.value.color = c.r > 0.5f32 ? Flock::Color.new(0.3, 0.9, 1.0) : Flock::Color::WHITE
    end
  end
end

app.run
