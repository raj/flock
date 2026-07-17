require "./spec_helper"
require "../src/flock/color"
require "../src/flock/render/camera"

# OrbitCamera / FlyCamera are pure math (no GPU): testable headless.
describe Flock::OrbitCamera do
  it "places the eye at +Z from the target at yaw=pitch=0" do
    o = Flock::OrbitCamera.new(target: Flock::Vec3.new(0, 0, 0), distance: 5.0f32, yaw: 0.0f32, pitch: 0.0f32)
    e = o.eye
    e.x.should be_close(0.0f32, 1e-5)
    e.y.should be_close(0.0f32, 1e-5)
    e.z.should be_close(5.0f32, 1e-5)
  end

  it "orbits to +X after a quarter-turn of yaw" do
    o = Flock::OrbitCamera.new(distance: 5.0f32, pitch: 0.0f32)
    o.rotate(Math::PI / 2, 0.0)
    e = o.eye
    e.x.should be_close(5.0f32, 1e-4)
    e.z.should be_close(0.0f32, 1e-4)
  end

  it "raises the eye with positive pitch and orbits around a moved target" do
    o = Flock::OrbitCamera.new(target: Flock::Vec3.new(1, 2, 3), distance: 4.0f32, yaw: 0.0f32, pitch: 0.0f32, max_pitch: 2.0f32)
    o.rotate(0.0, Math::PI / 2) # look straight down -> eye directly above target
    e = o.eye
    e.x.should be_close(1.0f32, 1e-4)
    e.y.should be_close(6.0f32, 1e-4) # target.y + distance
    e.z.should be_close(3.0f32, 1e-4)
  end

  it "clamps pitch and distance to their bounds" do
    o = Flock::OrbitCamera.new(distance: 5.0f32, min_pitch: -1.0f32, max_pitch: 1.0f32,
      min_distance: 2.0f32, max_distance: 10.0f32)
    o.rotate(0.0, 100.0)
    o.pitch.should eq(1.0f32)
    o.dolly(0.001) # would drop below min
    o.distance.should eq(2.0f32)
    o.dolly(1000.0) # would exceed max
    o.distance.should eq(10.0f32)
  end

  it "writes eye + target into a Camera3D" do
    world = Flock::World.new
    e = world.spawn
    world.add(e, Flock::Camera3D.new)
    o = Flock::OrbitCamera.new(target: Flock::Vec3.new(0, 1, 0), distance: 3.0f32, yaw: 0.0f32, pitch: 0.0f32)
    world.query(Flock::Camera3D) { |_e, cam| o.apply(cam) }
    world.query(Flock::Camera3D) do |_e, cam|
      cam.value.position.z.should be_close(3.0f32, 1e-4)
      cam.value.target.y.should be_close(1.0f32, 1e-5)
    end
  end
end

describe Flock::FlyCamera do
  it "faces -Z at yaw = pitch = 0" do
    f = Flock::FlyCamera.new
    fwd = f.forward
    fwd.x.should be_close(0.0f32, 1e-5)
    fwd.y.should be_close(0.0f32, 1e-5)
    fwd.z.should be_close(-1.0f32, 1e-5)
  end

  it "moves forward along the view direction" do
    f = Flock::FlyCamera.new(position: Flock::Vec3.new(0, 0, 0), speed: 2.0f32)
    f.move(1.0, 0.0, 0.0, 0.5) # 2 * 0.5 = 1 unit forward (-Z)
    f.position.z.should be_close(-1.0f32, 1e-4)
    f.position.x.should be_close(0.0f32, 1e-5)
  end

  it "strafes right along +X when facing -Z" do
    f = Flock::FlyCamera.new(position: Flock::Vec3.new(0, 0, 0), speed: 1.0f32)
    f.move(0.0, 1.0, 0.0, 1.0)
    f.position.x.should be_close(1.0f32, 1e-4)
    f.position.z.should be_close(0.0f32, 1e-4)
  end

  it "clamps pitch when looking up/down" do
    f = Flock::FlyCamera.new(min_pitch: -1.2f32, max_pitch: 1.2f32)
    f.look(0.0, 100.0)
    f.pitch.should eq(1.2f32)
    f.look(0.0, -100.0)
    f.pitch.should eq(-1.2f32)
  end

  it "applies position + target to a Camera3D" do
    world = Flock::World.new
    e = world.spawn
    world.add(e, Flock::Camera3D.new)
    f = Flock::FlyCamera.new(position: Flock::Vec3.new(2, 0, 0))
    world.query(Flock::Camera3D) { |_e, cam| f.apply(cam) }
    world.query(Flock::Camera3D) do |_e, cam|
      cam.value.position.x.should be_close(2.0f32, 1e-5)
      cam.value.target.z.should be_close(-1.0f32, 1e-4) # +X + forward(-Z)
    end
  end
end
