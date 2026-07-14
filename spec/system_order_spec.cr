require "./spec_helper"

describe "system ordering" do
  it "orders systems by before/after labels (registration order otherwise)" do
    app = Flock::App.new
    order = [] of Symbol
    app.add_system(Flock::Schedule::Update, label: :b) { |_w, _c| order << :b }
    app.add_system(Flock::Schedule::Update, label: :a, before: :b) { |_w, _c| order << :a }
    app.add_system(Flock::Schedule::Update, after: :b) { |_w, _c| order << :c }

    app.run_headless(1)
    order.should eq([:a, :b, :c]) # a before b (constraint); c after b; stable otherwise
  end

  it "gates a system with run_if" do
    app = Flock::App.new
    gate = false
    ticks = 0
    app.add_system(Flock::Schedule::Update, run_if: ->(_w : Flock::World) { gate }) { |_w, _c| ticks += 1 }

    app.run_headless(2)
    ticks.should eq(0) # gate false

    gate = true
    app.run_headless(2)
    ticks.should eq(2) # gate true -> runs each frame
  end
end
