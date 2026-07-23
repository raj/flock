require "./spec_helper"

describe "World change detection + query filters" do
  it "with:/without: filter the iterated set (structurally)" do
    w = Flock::World.new
    a = w.spawn; w.add(a, Position.new); w.add(a, Tag.new("keep"))
    b = w.spawn; w.add(b, Position.new) # no Tag
    c = w.spawn; w.add(c, Position.new); w.add(c, Tag.new("x")); w.add(c, Velocity.new)

    with_tag = [] of UInt32
    w.query(Position, with: {Tag}) { |e, _p| with_tag << e.id }
    with_tag.sort.should eq([a.id, c.id].sort)

    without_vel = [] of UInt32
    w.query(Position, without: {Velocity}) { |e, _p| without_vel << e.id }
    without_vel.sort.should eq([a.id, b.id].sort)
  end

  it "added?/changed? are true for a fresh insert within the run" do
    w = Flock::World.new
    w.begin_system(0_u32) # simulate a system starting (last_run = 0)
    e = w.spawn
    w.add(e, Position.new(1.0, 2.0))
    w.added?(e, Position).should be_true
    w.changed?(e, Position).should be_true
  end

  it "changed? goes false on the next run, true again after a write" do
    w = Flock::World.new
    e = w.spawn
    w.begin_system(0_u32)
    w.add(e, Position.new)
    last = w.change_tick # what the system would store as its last_run

    # Next run of the same system: nothing changed since.
    w.begin_system(last)
    w.changed?(e, Position).should be_false
    w.added?(e, Position).should be_false

    # A pointer mutation flagged via mark_changed is detected.
    w.query(Position) { |_e, p| p.value = Position.new(9.0, 9.0) }
    w.mark_changed(e, Position)
    w.changed?(e, Position).should be_true

    # set(...) also marks changed.
    last2 = w.change_tick
    w.begin_system(last2)
    w.changed?(e, Position).should be_false
    w.set(e, Position.new(3.0, 3.0))
    w.changed?(e, Position).should be_true
  end

  it "changed:/added: query filters yield only the matching entities" do
    w = Flock::World.new
    a = w.spawn; w.add(a, Position.new)
    b = w.spawn; w.add(b, Position.new)

    # New run: mutate only `a`.
    w.begin_system(w.change_tick)
    w.set(a, Position.new(5.0, 0.0))

    changed = [] of UInt32
    w.query(Position, changed: {Position}) { |e, _p| changed << e.id }
    changed.should eq([a.id])
  end

  it "drives change detection through the App per-system last-run" do
    app = Flock::App.new
    seen = [] of Int32
    target = app.world.spawn
    app.world.add(target, Position.new)

    # A system that reacts only when Position changed.
    app.add_system(Flock::Schedule::Update) do |world, _cmd|
      world.query(Position, changed: {Position}) { |_e, p| seen << p.value.x.to_i }
    end
    # A system that mutates Position on frame 2 only.
    frame = 0
    app.add_system(Flock::Schedule::Update) do |world, _cmd|
      frame += 1
      world.set(target, Position.new(frame.to_f, 0.0)) if frame == 2
    end

    app.update # frame 1: initial add is "changed" (first run) -> reacts once
    app.update # frame 2: mutated -> reacts
    app.update # frame 3: no change -> no react

    # Reacted on frame 1 (x=0, the initial value) and frame 2 (x=2).
    seen.should eq([0, 2])
  end
end
