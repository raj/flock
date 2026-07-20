require "./spec_helper"

describe Flock::SavePlugin do
  it "autosaves on the configured interval" do
    path = File.tempname("flock_autosave", ".json")
    begin
      app = Flock::App.new
      app.add_plugin(Flock::SavePlugin.new(path, interval: 0.0)) # save every frame
      app.add_startup { |w, _c| w.add(w.spawn, SavePos.new(11, 22)) }
      app.run_headless(1) # startup + one update -> autosave fires

      File.exists?(path).should be_true
      w2 = Flock::World.new
      map = Flock::Scene.spawn(w2, Flock::Scene.load(path))
      w2.get(map.values.first, SavePos).not_nil!.x.should eq(11)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "rotates through slots, keeping the last N autosaves" do
    path = File.tempname("flock_rot", ".json")
    slots = ["#{path}.0", "#{path}.1"]
    begin
      app = Flock::App.new
      app.add_plugin(Flock::SavePlugin.new(path, interval: 0.0, slots: 2))
      app.add_startup { |w, _c| w.add(w.spawn, SavePos.new(1, 1)) }
      app.run_headless(2) # two updates -> writes .0 then .1

      slots.each { |s| File.exists?(s).should be_true }
    ensure
      slots.each { |s| File.delete(s) if File.exists?(s) }
    end
  end

  it "does not save before the interval elapses" do
    path = File.tempname("flock_none", ".json")
    begin
      app = Flock::App.new
      app.add_plugin(Flock::SavePlugin.new(path, interval: 3600.0)) # far in the future
      app.add_startup { |w, _c| w.add(w.spawn, SavePos.new(1, 1)) }
      app.run_headless(3)
      File.exists?(path).should be_false
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
