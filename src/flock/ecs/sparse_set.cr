module Flock
  # Type-erased interface: lets World manipulate all storages without knowing
  # their concrete type (essential for `despawn`, which must remove an entity
  # from all storages).
  abstract class Storage
    abstract def remove_untyped(entity : Entity)
    abstract def size : Int32
  end

  # Dense storage of a component T, sparsely indexed by entity id.
  #
  # - `dense`/`entities`: compact arrays (cache-friendly iteration).
  # - `sparse`: entity id -> dense index, sentinel -1 = absent (no nilable
  #   union, lighter on the hot path).
  #
  # In-place mutation goes through `get_ptr`, which returns a pointer into the
  # dense array. This pointer stays valid as long as no insertion/removal
  # reallocates the array: any structural mutation during iteration must
  # therefore go through `Commands` (deferred).
  class SparseSet(T) < Storage
    getter dense : Array(T) = [] of T
    getter entities : Array(Entity) = [] of Entity
    @sparse : Array(Int32) = [] of Int32
    # Change-detection ticks, aligned with `dense`: the world change-tick at which each
    # component was added / last changed (see World#changed?/#added?).
    @added : Array(UInt32) = [] of UInt32
    @changed : Array(UInt32) = [] of UInt32

    def size : Int32
      @dense.size
    end

    # Yields every (entity, component) pair. Read-only (component is a copy); used by the
    # scene/save system to snapshot a storage.
    def each_pair(& : Entity, T ->) : Nil
      @entities.each_with_index { |e, i| yield e, @dense[i] }
    end

    # Dense index of the entity if present and of matching generation.
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

    # Copy of the component (convenient read-only).
    def get?(entity : Entity) : T?
      if index = index_of?(entity)
        @dense[index]
      end
    end

    # Pointer to the component in the dense array: `ptr.value.x = …` mutates
    # in place. See the pointer-validity warning at the top of the class.
    def get_ptr(entity : Entity) : Pointer(T)?
      if index = index_of?(entity)
        @dense.to_unsafe + index
      end
    end

    # Inserts or updates the entity's component. `tick` is the world change-tick stamped
    # as the change (and, for a fresh insert, the added) tick.
    def insert(entity : Entity, component : T, tick : UInt32 = 0_u32) : Nil
      id = entity.id.to_i
      while @sparse.size <= id
        @sparse << -1
      end

      index = @sparse[id]
      if index >= 0
        # The slot is occupied — an id has at most one dense entry, so overwrite it in place
        # whether it's the same generation (update) or a stale one (replace); never push a
        # second entry, which would orphan the old one and corrupt iteration.
        replaced = @entities[index].generation != entity.generation
        @dense[index] = component
        @entities[index] = entity
        @changed[index] = tick
        @added[index] = tick if replaced # a stale-generation replace is a new component
      else
        @sparse[id] = @dense.size
        @dense << component
        @entities << entity
        @added << tick
        @changed << tick
      end
    end

    # O(1) removal via swap-and-pop.
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
      @added[index] = @added[last]
      @changed[index] = @changed[last]
      @sparse[last_entity.id.to_i] = index

      @dense.pop
      @entities.pop
      @added.pop
      @changed.pop
      @sparse[id] = -1
    end

    def remove_untyped(entity : Entity) : Nil
      remove(entity)
    end

    # Change-detection ticks for an entity (nil if it doesn't own the component).
    def added_tick(entity : Entity) : UInt32?
      if index = index_of?(entity)
        @added[index]
      end
    end

    def changed_tick(entity : Entity) : UInt32?
      if index = index_of?(entity)
        @changed[index]
      end
    end

    # Stamps the entity's component as changed at `tick` (for in-place pointer mutations,
    # which the storage can't observe on its own).
    def touch(entity : Entity, tick : UInt32) : Nil
      if index = index_of?(entity)
        @changed[index] = tick
      end
    end
  end
end
