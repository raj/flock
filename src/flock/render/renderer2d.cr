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

    @instance_capacity : Int32 = 256
    @scratch : Array(Float32) = [] of Float32
    @tex_groups : Hash(UInt64, LibWGPU::BindGroup) = {} of UInt64 => LibWGPU::BindGroup

    @shader : LibWGPU::ShaderModule
    @pipeline : LibWGPU::RenderPipeline
    @pipeline_layout : LibWGPU::PipelineLayout
    @group0_layout : LibWGPU::BindGroupLayout
    @group1_layout : LibWGPU::BindGroupLayout
    @sampler : LibWGPU::Sampler
    @uniform_buf : LibWGPU::Buffer
    @instance_buf : LibWGPU::Buffer
    @group0 : LibWGPU::BindGroup
    # Custom per-sprite materials built via `build_material`, released on shutdown.
    @materials : Array(SpriteMaterial) = [] of SpriteMaterial

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
      @sampler = build_sampler
      @white = Texture.white(@gpu)

      @uniform_buf = make_buffer(64_u64, LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst)
      @instance_buf = make_buffer((@instance_capacity * BYTES_PER_INSTANCE).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      @group0 = build_group0
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

    # Frees all GPU handles (pipeline, buffers, bind groups, sampler, textures).
    def release : Nil
      @tex_groups.each_value { |bg| LibWGPU.bind_group_release(bg) }
      @tex_groups.clear
      LibWGPU.bind_group_release(@group0)
      LibWGPU.buffer_release(@instance_buf)
      LibWGPU.buffer_release(@uniform_buf)
      LibWGPU.sampler_release(@sampler)
      @materials.each &.release
      @materials.clear
      LibWGPU.render_pipeline_release(@pipeline)
      LibWGPU.pipeline_layout_release(@pipeline_layout)
      LibWGPU.bind_group_layout_release(@group0_layout)
      LibWGPU.bind_group_layout_release(@group1_layout)
      LibWGPU.shader_module_release(@shader)
      @white.release
    end

    private def make_buffer(size : UInt64, usage : LibWGPU::BufferUsage) : LibWGPU::Buffer
      desc = LibWGPU::BufferDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.usage = usage
      desc.size = size
      desc.mapped_at_creation = 0_u32
      LibWGPU.device_create_buffer(@gpu.device, pointerof(desc))
    end

    private def build_sampler : LibWGPU::Sampler
      d = LibWGPU::SamplerDescriptor.new
      d.label = WGPU.empty_string_view
      d.address_mode_u = LibWGPU::AddressMode::ClampToEdge
      d.address_mode_v = LibWGPU::AddressMode::ClampToEdge
      d.address_mode_w = LibWGPU::AddressMode::ClampToEdge
      d.mag_filter = LibWGPU::FilterMode::Nearest
      d.min_filter = LibWGPU::FilterMode::Nearest
      d.mipmap_filter = LibWGPU::MipmapFilterMode::Nearest
      d.lod_min_clamp = 0.0f32
      d.lod_max_clamp = 1.0f32
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
      @tex_groups.fetch(texture.view.address) do
        e0 = LibWGPU::BindGroupEntry.new
        e0.binding = 0_u32
        e0.texture_view = texture.view
        e1 = LibWGPU::BindGroupEntry.new
        e1.binding = 1_u32
        e1.sampler = @sampler

        entries = uninitialized LibWGPU::BindGroupEntry[2]
        entries[0] = e0
        entries[1] = e1

        d = LibWGPU::BindGroupDescriptor.new
        d.label = WGPU.empty_string_view
        d.layout = @group1_layout
        d.entry_count = 2_u64
        d.entries = entries.to_unsafe
        bg = LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
        @tex_groups[texture.view.address] = bg
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
        render_into(target, @gpu.width, @gpu.height, world)
        LibWGPU.surface_present(@gpu.surface)
        LibWGPU.texture_view_release(target)
        LibWGPU.texture_release(st.texture)
      when .outdated?, .lost?
        # Surface outdated (resize) or lost (display change): reconfigure
        # to the current size and retry on the next frame.
        @gpu.reconfigure_to_window
      else
        # Timeout / Error / transient status (e.g. 1st frame): skip this frame.
      end
    end

    # Renders the world into an arbitrary target (surface OR offscreen texture). Separates
    # the rendering logic from surface acquisition → reusable for readback-based
    # rendering tests.
    def render_into(target : LibWGPU::TextureView, width : UInt32, height : UInt32, world : World) : Nil
      @last_draw_calls = 0
      cameras = [] of Camera2D
      world.query(Camera2D) { |_e, cam| cameras << cam.value if cam.value.active }
      cameras << Camera2D.new(clear_color: Color.new(0.05, 0.05, 0.08)) if cameras.empty?
      cameras.sort_by!(&.order)

      # Collect: (z, material_id, pipeline, texture, model, color, uv_min, uv_size).
      sprites = [] of {Float32, Int32, LibWGPU::RenderPipeline, Texture, Mat4, Color, Vec2, Vec2}
      world.query(Transform2D, Sprite) do |_e, tf, sp|
        texture = sp.value.texture || @white
        mat = sp.value.material
        mat_id = mat ? mat.id : 0                 # 0 = default material
        pipeline = mat ? mat.pipeline : @pipeline
        # The shader quad is unit [-0.5, 0.5]: apply the sprite's size.
        model = tf.value.matrix * Mat4.scale(Vec3.new(sp.value.size.x, sp.value.size.y, 1.0f32))
        sprites << {sp.value.z, mat_id, pipeline, texture, model, sp.value.color, sp.value.uv_min, sp.value.uv_size}
      end
      # Sort by layer (z), then material, then texture: correct layering + batching.
      sprites.sort_by! { |s| {s[0], s[1], s[3].view.address} }
      @last_sprites = sprites.size
      ensure_capacity(sprites.size) if sprites.size > 0

      # Fill the instance storage buffer (in sorted order).
      unless sprites.empty?
        @scratch.clear
        sprites.each do |(_z, _mid, _pipe, _tex, model, color, uv_min, uv_size)|
          @scratch.concat(model.m)
          @scratch.push(color.r, color.g, color.b, color.a)
          @scratch.push(uv_min.x, uv_min.y, uv_size.x, uv_size.y)
        end
        LibWGPU.queue_write_buffer(@gpu.queue, @instance_buf, 0_u64,
          @scratch.to_unsafe.as(Void*), (@scratch.size * 4).to_u64)
      end

      cameras.each_with_index do |cam, ci|
        vp = cam.view_projection(width.to_f32, height.to_f32)
        LibWGPU.queue_write_buffer(@gpu.queue, @uniform_buf, 0_u64,
          vp.m.to_unsafe.as(Void*), 64_u64)

        color_att = LibWGPU::RenderPassColorAttachment.new
        color_att.view = target
        color_att.depth_slice = 0xFFFFFFFF_u32
        color_att.store_op = LibWGPU::StoreOp::Store
        # The 1st camera clears (background); the following ones overlay on top.
        if ci == 0
          cc = cam.clear_color || Color::BLACK
          color_att.load_op = LibWGPU::LoadOp::Clear
          color_att.clear_value = LibWGPU::Color.new(r: cc.r.to_f64, g: cc.g.to_f64, b: cc.b.to_f64, a: cc.a.to_f64)
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

        unless sprites.empty?
          # One draw per contiguous run of the same (material, texture), in sorted
          # layer order. group0 (uniform+instances) is shared via the explicit layout.
          i = 0
          while i < sprites.size
            mat_id = sprites[i][1]
            pipeline = sprites[i][2]
            tex = sprites[i][3]
            j = i + 1
            while j < sprites.size && sprites[j][1] == mat_id && sprites[j][3].view.address == tex.view.address
              j += 1
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

        LibWGPU.command_buffer_release(cmd)
        LibWGPU.render_pass_encoder_release(pass)
        LibWGPU.command_encoder_release(encoder)
      end
    end
  end
end
