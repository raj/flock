module Flock
  # (Transform2D / Transform3D moved to src/flock/transform.cr — native-free, shared.)

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
    # Emissive (glTF `KHR` emissive): `emissive` map (nil = white) multiplied by
    # `emissive_factor` (default black = no emission) and added to the final color.
    property emissive : Texture?
    property emissive_factor : Color
    # Ambient occlusion map (glTF): its R channel modulates the ambient/indirect term.
    # nil = white = no occlusion.
    property occlusion : Texture?
    # Per-instance tint (multiplied into the mesh's vertex color) + alpha. Lets many
    # entities share one mesh yet render in different colors within a single draw.
    property tint : Color
    # Alpha blending. When true the mesh is drawn in a separate back-to-front pass with
    # blending on and depth-writes off (so it reads the opaque depth but doesn't occlude
    # other translucent meshes). The `tint`/base-texture alpha then controls opacity.
    # Opaque meshes (the default) are unaffected and still batched/instanced.
    property transparent : Bool
    # Alpha MASK cutoff (glTF `alphaMode: "MASK"`): when > 0, fragments whose final alpha
    # is below this threshold are discarded (hard-edged cutout). 0 disables masking.
    property alpha_cutoff : Float32
    # UV-set selector bitmask (glTF `texCoord`): bit i set -> texture i samples the mesh's
    # second UV set (TEXCOORD_1). Bits: 0=base, 1=metallic-roughness, 2=normal, 3=emissive,
    # 4=occlusion. 0 (default) = every texture uses TEXCOORD_0.
    property tex_coords : UInt32
    # Frustum culling. Skinned/morphed meshes deform away from their bind-pose bounds, so
    # culling by those bounds can wrongly drop (or keep) them. Set false to always draw the
    # instance regardless of its bounding sphere. The CPU skinning/morph models set this.
    property cull : Bool

    def initialize(@mesh : Mesh, @material : Material3D? = nil, @texture : Texture? = nil,
                   @tint : Color = Color::WHITE, @metallic_roughness : Texture? = nil,
                   @normal_map : Texture? = nil, @metallic : Float32 = 0.0f32, @roughness : Float32 = 1.0f32,
                   @transparent : Bool = false, @emissive : Texture? = nil,
                   @emissive_factor : Color = Color::BLACK, @occlusion : Texture? = nil,
                   @alpha_cutoff : Float32 = 0.0f32, @tex_coords : UInt32 = 0_u32, @cull : Bool = true)
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
