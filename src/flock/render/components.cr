module Flock
  # 2D position/orientation/scale of an entity. Struct (DOD).
  struct Transform2D
    include Component
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
    property position : Vec3
    property rotation : Vec3
    property scale : Vec3
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

  # Attaches a Mesh to an entity for 3D rendering (with Transform3D), consumed by
  # Renderer3D + Camera3D. `material` swaps the shader (built via
  # `Renderer3D#build_material`); nil uses the renderer's built-in lit shader.
  struct MeshRenderer
    include Component
    property mesh : Mesh
    property material : Material3D?
    property texture : Texture? # base color
    # PBR maps (glTF metallic-roughness workflow), used by the built-in shader:
    # `metallic_roughness` packs roughness in G and metallic in B; `normal_map` is a
    # tangent-space normal map. `metallic`/`roughness` are scalar factors (0..1)
    # multiplied into the sampled values (or used alone when no map is set).
    property metallic_roughness : Texture?
    property normal_map : Texture?
    property metallic : Float32
    property roughness : Float32
    # Per-instance tint (multiplied into the mesh's vertex color) + alpha. Lets many
    # entities share one mesh yet render in different colors within a single draw.
    property tint : Color

    def initialize(@mesh : Mesh, @material : Material3D? = nil, @texture : Texture? = nil,
                   @tint : Color = Color::WHITE, @metallic_roughness : Texture? = nil,
                   @normal_map : Texture? = nil, @metallic : Float32 = 0.0f32, @roughness : Float32 = 1.0f32)
    end
  end

  # Sprite: tinted textured quad. `texture = nil` -> white (solid color).
  # `size` in world units (pixels by default). `uv_min`/`uv_size` for an atlas.
  # `z` = draw order (increasing = back to front). `material = nil` -> renderer's
  # default sprite shader; a custom `SpriteMaterial` swaps the shader. The batcher
  # sorts by (z, material, texture), so layering is respected while grouping draws.
  struct Sprite
    include Component
    property size : Vec2
    property color : Color
    property texture : Texture?
    property z : Float32
    property material : SpriteMaterial?
    property uv_min : Vec2
    property uv_size : Vec2

    def initialize(@size : Vec2, @color : Color = Color::WHITE, @texture : Texture? = nil,
                   @z : Float32 = 0.0f32, @material : SpriteMaterial? = nil,
                   @uv_min : Vec2 = Vec2.new(0, 0), @uv_size : Vec2 = Vec2.new(1, 1))
    end
  end
end
