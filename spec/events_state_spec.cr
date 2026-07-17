require "./spec_helper"

struct PingEvent
  getter n : Int32

  def initialize(@n : Int32)
  end
end

enum Phase
  Menu
  Playing
end

describe "Events" do
  it "sends and reads within a frame, then clears" do
    w = Flock::World.new
    w.send_event(PingEvent.new(1))
    w.send_event(PingEvent.new(2))

    seen = [] of Int32
    w.each_event(PingEvent) { |e| seen << e.n }
    seen.should eq([1, 2])

    w.events(PingEvent).clear
    w.events(PingEvent).size.should eq(0)
  end

  it "App#add_event clears the queue each frame" do
    app = Flock::App.new
    app.add_event(PingEvent)
    got = [] of Int32
    app.add_system(Flock::Schedule::Update) { |world, _c| world.send_event(PingEvent.new(42)) }
    app.add_system(Flock::Schedule::Render) { |world, _c| world.each_event(PingEvent) { |e| got << e.n } }

    app.run_headless(2)
    got.should eq([42, 42]) # sent in Update, read in Render, advanced in Last — one per frame
  end

  it "EventReader yields each event exactly once across frames (persistent cursor)" do
    app = Flock::App.new
    app.add_event(PingEvent)
    reader = Flock::EventReader(PingEvent).new
    seen = [] of Int32
    frame = 0
    app.add_system(Flock::Schedule::Update) do |world, _c|
      frame += 1
      world.send_event(PingEvent.new(frame))
    end
    app.add_system(Flock::Schedule::Render) do |world, _c|
      reader.read(world.events(PingEvent)) { |e| seen << e.n }
    end

    app.run_headless(3)
    seen.should eq([1, 2, 3]) # each event once, in order, no duplicates
  end

  it "EventReader catches an event even when it read before the sender (next frame)" do
    app = Flock::App.new
    app.add_event(PingEvent)
    reader = Flock::EventReader(PingEvent).new
    seen = [] of Int32
    # Reader runs in First (before the Update sender): misses this frame, gets it next.
    app.add_system(Flock::Schedule::First) do |world, _c|
      reader.read(world.events(PingEvent)) { |e| seen << e.n }
    end
    sent = false
    app.add_system(Flock::Schedule::Update) do |world, _c|
      unless sent
        world.send_event(PingEvent.new(7))
        sent = true
      end
    end

    app.run_headless(3)
    seen.should eq([7]) # caught once, on the frame after it was sent
  end

  it "add_event is idempotent: a duplicate registration doesn't double-advance the buffers" do
    app = Flock::App.new
    app.add_event(PingEvent)
    app.add_event(PingEvent) # duplicate: must NOT register a second Last updater
    got = [] of Int32
    app.add_system(Flock::Schedule::Update) { |world, _c| world.send_event(PingEvent.new(9)) }
    app.add_system(Flock::Schedule::Render) { |world, _c| world.each_event(PingEvent) { |e| got << e.n } }

    app.run_headless(2)
    got.should eq([9, 9]) # still one event per frame (double-advance would drop them)
  end

  it "each() does not loop forever when a handler sends the same event type" do
    w = Flock::World.new
    w.send_event(PingEvent.new(1))
    seen = [] of Int32
    # A reader that re-sends: the resend must land in a later frame, not extend this loop.
    w.each_event(PingEvent) do |e|
      seen << e.n
      w.send_event(PingEvent.new(e.n + 1)) if e.n < 3
    end
    seen.should eq([1]) # only the pre-existing event is iterated this pass (no infinite growth)
  end
end

describe "State" do
  it "runs in-state systems only in the matching state; transitions are deferred" do
    app = Flock::App.new
    app.add_state(Phase::Menu)
    menu_ticks = 0
    play_ticks = 0
    app.add_system_in_state(Phase::Menu, Flock::Schedule::Update) { |_w, _c| menu_ticks += 1 }
    app.add_system_in_state(Phase::Playing, Flock::Schedule::Update) { |_w, _c| play_ticks += 1 }
    app.add_system(Flock::Schedule::Update) { |world, _c| world.set_state(Phase::Playing) if menu_ticks == 1 }

    app.run_headless(3)
    # frame 1: Menu (menu=1), request Playing; frame 2 (First applies): Playing (play=1);
    # frame 3: Playing (play=2).
    menu_ticks.should eq(1)
    play_ticks.should eq(2)
  end

  it "runs OnEnter(initial) at startup and OnExit(old)/OnEnter(new) on transition" do
    app = Flock::App.new
    app.add_state(Phase::Menu)
    entered = [] of Phase
    exited = [] of Phase
    app.add_on_enter(Phase::Menu) { |_w, _c| entered << Phase::Menu }
    app.add_on_enter(Phase::Playing) { |_w, _c| entered << Phase::Playing }
    app.add_on_exit(Phase::Menu) { |_w, _c| exited << Phase::Menu }
    app.add_system(Flock::Schedule::Update) do |world, _c|
      world.set_state(Phase::Playing) if world.state(Phase) == Phase::Menu
    end

    app.run_headless(3)
    # startup -> OnEnter(Menu); frame 2 First applies -> OnExit(Menu) + OnEnter(Playing).
    entered.should eq([Phase::Menu, Phase::Playing])
    exited.should eq([Phase::Menu])
  end
end
