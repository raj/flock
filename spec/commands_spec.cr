require "./spec_helper"

describe Flock::Commands do
  it "diffère l'ajout des composants jusqu'à apply" do
    w = Flock::World.new
    cmd = Flock::Commands.new(w)

    e = cmd.spawn(Position.new(1.0, 2.0), Velocity.new(3.0, 4.0))
    # L'id est réservé immédiatement, mais les composants sont en file.
    w.alive?(e).should be_true
    w.get(e, Position).should be_nil

    cmd.apply
    w.get(e, Position).not_nil!.x.should eq(1.0)
    w.get(e, Velocity).not_nil!.dy.should eq(4.0)
    cmd.empty?.should be_true
  end

  it "diffère le despawn jusqu'à apply" do
    w = Flock::World.new
    e = w.spawn
    w.add(e, Position.new(0.0, 0.0))

    cmd = Flock::Commands.new(w)
    cmd.despawn(e)
    w.alive?(e).should be_true # pas encore appliqué

    cmd.apply
    w.alive?(e).should be_false
  end

  it "spawn sans composant réserve juste une entité" do
    w = Flock::World.new
    cmd = Flock::Commands.new(w)
    e = cmd.spawn
    w.alive?(e).should be_true
  end
end
