module Flock
  # Modular post-processing stack (native wgpu).
  #
  # A `PostStack` is an ordered list of `PostEffect`s run as fullscreen passes on the rendered
  # scene, followed by an output pass that writes the surface (with optional tonemapping). The
  # scene is rendered into an offscreen color target; each effect samples the current color and
  # writes the next, ping-ponging between two scratch targets; the output pass resolves the
  # result to the swapchain.
  #
  # Wiring: add a `PostProcessPlugin` (inserts the `PostStack` resource). `Renderer2D` routes a
  # 2D-only frame through it (so sprites/glow can bloom); `Renderer3D` routes its HDR scene
  # through it in place of the built-in tonemap pass (requires `Render3DPlugin(tonemap: …)`).
  #
  #   app.add_plugins(Flock::RenderPlugin.new,
  #                   Flock::PostProcessPlugin.new(Flock::Bloom.new(threshold: 0.7, intensity: 1.2)))
  #
  # Native only — the web backend has its own renderer.

  # A reusable fullscreen-triangle pass: one fragment shader + a fixed bind layout
  #   @binding(0) sampler · @binding(1) tex0 · @binding(2) tex1 · @binding(3) uniform Params
  # Params is 4×vec4<f32> (64 B) the effect fills as it likes. Draws 3 verts, no vertex buffer.
  class FullscreenPass
    PREAMBLE = <<-WGSL
    struct Params { a : vec4<f32>, b : vec4<f32>, c : vec4<f32>, d : vec4<f32> };
    @group(0) @binding(0) var samp : sampler;
    @group(0) @binding(1) var tex0 : texture_2d<f32>;
    @group(0) @binding(2) var tex1 : texture_2d<f32>;
    @group(0) @binding(3) var<uniform> P : Params;

    struct VSOut { @builtin(position) clip : vec4<f32>, @location(0) uv : vec2<f32> };

    @vertex
    fn vs_main(@builtin(vertex_index) vi : u32) -> VSOut {
      var p = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
      var out : VSOut;
      let xy = p[vi];
      out.clip = vec4<f32>(xy, 0.0, 1.0);
      out.uv = vec2<f32>((xy.x + 1.0) * 0.5, (1.0 - xy.y) * 0.5);
      return out;
    }

    fn aces(x : vec3<f32>) -> vec3<f32> {
      let a = 2.51; let b = 0.03; let c = 2.43; let d = 0.59; let e = 0.14;
      return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
    }
    WGSL

    @shader : LibWGPU::ShaderModule
    @layout : LibWGPU::BindGroupLayout
    @sampler : LibWGPU::Sampler
    @pipeline : LibWGPU::RenderPipeline
    @ubo : LibWGPU::Buffer

    def initialize(@gpu : GpuContext, frag : String, @format : LibWGPU::TextureFormat)
      @shader = build_shader("#{PREAMBLE}\n#{frag}")
      @layout = build_layout
      @sampler = build_sampler
      @pipeline = build_pipeline
      @ubo = WGPU.create_buffer(@gpu.device, 64_u64,
        LibWGPU::BufferUsage::Uniform | LibWGPU::BufferUsage::CopyDst, "postfx-params", false)
    end

    # Runs the pass into `output`, sampling `in0` (and `in1`; pass `in0` again when unused).
    def run(in0 : LibWGPU::TextureView, in1 : LibWGPU::TextureView,
            output : LibWGPU::TextureView, params : StaticArray(Float32, 16)) : Nil
      LibWGPU.queue_write_buffer(@gpu.queue, @ubo, 0_u64, params.to_unsafe.as(Void*), 64_u64)
      group = build_group(in0, in1)

      col = LibWGPU::RenderPassColorAttachment.new
      col.view = output
      col.depth_slice = 0xFFFFFFFF_u32
      col.load_op = LibWGPU::LoadOp::Clear
      col.store_op = LibWGPU::StoreOp::Store
      col.clear_value = LibWGPU::Color.new(r: 0.0, g: 0.0, b: 0.0, a: 1.0)
      pdesc = LibWGPU::RenderPassDescriptor.new
      pdesc.label = WGPU.empty_string_view
      pdesc.color_attachment_count = 1_u64
      pdesc.color_attachments = pointerof(col)

      enc_desc = LibWGPU::CommandEncoderDescriptor.new
      enc_desc.label = WGPU.empty_string_view
      encoder = LibWGPU.device_create_command_encoder(@gpu.device, pointerof(enc_desc))
      pass = LibWGPU.command_encoder_begin_render_pass(encoder, pointerof(pdesc))
      LibWGPU.render_pass_encoder_set_pipeline(pass, @pipeline)
      LibWGPU.render_pass_encoder_set_bind_group(pass, 0_u32, group, 0_u64, Pointer(UInt32).null)
      LibWGPU.render_pass_encoder_draw(pass, 3_u32, 1_u32, 0_u32, 0_u32)
      LibWGPU.render_pass_encoder_end(pass)
      cmd_desc = LibWGPU::CommandBufferDescriptor.new
      cmd_desc.label = WGPU.empty_string_view
      cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
      cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
      LibWGPU.queue_submit(@gpu.queue, 1_u64, cmds.to_unsafe)
      WGPU.release_pass(cmd, pass, encoder)
      LibWGPU.bind_group_release(group)
    end

    def release : Nil
      LibWGPU.buffer_release(@ubo)
      LibWGPU.render_pipeline_release(@pipeline)
      LibWGPU.sampler_release(@sampler)
      LibWGPU.bind_group_layout_release(@layout)
      LibWGPU.shader_module_release(@shader)
    end

    private def build_shader(wgsl : String) : LibWGPU::ShaderModule
      src = LibWGPU::ShaderSourceWGSL.new
      src.chain.s_type = LibWGPU::SType::ShaderSourceWGSL
      src.code = WGPU.string_view(wgsl)
      sdesc = LibWGPU::ShaderModuleDescriptor.new
      sdesc.label = WGPU.empty_string_view
      sdesc.next_in_chain = pointerof(src).as(Pointer(LibWGPU::ChainedStruct))
      LibWGPU.device_create_shader_module(@gpu.device, pointerof(sdesc))
    end

    private def build_sampler : LibWGPU::Sampler
      d = LibWGPU::SamplerDescriptor.new
      d.label = WGPU.empty_string_view
      d.address_mode_u = LibWGPU::AddressMode::ClampToEdge
      d.address_mode_v = LibWGPU::AddressMode::ClampToEdge
      d.address_mode_w = LibWGPU::AddressMode::ClampToEdge
      d.mag_filter = LibWGPU::FilterMode::Linear
      d.min_filter = LibWGPU::FilterMode::Linear
      d.mipmap_filter = LibWGPU::MipmapFilterMode::Linear
      d.lod_min_clamp = 0.0f32; d.lod_max_clamp = 1.0f32; d.max_anisotropy = 1_u16
      LibWGPU.device_create_sampler(@gpu.device, pointerof(d))
    end

    private def build_layout : LibWGPU::BindGroupLayout
      smp = LibWGPU::SamplerBindingLayout.new
      smp.type_ = LibWGPU::SamplerBindingType::Filtering
      e0 = LibWGPU::BindGroupLayoutEntry.new
      e0.binding = 0_u32; e0.visibility = LibWGPU::ShaderStage::Fragment; e0.sampler = smp

      tex = LibWGPU::TextureBindingLayout.new
      tex.sample_type = LibWGPU::TextureSampleType::Float
      tex.view_dimension = LibWGPU::TextureViewDimension::N2D
      e1 = LibWGPU::BindGroupLayoutEntry.new
      e1.binding = 1_u32; e1.visibility = LibWGPU::ShaderStage::Fragment; e1.texture = tex
      e2 = LibWGPU::BindGroupLayoutEntry.new
      e2.binding = 2_u32; e2.visibility = LibWGPU::ShaderStage::Fragment; e2.texture = tex

      ub = LibWGPU::BufferBindingLayout.new
      ub.type_ = LibWGPU::BufferBindingType::Uniform
      ub.min_binding_size = 64_u64
      e3 = LibWGPU::BindGroupLayoutEntry.new
      e3.binding = 3_u32; e3.visibility = LibWGPU::ShaderStage::Fragment; e3.buffer = ub

      entries = uninitialized LibWGPU::BindGroupLayoutEntry[4]
      entries[0] = e0; entries[1] = e1; entries[2] = e2; entries[3] = e3
      d = LibWGPU::BindGroupLayoutDescriptor.new
      d.label = WGPU.empty_string_view
      d.entry_count = 4_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group_layout(@gpu.device, pointerof(d))
    end

    private def build_group(in0 : LibWGPU::TextureView, in1 : LibWGPU::TextureView) : LibWGPU::BindGroup
      e0 = LibWGPU::BindGroupEntry.new; e0.binding = 0_u32; e0.sampler = @sampler
      e1 = LibWGPU::BindGroupEntry.new; e1.binding = 1_u32; e1.texture_view = in0
      e2 = LibWGPU::BindGroupEntry.new; e2.binding = 2_u32; e2.texture_view = in1
      e3 = LibWGPU::BindGroupEntry.new; e3.binding = 3_u32; e3.buffer = @ubo; e3.size = 64_u64
      entries = uninitialized LibWGPU::BindGroupEntry[4]
      entries[0] = e0; entries[1] = e1; entries[2] = e2; entries[3] = e3
      d = LibWGPU::BindGroupDescriptor.new
      d.label = WGPU.empty_string_view
      d.layout = @layout
      d.entry_count = 4_u64
      d.entries = entries.to_unsafe
      LibWGPU.device_create_bind_group(@gpu.device, pointerof(d))
    end

    private def build_pipeline : LibWGPU::RenderPipeline
      layouts = uninitialized LibWGPU::BindGroupLayout[1]
      layouts[0] = @layout
      pld = LibWGPU::PipelineLayoutDescriptor.new
      pld.label = WGPU.empty_string_view
      pld.bind_group_layout_count = 1_u64
      pld.bind_group_layouts = layouts.to_unsafe
      pl = LibWGPU.device_create_pipeline_layout(@gpu.device, pointerof(pld))

      vertex = LibWGPU::VertexState.new
      vertex.module_ = @shader
      vertex.entry_point = WGPU.string_view("vs_main")
      vertex.buffer_count = 0_u64

      target = LibWGPU::ColorTargetState.new
      target.format = @format
      target.write_mask = LibWGPU::ColorWriteMask::All
      fragment = LibWGPU::FragmentState.new
      fragment.module_ = @shader
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
  end

  # A scratch color target (one of the stack's ping-pong buffers, or an effect's own).
  class PostTarget
    getter view : LibWGPU::TextureView
    getter width : UInt32
    getter height : UInt32

    def initialize(@gpu : GpuContext, @width : UInt32, @height : UInt32, format : LibWGPU::TextureFormat)
      d = LibWGPU::TextureDescriptor.new
      d.label = WGPU.empty_string_view
      d.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::TextureBinding
      d.dimension = LibWGPU::TextureDimension::N2D
      d.size = LibWGPU::Extent3D.new(width: @width, height: @height, depth_or_array_layers: 1_u32)
      d.format = format
      d.mip_level_count = 1_u32
      d.sample_count = 1_u32
      @tex = LibWGPU.device_create_texture(@gpu.device, pointerof(d))
      @view = LibWGPU.texture_create_view(@tex, Pointer(LibWGPU::TextureViewDescriptor).null)
    end

    def release : Nil
      LibWGPU.texture_view_release(@view)
      LibWGPU.texture_release(@tex)
    end
  end

  # Base class for a post effect. Lazily builds its passes for the working (gpu, format) on
  # first use, and (re)allocates any scratch targets when the frame size changes.
  abstract class PostEffect
    property? enabled : Bool = true

    @gpu : GpuContext?
    @format : LibWGPU::TextureFormat?
    @w : UInt32 = 0_u32
    @h : UInt32 = 0_u32

    # Ensures the effect's passes exist for (gpu, format) and its scratch fits (w, h).
    def prepare(gpu : GpuContext, format : LibWGPU::TextureFormat, w : UInt32, h : UInt32) : Nil
      if @gpu.nil? || @format != format
        release
        @gpu = gpu; @format = format; @w = 0_u32; @h = 0_u32
        build(gpu, format)
      end
      if @w != w || @h != h
        resize(gpu, format, w, h)
        @w = w; @h = h
      end
    end

    # Samples `input`, writes the effect result into `output`. Called between prepare()s.
    abstract def apply(input : LibWGPU::TextureView, output : LibWGPU::TextureView) : Nil

    protected abstract def build(gpu : GpuContext, format : LibWGPU::TextureFormat) : Nil

    # Reallocate size-dependent scratch. Default: nothing.
    protected def resize(gpu : GpuContext, format : LibWGPU::TextureFormat, w : UInt32, h : UInt32) : Nil
    end

    def release : Nil
    end

    protected def params(a0 = 0.0f32, a1 = 0.0f32, a2 = 0.0f32, a3 = 0.0f32) : StaticArray(Float32, 16)
      p = StaticArray(Float32, 16).new(0.0f32)
      p[0] = a0; p[1] = a1; p[2] = a2; p[3] = a3
      p
    end
  end

  # Bloom: bright-pass → separable Gaussian blur (half-res) → additive composite.
  # `threshold` sets the luminance above which pixels bloom; `intensity` scales the glow.
  class Bloom < PostEffect
    property threshold : Float32
    property intensity : Float32

    def initialize(@threshold : Float32 = 1.0f32, @intensity : Float32 = 1.0f32)
    end

    @bright : FullscreenPass?
    @blur : FullscreenPass?
    @composite : FullscreenPass?
    @t_bright : PostTarget?
    @t_ping : PostTarget?
    @t_pong : PostTarget?

    protected def build(gpu : GpuContext, format : LibWGPU::TextureFormat) : Nil
      bright = <<-F
      @fragment fn fs_main(i : VSOut) -> @location(0) vec4<f32> {
        let c = textureSample(tex0, samp, i.uv).rgb;
        let l = dot(c, vec3<f32>(0.2126, 0.7152, 0.0722));
        let k = max(l - P.a.x, 0.0) / max(l, 1e-4);
        return vec4<f32>(c * k, 1.0);
      }
      F
      blur = <<-F
      @fragment fn fs_main(i : VSOut) -> @location(0) vec4<f32> {
        let o = P.a.xy;
        var w = array<f32, 5>(0.227027, 0.194594, 0.121621, 0.054054, 0.016216);
        var col = textureSample(tex0, samp, i.uv).rgb * w[0];
        for (var k = 1; k < 5; k = k + 1) {
          let d = o * f32(k);
          col = col + textureSample(tex0, samp, i.uv + d).rgb * w[k];
          col = col + textureSample(tex0, samp, i.uv - d).rgb * w[k];
        }
        return vec4<f32>(col, 1.0);
      }
      F
      composite = <<-F
      @fragment fn fs_main(i : VSOut) -> @location(0) vec4<f32> {
        let base = textureSample(tex0, samp, i.uv).rgb;
        let bloom = textureSample(tex1, samp, i.uv).rgb;
        return vec4<f32>(base + bloom * P.a.x, 1.0);
      }
      F
      @bright = FullscreenPass.new(gpu, bright, format)
      @blur = FullscreenPass.new(gpu, blur, format)
      @composite = FullscreenPass.new(gpu, composite, format)
    end

    protected def resize(gpu : GpuContext, format : LibWGPU::TextureFormat, w : UInt32, h : UInt32) : Nil
      @t_bright.try &.release
      @t_ping.try &.release
      @t_pong.try &.release
      hw = Math.max(1_u32, w // 2_u32)
      hh = Math.max(1_u32, h // 2_u32)
      @t_bright = PostTarget.new(gpu, hw, hh, format)
      @t_ping = PostTarget.new(gpu, hw, hh, format)
      @t_pong = PostTarget.new(gpu, hw, hh, format)
    end

    def apply(input : LibWGPU::TextureView, output : LibWGPU::TextureView) : Nil
      bright = @bright.not_nil!; blur = @blur.not_nil!; composite = @composite.not_nil!
      br = @t_bright.not_nil!; ping = @t_ping.not_nil!; pong = @t_pong.not_nil!
      hw = br.width.to_f32; hh = br.height.to_f32

      bright.run(input, input, br.view, params(@threshold))
      # Two separable-Gaussian iterations (H,V,H,V) for a wider, smoother glow.
      blur.run(br.view, br.view, ping.view, params(1.0f32 / hw, 0.0f32))
      blur.run(ping.view, ping.view, pong.view, params(0.0f32, 1.0f32 / hh))
      blur.run(pong.view, pong.view, ping.view, params(2.0f32 / hw, 0.0f32))
      blur.run(ping.view, ping.view, pong.view, params(0.0f32, 2.0f32 / hh))
      composite.run(input, pong.view, output, params(@intensity))
    end

    def release : Nil
      @bright.try &.release; @blur.try &.release; @composite.try &.release
      @t_bright.try &.release; @t_ping.try &.release; @t_pong.try &.release
      @bright = @blur = @composite = nil
      @t_bright = @t_ping = @t_pong = nil
    end
  end

  # FXAA (fast approximate anti-aliasing): a single edge-directed blur pass.
  class Fxaa < PostEffect
    @pass : FullscreenPass?

    protected def build(gpu : GpuContext, format : LibWGPU::TextureFormat) : Nil
      frag = <<-F
      @fragment fn fs_main(i : VSOut) -> @location(0) vec4<f32> {
        let rcp = P.a.xy;
        let L = vec3<f32>(0.299, 0.587, 0.114);
        let m  = textureSample(tex0, samp, i.uv).rgb;
        let lM  = dot(m, L);
        let lNW = dot(textureSample(tex0, samp, i.uv + vec2<f32>(-rcp.x, -rcp.y)).rgb, L);
        let lNE = dot(textureSample(tex0, samp, i.uv + vec2<f32>( rcp.x, -rcp.y)).rgb, L);
        let lSW = dot(textureSample(tex0, samp, i.uv + vec2<f32>(-rcp.x,  rcp.y)).rgb, L);
        let lSE = dot(textureSample(tex0, samp, i.uv + vec2<f32>( rcp.x,  rcp.y)).rgb, L);
        let lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
        let lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));
        var dir = vec2<f32>(-((lNW + lNE) - (lSW + lSE)), ((lNW + lSW) - (lNE + lSE)));
        let reduce = max((lNW + lNE + lSW + lSE) * 0.25 * 0.125, 1.0 / 128.0);
        let rcpDir = 1.0 / (min(abs(dir.x), abs(dir.y)) + reduce);
        dir = clamp(dir * rcpDir, vec2<f32>(-8.0), vec2<f32>(8.0)) * rcp;
        let rgbA = 0.5 * (textureSample(tex0, samp, i.uv + dir * (1.0 / 3.0 - 0.5)).rgb +
                          textureSample(tex0, samp, i.uv + dir * (2.0 / 3.0 - 0.5)).rgb);
        let rgbB = rgbA * 0.5 + 0.25 * (textureSample(tex0, samp, i.uv + dir * -0.5).rgb +
                                        textureSample(tex0, samp, i.uv + dir *  0.5).rgb);
        let lB = dot(rgbB, L);
        if (lB < lMin || lB > lMax) { return vec4<f32>(rgbA, 1.0); }
        return vec4<f32>(rgbB, 1.0);
      }
      F
      @pass = FullscreenPass.new(gpu, frag, format)
    end

    def apply(input : LibWGPU::TextureView, output : LibWGPU::TextureView) : Nil
      p = @pass.not_nil!
      p.run(input, input, output, params(1.0f32 / @w.to_f32, 1.0f32 / @h.to_f32))
    end

    def release : Nil
      @pass.try &.release
      @pass = nil
    end
  end

  # Vignette: darkens the frame toward the edges. `intensity` 0..1, `radius` in UV distance.
  class Vignette < PostEffect
    property intensity : Float32
    property radius : Float32

    def initialize(@intensity : Float32 = 0.5f32, @radius : Float32 = 0.8f32)
    end

    @pass : FullscreenPass?

    protected def build(gpu : GpuContext, format : LibWGPU::TextureFormat) : Nil
      frag = <<-F
      @fragment fn fs_main(i : VSOut) -> @location(0) vec4<f32> {
        let c = textureSample(tex0, samp, i.uv).rgb;
        let d = distance(i.uv, vec2<f32>(0.5, 0.5));
        let vig = 1.0 - P.a.x * smoothstep(P.a.y * 0.4, P.a.y, d);
        return vec4<f32>(c * vig, 1.0);
      }
      F
      @pass = FullscreenPass.new(gpu, frag, format)
    end

    def apply(input : LibWGPU::TextureView, output : LibWGPU::TextureView) : Nil
      @pass.not_nil!.run(input, input, output, params(@intensity, @radius))
    end

    def release : Nil
      @pass.try &.release
      @pass = nil
    end
  end

  # The stack's final pass: samples the processed scene and writes the surface, applying the
  # tonemap operator (None = straight copy). Built for the surface format, not the scene format.
  class OutputPass
    def initialize(@gpu : GpuContext)
      frag = <<-F
      @fragment fn fs_main(i : VSOut) -> @location(0) vec4<f32> {
        let hdr = textureSample(tex0, samp, i.uv);
        let mode = u32(P.d.x);
        var m = hdr.rgb;
        if (mode == 1u) { m = aces(hdr.rgb); }
        else if (mode == 2u) { m = hdr.rgb / (hdr.rgb + vec3<f32>(1.0)); }
        return vec4<f32>(m, hdr.a);
      }
      F
      @pass = FullscreenPass.new(@gpu, frag, @gpu.format)
    end

    def run(input : LibWGPU::TextureView, surface : LibWGPU::TextureView, tonemap : Tonemap) : Nil
      mode = tonemap.aces? ? 1.0f32 : (tonemap.reinhard? ? 2.0f32 : 0.0f32)
      p = StaticArray(Float32, 16).new(0.0f32)
      p[12] = mode # P.d.x
      @pass.run(input, input, surface, p)
    end

    def release : Nil
      @pass.release
    end
  end

  # An ordered chain of post effects + an output/tonemap pass. Inserted as a resource by
  # `PostProcessPlugin`; the renderers fetch it and call `run`.
  class PostStack < Resource
    getter effects : Array(PostEffect)
    # Default tonemap for the output pass (used by the 2D path; the 3D path passes the
    # renderer's own tonemap so `Render3DPlugin(tonemap: …)` stays authoritative).
    property tonemap : Tonemap

    @gpu : GpuContext
    @output : OutputPass?
    @a : PostTarget?
    @b : PostTarget?
    @format : LibWGPU::TextureFormat?
    @w : UInt32 = 0_u32
    @h : UInt32 = 0_u32

    def initialize(@gpu : GpuContext, @effects : Array(PostEffect) = [] of PostEffect,
                   @tonemap : Tonemap = Tonemap::None)
    end

    # Returns the first effect of type T in the chain (nil if none) — e.g. to tweak it live.
    def effect(type : T.class) : T? forall T
      @effects.each { |e| return e if e.is_a?(T) }
      nil
    end

    # Runs the chain: `scene` (offscreen color the renderer drew into) → effects (ping-pong on
    # two scratch targets) → output pass → `surface`. `format` is the scene/scratch format
    # (surface format for 2D, rgba16float for 3D HDR). `tonemap` overrides the default.
    def run(scene : LibWGPU::TextureView, surface : LibWGPU::TextureView,
            w : UInt32, h : UInt32, format : LibWGPU::TextureFormat,
            tonemap : Tonemap = @tonemap) : Nil
      ensure_targets(format, w, h)
      active = @effects.select(&.enabled?)
      active.each { |e| e.prepare(@gpu, format, w, h) }

      cur = scene
      a = @a.not_nil!; b = @b.not_nil!
      active.each do |e|
        dst = (cur == a.view) ? b.view : a.view
        e.apply(cur, dst)
        cur = dst
      end
      @output.not_nil!.run(cur, surface, tonemap)
    end

    private def ensure_targets(format : LibWGPU::TextureFormat, w : UInt32, h : UInt32) : Nil
      @output ||= OutputPass.new(@gpu)
      return if @format == format && @w == w && @h == h && @a
      @a.try &.release
      @b.try &.release
      @a = PostTarget.new(@gpu, w, h, format)
      @b = PostTarget.new(@gpu, w, h, format)
      @format = format; @w = w; @h = h
    end

    def release : Nil
      @effects.each &.release
      @output.try &.release
      @a.try &.release
      @b.try &.release
      @output = nil; @a = nil; @b = nil
    end
  end

  # Inserts a `PostStack` resource (built once the GpuContext exists). Add AFTER a render plugin.
  #
  #   app.add_plugins(Flock::RenderPlugin.new,
  #                   Flock::PostProcessPlugin.new(Flock::Bloom.new, tonemap: Flock::Tonemap::Aces))
  class PostProcessPlugin < Plugin
    def initialize(*effects : PostEffect, @tonemap : Tonemap = Tonemap::None)
      @effects = Array(PostEffect).new(effects.size) { |i| effects[i] }
    end

    def initialize(effects : Array(PostEffect), @tonemap : Tonemap = Tonemap::None)
      @effects = effects
    end

    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        world.insert_resource(PostStack.new(world.resource(GpuContext), @effects, @tonemap))
      end
    end
  end
end
