module Flock

  # 3D mesh renderer consuming Camera3D. Draws entities with (Transform3D, MeshRenderer)
  # using per-mesh vertex/index buffers, a shared view-projection uniform + a storage
  # buffer of model matrices (indexed by @builtin(instance_index)), a depth buffer for
  # correct occlusion, and simple directional lighting.
  #
  # Custom shaders: `build_material(wgsl)` returns a Material3D that reuses the shared
  # group0 (camera/models/globals). Globals exposes `time` (seconds) for animation.
  #
  # Wire it with `Render3DPlugin` (inserts the renderer + a Schedule::Render system).
  # Not to be combined with the 2D RenderPlugin (each owns the whole frame).
  class Renderer3D < Resource
    MODEL_BYTES   = 64 # mat4 (16 f32)
    GLOBALS_BYTES = 64 # time / camera position / ambient sky / ambient ground (4 vec4)
    PARAM_BYTES   = 48 # per-instance: tint vec4 + {metallic, roughness, cutoff, _} + emissive vec4
    MAX_LIGHTS    = 16   # storage-buffer capacity; extra lights are dropped
    LIGHT_BYTES   = 64   # per light: 4 vec4 (pos+kind / dir+range / color+intensity / cones)
    SHADOW_SIZE   = 2048 # shadow map resolution (Depth32Float), single directional caster


    @model_capacity : Int32 = 64
    @scratch : Array(Float32) = [] of Float32
    @scratch_n : Array(Float32) = [] of Float32
    @scratch_p : Array(Float32) = [] of Float32
    @scratch_l : Array(Float32) = [] of Float32
    @depth_w : UInt32 = 0
    @depth_h : UInt32 = 0
    # Frustum-culling stats from the last render_into (drawn vs. culled instances).
    getter last_drawn : Int32 = 0
    getter last_culled : Int32 = 0
    # Set false to disable frustum culling (e.g. for debugging).
    property cull : Bool = true

    @shader : LibWGPU::ShaderModule
    @pipeline : LibWGPU::RenderPipeline
    @transparent_pipeline : LibWGPU::RenderPipeline # alpha-blended variant (depth-write off)
    @group0_layout : LibWGPU::BindGroupLayout
    @group1_layout : LibWGPU::BindGroupLayout # texture + sampler
    @pipeline_layout : LibWGPU::PipelineLayout
    # GPU skinning: joint-matrix bind group layout + a dedicated skinned pipeline.
    @joint_layout : LibWGPU::BindGroupLayout
    @skinned_shader : LibWGPU::ShaderModule
    @skinned_pipeline : LibWGPU::RenderPipeline
    # GPU morph targets: group2 layout (deltas storage + weights storage + model uniform) +
    # a dedicated morph pipeline.
    @morph_layout : LibWGPU::BindGroupLayout
    @morph_shader : LibWGPU::ShaderModule
    @morph_pipeline : LibWGPU::RenderPipeline
    # IBL: group2 layout (2 cubemaps + LUT + sampler) + a default (unused) environment.
    @ibl_layout : LibWGPU::BindGroupLayout
    @default_ibl : IblEnvironment
    @white : Texture
    @flat_normal : Texture # 1x1 (0,0,1) tangent-space normal (no perturbation)
    @samplers : Hash(Tuple(SamplerFilter, SamplerWrap), LibWGPU::Sampler) = {} of Tuple(SamplerFilter, SamplerWrap) => LibWGPU::Sampler
    @tex_groups : Hash(Tuple(UInt64, UInt64, UInt64, UInt64, UInt64), LibWGPU::BindGroup) = {} of Tuple(UInt64, UInt64, UInt64, UInt64, UInt64) => LibWGPU::BindGroup
    @uniform_buf : LibWGPU::Buffer
    @model_buf : LibWGPU::Buffer
    @normal_buf : LibWGPU::Buffer
    @param_buf : LibWGPU::Buffer
    @globals_buf : LibWGPU::Buffer
    @lights_buf : LibWGPU::Buffer
    @group0 : LibWGPU::BindGroup
    # Shadow mapping (single directional caster): a depth-only pass into @shadow_tex,
    # sampled by the main PBR shader (group3) with a comparison sampler.
    @shadow_layout : LibWGPU::BindGroupLayout       # group3 for the main pass
    @shadow_pass_layout : LibWGPU::BindGroupLayout   # group0 for the depth pass
    @shadow_pipeline_layout : LibWGPU::PipelineLayout
    @shadow_shader : LibWGPU::ShaderModule
    @shadow_pipeline : LibWGPU::RenderPipeline
    @shadow_skinned_shader : LibWGPU::ShaderModule   # skinned depth pass (GPU-skinned casters)
    @shadow_skinned_pipeline : LibWGPU::RenderPipeline
    @shadow_vp_buf : LibWGPU::Buffer                 # light view-projection (mat4)
    @shadow_sampler : LibWGPU::Sampler               # comparison sampler
    @shadow_tex : LibWGPU::Texture
    @shadow_view : LibWGPU::TextureView
    @shadow_group3 : LibWGPU::BindGroup              # main-pass: light_vp + map + sampler
    @shadow_pass_group : LibWGPU::BindGroup          # depth-pass: light_vp + models
    @materials : Array(Material3D) = [] of Material3D
    @depth_tex : LibWGPU::Texture
    @depth_view : LibWGPU::TextureView
    # MSAA: when @sample_count > 1, geometry renders into a multisampled color target
    # (@msaa_view) that is resolved into the frame's single-sample target. The depth
    # buffer matches @sample_count. sample_count == 1 keeps the direct (non-resolved) path.
    @msaa_tex : LibWGPU::Texture
    @msaa_view : LibWGPU::TextureView
    # Post-processing (@tonemap != None): the scene renders to an HDR (rgba16float) target
    # (@hdr_view) which a fullscreen pass tonemaps into the frame target. @scene_format is
    # the color format the geometry pipelines write (HDR when tonemapping, else @gpu.format).
    @scene_format : LibWGPU::TextureFormat
    @hdr_tex : LibWGPU::Texture
    @hdr_view : LibWGPU::TextureView
    @post_shader : LibWGPU::ShaderModule
    @post_layout : LibWGPU::BindGroupLayout
    @post_pipeline : LibWGPU::RenderPipeline
    @post_sampler : LibWGPU::Sampler
    @post_group : LibWGPU::BindGroup

    # `sample_count` controls MSAA (1 = off, 2/4/8 = multisampled with a resolve to the
    # frame target). Common values are 1 and 4. Render3DPlugin defaults to 4.
    # `tonemap` enables HDR rendering + a fullscreen tonemap pass (None keeps LDR direct).
    def initialize(@gpu : GpuContext, @sample_count : Int32 = 1, @tonemap : Tonemap = Tonemap::None)
      raise "sample_count must be >= 1" if @sample_count < 1
      # Geometry writes HDR (rgba16float) when tonemapping, else straight to the frame format.
      @scene_format = @tonemap.none? ? @gpu.format : LibWGPU::TextureFormat::RGBA16Float
      # Explicit group0 (camera/models/globals/normals/params), group1 (textures) and
      # group2 (IBL) layouts so custom materials share the rigid pipeline layout.
      @group0_layout = build_group0_layout
      @group1_layout = build_group1_layout
      @ibl_layout = build_ibl_layout
      @shadow_layout = build_shadow_layout
      @pipeline_layout = build_pipeline_layout
      @white = Texture.white(@gpu)
      @flat_normal = Texture.from_pixels(@gpu, 1, 1, Bytes[128_u8, 128_u8, 255_u8, 255_u8])

      @shader = build_shader(WGSL)
      @pipeline = build_pipeline(@shader)
      @transparent_pipeline = build_pipeline(@shader, blend: true)
      @default_ibl = build_ibl_default

      # Skinned pipeline (group0 + group1 + joint matrices in group2).
      @joint_layout = build_joint_layout
      @skinned_shader = build_shader(SKINNED_WGSL)
      @skinned_pipeline = build_skinned_pipeline(@skinned_shader)

      # GPU morph pipeline (group0 + group1 + deltas/weights/model in group2).
      @morph_layout = build_morph_layout
      @morph_shader = build_shader(MORPH_WGSL)
      @morph_pipeline = build_morph_pipeline(@morph_shader)

      @uniform_buf = make_buffer(64_u64, LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst)
      @model_buf = make_buffer((@model_capacity * MODEL_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      @normal_buf = make_buffer((@model_capacity * MODEL_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      @param_buf = make_buffer((@model_capacity * PARAM_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      @globals_buf = make_buffer(GLOBALS_BYTES.to_u64, LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst)
      @lights_buf = make_buffer((MAX_LIGHTS * LIGHT_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      @group0 = build_group0

      # Shadow mapping: depth pass pipeline + shadow map + comparison sampler + bind groups.
      @shadow_pass_layout = build_shadow_pass_layout
      @shadow_pipeline_layout = build_shadow_pipeline_layout
      @shadow_shader = build_shader(SHADOW_WGSL)
      @shadow_pipeline = build_shadow_pipeline
      @shadow_skinned_shader = build_shader(SHADOW_SKINNED_WGSL)
      @shadow_skinned_pipeline = build_shadow_skinned_pipeline
      @shadow_vp_buf = make_buffer(64_u64, LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst)
      @shadow_sampler = build_shadow_sampler
      @shadow_tex = Pointer(Void).null.as(LibWGPU::Texture)
      @shadow_view = Pointer(Void).null.as(LibWGPU::TextureView)
      build_shadow_texture
      @shadow_group3 = build_shadow_group3
      @shadow_pass_group = build_shadow_pass_group

      # Post-processing (HDR target + fullscreen tonemap pass). Only when @tonemap != None.
      @hdr_tex = Pointer(Void).null.as(LibWGPU::Texture)
      @hdr_view = Pointer(Void).null.as(LibWGPU::TextureView)
      @post_layout = build_post_layout
      @post_sampler = build_sampler(SamplerFilter::Linear, SamplerWrap::Clamp)
      @post_shader = build_shader(POST_WGSL.gsub("MODE", @tonemap.reinhard? ? "1" : "0"))
      @post_pipeline = build_post_pipeline
      @post_group = Pointer(Void).null.as(LibWGPU::BindGroup)

      # Depth + MSAA color targets (lazily sized to the surface on first render).
      @depth_tex = Pointer(Void).null.as(LibWGPU::Texture)
      @depth_view = Pointer(Void).null.as(LibWGPU::TextureView)
      @msaa_tex = Pointer(Void).null.as(LibWGPU::Texture)
      @msaa_view = Pointer(Void).null.as(LibWGPU::TextureView)
    end

    # Builds a custom material from WGSL. It must declare the shared group0
    # (bindings 0=camera, 1=models, 2=globals) and the pos/normal/color vertex
    # inputs, with `vs_main`/`fs_main` entry points. See examples/solar_system.
    def build_material(wgsl : String) : Material3D
      mod = build_shader(wgsl)
      material = Material3D.new(build_pipeline(mod), mod)
      @materials << material
      material
    end

    def release : Nil
      LibWGPU.texture_view_release(@depth_view) unless @depth_view.null?
      LibWGPU.texture_release(@depth_tex) unless @depth_tex.null?
      LibWGPU.texture_view_release(@msaa_view) unless @msaa_view.null?
      LibWGPU.texture_release(@msaa_tex) unless @msaa_tex.null?
      LibWGPU.bind_group_release(@post_group) unless @post_group.null?
      LibWGPU.texture_view_release(@hdr_view) unless @hdr_view.null?
      LibWGPU.texture_release(@hdr_tex) unless @hdr_tex.null?
      LibWGPU.render_pipeline_release(@post_pipeline)
      LibWGPU.shader_module_release(@post_shader)
      LibWGPU.sampler_release(@post_sampler)
      LibWGPU.bind_group_layout_release(@post_layout)
      @materials.each &.release
      @tex_groups.each_value { |bg| LibWGPU.bind_group_release(bg) }
      @tex_groups.clear
      @samplers.each_value { |s| LibWGPU.sampler_release(s) }
      @samplers.clear
      @white.release
      @flat_normal.release
      LibWGPU.bind_group_release(@shadow_pass_group)
      LibWGPU.bind_group_release(@shadow_group3)
      LibWGPU.texture_view_release(@shadow_view) unless @shadow_view.null?
      LibWGPU.texture_release(@shadow_tex) unless @shadow_tex.null?
      LibWGPU.sampler_release(@shadow_sampler)
      LibWGPU.buffer_release(@shadow_vp_buf)
      LibWGPU.render_pipeline_release(@shadow_skinned_pipeline)
      LibWGPU.shader_module_release(@shadow_skinned_shader)
      LibWGPU.render_pipeline_release(@shadow_pipeline)
      LibWGPU.shader_module_release(@shadow_shader)
      LibWGPU.pipeline_layout_release(@shadow_pipeline_layout)
      LibWGPU.bind_group_layout_release(@shadow_pass_layout)
      LibWGPU.bind_group_layout_release(@shadow_layout)
      LibWGPU.bind_group_release(@group0)
      LibWGPU.buffer_release(@lights_buf)
      LibWGPU.buffer_release(@globals_buf)
      LibWGPU.buffer_release(@param_buf)
      LibWGPU.buffer_release(@normal_buf)
      LibWGPU.buffer_release(@model_buf)
      LibWGPU.buffer_release(@uniform_buf)
      @default_ibl.release
      LibWGPU.bind_group_layout_release(@ibl_layout)
      LibWGPU.render_pipeline_release(@morph_pipeline)
      LibWGPU.shader_module_release(@morph_shader)
      LibWGPU.bind_group_layout_release(@morph_layout)
      LibWGPU.render_pipeline_release(@skinned_pipeline)
      LibWGPU.shader_module_release(@skinned_shader)
      LibWGPU.bind_group_layout_release(@joint_layout)
      LibWGPU.pipeline_layout_release(@pipeline_layout)
      LibWGPU.render_pipeline_release(@transparent_pipeline)
      LibWGPU.render_pipeline_release(@pipeline)
      LibWGPU.shader_module_release(@shader)
      LibWGPU.bind_group_layout_release(@group1_layout)
      LibWGPU.bind_group_layout_release(@group0_layout)
    end

    private def build_shader(wgsl : String) : LibWGPU::ShaderModule
      code = WGPU.string_view(wgsl)
      src = LibWGPU::ShaderSourceWGSL.new
      src.chain.s_type = LibWGPU::SType::ShaderSourceWGSL
      src.code = code
      sdesc = LibWGPU::ShaderModuleDescriptor.new
      sdesc.label = WGPU.empty_string_view
      sdesc.next_in_chain = pointerof(src).as(Pointer(LibWGPU::ChainedStruct))
      LibWGPU.device_create_shader_module(@gpu.device, pointerof(sdesc))
    end

    private def build_group0_layout : LibWGPU::BindGroupLayout
      ubuf = LibWGPU::BufferBindingLayout.new
      ubuf.type_ = LibWGPU::BufferBindingType::Uniform
      e0 = LibWGPU::BindGroupLayoutEntry.new
      e0.binding = 0_u32
      e0.visibility = LibWGPU::ShaderStage::Vertex | LibWGPU::ShaderStage::Fragment
      e0.buffer = ubuf

      sbuf = LibWGPU::BufferBindingLayout.new
      sbuf.type_ = LibWGPU::BufferBindingType::ReadOnlyStorage
      e1 = LibWGPU::BindGroupLayoutEntry.new
      e1.binding = 1_u32
      e1.visibility = LibWGPU::ShaderStage::Vertex
      e1.buffer = sbuf

      gbuf = LibWGPU::BufferBindingLayout.new
      gbuf.type_ = LibWGPU::BufferBindingType::Uniform
      e2 = LibWGPU::BindGroupLayoutEntry.new
      e2.binding = 2_u32
      e2.visibility = LibWGPU::ShaderStage::Vertex | LibWGPU::ShaderStage::Fragment
      e2.buffer = gbuf

      nbuf = LibWGPU::BufferBindingLayout.new
      nbuf.type_ = LibWGPU::BufferBindingType::ReadOnlyStorage
      e3 = LibWGPU::BindGroupLayoutEntry.new
      e3.binding = 3_u32
      e3.visibility = LibWGPU::ShaderStage::Vertex
      e3.buffer = nbuf

      pbuf = LibWGPU::BufferBindingLayout.new
      pbuf.type_ = LibWGPU::BufferBindingType::ReadOnlyStorage
      e4 = LibWGPU::BindGroupLayoutEntry.new
      e4.binding = 4_u32
      e4.visibility = LibWGPU::ShaderStage::Vertex
      e4.buffer = pbuf

      lbuf = LibWGPU::BufferBindingLayout.new
      lbuf.type_ = LibWGPU::BufferBindingType::ReadOnlyStorage
      e5 = LibWGPU::BindGroupLayoutEntry.new
      e5.binding = 5_u32
      e5.visibility = LibWGPU::ShaderStage::Fragment
      e5.buffer = lbuf

      entries = uninitialized LibWGPU::BindGroupLayoutEntry[6]
      entries[0] = e0
      entries[1] = e1
      entries[2] = e2
      entries[3] = e3
      entries[4] = e4
      entries[5] = e5
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 6_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    # group1: base-color (0) + sampler (1) + metallic-roughness (2) + normal map (3).
    private def build_group1_layout : LibWGPU::BindGroupLayout
      texlayout = ->(binding : UInt32) do
        t = LibWGPU::TextureBindingLayout.new
        t.sample_type = LibWGPU::TextureSampleType::Float
        t.view_dimension = LibWGPU::TextureViewDimension::N2D
        e = LibWGPU::BindGroupLayoutEntry.new
        e.binding = binding
        e.visibility = LibWGPU::ShaderStage::Fragment
        e.texture = t
        e
      end
      smp = LibWGPU::SamplerBindingLayout.new
      smp.type_ = LibWGPU::SamplerBindingType::Filtering
      e1 = LibWGPU::BindGroupLayoutEntry.new
      e1.binding = 1_u32
      e1.visibility = LibWGPU::ShaderStage::Fragment
      e1.sampler = smp

      entries = uninitialized LibWGPU::BindGroupLayoutEntry[6]
      entries[0] = texlayout.call(0_u32) # base color
      entries[1] = e1                    # sampler
      entries[2] = texlayout.call(2_u32) # metallic-roughness
      entries[3] = texlayout.call(3_u32) # normal map
      entries[4] = texlayout.call(4_u32) # emissive
      entries[5] = texlayout.call(5_u32) # occlusion
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 6_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    private def build_pipeline_layout : LibWGPU::PipelineLayout
      layouts = uninitialized LibWGPU::BindGroupLayout[4]
      layouts[0] = @group0_layout
      layouts[1] = @group1_layout
      layouts[2] = @ibl_layout
      layouts[3] = @shadow_layout
      d = LibWGPU::PipelineLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.bind_group_layout_count = 4_u64
      d.bind_group_layouts = layouts.to_unsafe
      LibWGPU.device_create_pipeline_layout(@gpu.device, pointerof(d))
    end


    private def sampler_for(filter : SamplerFilter, wrap : SamplerWrap) : LibWGPU::Sampler
      @samplers[{filter, wrap}] ||= build_sampler(filter, wrap)
    end

    private def build_sampler(filter : SamplerFilter, wrap : SamplerWrap) : LibWGPU::Sampler
      addr = wrap.repeat? ? LibWGPU::AddressMode::Repeat : LibWGPU::AddressMode::ClampToEdge
      fmode = filter.linear? ? LibWGPU::FilterMode::Linear : LibWGPU::FilterMode::Nearest
      mmode = filter.linear? ? LibWGPU::MipmapFilterMode::Linear : LibWGPU::MipmapFilterMode::Nearest
      d = LibWGPU::SamplerDescriptor.new
      d.label = WGPU.empty_string_view
      d.address_mode_u = addr; d.address_mode_v = addr; d.address_mode_w = addr
      d.mag_filter = fmode; d.min_filter = fmode; d.mipmap_filter = mmode
      # Allow the whole mip chain when a texture has one; single-mip textures always
      # sample level 0 (LOD is clamped to the view's available levels), so this is safe.
      d.lod_min_clamp = 0.0f32; d.lod_max_clamp = 32.0f32; d.max_anisotropy = 1_u16
      LibWGPU.device_create_sampler(@gpu.device, pointerof(d))
    end

    # Number of cached texture bind groups (for tests / diagnostics).
    def cached_texture_groups : Int32
      @tex_groups.size
    end

    private def tex_group(base : Texture, mr : Texture, normal : Texture,
                          emissive : Texture, occlusion : Texture) : LibWGPU::BindGroup
      key = {base.id, mr.id, normal.id, emissive.id, occlusion.id}
      @tex_groups.fetch(key) do
        e0 = LibWGPU::BindGroupEntry.new; e0.binding = 0_u32; e0.texture_view = base.view
        e1 = LibWGPU::BindGroupEntry.new; e1.binding = 1_u32; e1.sampler = sampler_for(base.filter, base.wrap)
        e2 = LibWGPU::BindGroupEntry.new; e2.binding = 2_u32; e2.texture_view = mr.view
        e3 = LibWGPU::BindGroupEntry.new; e3.binding = 3_u32; e3.texture_view = normal.view
        e4 = LibWGPU::BindGroupEntry.new; e4.binding = 4_u32; e4.texture_view = emissive.view
        e5 = LibWGPU::BindGroupEntry.new; e5.binding = 5_u32; e5.texture_view = occlusion.view
        entries = uninitialized LibWGPU::BindGroupEntry[6]
        entries[0] = e0; entries[1] = e1; entries[2] = e2; entries[3] = e3; entries[4] = e4; entries[5] = e5
        d = LibWGPU::BindGroupDescriptor.new
        d.label = WGPU.empty_string_view
        d.layout = @group1_layout
        d.entry_count = 6_u64
        d.entries = entries.to_unsafe
        bg = LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
        @tex_groups[key] = bg
        # Evict when ANY of the keyed textures is released. First release wins; a later one
        # finds the entry gone (delete returns nil) and no-ops. Skip @white/@flat_normal
        # (defaults live for the renderer's lifetime and are released in `release`).
        {base, mr, normal, emissive, occlusion}.each do |tex|
          next if tex.same?(@white) || tex.same?(@flat_normal)
          tex.on_release { @tex_groups.delete(key).try { |g| LibWGPU.bind_group_release(g) } }
        end
        bg
      end
    end

    private def make_buffer(size : UInt64, usage : LibWGPU::BufferUsage) : LibWGPU::Buffer
      d = LibWGPU::BufferDescriptor.new
      d.label = WGPU.empty_string_view
      d.usage = usage
      d.size = size
      d.mapped_at_creation = 0_u32
      LibWGPU.device_create_buffer(@gpu.device, pointerof(d))
    end

    # Builds the rigid 3D pipeline. `blend: true` produces the transparency variant:
    # standard alpha blending with depth-writes disabled (depth test stays on, so opaque
    # geometry still occludes translucent fragments).
    private def build_pipeline(shader : LibWGPU::ShaderModule, blend : Bool = false) : LibWGPU::RenderPipeline
      vs = WGPU.string_view("vs_main")
      fs = WGPU.string_view("fs_main")

      blend_state = LibWGPU::BlendState.new
      blend_state.color = LibWGPU::BlendComponent.new(
        operation: LibWGPU::BlendOperation::Add,
        src_factor: LibWGPU::BlendFactor::SrcAlpha,
        dst_factor: LibWGPU::BlendFactor::OneMinusSrcAlpha)
      blend_state.alpha = LibWGPU::BlendComponent.new(
        operation: LibWGPU::BlendOperation::Add,
        src_factor: LibWGPU::BlendFactor::One,
        dst_factor: LibWGPU::BlendFactor::OneMinusSrcAlpha)

      # Vertex layout: pos(loc0), normal(loc1), color(loc2) Float32x3; uv(loc3), uv1(loc4) Float32x2.
      a0 = LibWGPU::VertexAttribute.new; a0.format = LibWGPU::VertexFormat::Float32x3; a0.offset = 0_u64; a0.shader_location = 0_u32
      a1 = LibWGPU::VertexAttribute.new; a1.format = LibWGPU::VertexFormat::Float32x3; a1.offset = 12_u64; a1.shader_location = 1_u32
      a2 = LibWGPU::VertexAttribute.new; a2.format = LibWGPU::VertexFormat::Float32x3; a2.offset = 24_u64; a2.shader_location = 2_u32
      a3 = LibWGPU::VertexAttribute.new; a3.format = LibWGPU::VertexFormat::Float32x2; a3.offset = 36_u64; a3.shader_location = 3_u32
      a4 = LibWGPU::VertexAttribute.new; a4.format = LibWGPU::VertexFormat::Float32x2; a4.offset = 44_u64; a4.shader_location = 4_u32
      attrs = uninitialized LibWGPU::VertexAttribute[5]
      attrs[0] = a0; attrs[1] = a1; attrs[2] = a2; attrs[3] = a3; attrs[4] = a4

      vlayout = LibWGPU::VertexBufferLayout.new
      vlayout.step_mode = LibWGPU::VertexStepMode::Vertex
      vlayout.array_stride = Mesh::STRIDE
      vlayout.attribute_count = 5_u64
      vlayout.attributes = attrs.to_unsafe

      vertex = LibWGPU::VertexState.new
      vertex.module_ = shader
      vertex.entry_point = vs
      vertex.buffer_count = 1_u64
      vertex.buffers = pointerof(vlayout)

      target = LibWGPU::ColorTargetState.new
      target.format = @scene_format
      target.write_mask = LibWGPU::ColorWriteMask::All
      target.blend = pointerof(blend_state) if blend

      fragment = LibWGPU::FragmentState.new
      fragment.module_ = shader
      fragment.entry_point = fs
      fragment.target_count = 1_u64
      fragment.targets = pointerof(target)

      primitive = LibWGPU::PrimitiveState.new
      primitive.topology = LibWGPU::PrimitiveTopology::TriangleList
      primitive.front_face = LibWGPU::FrontFace::CCW
      primitive.cull_mode = LibWGPU::CullMode::None

      # Depth test always on; depth-write off for the blended variant so translucent
      # fragments read the opaque depth but don't occlude one another. Stencil unused.
      face = LibWGPU::StencilFaceState.new
      face.compare = LibWGPU::CompareFunction::Always
      face.fail_op = LibWGPU::StencilOperation::Keep
      face.depth_fail_op = LibWGPU::StencilOperation::Keep
      face.pass_op = LibWGPU::StencilOperation::Keep
      depth = LibWGPU::DepthStencilState.new
      depth.format = LibWGPU::TextureFormat::Depth32Float
      depth.depth_write_enabled = blend ? LibWGPU::OptionalBool::False : LibWGPU::OptionalBool::True
      depth.depth_compare = LibWGPU::CompareFunction::Less
      depth.stencil_front = face
      depth.stencil_back = face

      multisample = LibWGPU::MultisampleState.new
      multisample.count = @sample_count.to_u32
      multisample.mask = 0xFFFFFFFF_u32

      desc = LibWGPU::RenderPipelineDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.layout = @pipeline_layout
      desc.vertex = vertex
      desc.primitive = primitive
      desc.depth_stencil = pointerof(depth)
      desc.multisample = multisample
      desc.fragment = pointerof(fragment)
      LibWGPU.device_create_render_pipeline(@gpu.device, pointerof(desc))
    end


    private def build_group0 : LibWGPU::BindGroup
      e0 = LibWGPU::BindGroupEntry.new
      e0.binding = 0_u32
      e0.buffer = @uniform_buf
      e0.offset = 0_u64
      e0.size = 64_u64
      e1 = LibWGPU::BindGroupEntry.new
      e1.binding = 1_u32
      e1.buffer = @model_buf
      e1.offset = 0_u64
      e1.size = (@model_capacity * MODEL_BYTES).to_u64
      e2 = LibWGPU::BindGroupEntry.new
      e2.binding = 2_u32
      e2.buffer = @globals_buf
      e2.offset = 0_u64
      e2.size = GLOBALS_BYTES.to_u64
      e3 = LibWGPU::BindGroupEntry.new
      e3.binding = 3_u32
      e3.buffer = @normal_buf
      e3.offset = 0_u64
      e3.size = (@model_capacity * MODEL_BYTES).to_u64
      e4 = LibWGPU::BindGroupEntry.new
      e4.binding = 4_u32
      e4.buffer = @param_buf
      e4.offset = 0_u64
      e4.size = (@model_capacity * PARAM_BYTES).to_u64
      e5 = LibWGPU::BindGroupEntry.new
      e5.binding = 5_u32
      e5.buffer = @lights_buf
      e5.offset = 0_u64
      e5.size = (MAX_LIGHTS * LIGHT_BYTES).to_u64
      entries = uninitialized LibWGPU::BindGroupEntry[6]
      entries[0] = e0
      entries[1] = e1
      entries[2] = e2
      entries[3] = e3
      entries[4] = e4
      entries[5] = e5
      d = LibWGPU::BindGroupDescriptor.new
      d.label = WGPU.empty_string_view
      d.layout = @group0_layout
      d.entry_count = 6_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
    end

    private def ensure_capacity(n : Int32) : Nil
      return if n <= @model_capacity
      cap = @model_capacity
      while cap < n
        cap *= 2
      end
      @model_capacity = cap
      LibWGPU.buffer_release(@model_buf)
      @model_buf = make_buffer((cap * MODEL_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      LibWGPU.buffer_release(@normal_buf)
      @normal_buf = make_buffer((cap * MODEL_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      LibWGPU.buffer_release(@param_buf)
      @param_buf = make_buffer((cap * PARAM_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      LibWGPU.bind_group_release(@group0)
      @group0 = build_group0
      LibWGPU.bind_group_release(@shadow_pass_group)
      @shadow_pass_group = build_shadow_pass_group
    end

    private def ensure_depth(w : UInt32, h : UInt32) : Nil
      return if w == @depth_w && h == @depth_h && !@depth_view.null?
      LibWGPU.texture_view_release(@depth_view) unless @depth_view.null?
      LibWGPU.texture_release(@depth_tex) unless @depth_tex.null?
      LibWGPU.texture_view_release(@msaa_view) unless @msaa_view.null?
      LibWGPU.texture_release(@msaa_tex) unless @msaa_tex.null?
      LibWGPU.texture_view_release(@hdr_view) unless @hdr_view.null?
      LibWGPU.texture_release(@hdr_tex) unless @hdr_tex.null?
      LibWGPU.bind_group_release(@post_group) unless @post_group.null?

      # Depth buffer, matched to the MSAA sample count so it can back the same pass.
      desc = LibWGPU::TextureDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.usage = LibWGPU::TextureUsage::RenderAttachment
      desc.dimension = LibWGPU::TextureDimension::N2D
      desc.size = LibWGPU::Extent3D.new(width: w, height: h, depth_or_array_layers: 1_u32)
      desc.format = LibWGPU::TextureFormat::Depth32Float
      desc.mip_level_count = 1_u32
      desc.sample_count = @sample_count.to_u32
      @depth_tex = LibWGPU.device_create_texture(@gpu.device, pointerof(desc))
      @depth_view = LibWGPU.texture_create_view(@depth_tex, Pointer(LibWGPU::TextureViewDescriptor).null)

      # HDR scene target (single-sample) when tonemapping — the post pass samples it.
      unless @tonemap.none?
        hdesc = LibWGPU::TextureDescriptor.new
        hdesc.label = WGPU.empty_string_view
        hdesc.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::TextureBinding
        hdesc.dimension = LibWGPU::TextureDimension::N2D
        hdesc.size = LibWGPU::Extent3D.new(width: w, height: h, depth_or_array_layers: 1_u32)
        hdesc.format = @scene_format
        hdesc.mip_level_count = 1_u32
        hdesc.sample_count = 1_u32
        @hdr_tex = LibWGPU.device_create_texture(@gpu.device, pointerof(hdesc))
        @hdr_view = LibWGPU.texture_create_view(@hdr_tex, Pointer(LibWGPU::TextureViewDescriptor).null)
        @post_group = build_post_group
      end

      # Multisampled color target (resolved to the scene/frame target). Only when MSAA is on.
      # Its format matches the geometry pipelines (@scene_format: HDR when tonemapping).
      if @sample_count > 1
        cdesc = LibWGPU::TextureDescriptor.new
        cdesc.label = WGPU.empty_string_view
        cdesc.usage = LibWGPU::TextureUsage::RenderAttachment
        cdesc.dimension = LibWGPU::TextureDimension::N2D
        cdesc.size = LibWGPU::Extent3D.new(width: w, height: h, depth_or_array_layers: 1_u32)
        cdesc.format = @scene_format
        cdesc.mip_level_count = 1_u32
        cdesc.sample_count = @sample_count.to_u32
        @msaa_tex = LibWGPU.device_create_texture(@gpu.device, pointerof(cdesc))
        @msaa_view = LibWGPU.texture_create_view(@msaa_tex, Pointer(LibWGPU::TextureViewDescriptor).null)
      end
      @depth_w = w
      @depth_h = h
    end

    # Renders all (Transform3D, MeshRenderer) entities to the window surface.
    def render(world : World) : Nil
      st = LibWGPU::SurfaceTexture.new
      LibWGPU.surface_get_current_texture(@gpu.surface, pointerof(st))
      case st.status
      when .success_optimal?, .success_suboptimal?
        target = LibWGPU.texture_create_view(st.texture, Pointer(LibWGPU::TextureViewDescriptor).null)
        render_into(world, target)
        LibWGPU.surface_present(@gpu.surface)
        WGPU.release_surface(target, st.texture)
      when .outdated?, .lost?
        # Some backends still hand back a texture with a non-success status; release it.
        LibWGPU.texture_release(st.texture) unless st.texture.null?
        @gpu.reconfigure_to_window
      else
        LibWGPU.texture_release(st.texture) unless st.texture.null?
      end
    end

    # Packs every (Transform3D, Light) entity into the lights storage buffer. Returns the
    # light count (capped at MAX_LIGHTS), the index of the first directional shadow caster
    # (-1 if none), and that caster's normalized travel direction. Layout per light: 4 vec4.
    private def upload_lights(world : World) : {Int32, Int32, Vec3}
      @scratch_l.clear
      count = 0
      shadow_index = -1
      shadow_dir = Vec3.new(0, -1, 0)
      world.query(Transform3D, Light) do |_e, tf, lt|
        next if count >= MAX_LIGHTS
        l = lt.value
        pos = tf.value.position
        d = l.direction
        len = Math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z).to_f32
        len = 1.0f32 if len < 1e-6f32
        nd = Vec3.new(d.x / len, d.y / len, d.z / len)
        if shadow_index < 0 && l.kind.directional? && l.casts_shadows
          shadow_index = count
          shadow_dir = nd
        end
        # v0: position + kind
        @scratch_l << pos.x << pos.y << pos.z << l.kind.value.to_f32
        # v1: normalized direction + range
        @scratch_l << nd.x << nd.y << nd.z << l.range
        # v2: color + intensity
        @scratch_l << l.color.r << l.color.g << l.color.b << l.intensity
        # v3: cone cosines (spot) + padding
        @scratch_l << Math.cos(l.inner).to_f32 << Math.cos(l.outer).to_f32 << 0.0f32 << 0.0f32
        count += 1
      end
      if count > 0
        LibWGPU.queue_write_buffer(@gpu.queue, @lights_buf, 0_u64,
          @scratch_l.to_unsafe.as(Void*), (count * LIGHT_BYTES).to_u64)
      end
      {count, shadow_index, shadow_dir}
    end

    # Depth-only pass writing the shadow map from the caster's point of view. Iterates the
    # same draw groups (identical instance base offsets as the main pass) so shadows match
    # the rendered geometry. Submitted before the main pass, so the queue orders the write
    # ahead of the sampling read.
    private def render_shadow_pass(groups, world : World) : Nil
      depth_att = LibWGPU::RenderPassDepthStencilAttachment.new
      depth_att.view = @shadow_view
      depth_att.depth_load_op = LibWGPU::LoadOp::Clear
      depth_att.depth_store_op = LibWGPU::StoreOp::Store
      depth_att.depth_clear_value = 1.0f32

      pass_desc = LibWGPU::RenderPassDescriptor.new
      pass_desc.label = WGPU.empty_string_view
      pass_desc.color_attachment_count = 0_u64
      pass_desc.color_attachments = Pointer(LibWGPU::RenderPassColorAttachment).null
      pass_desc.depth_stencil_attachment = pointerof(depth_att)

      enc_desc = LibWGPU::CommandEncoderDescriptor.new
      enc_desc.label = WGPU.empty_string_view
      encoder = LibWGPU.device_create_command_encoder(@gpu.device, pointerof(enc_desc))
      pass = LibWGPU.command_encoder_begin_render_pass(encoder, pointerof(pass_desc))
      LibWGPU.render_pass_encoder_set_pipeline(pass, @shadow_pipeline)
      LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @shadow_pass_group, 0_u64, Pointer(UInt32).null)
      base = 0_u32
      groups.each do |(mesh, _mat, _b, _mrt, _nt, _et, _ot, insts)|
        count = insts.size.to_u32
        LibWGPU.render_pass_encoder_set_vertex_buffer(pass, 0_u32, mesh.vertex_buf, 0_u64, mesh.vertex_bytes)
        LibWGPU.render_pass_encoder_set_index_buffer(pass, mesh.index_buf, LibWGPU::IndexFormat::Uint32, 0_u64, mesh.index_bytes)
        LibWGPU.render_pass_encoder_draw_indexed(pass, mesh.index_count, count, 0_u32, 0, base)
        base += count
      end

      # GPU-skinned casters: skin the vertices into the same depth map (group0 = light_vp,
      # group1 = the mesh's joint matrices). Additive — no-op when the scene has none.
      skinned_bound = false
      world.query(GpuSkinnedMesh) do |_e, sk|
        s = sk.value
        unless skinned_bound
          LibWGPU.render_pass_encoder_set_pipeline(pass, @shadow_skinned_pipeline)
          LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @shadow_pass_group, 0_u64, Pointer(UInt32).null)
          skinned_bound = true
        end
        LibWGPU.render_pass_encoder_set_bind_group(pass, 1_u32, s.joint_group, 0_u64, Pointer(UInt32).null)
        LibWGPU.render_pass_encoder_set_vertex_buffer(pass, 0_u32, s.mesh.vertex_buf, 0_u64, s.mesh.vertex_bytes)
        LibWGPU.render_pass_encoder_set_vertex_buffer(pass, 1_u32, s.skin_buf, 0_u64, s.skin_bytes)
        LibWGPU.render_pass_encoder_set_index_buffer(pass, s.mesh.index_buf, LibWGPU::IndexFormat::Uint32, 0_u64, s.mesh.index_bytes)
        LibWGPU.render_pass_encoder_draw_indexed(pass, s.mesh.index_count, 1_u32, 0_u32, 0, 0_u32)
      end

      LibWGPU.render_pass_encoder_end(pass)
      cmd_desc = LibWGPU::CommandBufferDescriptor.new
      cmd_desc.label = WGPU.empty_string_view
      cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
      cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
      LibWGPU.queue_submit(@gpu.queue, 1_u64, cmds.to_unsafe)
      WGPU.release_pass(cmd, pass, encoder)
    end

    # Renders the world's meshes into an arbitrary target (surface or offscreen),
    # with its own depth buffer. Used by `render` and by readback tests.
    # Aspect ratio a camera renders at: its viewport (if any), else the full framebuffer.
    private def camera_aspect(cam : Camera3D, fb_w : UInt32, fb_h : UInt32) : Float32
      if vp = cam.viewport
        vp.height > 0 ? vp.width / vp.height : @gpu.aspect
      else
        fb_h > 0 ? fb_w.to_f32 / fb_h.to_f32 : @gpu.aspect
      end
    end

    # Renders into an offscreen `RenderTarget`, sizing the depth/MSAA/HDR attachments to it.
    def render_into(world : World, target : RenderTarget) : Nil
      render_into(world, target.view, target.width, target.height)
    end

    # `width`/`height` size the depth/MSAA/HDR attachments and the default aspect; they
    # default to the window framebuffer but must be passed the actual target size when
    # rendering into an offscreen `RenderTarget` that differs from the window (else the
    # depth/MSAA attachments mismatch the color target and wgpu rejects the pass).
    def render_into(world : World, target : LibWGPU::TextureView,
                    width : UInt32 = @gpu.width, height : UInt32 = @gpu.height, window : Int32 = 0) : Nil
      ensure_depth(width, height)

      # Every active Camera3D for this `window` (0 = primary), drawn in ascending `order`
      # (split-screen / overlays / minimaps). Stable ordering on ties: `sort_by!` is unstable,
      # so key on (order, spawn index) to keep the primary camera deterministic.
      cameras = [] of Camera3D
      world.query(Camera3D) do |_e, cam|
        cameras << cam.value if cam.value.active && cam.value.window == window
      end
      indexed = cameras.map_with_index { |c, idx| {c, idx} }
      indexed.sort_by! { |(c, idx)| {c.order, idx} }
      cameras = indexed.map { |(c, _idx)| c }
      cameras << Camera3D.new if cameras.empty?
      cam = cameras.first          # primary: drives culling + transparent sort
      single = cameras.size == 1
      vp = cam.view_projection(camera_aspect(cam, width, height))

      # Globals: time (a.x), IBL flag (a.y), camera position (b.xyz), ambient sky/ground.
      t = world.resource?(Time).try(&.elapsed.to_f32) || 0.0f32
      amb = world.resource?(AmbientLight) || AmbientLight.new
      ibl = world.resource?(IblEnvironment)
      ibl_group = ibl ? ibl.group : @default_ibl.group
      # Collect lights (Transform3D + Light) into the lights storage buffer. With none,
      # the shader keeps its legacy hard-coded directional light (count stays 0).
      light_count, shadow_index, shadow_dir = upload_lights(world)

      globals = StaticArray(Float32, 16).new(0.0f32)
      globals[0] = t
      globals[1] = ibl ? 1.0f32 : 0.0f32
      globals[2] = light_count.to_f32
      # a.w = shadow caster index + 1 (0 = none). Left 0 here and set after the shadow pass.
      globals[8] = amb.sky.r; globals[9] = amb.sky.g; globals[10] = amb.sky.b
      globals[12] = amb.ground.r; globals[13] = amb.ground.g; globals[14] = amb.ground.b

      # Group entities by (mesh, material) so identical bodies are drawn in ONE
      # instanced draw call. Model matrices are laid out grouped; each group's
      # instances index the storage buffer via first_instance (= @builtin(instance_index)).
      # Frustum culling (primary camera) drops off-screen instances — only with ONE camera,
      # since the buffers are shared across cameras and a second view may see the culled ones.
      frustum = Frustum.from(vp)
      # inst = {model, tint, metallic, roughness, emissive factor, alpha cutoff, uv-set bits}
      groups = [] of {Mesh, Material3D?, Texture, Texture, Texture, Texture, Texture, Array({Mat4, Color, Float32, Float32, Color, Float32, Float32})}
      slot = {} of Tuple(UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) => Int32
      # Transparent instances are NOT batched: they draw one at a time, back to front.
      # {mesh, base, mr, nrm, emissive tex, occlusion tex, model, tint, metallic, roughness,
      #  emissive factor, alpha cutoff, uv-set bits, camera distance}.
      transparent = [] of {Mesh, Texture, Texture, Texture, Texture, Texture, Mat4, Color, Float32, Float32, Color, Float32, Float32, Float32}
      total = 0
      culled = 0
      cpos = cam.position
      world.query(Transform3D, MeshRenderer) do |_e, tf, mrr|
        m = mrr.value
        mesh = m.mesh
        model = tf.value.matrix

        if @cull && single && m.cull && mesh.bounds_radius != Float32::MAX
          center = model.transform_point(mesh.bounds_center)
          s = model.scale_factors
          radius = mesh.bounds_radius * Math.max(s.x, Math.max(s.y, s.z))
          unless frustum.intersects_sphere?(center, radius)
            culled += 1
            next
          end
        end

        base = m.texture || @white
        mr_tex = m.metallic_roughness || @white
        nrm_tex = m.normal_map || @flat_normal
        em_tex = m.emissive || @white     # x emissive factor (default black -> no emission)
        occ_tex = m.occlusion || @white   # R channel (default white -> no occlusion)

        uvbits = m.tex_coords.to_f32
        uvbits += 256.0f32 if m.unlit # KHR_materials_unlit flag (bit 8), read by the PBR shader

        if m.transparent
          c = model.transform_point(mesh.bounds_center)
          d = (c.x - cpos.x)**2 + (c.y - cpos.y)**2 + (c.z - cpos.z)**2
          transparent << {mesh, base, mr_tex, nrm_tex, em_tex, occ_tex, model, m.tint,
                          m.metallic, m.roughness, m.emissive_factor, m.alpha_cutoff, uvbits, d}
          next
        end

        material = m.material
        inst = {model, m.tint, m.metallic, m.roughness, m.emissive_factor, m.alpha_cutoff, uvbits}
        key = {mesh.object_id, material ? material.object_id : 0_u64,
               base.object_id, mr_tex.object_id, nrm_tex.object_id, em_tex.object_id, occ_tex.object_id}
        if gi = slot[key]?
          groups[gi][7] << inst
        else
          slot[key] = groups.size
          groups << {mesh, material, base, mr_tex, nrm_tex, em_tex, occ_tex, [inst]}
        end
        total += 1
      end
      # Farthest first, so nearer translucent surfaces blend over the ones behind them.
      transparent.sort! { |a, b| b[13] <=> a[13] }
      @last_drawn = total + transparent.size
      @last_culled = culled

      # Even with nothing to draw (empty scene or everything culled) we still run the
      # pass below so the frame is cleared; only the buffer uploads are skipped.
      # While packing, accumulate a world-space AABB of the drawn geometry so the shadow
      # frustum can be fitted to it (only needed when a caster is present).
      bb_min = Vec3.new(Float32::MAX, Float32::MAX, Float32::MAX)
      bb_max = Vec3.new(-Float32::MAX, -Float32::MAX, -Float32::MAX)
      # Opaque instances fill model/param slots [0, total); the sorted transparent ones
      # follow at [total, total + transparent.size). Each transparent draw indexes its slot
      # via first_instance, exactly like an opaque group of size 1.
      slots = total + transparent.size
      if slots > 0
        ensure_capacity(slots)
        @scratch.clear
        @scratch_n.clear
        @scratch_p.clear
        pack = ->(model : Mat4, tint : Color, metallic : Float32, roughness : Float32, emissive : Color, cutoff : Float32, uvbits : Float32) do
          @scratch.concat(model.m)
          @scratch_n.concat(model.normal_matrix.m)
          @scratch_p.push(tint.r, tint.g, tint.b, tint.a, metallic, roughness, cutoff, uvbits,
            emissive.r, emissive.g, emissive.b, 0.0f32)
        end
        groups.each do |(mesh, _mat, _b, _mrt, _nt, _et, _ot, insts)|
          insts.each do |(model, tint, metallic, roughness, emissive, cutoff, uvbits)|
            pack.call(model, tint, metallic, roughness, emissive, cutoff, uvbits)
            if shadow_index >= 0
              c = model.transform_point(mesh.bounds_center)
              s = model.scale_factors
              r = (mesh.bounds_radius == Float32::MAX ? 1.0f32 : mesh.bounds_radius) *
                  Math.max(s.x, Math.max(s.y, s.z))
              bb_min = Vec3.new(Math.min(bb_min.x, c.x - r), Math.min(bb_min.y, c.y - r), Math.min(bb_min.z, c.z - r))
              bb_max = Vec3.new(Math.max(bb_max.x, c.x + r), Math.max(bb_max.y, c.y + r), Math.max(bb_max.z, c.z + r))
            end
          end
        end
        transparent.each do |(_mesh, _b, _mrt, _nt, _et, _ot, model, tint, metallic, roughness, emissive, cutoff, uvbits, _d)|
          pack.call(model, tint, metallic, roughness, emissive, cutoff, uvbits)
        end
        LibWGPU.queue_write_buffer(@gpu.queue, @model_buf, 0_u64,
          @scratch.to_unsafe.as(Void*), (@scratch.size * 4).to_u64)
        LibWGPU.queue_write_buffer(@gpu.queue, @normal_buf, 0_u64,
          @scratch_n.to_unsafe.as(Void*), (@scratch_n.size * 4).to_u64)
        LibWGPU.queue_write_buffer(@gpu.queue, @param_buf, 0_u64,
          @scratch_p.to_unsafe.as(Void*), (@scratch_p.size * 4).to_u64)
      end

      # Fold the GPU-skinned casters' world AABBs into the shadow bounds, so the light
      # frustum covers them too (they aren't in the rigid `groups`). Their bounds are kept
      # current by GpuSkinnedModel each frame (shared-by-reference SkinnedBounds).
      if shadow_index >= 0
        world.query(GpuSkinnedMesh) do |_e, sk|
          b = sk.value.bounds
          next unless b.valid?
          bb_min = Vec3.new(Math.min(bb_min.x, b.min.x), Math.min(bb_min.y, b.min.y), Math.min(bb_min.z, b.min.z))
          bb_max = Vec3.new(Math.max(bb_max.x, b.max.x), Math.max(bb_max.y, b.max.y), Math.max(bb_max.z, b.max.z))
        end
      end

      # Shadow pass: render the drawn instances from the caster's point of view into the
      # shadow map. Fit an orthographic light frustum to the scene AABB (rigid + skinned).
      # Runs before the main pass; the same @model_buf + group layout (base offsets) reused.
      # Gated on a valid AABB (not total>0): a skinned-only scene still casts shadows.
      shadow_on = shadow_index >= 0 && bb_max.x >= bb_min.x
      if shadow_on
        center = Vec3.new((bb_min.x + bb_max.x) * 0.5f32, (bb_min.y + bb_max.y) * 0.5f32, (bb_min.z + bb_max.z) * 0.5f32)
        ext = bb_max - center
        radius = Math.max(ext.x, Math.max(ext.y, ext.z))
        radius = 0.5f32 if radius < 1e-3f32
        up = shadow_dir.y.abs > 0.99f32 ? Vec3.new(0, 0, 1) : Vec3.new(0, 1, 0)
        eye = center - shadow_dir * (radius + 1.0f32)
        view = Mat4.look_at(eye, center, up)
        proj = Mat4.orthographic(-radius, radius, -radius, radius, 0.05, (2.0f32 * radius + 2.0f32))
        light_vp = proj * view
        LibWGPU.queue_write_buffer(@gpu.queue, @shadow_vp_buf, 0_u64, light_vp.m.to_unsafe.as(Void*), 64_u64)
        render_shadow_pass(groups, world)
        # The shadow map now holds this frame's depth: enable sampling for the caster
        # (globals.a.w = index + 1). Uploaded per camera below; skipped scenes keep 0.
        globals[3] = (shadow_index + 1).to_f32
      end

      # The scene's single-sample destination: the HDR target when tonemapping (the post
      # pass reads it and writes `target`), otherwise the frame target directly.
      scene_target = @tonemap.none? ? target : @hdr_view

      # One render pass per camera (each needs its own view-projection + globals, so a
      # separate encoder + submit — queue writes between passes of a single encoder don't
      # interleave). Camera 0 (lowest order) clears the whole frame; later cameras load and
      # draw into their viewport (split-screen / overlays). With MSAA, each pass resolves
      # the (cumulative) multisample target, so the last resolve is the full frame.
      cameras.each_with_index do |acam, ci|
        avp = acam.view_projection(camera_aspect(acam, width, height))
        LibWGPU.queue_write_buffer(@gpu.queue, @uniform_buf, 0_u64, avp.m.to_unsafe.as(Void*), 64_u64)
        globals[4] = acam.position.x; globals[5] = acam.position.y; globals[6] = acam.position.z
        LibWGPU.queue_write_buffer(@gpu.queue, @globals_buf, 0_u64, globals.to_unsafe.as(Void*), GLOBALS_BYTES.to_u64)

        color_att = LibWGPU::RenderPassColorAttachment.new
        if @sample_count > 1
          color_att.view = @msaa_view
          color_att.resolve_target = scene_target
        else
          color_att.view = scene_target
        end
        color_att.depth_slice = 0xFFFFFFFF_u32
        color_att.store_op = LibWGPU::StoreOp::Store
        if ci == 0
          color_att.load_op = LibWGPU::LoadOp::Clear
          cc = acam.clear_color || Color::BLACK
          color_att.clear_value = LibWGPU::Color.new(r: cc.r.to_f64, g: cc.g.to_f64, b: cc.b.to_f64, a: cc.a.to_f64)
        else
          color_att.load_op = LibWGPU::LoadOp::Load # keep earlier cameras' pixels
        end

        depth_att = LibWGPU::RenderPassDepthStencilAttachment.new
        depth_att.view = @depth_view
        depth_att.depth_load_op = LibWGPU::LoadOp::Clear
        depth_att.depth_store_op = LibWGPU::StoreOp::Store
        depth_att.depth_clear_value = 1.0f32

        pass_desc = LibWGPU::RenderPassDescriptor.new
        pass_desc.label = WGPU.empty_string_view
        pass_desc.color_attachment_count = 1_u64
        pass_desc.color_attachments = pointerof(color_att)
        pass_desc.depth_stencil_attachment = pointerof(depth_att)

        enc_desc = LibWGPU::CommandEncoderDescriptor.new
        enc_desc.label = WGPU.empty_string_view
        encoder = LibWGPU.device_create_command_encoder(@gpu.device, pointerof(enc_desc))
        pass = LibWGPU.command_encoder_begin_render_pass(encoder, pointerof(pass_desc))
        if r = acam.viewport
          LibWGPU.render_pass_encoder_set_viewport(pass, r.x, r.y, r.width, r.height, 0.0f32, 1.0f32)
          LibWGPU.render_pass_encoder_set_scissor_rect(pass, r.x.to_u32, r.y.to_u32, r.width.to_u32, r.height.to_u32)
        end

        # group0 (camera/models/globals) is shared by every material's pipeline
        # (same explicit layout), so it stays bound across pipeline switches.
        LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @group0, 0_u64, Pointer(UInt32).null)
        # group2 = IBL (rigid pipeline); default (unused) environment when none is set.
        LibWGPU.render_pass_encoder_set_bind_group(pass, 2_u32, ibl_group, 0_u64, Pointer(UInt32).null)
        # group3 = shadow map; the shader only samples it for the caster at globals.a.w.
        LibWGPU.render_pass_encoder_set_bind_group(pass, 3_u32, @shadow_group3, 0_u64, Pointer(UInt32).null)
        current = Pointer(Void).null.as(LibWGPU::RenderPipeline)

        base = 0_u32
        groups.each do |(mesh, material, base_tex, mr_tex, nrm_tex, em_tex, occ_tex, insts)|
          count = insts.size.to_u32
          pipeline = material ? material.pipeline : @pipeline
          if pipeline != current
            LibWGPU.render_pass_encoder_set_pipeline(pass, pipeline)
            current = pipeline
          end
          LibWGPU.render_pass_encoder_set_bind_group(pass, 1_u32, tex_group(base_tex, mr_tex, nrm_tex, em_tex, occ_tex), 0_u64, Pointer(UInt32).null)
          LibWGPU.render_pass_encoder_set_vertex_buffer(pass, 0_u32, mesh.vertex_buf, 0_u64, mesh.vertex_bytes)
          LibWGPU.render_pass_encoder_set_index_buffer(pass, mesh.index_buf, LibWGPU::IndexFormat::Uint32, 0_u64, mesh.index_bytes)
          LibWGPU.render_pass_encoder_draw_indexed(pass, mesh.index_count, count, 0_u32, 0, base)
          base += count
        end

        # GPU-skinned meshes (own pipeline + skin buffer + joint group). Additive.
        white_group = nil.as(LibWGPU::BindGroup?)
        world.query(GpuSkinnedMesh) do |_e, sk|
          s = sk.value
          white_group ||= tex_group(@white, @white, @flat_normal, @white, @white)
          LibWGPU.render_pass_encoder_set_pipeline(pass, @skinned_pipeline)
          LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @group0, 0_u64, Pointer(UInt32).null)
          LibWGPU.render_pass_encoder_set_bind_group(pass, 1_u32, white_group.not_nil!, 0_u64, Pointer(UInt32).null)
          LibWGPU.render_pass_encoder_set_bind_group(pass, 2_u32, s.joint_group, 0_u64, Pointer(UInt32).null)
          LibWGPU.render_pass_encoder_set_vertex_buffer(pass, 0_u32, s.mesh.vertex_buf, 0_u64, s.mesh.vertex_bytes)
          LibWGPU.render_pass_encoder_set_vertex_buffer(pass, 1_u32, s.skin_buf, 0_u64, s.skin_bytes)
          LibWGPU.render_pass_encoder_set_index_buffer(pass, s.mesh.index_buf, LibWGPU::IndexFormat::Uint32, 0_u64, s.mesh.index_bytes)
          LibWGPU.render_pass_encoder_draw_indexed(pass, s.mesh.index_count, 1_u32, 0_u32, 0, 0_u32)
        end

        # GPU morph meshes (own pipeline; deltas + weights + model in group2). Additive.
        world.query(GpuMorphMesh) do |_e, mm|
          g = mm.value
          white_group ||= tex_group(@white, @white, @flat_normal, @white, @white)
          LibWGPU.render_pass_encoder_set_pipeline(pass, @morph_pipeline)
          LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @group0, 0_u64, Pointer(UInt32).null)
          LibWGPU.render_pass_encoder_set_bind_group(pass, 1_u32, white_group.not_nil!, 0_u64, Pointer(UInt32).null)
          LibWGPU.render_pass_encoder_set_bind_group(pass, 2_u32, g.group, 0_u64, Pointer(UInt32).null)
          LibWGPU.render_pass_encoder_set_vertex_buffer(pass, 0_u32, g.mesh.vertex_buf, 0_u64, g.mesh.vertex_bytes)
          LibWGPU.render_pass_encoder_set_index_buffer(pass, g.mesh.index_buf, LibWGPU::IndexFormat::Uint32, 0_u64, g.mesh.index_bytes)
          LibWGPU.render_pass_encoder_draw_indexed(pass, g.mesh.index_count, 1_u32, 0_u32, 0, 0_u32)
        end

        # Transparent instances (back to front), blended pipeline. Restore group2/group3
        # (the skinned/morph pipelines above use an incompatible layout at index 2).
        unless transparent.empty?
          LibWGPU.render_pass_encoder_set_pipeline(pass, @transparent_pipeline)
          LibWGPU.render_pass_encoder_set_bind_group(pass, 2_u32, ibl_group, 0_u64, Pointer(UInt32).null)
          LibWGPU.render_pass_encoder_set_bind_group(pass, 3_u32, @shadow_group3, 0_u64, Pointer(UInt32).null)
          tslot = total.to_u32
          transparent.each do |(mesh, base_tex, mr_tex, nrm_tex, em_tex, occ_tex, _model, _tint, _m, _r, _ef, _c, _uv, _d)|
            LibWGPU.render_pass_encoder_set_bind_group(pass, 1_u32, tex_group(base_tex, mr_tex, nrm_tex, em_tex, occ_tex), 0_u64, Pointer(UInt32).null)
            LibWGPU.render_pass_encoder_set_vertex_buffer(pass, 0_u32, mesh.vertex_buf, 0_u64, mesh.vertex_bytes)
            LibWGPU.render_pass_encoder_set_index_buffer(pass, mesh.index_buf, LibWGPU::IndexFormat::Uint32, 0_u64, mesh.index_bytes)
            LibWGPU.render_pass_encoder_draw_indexed(pass, mesh.index_count, 1_u32, 0_u32, 0, tslot)
            tslot += 1
          end
        end

        LibWGPU.render_pass_encoder_end(pass)
        cmd_desc = LibWGPU::CommandBufferDescriptor.new
        cmd_desc.label = WGPU.empty_string_view
        cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
        cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
        LibWGPU.queue_submit(@gpu.queue, 1_u64, cmds.to_unsafe)
        WGPU.release_pass(cmd, pass, encoder)
      end

      # Post / output pass (once, whole frame): HDR scene target → `target`.
      unless @tonemap.none?
        if stack = world.resource?(PostStack)
          # Modular post stack (bloom, fxaa, vignette, …) then tonemap → surface. The
          # renderer's own @tonemap stays authoritative for the output pass.
          stack.run(@hdr_view, target, width, height, @scene_format, @tonemap)
        else
          # Built-in tonemap-only fullscreen pass (the original inline path).
          pcol = LibWGPU::RenderPassColorAttachment.new
          pcol.view = target
          pcol.depth_slice = 0xFFFFFFFF_u32
          pcol.load_op = LibWGPU::LoadOp::Clear
          pcol.store_op = LibWGPU::StoreOp::Store
          pcol.clear_value = LibWGPU::Color.new(r: 0.0, g: 0.0, b: 0.0, a: 1.0)
          pdesc = LibWGPU::RenderPassDescriptor.new
          pdesc.label = WGPU.empty_string_view
          pdesc.color_attachment_count = 1_u64
          pdesc.color_attachments = pointerof(pcol)
          penc_desc = LibWGPU::CommandEncoderDescriptor.new
          penc_desc.label = WGPU.empty_string_view
          pencoder = LibWGPU.device_create_command_encoder(@gpu.device, pointerof(penc_desc))
          post = LibWGPU.command_encoder_begin_render_pass(pencoder, pointerof(pdesc))
          LibWGPU.render_pass_encoder_set_pipeline(post, @post_pipeline)
          LibWGPU.render_pass_encoder_set_bind_group(post, 0_u32, @post_group, 0_u64, Pointer(UInt32).null)
          LibWGPU.render_pass_encoder_draw(post, 3_u32, 1_u32, 0_u32, 0_u32)
          LibWGPU.render_pass_encoder_end(post)
          pcmd_desc = LibWGPU::CommandBufferDescriptor.new
          pcmd_desc.label = WGPU.empty_string_view
          pcmd = LibWGPU.command_encoder_finish(pencoder, pointerof(pcmd_desc))
          pcmds = StaticArray(LibWGPU::CommandBuffer, 1).new(pcmd)
          LibWGPU.queue_submit(@gpu.queue, 1_u64, pcmds.to_unsafe)
          WGPU.release_pass(pcmd, post, pencoder)
        end
      end
    end
  end

  # Wires the 3D renderer: inserts Renderer3D at startup (from the GpuContext) and
  # runs it each frame in Schedule::Render. Use it INSTEAD of RenderPlugin (each
  # owns the whole frame): pair WindowPlugin + Render3DPlugin (+ Input/Audio) rather
  # than DefaultPlugins.
  class Render3DPlugin < Plugin
    # `sample_count` sets MSAA (4 = 4x by default; 1 disables it). `tonemap` enables the
    # HDR post-processing pass (None by default).
    def initialize(@sample_count : Int32 = 4, @tonemap : Tonemap = Tonemap::None)
    end

    def build(app : App) : Nil
      sc = @sample_count
      tm = @tonemap
      app.add_startup do |world, _cmd|
        world.insert_resource(Renderer3D.new(world.resource(GpuContext), sc, tm))
      end
      app.add_system(Schedule::Render) do |world, _cmd|
        world.resource?(Renderer3D).try &.render(world)
      end
    end
  end
end
