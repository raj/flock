require "json"
require "./registry"

module Flock
  module Scene
    # One entity in a serialized scene: its (old) id + its saved components keyed by type name.
    class SavedEntity
      include JSON::Serializable
      getter id : UInt32
      getter components : Hash(String, JSON::Any)

      def initialize(@id, @components)
      end
    end

    # A serialized snapshot of the saveable part of a World: entities + resources. Round-trips
    # through `to_json` / `Document.from_json`.
    class Document
      include JSON::Serializable
      getter version : Int32
      getter entities : Array(SavedEntity)
      getter resources : Hash(String, JSON::Any)

      def initialize(@entities, @resources, @version = 1)
      end
    end

    VERSION = 1

    # Snapshots every registered (Saveable) component + resource in `world`.
    def self.capture(world : World) : Document
      by_entity = {} of UInt32 => Hash(String, JSON::Any)
      COMPONENTS.each do |name, ser|
        ser.each(world) do |entity, json|
          (by_entity[entity.id] ||= {} of String => JSON::Any)[name] = json
        end
      end
      entities = by_entity.keys.sort!.map { |id| SavedEntity.new(id, by_entity[id]) }

      resources = {} of String => JSON::Any
      RESOURCES.each do |name, ser|
        if json = ser.capture(world)
          resources[name] = json
        end
      end
      Document.new(entities, resources, VERSION)
    end

    # Serializes the current saveable state to a JSON string / a file.
    def self.to_json(world : World) : String
      capture(world).to_json
    end

    def self.save(world : World, path : String) : Nil
      File.write(path, to_json(world))
    end

    def self.from_json(json : String) : Document
      Document.from_json(json)
    end

    def self.load(path : String) : Document
      from_json(File.read(path))
    end

    # Spawns `doc` into `world` ADDITIVELY (existing entities are untouched). Two passes: first
    # allocate a fresh Entity per saved id (building the old-id -> new-Entity map), then add the
    # components (remapping entity references through the map). Unknown types are skipped with a
    # warning. Returns the id map.
    def self.spawn(world : World, doc : Document) : Hash(UInt32, Flock::Entity)
      map = {} of UInt32 => Flock::Entity
      doc.entities.each { |se| map[se.id] = world.spawn }
      doc.entities.each do |se|
        e = map[se.id]
        se.components.each do |name, json|
          if ser = COMPONENTS[name]?
            ser.spawn(world, e, json, map)
          else
            STDERR.puts "[flock scene] unknown component #{name.inspect} — skipped"
          end
        end
      end
      doc.resources.each do |name, json|
        if ser = RESOURCES[name]?
          ser.apply(world, json)
        else
          STDERR.puts "[flock scene] unknown resource #{name.inspect} — skipped"
        end
      end
      map
    end

    # Restores `doc` into `world`, first DESPAWNING every entity that currently has any saveable
    # component (so a load replaces the saved state rather than duplicating it), then spawning.
    def self.restore(world : World, doc : Document) : Hash(UInt32, Flock::Entity)
      seen = Set(UInt32).new
      to_despawn = [] of Flock::Entity
      COMPONENTS.each_value do |ser|
        ser.each(world) { |entity, _json| to_despawn << entity if seen.add?(entity.id) }
      end
      to_despawn.each { |e| world.despawn(e) }
      spawn(world, doc)
    end
  end
end

# Built-in components that are pure data (no GPU handles) are saveable out of the box.
Flock::Scene.register_component("Flock::Transform2D",
  Flock::Scene::ComponentSerializerFor(Flock::Transform2D).new)
Flock::Scene.register_component("Flock::Transform3D",
  Flock::Scene::ComponentSerializerFor(Flock::Transform3D).new)
Flock::Scene.register_component("Flock::Sprite2D",
  Flock::Scene::ComponentSerializerFor(Flock::Sprite2D).new)
