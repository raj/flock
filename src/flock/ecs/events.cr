module Flock
  # Event queue for a type T (a resource, one per event type). Double-buffered:
  # events live for the frame they are sent AND the next one, so an `EventReader`
  # never misses an event even if it runs before the sender. `App#add_event(T)`
  # advances the buffers once per frame.
  #
  # Two ways to read:
  # - `world.each_event(T)` — iterates THIS frame's events (simple; sender must run
  #   before the reader within the frame).
  # - an `EventReader(T)` — a persistent per-reader cursor that yields each event
  #   exactly once, across frames.
  class Events(T) < Resource
    @buf_a : Array(T) = [] of T
    @buf_b : Array(T) = [] of T
    @start_a : Int32 = 0 # global index of buf_a[0]
    @start_b : Int32 = 0
    @a_newer : Bool = true # which buffer holds the current frame's events
    @count : Int32 = 0     # total events ever sent (= next global index)
    # The owning World, wired on creation. Used ONLY to reach the shared entity lock and the
    # `parallel_scope` flag: while a parallel wave is active the reader snapshots its buffers
    # under that lock (a concurrent `send` appends under the same lock, so the array can't be
    # reallocated mid-iteration). nil / non-parallel = zero-cost, iterate the live buffer.
    @world : World? = nil

    def attach(world : World) : Nil
      @world = world
    end

    private def newer : Array(T)
      @a_newer ? @buf_a : @buf_b
    end

    def send(event : T) : Nil
      newer << event
      @count += 1
    end

    # This frame's events. Snapshots the count up front so a handler that sends the same
    # event type does not extend this iteration (avoids an unbounded loop). Note: those
    # re-sent events are NOT seen by `each` (this or next frame) — only an `EventReader`
    # picks them up. If a handler resends its own event type, use an EventReader.
    def each(& : T ->) : Nil
      # Under a parallel wave, iterate a snapshot taken under the shared lock: a concurrent
      # `send` (same lock) can't reallocate the buffer while we read it. The lock is released
      # before the first yield, so a handler that resends is never blocked. Sequential path
      # aliases the live buffer (no copy, no lock) — identical to before.
      b = snapshot(newer)
      n = b.size
      i = 0
      while i < n
        yield b[i]
        i += 1
      end
    end

    # Returns `buf` itself on the sequential path; a copy taken under the shared lock while a
    # parallel wave is active (so a concurrent append can't reallocate it mid-read).
    private def snapshot(buf : Array(T)) : Array(T)
      w = @world
      return buf unless w && w.parallel_scope
      w.event_lock_synchronize { buf.dup }
    end

    def size : Int32
      newer.size
    end

    def total : Int32
      @count
    end

    def clear : Nil
      @buf_a.clear
      @buf_b.clear
      @start_a = @start_b = @count
    end

    # Advances one frame: keeps this frame + last frame, drops anything older.
    def update : Nil
      if @a_newer
        @buf_b.clear; @start_b = @count; @a_newer = false
      else
        @buf_a.clear; @start_a = @count; @a_newer = true
      end
    end

    # Called once per frame by the App (via World#update_events) on every resource.
    def frame_update : Nil
      update
    end

    # Yields events with global index >= `from` (oldest buffer first); returns the
    # new cursor (total count). Used by EventReader.
    def read_from(from : Int32, & : T ->) : Int32
      # Snapshot the target count up front: only events that existed at entry (global index
      # < target) are delivered now, and the cursor advances to exactly `target`. An event SENT
      # by a handler during this read (index >= target) is deferred to the next read — delivered
      # once, never skipped (returning the live @count would skip it). While a parallel wave is
      # active the buffers, their index bases, and `target` are all snapshotted together under
      # the shared lock, so a concurrent `send` can't reallocate a buffer or leave `target`
      # inconsistent with them; the lock is released before any yield.
      w = @world
      if w && w.parallel_scope
        a, b, sa, sb, an, target = w.event_lock_synchronize do
          {@buf_a.dup, @buf_b.dup, @start_a, @start_b, @a_newer, @count}
        end
      else
        a, b, sa, sb, an, target = @buf_a, @buf_b, @start_a, @start_b, @a_newer, @count
      end
      if an
        emit(b, sb, from, target) { |e| yield e }
        emit(a, sa, from, target) { |e| yield e }
      else
        emit(a, sa, from, target) { |e| yield e }
        emit(b, sb, from, target) { |e| yield e }
      end
      target
    end

    private def emit(buf : Array(T), start : Int32, from : Int32, target : Int32, & : T ->) : Nil
      # Snapshot the length so a reader that sends the same type doesn't loop forever;
      # the `gi < target` bound skips events appended during this read (delivered next read).
      n = buf.size
      i = 0
      while i < n
        gi = start + i
        yield buf[i] if gi >= from && gi < target
        i += 1
      end
    end
  end

  # A persistent per-reader cursor over Events(T): yields each event exactly once,
  # across frames. Create one and capture it in a system closure so it survives frames:
  #
  #   reader = Flock::EventReader(DamageEvent).new
  #   app.add_system(Flock::Schedule::Update) do |world, _cmd|
  #     reader.read(world.events(DamageEvent)) { |e| ... }
  #   end
  class EventReader(T)
    @cursor : Int32 = 0

    def read(events : Events(T), & : T ->) : Nil
      @cursor = events.read_from(@cursor) { |e| yield e }
    end
  end

  class World
    # Returns the Events(T) resource, creating it lazily on first use.
    #
    # First-use creation mutates the shared `@resources` Hash (a rehash can corrupt it),
    # so while a parallel wave is active the lookup/insert is serialized under the same
    # lock as entity allocation. The sequential path takes no lock (see `@parallel_scope`).
    def events(type : T.class) : Events(T) forall T
      return @entity_lock.synchronize { get_or_create_events(T) } if @parallel_scope
      get_or_create_events(T)
    end

    private def get_or_create_events(type : T.class) : Events(T) forall T
      key = Events(T).name
      if existing = @resources[key]?
        existing.as(Events(T))
      else
        ev = Events(T).new
        ev.attach(self) # wire the shared lock so parallel reads can snapshot safely
        @resources[key] = ev
        ev
      end
    end

    # Sends an event. Under a parallel wave, both the lazy queue creation AND the append
    # (`@newer << event; @count += 1`, not otherwise thread-safe) happen under the lock, so
    # two systems sending the same event type in one wave don't race. Note: not called
    # nested with `events`, so the (non-reentrant) mutex never re-locks.
    def send_event(event : T) : Nil forall T
      return @entity_lock.synchronize { get_or_create_events(T).send(event) } if @parallel_scope
      get_or_create_events(T).send(event)
    end

    def each_event(type : T.class, & : T ->) forall T
      events(T).each { |e| yield e }
    end

    # Advances every event queue's double buffer by one frame. The App calls this once per
    # frame after Last, so events are readable for the frame they were sent plus the next —
    # no per-type `add_event` registration required.
    def update_events : Nil
      @resources.each_value(&.frame_update)
    end
  end
end
