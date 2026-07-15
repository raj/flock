module Flock
  # Queue of deferred structural mutations. Applied by the App after each
  # stage, so as not to invalidate an in-progress query (dense pointers are
  # sensitive to reallocations caused by add/spawn/despawn).
  #
  #   cmd.spawn(Transform2D.new(...), Sprite.new(...))
  #   cmd.despawn(entity)
  class Commands
    @ops : Array(Proc(World, Nil)) = [] of Proc(World, Nil)

    def initialize(@world : World)
    end

    # Immediately reserves an entity (the id is valid right away) and queues
    # the addition of its components. Usable without a component: `cmd.spawn`.
    # (One method overload per arity, 0 to 8 arguments — macros cannot be
    # invoked on an instance in Crystal.)
    #
    # Any argument may be a plain component OR a `Flock::Bundle` (a group of
    # components); bundles are expanded — and mixed with plain components — when
    # the queue is applied. So `cmd.spawn(PlayerBundle.new(...), Velocity.new)`
    # counts as 2 arguments regardless of how many components the bundle holds.
    {% for n in 0..8 %}
      def spawn(
        {% for i in 1..n %}c{{i}} : C{{i}}{% if i < n %},{% end %}{% end %}
      ) : Entity {% if n > 0 %}forall {% for i in 1..n %}C{{i}}{% if i < n %},{% end %}{% end %}{% end %}
        entity = @world.spawn
        {% for i in 1..n %}
          add(entity, c{{i}})
        {% end %}
        entity
      end
    {% end %}

    def add(entity : Entity, component : T) : Nil forall T
      @ops << ->(w : World) { w.add(entity, component); nil }
    end

    def remove(entity : Entity, type : T.class) : Nil forall T
      @ops << ->(w : World) { w.remove(entity, T); nil }
    end

    def despawn(entity : Entity) : Nil
      @ops << ->(w : World) { w.despawn(entity); nil }
    end

    # Applies then clears the queue.
    def apply(world : World = @world) : Nil
      @ops.each &.call(world)
      @ops.clear
    end

    def empty? : Bool
      @ops.empty?
    end
  end
end
