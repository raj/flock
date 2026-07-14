module Flock
  # Game loop clock (resource). `delta` = duration of the previous frame,
  # `elapsed` = time since startup, in seconds. Used for framerate-independent
  # movement. Based on the stdlib monotonic clock (no native dependency).
  class Time < Resource
    getter delta : Float64 = 0.0
    getter elapsed : Float64 = 0.0
    # Fixed timestep (constant), to be used in FixedUpdate systems.
    property fixed_delta : Float64 = 1.0 / 60.0

    @last : ::Time::Instant
    @start : ::Time::Instant

    def initialize
      now = ::Time.instant
      @last = now
      @start = now
    end

    # Updates delta/elapsed. Called once per frame by the App.
    def tick : Nil
      now = ::Time.instant
      @delta = (now - @last).total_seconds
      @elapsed = (now - @start).total_seconds
      @last = now
    end
  end
end
