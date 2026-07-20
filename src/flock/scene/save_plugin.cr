module Flock
  # Periodic autosave: writes `Flock::Scene.save(world, path)` every `interval` seconds (wall-clock,
  # accumulated from Time#delta). With `slots > 1` it rotates through `path.0 .. path.(slots-1)`,
  # keeping the last N autosaves. Add it like any plugin:
  #
  #   app.add_plugin(Flock::SavePlugin.new("autosave.json", interval: 30.0, slots: 3))
  class SavePlugin < Plugin
    @elapsed : Float64 = 0.0
    @slot : Int32 = 0

    def initialize(@path : String, @interval : Float64 = 30.0, @slots : Int32 = 1)
    end

    def build(app : App) : Nil
      app.add_system(Schedule::Last) do |world, _cmd|
        @elapsed += world.resource(Time).delta
        if @elapsed >= @interval
          @elapsed = 0.0
          target = @slots > 1 ? "#{@path}.#{@slot}" : @path
          Flock::Scene.save(world, target)
          @slot = (@slot + 1) % @slots if @slots > 1
        end
      end
    end
  end
end
