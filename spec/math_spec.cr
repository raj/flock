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

  it "normal_matrix of a non-uniform scale is the inverse scale (inverse-transpose)" do
    n = Flock::Mat4.scale(Flock::Vec3.new(2, 4, 0.5)).normal_matrix
    n[0, 0].should be_close(0.5f32, 1e-6)  # 1/2
    n[1, 1].should be_close(0.25f32, 1e-6) # 1/4
    n[2, 2].should be_close(2.0f32, 1e-6)  # 1/0.5
  end

  it "normal_matrix of a rotation equals the rotation (orthogonal)" do
    r = Flock::Mat4.rotation_z(0.7)
    n = r.normal_matrix
    {0, 1, 2}.each do |c|
      {0, 1, 2}.each do |row|
        n[c, row].should be_close(r[c, row], 1e-5)
      end
    end
  end
end

describe Flock::Frustum do
  it "accepts spheres in front of the camera and rejects those outside" do
    vp = Flock::Mat4.perspective(0.9, 1.0, 0.1, 100.0) *
         Flock::Mat4.look_at(Flock::Vec3.new(0, 0, 5), Flock::Vec3.new(0, 0, 0), Flock::Vec3.new(0, 1, 0))
    f = Flock::Frustum.from(vp)
    f.intersects_sphere?(Flock::Vec3.new(0, 0, 0), 1.0f32).should be_true     # in front
    f.intersects_sphere?(Flock::Vec3.new(0, 0, 50), 1.0f32).should be_false   # behind camera
    f.intersects_sphere?(Flock::Vec3.new(100, 0, 0), 1.0f32).should be_false  # far to the side
  end

  it "keeps a just-off-screen sphere whose radius crosses the plane" do
    vp = Flock::Mat4.perspective(0.9, 1.0, 0.1, 100.0) *
         Flock::Mat4.look_at(Flock::Vec3.new(0, 0, 5), Flock::Vec3.new(0, 0, 0), Flock::Vec3.new(0, 1, 0))
    f = Flock::Frustum.from(vp)
    # A huge sphere centered off to the side still intersects the frustum.
    f.intersects_sphere?(Flock::Vec3.new(100, 0, 0), 200.0f32).should be_true
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
