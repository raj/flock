require "./spec_helper"

describe Flock::SparseSet do
  it "inserts and reads back a component" do
    set = Flock::SparseSet(Position).new
    e = Flock::Entity.new(3_u32, 0_u32)
    set.insert(e, Position.new(1.0, 2.0))

    set.size.should eq(1)
    set.has?(e).should be_true
    set.get?(e).not_nil!.x.should eq(1.0)
  end

  it "updates in place via get_ptr" do
    set = Flock::SparseSet(Position).new
    e = Flock::Entity.new(0_u32, 0_u32)
    set.insert(e, Position.new(1.0, 1.0))

    ptr = set.get_ptr(e).not_nil!
    ptr.value.x = 42.0

    # The mutation through the pointer persists in the dense array.
    set.get?(e).not_nil!.x.should eq(42.0)
  end

  it "updates instead of duplicating on re-insertion" do
    set = Flock::SparseSet(Position).new
    e = Flock::Entity.new(1_u32, 0_u32)
    set.insert(e, Position.new(1.0, 1.0))
    set.insert(e, Position.new(9.0, 9.0))

    set.size.should eq(1)
    set.get?(e).not_nil!.x.should eq(9.0)
  end

  it "removes in O(1) via swap-and-pop while keeping the others consistent" do
    set = Flock::SparseSet(Position).new
    a = Flock::Entity.new(0_u32, 0_u32)
    b = Flock::Entity.new(1_u32, 0_u32)
    c = Flock::Entity.new(2_u32, 0_u32)
    set.insert(a, Position.new(0.0, 0.0))
    set.insert(b, Position.new(1.0, 0.0))
    set.insert(c, Position.new(2.0, 0.0))

    set.remove(b) # b is in the middle -> c takes its place

    set.size.should eq(2)
    set.has?(b).should be_false
    set.get?(a).not_nil!.x.should eq(0.0)
    set.get?(c).not_nil!.x.should eq(2.0)
  end

  it "ignores a handle with a stale generation" do
    set = Flock::SparseSet(Position).new
    old = Flock::Entity.new(5_u32, 0_u32)
    fresh = Flock::Entity.new(5_u32, 1_u32) # same id, next generation
    set.insert(fresh, Position.new(7.0, 7.0))

    set.get?(old).should be_nil
    set.get?(fresh).not_nil!.x.should eq(7.0)
  end
end
