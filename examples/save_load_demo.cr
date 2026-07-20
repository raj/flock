# Scene save/load demo: bouncing boxes whose state (Transform2D + a saveable `Bouncer`) can be
# snapshotted to JSON and restored. The rendered Sprite is transient (not saved) and rebuilt by
# a "hydrate" system after a load — the idiomatic split between saved data and render components.
#
#   F5 = save to /tmp/flock_save.json, F9 = restore.
#
#   crystal run examples/save_load_demo.cr
#   WGPU_FRAMES=120 crystal run examples/save_load_demo.cr   # headless smoke
require "../src/flock/gpu"

SAVE_PATH = "/tmp/flock_save.json"

# Saveable gameplay state (color/size drive the transient Sprite; vel drives movement).
struct Bouncer
  include Flock::Component
  include Flock::Saveable
  property color : Flock::Color
  property size : Flock::Vec2
  property vel : Flock::Vec2

  def initialize(@color : Flock::Color, @size : Flock::Vec2, @vel : Flock::Vec2)
  end
end

def setup(world : Flock::World, cmd : Flock::Commands)
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.09, 0.10, 0.13)))
  cols = [Flock::Color.new(0.90, 0.40, 0.35), Flock::Color.new(0.40, 0.70, 0.92), Flock::Color.new(0.55, 0.85, 0.50)]
  6.times do |i|
    cmd.spawn(
      Flock::Transform2D.new(position: Flock::Vec2.new((i - 3) * 100.0 + 50.0, 0.0)),
      Bouncer.new(cols[i % 3], Flock::Vec2.new(60, 60), Flock::Vec2.new(i.odd? ? 90.0 : -90.0, 70.0)))
  end
end

# Rebuild the transient (non-saved) Sprite for any box that lacks one — runs after a load.
def hydrate(world : Flock::World, cmd : Flock::Commands)
  world.query(Bouncer, Flock::Transform2D) do |e, box, _tf|
    next if world.has?(e, Flock::Sprite)
    b = box.value
    cmd.add(e, Flock::Sprite.new(b.size, b.color))
  end
end

def move(world : Flock::World, cmd : Flock::Commands)
  dt = world.resource(Flock::Time).delta.to_f32
  world.query(Bouncer, Flock::Transform2D) do |_e, box, tf|
    b = box.value
    pos = tf.value.position + b.vel * dt
    vx = pos.x.abs > 360.0f32 ? -b.vel.x : b.vel.x
    vy = pos.y.abs > 260.0f32 ? -b.vel.y : b.vel.y
    b.vel = Flock::Vec2.new(vx, vy)
    box.value = b
    t = tf.value
    t.position = pos
    tf.value = t
  end
end

def save_load(world : Flock::World, cmd : Flock::Commands)
  input = world.resource(Flock::Input)
  if input.just_pressed?(Flock::Key::F5)
    Flock::Scene.save(world, SAVE_PATH)
    puts "[demo] saved -> #{SAVE_PATH}"
  elsif input.just_pressed?(Flock::Key::F9) && File.exists?(SAVE_PATH)
    Flock::Scene.restore(world, Flock::Scene.load(SAVE_PATH))
    puts "[demo] restored <- #{SAVE_PATH}"
  end
end

app = Flock::App.new
app.add_plugin(Flock::WindowPlugin.new("Flock - Save/Load (F5 save, F9 restore)", 800, 600))
app.add_plugin(Flock::InputPlugin.new)
app.add_plugin(Flock::RenderPlugin.new)

app.add_startup(&->setup(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->save_load(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->hydrate(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->move(Flock::World, Flock::Commands))

app.run
