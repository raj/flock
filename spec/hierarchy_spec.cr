require "./spec_helper"

describe Flock::Hierarchy do
  it "composes a child's world transform from its parent chain" do
    w = Flock::World.new
    parent = w.spawn
    w.add(parent, Flock::Transform2D.at(10.0, 0.0))
    child = w.spawn
    w.add(child, Flock::Transform2D.at(5.0, 0.0))
    w.add(child, Flock::Parent.new(parent))

    Flock::Hierarchy.propagate(w)

    tf = w.get(child, Flock::Transform2D).not_nil!
    tf.matrix_override.should_not be_nil # world matrix resolved
    world_origin = tf.matrix.transform_point(Flock::Vec3.new(0, 0, 0))
    world_origin.x.should be_close(15.0f32, 0.001) # 10 (parent) + 5 (child), composed
    world_origin.y.should be_close(0.0f32, 0.001)

    # The root parent keeps a nil override (its local IS its world).
    w.get(parent, Flock::Transform2D).not_nil!.matrix_override.should be_nil
  end

  it "composes three levels deep" do
    w = Flock::World.new
    a = w.spawn; w.add(a, Flock::Transform2D.at(1.0, 0.0))
    b = w.spawn; w.add(b, Flock::Transform2D.at(2.0, 0.0)); w.add(b, Flock::Parent.new(a))
    c = w.spawn; w.add(c, Flock::Transform2D.at(4.0, 0.0)); w.add(c, Flock::Parent.new(b))

    Flock::Hierarchy.propagate(w)
    origin = w.get(c, Flock::Transform2D).not_nil!.matrix.transform_point(Flock::Vec3.new(0, 0, 0))
    origin.x.should be_close(7.0f32, 0.001) # 1 + 2 + 4
  end

  it "preserves the parent hierarchy across save/restore (link remapped, world recomputed)" do
    w1 = Flock::World.new
    p = w1.spawn; w1.add(p, Flock::Transform2D.at(10.0, 0.0))
    c = w1.spawn; w1.add(c, Flock::Transform2D.at(5.0, 0.0)); w1.add(c, Flock::Parent.new(p))

    doc = Flock::Scene.from_json(Flock::Scene.to_json(w1))
    w2 = Flock::World.new
    map = Flock::Scene.spawn(w2, doc)

    new_c = map[c.id]
    w2.get(new_c, Flock::Parent).not_nil!.entity.should eq(map[p.id]) # link remapped

    Flock::Hierarchy.propagate(w2)
    origin = w2.get(new_c, Flock::Transform2D).not_nil!.matrix.transform_point(Flock::Vec3.new(0, 0, 0))
    origin.x.should be_close(15.0f32, 0.001) # world transform reconstructed after load
  end
end
