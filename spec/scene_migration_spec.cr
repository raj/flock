require "./spec_helper"

describe "Flock::Scene migration" do
  it "applies a registered migration to upgrade an older document" do
    # A migration that renames the component key "Legacy" -> "SavePos" in every entity.
    Flock::Scene.register_migration(1) do |json|
      json["entities"].as_a.each do |e|
        comps = e["components"].as_h
        if v = comps.delete("Legacy")
          comps["SavePos"] = v
        end
      end
      json
    end

    v1 = <<-JSON
    {
      "version": 1,
      "entities": [ { "id": 0, "components": { "Legacy": {"x": 3, "y": 4} } } ],
      "resources": {}
    }
    JSON

    migrated = Flock::Scene.migrate(JSON.parse(v1), to: 2)
    migrated["version"].as_i.should eq(2)
    migrated["entities"][0]["components"].as_h.has_key?("SavePos").should be_true
    migrated["entities"][0]["components"].as_h.has_key?("Legacy").should be_false
  end

  it "raises when a migration step is missing" do
    expect_raises(Exception, /no scene migration from version 5/) do
      Flock::Scene.migrate(JSON.parse(%({"version":5,"entities":[],"resources":{}})), to: 7)
    end
  end

  it "from_json migrates up to current_version, so old saves load into the new schema" do
    Flock::Scene.current_version = 2 # game bumped its schema (migration 1->2 registered above)
    begin
      v1 = %({"version":1,"entities":[{"id":0,"components":{"Legacy":{"x":7,"y":8}}}],"resources":{}})
      w = Flock::World.new
      map = Flock::Scene.spawn(w, Flock::Scene.from_json(v1))
      pos = w.get(map[0_u32], SavePos).not_nil! # loaded via the migrated "SavePos" key
      pos.x.should eq(7)
      pos.y.should eq(8)
    ensure
      Flock::Scene.current_version = 1 # don't leak the bump into other specs
    end
  end

  it "leaves a current-version document unchanged" do
    doc = %({"version":1,"entities":[],"resources":{}})
    Flock::Scene.migrate(JSON.parse(doc), to: 1)["version"].as_i.should eq(1)
  end
end
