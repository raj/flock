module Flock
  # Entité légère : un ID unique + une génération pour distinguer un ID recyclé
  # d'un ancien handle. Type valeur (struct) : pas d'allocation.
  struct Entity
    getter id : UInt32
    getter generation : UInt32

    def initialize(@id : UInt32, @generation : UInt32)
    end
  end
end
