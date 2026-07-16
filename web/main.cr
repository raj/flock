# Flock web demo on the WebPlugins backend. Shows textured sprites (a procedural
# checkerboard), text rasterized to a texture, keyboard + Web Gamepad input, and a
# WebAudio beep — all driven by the shared App/Plugin/Schedule/ECS core in WASM.
#
# Controls: arrow keys or a gamepad's left stick move the white player; Space (or gamepad
# button 0) plays a beep. Build: web/build.sh
require "./web_backend"

WIDTH  = 800.0f32
HEIGHT = 600.0f32

struct Velocity
  include Flock::Component
  property v : Flock::Vec2

  def initialize(@v : Flock::Vec2)
  end
end

struct Player
  include Flock::Component
end

app = Flock::App.new
app.add_plugin(Flock::Web::WebPlugins.new)

app.add_startup do |_world, cmd|
  checker = Flock::Web.checkerboard # procedural texture (id)

  120.times do
    s = 16.0f32 + rand.to_f32 * 30.0f32
    cmd.spawn(
      Flock::Web::Transform2D.new(Flock::Vec2.new(rand.to_f32 * WIDTH, rand.to_f32 * HEIGHT)),
      Flock::Web::Sprite.new(Flock::Vec2.new(s, s),
        Flock::Vec3.new(0.4f32 + rand.to_f32 * 0.6f32, 0.4f32 + rand.to_f32 * 0.6f32, 0.4f32 + rand.to_f32 * 0.6f32),
        checker),
      Velocity.new(Flock::Vec2.new((rand.to_f32 - 0.5f32) * 280.0f32, (rand.to_f32 - 0.5f32) * 280.0f32)))
  end

  # Text rasterized to a texture, drawn as a (tinted) sprite.
  title = Flock::Web.make_text("FLOCK · WEB")
  cmd.spawn(
    Flock::Web::Transform2D.new(Flock::Vec2.new(WIDTH * 0.5f32 - 150.0f32, 24.0f32)),
    Flock::Web::Sprite.new(Flock::Vec2.new(300, 60), Flock::Vec3.new(0.6, 0.9, 1.0), title))

  cmd.spawn(
    Player.new,
    Flock::Web::Transform2D.new(Flock::Vec2.new(WIDTH * 0.5f32, HEIGHT * 0.5f32)),
    Flock::Web::Sprite.new(Flock::Vec2.new(44, 44), Flock::Vec3.new(1.0, 1.0, 1.0)))
end

# Bouncing checkerboard squares.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  dt = world.resource(Flock::Time).delta.to_f32
  world.query(Flock::Web::Transform2D, Velocity) do |_e, tf, vel|
    p = tf.value.position + vel.value.v * dt
    v = vel.value.v
    if p.x < 0 || p.x > WIDTH
      v = Flock::Vec2.new(-v.x, v.y); p = Flock::Vec2.new(p.x.clamp(0.0f32, WIDTH), p.y)
    end
    if p.y < 0 || p.y > HEIGHT
      v = Flock::Vec2.new(v.x, -v.y); p = Flock::Vec2.new(p.x, p.y.clamp(0.0f32, HEIGHT))
    end
    tf.value.position = p
    vel.value.v = v
  end
end

# Player: keyboard arrows + gamepad left stick.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  dt = world.resource(Flock::Time).delta.to_f32
  inp = world.resource(Flock::Web::Input)
  dx = 0.0f32; dy = 0.0f32
  dx -= 1.0f32 if inp.pressed?(Flock::Web::ARROW_LEFT)
  dx += 1.0f32 if inp.pressed?(Flock::Web::ARROW_RIGHT)
  dy -= 1.0f32 if inp.pressed?(Flock::Web::ARROW_UP)
  dy += 1.0f32 if inp.pressed?(Flock::Web::ARROW_DOWN)
  if inp.gamepad_connected?
    dx += inp.gamepad_x if inp.gamepad_x.abs > 0.15f32
    dy += inp.gamepad_y if inp.gamepad_y.abs > 0.15f32
  end
  world.query(Player, Flock::Web::Transform2D) do |_e, _p, tf|
    np = tf.value.position + Flock::Vec2.new(dx, dy) * (340.0f32 * dt)
    tf.value.position = Flock::Vec2.new(np.x.clamp(0.0f32, WIDTH - 44.0f32), np.y.clamp(0.0f32, HEIGHT - 44.0f32))
  end
end

# Beep on Space / gamepad button 0 (edge-triggered).
space_prev = false
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  inp = world.resource(Flock::Web::Input)
  now = inp.pressed?(Flock::Web::SPACE) || inp.gamepad_button?(0)
  Flock::Web.beep(660, 120) if now && !space_prev
  space_prev = now
end

Flock::Web.launch(app)
