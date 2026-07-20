require "json"

module Flock
  # Scene serialization: snapshot the live World (opted-in components + resources) to JSON and
  # restore it — save games, level loading, duplication. Crystal has no runtime reflection, so
  # types opt in with `include Flock::Saveable` (components) / `Flock::SaveableResource`
  # (resources), which registers a (de)serializer keyed by the type's name.
  module Scene
    # Serializes one *component* type. The concrete type is captured at macro-expansion time
    # (via `ComponentSerializerFor(T)`), so no reflection is needed.
    abstract class ComponentSerializer
      # Yields (entity, component-as-JSON) for every instance in the world.
      abstract def each(world : World, &block : Entity, JSON::Any ->) : Nil
      # Deserializes `json` and adds it to `entity`, remapping any entity-reference fields
      # through `map` (old entity id -> freshly spawned Entity).
      abstract def spawn(world : World, entity : Entity, json : JSON::Any, map : Hash(UInt32, Entity)) : Nil
    end

    class ComponentSerializerFor(T) < ComponentSerializer
      def each(world : World, &block : Entity, JSON::Any ->) : Nil
        world.storage(T).each_pair { |e, c| block.call(e, JSON.parse(c.to_json)) }
      end

      def spawn(world : World, entity : Entity, json : JSON::Any, map : Hash(UInt32, Entity)) : Nil
        component = T.from_json(json.to_json)
        # Entity-reference components implement `remap_entities` (via `entity_fields`); others
        # don't respond to it (compile-time), so the branch is elided and they're added as-is.
        component = component.remap_entities(map) if component.responds_to?(:remap_entities)
        world.add(entity, component)
      end
    end

    # Serializes one *resource* type.
    abstract class ResourceSerializer
      abstract def capture(world : World) : JSON::Any?
      abstract def apply(world : World, json : JSON::Any) : Nil
    end

    class ResourceSerializerFor(T) < ResourceSerializer
      def capture(world : World) : JSON::Any?
        if r = world.resource?(T)
          JSON.parse(r.to_json)
        end
      end

      def apply(world : World, json : JSON::Any) : Nil
        world.insert_resource(T.from_json(json.to_json))
      end
    end

    # Registries populated at load time by the Saveable macros.
    COMPONENTS = {} of String => ComponentSerializer
    RESOURCES  = {} of String => ResourceSerializer

    def self.register_component(name : String, serializer : ComponentSerializer) : Nil
      COMPONENTS[name] = serializer
    end

    def self.register_resource(name : String, serializer : ResourceSerializer) : Nil
      RESOURCES[name] = serializer
    end
  end

  # Mark a component `struct` as part of the saved scene: `include Flock::Saveable`. Adds
  # JSON::Serializable and registers a serializer under the type's fully-qualified name. All the
  # component's fields must themselves be JSON-serializable (Flock's Vec2/Vec3/Color/Entity are).
  module Saveable
    macro included
      include JSON::Serializable
      ::Flock::Scene.register_component({{@type.name.stringify}}, ::Flock::Scene::ComponentSerializerFor({{@type}}).new)
    end

    # Declares which fields hold `Entity` references, so they are remapped from saved ids to
    # freshly spawned entities on load. Each named field must be `Entity` or `Entity?`. Available
    # once the component `include`s `Flock::Saveable`:
    #
    #   struct Follow
    #     include Flock::Component
    #     include Flock::Saveable
    #     property target : Flock::Entity
    #     entity_fields target
    #   end
    # Pins the name this component is saved under, independent of the Crystal type name — so a
    # type rename doesn't invalidate existing save files. Call after `include Flock::Saveable`:
    #
    #   struct Position
    #     include Flock::Component
    #     include Flock::Saveable
    #     saveable_as "Position"   # stays "Position" even if the struct is renamed/namespaced
    #   end
    macro saveable_as(key)
      ::Flock::Scene::COMPONENTS.delete({{@type.name.stringify}}) # drop the auto type-name entry
      ::Flock::Scene.register_component({{key}}, ::Flock::Scene::ComponentSerializerFor({{@type}}).new)
    end

    macro entity_fields(*names)
      # Returns a copy with every declared entity field remapped through `map` (old id -> Entity).
      # A reference to an entity absent from the scene is left unchanged.
      def remap_entities(map : Hash(UInt32, ::Flock::Entity)) : self
        copy = self
        {% for name in names %}
          if __e = copy.{{name.id}}
            if __mapped = map[__e.id]?
              copy.{{name.id}} = __mapped
            end
          end
        {% end %}
        copy
      end
    end
  end

  # Mark a `Resource` subclass as saved: `include Flock::SaveableResource`.
  module SaveableResource
    macro included
      include JSON::Serializable
      ::Flock::Scene.register_resource({{@type.name.stringify}}, ::Flock::Scene::ResourceSerializerFor({{@type}}).new)
    end
  end
end
