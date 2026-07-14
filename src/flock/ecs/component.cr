module Flock
  # Attribue un id entier dense et stable à chaque type de composant, dans l'ordre
  # de première utilisation. Permet de ranger les storages dans un Array indexé par
  # id (O(1), sans hashing) plutôt que dans un Hash keyé par nom de classe.
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

  # À inclure dans tout type utilisé comme composant :
  #   struct Position; include Flock::Component; ... end
  # Chaque type obtient son propre `component_id` (mémoïsé, unique).
  module Component
    macro included
      class_getter component_id : Int32 = Flock::ComponentRegistry.next_id
    end
  end
end
