module Flock
  # Built-in, reusable custom-material shaders for `Sprite2D#material`, shipped by the
  # engine and usable on BOTH backends (native WGSL, web WebGPU-WGSL + WebGL2-GLSL).
  #
  # Each effect is a small backend-neutral "core" (external file under render/shaders/,
  # embedded here at compile time) that computes two locals — `rgb : vec3` and `a : float`
  # — from the quad UV and sprite tint. A per-backend wrapper adds the boilerplate
  # (vertex stage, entry point, correct alpha convention):
  #
  #   * native  → `SpriteShaders.native(core_wgsl)` : full WGSL module (straight alpha)
  #   * web     → `SpriteShaders.web_wgsl(core_wgsl)` : `fs` fragment (premultiplied)
  #               `SpriteShaders.web_glsl(core_glsl)` : GLSL `main()` body (premultiplied)
  #
  # Register with `Renderer2D#register_builtin` (native) or
  # `Flock::Web.register_builtin` (web); both take a symbol from `BUILTINS`.
  module SpriteShaders
    extend self

    # Shared native vertex stage + bindings (matches Renderer2D's instancing convention).
    # The wrapper appends `fs_main`.
    PREAMBLE_NATIVE = <<-WGSL
    struct Instance {
      model : mat4x4<f32>,
      color : vec4<f32>,
      uv    : vec4<f32>,
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
    WGSL

    # Effect cores (embedded at compile time from render/shaders/*).
    GLOW_WGSL      = {{ read_file("#{__DIR__}/shaders/glow.wgsl") }}
    GLOW_GLSL      = {{ read_file("#{__DIR__}/shaders/glow.glsl") }}
    RING_WGSL      = {{ read_file("#{__DIR__}/shaders/ring.wgsl") }}
    RING_GLSL      = {{ read_file("#{__DIR__}/shaders/ring.glsl") }}
    DISC_WGSL      = {{ read_file("#{__DIR__}/shaders/disc.wgsl") }}
    DISC_GLSL      = {{ read_file("#{__DIR__}/shaders/disc.glsl") }}
    VIGNETTE_WGSL  = {{ read_file("#{__DIR__}/shaders/vignette.wgsl") }}
    VIGNETTE_GLSL  = {{ read_file("#{__DIR__}/shaders/vignette.glsl") }}
    INVADER_A_WGSL = {{ read_file("#{__DIR__}/shaders/invader_a.wgsl") }}
    INVADER_A_GLSL = {{ read_file("#{__DIR__}/shaders/invader_a.glsl") }}
    INVADER_B_WGSL = {{ read_file("#{__DIR__}/shaders/invader_b.wgsl") }}
    INVADER_B_GLSL = {{ read_file("#{__DIR__}/shaders/invader_b.glsl") }}

    # Available built-in shader names.
    BUILTINS = [:glow, :ring, :disc, :vignette, :invader_a, :invader_b]

    # Returns the {wgsl_core, glsl_core} pair for a built-in name.
    def core(name : Symbol) : Tuple(String, String)
      case name
      when :glow      then {GLOW_WGSL, GLOW_GLSL}
      when :ring      then {RING_WGSL, RING_GLSL}
      when :disc      then {DISC_WGSL, DISC_GLSL}
      when :vignette  then {VIGNETTE_WGSL, VIGNETTE_GLSL}
      when :invader_a then {INVADER_A_WGSL, INVADER_A_GLSL}
      when :invader_b then {INVADER_B_WGSL, INVADER_B_GLSL}
      else                 raise "unknown built-in sprite shader: #{name}"
      end
    end

    # Wraps a WGSL core into a full native sprite-material module (straight alpha).
    def native(core_wgsl : String) : String
      <<-WGSL
      #{PREAMBLE_NATIVE}

      @fragment
      fn fs_main(i : VSOut) -> @location(0) vec4<f32> {
        #{core_wgsl}
        return vec4<f32>(rgb, a);
      }
      WGSL
    end

    # Wraps a WGSL core into a web (WebGPU) fragment. Premultiplied alpha (web blend).
    def web_wgsl(core_wgsl : String) : String
      <<-WGSL
      @fragment
      fn fs(i : VSOut) -> @location(0) vec4<f32> {
        #{core_wgsl}
        return vec4<f32>(rgb * a, a);
      }
      WGSL
    end

    # Wraps a GLSL core into a web (WebGL2) `main()` body. Premultiplied alpha (web blend).
    def web_glsl(core_glsl : String) : String
      <<-GLSL
      #{core_glsl}
        o = vec4(rgb * a, a);
      GLSL
    end
  end
end
