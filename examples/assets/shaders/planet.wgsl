struct Camera { view_proj : mat4x4<f32> };
struct Globals { time : f32 };
@group(0) @binding(0) var<uniform> cam : Camera;
@group(0) @binding(1) var<storage, read> models : array<mat4x4<f32>>;
@group(0) @binding(2) var<uniform> globals : Globals;
@group(0) @binding(3) var<storage, read> normals : array<mat4x4<f32>>;
struct Inst { tint : vec4<f32>, mr : vec4<f32> };
@group(0) @binding(4) var<storage, read> params : array<Inst>;

struct VSOut {
  @builtin(position) clip : vec4<f32>,
  @location(0) lpos : vec3<f32>,
  @location(1) normal : vec3<f32>,
  @location(2) color : vec3<f32>,
};

@vertex
fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
           @location(2) col : vec3<f32>, @builtin(instance_index) ii : u32) -> VSOut {
  var out : VSOut;
  out.clip = cam.view_proj * models[ii] * vec4<f32>(pos, 1.0);
  out.lpos = pos;
  out.normal = normalize((normals[ii] * vec4<f32>(nrm, 0.0)).xyz);
  out.color = col * params[ii].tint.rgb; // each planet tinted from its instance param
  return out;
}

@fragment
fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
  // Light comes from the sun at the origin; approximate with a fixed direction.
  let light = normalize(vec3<f32>(0.5, 0.6, 0.4));
  let n = normalize(in.normal);
  let diff = max(dot(n, light), 0.0);
  let bands = 0.5 + 0.5 * sin(in.lpos.y * 22.0 + globals.time * 0.4);
  let tint = mix(in.color, in.color * vec3<f32>(0.65, 0.75, 1.0), bands * 0.4);
  let shade = 0.12 + 0.88 * diff;
  return vec4<f32>(tint * shade, 1.0);
}