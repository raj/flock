module Flock
  # 2D position/orientation/scale of an entity (struct, DOD). Native-free — shared by
  # the native renderer and the web backend.
  struct Transform2D
    include Component
    include JSON::Serializable
    property position : Vec2
    property rotation : Float32 # radians
    property scale : Vec2

    def initialize(@position : Vec2 = Vec2.new, @rotation : Float32 = 0.0f32,
                   @scale : Vec2 = Vec2.new(1, 1))
    end

    def self.at(x : Number, y : Number) : Transform2D
      new(Vec2.new(x, y))
    end

    # Model matrix: translate * rotate * scale.
    def matrix : Mat4
      Mat4.translation(Vec3.new(@position.x, @position.y, 0)) *
        Mat4.rotation_z(@rotation) *
        Mat4.scale(Vec3.new(@scale.x, @scale.y, 1))
    end
  end

  # 3D transform. `rotation` is Euler angles (radians, applied Z*Y*X). When
  # `matrix_override` is set (e.g. by an animation player computing a world matrix
  # from a node hierarchy / quaternions), `matrix` returns it verbatim.
  struct Transform3D
    include Component
    include JSON::Serializable
    property position : Vec3
    property rotation : Vec3
    property scale : Vec3
    @[JSON::Field(ignore: true)] # a transient cache; not part of the saved state
    property matrix_override : Mat4?

    def initialize(@position : Vec3 = Vec3.new, @rotation : Vec3 = Vec3.new,
                   @scale : Vec3 = Vec3.new(1, 1, 1), @matrix_override : Mat4? = nil)
    end

    # Model matrix: the override if present, else translate * rotate(Z*Y*X) * scale.
    def matrix : Mat4
      if mo = @matrix_override
        return mo
      end
      Mat4.translation(@position) *
        Mat4.rotation_z(@rotation.z) * Mat4.rotation_y(@rotation.y) * Mat4.rotation_x(@rotation.x) *
        Mat4.scale(@scale)
    end
  end
end
