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

blip_id = -1 # sound id, set in startup, read by the beep system

app.add_startup do |_world, cmd|
  Flock::Web.master_volume(80) # master output level (0..100)
  checker = Flock::Web.checkerboard # procedural texture (id)

  # Load an image + a sound from files (async; sprites show white until the image lands).
  img = Flock::Web.load_image("assets/sprite.png")
  blip_id = Flock::Web.load_sound("assets/blip.wav")

  # Full image, and a second sprite showing just its top-left quarter (atlas UV sub-rect).
  cmd.spawn(
    Flock::Transform2D.at(60.0f32, 120.0f32),
    Flock::Web::Sprite.new(Flock::Vec2.new(96, 96), Flock::Color::WHITE, img))
  cmd.spawn(
    Flock::Transform2D.at(60.0f32, 240.0f32),
    Flock::Web::Sprite.new(Flock::Vec2.new(96, 96), Flock::Color::WHITE, img,
      Flock::Vec2.new(0.0, 0.0), Flock::Vec2.new(0.5, 0.5)))

  120.times do
    s = 16.0f32 + rand.to_f32 * 30.0f32
    cmd.spawn(
      Flock::Transform2D.at(rand.to_f32 * WIDTH, rand.to_f32 * HEIGHT),
      Flock::Web::Sprite.new(Flock::Vec2.new(s, s),
        Flock::Color.new(0.4f32 + rand.to_f32 * 0.6f32, 0.4f32 + rand.to_f32 * 0.6f32, 0.4f32 + rand.to_f32 * 0.6f32),
        checker),
      Velocity.new(Flock::Vec2.new((rand.to_f32 - 0.5f32) * 280.0f32, (rand.to_f32 - 0.5f32) * 280.0f32)))
  end

  # Text rasterized to a texture, drawn as a (tinted) sprite.
  title = Flock::Web.make_text("FLOCK · WEB")
  cmd.spawn(
    Flock::Transform2D.at(WIDTH * 0.5f32 - 150.0f32, 24.0f32),
    Flock::Web::Sprite.new(Flock::Vec2.new(300, 60), Flock::Color.new(0.6, 0.9, 1.0), title))

  cmd.spawn(
    Player.new,
    Flock::Transform2D.at(WIDTH * 0.5f32, HEIGHT * 0.5f32),
    Flock::Web::Sprite.new(Flock::Vec2.new(44, 44), Flock::Color.new(1.0, 1.0, 1.0)))
end

# Bouncing checkerboard squares.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  dt = world.resource(Flock::Time).delta.to_f32
  world.query(Flock::Transform2D, Velocity) do |_e, tf, vel|
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
  world.query(Player, Flock::Transform2D) do |_e, _p, tf|
    np = tf.value.position + Flock::Vec2.new(dx, dy) * (340.0f32 * dt)
    tf.value.position = Flock::Vec2.new(np.x.clamp(0.0f32, WIDTH - 44.0f32), np.y.clamp(0.0f32, HEIGHT - 44.0f32))
  end
end

# Beep on Space / gamepad button 0 (edge-triggered).
space_prev = false
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  inp = world.resource(Flock::Web::Input)
  now = inp.pressed?(Flock::Web::SPACE) || inp.gamepad_button?(0)
  if now && !space_prev
    if blip_id >= 0
      Flock::Web.play_sound(blip_id) # loaded audio file
    else
      Flock::Web.beep(660, 120)      # fallback synth beep
    end
  end
  space_prev = now
end

Flock::Web.launch(app)
