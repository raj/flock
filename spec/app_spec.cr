require "./spec_helper"

# Plugin de test : peuple le monde au startup, avance les positions à chaque update.
class MovePlugin < Flock::Plugin
  def build(app : Flock::App)
    app.add_startup do |_world, cmd|
      cmd.spawn(Position.new(0.0, 0.0), Velocity.new(1.0, 2.0))
    end
    app.add_system(Flock::Schedule::Update) do |world, _cmd|
      world.query(Position, Velocity) do |_e, pos, vel|
        p = pos.value
        p.x += vel.value.dx
        p.y += vel.value.dy
        pos.value = p
      end
    end
  end
end

describe Flock::App do
  it "build un plugin, exécute startup puis les ticks (headless)" do
    app = Flock::App.new.add_plugin(MovePlugin.new)
    app.run_headless(3)

    xs = [] of Float64
    app.world.query(Position) { |_e, pos| xs << pos.value.x }
    xs.size.should eq(1)
    xs[0].should eq(3.0) # 3 ticks * dx(1.0)
  end

  it "les commandes d'un schedule sont appliquées avant le schedule suivant" do
    app = Flock::App.new
    app.add_startup { |_w, cmd| cmd.spawn(Position.new(0.0, 0.0)) }
    app.run_headless(0) # startup seul

    count = 0
    app.world.query(Position) { |_e, _p| count += 1 }
    count.should eq(1)
  end

  it "expose Time comme ressource" do
    app = Flock::App.new
    app.run_headless(1)
    app.world.resource(Flock::Time).elapsed.should be >= 0.0
  end

  it "run sans runner lève une erreur explicite" do
    app = Flock::App.new
    expect_raises(Exception, /runner/) { app.run }
  end
end
