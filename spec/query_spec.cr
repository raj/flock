require "./spec_helper"

describe "World#query" do
  it "n'itère que les entités possédant tous les composants" do
    w = Flock::World.new
    both = w.spawn
    w.add(both, Position.new(0.0, 0.0))
    w.add(both, Velocity.new(1.0, 1.0))

    pos_only = w.spawn
    w.add(pos_only, Position.new(0.0, 0.0))

    visited = [] of UInt32
    w.query(Position, Velocity) do |entity, pos, vel|
      visited << entity.id
    end

    visited.should eq([both.id])
  end

  it "mute les composants en place via les pointeurs yieldés" do
    w = Flock::World.new
    e = w.spawn
    w.add(e, Position.new(0.0, 0.0))
    w.add(e, Velocity.new(2.0, 3.0))

    # Idiome de mutation DOD : lire -> modifier -> réécrire le struct (le sucre
    # `ptr.value.x += …` ne persiste pas en Crystal ; l'affectation directe si).
    w.query(Position, Velocity) do |_entity, pos, vel|
      p = pos.value
      p.x += vel.value.dx
      p.y += vel.value.dy
      pos.value = p
    end

    w.get(e, Position).not_nil!.x.should eq(2.0)
    w.get(e, Position).not_nil!.y.should eq(3.0)
  end

  it "reste correct quel que soit le composant driver (choix du plus petit set)" do
    w = Flock::World.new
    # Beaucoup de Position, peu de Velocity : le driver doit être Velocity.
    100.times do
      e = w.spawn
      w.add(e, Position.new(0.0, 0.0))
    end
    target = w.spawn
    w.add(target, Position.new(0.0, 0.0))
    w.add(target, Velocity.new(5.0, 0.0))

    count = 0
    w.query(Position, Velocity) do |_e, _pos, _vel|
      count += 1
    end
    count.should eq(1)
  end

  it "supporte un despawn depuis le bloc (itération sur une copie)" do
    w = Flock::World.new
    ids = [] of Flock::Entity
    5.times do
      e = w.spawn
      w.add(e, Position.new(0.0, 0.0))
      ids << e
    end

    w.query(Position) do |entity, _pos|
      w.despawn(entity)
    end

    w.storage(Position).size.should eq(0)
  end
end
