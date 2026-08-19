require "./spec_helper"

# A resource used to exercise reads_res:/writes_res: access declarations.
class Counter < Flock::Resource
  property n : Int32 = 0
end

describe "Parallel scheduler" do
  describe "Access#conflicts?" do
    it "read-read never conflicts; write-vs-touch does" do
      reader = Flock::Access.new(Set{"C:Position"}, Set(String).new, false)
      reader2 = Flock::Access.new(Set{"C:Position"}, Set(String).new, false)
      writer = Flock::Access.new(Set(String).new, Set{"C:Position"}, false)
      other = Flock::Access.new(Set(String).new, Set{"C:Velocity"}, false)

      reader.conflicts?(reader2).should be_false # two readers of the same type
      reader.conflicts?(writer).should be_true   # reader vs writer
      writer.conflicts?(writer).should be_true   # two writers
      writer.conflicts?(other).should be_false   # disjoint writes
      Flock::Access.barrier.conflicts?(other).should be_true
      other.conflicts?(Flock::Access.barrier).should be_true
    end
  end

  describe "#parallel_plan (wave batching)" do
    it "groups non-conflicting systems and splits conflicting ones" do
      app = Flock::App.new
      # move reads Velocity + writes Position; spin writes Velocity (conflicts with move);
      # ai writes Tag (independent of both).
      app.add_system(Flock::Schedule::Update, label: :move, reads: {Velocity}, writes: {Position}) { |_w, _c| }
      app.add_system(Flock::Schedule::Update, label: :spin, writes: {Velocity}) { |_w, _c| }
      app.add_system(Flock::Schedule::Update, label: :ai, writes: {Tag}) { |_w, _c| }

      app.parallel_plan(Flock::Schedule::Update).should eq([[:move, :ai], [:spin]])
    end

    it "an undeclared system is a barrier: runs alone and splits its neighbours" do
      app = Flock::App.new
      app.add_system(Flock::Schedule::Update, label: :a, writes: {Position}) { |_w, _c| }
      app.add_system(Flock::Schedule::Update, label: :barrier) { |_w, _c| } # no access declared
      app.add_system(Flock::Schedule::Update, label: :b, writes: {Velocity}) { |_w, _c| }

      # a and b are independent, but the barrier between them prevents merging.
      app.parallel_plan(Flock::Schedule::Update).should eq([[:a], [:barrier], [:b]])
    end

    it "honours before/after ordering even when access does not conflict" do
      app = Flock::App.new
      app.add_system(Flock::Schedule::Update, label: :first, writes: {Position}) { |_w, _c| }
      app.add_system(Flock::Schedule::Update, label: :second, writes: {Velocity}, after: :first) { |_w, _c| }

      # Disjoint writes would share a wave, but `after: :first` forces a later wave.
      app.parallel_plan(Flock::Schedule::Update).should eq([[:first], [:second]])
    end

    it "resources participate in conflict detection" do
      app = Flock::App.new
      app.add_system(Flock::Schedule::Update, label: :inc, writes_res: {Counter}) { |_w, _c| }
      app.add_system(Flock::Schedule::Update, label: :read, reads_res: {Counter}) { |_w, _c| }

      app.parallel_plan(Flock::Schedule::Update).should eq([[:inc], [:read]])
    end
  end

  describe "parallel == sequential (equivalence)" do
    # Builds an app of N entities (Position+Velocity) and two disjoint-write systems that run
    # in one wave: `incp` bumps every Position.x, `incv` bumps every Velocity.dx.
    build = ->(parallel : Bool) do
      app = Flock::App.new
      app.parallel = parallel
      app.add_startup do |_w, cmd|
        20.times { cmd.spawn(Position.new(0.0, 0.0), Velocity.new(0.0, 0.0)) }
      end
      app.add_system(Flock::Schedule::Update, label: :incp, writes: {Position}) do |w, _c|
        w.query(Position) { |_e, p| p.value.x = p.value.x + 1.0 }
      end
      app.add_system(Flock::Schedule::Update, label: :incv, writes: {Velocity}) do |w, _c|
        w.query(Velocity) { |_e, v| v.value.dx = v.value.dx + 2.0 }
      end
      app
    end

    read = ->(app : Flock::App) do
      xs = [] of Float64
      ds = [] of Float64
      app.world.query(Position, Velocity) do |_e, p, v|
        xs << p.value.x
        ds << v.value.dx
      end
      {xs.sort, ds.sort}
    end

    it "produces identical component values after N frames" do
      seq = build.call(false); seq.run_headless(5)
      par = build.call(true); par.run_headless(5)

      read.call(seq).should eq(read.call(par))
      # sanity: the systems actually ran (5 frames)
      read.call(par)[0].should eq(Array.new(20, 5.0))
      read.call(par)[1].should eq(Array.new(20, 10.0))
    end
  end

  describe "deferred Commands under parallel" do
    it "spawns from a parallel wave apply after the schedule, in system order" do
      app = Flock::App.new
      app.parallel = true
      # Two independent systems each spawn a tagged entity from within the same wave.
      app.add_system(Flock::Schedule::Update, label: :spawn_a, writes: {Position}) do |_w, cmd|
        cmd.spawn(Position.new(1.0, 0.0))
      end
      app.add_system(Flock::Schedule::Update, label: :spawn_b, writes: {Velocity}) do |_w, cmd|
        cmd.spawn(Velocity.new(9.0, 0.0))
      end
      app.run_headless(1)

      positions = [] of Float64
      app.world.query(Position) { |_e, p| positions << p.value.x }
      velocities = [] of Float64
      app.world.query(Velocity) { |_e, v| velocities << v.value.dx }
      positions.should eq([1.0])
      velocities.should eq([9.0])
    end
  end
end
