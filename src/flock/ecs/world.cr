module Flock
  # Singleton global (Time, Input, Audio, GpuContext…). À sous-classer.
  abstract class Resource
    # Libère les ressources natives détenues. No-op par défaut ; surchargé par les
    # ressources qui possèdent des handles GPU/SDL (GpuContext, Renderer2D, Material).
    def release : Nil
    end

    # Ordre de libération (croissant). GpuContext se libère en dernier (il détient le
    # device dont dépendent les autres).
    def release_order : Int32
      0
    end
  end

  # Conteneur central de l'ECS : entités, storages de composants, ressources.
  class World
    @next_entity_id : UInt32 = 0_u32
    @generations : Array(UInt32) = [] of UInt32
    @free_ids : Array(UInt32) = [] of UInt32

    # Storages indexés par `component_id` (O(1), sans hashing). `nil` = pas encore créé.
    @storages : Array(Storage?) = [] of Storage?
    @resources : Hash(String, Resource) = {} of String => Resource

    # --- Entités -----------------------------------------------------------

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

    # Retire l'entité de tous les storages puis recycle son id.
    def despawn(entity : Entity) : Nil
      return unless alive?(entity)
      @storages.each do |storage|
        storage.try &.remove_untyped(entity)
      end
      @generations[entity.id] += 1 # invalide les handles existants
      @free_ids << entity.id
    end

    # --- Composants --------------------------------------------------------

    def storage(type : T.class) : SparseSet(T) forall T
      # Validation compile-time : un composant doit `include Flock::Component`
      # (fournit `component_id`). Message clair plutôt qu'un obscur "undefined method".
      {% raise "#{T} n'est pas un composant : ajoute `include Flock::Component`" unless T < Flock::Component %}
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

    # --- Ressources --------------------------------------------------------

    def insert_resource(resource : Resource) : Nil
      @resources[resource.class.name] = resource
    end

    def resource(type : T.class) : T forall T
      res = @resources[T.name]?
      raise "Resource #{T} absente du World" unless res
      res.as(T)
    end

    def resource?(type : T.class) : T? forall T
      @resources[T.name]?.as(T?)
    end

    # Libère toutes les ressources (ordre croissant de release_order) et vide le
    # registre. Appelé par App#run à la fermeture.
    def shutdown : Nil
      @resources.values.sort_by(&.release_order).each(&.release)
      @resources.clear
    end

    # --- Query -------------------------------------------------------------

    # Itère les entités possédant TOUS les composants listés. Les composants sont
    # yieldés comme Pointer(T) (accès au tableau dense).
    #
    #   world.query(Position, Velocity) do |entity, pos, vel|
    #     p = pos.value        # lire
    #     p.x += vel.value.dx  # modifier
    #     pos.value = p        # réécrire (le sucre `pos.value.x += …` ne persiste pas)
    #   end
    #
    # Lecture seule : `pos.value.x`. Mutation d'un seul champ : l'affectation
    # directe `pos.value.x = pos.value.x + dx` fonctionne aussi.
    #
    # Pilote sur le plus petit ensemble d'entités et fait un seul lookup par
    # composant. L'itération se fait sur une copie (`dup`) : le bloc peut donc
    # despawn sans corrompre le parcours (préférer Commands pour les ajouts, qui
    # peuvent réallouer les tableaux dense et invalider les pointeurs).
    #
    # (Les macros ne sont pas invocables sur une instance en Crystal : on génère
    # donc une vraie surcharge de méthode `query` par arité, 1 à 8 composants.)
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
