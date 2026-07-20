require "./spec_helper"

# Saveable test components/resources (register themselves via the macros at load).
struct SavePos
  include Flock::Component
  include Flock::Saveable
  property x : Int32
  property y : Int32

  def initialize(@x : Int32 = 0, @y : Int32 = 0)
  end
end

struct SaveLink
  include Flock::Component
  include Flock::Saveable
  property target : Flock::Entity
  property label : String

  def initialize(@target : Flock::Entity, @label : String = "")
  end

  entity_fields target
end

class SaveScore < Flock::Resource
  include Flock::SaveableResource
  property value : Int32

  def initialize(@value : Int32 = 0)
  end
end

describe Flock::Scene do
  it "captures components, round-trips through JSON, and spawns into a fresh world" do
    w1 = Flock::World.new
    e = w1.spawn
    w1.add(e, SavePos.new(7, 9))
    w1.add(e, Flock::Transform2D.at(3.0, 4.0)) # a built-in saveable component

    json = Flock::Scene.to_json(w1)
    json.should contain("SavePos")
    json.should contain("Flock::Transform2D")

    w2 = Flock::World.new
    doc = Flock::Scene.from_json(json)
    map = Flock::Scene.spawn(w2, doc)

    ne = map[e.id]
    w2.get(ne, SavePos).not_nil!.x.should eq(7)
    w2.get(ne, SavePos).not_nil!.y.should eq(9)
    w2.get(ne, Flock::Transform2D).not_nil!.position.x.should eq(3.0f32)
  end

  it "remaps entity references to the freshly spawned entities" do
    w1 = Flock::World.new
    a = w1.spawn
    w1.add(a, SavePos.new(1, 1))
    b = w1.spawn
    w1.add(b, SaveLink.new(target: a, label: "b->a"))

    doc = Flock::Scene.from_json(Flock::Scene.to_json(w1))
    w2 = Flock::World.new
    map = Flock::Scene.spawn(w2, doc)

    new_b = map[b.id]
    link = w2.get(new_b, SaveLink).not_nil!
    link.label.should eq("b->a")
    link.target.should eq(map[a.id]) # remapped to the new entity, not the stale saved id
    w2.get(link.target, SavePos).not_nil!.x.should eq(1)
  end

  it "captures and restores resources" do
    w1 = Flock::World.new
    w1.insert_resource(SaveScore.new(1200))
    doc = Flock::Scene.from_json(Flock::Scene.to_json(w1))

    w2 = Flock::World.new
    Flock::Scene.spawn(w2, doc)
    w2.resource(SaveScore).value.should eq(1200)
  end

  it "restore replaces existing saveable entities instead of duplicating" do
    w = Flock::World.new
    old = w.spawn
    w.add(old, SavePos.new(5, 5))

    doc = Flock::Scene::Document.new(
      [Flock::Scene::SavedEntity.new(0_u32, {"SavePos" => JSON.parse(%({"x":1,"y":2}))})],
      {} of String => JSON::Any)
    Flock::Scene.restore(w, doc)

    # Only the restored entity remains (old one despawned).
    total = 0
    coords = [] of Int32
    w.query(SavePos) { |_e, p| total += 1; coords << p.value.x }
    total.should eq(1)
    coords.first.should eq(1)
  end

  it "skips unknown component/resource types with a warning (no crash)" do
    doc = Flock::Scene::Document.new(
      [Flock::Scene::SavedEntity.new(0_u32, {"Ghost::Missing" => JSON.parse("{}")})],
      {"Ghost::Res" => JSON.parse("{}")})
    w = Flock::World.new
    map = Flock::Scene.spawn(w, doc) # must not raise
    map.size.should eq(1)
  end
end
