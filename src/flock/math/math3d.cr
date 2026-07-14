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

  # Matrice 4x4 stockée en colonne-major (convention WGSL/WebGPU). L'espace de
  # profondeur cible est [0, 1] (Metal/D3D/WebGPU), pas [-1, 1] (OpenGL).
  struct Mat4
    getter m : StaticArray(Float32, 16)

    def initialize(@m : StaticArray(Float32, 16))
    end

    # Accès (colonne, ligne).
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

    # Projection orthographique (profondeur [0, 1]).
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

    # Projection perspective right-handed (profondeur [0, 1]). fov_y en radians.
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

    # Matrice de vue right-handed (regarde de `eye` vers `target`).
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

    # Rotation autour de l'axe Z (radians) — l'axe du plan 2D.
    def self.rotation_z(rad : Number) : Mat4
      c = Math.cos(rad).to_f32
      s = Math.sin(rad).to_f32
      a = identity.m
      a[0] = c; a[1] = s
      a[4] = -s; a[5] = c
      Mat4.new(a)
    end

    # Produit matriciel (colonne-major) : self * other.
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

    # Vue plate pour l'upload dans un uniform buffer wgpu.
    def to_slice : Slice(Float32)
      @m.to_slice
    end
  end
end
