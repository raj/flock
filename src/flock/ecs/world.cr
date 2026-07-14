module Flock
  # Global singleton (Time, Input, Audio, GpuContext…). To be subclassed.
  abstract class Resource
    # Releases owned native resources. No-op by default; overridden by resources
    # that own GPU/SDL handles (GpuContext, Renderer2D, Material).
    def release : Nil
    end

    # Release order (ascending). GpuContext is released last (it owns the device
    # the others depend on).
    def release_order : Int32
      0
    end
  end

  # Central ECS container: entities, component storages, resources.
  class World
    @next_entity_id : UInt32 = 0_u32
    @generations : Array(UInt32) = [] of UInt32
    @free_ids : Array(UInt32) = [] of UInt32

    # Storages indexed by `component_id` (O(1), no hashing). `nil` = not yet created.
    @storages : Array(Storage?) = [] of Storage?
    @resources : Hash(String, Resource) = {} of String => Resource

    # --- Entities ----------------------------------------------------------

    def spawn : Entity
      if id = @free_ids.pop?
        @generations[id] += 1
        Entity.new(id, @generations[id])
      else
        id = @next_entity_id
        @next_entity_id += 1
        @generations << 0_u32
        Entity.new(id, 0_u32)
      end
    end

    def alive?(entity : Entity) : Bool
      id = entity.id
      id < @generations.size && @generations[id] == entity.generation
    end

    # Removes the entity from all storages then recycles its id.
    def despawn(entity : Entity) : Nil
      return unless alive?(entity)
      @storages.each do |storage|
        storage.try &.remove_untyped(entity)
      end
      @generations[entity.id] += 1 # invalidates existing handles
      @free_ids << entity.id
    end

    # --- Components --------------------------------------------------------

    def storage(type : T.class) : SparseSet(T) forall T
      # Compile-time validation: a component must `include Flock::Component`
      # (provides `component_id`). Clear message rather than an obscure "undefined method".
      {% raise "#{T} is not a component: add `include Flock::Component`" unless T < Flock::Component %}
      id = T.component_id
      while @storages.size <= id
        @storages << nil
      end
      if existing = @storages[id]
        existing.as(SparseSet(T))
      else
        set = SparseSet(T).new
        @storages[id] = set
        set
      end
    end

    def add(entity : Entity, component : T) : Nil forall T
      storage(T).insert(entity, component)
    end

    def get(entity : Entity, type : T.class) : T? forall T
      storage(T).get?(entity)
    end

    def get_ptr(entity : Entity, type : T.class) : Pointer(T)? forall T
      storage(T).get_ptr(entity)
    end

    def has?(entity : Entity, type : T.class) : Bool forall T
      storage(T).has?(entity)
    end

    def remove(entity : Entity, type : T.class) : Nil forall T
      storage(T).remove(entity)
    end

    # --- Resources ---------------------------------------------------------

    def insert_resource(resource : Resource) : Nil
      @resources[resource.class.name] = resource
    end

    def resource(type : T.class) : T forall T
      res = @resources[T.name]?
      raise "Resource #{T} missing from World" unless res
      res.as(T)
    end

    def resource?(type : T.class) : T? forall T
      @resources[T.name]?.as(T?)
    end

    # Releases all resources (ascending release_order) and clears the
    # registry. Called by App#run on shutdown.
    def shutdown : Nil
      @resources.values.sort_by(&.release_order).each(&.release)
      @resources.clear
    end

    # --- Query -------------------------------------------------------------

    # Iterates entities that own ALL the listed components. Components are
    # yielded as Pointer(T) (access to the dense array).
    #
    #   world.query(Position, Velocity) do |entity, pos, vel|
    #     p = pos.value        # read
    #     p.x += vel.value.dx  # modify
    #     pos.value = p        # write back (the sugar `pos.value.x += …` does not persist)
    #   end
    #
    # Read-only: `pos.value.x`. Single-field mutation: the direct assignment
    # `pos.value.x = pos.value.x + dx` also works.
    #
    # Drives over the smallest set of entities and does a single lookup per
    # component. Iteration runs over a copy (`dup`): the block may therefore
    # despawn without corrupting the traversal (prefer Commands for additions,
    # which may reallocate the dense arrays and invalidate the pointers).
    #
    # (Macros cannot be invoked on an instance in Crystal: so we generate a
    # real `query` method overload per arity, 1 to 8 components.)
    {% for n in 1..8 %}
      def query(
        {% for i in 1..n %}t{{i}} : T{{i}}.class{% if i < n %},{% end %}{% end %}
      ) : Nil forall {% for i in 1..n %}T{{i}}{% if i < n %},{% end %}{% end %}
        {% for i in 1..n %}
          s{{i}} = storage(T{{i}})
        {% end %}

        drv = s1.entities
        {% for i in 2..n %}
          drv = s{{i}}.entities if s{{i}}.entities.size < drv.size
        {% end %}

        drv.dup.each do |entity|
          {% for i in 1..n %}
            p{{i}} = s{{i}}.get_ptr(entity)
            next unless p{{i}}
          {% end %}
          yield entity, {% for i in 1..n %}p{{i}}{% if i < n %},{% end %}{% end %}
        end
      end
    {% end %}
  end
end
