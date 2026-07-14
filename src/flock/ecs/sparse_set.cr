module Flock
  # Interface type-erased : permet à World de manipuler tous les storages sans
  # connaître leur type concret (indispensable pour `despawn`, qui doit retirer une
  # entité de tous les storages).
  abstract class Storage
    abstract def remove_untyped(entity : Entity)
    abstract def size : Int32
  end

  # Stockage dense d'un composant T, indexé de façon éparse par id d'entité.
  #
  # - `dense`/`entities` : tableaux compacts (itération cache-friendly).
  # - `sparse` : id d'entité -> index dense, sentinelle -1 = absent (pas d'union
  #   nilable, plus léger en hot path).
  #
  # La mutation en place se fait via `get_ptr`, qui renvoie un pointeur dans le
  # tableau dense. Ce pointeur reste valide tant qu'aucune insertion/suppression ne
  # réalloue le tableau : toute mutation structurelle en cours d'itération doit donc
  # passer par `Commands` (différé).
  class SparseSet(T) < Storage
    getter dense : Array(T) = [] of T
    getter entities : Array(Entity) = [] of Entity
    @sparse : Array(Int32) = [] of Int32

    def size : Int32
      @dense.size
    end

    # Index dense de l'entité si présente et de génération concordante.
    def index_of?(entity : Entity) : Int32?
      id = entity.id.to_i
      return nil if id >= @sparse.size
      index = @sparse[id]
      return nil if index < 0
      return nil if @entities[index].generation != entity.generation
      index
    end

    def has?(entity : Entity) : Bool
      !index_of?(entity).nil?
    end

    # Copie du composant (lecture seule pratique).
    def get?(entity : Entity) : T?
      if index = index_of?(entity)
        @dense[index]
      end
    end

    # Pointeur vers le composant dans le tableau dense : `ptr.value.x = …` mute
    # en place. Voir l'avertissement sur la validité du pointeur en tête de classe.
    def get_ptr(entity : Entity) : Pointer(T)?
      if index = index_of?(entity)
        @dense.to_unsafe + index
      end
    end

    # Insère ou met à jour le composant de l'entité.
    def insert(entity : Entity, component : T) : Nil
      id = entity.id.to_i
      while @sparse.size <= id
        @sparse << -1
      end

      index = @sparse[id]
      if index >= 0 && @entities[index].generation == entity.generation
        @dense[index] = component
        @entities[index] = entity
      else
        @sparse[id] = @dense.size
        @dense << component
        @entities << entity
      end
    end

    # Retrait O(1) par swap-and-pop.
    def remove(entity : Entity) : Nil
      id = entity.id.to_i
      return if id >= @sparse.size
      index = @sparse[id]
      return if index < 0
      return if @entities[index].generation != entity.generation

      last = @dense.size - 1
      last_entity = @entities[last]

      @dense[index] = @dense[last]
      @entities[index] = last_entity
      @sparse[last_entity.id.to_i] = index

      @dense.pop
      @entities.pop
      @sparse[id] = -1
    end

    def remove_untyped(entity : Entity) : Nil
      remove(entity)
    end
  end
end
