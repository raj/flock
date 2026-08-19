require "./spec_helper"

describe Flock::SystemProfiler do
  it "records per-system CPU time under App#enable_profiling" do
    app = Flock::App.new
    app.enable_profiling
    app.add_system(Flock::Schedule::Update, label: :heavy) do |_w, _c|
      s = 0.0
      120_000.times { |i| s += Math.sqrt(i.to_f + 1.0) }
      s.should be > 0.0 # keep the loop (no dead-code elimination)
    end
    app.add_system(Flock::Schedule::Update, label: :light) { |_w, _c| }
    app.add_system(Flock::Schedule::Update) { |_w, _c| } # unlabeled → "Update#2"
    app.run_headless(3)

    prof = app.world.resource(Flock::SystemProfiler)
    prof.roll
    prof.avg_ms.has_key?("heavy").should be_true
    prof.avg_ms.has_key?("light").should be_true
    prof.avg_ms.keys.any?(&.starts_with?("Update#")).should be_true # unlabeled fallback name
    prof.avg_ms["heavy"].should be >= prof.avg_ms["light"]          # heavier system costs more
    prof.total_ms.should be > 0.0
    prof.report.should contain("heavy")
  end

  it "has zero overhead / no resource when profiling is off (default)" do
    app = Flock::App.new
    app.profiling.should be_false
    app.add_system(Flock::Schedule::Update, label: :x) { |_w, _c| }
    app.run_headless(2)
    app.world.resource?(Flock::SystemProfiler).should be_nil
  end
end
