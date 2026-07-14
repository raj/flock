module Flock
  # File de mutations structurelles différées. Appliquée par l'App après chaque
  # stage, pour ne pas invalider une query en cours (les pointeurs dense sont
  # sensibles aux réallocations provoquées par add/spawn/despawn).
  #
  #   cmd.spawn(Transform2D.new(...), Sprite.new(...))
  #   cmd.despawn(entity)
  class Commands
    @ops : Array(Proc(World, Nil)) = [] of Proc(World, Nil)

    def initialize(@world : World)
    end

    # Réserve immédiatement une entité (l'id est valide tout de suite) et met en
    # file l'ajout de ses composants. Utilisable sans composant : `cmd.spawn`.
    # (Une surcharge de méthode par arité, 0 à 8 composants — les macros ne sont
    # pas invocables sur une instance en Crystal.)
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

    # Applique puis vide la file.
    def apply(world : World = @world) : Nil
      @ops.each &.call(world)
      @ops.clear
    end

    def empty? : Bool
      @ops.empty?
    end
  end
end
