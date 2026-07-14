module Flock
  # Engine entry point: holds the World, the systems grouped by Schedule, the
  # plugins and the runner (the main loop).
  #
  #   Flock::App.new
  #     .add_plugin(MyPlugin.new)
  #     .add_startup { |world, cmd| ... }
  #     .add_system(Flock::Schedule::Update) { |world, cmd| ... }
  #     .run
  #
  # A system is a `Proc(World, Commands, Nil)`: it reads/mutates the World and
  # queues structural mutations via `cmd` (applied at the end of the schedule).
  class App
    alias System = Proc(World, Commands, Nil)

    MAX_FIXED_STEPS = 8 # "spiral of death" guard if a frame is very slow

    getter world : World
    getter fixed_dt : Float64 = 1.0 / 60.0

    @systems : Hash(Schedule, Array(System)) = {} of Schedule => Array(System)
    @runner : Proc(App, Nil)? = nil
    @accumulator : Float64 = 0.0

    def initialize
      @world = World.new
      Schedule.values.each { |s| @systems[s] = [] of System }
      @world.insert_resource(Time.new)
      time.fixed_delta = @fixed_dt
    end

    # Fixed timestep (seconds) of the FixedUpdate systems.
    def fixed_dt=(seconds : Float64) : Nil
      @fixed_dt = seconds
      time.fixed_delta = seconds
    end

    # Sugar: sets the fixed step by frequency (e.g. `fixed_hz(50)`).
    def fixed_hz(hz : Number) : self
      self.fixed_dt = 1.0 / hz.to_f
      self
    end

    def time : Time
      @world.resource(Time)
    end

    # --- Configuration -----------------------------------------------------

    def add_plugin(plugin : Plugin) : self
      plugin.build(self)
      self
    end

    def add_plugins(*plugins : Plugin) : self
      plugins.each { |p| add_plugin(p) }
      self
    end

    def add_system(schedule : Schedule, &block : World, Commands ->) : self
      @systems[schedule] << block
      self
    end

    def add_startup(&block : World, Commands ->) : self
      @systems[Schedule::Startup] << block
      self
    end

    def add_fixed_system(&block : World, Commands ->) : self
      @systems[Schedule::FixedUpdate] << block
      self
    end

    # Registers an event type T: creates its queue and clears it each frame (Last).
    def add_event(type : T.class) : self forall T
      @world.events(T)
      @systems[Schedule::Last] << ->(w : World, _c : Commands) { w.events(T).clear; nil }
      self
    end

    # Registers a state machine of type S with an initial value; deferred transitions
    # are applied at the start of each frame (First).
    def add_state(initial : S) : self forall S
      @world.insert_resource(State(S).new(initial))
      @systems[Schedule::First] << ->(w : World, _c : Commands) { w.resource(State(S)).apply_pending; nil }
      self
    end

    # Adds a system that runs only while the state of type S equals `state`.
    def add_system_in_state(state : S, schedule : Schedule, &block : World, Commands ->) : self forall S
      @systems[schedule] << ->(w : World, c : Commands) do
        block.call(w, c) if w.state(S) == state
        nil
      end
      self
    end

    # Installed by WindowPlugin to drive the loop via SDL events.
    def runner(&block : App ->) : Nil
      @runner = block
    end

    # --- Execution ---------------------------------------------------------

    # Runs all systems of a schedule then applies the queued commands.
    def run_schedule(schedule : Schedule) : Nil
      cmd = Commands.new(@world)
      @systems[schedule].each &.call(@world, cmd)
      cmd.apply
    end

    def startup : Nil
      run_schedule(Schedule::Startup)
    end

    # One frame: First -> (FixedUpdate × N) -> Update -> Render -> Last.
    def update : Nil
      time.tick
      run_schedule(Schedule::First)
      advance_fixed(time.delta)
      run_schedule(Schedule::Update)
      run_schedule(Schedule::Render)
      run_schedule(Schedule::Last)
    end

    # Accumulates `dt` and runs FixedUpdate as many times as the fixed step fits
    # (bounded by MAX_FIXED_STEPS). Returns the number of steps run. Testable in
    # isolation with a deterministic `dt`.
    def advance_fixed(dt : Float64) : Int32
      @accumulator += dt
      steps = 0
      while @accumulator >= @fixed_dt
        run_schedule(Schedule::FixedUpdate)
        @accumulator -= @fixed_dt
        steps += 1
        if steps >= MAX_FIXED_STEPS
          @accumulator = 0.0 # drop the accumulated lag (anti-spiral)
          break
        end
      end
      steps
    end

    # Starts the engine: startup then the installed runner's loop.
    def run : Nil
      startup
      if runner = @runner
        runner.call(self)
      else
        raise "No runner installed: add WindowPlugin (SDL loop) or use run_headless."
      end
      @world.shutdown # releases GPU/SDL resources on shutdown
    end

    # Finite, deterministic loop, windowless — for tests and headless runs.
    def run_headless(ticks : Int32) : Nil
      startup
      ticks.times { update }
    end
  end
end
