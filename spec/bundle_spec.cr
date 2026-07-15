require "./spec_helper"

# A bundle grouping two components.
struct MovingBundle
  include Flock::Bundle

  def initialize(@x : Float64, @dx : Float64)
  end

  def components
    {Position.new(@x, 0.0), Velocity.new(@dx, 0.0)}
  end
end

# A bundle that nests another bundle plus an extra component.
struct TaggedMovingBundle
  include Flock::Bundle

  def initialize(@x : Float64, @dx : Float64, @name : String)
  end

  def components
    {MovingBundle.new(@x, @dx), Tag.new(@name)}
  end
end

describe "Flock::Bundle" do
  it "expands a bundle into its individual component storages via World#add" do
    w = Flock::World.new
    e = w.spawn
    w.add(e, MovingBundle.new(3.0, 1.5))

    w.get(e, Position).not_nil!.x.should eq(3.0)
    w.get(e, Velocity).not_nil!.dx.should eq(1.5)
  end

  it "expands bundles passed to Commands#spawn, mixed with plain components" do
    w = Flock::World.new
    cmd = Flock::Commands.new(w)
    e = cmd.spawn(MovingBundle.new(2.0, 4.0), Tag.new("hero"))
    cmd.apply

    w.get(e, Position).not_nil!.x.should eq(2.0)
    w.get(e, Velocity).not_nil!.dx.should eq(4.0)
    w.get(e, Tag).not_nil!.name.should eq("hero")
  end

  it "expands nested bundles recursively" do
    w = Flock::World.new
    e = w.spawn
    w.add(e, TaggedMovingBundle.new(5.0, 6.0, "boss"))

    w.get(e, Position).not_nil!.x.should eq(5.0)
    w.get(e, Velocity).not_nil!.dx.should eq(6.0)
    w.get(e, Tag).not_nil!.name.should eq("boss")
  end

  it "makes a bundled entity match a multi-component query" do
    w = Flock::World.new
    w.add(w.spawn, MovingBundle.new(1.0, 1.0))

    seen = 0
    w.query(Position, Velocity) { |_e, _p, _v| seen += 1 }
    seen.should eq(1)
  end
end
