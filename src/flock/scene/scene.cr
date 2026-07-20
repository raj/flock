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

    # The version stamped into new saves and the target that `from_json` migrates up to. Defaults
    # to the engine's VERSION; a game that changes its save schema bumps this and registers the
    # matching migrations, so old save files upgrade transparently on load.
    @@current_version : Int32 = VERSION

    def self.current_version : Int32
      @@current_version
    end

    def self.current_version=(v : Int32) : Int32
      @@current_version = v
    end

    # from_version -> a function upgrading a whole scene-document JSON by exactly one version.
    MIGRATIONS = {} of Int32 => JSON::Any -> JSON::Any

    # Registers a migration that upgrades a document from `from` to `from + 1`. The block receives
    # and returns the whole document as JSON::Any (mutate `json.as_h`, or rebuild). Example
    # renaming a component key across every entity:
    #
    #   Flock::Scene.register_migration(1) do |json|
    #     json["entities"].as_a.each do |e|
    #       comps = e["components"].as_h
    #       if v = comps.delete("Old"); comps["New"] = v; end
    #     end
    #     json
    #   end
    def self.register_migration(from : Int32, &block : JSON::Any -> JSON::Any) : Nil
      MIGRATIONS[from] = block
    end

    # Applies registered migrations to bring `json` up to `to` (default: current_version). Raises
    # if a step in the chain is missing. A document already at/above `to` is returned unchanged.
    def self.migrate(json : JSON::Any, to : Int32 = @@current_version) : JSON::Any
      v = json["version"]?.try(&.as_i) || 1
      while v < to
        mig = MIGRATIONS[v]? || raise "no scene migration from version #{v} (need to reach #{to})"
        json = mig.call(json)
        v += 1
        json.as_h?.try { |h| h["version"] = JSON::Any.new(v.to_i64) }
      end
      json
    end

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
      Document.new(entities, resources, @@current_version)
    end

    # Serializes the current saveable state to a JSON string / a file.
    def self.to_json(world : World) : String
      capture(world).to_json
    end

    def self.save(world : World, path : String) : Nil
      File.write(path, to_json(world))
    end

    def self.from_json(json : String) : Document
      # Upgrade older saves to current_version before constructing the Document.
      Document.from_json(migrate(JSON.parse(json)).to_json)
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
