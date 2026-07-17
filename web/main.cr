# Flock web demo on the WebPlugins backend. It runs the SAME backend-agnostic
# SharedScene (examples/shared_scene.cr) that examples/shared_scene_native.cr runs
# natively, plus web-specific extras: a text banner, a keyboard/gamepad player, and a
# WebAudio sound on Space. Build: web/build.sh
require "./web_backend"
require "../examples/shared_scene"

W = SharedScene::WIDTH
H = SharedScene::HEIGHT

struct Player
  include Flock::Component
end

app = Flock::App.new
app.add_plugin(Flock::Web::WebPlugins.new)

# Backend-agnostic scene (identical source to the native example). Textures load async
# from files on web; on native the same call registers an SDL-loaded texture.
SharedScene.setup(app, ->(name : String) { Flock::Web.load_image("assets/#{name}") })

blip_id = -1 # sound id, set in startup, read by the beep system

# Web-specific extras.
app.add_startup do |_world, cmd|
  Flock::Web.master_volume(80)
  blip_id = Flock::Web.load_sound("assets/blip.wav")

  title = Flock::Web.make_text("FLOCK · WEB")
  cmd.spawn(
    Flock::Transform2D.at(W * 0.5f32 - 150.0f32, 24.0f32),
    Flock::Sprite2D.new(Flock::Vec2.new(300, 60), Flock::Color.new(0.6, 0.9, 1.0), title))

  cmd.spawn(
    Player.new,
    Flock::Transform2D.at(W * 0.5f32, H * 0.5f32),
    Flock::Sprite2D.new(Flock::Vec2.new(44, 44), Flock::Color::WHITE))
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
    tf.value.position = Flock::Vec2.new(np.x.clamp(0.0f32, W - 44.0f32), np.y.clamp(0.0f32, H - 44.0f32))
  end
end

# Beep on Space / gamepad button 0 (edge-triggered).
space_prev = false
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  inp = world.resource(Flock::Web::Input)
  now = inp.pressed?(Flock::Web::SPACE) || inp.gamepad_button?(0)
  if now && !space_prev
    if blip_id >= 0
      Flock::Web.play_sound(blip_id)
    else
      Flock::Web.beep(660, 120)
    end
  end
  space_prev = now
end

Flock::Web.launch(app)
