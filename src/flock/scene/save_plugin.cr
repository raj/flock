module Flock
  # Periodic autosave: writes `Flock::Scene.save(world, path)` every `interval` seconds (wall-clock,
  # accumulated from Time#delta). With `slots > 1` it rotates through `path.0 .. path.(slots-1)`,
  # keeping the last N autosaves. Add it like any plugin:
  #
  #   app.add_plugin(Flock::SavePlugin.new("autosave.json", interval: 30.0, slots: 3))
  class SavePlugin < Plugin
    @elapsed : Float64 = 0.0
    @slot : Int32 = 0
    @warned : Bool = false

    def initialize(@path : String, @interval : Float64 = 30.0, @slots : Int32 = 1)
    end

    def build(app : App) : Nil
      app.add_system(Schedule::Last) do |world, _cmd|
        @elapsed += world.resource(Time).delta
        if @elapsed >= @interval
          @elapsed -= @interval # keep the sub-interval remainder so the cadence doesn't drift
          target = @slots > 1 ? "#{@path}.#{@slot}" : @path
          begin
            # Atomic-ish: write to a temp file first, then rename over the slot, so a
            # crash mid-write (full disk, killed process) never corrupts the last good save.
            tmp = "#{target}.tmp"
            Flock::Scene.save(world, tmp)
            File.rename(tmp, target)
          rescue ex
            # Autosave must never take the game down (read-only dir, full disk, …):
            # report once and keep running.
            unless @warned
              @warned = true
              STDERR.puts "[flock] SavePlugin: autosave to '#{target}' failed (#{ex.class}: #{ex.message}) — further failures silenced"
            end
          end
          @slot = (@slot + 1) % @slots if @slots > 1
        end
      end
    end
  end
end
