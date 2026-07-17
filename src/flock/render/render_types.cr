module Flock
  # Hemisphere ambient light ("ambient probe"): surfaces facing up receive `sky`,
  # facing down receive `ground`, blended by the world normal. Insert it as a resource
  # to tint the 3D ambient term; absent, Renderer3D uses a neutral gray (~the old flat
  # ambient). A cheap stand-in for image-based lighting.
  class AmbientLight < Resource
    property sky : Color
    property ground : Color

    def initialize(@sky : Color = Color.new(0.2, 0.2, 0.2), @ground : Color = Color.new(0.2, 0.2, 0.2))
    end
  end

  enum LightKind : Int32
    Directional # infinitely far; only `direction` matters
    Point       # omni, positioned (Transform3D.position), falls off within `range`
    Spot        # positioned + `direction` + a cone (`inner`/`outer` half-angles, radians)
  end

  # A light source. Attach it (with a `Transform3D` for position) to an entity; Renderer3D
  # collects all lights each frame and the PBR shader accumulates them. With no `Light`
  # entities, the renderer falls back to its legacy single hard-coded directional light.
  struct Light
    include Component
    property kind : LightKind
    property color : Color
    property intensity : Float32
    property direction : Vec3    # directional/spot aim (world space)
    property range : Float32     # point/spot falloff radius
    property inner : Float32     # spot inner cone half-angle (radians)
    property outer : Float32     # spot outer cone half-angle (radians)
    property casts_shadows : Bool # only the first directional shadow-caster is honored

    def initialize(@kind : LightKind = LightKind::Directional, @color : Color = Color::WHITE,
                   @intensity : Float32 = 1.0f32, @direction : Vec3 = Vec3.new(0, -1, 0),
                   @range : Float32 = 10.0f32, @inner : Float32 = 0.3f32, @outer : Float32 = 0.5f32,
                   @casts_shadows : Bool = false)
    end

    def self.directional(direction : Vec3, color : Color = Color::WHITE, intensity : Number = 1.0,
                          casts_shadows : Bool = false) : Light
      new(LightKind::Directional, color, intensity.to_f32, direction, casts_shadows: casts_shadows)
    end

    def self.point(color : Color = Color::WHITE, intensity : Number = 1.0, range : Number = 10.0) : Light
      new(LightKind::Point, color, intensity.to_f32, Vec3.new, range.to_f32)
    end

    def self.spot(direction : Vec3, color : Color = Color::WHITE, intensity : Number = 1.0,
                  range : Number = 10.0, inner : Number = 0.3, outer : Number = 0.5) : Light
      new(LightKind::Spot, color, intensity.to_f32, direction, range.to_f32, inner.to_f32, outer.to_f32)
    end
  end

  # Mutable, shared-by-reference world-space AABB of a skinned mesh's current pose. It's a
  # class (reference), so the `GpuSkinnedMesh` copy stored in the World and the copy held by
  # `GpuSkinnedModel` share ONE object: the model updates it each frame, the renderer reads
  # it (to fit the shadow frustum) without any write-back plumbing.
  class SkinnedBounds
    property min : Vec3 = Vec3.new(Float32::MAX, Float32::MAX, Float32::MAX)
    property max : Vec3 = Vec3.new(-Float32::MAX, -Float32::MAX, -Float32::MAX)
    getter? valid : Bool = false

    def reset : Nil
      @min = Vec3.new(Float32::MAX, Float32::MAX, Float32::MAX)
      @max = Vec3.new(-Float32::MAX, -Float32::MAX, -Float32::MAX)
      @valid = false
    end

    # Folds a world sphere (center ± radius) into the AABB.
    def add(c : Vec3, r : Float32) : Nil
      @min = Vec3.new(Math.min(@min.x, c.x - r), Math.min(@min.y, c.y - r), Math.min(@min.z, c.z - r))
      @max = Vec3.new(Math.max(@max.x, c.x + r), Math.max(@max.y, c.y + r), Math.max(@max.z, c.z + r))
      @valid = true
    end
  end

  # A GPU-skinned mesh instance (drawn with Renderer3D's skinned pipeline): it reuses a
  # bind-pose `Mesh` for slot 0, plus a skin vertex buffer (joints+weights) for slot 1
  # and a joint-matrix storage buffer updated each frame. Built via
  # `Renderer3D#build_gpu_skin` and driven by `Flock::GpuSkinnedModel`.
  struct GpuSkinnedMesh
    include Component
    getter mesh : Mesh
    getter skin_buf : LibWGPU::Buffer
    getter skin_bytes : UInt64
    getter joint_buf : LibWGPU::Buffer
    getter joint_group : LibWGPU::BindGroup
    getter joint_count : Int32
    getter joint_nodes : Array(Int32)
    getter inverse_binds : Array(Mat4)
    getter bounds : SkinnedBounds = SkinnedBounds.new # shared, updated by GpuSkinnedModel

    def initialize(@mesh, @skin_buf, @skin_bytes, @joint_buf, @joint_group, @joint_count, @joint_nodes, @inverse_binds)
    end

    # Frees the skin GPU resources (not the shared bind-pose Mesh — release that separately).
    def release : Nil
      LibWGPU.bind_group_release(@joint_group)
      LibWGPU.buffer_release(@joint_buf)
      LibWGPU.buffer_release(@skin_buf)
    end
  end

  # A GPU morph-target mesh (drawn with Renderer3D's morph pipeline): the base `Mesh` plus a
  # storage buffer of per-vertex target deltas, a weights storage buffer + a model-matrix
  # uniform (both updated each frame), and its bind group. Built via
  # `Renderer3D#build_gpu_morph`, driven by `Flock::GpuMorphModel`.
  struct GpuMorphMesh
    include Component
    getter mesh : Mesh
    getter deltas_buf : LibWGPU::Buffer
    getter weights_buf : LibWGPU::Buffer
    getter model_buf : LibWGPU::Buffer
    getter group : LibWGPU::BindGroup
    getter target_count : Int32
    getter node : Int32
    getter default_weights : Array(Float32)

    def initialize(@mesh, @deltas_buf, @weights_buf, @model_buf, @group, @target_count, @node, @default_weights)
    end

    # Frees the morph GPU resources (not the shared bind-pose Mesh — release that separately).
    def release : Nil
      LibWGPU.bind_group_release(@group)
      LibWGPU.buffer_release(@model_buf)
      LibWGPU.buffer_release(@weights_buf)
      LibWGPU.buffer_release(@deltas_buf)
    end
  end

  # A custom 3D material: a render pipeline built from user WGSL by
  # `Renderer3D#build_material`, sharing the renderer's pipeline layout (group0 =
  # camera + models + globals) and vertex layout (pos/normal/color). Assign to
  # `MeshRenderer#material` to draw that mesh with it.
  class Material3D
    getter pipeline : LibWGPU::RenderPipeline

    def initialize(@pipeline : LibWGPU::RenderPipeline, @shader : LibWGPU::ShaderModule)
    end

    def release : Nil
      LibWGPU.render_pipeline_release(@pipeline)
      LibWGPU.shader_module_release(@shader)
    end
  end

  # Tonemapping operator for the optional HDR post-processing pass. `None` keeps the
  # direct LDR path (no post pass). `Aces`/`Reinhard` render the scene to an HDR
  # (rgba16float) target and compress it to the display range in a fullscreen pass.
  enum Tonemap
    None
    Aces     # Narkowicz ACES filmic approximation
    Reinhard # c / (1 + c)
  end
end
