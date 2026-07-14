# Mouse demo: a square follows the cursor (world coordinates) and turns red on
# left click.
#   crystal run examples/mouse_demo.cr
require "../src/flock/gpu"

struct Cursor
  include Flock::Component
end

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — mouse", 800, 600))

app.add_startup do |_world, cmd|
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.1, 0.1, 0.15)))
  cmd.spawn(Cursor.new, Flock::Transform2D.at(0, 0),
    Flock::Sprite.new(Flock::Vec2.new(40, 40), Flock::Color::WHITE))
end

app.add_system(Flock::Schedule::Update) do |world, _cmd|
  input = world.resource(Flock::Input)
  gpu = world.resource(Flock::GpuContext)

  cam = Flock::Camera2D.new
  world.query(Flock::Camera2D) { |_e, c| cam = c.value }
  world_pos = cam.screen_to_world(input.mouse_position, gpu.width.to_f32, gpu.height.to_f32)
  down = input.mouse_pressed?(Flock::MouseButton::Left)

  world.query(Cursor, Flock::Transform2D, Flock::Sprite) do |_e, _c, tf, sp|
    tf.value.position = world_pos
    sp.value.color = down ? Flock::Color::RED : Flock::Color::WHITE
  end
end

app.run
