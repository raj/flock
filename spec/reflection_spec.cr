require "./spec_helper"

# Uses the built-in Saveable components registered by src/flock/scene/scene.cr
# (Flock::Transform2D, Flock::Sprite2D).
describe "Flock::Scene reflection" do
  it "lists a registered component's field schema" do
    fields = Flock::Scene.fields("Flock::Transform2D")
    fields = fields.should_not be_nil
    names = fields.map(&.[0])
    names.should contain("position")
    # each entry is {name, type-name}
    pos = fields.find { |(n, _t)| n == "position" }.not_nil!
    pos[1].should contain("Vec2")
  end

  it "enumerates the registered components on an entity" do
    w = Flock::World.new
    e = w.spawn
    w.add(e, Flock::Transform2D.at(1.0f32, 2.0f32))
    w.add(e, Flock::Sprite2D.new(Flock::Vec2.new(10, 10)))

    comps = Flock::Scene.components_of(w, e)
    comps.keys.should contain("Flock::Transform2D")
    comps.keys.should contain("Flock::Sprite2D")
    comps["Flock::Transform2D"]["position"]["x"].as_f.should eq(1.0)
  end

  it "gets / sets / removes a component by name (editor round-trip)" do
    w = Flock::World.new
    e = w.spawn
    w.add(e, Flock::Transform2D.at(1.0f32, 2.0f32))

    got = Flock::Scene.get_component(w, e, "Flock::Transform2D").not_nil!
    got["position"]["x"].as_f.should eq(1.0)

    # Edit the position and write it back through the reflection API.
    edited = JSON.parse(%({"position":{"x":9.0,"y":9.0},"rotation":0.0,"scale":{"x":1.0,"y":1.0}}))
    Flock::Scene.set_component(w, e, "Flock::Transform2D", edited).should be_true
    w.get(e, Flock::Transform2D).not_nil!.position.x.should eq(9.0f32)

    Flock::Scene.remove_component(w, e, "Flock::Transform2D").should be_true
    w.has?(e, Flock::Transform2D).should be_false
  end

  it "returns false for an unregistered component name" do
    w = Flock::World.new
    e = w.spawn
    Flock::Scene.set_component(w, e, "Nope::Missing", JSON.parse("{}")).should be_false
    Flock::Scene.get_component(w, e, "Nope::Missing").should be_nil
  end
end
