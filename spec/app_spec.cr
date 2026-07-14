require "./spec_helper"

# Test plugin: populates the world at startup, advances positions on each update.
class MovePlugin < Flock::Plugin
  def build(app : Flock::App)
    app.add_startup do |_world, cmd|
      cmd.spawn(Position.new(0.0, 0.0), Velocity.new(1.0, 2.0))
    end
    app.add_system(Flock::Schedule::Update) do |world, _cmd|
      world.query(Position, Velocity) do |_e, pos, vel|
        p = pos.value
        p.x += vel.value.dx
        p.y += vel.value.dy
        pos.value = p
      end
    end
  end
end

describe Flock::App do
  it "builds a plugin, runs startup then the ticks (headless)" do
    app = Flock::App.new.add_plugin(MovePlugin.new)
    app.run_headless(3)

    xs = [] of Float64
    app.world.query(Position) { |_e, pos| xs << pos.value.x }
    xs.size.should eq(1)
    xs[0].should eq(3.0) # 3 ticks * dx(1.0)
  end

  it "the commands of a schedule are applied before the next schedule" do
    app = Flock::App.new
    app.add_startup { |_w, cmd| cmd.spawn(Position.new(0.0, 0.0)) }
    app.run_headless(0) # startup only

    count = 0
    app.world.query(Position) { |_e, _p| count += 1 }
    count.should eq(1)
  end

  it "exposes Time as a resource" do
    app = Flock::App.new
    app.run_headless(1)
    app.world.resource(Flock::Time).elapsed.should be >= 0.0
  end

  it "run without a runner raises an explicit error" do
    app = Flock::App.new
    expect_raises(Exception, /runner/) { app.run }
  end

  it "fixed timestep: advance_fixed runs FixedUpdate the correct number of times" do
    app = Flock::App.new
    app.fixed_dt = 0.03
    n = 0
    app.add_fixed_system { |_w, _c| n += 1 }

    app.advance_fixed(0.10).should eq(3) # floor(0.10 / 0.03) = 3 (remainder ~0.01)
    n.should eq(3)
    app.advance_fixed(0.01).should eq(0) # 0.01 + 0.01 = 0.02 < 0.03
    n.should eq(3)
    app.advance_fixed(0.02).should eq(1) # 0.02 + 0.02 = 0.04 >= 0.03
    n.should eq(4)

    app.world.resource(Flock::Time).fixed_delta.should eq(0.03)
  end

  it "fixed timestep: bounded by MAX_FIXED_STEPS (anti-spiral)" do
    app = Flock::App.new
    app.fixed_dt = 0.01
    app.add_fixed_system { |_w, _c| }
    app.advance_fixed(10.0).should eq(Flock::App::MAX_FIXED_STEPS) # huge dt -> capped
  end
end
