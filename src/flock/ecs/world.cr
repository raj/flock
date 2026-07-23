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

    # Per-frame hook, called once each frame by the App on EVERY resource. No-op by
    # default; Events(T) overrides it to advance its double buffer, so sending an event
    # works without a manual `App#add_event` registration.
    def frame_update : Nil
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

    # Change detection. `change_tick` is bumped once per system run (by App#run_schedule
    # via begin_system); component writes stamp it, and a query filter / predicate reports
    # a change when the stamped tick is newer than the running system's last-run tick.
    getter change_tick : UInt32 = 1_u32
    @last_run : UInt32 = 0_u32

    # Called by App before each system runs: bumps the change-tick and records the tick the
    # about-to-run system last executed at (so changed?/added? are relative to it).
    def begin_system(last_run : UInt32) : Nil
      @change_tick &+= 1_u32
      @last_run = last_run
    end

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
      # Ignore inserts for dead handles (e.g. a deferred `cmd.despawn(e)` then
      # `cmd.add(e, …)` in the same frame) — they would orphan an unreachable dense entry.
      return unless alive?(entity)
      {% if T < Flock::Bundle %}
        # A bundle expands into its individual components (each keeps its concrete
        # type, so it reaches the right storage). Bundles nest recursively.
        expand_bundle(entity, component.components)
      {% else %}
        storage(T).insert(entity, component, @change_tick)
      {% end %}
    end

    # Re-inserts a component and marks it changed at the current tick. Use after computing
    # a new value; equivalent to `add` but reads as intent ("I changed this").
    def set(entity : Entity, component : T) : Nil forall T
      add(entity, component)
    end

    # Flags an existing component as changed at the current tick — for in-place pointer
    # mutations (`query`/`get_ptr`), which the storage can't observe automatically.
    def mark_changed(entity : Entity, type : T.class) : Nil forall T
      storage(T).touch(entity, @change_tick)
    end

    # Did the entity's T component change since the running system last ran?
    def changed?(entity : Entity, type : T.class) : Bool forall T
      t = storage(T).changed_tick(entity)
      t ? t > @last_run : false
    end

    # Was the entity's T component added since the running system last ran?
    def added?(entity : Entity, type : T.class) : Bool forall T
      t = storage(T).added_tick(entity)
      t ? t > @last_run : false
    end

    # Adds each component of a bundle's tuple, one storage insert per element.
    private def expand_bundle(entity : Entity, comps : T) : Nil forall T
      {% for i in 0...T.type_vars.size %}
        add(entity, comps[{{i}}])
      {% end %}
    end

    def get(entity : Entity, type : T.class) : T? forall T
      storage(T).get?(entity)
    end

    # Returns a raw `Pointer(T)` to the component's storage slot (nil if absent).
    #
    # ⚠ MUTATION CAVEAT (same as `query`): with struct components, the compound
    # sugar `ptr.value.field += x` does NOT persist — Crystal mutates a temporary
    # copy of the struct and discards it. To write back you must assign the whole
    # value, e.g. `ptr.value.field = ptr.value.field + x`, or read the struct into
    # a local, mutate it, then `ptr.value = local`.
    #
    # ⚠ The pointer is also invalidated by any structural mutation (`add`/`despawn`)
    # that reallocates or reorders the dense arrays — do not hold it across those.
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
      # Release the previous resource of the same type before overwriting it, so a
      # replaced GPU/SDL-backed resource doesn't leak its native handle. Skip when
      # re-inserting the exact same object (releasing then keeping it would be a bug).
      existing = @resources[resource.class.name]?
      if existing && !existing.same?(resource) && existing.responds_to?(:release)
        existing.release
      end
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
    # component. Iteration runs over a copy (`dup`), so the traversal itself is
    # safe against structural changes in the block.
    #
    # POINTER VALIDITY: the yielded `Pointer(T)`s point into the dense arrays and
    # are invalidated by ANY structural mutation during the SAME iteration —
    # `add` (may reallocate) OR `despawn` (swap-and-pop moves another entity into
    # the freed slot, so a stale pointer then aliases an unrelated live entity).
    # Do NOT read or write through a component pointer after despawning/adding in
    # the block. Read what you need first, then defer the mutation via `Commands`
    # (applied after the schedule) — that is the intended pattern.
    #
    # (Macros cannot be invoked on an instance in Crystal: so we generate a
    # real `query` method overload per arity, 1 to 8 components.)
    # Optional keyword filters (tuples of component classes, expanded at compile time):
    #   with:    entity must ALSO own these (not yielded) — like Bevy's `With<T>`
    #   without: entity must NOT own any of these                 — `Without<T>`
    #   changed: entity's component must have changed this run     — `Changed<T>`
    #   added:   entity's component must have been added this run  — `Added<T>`
    #
    #   world.query(Sprite, with: {Enemy}, without: {Frozen}) { |e, sp| ... }
    #   world.query(Score, changed: {Score}) { |e, s| refresh_hud(s.value) }
    #
    # `changed`/`added` rely on the tick set by `add`/`set`/`mark_changed`; a raw pointer
    # write is invisible unless you follow it with `mark_changed` (or write via `set`).
    {% for n in 1..8 %}
      def query(
        {% for i in 1..n %}t{{i}} : T{{i}}.class,{% end %}
        with _with = Tuple.new, without _without = Tuple.new,
        changed _changed = Tuple.new, added _added = Tuple.new
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

          keep = true
          _with.each { |c| keep = false unless has?(entity, c) }
          _without.each { |c| keep = false if has?(entity, c) }
          _changed.each { |c| keep = false unless changed?(entity, c) }
          _added.each { |c| keep = false unless added?(entity, c) }
          next unless keep

          yield entity, {% for i in 1..n %}p{{i}}{% if i < n %},{% end %}{% end %}
        end
      end
    {% end %}
  end
end
