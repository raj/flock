module Flock
  # Global state-machine value for a type S (usually an enum), held as a resource.
  # Transitions are deferred: `set_state` sets a pending value that is applied at the
  # start of the next frame (by the system installed via `App#add_state`), so systems
  # never observe a mid-frame state change.
  class State(S) < Resource
    property current : S
    property pending : S?

    def initialize(@current : S)
      @pending = nil
    end

    def apply_pending : Nil
      if p = @pending
        @current = p
        @pending = nil
      end
    end
  end

  class World
    def state(type : S.class) : S forall S
      resource(State(S)).current
    end

    # Requests a transition (applied at the start of the next frame).
    def set_state(value : S) : Nil forall S
      resource(State(S)).pending = value
    end
  end
end
