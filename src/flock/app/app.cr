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

    # A registered system plus its ordering metadata: an optional `label`, optional
    # `before`/`after` a label (topologically sorted within the schedule), and an
    # optional `run_if` condition.
    # A class (not a struct) so `last_run` mutates in place and is shared between the
    # `@systems` arrays and the cached `@order_cache` ordering.
    class SystemEntry
      getter proc : System
      getter label : Symbol?
      getter before : Symbol?
      getter after : Symbol?
      getter run_if : Proc(World, Bool)?
      # World change-tick at which this system last ran (for change detection).
      property last_run : UInt32 = 0_u32

      def initialize(@proc : System, @label : Symbol? = nil, @before : Symbol? = nil,
                     @after : Symbol? = nil, @run_if : Proc(World, Bool)? = nil)
      end
    end

    getter world : World
    getter fixed_dt : Float64 = 1.0 / 60.0

    @systems : Hash(Schedule, Array(SystemEntry)) = {} of Schedule => Array(SystemEntry)
    @order_cache : Hash(Schedule, Array(SystemEntry)) = {} of Schedule => Array(SystemEntry)
    @runner : Proc(App, Nil)? = nil
    @accumulator : Float64 = 0.0
    # OnEnter/OnExit systems keyed by "State(S)=value".
    @on_enter : Hash(String, Array(System)) = {} of String => Array(System)
    @on_exit : Hash(String, Array(System)) = {} of String => Array(System)

    def initialize
      @world = World.new
      Schedule.values.each { |s| @systems[s] = [] of SystemEntry }
      @world.insert_resource(Time.new)
      time.fixed_delta = @fixed_dt
    end

    # Central registration: appends a system entry and invalidates the cached order.
    private def register(schedule : Schedule, proc : System, label : Symbol? = nil,
                         before : Symbol? = nil, after : Symbol? = nil,
                         run_if : Proc(World, Bool)? = nil) : Nil
      @systems[schedule] << SystemEntry.new(proc, label, before, after, run_if)
      @order_cache.delete(schedule)
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

    # Adds a system to a schedule. Optional ordering: `label` names it; `before`/`after`
    # order it relative to another label; `run_if` gates it on a condition.
    def add_system(schedule : Schedule, *, label : Symbol? = nil, before : Symbol? = nil,
                   after : Symbol? = nil, run_if : Proc(World, Bool)? = nil,
                   &block : World, Commands ->) : self
      register(schedule, block, label, before, after, run_if)
      self
    end

    def add_startup(&block : World, Commands ->) : self
      register(Schedule::Startup, block)
      self
    end

    def add_fixed_system(&block : World, Commands ->) : self
      register(Schedule::FixedUpdate, block)
      self
    end

    # Pre-creates the event queue for T. Advancing the double buffer each frame is now
    # automatic (World#update_events runs after Last for every event type), so this is
    # optional — sending/reading T works without it. Kept for discoverability and to
    # allocate the queue up front rather than lazily inside a system.
    def add_event(type : T.class) : self forall T
      @world.events(T)
      self
    end

    # Registers a state machine of type S with an initial value. Deferred transitions
    # are applied at the start of each frame (First): OnExit(old) then OnEnter(new) run
    # once per change. OnEnter(initial) runs at startup.
    def add_state(initial : S) : self forall S
      @world.insert_resource(State(S).new(initial))

      register(Schedule::Startup, ->(w : World, c : Commands) do
        run_state_systems(@on_enter, state_key(State(S).name, w.resource(State(S)).current), w, c)
        nil
      end)

      register(Schedule::First, ->(w : World, c : Commands) do
        st = w.resource(State(S))
        if pending = st.pending
          st.pending = nil
          unless pending == st.current
            old = st.current
            st.current = pending
            run_state_systems(@on_exit, state_key(State(S).name, old), w, c)
            run_state_systems(@on_enter, state_key(State(S).name, pending), w, c)
          end
        end
        nil
      end)
      self
    end

    # Runs a system once when entering the given state value.
    def add_on_enter(value : S, &block : World, Commands ->) : self forall S
      (@on_enter[state_key(State(S).name, value)] ||= [] of System) << block
      self
    end

    # Runs a system once when leaving the given state value.
    def add_on_exit(value : S, &block : World, Commands ->) : self forall S
      (@on_exit[state_key(State(S).name, value)] ||= [] of System) << block
      self
    end

    private def state_key(type_name : String, value) : String
      "#{type_name}=#{value}"
    end

    private def run_state_systems(map : Hash(String, Array(System)), key : String, world : World, cmd : Commands) : Nil
      if list = map[key]?
        list.each &.call(world, cmd)
      end
    end

    # Adds a system that runs only while the state of type S equals `state`.
    def add_system_in_state(state : S, schedule : Schedule, &block : World, Commands ->) : self forall S
      register(schedule, block, run_if: ->(w : World) { w.state(S) == state })
      self
    end

    # Installed by WindowPlugin to drive the loop via SDL events.
    def runner(&block : App ->) : Nil
      @runner = block
    end

    # --- Execution ---------------------------------------------------------

    # Runs all systems of a schedule (in resolved order, honoring run_if) then applies
    # the queued commands.
    def run_schedule(schedule : Schedule) : Nil
      cmd = Commands.new(@world)
      ordered_systems(schedule).each do |entry|
        if cond = entry.run_if
          next unless cond.call(@world)
        end
        # Change-detection window: bump the tick and expose this system's last-run tick,
        # then record the new tick so its next run sees only newer changes.
        @world.begin_system(entry.last_run)
        entry.proc.call(@world, cmd)
        entry.last_run = @world.change_tick
      end
      cmd.apply
    end

    private def ordered_systems(schedule : Schedule) : Array(SystemEntry)
      @order_cache[schedule] ||= topo_order(@systems[schedule])
    end

    # Stable topological sort by before/after label constraints. Systems without
    # constraints keep registration order; a cycle falls back to registration order.
    private def topo_order(entries : Array(SystemEntry)) : Array(SystemEntry)
      n = entries.size
      return entries if n <= 1

      by_label = {} of Symbol => Array(Int32)
      entries.each_with_index do |e, i|
        if l = e.label
          (by_label[l] ||= [] of Int32) << i
        end
      end

      succ = Array(Array(Int32)).new(n) { [] of Int32 }
      indeg = Array(Int32).new(n, 0)
      link = ->(from : Int32, to : Int32) do
        succ[from] << to
        indeg[to] += 1
      end
      entries.each_with_index do |e, i|
        if a = e.after
          by_label[a]?.try &.each { |j| link.call(j, i) } # j runs before i
        end
        if b = e.before
          by_label[b]?.try &.each { |j| link.call(i, j) } # i runs before j
        end
      end

      ready = (0...n).select { |i| indeg[i] == 0 }
      result = [] of SystemEntry
      until ready.empty?
        i = ready.min # smallest index -> stable (registration order on ties)
        ready.delete(i)
        result << entries[i]
        succ[i].each do |j|
          indeg[j] -= 1
          ready << j if indeg[j] == 0
        end
      end

      result.size == n ? result : entries
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
      # Advance every event queue after all systems have run this frame (events stay
      # readable for the frame they were sent plus the next). Automatic for every event
      # type, so `send_event` works without a prior `add_event`.
      @world.update_events
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
          # Anti-spiral: drop the excess whole-step lag but KEEP the sub-step remainder,
          # so the fixed cadence stays continuous instead of jumping after a hitch.
          @accumulator = @accumulator % @fixed_dt
          break
        end
      end
      steps
    end

    # Starts the engine: startup then the installed runner's loop.
    def run : Nil
      raise "No runner installed: add WindowPlugin (SDL loop) or use run_headless." unless (runner = @runner)
      begin
        startup # inside begin/ensure: a startup system may allocate GPU/SDL resources
        runner.call(self)
      ensure
        @world.shutdown # release GPU/SDL resources even if startup/runner raised
      end
    end

    # Finite, deterministic loop, windowless — for tests and headless runs. Does NOT call
    # `shutdown` (tests inspect world state afterwards, and the process exits regardless);
    # call `world.shutdown` yourself if a long-lived headless run must release resources.
    def run_headless(ticks : Int32) : Nil
      startup
      ticks.times { update }
    end
  end
end
