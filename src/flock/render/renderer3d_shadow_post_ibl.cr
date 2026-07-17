module Flock
  # Renderer3D: shadow / post-processing / IBL pipeline + resource builders.
  class Renderer3D
    # group3 (main pass): light view-projection uniform + shadow depth map + comparison sampler.
    private def build_shadow_layout : LibWGPU::BindGroupLayout
      ub = LibWGPU::BufferBindingLayout.new
      ub.type_ = LibWGPU::BufferBindingType::Uniform
      e0 = LibWGPU::BindGroupLayoutEntry.new
      e0.binding = 0_u32; e0.visibility = LibWGPU::ShaderStage::Fragment; e0.buffer = ub

      tex = LibWGPU::TextureBindingLayout.new
      tex.sample_type = LibWGPU::TextureSampleType::Depth
      tex.view_dimension = LibWGPU::TextureViewDimension::N2D
      e1 = LibWGPU::BindGroupLayoutEntry.new
      e1.binding = 1_u32; e1.visibility = LibWGPU::ShaderStage::Fragment; e1.texture = tex

      smp = LibWGPU::SamplerBindingLayout.new
      smp.type_ = LibWGPU::SamplerBindingType::Comparison
      e2 = LibWGPU::BindGroupLayoutEntry.new
      e2.binding = 2_u32; e2.visibility = LibWGPU::ShaderStage::Fragment; e2.sampler = smp

      entries = uninitialized LibWGPU::BindGroupLayoutEntry[3]
      entries[0] = e0; entries[1] = e1; entries[2] = e2
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 3_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    # group0 for the depth-only shadow pass: light-vp uniform + model storage buffer.
    private def build_shadow_pass_layout : LibWGPU::BindGroupLayout
      ub = LibWGPU::BufferBindingLayout.new
      ub.type_ = LibWGPU::BufferBindingType::Uniform
      e0 = LibWGPU::BindGroupLayoutEntry.new
      e0.binding = 0_u32; e0.visibility = LibWGPU::ShaderStage::Vertex; e0.buffer = ub

      sb = LibWGPU::BufferBindingLayout.new
      sb.type_ = LibWGPU::BufferBindingType::ReadOnlyStorage
      e1 = LibWGPU::BindGroupLayoutEntry.new
      e1.binding = 1_u32; e1.visibility = LibWGPU::ShaderStage::Vertex; e1.buffer = sb

      entries = uninitialized LibWGPU::BindGroupLayoutEntry[2]
      entries[0] = e0; entries[1] = e1
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 2_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    private def build_shadow_pipeline_layout : LibWGPU::PipelineLayout
      layouts = uninitialized LibWGPU::BindGroupLayout[1]
      layouts[0] = @shadow_pass_layout
      d = LibWGPU::PipelineLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.bind_group_layout_count = 1_u64
      d.bind_group_layouts = layouts.to_unsafe
      LibWGPU.device_create_pipeline_layout(@gpu.device, pointerof(d))
    end

    # Depth-only pipeline (no fragment/color target) writing the shadow map.
    private def build_shadow_pipeline : LibWGPU::RenderPipeline
      vs = WGPU.string_view("vs_main")
      a0 = LibWGPU::VertexAttribute.new
      a0.format = LibWGPU::VertexFormat::Float32x3; a0.offset = 0_u64; a0.shader_location = 0_u32
      attrs = uninitialized LibWGPU::VertexAttribute[1]
      attrs[0] = a0
      vlayout = LibWGPU::VertexBufferLayout.new
      vlayout.step_mode = LibWGPU::VertexStepMode::Vertex
      vlayout.array_stride = Mesh::STRIDE
      vlayout.attribute_count = 1_u64
      vlayout.attributes = attrs.to_unsafe

      vertex = LibWGPU::VertexState.new
      vertex.module_ = @shadow_shader
      vertex.entry_point = vs
      vertex.buffer_count = 1_u64
      vertex.buffers = pointerof(vlayout)

      primitive = LibWGPU::PrimitiveState.new
      primitive.topology = LibWGPU::PrimitiveTopology::TriangleList
      primitive.front_face = LibWGPU::FrontFace::CCW
      primitive.cull_mode = LibWGPU::CullMode::None

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
      desc.layout = @shadow_pipeline_layout
      desc.vertex = vertex
      desc.primitive = primitive
      desc.depth_stencil = pointerof(depth)
      desc.multisample = multisample
      desc.fragment = Pointer(LibWGPU::FragmentState).null
      LibWGPU.device_create_render_pipeline(@gpu.device, pointerof(desc))
    end

    # Skinned depth-only pipeline for the shadow pass: base mesh (pos) in buffer 0, skin
    # (joints/weights) in buffer 1, joint matrices in group1. group0 = the shadow bind group
    # (light_vp). Depth-only, single-sample, no color target.
    private def build_shadow_skinned_pipeline : LibWGPU::RenderPipeline
      a0 = LibWGPU::VertexAttribute.new
      a0.format = LibWGPU::VertexFormat::Float32x3; a0.offset = 0_u64; a0.shader_location = 0_u32
      attrs0 = uninitialized LibWGPU::VertexAttribute[1]
      attrs0[0] = a0
      aj = LibWGPU::VertexAttribute.new
      aj.format = LibWGPU::VertexFormat::Uint32x4; aj.offset = 0_u64; aj.shader_location = 1_u32
      aw = LibWGPU::VertexAttribute.new
      aw.format = LibWGPU::VertexFormat::Float32x4; aw.offset = 16_u64; aw.shader_location = 2_u32
      attrs1 = uninitialized LibWGPU::VertexAttribute[2]
      attrs1[0] = aj; attrs1[1] = aw

      l0 = LibWGPU::VertexBufferLayout.new
      l0.step_mode = LibWGPU::VertexStepMode::Vertex; l0.array_stride = Mesh::STRIDE
      l0.attribute_count = 1_u64; l0.attributes = attrs0.to_unsafe
      l1 = LibWGPU::VertexBufferLayout.new
      l1.step_mode = LibWGPU::VertexStepMode::Vertex; l1.array_stride = 32_u64
      l1.attribute_count = 2_u64; l1.attributes = attrs1.to_unsafe
      layouts = uninitialized LibWGPU::VertexBufferLayout[2]
      layouts[0] = l0; layouts[1] = l1

      vertex = LibWGPU::VertexState.new
      vertex.module_ = @shadow_skinned_shader
      vertex.entry_point = WGPU.string_view("vs_main")
      vertex.buffer_count = 2_u64
      vertex.buffers = layouts.to_unsafe

      primitive = LibWGPU::PrimitiveState.new
      primitive.topology = LibWGPU::PrimitiveTopology::TriangleList
      primitive.front_face = LibWGPU::FrontFace::CCW
      primitive.cull_mode = LibWGPU::CullMode::None

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

      # group0 = shadow bind group (light_vp @0, models @1 unused), group1 = joint matrices.
      pl_layouts = uninitialized LibWGPU::BindGroupLayout[2]
      pl_layouts[0] = @shadow_pass_layout; pl_layouts[1] = @joint_layout
      pld = LibWGPU::PipelineLayoutDescriptor.new
      pld.label = WGPU.empty_string_view
      pld.bind_group_layout_count = 2_u64
      pld.bind_group_layouts = pl_layouts.to_unsafe
      pl = LibWGPU.device_create_pipeline_layout(@gpu.device, pointerof(pld))

      desc = LibWGPU::RenderPipelineDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.layout = pl
      desc.vertex = vertex
      desc.primitive = primitive
      desc.depth_stencil = pointerof(depth)
      desc.multisample = multisample
      desc.fragment = Pointer(LibWGPU::FragmentState).null
      pipe = LibWGPU.device_create_render_pipeline(@gpu.device, pointerof(desc))
      LibWGPU.pipeline_layout_release(pl)
      pipe
    end

    private def build_shadow_texture : Nil
      desc = LibWGPU::TextureDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::TextureBinding
      desc.dimension = LibWGPU::TextureDimension::N2D
      desc.size = LibWGPU::Extent3D.new(width: SHADOW_SIZE.to_u32, height: SHADOW_SIZE.to_u32, depth_or_array_layers: 1_u32)
      desc.format = LibWGPU::TextureFormat::Depth32Float
      desc.mip_level_count = 1_u32
      desc.sample_count = 1_u32
      @shadow_tex = LibWGPU.device_create_texture(@gpu.device, pointerof(desc))
      vd = LibWGPU::TextureViewDescriptor.new
      vd.label = WGPU.empty_string_view
      vd.format = LibWGPU::TextureFormat::Depth32Float
      vd.dimension = LibWGPU::TextureViewDimension::N2D
      vd.base_mip_level = 0_u32; vd.mip_level_count = 1_u32
      vd.base_array_layer = 0_u32; vd.array_layer_count = 1_u32
      vd.aspect = LibWGPU::TextureAspect::DepthOnly
      @shadow_view = LibWGPU.texture_create_view(@shadow_tex, pointerof(vd))
    end

    private def build_shadow_sampler : LibWGPU::Sampler
      d = LibWGPU::SamplerDescriptor.new
      d.label = WGPU.empty_string_view
      d.address_mode_u = LibWGPU::AddressMode::ClampToEdge
      d.address_mode_v = LibWGPU::AddressMode::ClampToEdge
      d.address_mode_w = LibWGPU::AddressMode::ClampToEdge
      d.mag_filter = LibWGPU::FilterMode::Linear
      d.min_filter = LibWGPU::FilterMode::Linear
      d.mipmap_filter = LibWGPU::MipmapFilterMode::Nearest
      d.lod_min_clamp = 0.0f32; d.lod_max_clamp = 1.0f32
      d.compare = LibWGPU::CompareFunction::LessEqual
      d.max_anisotropy = 1_u16
      LibWGPU.device_create_sampler(@gpu.device, pointerof(d))
    end

    private def build_shadow_group3 : LibWGPU::BindGroup
      e0 = LibWGPU::BindGroupEntry.new
      e0.binding = 0_u32; e0.buffer = @shadow_vp_buf; e0.offset = 0_u64; e0.size = 64_u64
      e1 = LibWGPU::BindGroupEntry.new
      e1.binding = 1_u32; e1.texture_view = @shadow_view
      e2 = LibWGPU::BindGroupEntry.new
      e2.binding = 2_u32; e2.sampler = @shadow_sampler
      entries = uninitialized LibWGPU::BindGroupEntry[3]
      entries[0] = e0; entries[1] = e1; entries[2] = e2
      d = LibWGPU::BindGroupDescriptor.new
      d.label = WGPU.empty_string_view
      d.layout = @shadow_layout
      d.entry_count = 3_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
    end

    private def build_shadow_pass_group : LibWGPU::BindGroup
      e0 = LibWGPU::BindGroupEntry.new
      e0.binding = 0_u32; e0.buffer = @shadow_vp_buf; e0.offset = 0_u64; e0.size = 64_u64
      e1 = LibWGPU::BindGroupEntry.new
      e1.binding = 1_u32; e1.buffer = @model_buf; e1.offset = 0_u64
      e1.size = (@model_capacity * MODEL_BYTES).to_u64
      entries = uninitialized LibWGPU::BindGroupEntry[2]
      entries[0] = e0; entries[1] = e1
      d = LibWGPU::BindGroupDescriptor.new
      d.label = WGPU.empty_string_view
      d.layout = @shadow_pass_layout
      d.entry_count = 2_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
    end

    # Post pass bind group layout: HDR scene texture + a filtering sampler.
    private def build_post_layout : LibWGPU::BindGroupLayout
      t = LibWGPU::TextureBindingLayout.new
      t.sample_type = LibWGPU::TextureSampleType::Float
      t.view_dimension = LibWGPU::TextureViewDimension::N2D
      e0 = LibWGPU::BindGroupLayoutEntry.new
      e0.binding = 0_u32; e0.visibility = LibWGPU::ShaderStage::Fragment; e0.texture = t
      smp = LibWGPU::SamplerBindingLayout.new
      smp.type_ = LibWGPU::SamplerBindingType::Filtering
      e1 = LibWGPU::BindGroupLayoutEntry.new
      e1.binding = 1_u32; e1.visibility = LibWGPU::ShaderStage::Fragment; e1.sampler = smp
      entries = uninitialized LibWGPU::BindGroupLayoutEntry[2]
      entries[0] = e0; entries[1] = e1
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 2_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    # Fullscreen tonemap pipeline: no vertex buffer, no depth, writes the frame format.
    private def build_post_pipeline : LibWGPU::RenderPipeline
      layouts = uninitialized LibWGPU::BindGroupLayout[1]
      layouts[0] = @post_layout
      pld = LibWGPU::PipelineLayoutDescriptor.new
      pld.label = WGPU.empty_string_view
      pld.bind_group_layout_count = 1_u64
      pld.bind_group_layouts = layouts.to_unsafe
      pl = LibWGPU.device_create_pipeline_layout(@gpu.device, pointerof(pld))

      vertex = LibWGPU::VertexState.new
      vertex.module_ = @post_shader
      vertex.entry_point = WGPU.string_view("vs_main")
      vertex.buffer_count = 0_u64

      target = LibWGPU::ColorTargetState.new
      target.format = @gpu.format
      target.write_mask = LibWGPU::ColorWriteMask::All
      fragment = LibWGPU::FragmentState.new
      fragment.module_ = @post_shader
      fragment.entry_point = WGPU.string_view("fs_main")
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
      desc.layout = pl
      desc.vertex = vertex
      desc.primitive = primitive
      desc.depth_stencil = Pointer(LibWGPU::DepthStencilState).null
      desc.multisample = multisample
      desc.fragment = pointerof(fragment)
      pipeline = LibWGPU.device_create_render_pipeline(@gpu.device, pointerof(desc))
      LibWGPU.pipeline_layout_release(pl)
      pipeline
    end

    private def build_post_group : LibWGPU::BindGroup
      e0 = LibWGPU::BindGroupEntry.new
      e0.binding = 0_u32; e0.texture_view = @hdr_view
      e1 = LibWGPU::BindGroupEntry.new
      e1.binding = 1_u32; e1.sampler = @post_sampler
      entries = uninitialized LibWGPU::BindGroupEntry[2]
      entries[0] = e0; entries[1] = e1
      d = LibWGPU::BindGroupDescriptor.new
      d.label = WGPU.empty_string_view
      d.layout = @post_layout
      d.entry_count = 2_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
    end

    # group2 (rigid pipeline): irradiance cube + prefiltered cube + BRDF LUT + sampler.
    private def build_ibl_layout : LibWGPU::BindGroupLayout
      cube = ->(binding : UInt32) do
        t = LibWGPU::TextureBindingLayout.new
        t.sample_type = LibWGPU::TextureSampleType::Float
        t.view_dimension = LibWGPU::TextureViewDimension::Cube
        e = LibWGPU::BindGroupLayoutEntry.new
        e.binding = binding; e.visibility = LibWGPU::ShaderStage::Fragment; e.texture = t
        e
      end
      lut = LibWGPU::TextureBindingLayout.new
      lut.sample_type = LibWGPU::TextureSampleType::Float
      lut.view_dimension = LibWGPU::TextureViewDimension::N2D
      e2 = LibWGPU::BindGroupLayoutEntry.new
      e2.binding = 2_u32; e2.visibility = LibWGPU::ShaderStage::Fragment; e2.texture = lut
      smp = LibWGPU::SamplerBindingLayout.new
      smp.type_ = LibWGPU::SamplerBindingType::Filtering
      e3 = LibWGPU::BindGroupLayoutEntry.new
      e3.binding = 3_u32; e3.visibility = LibWGPU::ShaderStage::Fragment; e3.sampler = smp

      entries = uninitialized LibWGPU::BindGroupLayoutEntry[4]
      entries[0] = cube.call(0_u32); entries[1] = cube.call(1_u32); entries[2] = e2; entries[3] = e3
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 4_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    # Builds an IBL environment (sky/horizon/ground gradient): CPU-precomputes the
    # irradiance + prefiltered-specular cubemaps and the BRDF LUT, uploads them, and
    # assembles the group2 bind group. Insert the result as an `IblEnvironment` resource.
    def build_ibl(sky : Color, horizon : Color, ground : Color) : IblEnvironment
      env = IblEnvironment.gen_env(sky, horizon, ground)
      irr = make_cube(IblEnvironment::IRR_SIZE, [IblEnvironment.gen_irradiance(env)])
      pref_mips = Array(Array(Bytes)).new(IblEnvironment::PREF_MIPS) do |m|
        size = IblEnvironment::PREF_SIZE >> m
        rough = m.to_f64 / (IblEnvironment::PREF_MIPS - 1)
        IblEnvironment.gen_prefilter(env, size, rough)
      end
      pref = make_cube(IblEnvironment::PREF_SIZE, pref_mips)
      brdf = make_2d(IblEnvironment::LUT_SIZE, IblEnvironment.gen_brdf_lut)
      sampler = build_sampler(SamplerFilter::Linear, SamplerWrap::Clamp)
      group = build_ibl_group(irr[1], pref[1], brdf[1], sampler)
      IblEnvironment.new(irr[0], irr[1], pref[0], pref[1], brdf[0], brdf[1], sampler, group)
    end

    private def build_ibl_default : IblEnvironment
      black = Bytes.new(4, 0_u8)
      faces = Array(Bytes).new(6) { black.dup }
      irr = make_cube(1, [faces])
      pref = make_cube(1, [Array(Bytes).new(6) { black.dup }])
      brdf = make_2d(1, black.dup)
      sampler = build_sampler(SamplerFilter::Linear, SamplerWrap::Clamp)
      group = build_ibl_group(irr[1], pref[1], brdf[1], sampler)
      IblEnvironment.new(irr[0], irr[1], pref[0], pref[1], brdf[0], brdf[1], sampler, group)
    end

    # Creates a cubemap (6 layers) from mip levels of face data (mips[m][face] = RGBA8).
    private def make_cube(base : Int32, mips : Array(Array(Bytes))) : {LibWGPU::Texture, LibWGPU::TextureView}
      desc = LibWGPU::TextureDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.usage = LibWGPU::TextureUsage::TextureBinding | LibWGPU::TextureUsage::CopyDst
      desc.dimension = LibWGPU::TextureDimension::N2D
      desc.size = LibWGPU::Extent3D.new(width: base.to_u32, height: base.to_u32, depth_or_array_layers: 6_u32)
      desc.format = LibWGPU::TextureFormat::RGBA8Unorm
      desc.mip_level_count = mips.size.to_u32
      desc.sample_count = 1_u32
      tex = LibWGPU.device_create_texture(@gpu.device, pointerof(desc))

      mips.each_with_index do |faces, m|
        size = (base >> m).to_u32
        faces.each_with_index do |data, f|
          dest = LibWGPU::TexelCopyTextureInfo.new
          dest.texture = tex
          dest.mip_level = m.to_u32
          dest.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: f.to_u32)
          dest.aspect = LibWGPU::TextureAspect::All
          layout = LibWGPU::TexelCopyBufferLayout.new
          layout.offset = 0_u64
          layout.bytes_per_row = size * 4_u32
          layout.rows_per_image = size
          ext = LibWGPU::Extent3D.new(width: size, height: size, depth_or_array_layers: 1_u32)
          LibWGPU.queue_write_texture(@gpu.queue, pointerof(dest),
            data.to_unsafe.as(Void*), data.size.to_u64, pointerof(layout), pointerof(ext))
        end
      end

      vd = LibWGPU::TextureViewDescriptor.new
      vd.label = WGPU.empty_string_view
      vd.format = LibWGPU::TextureFormat::RGBA8Unorm
      vd.dimension = LibWGPU::TextureViewDimension::Cube
      vd.base_mip_level = 0_u32
      vd.mip_level_count = mips.size.to_u32
      vd.base_array_layer = 0_u32
      vd.array_layer_count = 6_u32
      vd.aspect = LibWGPU::TextureAspect::All
      {tex, LibWGPU.texture_create_view(tex, pointerof(vd))}
    end

    private def make_2d(size : Int32, data : Bytes) : {LibWGPU::Texture, LibWGPU::TextureView}
      desc = LibWGPU::TextureDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.usage = LibWGPU::TextureUsage::TextureBinding | LibWGPU::TextureUsage::CopyDst
      desc.dimension = LibWGPU::TextureDimension::N2D
      desc.size = LibWGPU::Extent3D.new(width: size.to_u32, height: size.to_u32, depth_or_array_layers: 1_u32)
      desc.format = LibWGPU::TextureFormat::RGBA8Unorm
      desc.mip_level_count = 1_u32
      desc.sample_count = 1_u32
      tex = LibWGPU.device_create_texture(@gpu.device, pointerof(desc))
      dest = LibWGPU::TexelCopyTextureInfo.new
      dest.texture = tex; dest.mip_level = 0_u32
      dest.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32); dest.aspect = LibWGPU::TextureAspect::All
      layout = LibWGPU::TexelCopyBufferLayout.new
      layout.offset = 0_u64; layout.bytes_per_row = size.to_u32 * 4_u32; layout.rows_per_image = size.to_u32
      ext = LibWGPU::Extent3D.new(width: size.to_u32, height: size.to_u32, depth_or_array_layers: 1_u32)
      LibWGPU.queue_write_texture(@gpu.queue, pointerof(dest), data.to_unsafe.as(Void*), data.size.to_u64, pointerof(layout), pointerof(ext))
      {tex, LibWGPU.texture_create_view(tex, Pointer(LibWGPU::TextureViewDescriptor).null)}
    end

    private def build_ibl_group(irr : LibWGPU::TextureView, pref : LibWGPU::TextureView,
                                brdf : LibWGPU::TextureView, sampler : LibWGPU::Sampler) : LibWGPU::BindGroup
      e0 = LibWGPU::BindGroupEntry.new; e0.binding = 0_u32; e0.texture_view = irr
      e1 = LibWGPU::BindGroupEntry.new; e1.binding = 1_u32; e1.texture_view = pref
      e2 = LibWGPU::BindGroupEntry.new; e2.binding = 2_u32; e2.texture_view = brdf
      e3 = LibWGPU::BindGroupEntry.new; e3.binding = 3_u32; e3.sampler = sampler
      entries = uninitialized LibWGPU::BindGroupEntry[4]
      entries[0] = e0; entries[1] = e1; entries[2] = e2; entries[3] = e3
      d = LibWGPU::BindGroupDescriptor.new
      d.label = WGPU.empty_string_view
      d.layout = @ibl_layout
      d.entry_count = 4_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
    end
  end
end
