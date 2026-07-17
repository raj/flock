require "./spec_helper"

describe Flock::Mat4 do
  it "identity * identity = identity" do
    (Flock::Mat4.identity * Flock::Mat4.identity).m.should eq(Flock::Mat4.identity.m)
  end

  it "M * identity = M" do
    m = Flock::Mat4.perspective(Math::PI / 3, 16.0 / 9.0, 0.1, 100.0)
    (m * Flock::Mat4.identity).m.should eq(m.m)
  end

  it "M * M.inverse = identity for a non-trivial TRS matrix" do
    m = Flock::Mat4.translation(Flock::Vec3.new(3, -2, 5)) *
        Flock::Mat4.rotation_y(0.7) * Flock::Mat4.rotation_x(0.4) *
        Flock::Mat4.scale(Flock::Vec3.new(2.0, 0.5, 1.5))
    prod = (m * m.inverse).m
    16.times do |i|
      prod[i].should be_close((i % 5 == 0) ? 1.0f32 : 0.0f32, 1e-4) # diagonal 1, else 0
    end
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
    f.intersects_sphere?(Flock::Vec3.new(0, 0, 0), 1.0f32).should be_true    # in front
    f.intersects_sphere?(Flock::Vec3.new(0, 0, 50), 1.0f32).should be_false  # behind camera
    f.intersects_sphere?(Flock::Vec3.new(100, 0, 0), 1.0f32).should be_false # far to the side
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

  it "division and length_squared" do
    v = Flock::Vec3.new(6, 9, 3) / 3
    v.x.should be_close(2.0f32, 1e-6)
    v.y.should be_close(3.0f32, 1e-6)
    v.z.should be_close(1.0f32, 1e-6)
    Flock::Vec3.new(1, 2, 2).length_squared.should be_close(9.0f32, 1e-6)
  end
end

describe Flock::Vec2 do
  it "dot" do
    Flock::Vec2.new(1, 0).dot(Flock::Vec2.new(0, 1)).should eq(0.0f32)
    Flock::Vec2.new(2, 3).dot(Flock::Vec2.new(4, 5)).should be_close(23.0f32, 1e-6)
  end

  it "cross is the signed z of the 3D cross" do
    # x cross y = +1 (counter-clockwise), y cross x = -1
    Flock::Vec2.new(1, 0).cross(Flock::Vec2.new(0, 1)).should be_close(1.0f32, 1e-6)
    Flock::Vec2.new(0, 1).cross(Flock::Vec2.new(1, 0)).should be_close(-1.0f32, 1e-6)
  end

  it "division scales down component-wise" do
    v = Flock::Vec2.new(6, 8) / 2
    v.x.should be_close(3.0f32, 1e-6)
    v.y.should be_close(4.0f32, 1e-6)
  end

  it "normalize gives a unit length and length is a 3-4-5" do
    Flock::Vec2.new(3, 4).length.should be_close(5.0f32, 1e-6)
    Flock::Vec2.new(3, 4).normalize.length.should be_close(1.0f32, 1e-6)
  end
end

describe Flock::Quaternion do
  it "identity leaves a vector unchanged" do
    v = Flock::Quaternion.identity.rotate(Flock::Vec3.new(1, 2, 3))
    v.x.should be_close(1.0f32, 1e-6)
    v.y.should be_close(2.0f32, 1e-6)
    v.z.should be_close(3.0f32, 1e-6)
  end

  it "from_axis_angle rotates 90deg about Z: x -> y" do
    q = Flock::Quaternion.from_axis_angle(Flock::Vec3.new(0, 0, 1), Math::PI / 2)
    v = q.rotate(Flock::Vec3.new(1, 0, 0))
    v.x.should be_close(0.0f32, 1e-5)
    v.y.should be_close(1.0f32, 1e-5)
    v.z.should be_close(0.0f32, 1e-5)
  end

  it "product composes rotations (self after o), 90+90 = 180 about Z" do
    q90 = Flock::Quaternion.from_axis_angle(Flock::Vec3.new(0, 0, 1), Math::PI / 2)
    v = (q90 * q90).rotate(Flock::Vec3.new(1, 0, 0))
    v.x.should be_close(-1.0f32, 1e-5)
    v.y.should be_close(0.0f32, 1e-5)
  end

  it "rotate agrees with to_mat4.transform_direction" do
    q = Flock::Quaternion.from_axis_angle(Flock::Vec3.new(1, 1, 0), 0.7).normalize
    v = Flock::Vec3.new(0.3, -1.2, 2.0)
    a = q.rotate(v)
    b = q.to_mat4.transform_direction(v)
    a.x.should be_close(b.x, 1e-5)
    a.y.should be_close(b.y, 1e-5)
    a.z.should be_close(b.z, 1e-5)
  end

  it "from_euler matches the engine's Z*Y*X matrix order" do
    ex, ey, ez = 0.3f32, -0.5f32, 1.1f32
    q = Flock::Quaternion.from_euler(ex, ey, ez)
    m = Flock::Mat4.rotation_z(ez) * Flock::Mat4.rotation_y(ey) * Flock::Mat4.rotation_x(ex)
    v = Flock::Vec3.new(1, 2, 3)
    a = q.rotate(v)
    b = m.transform_direction(v)
    a.x.should be_close(b.x, 1e-5)
    a.y.should be_close(b.y, 1e-5)
    a.z.should be_close(b.z, 1e-5)
  end

  it "conjugate undoes the rotation (q.conjugate * q = identity)" do
    q = Flock::Quaternion.from_axis_angle(Flock::Vec3.new(0, 1, 0), 1.3).normalize
    v = Flock::Vec3.new(2, 0, -1)
    back = q.conjugate.rotate(q.rotate(v))
    back.x.should be_close(2.0f32, 1e-5)
    back.y.should be_close(0.0f32, 1e-5)
    back.z.should be_close(-1.0f32, 1e-5)
  end

  it "integrate stays unit-length and advances about the omega axis" do
    q = Flock::Quaternion.identity.integrate(Flock::Vec3.new(0, 0, 1), 0.1)
    q.length.should be_close(1.0f32, 1e-6)
    # small rotation about +Z tilts x slightly toward +y
    v = q.rotate(Flock::Vec3.new(1, 0, 0))
    v.y.should be_close(Math.sin(0.1).to_f32, 1e-3)
  end
end
