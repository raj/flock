module Flock
  # Full-screen "wgpu-style" material: a pipeline that draws a full-screen triangle
  # with the given Shader, plus a user uniform (up to 16 floats / 64 bytes). Ideal
  # for a procedural effect or a post-process.
  #
  # The shader must expose `vs_main` (generating the triangle from @builtin(vertex_index))
  # and `fs_main`, and — if it reads the uniform — `@group(0) @binding(0) var<uniform> u : ...`.
  #
  # The raw handles (`pipeline`, `bind_group`) are exposed to drive the pass
  # yourself if needed.
  class Material < Resource
    getter pipeline : LibWGPU::RenderPipeline
    getter bind_group : LibWGPU::BindGroup
    @uniform : LibWGPU::Buffer
    @layout : LibWGPU::BindGroupLayout
    @shader_module : LibWGPU::ShaderModule

    def initialize(@gpu : GpuContext, shader : Shader)
      @shader_module = shader.module
      @pipeline = build_pipeline(shader)
      @layout = LibWGPU.render_pipeline_get_bind_group_layout(@pipeline, 0_u32)

      d = LibWGPU::BufferDescriptor.new
      d.label = WGPU.empty_string_view
      d.usage = LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst
      d.size = 64_u64
      d.mapped_at_creation = 0_u32
      @uniform = LibWGPU.device_create_buffer(@gpu.device, pointerof(d))

      e = LibWGPU::BindGroupEntry.new
      e.binding = 0_u32
      e.buffer = @uniform
      e.offset = 0_u64
      e.size = 64_u64
      bd = LibWGPU::BindGroupDescriptor.new
      bd.label = WGPU.empty_string_view
      bd.layout = @layout
      bd.entry_count = 1_u64
      bd.entries = pointerof(e)
      @bind_group = LibWGPU.device_create_bind_group(@gpu.device, pointerof(bd))
    end

    def release : Nil
      LibWGPU.render_pipeline_release(@pipeline)
      LibWGPU.bind_group_release(@bind_group)
      LibWGPU.buffer_release(@uniform)
      LibWGPU.bind_group_layout_release(@layout)
      LibWGPU.shader_module_release(@shader_module)
    end

    # Writes the user parameters into the uniform (padded to 16 floats).
    def set_uniform(values : Array(Float32)) : Nil
      buf = values.dup
      while buf.size < 16
        buf << 0.0f32
      end
      LibWGPU.queue_write_buffer(@gpu.queue, @uniform, 0_u64, buf.to_unsafe.as(Void*), 64_u64)
    end

    # Renders a full-screen pass onto the surface (clears, draws, presents).
    def render(gpu : GpuContext = @gpu) : Nil
      st = LibWGPU::SurfaceTexture.new
      LibWGPU.surface_get_current_texture(gpu.surface, pointerof(st))
      return unless st.status.success_optimal? || st.status.success_suboptimal?
      target = LibWGPU.texture_create_view(st.texture, Pointer(LibWGPU::TextureViewDescriptor).null)

      color = LibWGPU::RenderPassColorAttachment.new
      color.view = target
      color.depth_slice = 0xFFFFFFFF_u32
      color.load_op = LibWGPU::LoadOp::Clear
      color.store_op = LibWGPU::StoreOp::Store
      color.clear_value = LibWGPU::Color.new(r: 0.0, g: 0.0, b: 0.0, a: 1.0)

      pass_desc = LibWGPU::RenderPassDescriptor.new
      pass_desc.label = WGPU.empty_string_view
      pass_desc.color_attachment_count = 1_u64
      pass_desc.color_attachments = pointerof(color)

      enc_desc = LibWGPU::CommandEncoderDescriptor.new
      enc_desc.label = WGPU.empty_string_view
      encoder = LibWGPU.device_create_command_encoder(gpu.device, pointerof(enc_desc))
      pass = LibWGPU.command_encoder_begin_render_pass(encoder, pointerof(pass_desc))
      LibWGPU.render_pass_encoder_set_pipeline(pass, @pipeline)
      LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @bind_group, 0_u64, Pointer(UInt32).null)
      LibWGPU.render_pass_encoder_draw(pass, 3_u32, 1_u32, 0_u32, 0_u32)
      LibWGPU.render_pass_encoder_end(pass)

      cmd_desc = LibWGPU::CommandBufferDescriptor.new
      cmd_desc.label = WGPU.empty_string_view
      cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
      cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
      LibWGPU.queue_submit(gpu.queue, 1_u64, cmds.to_unsafe)
      LibWGPU.surface_present(gpu.surface)

      WGPU.release_pass(cmd, pass, encoder)
      WGPU.release_surface(target, st.texture)
    end

    private def build_pipeline(shader : Shader) : LibWGPU::RenderPipeline
      vs = WGPU.string_view("vs_main")
      fs = WGPU.string_view("fs_main")

      vertex = LibWGPU::VertexState.new
      vertex.module_ = shader.module
      vertex.entry_point = vs

      target = LibWGPU::ColorTargetState.new
      target.format = @gpu.format
      target.write_mask = LibWGPU::ColorWriteMask::All

      fragment = LibWGPU::FragmentState.new
      fragment.module_ = shader.module
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
  end
end
