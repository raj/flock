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

  enum LightKind : Int32
    Directional # infinitely far; only `direction` matters
    Point       # omni, positioned (Transform3D.position), falls off within `range`
    Spot        # positioned + `direction` + a cone (`inner`/`outer` half-angles, radians)
  end

  # A light source. Attach it (with a `Transform3D` for position) to an entity; Renderer3D
  # collects all lights each frame and the PBR shader accumulates them. With no `Light`
  # entities, the renderer falls back to its legacy single hard-coded directional light.
  struct Light
    include Component
    property kind : LightKind
    property color : Color
    property intensity : Float32
    property direction : Vec3    # directional/spot aim (world space)
    property range : Float32     # point/spot falloff radius
    property inner : Float32     # spot inner cone half-angle (radians)
    property outer : Float32     # spot outer cone half-angle (radians)
    property casts_shadows : Bool # only the first directional shadow-caster is honored

    def initialize(@kind : LightKind = LightKind::Directional, @color : Color = Color::WHITE,
                   @intensity : Float32 = 1.0f32, @direction : Vec3 = Vec3.new(0, -1, 0),
                   @range : Float32 = 10.0f32, @inner : Float32 = 0.3f32, @outer : Float32 = 0.5f32,
                   @casts_shadows : Bool = false)
    end

    def self.directional(direction : Vec3, color : Color = Color::WHITE, intensity : Number = 1.0,
                          casts_shadows : Bool = false) : Light
      new(LightKind::Directional, color, intensity.to_f32, direction, casts_shadows: casts_shadows)
    end

    def self.point(color : Color = Color::WHITE, intensity : Number = 1.0, range : Number = 10.0) : Light
      new(LightKind::Point, color, intensity.to_f32, Vec3.new, range.to_f32)
    end

    def self.spot(direction : Vec3, color : Color = Color::WHITE, intensity : Number = 1.0,
                  range : Number = 10.0, inner : Number = 0.3, outer : Number = 0.5) : Light
      new(LightKind::Spot, color, intensity.to_f32, direction, range.to_f32, inner.to_f32, outer.to_f32)
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

  # A GPU morph-target mesh (drawn with Renderer3D's morph pipeline): the base `Mesh` plus a
  # storage buffer of per-vertex target deltas, a weights storage buffer + a model-matrix
  # uniform (both updated each frame), and its bind group. Built via
  # `Renderer3D#build_gpu_morph`, driven by `Flock::GpuMorphModel`.
  struct GpuMorphMesh
    include Component
    getter mesh : Mesh
    getter deltas_buf : LibWGPU::Buffer
    getter weights_buf : LibWGPU::Buffer
    getter model_buf : LibWGPU::Buffer
    getter group : LibWGPU::BindGroup
    getter target_count : Int32
    getter node : Int32
    getter default_weights : Array(Float32)

    def initialize(@mesh, @deltas_buf, @weights_buf, @model_buf, @group, @target_count, @node, @default_weights)
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

  # Tonemapping operator for the optional HDR post-processing pass. `None` keeps the
  # direct LDR path (no post pass). `Aces`/`Reinhard` render the scene to an HDR
  # (rgba16float) target and compress it to the display range in a fullscreen pass.
  enum Tonemap
    None
    Aces     # Narkowicz ACES filmic approximation
    Reinhard # c / (1 + c)
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
    PARAM_BYTES   = 48 # per-instance: tint vec4 + {metallic, roughness, cutoff, _} + emissive vec4
    MAX_LIGHTS    = 16   # storage-buffer capacity; extra lights are dropped
    LIGHT_BYTES   = 64   # per light: 4 vec4 (pos+kind / dir+range / color+intensity / cones)
    SHADOW_SIZE   = 2048 # shadow map resolution (Depth32Float), single directional caster

    WGSL = <<-SHADER
    struct Camera { view_proj : mat4x4<f32> };
    // std uniform layout: a.x=time, b.xyz=camera pos, c.rgb=ambient sky, d.rgb=ambient ground.
    struct Globals { a : vec4<f32>, b : vec4<f32>, c : vec4<f32>, d : vec4<f32> };
    // a.x=time, a.y=ibl flag, a.z=light count. b.xyz=camera pos. c/d=ambient sky/ground.
    // mr.x=metallic, mr.y=roughness, mr.z=alpha cutoff (>0 = MASK), mr.w=UV-set bitmask
    // (bit i set -> texture i samples TEXCOORD_1; 0=base,1=mr,2=normal,3=emissive,4=occlusion).
    // emissive.rgb=emissive factor.
    struct Inst { tint : vec4<f32>, mr : vec4<f32>, emissive : vec4<f32> };
    // GPU light: v0=(pos.xyz, kind), v1=(dir.xyz, range), v2=(color.rgb, intensity),
    // v3=(cos(inner), cos(outer), _, _). kind: 0=directional, 1=point, 2=spot.
    struct Light { v0 : vec4<f32>, v1 : vec4<f32>, v2 : vec4<f32>, v3 : vec4<f32> };
    @group(0) @binding(0) var<uniform> cam : Camera;
    @group(0) @binding(1) var<storage, read> models : array<mat4x4<f32>>;
    @group(0) @binding(2) var<uniform> globals : Globals;
    @group(0) @binding(3) var<storage, read> normals : array<mat4x4<f32>>;
    @group(0) @binding(4) var<storage, read> params : array<Inst>;
    @group(0) @binding(5) var<storage, read> lights : array<Light>;
    @group(1) @binding(0) var base_tex : texture_2d<f32>;
    @group(1) @binding(1) var samp : sampler;
    @group(1) @binding(2) var mr_tex : texture_2d<f32>;   // metallic-roughness (G=rough, B=metal)
    @group(1) @binding(3) var nrm_tex : texture_2d<f32>;  // tangent-space normal map
    @group(1) @binding(4) var emissive_tex : texture_2d<f32>; // emissive (x emissive factor)
    @group(1) @binding(5) var occlusion_tex : texture_2d<f32>; // ambient occlusion (R channel)
    // group2: image-based lighting (used when globals.a.y > 0.5).
    @group(2) @binding(0) var irr_cube : texture_cube<f32>;    // diffuse irradiance
    @group(2) @binding(1) var pref_cube : texture_cube<f32>;   // prefiltered specular (mips)
    @group(2) @binding(2) var brdf_lut : texture_2d<f32>;      // split-sum BRDF LUT
    @group(2) @binding(3) var ibl_samp : sampler;
    // group3: shadow map for the directional caster at index globals.a.w (-1 = none).
    @group(3) @binding(0) var<uniform> light_vp : mat4x4<f32>; // world -> light clip space
    @group(3) @binding(1) var shadow_map : texture_depth_2d;
    @group(3) @binding(2) var shadow_samp : sampler_comparison;

    struct VSOut {
      @builtin(position) clip : vec4<f32>,
      @location(0) normal : vec3<f32>,
      @location(1) color : vec3<f32>,
      @location(2) uv : vec2<f32>,
      @location(3) world : vec3<f32>,
      @location(4) mr : vec2<f32>,
      @location(5) alpha : f32,
      @location(6) emissive : vec3<f32>,
      @location(7) cutoff : f32,
      @location(8) uv1 : vec2<f32>,
      @location(9) uvbits : f32,
    };

    @vertex
    fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
               @location(2) col : vec3<f32>, @location(3) uv : vec2<f32>,
               @location(4) uv1 : vec2<f32>,
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
      out.uv1 = uv1;
      out.mr = params[ii].mr.xy;
      out.emissive = params[ii].emissive.rgb;
      out.cutoff = params[ii].mr.z;
      out.uvbits = params[ii].mr.w;
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

    // Shadow factor for a world position (1 = lit, 0 = fully shadowed). Projects into the
    // caster's light space and does a 3x3 PCF comparison against the shadow depth map.
    fn sample_shadow(world : vec3<f32>) -> f32 {
      let lp = light_vp * vec4<f32>(world, 1.0);
      let ndc = lp.xyz / lp.w;
      let uv = vec2<f32>(ndc.x * 0.5 + 0.5, ndc.y * -0.5 + 0.5);
      // Outside the shadow frustum -> treat as lit (no shadow information there).
      if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z < 0.0 || ndc.z > 1.0) {
        return 1.0;
      }
      let bias = 0.0025;
      let cur = ndc.z - bias;
      let texel = 1.0 / 2048.0;
      var sum = 0.0;
      for (var y = -1; y <= 1; y = y + 1) {
        for (var x = -1; x <= 1; x = x + 1) {
          let off = vec2<f32>(f32(x), f32(y)) * texel;
          sum = sum + textureSampleCompareLevel(shadow_map, shadow_samp, uv + off, cur);
        }
      }
      return sum / 9.0;
    }

    // GGX / Cook-Torrance BRDF for one light direction L, returns (diffuse + spec) * NdotL.
    fn shade(N : vec3<f32>, V : vec3<f32>, L : vec3<f32>, base : vec3<f32>,
             metal : f32, rough : f32) -> vec3<f32> {
      let H = normalize(L + V);
      let NdotL = max(dot(N, L), 0.0);
      let NdotV = max(dot(N, V), 1e-3);
      let NdotH = max(dot(N, H), 0.0);
      let VdotH = max(dot(V, H), 0.0);
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
      return (diffuse + spec) * NdotL;
    }

    @fragment
    fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
      // Per-texture UV set: bit i of the mask picks TEXCOORD_1 for texture i.
      let bits = u32(in.uvbits + 0.5);
      let uv_base = select(in.uv, in.uv1, (bits & 1u) != 0u);
      let uv_mr   = select(in.uv, in.uv1, (bits & 2u) != 0u);
      let uv_nrm  = select(in.uv, in.uv1, (bits & 4u) != 0u);
      let uv_em   = select(in.uv, in.uv1, (bits & 8u) != 0u);
      let uv_occ  = select(in.uv, in.uv1, (bits & 16u) != 0u);

      let btex = textureSample(base_tex, samp, uv_base);
      let alpha = btex.a * in.alpha;
      // Alpha MASK (glTF): hard cutout when a cutoff is set (mr.z / in.cutoff > 0).
      if (in.cutoff > 0.0 && alpha < in.cutoff) { discard; }
      let base = in.color * btex.rgb;
      let mrs = textureSample(mr_tex, samp, uv_mr);
      let metal = clamp(mrs.b * in.mr.x, 0.0, 1.0);
      let rough = clamp(mrs.g * in.mr.y, 0.045, 1.0);

      let N = perturb_normal(normalize(in.normal), in.world, uv_nrm);
      let V = normalize(globals.b.xyz - in.world);
      let NdotV = max(dot(N, V), 1e-3);

      // Direct lighting. With no Light entities (count 0) fall back to the legacy
      // single hard-coded directional light, so scenes without lights look unchanged.
      let count = u32(globals.a.z + 0.5);
      var lit = vec3<f32>(0.0);
      if (count == 0u) {
        lit = shade(N, V, normalize(vec3<f32>(0.4, 0.8, 0.6)), base, metal, rough);
      } else {
        for (var i = 0u; i < count; i = i + 1u) {
          let lg = lights[i];
          let kind = i32(lg.v0.w + 0.5);
          var L : vec3<f32>;
          var atten = 1.0;
          if (kind == 0) {
            // Directional: v1.xyz is the direction the light travels; L points toward it.
            L = normalize(-lg.v1.xyz);
          } else {
            // Point / spot: positioned at v0.xyz, falls off within v1.w (range).
            let to_light = lg.v0.xyz - in.world;
            let dist = length(to_light);
            L = to_light / max(dist, 1e-4);
            let range = max(lg.v1.w, 1e-4);
            let f = clamp(1.0 - dist / range, 0.0, 1.0);
            atten = f * f;
            if (kind == 2) {
              // Spot cone: smooth falloff between inner (v3.x) and outer (v3.y) cosines.
              let cd = dot(-L, normalize(lg.v1.xyz));
              atten = atten * clamp((cd - lg.v3.y) / max(lg.v3.x - lg.v3.y, 1e-4), 0.0, 1.0);
            }
          }
          // Shadow only the designated directional caster. globals.a.w holds
          // (caster index + 1); 0 means no shadow caster this frame.
          var sh = 1.0;
          if (i32(globals.a.w + 0.5) == i32(i) + 1) {
            sh = sample_shadow(in.world);
          }
          lit = lit + shade(N, V, L, base, metal, rough) * lg.v2.rgb * lg.v2.w * atten * sh;
        }
      }

      var ambient : vec3<f32>;
      if (globals.a.y > 0.5) {
        // Prefiltered image-based lighting (split-sum).
        let F0 = mix(vec3<f32>(0.04, 0.04, 0.04), base, metal);
        let fr = F0 + (max(vec3<f32>(1.0 - rough), F0) - F0) * pow(1.0 - NdotV, 5.0);
        let kd = (vec3<f32>(1.0) - fr) * (1.0 - metal);
        let irr = textureSampleLevel(irr_cube, ibl_samp, N, 0.0).rgb;
        let diff_ibl = irr * base * kd;
        let R = reflect(-V, N);
        let maxlod = f32(textureNumLevels(pref_cube) - 1u);
        let pref = textureSampleLevel(pref_cube, ibl_samp, R, rough * maxlod).rgb;
        let ab = textureSampleLevel(brdf_lut, ibl_samp, vec2<f32>(NdotV, rough), 0.0).rg;
        let spec_ibl = pref * (F0 * ab.x + ab.y);
        ambient = diff_ibl + spec_ibl;
      } else {
        // Hemisphere ambient probe: sky when facing up, ground when facing down.
        ambient = base * mix(globals.d.rgb, globals.c.rgb, N.y * 0.5 + 0.5);
      }
      // Ambient occlusion (glTF): the R channel attenuates the indirect/ambient term only.
      ambient = ambient * textureSample(occlusion_tex, samp, uv_occ).r;
      // Emissive (glTF): map x factor, added after lighting (unaffected by occlusion).
      let emissive = textureSample(emissive_tex, samp, uv_em).rgb * in.emissive;
      return vec4<f32>(ambient + lit + emissive, alpha);
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

    // Inverse-transpose of a 3x3 (cofactor matrix / det) — transforms normals correctly
    // under non-uniform scale. Column-major mat3x3.
    fn normal_matrix(m : mat3x3<f32>) -> mat3x3<f32> {
      let c0 = cross(m[1], m[2]);
      let c1 = cross(m[2], m[0]);
      let c2 = cross(m[0], m[1]);
      let det = dot(m[0], c0);
      if (abs(det) < 1e-8) { return m; } // degenerate -> fall back to the matrix itself
      let inv = 1.0 / det;
      // Rows of the cofactor matrix become columns of its transpose.
      return mat3x3<f32>(c0 * inv, c1 * inv, c2 * inv);
    }

    @vertex
    fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
               @location(2) col : vec3<f32>, @location(3) uv : vec2<f32>,
               @location(4) uv1 : vec2<f32>,
               @location(5) ji : vec4<u32>, @location(6) jw : vec4<f32>) -> VSOut {
      let skin = jw.x * joints[ji.x] + jw.y * joints[ji.y] + jw.z * joints[ji.z] + jw.w * joints[ji.w];
      var out : VSOut;
      let wp = skin * vec4<f32>(pos, 1.0);
      out.clip = cam.view_proj * wp;
      // Skin the normal with the inverse-transpose of the skin's 3x3 (correct under scale).
      let nm = normal_matrix(mat3x3<f32>(skin[0].xyz, skin[1].xyz, skin[2].xyz));
      out.normal = normalize(nm * nrm);
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

    # Depth-only shadow pass: renders the rigid instances from the caster's point of view
    # into the shadow map. Reuses group0's model storage buffer; the camera slot holds the
    # light view-projection. No fragment output (depth is the only product).
    SHADOW_WGSL = <<-SHADER
    @group(0) @binding(0) var<uniform> light_vp : mat4x4<f32>;
    @group(0) @binding(1) var<storage, read> models : array<mat4x4<f32>>;

    @vertex
    fn vs_main(@location(0) pos : vec3<f32>, @builtin(instance_index) ii : u32) -> @builtin(position) vec4<f32> {
      return light_vp * models[ii] * vec4<f32>(pos, 1.0);
    }
    SHADER

    # Fullscreen post-processing pass: samples the HDR scene texture and tonemaps it to the
    # display range. The `MODE` placeholder (0=Aces, 1=Reinhard) is substituted per operator.
    POST_WGSL = <<-SHADER
    @group(0) @binding(0) var hdr_tex : texture_2d<f32>;
    @group(0) @binding(1) var hdr_samp : sampler;

    struct VSOut { @builtin(position) clip : vec4<f32>, @location(0) uv : vec2<f32> };

    @vertex
    fn vs_main(@builtin(vertex_index) vi : u32) -> VSOut {
      // Oversized triangle covering the screen (no vertex buffer).
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

    @fragment
    fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
      let hdr = textureSample(hdr_tex, hdr_samp, in.uv);
      var mapped : vec3<f32>;
      if (MODE == 0) {
        mapped = aces(hdr.rgb);
      } else {
        mapped = hdr.rgb / (hdr.rgb + vec3<f32>(1.0));
      }
      return vec4<f32>(mapped, hdr.a);
    }
    SHADER

    # GPU morph-target shader: blends the base vertex with weighted target deltas read from
    # a storage buffer (indexed by @builtin(vertex_index)), then applies the node's model
    # matrix. Weights + deltas live in group2; targetCount = arrayLength(&weights). Simple
    # diffuse + hemisphere ambient like the skinned shader.
    MORPH_WGSL = <<-SHADER
    struct Camera { view_proj : mat4x4<f32> };
    struct Globals { a : vec4<f32>, b : vec4<f32>, c : vec4<f32>, d : vec4<f32> };
    @group(0) @binding(0) var<uniform> cam : Camera;
    @group(0) @binding(2) var<uniform> globals : Globals;
    @group(1) @binding(0) var base_tex : texture_2d<f32>;
    @group(1) @binding(1) var samp : sampler;
    @group(2) @binding(0) var<storage, read> deltas : array<f32>;  // [(vi*tc + t)*6 + k]
    @group(2) @binding(1) var<storage, read> weights : array<f32>; // one per target
    @group(2) @binding(2) var<uniform> model : mat4x4<f32>;

    struct VSOut {
      @builtin(position) clip : vec4<f32>,
      @location(0) normal : vec3<f32>,
      @location(1) color : vec3<f32>,
      @location(2) uv : vec2<f32>,
    };

    fn normal_matrix(m : mat3x3<f32>) -> mat3x3<f32> {
      let c0 = cross(m[1], m[2]); let c1 = cross(m[2], m[0]); let c2 = cross(m[0], m[1]);
      let det = dot(m[0], c0);
      if (abs(det) < 1e-8) { return m; }
      let inv = 1.0 / det;
      return mat3x3<f32>(c0 * inv, c1 * inv, c2 * inv);
    }

    @vertex
    fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
               @location(2) col : vec3<f32>, @location(3) uv : vec2<f32>,
               @builtin(vertex_index) vi : u32) -> VSOut {
      let tc = arrayLength(&weights);
      var p = pos;
      var n = nrm;
      for (var t = 0u; t < tc; t = t + 1u) {
        let w = weights[t];
        let o = (vi * tc + t) * 6u;
        p = p + w * vec3<f32>(deltas[o], deltas[o + 1u], deltas[o + 2u]);
        n = n + w * vec3<f32>(deltas[o + 3u], deltas[o + 4u], deltas[o + 5u]);
      }
      var out : VSOut;
      let wp = model * vec4<f32>(p, 1.0);
      out.clip = cam.view_proj * wp;
      let nm = normal_matrix(mat3x3<f32>(model[0].xyz, model[1].xyz, model[2].xyz));
      out.normal = normalize(nm * n);
      out.color = col;
      out.uv = uv;
      return out;
    }

    @fragment
    fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
      let base = in.color * textureSample(base_tex, samp, in.uv).rgb;
      let nn = normalize(in.normal);
      let d = max(dot(nn, normalize(vec3<f32>(0.4, 0.8, 0.6))), 0.0);
      let amb = mix(globals.d.rgb, globals.c.rgb, nn.y * 0.5 + 0.5);
      return vec4<f32>(base * (amb + d), 1.0);
    }
    SHADER

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

    private def tex_group(base : Texture, mr : Texture, normal : Texture,
                          emissive : Texture, occlusion : Texture) : LibWGPU::BindGroup
      key = {base.view.address, mr.view.address, normal.view.address,
             emissive.view.address, occlusion.view.address}
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
        LibWGPU.texture_view_release(target)
        LibWGPU.texture_release(st.texture)
      when .outdated?, .lost?
        @gpu.reconfigure_to_window
      else
        # skip
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
    private def render_shadow_pass(groups) : Nil
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

    # Renders the world's meshes into an arbitrary target (surface or offscreen),
    # with its own depth buffer. Used by `render` and by readback tests.
    def render_into(world : World, target : LibWGPU::TextureView) : Nil
      ensure_depth(@gpu.width, @gpu.height)

      camera = nil.as(Camera3D?)
      world.query(Camera3D) { |_e, cam| camera = cam.value if cam.value.active }
      cam = camera || Camera3D.new
      vp = cam.view_projection(@gpu.aspect)
      LibWGPU.queue_write_buffer(@gpu.queue, @uniform_buf, 0_u64, vp.m.to_unsafe.as(Void*), 64_u64)

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
      # a.w = shadow caster index + 1 (0 = none); the shader shadows only that light.
      globals[3] = shadow_index >= 0 ? (shadow_index + 1).to_f32 : 0.0f32
      globals[4] = cam.position.x; globals[5] = cam.position.y; globals[6] = cam.position.z
      globals[8] = amb.sky.r; globals[9] = amb.sky.g; globals[10] = amb.sky.b
      globals[12] = amb.ground.r; globals[13] = amb.ground.g; globals[14] = amb.ground.b
      LibWGPU.queue_write_buffer(@gpu.queue, @globals_buf, 0_u64, globals.to_unsafe.as(Void*), GLOBALS_BYTES.to_u64)

      # Group entities by (mesh, material) so identical bodies are drawn in ONE
      # instanced draw call. Model matrices are laid out grouped; each group's
      # instances index the storage buffer via first_instance (= @builtin(instance_index)).
      # Frustum culling drops instances whose world bounding sphere is off-screen.
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

        if @cull && m.cull && mesh.bounds_radius != Float32::MAX
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

      # Shadow pass: render the drawn instances from the caster's point of view into the
      # shadow map. Fit an orthographic light frustum to the scene AABB. Runs before the
      # main pass; the same @model_buf + group layout (base offsets) are reused.
      shadow_on = shadow_index >= 0 && total > 0 && bb_max.x >= bb_min.x
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
        render_shadow_pass(groups)
      end

      # The scene's single-sample destination: the HDR target when tonemapping (the post
      # pass reads it and writes `target`), otherwise the frame target directly.
      scene_target = @tonemap.none? ? target : @hdr_view

      color_att = LibWGPU::RenderPassColorAttachment.new
      # MSAA: render into the multisampled target and resolve into scene_target.
      # Without MSAA, render straight into scene_target (no resolve).
      if @sample_count > 1
        color_att.view = @msaa_view
        color_att.resolve_target = scene_target
      else
        color_att.view = scene_target
      end
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
      # group2 = IBL (rigid pipeline); default (unused) environment when none is set.
      LibWGPU.render_pass_encoder_set_bind_group(pass, 2_u32, ibl_group, 0_u64, Pointer(UInt32).null)
      # group3 = shadow map (light_vp + depth map + comparison sampler); the shader only
      # samples it for the caster at globals.a.w, so it is harmless when no caster is set.
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
        # One instanced draw for the whole group; first_instance = base offset.
        LibWGPU.render_pass_encoder_draw_indexed(pass, mesh.index_count, count, 0_u32, 0, base)
        base += count
      end

      # GPU-skinned meshes (own pipeline + skin buffer + joint group). Additive: no-op
      # when the scene has none, so the rigid path above is unaffected.
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

      # Transparent pass: after all opaque geometry, draw the sorted translucent instances
      # (back to front) with the blended pipeline (depth test on, depth-write off). Each is
      # a single-instance draw whose first_instance points at its model/param slot.
      unless transparent.empty?
        LibWGPU.render_pass_encoder_set_pipeline(pass, @transparent_pipeline)
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

      # Post pass (same encoder, after the scene): tonemap the HDR target into `target`.
      post = Pointer(Void).null.as(LibWGPU::RenderPassEncoder)
      unless @tonemap.none?
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
        post = LibWGPU.command_encoder_begin_render_pass(encoder, pointerof(pdesc))
        LibWGPU.render_pass_encoder_set_pipeline(post, @post_pipeline)
        LibWGPU.render_pass_encoder_set_bind_group(post, 0_u32, @post_group, 0_u64, Pointer(UInt32).null)
        LibWGPU.render_pass_encoder_draw(post, 3_u32, 1_u32, 0_u32, 0_u32)
        LibWGPU.render_pass_encoder_end(post)
      end

      cmd_desc = LibWGPU::CommandBufferDescriptor.new
      cmd_desc.label = WGPU.empty_string_view
      cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
      cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
      LibWGPU.queue_submit(@gpu.queue, 1_u64, cmds.to_unsafe)

      LibWGPU.command_buffer_release(cmd)
      LibWGPU.render_pass_encoder_release(post) unless post.null?
      LibWGPU.render_pass_encoder_release(pass)
      LibWGPU.command_encoder_release(encoder)
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
