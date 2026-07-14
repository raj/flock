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
    got.should eq([42, 42]) # sent in Update, read in Render, cleared in Last — one per frame
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
end
