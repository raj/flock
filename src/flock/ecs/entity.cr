module Flock
  # Lightweight entity: a unique ID + a generation to distinguish a recycled ID
  # from an old handle. Value type (struct): no allocation.
  struct Entity
    getter id : UInt32
    getter generation : UInt32

    def initialize(@id : UInt32, @generation : UInt32)
    end
  end
end
