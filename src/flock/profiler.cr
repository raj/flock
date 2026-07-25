module Flock
  # Per-system CPU timing (opt-in). When `App#enable_profiling` is on, the sequential scheduler
  # times each system and records it here; `roll` (called each diagnostics window) turns the
  # accumulated times into a per-system average, and `report` lists the hottest systems. Pure /
  # native-free. Off by default — no overhead unless enabled.
  class SystemProfiler < Resource
    # Per-system average CPU time (ms) over the last rolled window, by system name.
    getter avg_ms : Hash(String, Float64) = {} of String => Float64

    @acc = {} of String => Float64  # accumulated seconds this window
    @calls = {} of String => Int32  # invocations this window

    # Records one system invocation's wall time (seconds). Called by the scheduler.
    def record(name : String, seconds : Float64) : Nil
      @acc[name] = (@acc[name]? || 0.0) + seconds
      @calls[name] = (@calls[name]? || 0) + 1
    end

    # Averages the window (mean ms per call) and resets the accumulators.
    def roll : Nil
      out = {} of String => Float64
      @acc.each do |name, secs|
        calls = @calls[name]? || 1
        out[name] = (secs / calls) * 1000.0
      end
      @avg_ms = out
      @acc.clear
      @calls.clear
    end

    # Total average CPU time (ms) across all systems in the last window.
    def total_ms : Float64
      @avg_ms.values.sum
    end

    # One-line report: the `top` hottest systems, "name 1.23ms" descending.
    def report(top : Int32 = 8) : String
      @avg_ms.to_a.sort_by! { |(_n, ms)| -ms }.first(top)
        .map { |(n, ms)| "#{n} #{ms.round(3)}ms" }.join("  ")
    end
  end
end
