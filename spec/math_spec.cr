require "./spec_helper"

describe Flock::Mat4 do
  it "identity * identity = identity" do
    (Flock::Mat4.identity * Flock::Mat4.identity).m.should eq(Flock::Mat4.identity.m)
  end

  it "M * identity = M" do
    m = Flock::Mat4.perspective(Math::PI / 3, 16.0 / 9.0, 0.1, 100.0)
    (m * Flock::Mat4.identity).m.should eq(m.m)
  end

  it "orthographic maps [left,right]x[bottom,top] onto the clip cube" do
    m = Flock::Mat4.orthographic(0.0, 800.0, 0.0, 600.0)
    # x=400 (center) -> 0 in NDC; here we check the scale/translation terms.
    m[0, 0].should be_close(2.0f32 / 800.0f32, 1e-6)
    m[1, 1].should be_close(2.0f32 / 600.0f32, 1e-6)
    m[3, 0].should be_close(-1.0f32, 1e-6) # (r+l)/(l-r) = -1
    m[3, 1].should be_close(-1.0f32, 1e-6)
  end

  it "perspective produces w = -z (depth projection)" do
    m = Flock::Mat4.perspective(Math::PI / 2, 1.0, 1.0, 10.0)
    m[2, 3].should be_close(-1.0f32, 1e-6) # w row takes -z
  end

  it "look_at from the origin looking down -z is close to identity in rotation" do
    v = Flock::Mat4.look_at(Flock::Vec3.new(0, 0, 0), Flock::Vec3.new(0, 0, -1), Flock::Vec3.new(0, 1, 0))
    v[0, 0].should be_close(1.0f32, 1e-6)
    v[1, 1].should be_close(1.0f32, 1e-6)
    v[2, 2].should be_close(1.0f32, 1e-6)
  end
end

describe Flock::Vec3 do
  it "cross and dot" do
    x = Flock::Vec3.new(1, 0, 0)
    y = Flock::Vec3.new(0, 1, 0)
    z = x.cross(y)
    z.z.should be_close(1.0f32, 1e-6)
    x.dot(y).should eq(0.0f32)
  end

  it "normalize gives a unit length" do
    Flock::Vec3.new(3, 4, 0).normalize.length.should be_close(1.0f32, 1e-6)
  end
end
