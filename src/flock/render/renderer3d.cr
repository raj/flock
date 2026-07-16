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

    def initialize(@mesh, @skin_buf, @skin_bytes, @joint_buf, @joint_group, @joint_count, @joint_nodes, @inverse_binds)
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
    PARAM_BYTES   = 32 # per-instance: tint vec4 + {metallic, roughness, _, _} vec4

    WGSL = <<-SHADER
    struct Camera { view_proj : mat4x4<f32> };
    // std uniform layout: a.x=time, b.xyz=camera pos, c.rgb=ambient sky, d.rgb=ambient ground.
    struct Globals { a : vec4<f32>, b : vec4<f32>, c : vec4<f32>, d : vec4<f32> };
    struct Inst { tint : vec4<f32>, mr : vec4<f32> }; // mr.x=metallic, mr.y=roughness
    @group(0) @binding(0) var<uniform> cam : Camera;
    @group(0) @binding(1) var<storage, read> models : array<mat4x4<f32>>;
    @group(0) @binding(2) var<uniform> globals : Globals;
    @group(0) @binding(3) var<storage, read> normals : array<mat4x4<f32>>;
    @group(0) @binding(4) var<storage, read> params : array<Inst>;
    @group(1) @binding(0) var base_tex : texture_2d<f32>;
    @group(1) @binding(1) var samp : sampler;
    @group(1) @binding(2) var mr_tex : texture_2d<f32>;   // metallic-roughness (G=rough, B=metal)
    @group(1) @binding(3) var nrm_tex : texture_2d<f32>;  // tangent-space normal map

    struct VSOut {
      @builtin(position) clip : vec4<f32>,
      @location(0) normal : vec3<f32>,
      @location(1) color : vec3<f32>,
      @location(2) uv : vec2<f32>,
      @location(3) world : vec3<f32>,
      @location(4) mr : vec2<f32>,
      @location(5) alpha : f32,
    };

    @vertex
    fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
               @location(2) col : vec3<f32>, @location(3) uv : vec2<f32>,
               @builtin(instance_index) ii : u32) -> VSOut {
      var out : VSOut;
      let wp = models[ii] * vec4<f32>(pos, 1.0);
      out.clip = cam.view_proj * wp;
      out.world = wp.xyz;
      // Normal matrix (inverse-transpose) -> correct under non-uniform scale.
      out.normal = normalize((normals[ii] * vec4<f32>(nrm, 0.0)).xyz);
      out.color = col * params[ii].tint.rgb;
      out.alpha = params[ii].tint.a;
      out.uv = uv;
      out.mr = params[ii].mr.xy;
      return out;
    }

    // Tangent-space normal perturbation without stored tangents (derivative TBN).
    fn perturb_normal(nn : vec3<f32>, wp : vec3<f32>, uv : vec2<f32>) -> vec3<f32> {
      let m = textureSample(nrm_tex, samp, uv).xyz * 2.0 - 1.0;
      let dp1 = dpdx(wp); let dp2 = dpdy(wp);
      let du1 = dpdx(uv); let du2 = dpdy(uv);
      let dp2p = cross(dp2, nn); let dp1p = cross(nn, dp1);
      let T = dp2p * du1.x + dp1p * du2.x;
      let B = dp2p * du1.y + dp1p * du2.y;
      let denom = max(dot(T, T), dot(B, B));
      // Degenerate UVs (no texture coords) -> no tangent frame; keep the geometric normal.
      if (denom < 1e-12) { return nn; }
      let inv = inverseSqrt(denom);
      return normalize(T * (inv * m.x) + B * (inv * m.y) + nn * m.z);
    }

    @fragment
    fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
      let btex = textureSample(base_tex, samp, in.uv);
      let base = in.color * btex.rgb;
      let mrs = textureSample(mr_tex, samp, in.uv);
      let metal = clamp(mrs.b * in.mr.x, 0.0, 1.0);
      let rough = clamp(mrs.g * in.mr.y, 0.045, 1.0);

      let N = perturb_normal(normalize(in.normal), in.world, in.uv);
      let L = normalize(vec3<f32>(0.4, 0.8, 0.6));
      let V = normalize(globals.b.xyz - in.world);
      let H = normalize(L + V);
      let NdotL = max(dot(N, L), 0.0);
      let NdotV = max(dot(N, V), 1e-3);
      let NdotH = max(dot(N, H), 0.0);
      let VdotH = max(dot(V, H), 0.0);

      // GGX / Cook-Torrance specular for one directional light.
      let a = rough * rough;
      let a2 = a * a;
      let dn = NdotH * NdotH * (a2 - 1.0) + 1.0;
      let D = a2 / (3.14159265 * dn * dn + 1e-5);
      let k = (rough + 1.0) * (rough + 1.0) / 8.0;
      let G = (NdotV / (NdotV * (1.0 - k) + k)) * (NdotL / (NdotL * (1.0 - k) + k));
      let F0 = mix(vec3<f32>(0.04, 0.04, 0.04), base, metal);
      let F = F0 + (vec3<f32>(1.0, 1.0, 1.0) - F0) * pow(1.0 - VdotH, 5.0);
      let spec = (D * G) * F / (4.0 * NdotV * NdotL + 1e-4);

      let diffuse = base * (1.0 - metal);
      let lit = (diffuse + spec) * NdotL;
      // Hemisphere ambient probe: sky when facing up, ground when facing down.
      let up = N.y * 0.5 + 0.5;
      let ambient = base * mix(globals.d.rgb, globals.c.rgb, up);
      return vec4<f32>(ambient + lit, btex.a * in.alpha);
    }
    SHADER

    # GPU skinning shader: reads per-vertex joints/weights from vertex buffer slot 1 and
    # joint matrices from group2, and skins pos/normal on the GPU. Reuses group0 (cam +
    # globals) and group1 (base color). Simple diffuse + hemisphere ambient.
    SKINNED_WGSL = <<-SHADER
    struct Camera { view_proj : mat4x4<f32> };
    struct Globals { a : vec4<f32>, b : vec4<f32>, c : vec4<f32>, d : vec4<f32> };
    @group(0) @binding(0) var<uniform> cam : Camera;
    @group(0) @binding(2) var<uniform> globals : Globals;
    @group(1) @binding(0) var base_tex : texture_2d<f32>;
    @group(1) @binding(1) var samp : sampler;
    @group(2) @binding(0) var<storage, read> joints : array<mat4x4<f32>>;

    struct VSOut {
      @builtin(position) clip : vec4<f32>,
      @location(0) normal : vec3<f32>,
      @location(1) color : vec3<f32>,
      @location(2) uv : vec2<f32>,
    };

    @vertex
    fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
               @location(2) col : vec3<f32>, @location(3) uv : vec2<f32>,
               @location(4) ji : vec4<u32>, @location(5) jw : vec4<f32>) -> VSOut {
      let skin = jw.x * joints[ji.x] + jw.y * joints[ji.y] + jw.z * joints[ji.z] + jw.w * joints[ji.w];
      var out : VSOut;
      let wp = skin * vec4<f32>(pos, 1.0);
      out.clip = cam.view_proj * wp;
      out.normal = normalize((skin * vec4<f32>(nrm, 0.0)).xyz);
      out.color = col;
      out.uv = uv;
      return out;
    }

    @fragment
    fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
      let base = in.color * textureSample(base_tex, samp, in.uv).rgb;
      let n = normalize(in.normal);
      let d = max(dot(n, normalize(vec3<f32>(0.4, 0.8, 0.6))), 0.0);
      let amb = mix(globals.d.rgb, globals.c.rgb, n.y * 0.5 + 0.5);
      return vec4<f32>(base * (amb + d), 1.0);
    }
    SHADER

    @model_capacity : Int32 = 64
    @scratch : Array(Float32) = [] of Float32
    @scratch_n : Array(Float32) = [] of Float32
    @scratch_p : Array(Float32) = [] of Float32
    @depth_w : UInt32 = 0
    @depth_h : UInt32 = 0
    # Frustum-culling stats from the last render_into (drawn vs. culled instances).
    getter last_drawn : Int32 = 0
    getter last_culled : Int32 = 0
    # Set false to disable frustum culling (e.g. for debugging).
    property cull : Bool = true

    @shader : LibWGPU::ShaderModule
    @pipeline : LibWGPU::RenderPipeline
    @group0_layout : LibWGPU::BindGroupLayout
    @group1_layout : LibWGPU::BindGroupLayout # texture + sampler
    @pipeline_layout : LibWGPU::PipelineLayout
    # GPU skinning: joint-matrix bind group layout + a dedicated skinned pipeline.
    @joint_layout : LibWGPU::BindGroupLayout
    @skinned_shader : LibWGPU::ShaderModule
    @skinned_pipeline : LibWGPU::RenderPipeline
    @white : Texture
    @flat_normal : Texture # 1x1 (0,0,1) tangent-space normal (no perturbation)
    @samplers : Hash(Tuple(SamplerFilter, SamplerWrap), LibWGPU::Sampler) = {} of Tuple(SamplerFilter, SamplerWrap) => LibWGPU::Sampler
    @tex_groups : Hash(Tuple(UInt64, UInt64, UInt64), LibWGPU::BindGroup) = {} of Tuple(UInt64, UInt64, UInt64) => LibWGPU::BindGroup
    @uniform_buf : LibWGPU::Buffer
    @model_buf : LibWGPU::Buffer
    @normal_buf : LibWGPU::Buffer
    @param_buf : LibWGPU::Buffer
    @globals_buf : LibWGPU::Buffer
    @group0 : LibWGPU::BindGroup
    @materials : Array(Material3D) = [] of Material3D
    @depth_tex : LibWGPU::Texture
    @depth_view : LibWGPU::TextureView

    def initialize(@gpu : GpuContext)
      # Explicit group0 layout (camera uniform + model storage + globals uniform) +
      # group1 (base-color texture + sampler) so custom materials share both.
      @group0_layout = build_group0_layout
      @group1_layout = build_group1_layout
      @pipeline_layout = build_pipeline_layout
      @white = Texture.white(@gpu)
      @flat_normal = Texture.from_pixels(@gpu, 1, 1, Bytes[128_u8, 128_u8, 255_u8, 255_u8])

      @shader = build_shader(WGSL)
      @pipeline = build_pipeline(@shader)

      # Skinned pipeline (group0 + group1 + joint matrices in group2).
      @joint_layout = build_joint_layout
      @skinned_shader = build_shader(SKINNED_WGSL)
      @skinned_pipeline = build_skinned_pipeline(@skinned_shader)

      @uniform_buf = make_buffer(64_u64, LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst)
      @model_buf = make_buffer((@model_capacity * MODEL_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      @normal_buf = make_buffer((@model_capacity * MODEL_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      @param_buf = make_buffer((@model_capacity * PARAM_BYTES).to_u64,
        LibWGPU::BufferUsage::Storage | LibWGPU::BufferUsage::CopyDst)
      @globals_buf = make_buffer(GLOBALS_BYTES.to_u64, LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst)
      @group0 = build_group0

      # Depth texture (lazily sized to the surface on first render).
      @depth_tex = Pointer(Void).null.as(LibWGPU::Texture)
      @depth_view = Pointer(Void).null.as(LibWGPU::TextureView)
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
      @materials.each &.release
      @tex_groups.each_value { |bg| LibWGPU.bind_group_release(bg) }
      @tex_groups.clear
      @samplers.each_value { |s| LibWGPU.sampler_release(s) }
      @samplers.clear
      @white.release
      @flat_normal.release
      LibWGPU.bind_group_release(@group0)
      LibWGPU.buffer_release(@globals_buf)
      LibWGPU.buffer_release(@param_buf)
      LibWGPU.buffer_release(@normal_buf)
      LibWGPU.buffer_release(@model_buf)
      LibWGPU.buffer_release(@uniform_buf)
      LibWGPU.render_pipeline_release(@skinned_pipeline)
      LibWGPU.shader_module_release(@skinned_shader)
      LibWGPU.bind_group_layout_release(@joint_layout)
      LibWGPU.pipeline_layout_release(@pipeline_layout)
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

      entries = uninitialized LibWGPU::BindGroupLayoutEntry[5]
      entries[0] = e0
      entries[1] = e1
      entries[2] = e2
      entries[3] = e3
      entries[4] = e4
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 5_u64
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

      entries = uninitialized LibWGPU::BindGroupLayoutEntry[4]
      entries[0] = texlayout.call(0_u32)
      entries[1] = e1
      entries[2] = texlayout.call(2_u32)
      entries[3] = texlayout.call(3_u32)
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 4_u64
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
      d.lod_min_clamp = 0.0f32; d.lod_max_clamp = 1.0f32; d.max_anisotropy = 1_u16
      LibWGPU.device_create_sampler(@gpu.device, pointerof(d))
    end

    private def tex_group(base : Texture, mr : Texture, normal : Texture) : LibWGPU::BindGroup
      key = {base.view.address, mr.view.address, normal.view.address}
      @tex_groups.fetch(key) do
        e0 = LibWGPU::BindGroupEntry.new; e0.binding = 0_u32; e0.texture_view = base.view
        e1 = LibWGPU::BindGroupEntry.new; e1.binding = 1_u32; e1.sampler = sampler_for(base.filter, base.wrap)
        e2 = LibWGPU::BindGroupEntry.new; e2.binding = 2_u32; e2.texture_view = mr.view
        e3 = LibWGPU::BindGroupEntry.new; e3.binding = 3_u32; e3.texture_view = normal.view
        entries = uninitialized LibWGPU::BindGroupEntry[4]
        entries[0] = e0; entries[1] = e1; entries[2] = e2; entries[3] = e3
        d = LibWGPU::BindGroupDescriptor.new
        d.label = WGPU.empty_string_view
        d.layout = @group1_layout
        d.entry_count = 4_u64
        d.entries = entries.to_unsafe
        bg = LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
        @tex_groups[key] = bg
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

    private def build_pipeline(shader : LibWGPU::ShaderModule) : LibWGPU::RenderPipeline
      vs = WGPU.string_view("vs_main")
      fs = WGPU.string_view("fs_main")

      # Vertex layout: pos(loc0), normal(loc1), color(loc2) Float32x3; uv(loc3) Float32x2.
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
      vertex.entry_point = vs
      vertex.buffer_count = 1_u64
      vertex.buffers = pointerof(vlayout)

      target = LibWGPU::ColorTargetState.new
      target.format = @gpu.format
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
      desc.layout = @pipeline_layout
      desc.vertex = vertex
      desc.primitive = primitive
      desc.depth_stencil = pointerof(depth)
      desc.multisample = multisample
      desc.fragment = pointerof(fragment)
      LibWGPU.device_create_render_pipeline(@gpu.device, pointerof(desc))
    end

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

      # Buffer 0: the bind-pose mesh (pos/normal/color/uv), same layout as the rigid path.
      a0 = LibWGPU::VertexAttribute.new; a0.format = LibWGPU::VertexFormat::Float32x3; a0.offset = 0_u64; a0.shader_location = 0_u32
      a1 = LibWGPU::VertexAttribute.new; a1.format = LibWGPU::VertexFormat::Float32x3; a1.offset = 12_u64; a1.shader_location = 1_u32
      a2 = LibWGPU::VertexAttribute.new; a2.format = LibWGPU::VertexFormat::Float32x3; a2.offset = 24_u64; a2.shader_location = 2_u32
      a3 = LibWGPU::VertexAttribute.new; a3.format = LibWGPU::VertexFormat::Float32x2; a3.offset = 36_u64; a3.shader_location = 3_u32
      attrs0 = uninitialized LibWGPU::VertexAttribute[4]
      attrs0[0] = a0; attrs0[1] = a1; attrs0[2] = a2; attrs0[3] = a3

      # Buffer 1: skin data — joints (Uint32x4) + weights (Float32x4), stride 32.
      a4 = LibWGPU::VertexAttribute.new; a4.format = LibWGPU::VertexFormat::Uint32x4; a4.offset = 0_u64; a4.shader_location = 4_u32
      a5 = LibWGPU::VertexAttribute.new; a5.format = LibWGPU::VertexFormat::Float32x4; a5.offset = 16_u64; a5.shader_location = 5_u32
      attrs1 = uninitialized LibWGPU::VertexAttribute[2]
      attrs1[0] = a4; attrs1[1] = a5

      # Configure each layout as a local, then copy into the array (indexing a
      # StaticArray of structs returns a copy, so `layouts[0].field = …` wouldn't stick).
      l0 = LibWGPU::VertexBufferLayout.new
      l0.step_mode = LibWGPU::VertexStepMode::Vertex
      l0.array_stride = Mesh::STRIDE
      l0.attribute_count = 4_u64
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
      target.format = @gpu.format
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
      multisample.count = 1_u32
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
                       joint_nodes : Array(Int32), inverse_binds : Array(Mat4)) : GpuSkinnedMesh
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

      GpuSkinnedMesh.new(mesh, skin_buf, skin_bytes, joint_buf, joint_group, jcount, joint_nodes, inverse_binds)
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
      entries = uninitialized LibWGPU::BindGroupEntry[5]
      entries[0] = e0
      entries[1] = e1
      entries[2] = e2
      entries[3] = e3
      entries[4] = e4
      d = LibWGPU::BindGroupDescriptor.new
      d.label = WGPU.empty_string_view
      d.layout = @group0_layout
      d.entry_count = 5_u64
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

      # Globals: time (a.x), camera position (b.xyz), ambient sky (c.rgb) / ground (d.rgb).
      t = world.resource?(Time).try(&.elapsed.to_f32) || 0.0f32
      amb = world.resource?(AmbientLight) || AmbientLight.new
      globals = StaticArray(Float32, 16).new(0.0f32)
      globals[0] = t
      globals[4] = cam.position.x; globals[5] = cam.position.y; globals[6] = cam.position.z
      globals[8] = amb.sky.r; globals[9] = amb.sky.g; globals[10] = amb.sky.b
      globals[12] = amb.ground.r; globals[13] = amb.ground.g; globals[14] = amb.ground.b
      LibWGPU.queue_write_buffer(@gpu.queue, @globals_buf, 0_u64, globals.to_unsafe.as(Void*), GLOBALS_BYTES.to_u64)

      # Group entities by (mesh, material) so identical bodies are drawn in ONE
      # instanced draw call. Model matrices are laid out grouped; each group's
      # instances index the storage buffer via first_instance (= @builtin(instance_index)).
      # Frustum culling drops instances whose world bounding sphere is off-screen.
      frustum = Frustum.from(vp)
      groups = [] of {Mesh, Material3D?, Texture, Texture, Texture, Array({Mat4, Color, Float32, Float32})}
      slot = {} of Tuple(UInt64, UInt64, UInt64, UInt64, UInt64) => Int32
      total = 0
      culled = 0
      world.query(Transform3D, MeshRenderer) do |_e, tf, mrr|
        mesh = mrr.value.mesh
        model = tf.value.matrix

        if @cull && mesh.bounds_radius != Float32::MAX
          center = model.transform_point(mesh.bounds_center)
          s = model.scale_factors
          radius = mesh.bounds_radius * Math.max(s.x, Math.max(s.y, s.z))
          unless frustum.intersects_sphere?(center, radius)
            culled += 1
            next
          end
        end

        material = mrr.value.material
        base = mrr.value.texture || @white
        mr_tex = mrr.value.metallic_roughness || @white
        nrm_tex = mrr.value.normal_map || @flat_normal
        inst = {model, mrr.value.tint, mrr.value.metallic, mrr.value.roughness}
        key = {mesh.object_id, material ? material.object_id : 0_u64,
               base.object_id, mr_tex.object_id, nrm_tex.object_id}
        if gi = slot[key]?
          groups[gi][5] << inst
        else
          slot[key] = groups.size
          groups << {mesh, material, base, mr_tex, nrm_tex, [inst]}
        end
        total += 1
      end
      @last_drawn = total
      @last_culled = culled

      # Even with nothing to draw (empty scene or everything culled) we still run the
      # pass below so the frame is cleared; only the buffer uploads are skipped.
      if total > 0
        ensure_capacity(total)
        @scratch.clear
        @scratch_n.clear
        @scratch_p.clear
        groups.each do |(_m, _mat, _b, _mrt, _nt, insts)|
          insts.each do |(model, tint, metallic, roughness)|
            @scratch.concat(model.m)
            @scratch_n.concat(model.normal_matrix.m)
            @scratch_p.push(tint.r, tint.g, tint.b, tint.a, metallic, roughness, 0.0f32, 0.0f32)
          end
        end
        LibWGPU.queue_write_buffer(@gpu.queue, @model_buf, 0_u64,
          @scratch.to_unsafe.as(Void*), (@scratch.size * 4).to_u64)
        LibWGPU.queue_write_buffer(@gpu.queue, @normal_buf, 0_u64,
          @scratch_n.to_unsafe.as(Void*), (@scratch_n.size * 4).to_u64)
        LibWGPU.queue_write_buffer(@gpu.queue, @param_buf, 0_u64,
          @scratch_p.to_unsafe.as(Void*), (@scratch_p.size * 4).to_u64)
      end

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
      # group0 (camera/models/globals) is shared by every material's pipeline
      # (same explicit layout), so it stays bound across pipeline switches.
      LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @group0, 0_u64, Pointer(UInt32).null)
      current = Pointer(Void).null.as(LibWGPU::RenderPipeline)

      base = 0_u32
      groups.each do |(mesh, material, base_tex, mr_tex, nrm_tex, insts)|
        count = insts.size.to_u32
        pipeline = material ? material.pipeline : @pipeline
        if pipeline != current
          LibWGPU.render_pass_encoder_set_pipeline(pass, pipeline)
          current = pipeline
        end
        LibWGPU.render_pass_encoder_set_bind_group(pass, 1_u32, tex_group(base_tex, mr_tex, nrm_tex), 0_u64, Pointer(UInt32).null)
        LibWGPU.render_pass_encoder_set_vertex_buffer(pass, 0_u32, mesh.vertex_buf, 0_u64, mesh.vertex_bytes)
        LibWGPU.render_pass_encoder_set_index_buffer(pass, mesh.index_buf, LibWGPU::IndexFormat::Uint32, 0_u64, mesh.index_bytes)
        # One instanced draw for the whole group; first_instance = base offset.
        LibWGPU.render_pass_encoder_draw_indexed(pass, mesh.index_count, count, 0_u32, 0, base)
        base += count
      end

      # GPU-skinned meshes (own pipeline + skin buffer + joint group). Additive: no-op
      # when the scene has none, so the rigid path above is unaffected.
      white_group = nil.as(LibWGPU::BindGroup?)
      world.query(GpuSkinnedMesh) do |_e, sk|
        s = sk.value
        white_group ||= tex_group(@white, @white, @flat_normal)
        LibWGPU.render_pass_encoder_set_pipeline(pass, @skinned_pipeline)
        LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, @group0, 0_u64, Pointer(UInt32).null)
        LibWGPU.render_pass_encoder_set_bind_group(pass, 1_u32, white_group.not_nil!, 0_u64, Pointer(UInt32).null)
        LibWGPU.render_pass_encoder_set_bind_group(pass, 2_u32, s.joint_group, 0_u64, Pointer(UInt32).null)
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

      LibWGPU.command_buffer_release(cmd)
      LibWGPU.render_pass_encoder_release(pass)
      LibWGPU.command_encoder_release(encoder)
    end
  end

  # Wires the 3D renderer: inserts Renderer3D at startup (from the GpuContext) and
  # runs it each frame in Schedule::Render. Use it INSTEAD of RenderPlugin (each
  # owns the whole frame): pair WindowPlugin + Render3DPlugin (+ Input/Audio) rather
  # than DefaultPlugins.
  class Render3DPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        world.insert_resource(Renderer3D.new(world.resource(GpuContext)))
      end
      app.add_system(Schedule::Render) do |world, _cmd|
        world.resource?(Renderer3D).try &.render(world)
      end
    end
  end
end
