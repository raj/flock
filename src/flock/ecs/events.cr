module Flock
  # Frame-scoped event queue for a type T (a resource, one per event type). Systems
  # `send` events and other systems read them the same frame; the queue is cleared
  # once per frame by the system installed via `App#add_event(T)`. Order matters:
  # the sender must run before the reader within the frame.
  class Events(T) < Resource
    @buffer : Array(T) = [] of T

    def send(event : T) : Nil
      @buffer << event
    end

    def each(& : T ->) : Nil
      @buffer.each { |e| yield e }
    end

    def size : Int32
      @buffer.size
    end

    def clear : Nil
      @buffer.clear
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
