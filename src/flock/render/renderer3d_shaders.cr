module Flock
  # WGSL shader sources for Renderer3D (kept out of the core for size).
  class Renderer3D
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
      // KHR_materials_unlit (bit 8 of the UV-set mask): output the base color, no lighting.
      if ((bits & 256u) != 0u) { return vec4<f32>(base, alpha); }
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

    # Skinned depth-only shadow pass: skins the vertex with the joint matrices (group1),
    # same as the main skinned shader, so GPU-skinned meshes cast correct shadows. Reuses
    # group0 (light_vp + unused models slot) so it shares the rigid shadow bind group.
    SHADOW_SKINNED_WGSL = <<-SHADER
    @group(0) @binding(0) var<uniform> light_vp : mat4x4<f32>;
    @group(1) @binding(0) var<storage, read> joints : array<mat4x4<f32>>;

    @vertex
    fn vs_main(@location(0) pos : vec3<f32>, @location(1) ji : vec4<u32>, @location(2) jw : vec4<f32>) -> @builtin(position) vec4<f32> {
      let skin = jw.x * joints[ji.x] + jw.y * joints[ji.y] + jw.z * joints[ji.z] + jw.w * joints[ji.w];
      return light_vp * skin * vec4<f32>(pos, 1.0);
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
  end
end
