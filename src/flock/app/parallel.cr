{% if flag?(:preview_mt) || flag?(:execution_context) %}
  require "wait_group" # multi-thread wave execution (fibers spread across worker threads)
{% end %}

module Flock
  # Declared data access of a system — what component/resource types it reads and writes.
  # The parallel scheduler uses it to decide which systems may run at the same time: two
  # systems can share a wave only if neither writes a type the other touches.
  #
  # Tokens are fully-qualified type names prefixed `C:` (component) or `R:` (resource), so a
  # component and a resource of the same name never alias. A system that declares NO access
  # is a `barrier`: it conflicts with everything and runs alone — the safe default, so an
  # undeclared (or hard-to-analyze) system never races.
  struct Access
    getter reads : Set(String)
    getter writes : Set(String)
    getter? barrier : Bool

    def initialize(@reads : Set(String), @writes : Set(String), @barrier : Bool)
    end

    # The conservative default: conflicts with every other system.
    def self.barrier : Access
      new(Set(String).new, Set(String).new, true)
    end

    # Can these two systems NOT run concurrently? True if either is a barrier, or one writes
    # a type the other reads or writes. Two pure readers of the same type never conflict.
    def conflicts?(other : Access) : Bool
      return true if @barrier || other.barrier?
      intersects?(@writes, other.reads) ||
        intersects?(@writes, other.writes) ||
        intersects?(@reads, other.writes)
    end

    private def intersects?(a : Set(String), b : Set(String)) : Bool
      small, large = a.size <= b.size ? {a, b} : {b, a}
      small.each { |x| return true if large.includes?(x) }
      false
    end
  end

  class App
    # Once-per-process warning when parallel is requested without an MT-capable build.
    @@warned_no_mt = false

    protected def self.warn_no_mt : Nil
      return if @@warned_no_mt
      @@warned_no_mt = true
      STDERR.puts "[Flock] App#parallel is on, but this binary was built without -Dpreview_mt " \
                  "(nor -Dexecution_context); waves run sequentially — correct results, no speedup."
    end

    # Builds an `Access` from the declared component/resource tuples (fully-qualified,
    # prefixed tokens). Empty on all four → a barrier.
    protected def build_access(reads, writes, reads_res, writes_res) : Access
      r = Set(String).new
      w = Set(String).new
      reads.each { |c| r << "C:#{c.name}" }
      writes.each { |c| w << "C:#{c.name}" }
      reads_res.each { |c| r << "R:#{c.name}" }
      writes_res.each { |c| w << "R:#{c.name}" }
      return Access.barrier if r.empty? && w.empty?
      Access.new(r, w, false)
    end

    # A proc that pre-creates the declared component storages on the main thread. Lazy
    # storage creation (`World#storage`) mutates a shared array, so it must not happen
    # concurrently inside a wave — we warm every declared storage first.
    protected def build_prewarm(reads, writes) : Proc(World, Nil)?
      return nil if reads.empty? && writes.empty?
      ->(world : World) do
        reads.each { |c| world.storage(c) }
        writes.each { |c| world.storage(c) }
        nil
      end
    end

    # Partitions a schedule's (already topologically ordered) systems into waves: each wave's
    # systems have mutually non-conflicting access and no ordering edge between them, so a wave
    # can run concurrently. Barriers occupy a wave alone and split the ones around them. Waves
    # preserve the topo order (a system never lands before one it must run after), so running
    # waves in order — sequentially or in parallel — matches the sequential schedule.
    def build_waves(entries : Array(SystemEntry)) : Array(Array(SystemEntry))
      n = entries.size
      return [entries.dup] if n <= 1

      # Ordering edges from before/after labels: preds[i] = systems that must precede i.
      by_label = {} of Symbol => Array(Int32)
      entries.each_with_index do |e, i|
        if l = e.label
          (by_label[l] ||= [] of Int32) << i
        end
      end
      preds = Array(Array(Int32)).new(n) { [] of Int32 }
      entries.each_with_index do |e, i|
        if a = e.after
          by_label[a]?.try &.each { |j| preds[i] << j } # j before i
        end
        if b = e.before
          by_label[b]?.try &.each { |j| preds[j] << i } # i before j
        end
      end

      wave_of = Array(Int32).new(n, -1)
      wave_ids = [] of Array(Int32)
      wave_has_barrier = [] of Bool
      barrier_floor = 0

      new_wave = -> do
        wave_ids << [] of Int32
        wave_has_barrier << false
      end

      entries.each_with_index do |e, i|
        minw = barrier_floor
        preds[i].each { |p| minw = Math.max(minw, wave_of[p] + 1) }
        acc = e.access

        if acc.barrier?
          w = Math.max(minw, wave_ids.size) # a fresh wave at the end, at/after minw
          while wave_ids.size <= w
            new_wave.call
          end
          wave_ids[w] << i
          wave_has_barrier[w] = true
          wave_of[i] = w
          barrier_floor = w + 1
        else
          w = minw
          loop do
            new_wave.call if w >= wave_ids.size
            conflict = wave_has_barrier[w] || wave_ids[w].any? { |j| entries[j].access.conflicts?(acc) }
            if conflict
              w += 1
              next
            end
            wave_ids[w] << i
            wave_of[i] = w
            break
          end
        end
      end

      wave_ids.map { |ids| ids.map { |i| entries[i] } }
    end

    # Human-readable plan: the label (or nil) of each system, grouped by wave. Handy to see
    # what `parallel` would run together (`app.parallel_plan(Flock::Schedule::Update)`).
    def parallel_plan(schedule : Schedule) : Array(Array(Symbol?))
      build_waves(ordered_systems(schedule)).map { |wave| wave.map(&.label) }
    end

    # Parallel counterpart of `run_schedule`: runs each wave (concurrently when the wave holds
    # more than one system), then applies all deferred Commands in system order at the end of
    # the schedule — same deferral point as the sequential path.
    protected def run_schedule_parallel(schedule : Schedule) : Nil
      waves = (@wave_cache[schedule] ||= build_waves(ordered_systems(schedule)))
      deferred = [] of Commands

      waves.each do |wave|
        active = wave.select do |e|
          if cond = e.run_if
            cond.call(@world)
          else
            true
          end
        end
        next if active.empty?

        if active.size == 1
          entry = active.first
          cmd = Commands.new(@world)
          @world.begin_system(entry.last_run)
          entry.proc.call(@world, cmd)
          entry.last_run = @world.change_tick
          deferred << cmd
        else
          run_wave_parallel(active, deferred)
        end
      end

      deferred.each(&.apply)
    end

    # Runs a multi-system wave concurrently. Change detection is applied at WAVE granularity:
    # one change-tick for the whole wave, and `last_run` = the oldest of the wave's systems
    # (conservative — a `changed:`/`added:` filter may fire for a few extra entities, never
    # too few). Each system gets its own Commands buffer (merged, in order, after the wave).
    private def run_wave_parallel(active : Array(SystemEntry), deferred : Array(Commands)) : Nil
      min_last = active.min_of(&.last_run)
      @world.begin_system(min_last) # bumps change_tick once; sets @last_run = min_last
      wave_tick = @world.change_tick

      active.each { |e| e.prewarm.try &.call(@world) } # create declared storages up front

      cmds = Array(Commands).new(active.size) { Commands.new(@world) }
      @world.parallel_scope = true
      begin
        {% if flag?(:preview_mt) || flag?(:execution_context) %}
          wg = WaitGroup.new(active.size)
          active.each_with_index do |entry, i|
            c = cmds[i]
            spawn do
              begin
                entry.proc.call(@world, c)
              ensure
                wg.done
              end
            end
          end
          wg.wait
        {% else %}
          App.warn_no_mt
          active.each_with_index { |entry, i| entry.proc.call(@world, cmds[i]) }
        {% end %}
      ensure
        @world.parallel_scope = false
      end

      active.each { |e| e.last_run = wave_tick }
      cmds.each { |c| deferred << c }
    end
  end
end
