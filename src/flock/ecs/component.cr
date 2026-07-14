module Flock
  # Assigns a dense, stable integer id to each component type, in order of first
  # use. Lets storages be stored in an Array indexed by id (O(1), no hashing)
  # rather than in a Hash keyed by class name.
  module ComponentRegistry
    @@count = 0

    def self.next_id : Int32
      id = @@count
      @@count += 1
      id
    end

    def self.count : Int32
      @@count
    end
  end

  # To be included in any type used as a component:
  #   struct Position; include Flock::Component; ... end
  # Each type gets its own `component_id` (memoized, unique).
  module Component
    macro included
      class_getter component_id : Int32 = Flock::ComponentRegistry.next_id
    end
  end
end
