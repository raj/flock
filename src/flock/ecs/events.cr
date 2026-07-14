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

    private def newer : Array(T)
      @a_newer ? @buf_a : @buf_b
    end

    def send(event : T) : Nil
      newer << event
      @count += 1
    end

    # This frame's events.
    def each(& : T ->) : Nil
      newer.each { |e| yield e }
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

    # Yields events with global index >= `from` (oldest buffer first); returns the
    # new cursor (total count). Used by EventReader.
    def read_from(from : Int32, & : T ->) : Int32
      if @a_newer
        emit(@buf_b, @start_b, from) { |e| yield e }
        emit(@buf_a, @start_a, from) { |e| yield e }
      else
        emit(@buf_a, @start_a, from) { |e| yield e }
        emit(@buf_b, @start_b, from) { |e| yield e }
      end
      @count
    end

    private def emit(buf : Array(T), start : Int32, from : Int32, & : T ->) : Nil
      buf.each_with_index do |e, i|
        yield e if (start + i) >= from
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
    def events(type : T.class) : Events(T) forall T
      key = Events(T).name
      if existing = @resources[key]?
        existing.as(Events(T))
      else
        ev = Events(T).new
        @resources[key] = ev
        ev
      end
    end

    def send_event(event : T) : Nil forall T
      events(T).send(event)
    end

    def each_event(type : T.class, & : T ->) forall T
      events(T).each { |e| yield e }
    end
  end
end
