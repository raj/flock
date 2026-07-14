require "./spec_helper"

class Counter < Flock::Resource
  property value : Int32 = 0
end

describe Flock::World do
  it "spawn produit des entités distinctes" do
    w = Flock::World.new
    a = w.spawn
    b = w.spawn
    a.id.should_not eq(b.id)
    w.alive?(a).should be_true
  end

  it "despawn recycle l'id en incrémentant la génération" do
    w = Flock::World.new
    a = w.spawn
    id = a.id
    w.despawn(a)

    w.alive?(a).should be_false # l'ancien handle est invalide
    b = w.spawn                 # l'id est recyclé...
    b.id.should eq(id)
    b.generation.should_not eq(a.generation) # ...mais avec une nouvelle génération
    w.alive?(b).should be_true
  end

  it "despawn retire les composants de tous les storages" do
    w = Flock::World.new
    e = w.spawn
    w.add(e, Position.new(1.0, 2.0))
    w.add(e, Velocity.new(3.0, 4.0))

    w.despawn(e)

    w.storage(Position).size.should eq(0)
    w.storage(Velocity).size.should eq(0)
  end

  it "add/get/remove d'un composant" do
    w = Flock::World.new
    e = w.spawn
    w.add(e, Position.new(5.0, 6.0))

    w.get(e, Position).not_nil!.y.should eq(6.0)
    w.has?(e, Position).should be_true

    w.remove(e, Position)
    w.get(e, Position).should be_nil
  end

  it "stocke et relit une ressource singleton" do
    w = Flock::World.new
    c = Counter.new
    c.value = 10
    w.insert_resource(c)

    w.resource(Counter).value.should eq(10)
    w.resource(Counter).value = 11
    w.resource(Counter).value.should eq(11) # même instance
    w.resource?(Counter).should_not be_nil
  end

  it "resource lève si absente" do
    w = Flock::World.new
    expect_raises(Exception, /Counter/) { w.resource(Counter) }
  end
end
