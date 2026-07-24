module Flock
  # A custom sprite material: a render pipeline (built from user WGSL by
  # `Renderer2D#build_material`) sharing the renderer's instancing convention and
  # pipeline layout. Assign to `Sprite#material` to draw that sprite with it.
  class SpriteMaterial
    @@next_id = 1 # 0 is reserved for the renderer's default material

    getter id : Int32
    getter pipeline : LibWGPU::RenderPipeline

    def initialize(@pipeline : LibWGPU::RenderPipeline, @shader : LibWGPU::ShaderModule)
      @id = @@next_id
      @@next_id += 1
    end

    def release : Nil
      LibWGPU.render_pipeline_release(@pipeline)
      LibWGPU.shader_module_release(@shader)
    end
  end

  # 2D renderer: instanced textured quads. All geometry (unit quad) lives in the
  # shader (const arrays indexed by vertex_index); per frame we only rewrite the
  # instance storage buffer + the view-projection uniform. One draw calls
  # `draw(6, count, 0, first_instance)` per texture batch.
  class Renderer2D < Resource
    FLOATS_PER_INSTANCE =  24 # mat4(16) + color(4) + uv(4)
    BYTES_PER_INSTANCE  =  96

    WGSL = <<-SHADER
    struct Instance {
      model : mat4x4<f32>,
      color : vec4<f32>,
      uv    : vec4<f32>,   // uv_min.xy, uv_size.zw
    };
    @group(0) @binding(0) var<uniform> u_vp : mat4x4<f32>;
    @group(0) @binding(1) var<storage, read> instances : array<Instance>;
    @group(1) @binding(0) var tex : texture_2d<f32>;
    @group(1) @binding(1) var samp : sampler;

    const QUAD = array<vec2<f32>, 6>(
      vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, -0.5), vec2<f32>(0.5, 0.5),
      vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, 0.5), vec2<f32>(-0.5, 0.5)
    );
    const QUV = array<vec2<f32>, 6>(
      vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 1.0), vec2<f32>(1.0, 0.0),
      vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 0.0)
    );

    struct VSOut {
      @builtin(position) pos : vec4<f32>,
      @location(0) uv : vec2<f32>,
      @location(1) color : vec4<f32>,
    };

    @vertex
    fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> VSOut {
      let inst = instances[ii];
      var out : VSOut;
      out.pos = u_vp * inst.model * vec4<f32>(QUAD[vi], 0.0, 1.0);
      out.uv = inst.uv.xy + QUV[vi] * inst.uv.zw;
      out.color = inst.color;
      return out;
    }

    @fragment
    fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
      return textureSample(tex, samp, in.uv) * in.color;
    }
    SHADER

    # Fills the scissored region with a uniform color (per-viewport clear). No blend.
    CLEAR_WGSL = <<-SHADER
    @group(0) @binding(0) var<uniform> u_color : vec4<f32>;
    const TRI = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
    @vertex
    fn vs_main(@builtin(vertex_index) vi : u32) -> @builtin(position) vec4<f32> {
      return vec4<f32>(TRI[vi], 0.0, 1.0);
    }
    @fragment
    fn fs_main() -> @location(0) vec4<f32> { return u_color; }
    SHADER

    @instance_capacity : Int32 = 256
    @scratch : Array(Float32) = [] of Float32
    @tex_groups : Hash(UInt64, LibWGPU::BindGroup) = {} of UInt64 => LibWGPU::BindGroup

    @shader : LibWGPU::ShaderModule
    @pipeline : LibWGPU::RenderPipeline
    @pipeline_layout : LibWGPU::PipelineLayout
    @group0_layout : LibWGPU::BindGroupLayout
    @group1_layout : LibWGPU::BindGroupLayout
    # GPU samplers cached by (filter, wrap), built on demand per texture.
    @samplers : Hash(Tuple(SamplerFilter, SamplerWrap), LibWGPU::Sampler) = {} of Tuple(SamplerFilter, SamplerWrap) => LibWGPU::Sampler
    @uniform_buf : LibWGPU::Buffer
    @instance_buf : LibWGPU::Buffer
    @group0 : LibWGPU::BindGroup
    # Custom per-sprite materials built via `build_material`, released on shutdown.
    @materials : Array(SpriteMaterial) = [] of SpriteMaterial
    # id -> custom material for backend-agnostic Sprite2D (see register_material).
    @material_by_id : Hash(Int32, SpriteMaterial) = {} of Int32 => SpriteMaterial
    # Texture bank for backend-agnostic `Sprite2D` (id -> Texture; id 0 = white).
    @texture_bank : Array(Texture) = [] of Texture
    # Per-viewport region-clear pipeline (fills the scissor rect with a color).
    @clear_shader : LibWGPU::ShaderModule
    @clear_pipeline : LibWGPU::RenderPipeline
    @clear_layout : LibWGPU::BindGroupLayout
    @clear_uniform : LibWGPU::Buffer
    @clear_group : LibWGPU::BindGroup

    # Offscreen scene target for the 2D post-processing path (allocated lazily when a
    # PostStack resource is present; same format as the surface → no pipeline rebuild).
    @scene_tex : LibWGPU::Texture = Pointer(Void).null.as(LibWGPU::Texture)
    @scene_view : LibWGPU::TextureView = Pointer(Void).null.as(LibWGPU::TextureView)
    @scene_w : UInt32 = 0_u32
    @scene_h : UInt32 = 0_u32

    # Statistics for the last frame (batching).
    getter last_sprites : Int32 = 0
    getter last_draw_calls : Int32 = 0

    getter white : Texture

    def initialize(@gpu : GpuContext)
      @shader = compile_shader(WGSL)
      # Explicit shared layouts so bind groups (uniform/storage/texture) and the
      # pipeline layout can be reused across every sprite material.
      @group0_layout = build_group0_layout
      @group1_layout = build_group1_layout
      @pipeline_layout = build_pipeline_layout
      @pipeline = build_pipeline(@shader)
      @white = Texture.white(@gpu)
      @texture_bank << @white # id 0 = solid white

      @uniform_buf = make_buffer(64_u64, LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst)
      @instance_buf = make_buffer((@instance_capacity * BYTES_PER_INSTANCE).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      @group0 = build_group0

      # Region-clear pipeline (auto layout, single color uniform).
      @clear_shader = compile_shader(CLEAR_WGSL)
      @clear_pipeline = build_clear_pipeline(@clear_shader)
      @clear_layout = LibWGPU.render_pipeline_get_bind_group_layout(@clear_pipeline, 0_u32)
      @clear_uniform = make_buffer(16_u64, LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst)
      @clear_group = build_clear_group
    end

    # Builds a sprite material from custom WGSL following the sprite convention
    # (group0 = uniform view-proj + instance storage; group1 = texture + sampler;
    # vs_main / fs_main; instances read via @builtin(instance_index)). Assign it to
    # `Sprite#material`. Shares the renderer's pipeline layout, uniform and instances.
    def build_material(wgsl : String) : SpriteMaterial
      mod = compile_shader(wgsl)
      material = SpriteMaterial.new(build_pipeline(mod), mod)
      @materials << material
      material
    end

    # Backend-agnostic `Sprite2D` material: builds a custom-WGSL material and returns an
    # integer id to store in `Sprite2D#material` (0 = default shader). Mirrors the web
    # backend's `Flock::Web.register_material`, so one game source can carry a custom
    # shader on both targets.
    def register_material(wgsl : String) : Int32
      m = build_material(wgsl)
      @material_by_id[m.id] = m
      m.id
    end

    # Registers one of Flock's built-in Sprite2D material shaders (see SpriteShaders,
    # e.g. `:glow`, `:ring`, `:disc`, `:vignette`) and returns its id.
    def register_builtin(name : Symbol) : Int32
      register_material(SpriteShaders.native(SpriteShaders.core(name)[0]))
    end

    # Registers a texture for backend-agnostic `Sprite2D` and returns its id. The
    # renderer takes ownership (released on shutdown). id 0 is the built-in white.
    def register_texture(texture : Texture) : Int32
      id = @texture_bank.size
      @texture_bank << texture
      id
    end

    private def compile_shader(wgsl : String) : LibWGPU::ShaderModule
      code = WGPU.string_view(wgsl)
      src = LibWGPU::ShaderSourceWGSL.new
      src.chain.s_type = LibWGPU::SType::ShaderSourceWGSL
      src.code = code
      sdesc = LibWGPU::ShaderModuleDescriptor.new
      sdesc.label = WGPU.empty_string_view
      sdesc.next_in_chain = pointerof(src).as(Pointer(LibWGPU::ChainedStruct))
      LibWGPU.device_create_shader_module(@gpu.device, pointerof(sdesc))
    end

    private def build_clear_pipeline(shader : LibWGPU::ShaderModule) : LibWGPU::RenderPipeline
      vs = WGPU.string_view("vs_main")
      fs = WGPU.string_view("fs_main")
      vertex = LibWGPU::VertexState.new
      vertex.module_ = shader
      vertex.entry_point = vs
      target = LibWGPU::ColorTargetState.new
      target.format = @gpu.format
      target.write_mask = LibWGPU::ColorWriteMask::All # opaque overwrite (no blend)
      fragment = LibWGPU::FragmentState.new
      fragment.module_ = shader
      fragment.entry_point = fs
      fragment.target_count = 1_u64
      fragment.targets = pointerof(target)
      primitive = LibWGPU::PrimitiveState.new
      primitive.topology = LibWGPU::PrimitiveTopology::TriangleList
      primitive.front_face = LibWGPU::FrontFace::CCW
      primitive.cull_mode = LibWGPU::CullMode::None
      multisample = LibWGPU::MultisampleState.new
      multisample.count = 1_u32
      multisample.mask = 0xFFFFFFFF_u32
      desc = LibWGPU::RenderPipelineDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.layout = WGPU.null(LibWGPU::PipelineLayout)
      desc.vertex = vertex
      desc.primitive = primitive
      desc.multisample = multisample
      desc.fragment = pointerof(fragment)
      LibWGPU.device_create_render_pipeline(@gpu.device, pointerof(desc))
    end

    private def build_clear_group : LibWGPU::BindGroup
      e = LibWGPU::BindGroupEntry.new
      e.binding = 0_u32
      e.buffer = @clear_uniform
      e.offset = 0_u64
      e.size = 16_u64
      d = LibWGPU::BindGroupDescriptor.new
      d.label = WGPU.empty_string_view
      d.layout = @clear_layout
      d.entry_count = 1_u64
      d.entries = pointerof(e)
      LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
    end

    # Fills the current scissor region with `color` (opaque). Scissor/viewport must
    # be set by the caller beforehand.
    private def fill_region(pass : LibWGPU::RenderPassEncoder, color : Color) : Nil
      data = [color.r, color.g, color.b, color.a]
      LibWGPU.queue_write_buffer(@gpu.queue, @clear_uniform, 0_u64, data.to_unsafe.as(Void*), 16_u64)
      LibWGPU.render_pass_encoder_set_pipeline(pass, @clear_pipeline)
      LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @clear_group, 0_u64, Pointer(UInt32).null)
      LibWGPU.render_pass_encoder_draw(pass, 3_u32, 1_u32, 0_u32, 0_u32)
    end

    # Frees all GPU handles (pipeline, buffers, bind groups, sampler, textures).
    def release : Nil
      @tex_groups.each_value { |bg| LibWGPU.bind_group_release(bg) }
      @tex_groups.clear
      LibWGPU.bind_group_release(@group0)
      LibWGPU.buffer_release(@instance_buf)
      LibWGPU.buffer_release(@uniform_buf)
      @samplers.each_value { |s| LibWGPU.sampler_release(s) }
      @samplers.clear
      @materials.each &.release
      @materials.clear
      @texture_bank[1..].each &.release # id 0 = @white, released below
      @texture_bank.clear
      LibWGPU.bind_group_release(@clear_group)
      LibWGPU.buffer_release(@clear_uniform)
      LibWGPU.bind_group_layout_release(@clear_layout)
      LibWGPU.render_pipeline_release(@clear_pipeline)
      LibWGPU.shader_module_release(@clear_shader)
      LibWGPU.render_pipeline_release(@pipeline)
      LibWGPU.pipeline_layout_release(@pipeline_layout)
      LibWGPU.bind_group_layout_release(@group0_layout)
      LibWGPU.bind_group_layout_release(@group1_layout)
      LibWGPU.shader_module_release(@shader)
      @white.release
      unless @scene_view.null?
        LibWGPU.texture_view_release(@scene_view)
        LibWGPU.texture_release(@scene_tex)
      end
    end

    # Converts a world-space clip rect to a framebuffer scissor rect (x, y, w, h in px), via
    # the camera's view-projection. Returns nil when the rect is empty (fully clipped).
    private def clip_scissor(vp : Mat4, clip : ClipRect, vw : Float32, vh : Float32,
                             viewport : Viewport?) : Tuple(UInt32, UInt32, UInt32, UInt32)?
      ox = viewport.try(&.x) || 0.0f32
      oy = viewport.try(&.y) || 0.0f32
      to_px = ->(wx : Float32, wy : Float32) do
        n = vp.transform_point(Vec3.new(wx, wy, 0.0f32))
        {ox + (n.x * 0.5f32 + 0.5f32) * vw, oy + (1.0f32 - (n.y * 0.5f32 + 0.5f32)) * vh}
      end
      p0 = to_px.call(clip.min.x, clip.min.y)
      p1 = to_px.call(clip.max.x, clip.max.y)
      x0 = Math.min(p0[0], p1[0]); x1 = Math.max(p0[0], p1[0])
      y0 = Math.min(p0[1], p1[1]); y1 = Math.max(p0[1], p1[1])
      vx0 = ox; vy0 = oy; vx1 = ox + vw; vy1 = oy + vh
      x0 = x0.clamp(vx0, vx1); x1 = x1.clamp(vx0, vx1)
      y0 = y0.clamp(vy0, vy1); y1 = y1.clamp(vy0, vy1)
      w = x1 - x0; h = y1 - y0
      return nil if w <= 0.5f32 || h <= 0.5f32
      {x0.to_u32, y0.to_u32, w.to_u32, h.to_u32}
    end

    # (Re)allocates the offscreen scene target for the 2D post path when the size changes.
    private def ensure_scene_target(w : UInt32, h : UInt32) : Nil
      return if @scene_w == w && @scene_h == h && !@scene_view.null?
      unless @scene_view.null?
        LibWGPU.texture_view_release(@scene_view)
        LibWGPU.texture_release(@scene_tex)
      end
      d = LibWGPU::TextureDescriptor.new
      d.label = WGPU.empty_string_view
      d.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::TextureBinding
      d.dimension = LibWGPU::TextureDimension::N2D
      d.size = LibWGPU::Extent3D.new(width: w, height: h, depth_or_array_layers: 1_u32)
      d.format = @gpu.format
      d.mip_level_count = 1_u32
      d.sample_count = 1_u32
      @scene_tex = LibWGPU.device_create_texture(@gpu.device, pointerof(d))
      @scene_view = LibWGPU.texture_create_view(@scene_tex, Pointer(LibWGPU::TextureViewDescriptor).null)
      @scene_w = w; @scene_h = h
    end

    private def make_buffer(size : UInt64, usage : LibWGPU::BufferUsage) : LibWGPU::Buffer
      desc = LibWGPU::BufferDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.usage = usage
      desc.size = size
      desc.mapped_at_creation = 0_u32
      LibWGPU.device_create_buffer(@gpu.device, pointerof(desc))
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
      d.address_mode_u = addr
      d.address_mode_v = addr
      d.address_mode_w = addr
      d.mag_filter = fmode
      d.min_filter = fmode
      d.mipmap_filter = mmode
      d.lod_min_clamp = 0.0f32
      # Allow the whole mip chain when a texture has one (single-mip textures still sample
      # level 0). Textures loaded via Texture.load are mipmapped by default.
      d.lod_max_clamp = 32.0f32
      d.max_anisotropy = 1_u16
      LibWGPU.device_create_sampler(@gpu.device, pointerof(d))
    end

    # group0: uniform view-projection (binding 0) + read-only instance storage
    # (binding 1), both visible to the vertex stage.
    private def build_group0_layout : LibWGPU::BindGroupLayout
      ubuf = LibWGPU::BufferBindingLayout.new
      ubuf.type_ = LibWGPU::BufferBindingType::Uniform
      e0 = LibWGPU::BindGroupLayoutEntry.new
      e0.binding = 0_u32
      e0.visibility = LibWGPU::ShaderStage::Vertex
      e0.buffer = ubuf

      sbuf = LibWGPU::BufferBindingLayout.new
      sbuf.type_ = LibWGPU::BufferBindingType::ReadOnlyStorage
      e1 = LibWGPU::BindGroupLayoutEntry.new
      e1.binding = 1_u32
      e1.visibility = LibWGPU::ShaderStage::Vertex
      e1.buffer = sbuf

      entries = uninitialized LibWGPU::BindGroupLayoutEntry[2]
      entries[0] = e0
      entries[1] = e1
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 2_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    # group1: texture (binding 0) + sampler (binding 1), visible to the fragment stage.
    private def build_group1_layout : LibWGPU::BindGroupLayout
      tex = LibWGPU::TextureBindingLayout.new
      tex.sample_type = LibWGPU::TextureSampleType::Float
      tex.view_dimension = LibWGPU::TextureViewDimension::N2D
      e0 = LibWGPU::BindGroupLayoutEntry.new
      e0.binding = 0_u32
      e0.visibility = LibWGPU::ShaderStage::Fragment
      e0.texture = tex

      smp = LibWGPU::SamplerBindingLayout.new
      smp.type_ = LibWGPU::SamplerBindingType::Filtering
      e1 = LibWGPU::BindGroupLayoutEntry.new
      e1.binding = 1_u32
      e1.visibility = LibWGPU::ShaderStage::Fragment
      e1.sampler = smp

      entries = uninitialized LibWGPU::BindGroupLayoutEntry[2]
      entries[0] = e0
      entries[1] = e1
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 2_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    private def build_pipeline_layout : LibWGPU::PipelineLayout
      layouts = uninitialized LibWGPU::BindGroupLayout[2]
      layouts[0] = @group0_layout
      layouts[1] = @group1_layout
      d = LibWGPU::PipelineLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.bind_group_layout_count = 2_u64
      d.bind_group_layouts = layouts.to_unsafe
      LibWGPU.device_create_pipeline_layout(@gpu.device, pointerof(d))
    end

    private def build_pipeline(shader : LibWGPU::ShaderModule) : LibWGPU::RenderPipeline
      vs = WGPU.string_view("vs_main")
      fs = WGPU.string_view("fs_main")

      vertex = LibWGPU::VertexState.new
      vertex.module_ = shader
      vertex.entry_point = vs

      blend = LibWGPU::BlendState.new
      blend.color = LibWGPU::BlendComponent.new(
        operation: LibWGPU::BlendOperation::Add,
        src_factor: LibWGPU::BlendFactor::SrcAlpha,
        dst_factor: LibWGPU::BlendFactor::OneMinusSrcAlpha)
      blend.alpha = LibWGPU::BlendComponent.new(
        operation: LibWGPU::BlendOperation::Add,
        src_factor: LibWGPU::BlendFactor::One,
        dst_factor: LibWGPU::BlendFactor::OneMinusSrcAlpha)

      target = LibWGPU::ColorTargetState.new
      target.format = @gpu.format
      target.write_mask = LibWGPU::ColorWriteMask::All
      target.blend = pointerof(blend)

      fragment = LibWGPU::FragmentState.new
      fragment.module_ = shader
      fragment.entry_point = fs
      fragment.target_count = 1_u64
      fragment.targets = pointerof(target)

      primitive = LibWGPU::PrimitiveState.new
      primitive.topology = LibWGPU::PrimitiveTopology::TriangleList
      primitive.front_face = LibWGPU::FrontFace::CCW
      primitive.cull_mode = LibWGPU::CullMode::None

      multisample = LibWGPU::MultisampleState.new
      multisample.count = 1_u32
      multisample.mask = 0xFFFFFFFF_u32

      desc = LibWGPU::RenderPipelineDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.layout = @pipeline_layout # shared explicit layout (materials reuse it)
      desc.vertex = vertex
      desc.primitive = primitive
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
      e1.buffer = @instance_buf
      e1.offset = 0_u64
      e1.size = (@instance_capacity * BYTES_PER_INSTANCE).to_u64

      entries = uninitialized LibWGPU::BindGroupEntry[2]
      entries[0] = e0
      entries[1] = e1

      d = LibWGPU::BindGroupDescriptor.new
      d.label = WGPU.empty_string_view
      d.layout = @group0_layout
      d.entry_count = 2_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
    end

    private def tex_group(texture : Texture) : LibWGPU::BindGroup
      @tex_groups.fetch(texture.id) do
        e0 = LibWGPU::BindGroupEntry.new
        e0.binding = 0_u32
        e0.texture_view = texture.view
        e1 = LibWGPU::BindGroupEntry.new
        e1.binding = 1_u32
        e1.sampler = sampler_for(texture.filter, texture.wrap)

        entries = uninitialized LibWGPU::BindGroupEntry[2]
        entries[0] = e0
        entries[1] = e1

        d = LibWGPU::BindGroupDescriptor.new
        d.label = WGPU.empty_string_view
        d.layout = @group1_layout
        d.entry_count = 2_u64
        d.entries = entries.to_unsafe
        bg = LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
        @tex_groups[texture.id] = bg
        # Evict + free this bind group when the texture is released (dynamic-text friendly).
        id = texture.id
        texture.on_release { @tex_groups.delete(id).try { |g| LibWGPU.bind_group_release(g) } }
        bg
      end
    end

    private def ensure_capacity(n : Int32) : Nil
      return if n <= @instance_capacity
      cap = @instance_capacity
      while cap < n
        cap *= 2
      end
      @instance_capacity = cap
      LibWGPU.buffer_release(@instance_buf)
      @instance_buf = make_buffer((cap * BYTES_PER_INSTANCE).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      LibWGPU.bind_group_release(@group0)
      @group0 = build_group0
    end

    # Renders the frame to the window surface, handling acquisition statuses.
    def render(world : World) : Nil
      st = LibWGPU::SurfaceTexture.new
      LibWGPU.surface_get_current_texture(@gpu.surface, pointerof(st))

      case st.status
      when .success_optimal?, .success_suboptimal?
        # Suboptimal is still presentable; the surface will be reconfigured on the next resize.
        target = LibWGPU.texture_create_view(st.texture, Pointer(LibWGPU::TextureViewDescriptor).null)
        if post = world.resource?(PostStack)
          # 2D post-processing: render the scene into an offscreen color target, then run the
          # effect chain (bloom, etc.) into the swapchain. Same surface format → no pipeline
          # rebuild (LDR path). Lets a pure-2D game (sprites/glow/starfield) bloom.
          ensure_scene_target(@gpu.width, @gpu.height)
          render_into(@scene_view, @gpu.width, @gpu.height, world)
          post.run(@scene_view, target, @gpu.width, @gpu.height, @gpu.format, post.tonemap)
        else
          render_into(target, @gpu.width, @gpu.height, world)
        end
        LibWGPU.surface_present(@gpu.surface)
        WGPU.release_surface(target, st.texture)
      when .outdated?, .lost?
        # Surface outdated (resize) or lost (display change): reconfigure
        # to the current size and retry on the next frame.
        # Some backends still hand back a texture with a non-success status; release it.
        LibWGPU.texture_release(st.texture) unless st.texture.null?
        @gpu.reconfigure_to_window
      else
        # Timeout / Error / transient status (e.g. 1st frame): skip this frame.
        LibWGPU.texture_release(st.texture) unless st.texture.null?
      end
    end

    # Renders the world into an arbitrary target (surface OR offscreen texture). Separates
    # the rendering logic from surface acquisition → reusable for readback-based
    # rendering tests.
    # `load_previous` keeps whatever is already in `target` (LoadOp::Load) instead of
    # clearing — used to draw sprites/HUD ON TOP of a prior pass (e.g. the 3D scene),
    # so 2D and 3D can share one frame (see Render2D3DPlugin).
    def render_into(target : LibWGPU::TextureView, width : UInt32, height : UInt32, world : World,
                    load_previous : Bool = false) : Nil
      @last_draw_calls = 0
      cameras = [] of Camera2D
      world.query(Camera2D) { |_e, cam| cameras << cam.value if cam.value.active }
      cameras << Camera2D.new(clear_color: Color.new(0.05, 0.05, 0.08)) if cameras.empty?
      # Stable order on ties: `sort_by!` is unstable, so key on (order, spawn index) to keep
      # the primary (full-frame clear) camera deterministic when two share an `order`.
      cameras = cameras.map_with_index { |c, idx| {c, idx} }.sort_by! { |(c, idx)| {c.order, idx} }.map { |(c, _idx)| c }

      # Collect: (z, material_id, pipeline, texture, model, color, uv_min, uv_size, clip).
      sprites = [] of {Float32, Int32, LibWGPU::RenderPipeline, Texture, Mat4, Color, Vec2, Vec2, ClipRect?}
      world.query(Transform2D, Sprite) do |_e, tf, sp|
        texture = sp.value.texture || @white
        mat = sp.value.material
        mat_id = mat ? mat.id : 0                 # 0 = default material
        pipeline = mat ? mat.pipeline : @pipeline
        # The shader quad is unit [-0.5, 0.5]: apply the sprite's size.
        model = tf.value.matrix * Mat4.scale(Vec3.new(sp.value.size.x, sp.value.size.y, 1.0f32))
        sprites << {sp.value.z, mat_id, pipeline, texture, model, sp.value.color, sp.value.uv_min, sp.value.uv_size, nil.as(ClipRect?)}
      end

      # Backend-agnostic Sprite2D: texture is an id into the bank (0 = white). Lets the
      # same game source render on native + web.
      world.query(Transform2D, Sprite2D) do |_e, tf, sp|
        id = sp.value.texture
        texture = (0 <= id < @texture_bank.size) ? @texture_bank[id] : @white
        mid = sp.value.material
        mat = mid > 0 ? @material_by_id[mid]? : nil
        pipeline = mat ? mat.pipeline : @pipeline
        mat_id = mat ? mat.id : 0
        model = tf.value.matrix * Mat4.scale(Vec3.new(sp.value.size.x, sp.value.size.y, 1.0f32))
        sprites << {sp.value.z, mat_id, pipeline, texture, model, sp.value.color, sp.value.uv_min, sp.value.uv_size, sp.value.clip}
      end

      # SpriteBatch: expand one entity's quads into instances (all share texture+material, so
      # they collapse into a single instanced draw). No per-tile entities.
      world.query(Transform2D, SpriteBatch) do |_e, tf, sb|
        b = sb.value
        texture = (0 <= b.texture < @texture_bank.size) ? @texture_bank[b.texture] : @white
        mat = b.material > 0 ? @material_by_id[b.material]? : nil
        pipeline = mat ? mat.pipeline : @pipeline
        mat_id = mat ? mat.id : 0
        base = tf.value.matrix
        b.items.each do |it|
          model = base * Flock::Transform2D.at(it.pos.x, it.pos.y).matrix * Mat4.scale(Vec3.new(it.size.x, it.size.y, 1.0f32))
          sprites << {b.z, mat_id, pipeline, texture, model, it.color, it.uv_min, it.uv_size, nil.as(ClipRect?)}
        end
      end
      # Sort by layer (z), then material, then texture: correct layering + batching.
      sprites.sort_by! { |s| {s[0], s[1], s[3].view.address} }
      @last_sprites = sprites.size
      ensure_capacity(sprites.size) if sprites.size > 0

      # Fill the instance storage buffer (in sorted order).
      unless sprites.empty?
        @scratch.clear
        sprites.each do |(_z, _mid, _pipe, _tex, model, color, uv_min, uv_size, _clip)|
          @scratch.concat(model.m)
          @scratch.push(color.r, color.g, color.b, color.a)
          @scratch.push(uv_min.x, uv_min.y, uv_size.x, uv_size.y)
        end
        LibWGPU.queue_write_buffer(@gpu.queue, @instance_buf, 0_u64,
          @scratch.to_unsafe.as(Void*), (@scratch.size * 4).to_u64)
      end

      cameras.each_with_index do |cam, ci|
        # Project onto the camera's actual render target (its viewport, if any), not the
        # whole framebuffer — otherwise a sub-viewport squashes the world by its aspect.
        vw = cam.viewport.try(&.width) || width.to_f32
        vh = cam.viewport.try(&.height) || height.to_f32
        vp = cam.view_projection(vw, vh)
        LibWGPU.queue_write_buffer(@gpu.queue, @uniform_buf, 0_u64,
          vp.m.to_unsafe.as(Void*), 64_u64)

        color_att = LibWGPU::RenderPassColorAttachment.new
        color_att.view = target
        color_att.depth_slice = 0xFFFFFFFF_u32
        color_att.store_op = LibWGPU::StoreOp::Store
        # 1st camera defines the whole attachment (LoadOp::Clear): its own color if
        # fullscreen, else black. Later cameras load and only paint their region.
        # In overlay mode (load_previous) nothing is cleared — sprites draw on top.
        if ci == 0 && !load_previous
          base = cam.viewport ? Color::BLACK : (cam.clear_color || Color::BLACK)
          color_att.load_op = LibWGPU::LoadOp::Clear
          color_att.clear_value = LibWGPU::Color.new(r: base.r.to_f64, g: base.g.to_f64, b: base.b.to_f64, a: base.a.to_f64)
        else
          color_att.load_op = LibWGPU::LoadOp::Load
        end

        pass_desc = LibWGPU::RenderPassDescriptor.new
        pass_desc.label = WGPU.empty_string_view
        pass_desc.color_attachment_count = 1_u64
        pass_desc.color_attachments = pointerof(color_att)

        enc_desc = LibWGPU::CommandEncoderDescriptor.new
        enc_desc.label = WGPU.empty_string_view
        encoder = LibWGPU.device_create_command_encoder(@gpu.device, pointerof(enc_desc))
        pass = LibWGPU.command_encoder_begin_render_pass(encoder, pointerof(pass_desc))

        if vp_rect = cam.viewport
          LibWGPU.render_pass_encoder_set_viewport(pass, vp_rect.x, vp_rect.y, vp_rect.width, vp_rect.height, 0.0f32, 1.0f32)
          LibWGPU.render_pass_encoder_set_scissor_rect(pass, vp_rect.x.to_u32, vp_rect.y.to_u32, vp_rect.width.to_u32, vp_rect.height.to_u32)
        end

        # Per-region clear: paint this camera's viewport with its own color (the
        # fullscreen 1st camera is already handled by LoadOp::Clear above).
        if (cc = cam.clear_color) && (cam.viewport || ci != 0)
          fill_region(pass, cc)
        end

        unless sprites.empty?
          # One draw per contiguous run of the same (material, texture, clip), in sorted
          # layer order. group0 (uniform+instances) is shared via the explicit layout. A
          # per-sprite `clip` sets the scissor for its run (world rect → framebuffer px).
          full = cam.viewport
          i = 0
          while i < sprites.size
            mat_id = sprites[i][1]
            pipeline = sprites[i][2]
            tex = sprites[i][3]
            clip = sprites[i][8]
            j = i + 1
            while j < sprites.size && sprites[j][1] == mat_id &&
                  sprites[j][3].view.address == tex.view.address && sprites[j][8] == clip
              j += 1
            end

            # Scissor: the sprite's clip rect if any, else the camera viewport / full frame.
            if clip
              sc = clip_scissor(vp, clip, vw, vh, full)
              if sc.nil?
                i = j # fully clipped away — skip this run
                next
              end
              LibWGPU.render_pass_encoder_set_scissor_rect(pass, sc[0], sc[1], sc[2], sc[3])
            elsif fr = full
              LibWGPU.render_pass_encoder_set_scissor_rect(pass, fr.x.to_u32, fr.y.to_u32, fr.width.to_u32, fr.height.to_u32)
            else
              LibWGPU.render_pass_encoder_set_scissor_rect(pass, 0_u32, 0_u32, width, height)
            end

            LibWGPU.render_pass_encoder_set_pipeline(pass, pipeline)
            LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @group0, 0_u64, Pointer(UInt32).null)
            LibWGPU.render_pass_encoder_set_bind_group(pass, 1_u32, tex_group(tex), 0_u64, Pointer(UInt32).null)
            LibWGPU.render_pass_encoder_draw(pass, 6_u32, (j - i).to_u32, 0_u32, i.to_u32)
            @last_draw_calls += 1
            i = j
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
    end
  end
end
