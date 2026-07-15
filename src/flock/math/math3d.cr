module Flock
  struct Vec2
    property x : Float32
    property y : Float32

    def initialize(x : Number = 0, y : Number = 0)
      @x = x.to_f32
      @y = y.to_f32
    end

    def +(o : Vec2); Vec2.new(@x + o.x, @y + o.y); end
    def -(o : Vec2); Vec2.new(@x - o.x, @y - o.y); end
    def *(s : Number); Vec2.new(@x * s, @y * s); end

    def length : Float32
      Math.sqrt(@x * @x + @y * @y).to_f32
    end
  end

  struct Vec3
    property x : Float32
    property y : Float32
    property z : Float32

    def initialize(x : Number = 0, y : Number = 0, z : Number = 0)
      @x = x.to_f32
      @y = y.to_f32
      @z = z.to_f32
    end

    def +(o : Vec3); Vec3.new(@x + o.x, @y + o.y, @z + o.z); end
    def -(o : Vec3); Vec3.new(@x - o.x, @y - o.y, @z - o.z); end
    def *(s : Number); Vec3.new(@x * s, @y * s, @z * s); end

    def dot(o : Vec3) : Float32
      @x * o.x + @y * o.y + @z * o.z
    end

    def cross(o : Vec3) : Vec3
      Vec3.new(@y * o.z - @z * o.y, @z * o.x - @x * o.z, @x * o.y - @y * o.x)
    end

    def length : Float32
      Math.sqrt(dot(self)).to_f32
    end

    def normalize : Vec3
      len = length
      len == 0 ? self : self * (1.0f32 / len)
    end
  end

  # 4x4 matrix stored in column-major order (WGSL/WebGPU convention). The target
  # depth space is [0, 1] (Metal/D3D/WebGPU), not [-1, 1] (OpenGL).
  struct Mat4
    getter m : StaticArray(Float32, 16)

    def initialize(@m : StaticArray(Float32, 16))
    end

    # Access (column, row).
    def [](col : Int32, row : Int32) : Float32
      @m[col * 4 + row]
    end

    def self.zero : Mat4
      Mat4.new(StaticArray(Float32, 16).new(0.0f32))
    end

    def self.identity : Mat4
      a = StaticArray(Float32, 16).new(0.0f32)
      a[0] = a[5] = a[10] = a[15] = 1.0f32
      Mat4.new(a)
    end

    # Orthographic projection (depth [0, 1]).
    def self.orthographic(left : Number, right : Number, bottom : Number, top : Number,
                          near : Number = -1.0, far : Number = 1.0) : Mat4
      l, r, b, t, n, f = left.to_f32, right.to_f32, bottom.to_f32, top.to_f32, near.to_f32, far.to_f32
      a = StaticArray(Float32, 16).new(0.0f32)
      a[0] = 2.0f32 / (r - l)
      a[5] = 2.0f32 / (t - b)
      a[10] = 1.0f32 / (n - f)
      a[12] = (r + l) / (l - r)
      a[13] = (t + b) / (b - t)
      a[14] = n / (n - f)
      a[15] = 1.0f32
      Mat4.new(a)
    end

    # Right-handed perspective projection (depth [0, 1]). fov_y in radians.
    def self.perspective(fov_y : Number, aspect : Number, near : Number, far : Number) : Mat4
      fy = 1.0f32 / Math.tan(fov_y.to_f32 / 2.0f32)
      n, f = near.to_f32, far.to_f32
      a = StaticArray(Float32, 16).new(0.0f32)
      a[0] = fy / aspect.to_f32
      a[5] = fy
      a[10] = f / (n - f)
      a[11] = -1.0f32
      a[14] = (f * n) / (n - f)
      Mat4.new(a)
    end

    # Right-handed view matrix (looks from `eye` toward `target`).
    def self.look_at(eye : Vec3, target : Vec3, up : Vec3) : Mat4
      fwd = (target - eye).normalize
      side = fwd.cross(up).normalize
      u = side.cross(fwd)
      a = StaticArray(Float32, 16).new(0.0f32)
      a[0] = side.x; a[1] = u.x; a[2] = -fwd.x
      a[4] = side.y; a[5] = u.y; a[6] = -fwd.y
      a[8] = side.z; a[9] = u.z; a[10] = -fwd.z
      a[12] = -side.dot(eye)
      a[13] = -u.dot(eye)
      a[14] = fwd.dot(eye)
      a[15] = 1.0f32
      Mat4.new(a)
    end

    def self.translation(v : Vec3) : Mat4
      a = identity.m
      a[12] = v.x; a[13] = v.y; a[14] = v.z
      Mat4.new(a)
    end

    def self.scale(v : Vec3) : Mat4
      a = StaticArray(Float32, 16).new(0.0f32)
      a[0] = v.x; a[5] = v.y; a[10] = v.z; a[15] = 1.0f32
      Mat4.new(a)
    end

    # Rotation about the Z axis (radians) — the axis of the 2D plane.
    def self.rotation_z(rad : Number) : Mat4
      c = Math.cos(rad).to_f32
      s = Math.sin(rad).to_f32
      a = identity.m
      a[0] = c; a[1] = s
      a[4] = -s; a[5] = c
      Mat4.new(a)
    end

    # Rotation about the X axis (radians).
    def self.rotation_x(rad : Number) : Mat4
      c = Math.cos(rad).to_f32
      s = Math.sin(rad).to_f32
      a = identity.m
      a[5] = c; a[6] = s
      a[9] = -s; a[10] = c
      Mat4.new(a)
    end

    # Rotation about the Y axis (radians).
    def self.rotation_y(rad : Number) : Mat4
      c = Math.cos(rad).to_f32
      s = Math.sin(rad).to_f32
      a = identity.m
      a[0] = c; a[2] = -s
      a[8] = s; a[10] = c
      Mat4.new(a)
    end

    # Rotation from a quaternion (x, y, z, w) — e.g. a glTF node rotation.
    def self.rotation_quaternion(x : Number, y : Number, z : Number, w : Number) : Mat4
      xf, yf, zf, wf = x.to_f32, y.to_f32, z.to_f32, w.to_f32
      xx = xf * xf; yy = yf * yf; zz = zf * zf
      xy = xf * yf; xz = xf * zf; yz = yf * zf
      wx = wf * xf; wy = wf * yf; wz = wf * zf
      a = identity.m
      a[0] = 1 - 2*(yy + zz); a[1] = 2*(xy + wz);     a[2] = 2*(xz - wy)
      a[4] = 2*(xy - wz);     a[5] = 1 - 2*(xx + zz); a[6] = 2*(yz + wx)
      a[8] = 2*(xz + wy);     a[9] = 2*(yz - wx);     a[10] = 1 - 2*(xx + yy)
      Mat4.new(a)
    end

    # Matrix product (column-major): self * other.
    def *(o : Mat4) : Mat4
      a = StaticArray(Float32, 16).new(0.0f32)
      4.times do |col|
        4.times do |row|
          sum = 0.0f32
          4.times do |k|
            sum += self[k, row] * o[col, k]
          end
          a[col * 4 + row] = sum
        end
      end
      Mat4.new(a)
    end

    # Normal matrix: the inverse-transpose of the upper-left 3x3, embedded in a
    # Mat4 (3x3 in the upper-left, [3,3]=1, rest 0). Transforms normals correctly
    # under non-uniform scale (equals the rotation part for rigid transforms).
    def normal_matrix : Mat4
      # Upper-left 3x3 (column-major access [col, row]).
      a = self[0, 0]; b = self[1, 0]; c = self[2, 0]
      d = self[0, 1]; e = self[1, 1]; f = self[2, 1]
      g = self[0, 2]; h = self[1, 2]; i = self[2, 2]

      det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
      # The normal matrix is cofactor(M)/det = transpose(inverse(M)).
      res = StaticArray(Float32, 16).new(0.0f32)
      res[15] = 1.0f32
      if det.abs < 1e-8f32
        res[0] = res[5] = res[10] = 1.0f32 # degenerate: fall back to identity
        return Mat4.new(res)
      end
      inv = 1.0f32 / det
      # N[row][col] stored column-major: res[col*4 + row].
      res[0] = (e * i - f * h) * inv   # N00
      res[1] = -(b * i - c * h) * inv  # N10
      res[2] = (b * f - c * e) * inv   # N20
      res[4] = -(d * i - f * g) * inv  # N01
      res[5] = (a * i - c * g) * inv   # N11
      res[6] = -(a * f - c * d) * inv  # N21
      res[8] = (d * h - e * g) * inv   # N02
      res[9] = -(a * h - b * g) * inv  # N12
      res[10] = (a * e - b * d) * inv  # N22
      Mat4.new(res)
    end

    # Transforms a point (w=1) by this matrix.
    def transform_point(p : Vec3) : Vec3
      Vec3.new(
        self[0, 0] * p.x + self[1, 0] * p.y + self[2, 0] * p.z + self[3, 0],
        self[0, 1] * p.x + self[1, 1] * p.y + self[2, 1] * p.z + self[3, 1],
        self[0, 2] * p.x + self[1, 2] * p.y + self[2, 2] * p.z + self[3, 2])
    end

    # Per-axis scale factors = lengths of the upper-3x3 basis columns (rotation-invariant).
    def scale_factors : Vec3
      sx = Math.sqrt(self[0, 0]**2 + self[0, 1]**2 + self[0, 2]**2)
      sy = Math.sqrt(self[1, 0]**2 + self[1, 1]**2 + self[1, 2]**2)
      sz = Math.sqrt(self[2, 0]**2 + self[2, 1]**2 + self[2, 2]**2)
      Vec3.new(sx, sy, sz)
    end

    # Flat view for uploading into a wgpu uniform buffer.
    def to_slice : Slice(Float32)
      @m.to_slice
    end
  end

  # View frustum as 6 normalized planes (a,b,c,d), extracted from a view-projection
  # matrix (Gribb-Hartmann). Used for culling: a point/sphere is inside when it lies
  # on the inner side of every plane. Assumes WebGPU/Metal/D3D clip depth [0, w].
  struct Frustum
    getter planes : Array(StaticArray(Float32, 4))

    def initialize(@planes : Array(StaticArray(Float32, 4)))
    end

    def self.from(vp : Mat4) : Frustum
      # Rows of the view-projection matrix (row i · world = i-th clip component).
      row = ->(i : Int32) { {vp[0, i], vp[1, i], vp[2, i], vp[3, i]} }
      r0 = row.call(0); r1 = row.call(1); r2 = row.call(2); r3 = row.call(3)
      raw = [
        {r3[0] + r0[0], r3[1] + r0[1], r3[2] + r0[2], r3[3] + r0[3]}, # left   (X + W >= 0)
        {r3[0] - r0[0], r3[1] - r0[1], r3[2] - r0[2], r3[3] - r0[3]}, # right  (W - X >= 0)
        {r3[0] + r1[0], r3[1] + r1[1], r3[2] + r1[2], r3[3] + r1[3]}, # bottom (Y + W >= 0)
        {r3[0] - r1[0], r3[1] - r1[1], r3[2] - r1[2], r3[3] - r1[3]}, # top    (W - Y >= 0)
        {r2[0], r2[1], r2[2], r2[3]},                                 # near   (Z >= 0)
        {r3[0] - r2[0], r3[1] - r2[1], r3[2] - r2[2], r3[3] - r2[3]}, # far    (W - Z >= 0)
      ]
      planes = raw.map do |(a, b, c, d)|
        len = Math.sqrt(a * a + b * b + c * c)
        len = 1.0f32 if len == 0
        StaticArray[a / len, b / len, c / len, d / len]
      end
      Frustum.new(planes)
    end

    # True if the world-space sphere is at least partially inside the frustum.
    def intersects_sphere?(center : Vec3, radius : Float32) : Bool
      @planes.each do |p|
        dist = p[0] * center.x + p[1] * center.y + p[2] * center.z + p[3]
        return false if dist < -radius
      end
      true
    end
  end
end
