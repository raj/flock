# Flock web demo, built on the WebPlugins backend (web_backend.cr). Same structure as a
# native Flock game: an App with plugins + systems on schedules, querying components.
# Bouncing squares (ECS movement) + a white player square driven by the arrow keys.
#
# Build: web/build.sh  → web/app.wasm + web/app.mjs  (served with index.html + renderer.js)
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
  160.times do
    s = 12.0f32 + rand.to_f32 * 30.0f32
    cmd.spawn(
      Flock::Web::Transform2D.new(Flock::Vec2.new(rand.to_f32 * WIDTH, rand.to_f32 * HEIGHT)),
      Flock::Web::Sprite.new(Flock::Vec2.new(s, s),
        Flock::Vec3.new(0.3f32 + rand.to_f32 * 0.7f32, 0.3f32 + rand.to_f32 * 0.7f32, 0.3f32 + rand.to_f32 * 0.7f32)),
      Velocity.new(Flock::Vec2.new((rand.to_f32 - 0.5f32) * 300.0f32, (rand.to_f32 - 0.5f32) * 300.0f32)))
  end

  cmd.spawn(
    Player.new,
    Flock::Web::Transform2D.new(Flock::Vec2.new(WIDTH * 0.5f32, HEIGHT * 0.5f32)),
    Flock::Web::Sprite.new(Flock::Vec2.new(44, 44), Flock::Vec3.new(1.0, 1.0, 1.0)))
end

# Bouncing squares.
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

# Player: arrow-key movement (WebPlugins Input resource).
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  dt = world.resource(Flock::Time).delta.to_f32
  inp = world.resource(Flock::Web::Input)
  dx = 0.0f32; dy = 0.0f32
  dx -= 1.0f32 if inp.pressed?(Flock::Web::ARROW_LEFT)
  dx += 1.0f32 if inp.pressed?(Flock::Web::ARROW_RIGHT)
  dy -= 1.0f32 if inp.pressed?(Flock::Web::ARROW_UP)
  dy += 1.0f32 if inp.pressed?(Flock::Web::ARROW_DOWN)
  world.query(Player, Flock::Web::Transform2D) do |_e, _p, tf|
    np = tf.value.position + Flock::Vec2.new(dx, dy) * (320.0f32 * dt)
    tf.value.position = Flock::Vec2.new(np.x.clamp(0.0f32, WIDTH - 44.0f32), np.y.clamp(0.0f32, HEIGHT - 44.0f32))
  end
end

Flock::Web.launch(app)
