module Flock
  # Renderer3D: GPU skinning + morph-target pipeline + resource builders.
  class Renderer3D
    # group2 for skinning: a read-only storage buffer of joint matrices (vertex stage).
    private def build_joint_layout : LibWGPU::BindGroupLayout
      jb = LibWGPU::BufferBindingLayout.new
      jb.type_ = LibWGPU::BufferBindingType::ReadOnlyStorage
      e0 = LibWGPU::BindGroupLayoutEntry.new
      e0.binding = 0_u32
      e0.visibility = LibWGPU::ShaderStage::Vertex
      e0.buffer = jb
      entries = uninitialized LibWGPU::BindGroupLayoutEntry[1]
      entries[0] = e0
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 1_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    private def build_skinned_pipeline(shader : LibWGPU::ShaderModule) : LibWGPU::RenderPipeline
      vs = WGPU.string_view("vs_main")
      fs = WGPU.string_view("fs_main")

      # Buffer 0: the bind-pose mesh (pos/normal/color/uv/uv1), same layout as the rigid path.
      a0 = LibWGPU::VertexAttribute.new; a0.format = LibWGPU::VertexFormat::Float32x3; a0.offset = 0_u64; a0.shader_location = 0_u32
      a1 = LibWGPU::VertexAttribute.new; a1.format = LibWGPU::VertexFormat::Float32x3; a1.offset = 12_u64; a1.shader_location = 1_u32
      a2 = LibWGPU::VertexAttribute.new; a2.format = LibWGPU::VertexFormat::Float32x3; a2.offset = 24_u64; a2.shader_location = 2_u32
      a3 = LibWGPU::VertexAttribute.new; a3.format = LibWGPU::VertexFormat::Float32x2; a3.offset = 36_u64; a3.shader_location = 3_u32
      a3b = LibWGPU::VertexAttribute.new; a3b.format = LibWGPU::VertexFormat::Float32x2; a3b.offset = 44_u64; a3b.shader_location = 4_u32
      attrs0 = uninitialized LibWGPU::VertexAttribute[5]
      attrs0[0] = a0; attrs0[1] = a1; attrs0[2] = a2; attrs0[3] = a3; attrs0[4] = a3b

      # Buffer 1: skin data — joints (Uint32x4, loc5) + weights (Float32x4, loc6), stride 32.
      a4 = LibWGPU::VertexAttribute.new; a4.format = LibWGPU::VertexFormat::Uint32x4; a4.offset = 0_u64; a4.shader_location = 5_u32
      a5 = LibWGPU::VertexAttribute.new; a5.format = LibWGPU::VertexFormat::Float32x4; a5.offset = 16_u64; a5.shader_location = 6_u32
      attrs1 = uninitialized LibWGPU::VertexAttribute[2]
      attrs1[0] = a4; attrs1[1] = a5

      # Configure each layout as a local, then copy into the array (indexing a
      # StaticArray of structs returns a copy, so `layouts[0].field = …` wouldn't stick).
      l0 = LibWGPU::VertexBufferLayout.new
      l0.step_mode = LibWGPU::VertexStepMode::Vertex
      l0.array_stride = Mesh::STRIDE
      l0.attribute_count = 5_u64
      l0.attributes = attrs0.to_unsafe
      l1 = LibWGPU::VertexBufferLayout.new
      l1.step_mode = LibWGPU::VertexStepMode::Vertex
      l1.array_stride = 32_u64
      l1.attribute_count = 2_u64
      l1.attributes = attrs1.to_unsafe
      layouts = uninitialized LibWGPU::VertexBufferLayout[2]
      layouts[0] = l0
      layouts[1] = l1

      vertex = LibWGPU::VertexState.new
      vertex.module_ = shader
      vertex.entry_point = vs
      vertex.buffer_count = 2_u64
      vertex.buffers = layouts.to_unsafe

      target = LibWGPU::ColorTargetState.new
      target.format = @scene_format
      target.write_mask = LibWGPU::ColorWriteMask::All
      fragment = LibWGPU::FragmentState.new
      fragment.module_ = shader
      fragment.entry_point = fs
      fragment.target_count = 1_u64
      fragment.targets = pointerof(target)

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
      multisample.count = @sample_count.to_u32
      multisample.mask = 0xFFFFFFFF_u32

      pl_layouts = uninitialized LibWGPU::BindGroupLayout[3]
      pl_layouts[0] = @group0_layout; pl_layouts[1] = @group1_layout; pl_layouts[2] = @joint_layout
      pld = LibWGPU::PipelineLayoutDescriptor.new
      pld.label = WGPU.empty_string_view
      pld.bind_group_layout_count = 3_u64
      pld.bind_group_layouts = pl_layouts.to_unsafe
      skinned_layout = LibWGPU.device_create_pipeline_layout(@gpu.device, pointerof(pld))

      desc = LibWGPU::RenderPipelineDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.layout = skinned_layout
      desc.vertex = vertex
      desc.primitive = primitive
      desc.depth_stencil = pointerof(depth)
      desc.multisample = multisample
      desc.fragment = pointerof(fragment)
      pipe = LibWGPU.device_create_render_pipeline(@gpu.device, pointerof(desc))
      LibWGPU.pipeline_layout_release(skinned_layout)
      pipe
    end

    # Builds a GPU-skinned mesh: reuses `mesh` for slot 0, uploads a skin vertex buffer
    # (joints u32x4 + weights f32x4 per vertex) and allocates a joint-matrix storage
    # buffer (+ its bind group). Feed `joints`/`weights` 4-per-vertex, in mesh order.
    def build_gpu_skin(mesh : Mesh, joints : Array(Int32), weights : Array(Float32),
                       joint_nodes : Array(Int32), inverse_binds : Array(Mat4), mesh_node : Int32 = 0) : GpuSkinnedMesh
      vcount = joints.size // 4
      skin = Array(UInt32).new(vcount * 8)
      vcount.times do |v|
        4.times { |i| skin << joints[v * 4 + i].to_u32 }
        4.times { |i| skin << weights[v * 4 + i].unsafe_as(UInt32) } # reinterpret f32 bits
      end
      skin_bytes = (skin.size * 4).to_u64
      skin_buf = make_buffer(skin_bytes, LibWGPU::BufferUsage::Vertex | LibWGPU::BufferUsage::CopyDst)
      LibWGPU.queue_write_buffer(@gpu.queue, skin_buf, 0_u64, skin.to_unsafe.as(Void*), skin_bytes)

      jcount = joint_nodes.size
      joint_buf = make_buffer((jcount * MODEL_BYTES).to_u64, LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      e0 = LibWGPU::BindGroupEntry.new
      e0.binding = 0_u32; e0.buffer = joint_buf; e0.offset = 0_u64; e0.size = (jcount * MODEL_BYTES).to_u64
      entries = uninitialized LibWGPU::BindGroupEntry[1]
      entries[0] = e0
      bgd = LibWGPU::BindGroupDescriptor.new
      bgd.label = WGPU.empty_string_view
      bgd.layout = @joint_layout
      bgd.entry_count = 1_u64
      bgd.entries = entries.to_unsafe
      joint_group = LibWGPU.device_create_bind_group(@gpu.device, pointerof(bgd))

      GpuSkinnedMesh.new(mesh, skin_buf, skin_bytes, joint_buf, joint_group, jcount, joint_nodes, inverse_binds, mesh_node)
    end

    # group2 for GPU morphing: deltas storage + weights storage (vertex) + model uniform.
    private def build_morph_layout : LibWGPU::BindGroupLayout
      sb = LibWGPU::BufferBindingLayout.new
      sb.type_ = LibWGPU::BufferBindingType::ReadOnlyStorage
      e0 = LibWGPU::BindGroupLayoutEntry.new
      e0.binding = 0_u32; e0.visibility = LibWGPU::ShaderStage::Vertex; e0.buffer = sb
      e1 = LibWGPU::BindGroupLayoutEntry.new
      e1.binding = 1_u32; e1.visibility = LibWGPU::ShaderStage::Vertex; e1.buffer = sb
      ub = LibWGPU::BufferBindingLayout.new
      ub.type_ = LibWGPU::BufferBindingType::Uniform
      e2 = LibWGPU::BindGroupLayoutEntry.new
      e2.binding = 2_u32; e2.visibility = LibWGPU::ShaderStage::Vertex; e2.buffer = ub
      entries = uninitialized LibWGPU::BindGroupLayoutEntry[3]
      entries[0] = e0; entries[1] = e1; entries[2] = e2
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 3_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    # Morph pipeline: single base vertex buffer (pos/normal/color/uv), group0 + group1 +
    # morph group2. Deltas are fetched in the vertex shader by @builtin(vertex_index).
    private def build_morph_pipeline(shader : LibWGPU::ShaderModule) : LibWGPU::RenderPipeline
      a0 = LibWGPU::VertexAttribute.new; a0.format = LibWGPU::VertexFormat::Float32x3; a0.offset = 0_u64; a0.shader_location = 0_u32
      a1 = LibWGPU::VertexAttribute.new; a1.format = LibWGPU::VertexFormat::Float32x3; a1.offset = 12_u64; a1.shader_location = 1_u32
      a2 = LibWGPU::VertexAttribute.new; a2.format = LibWGPU::VertexFormat::Float32x3; a2.offset = 24_u64; a2.shader_location = 2_u32
      a3 = LibWGPU::VertexAttribute.new; a3.format = LibWGPU::VertexFormat::Float32x2; a3.offset = 36_u64; a3.shader_location = 3_u32
      attrs = uninitialized LibWGPU::VertexAttribute[4]
      attrs[0] = a0; attrs[1] = a1; attrs[2] = a2; attrs[3] = a3
      vlayout = LibWGPU::VertexBufferLayout.new
      vlayout.step_mode = LibWGPU::VertexStepMode::Vertex
      vlayout.array_stride = Mesh::STRIDE
      vlayout.attribute_count = 4_u64
      vlayout.attributes = attrs.to_unsafe

      vertex = LibWGPU::VertexState.new
      vertex.module_ = shader
      vertex.entry_point = WGPU.string_view("vs_main")
      vertex.buffer_count = 1_u64
      vertex.buffers = pointerof(vlayout)

      target = LibWGPU::ColorTargetState.new
      target.format = @scene_format
      target.write_mask = LibWGPU::ColorWriteMask::All
      fragment = LibWGPU::FragmentState.new
      fragment.module_ = shader
      fragment.entry_point = WGPU.string_view("fs_main")
      fragment.target_count = 1_u64
      fragment.targets = pointerof(target)

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
      multisample.count = @sample_count.to_u32
      multisample.mask = 0xFFFFFFFF_u32

      pl_layouts = uninitialized LibWGPU::BindGroupLayout[3]
      pl_layouts[0] = @group0_layout; pl_layouts[1] = @group1_layout; pl_layouts[2] = @morph_layout
      pld = LibWGPU::PipelineLayoutDescriptor.new
      pld.label = WGPU.empty_string_view
      pld.bind_group_layout_count = 3_u64
      pld.bind_group_layouts = pl_layouts.to_unsafe
      ml = LibWGPU.device_create_pipeline_layout(@gpu.device, pointerof(pld))

      desc = LibWGPU::RenderPipelineDescriptor.new
      desc.label = WGPU.empty_string_view
      desc.layout = ml
      desc.vertex = vertex
      desc.primitive = primitive
      desc.depth_stencil = pointerof(depth)
      desc.multisample = multisample
      desc.fragment = pointerof(fragment)
      pipe = LibWGPU.device_create_render_pipeline(@gpu.device, pointerof(desc))
      LibWGPU.pipeline_layout_release(ml)
      pipe
    end

    # Builds a GPU morph mesh: uploads the interleaved per-vertex target deltas
    # ([(vertex*targetCount + target)*6] = {dpos.xyz, dnrm.xyz}), allocates the weights +
    # model-matrix buffers, and assembles the group2 bind group. `targets[t]` holds 6 floats
    # per vertex (dpos + dnrm), matching `MorphPart`.
    def build_gpu_morph(mesh : Mesh, targets : Array(Array(Float32)), node : Int32,
                        default_weights : Array(Float32)) : GpuMorphMesh
      tc = targets.size
      vcount = tc > 0 ? targets[0].size // 6 : 0
      interleaved = Array(Float32).new(vcount * tc * 6)
      vcount.times do |v|
        tc.times do |t|
          6.times { |k| interleaved << targets[t][v * 6 + k] }
        end
      end
      dbytes = (interleaved.size * 4).to_u64
      dbytes = 4_u64 if dbytes == 0
      deltas_buf = make_buffer(dbytes, LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      LibWGPU.queue_write_buffer(@gpu.queue, deltas_buf, 0_u64, interleaved.to_unsafe.as(Void*), (interleaved.size * 4).to_u64) unless interleaved.empty?

      wbytes = (Math.max(tc, 1) * 4).to_u64
      weights_buf = make_buffer(wbytes, LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      model_buf = make_buffer(64_u64, LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst)

      e0 = LibWGPU::BindGroupEntry.new; e0.binding = 0_u32; e0.buffer = deltas_buf; e0.offset = 0_u64; e0.size = dbytes
      e1 = LibWGPU::BindGroupEntry.new; e1.binding = 1_u32; e1.buffer = weights_buf; e1.offset = 0_u64; e1.size = wbytes
      e2 = LibWGPU::BindGroupEntry.new; e2.binding = 2_u32; e2.buffer = model_buf; e2.offset = 0_u64; e2.size = 64_u64
      entries = uninitialized LibWGPU::BindGroupEntry[3]
      entries[0] = e0; entries[1] = e1; entries[2] = e2
      bgd = LibWGPU::BindGroupDescriptor.new
      bgd.label = WGPU.empty_string_view
      bgd.layout = @morph_layout
      bgd.entry_count = 3_u64
      bgd.entries = entries.to_unsafe
      group = LibWGPU.device_create_bind_group(@gpu.device, pointerof(bgd))

      GpuMorphMesh.new(mesh, deltas_buf, weights_buf, model_buf, group, tc, node, default_weights)
    end
  end
end
