module Flock
  # 3D mesh renderer consuming Camera3D. Draws entities with (Transform3D, MeshRenderer)
  # using per-mesh vertex/index buffers, a shared view-projection uniform + a storage
  # buffer of model matrices (indexed by @builtin(instance_index)), a depth buffer for
  # correct occlusion, and simple directional lighting.
  #
  # Self-contained: `render(world)` acquires the surface, clears color + depth, and
  # presents. Use it in a Schedule::Render system (not together with RenderPlugin,
  # which owns the 2D frame).
  class Renderer3D < Resource
    MODEL_BYTES = 64 # mat4 (16 f32)

    WGSL = <<-SHADER
    struct Camera { view_proj : mat4x4<f32> };
    @group(0) @binding(0) var<uniform> cam : Camera;
    @group(0) @binding(1) var<storage, read> models : array<mat4x4<f32>>;

    struct VSOut {
      @builtin(position) clip : vec4<f32>,
      @location(0) normal : vec3<f32>,
      @location(1) color : vec3<f32>,
    };

    @vertex
    fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
               @location(2) col : vec3<f32>, @builtin(instance_index) ii : u32) -> VSOut {
      let model = models[ii];
      var out : VSOut;
      out.clip = cam.view_proj * model * vec4<f32>(pos, 1.0);
      out.normal = normalize((model * vec4<f32>(nrm, 0.0)).xyz);
      out.color = col;
      return out;
    }

    @fragment
    fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
      let light = normalize(vec3<f32>(0.4, 0.8, 0.6));
      let diff = max(dot(normalize(in.normal), light), 0.0);
      let shade = 0.25 + 0.75 * diff; // ambient + diffuse
      return vec4<f32>(in.color * shade, 1.0);
    }
    SHADER

    @model_capacity : Int32 = 64
    @scratch : Array(Float32) = [] of Float32
    @depth_w : UInt32 = 0
    @depth_h : UInt32 = 0

    @shader : LibWGPU::ShaderModule
    @pipeline : LibWGPU::RenderPipeline
    @group0_layout : LibWGPU::BindGroupLayout
    @uniform_buf : LibWGPU::Buffer
    @model_buf : LibWGPU::Buffer
    @group0 : LibWGPU::BindGroup
    @depth_tex : LibWGPU::Texture
    @depth_view : LibWGPU::TextureView

    def initialize(@gpu : GpuContext)
      code = WGPU.string_view(WGSL)
      src = LibWGPU::ShaderSourceWGSL.new
      src.chain.s_type = LibWGPU::SType::ShaderSourceWGSL
      src.code = code
      sdesc = LibWGPU::ShaderModuleDescriptor.new
      sdesc.label = WGPU.empty_string_view
      sdesc.next_in_chain = pointerof(src).as(Pointer(LibWGPU::ChainedStruct))
      @shader = LibWGPU.device_create_shader_module(@gpu.device, pointerof(sdesc))

      @pipeline = build_pipeline
      @group0_layout = LibWGPU.render_pipeline_get_bind_group_layout(@pipeline, 0_u32)

      @uniform_buf = make_buffer(64_u64, LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst)
      @model_buf = make_buffer((@model_capacity * MODEL_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      @group0 = build_group0

      # Depth texture (lazily sized to the surface on first render).
      @depth_tex = Pointer(Void).null.as(LibWGPU::Texture)
      @depth_view = Pointer(Void).null.as(LibWGPU::TextureView)
    end

    def release : Nil
      LibWGPU.texture_view_release(@depth_view) unless @depth_view.null?
      LibWGPU.texture_release(@depth_tex) unless @depth_tex.null?
      LibWGPU.bind_group_release(@group0)
      LibWGPU.buffer_release(@model_buf)
      LibWGPU.buffer_release(@uniform_buf)
      LibWGPU.bind_group_layout_release(@group0_layout)
      LibWGPU.render_pipeline_release(@pipeline)
      LibWGPU.shader_module_release(@shader)
    end

    private def make_buffer(size : UInt64, usage : LibWGPU::BufferUsage) : LibWGPU::Buffer
      d = LibWGPU::BufferDescriptor.new
      d.label = WGPU.empty_string_view
      d.usage = usage
      d.size = size
      d.mapped_at_creation = 0_u32
      LibWGPU.device_create_buffer(@gpu.device, pointerof(d))
    end

    private def build_pipeline : LibWGPU::RenderPipeline
      vs = WGPU.string_view("vs_main")
      fs = WGPU.string_view("fs_main")

      # Vertex layout: pos(loc0), normal(loc1), color(loc2), all Float32x3.
      a0 = LibWGPU::VertexAttribute.new; a0.format = LibWGPU::VertexFormat::Float32x3; a0.offset = 0_u64; a0.shader_location = 0_u32
      a1 = LibWGPU::VertexAttribute.new; a1.format = LibWGPU::VertexFormat::Float32x3; a1.offset = 12_u64; a1.shader_location = 1_u32
      a2 = LibWGPU::VertexAttribute.new; a2.format = LibWGPU::VertexFormat::Float32x3; a2.offset = 24_u64; a2.shader_location = 2_u32
      attrs = uninitialized LibWGPU::VertexAttribute[3]
      attrs[0] = a0; attrs[1] = a1; attrs[2] = a2

      vlayout = LibWGPU::VertexBufferLayout.new
      vlayout.step_mode = LibWGPU::VertexStepMode::Vertex
      vlayout.array_stride = Mesh::STRIDE
      vlayout.attribute_count = 3_u64
      vlayout.attributes = attrs.to_unsafe

      vertex = LibWGPU::VertexState.new
      vertex.module_ = @shader
      vertex.entry_point = vs
      vertex.buffer_count = 1_u64
      vertex.buffers = pointerof(vlayout)

      target = LibWGPU::ColorTargetState.new
      target.format = @gpu.format
      target.write_mask = LibWGPU::ColorWriteMask::All

      fragment = LibWGPU::FragmentState.new
      fragment.module_ = @shader
      fragment.entry_point = fs
      fragment.target_count = 1_u64
      fragment.targets = pointerof(target)

      primitive = LibWGPU::PrimitiveState.new
      primitive.topology = LibWGPU::PrimitiveTopology::TriangleList
      primitive.front_face = LibWGPU::FrontFace::CCW
      primitive.cull_mode = LibWGPU::CullMode::None

      # Depth test/write (Depth32Float). Stencil unused: default face state.
      face = LibWGPU::StencilFaceState.new
      face.compare = LibWGPU::CompareFunction::Always
      face.fail_op = LibWGPU::StencilOperation::Keep
      face.depth_fail_op = LibWGPU::StencilOperation::Keep
      face.pass_op = LibWGPU::StencilOperation::Keep
      depth = LibWGPU::DepthStencilState.new
      depth.format = LibWGPU::TextureFormat::Depth32Float
      depth.depth_write_enabled = LibWGPU::OptionalBool::True
      depth.depth_compare = LibWGPU::CompareFunction::Less
      depth.stencil_front = face
      depth.stencil_back = face

      multisample = LibWGPU::MultisampleState.new
      multisample.count = 1_u32
      multisample.mask = 0xFFFFFFFF_u32

      desc = LibWGPU::RenderPipelineDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.layout = WGPU.null(LibWGPU::PipelineLayout)
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
      LibWGPU.bind_group_release(@group0)
      @group0 = build_group0
    end

    private def ensure_depth(w : UInt32, h : UInt32) : Nil
      return if w == @depth_w && h == @depth_h && !@depth_view.null?
      LibWGPU.texture_view_release(@depth_view) unless @depth_view.null?
      LibWGPU.texture_release(@depth_tex) unless @depth_tex.null?

      desc = LibWGPU::TextureDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.usage = LibWGPU::TextureUsage::RenderAttachment
      desc.dimension = LibWGPU::TextureDimension::N2D
      desc.size = LibWGPU::Extent3D.new(width: w, height: h, depth_or_array_layers: 1_u32)
      desc.format = LibWGPU::TextureFormat::Depth32Float
      desc.mip_level_count = 1_u32
      desc.sample_count = 1_u32
      @depth_tex = LibWGPU.device_create_texture(@gpu.device, pointerof(desc))
      @depth_view = LibWGPU.texture_create_view(@depth_tex, Pointer(LibWGPU::TextureViewDescriptor).null)
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
        LibWGPU.texture_view_release(target)
        LibWGPU.texture_release(st.texture)
      when .outdated?, .lost?
        @gpu.reconfigure_to_window
      else
        # skip
      end
    end

    # Renders the world's meshes into an arbitrary target (surface or offscreen),
    # with its own depth buffer. Used by `render` and by readback tests.
    def render_into(world : World, target : LibWGPU::TextureView) : Nil
      ensure_depth(@gpu.width, @gpu.height)

      camera = nil.as(Camera3D?)
      world.query(Camera3D) { |_e, cam| camera = cam.value if cam.value.active }
      cam = camera || Camera3D.new
      vp = cam.view_projection(@gpu.aspect)
      LibWGPU.queue_write_buffer(@gpu.queue, @uniform_buf, 0_u64, vp.m.to_unsafe.as(Void*), 64_u64)

      meshes = [] of {Mesh, Mat4}
      world.query(Transform3D, MeshRenderer) do |_e, tf, mr|
        meshes << {mr.value.mesh, tf.value.matrix}
      end
      return if meshes.empty?
      ensure_capacity(meshes.size)

      @scratch.clear
      meshes.each { |(_m, model)| @scratch.concat(model.m) }
      LibWGPU.queue_write_buffer(@gpu.queue, @model_buf, 0_u64,
        @scratch.to_unsafe.as(Void*), (@scratch.size * 4).to_u64)

      color_att = LibWGPU::RenderPassColorAttachment.new
      color_att.view = target
      color_att.depth_slice = 0xFFFFFFFF_u32
      color_att.load_op = LibWGPU::LoadOp::Clear
      color_att.store_op = LibWGPU::StoreOp::Store
      cc = cam.clear_color || Color::BLACK
      color_att.clear_value = LibWGPU::Color.new(r: cc.r.to_f64, g: cc.g.to_f64, b: cc.b.to_f64, a: cc.a.to_f64)

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
      LibWGPU.render_pass_encoder_set_pipeline(pass, @pipeline)
      LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @group0, 0_u64, Pointer(UInt32).null)

      meshes.each_with_index do |(mesh, _model), i|
        LibWGPU.render_pass_encoder_set_vertex_buffer(pass, 0_u32, mesh.vertex_buf, 0_u64, mesh.vertex_bytes)
        LibWGPU.render_pass_encoder_set_index_buffer(pass, mesh.index_buf, LibWGPU::IndexFormat::Uint32, 0_u64, mesh.index_bytes)
        LibWGPU.render_pass_encoder_draw_indexed(pass, mesh.index_count, 1_u32, 0_u32, 0, i.to_u32)
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
