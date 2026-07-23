# Demo: query filters + change detection (headless, no window/GPU).
#
#   crystal run examples/change_detection.cr
#
# Shows the four keyword filters — with:/without: (structural) and changed:/added:
# (tick-based) — plus the write paths that make change detection fire: `world.set` and
# `world.mark_changed` (needed after an in-place pointer write, which the storage can't see).
require "../src/flock" # core only — no SDL/wgpu needed

struct Position
  include Flock::Component
  property x : Float64

  def initialize(@x : Float64 = 0.0)
  end
end

struct Velocity
  include Flock::Component
  property dx : Float64

  def initialize(@dx : Float64 = 0.0)
  end
end

struct Enemy
  include Flock::Component
end

struct Frozen
  include Flock::Component
end

app = Flock::App.new

# Spawn: two movers (one Frozen), and a mover that is also an Enemy.
app.add_startup do |_world, cmd|
  cmd.spawn(Position.new(0.0), Velocity.new(1.0))                # id A — moves
  cmd.spawn(Position.new(0.0), Velocity.new(2.0), Frozen.new)    # id B — frozen (skipped)
  cmd.spawn(Position.new(0.0), Velocity.new(5.0), Enemy.new)     # id C — moves, enemy
end

# Move everything with a Velocity EXCEPT frozen entities, and flag the write so change
# detection sees it (a raw pointer write is invisible on its own).
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  world.query(Position, Velocity, without: {Frozen}) do |e, pos, vel|
    pos.value = Position.new(pos.value.x + vel.value.dx)
    world.mark_changed(e, Position)
  end
end

# React only to positions that changed since this system last ran. The frozen entity B
# prints once (its spawn counts as a change: Added implies Changed) and then never again,
# because it never moves — unlike A and C which move every frame.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  world.query(Position, changed: {Position}) do |e, pos|
    puts "  changed: entity #{e.id} -> x=#{pos.value.x}"
  end
end

# React only to enemies the first time they appear (Added).
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  world.query(Enemy, added: {Enemy}) do |e, _enemy|
    puts "  NEW enemy: entity #{e.id}"
  end
end

# Structural filter: enemies only (with:), position not yielded from Velocity here.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  count = 0
  world.query(Position, with: {Enemy}) { |_e, _p| count += 1 }
  puts "  enemies alive: #{count}"
end

app.startup
3.times do |frame|
  puts "frame #{frame}"
  # Spawn a second enemy at frame 1 to show Added firing once, later.
  if frame == 1
    cmd = Flock::Commands.new(app.world)
    cmd.spawn(Position.new(100.0), Velocity.new(0.5), Enemy.new)
    cmd.apply
  end
  app.update
end
app.world.shutdown
