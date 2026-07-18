struct Camera { view_proj : mat4x4<f32> };
struct Globals { time : f32 };
@group(0) @binding(0) var<uniform> cam : Camera;
@group(0) @binding(1) var<storage, read> models : array<mat4x4<f32>>;
@group(0) @binding(2) var<uniform> globals : Globals;
struct VSOut { @builtin(position) clip : vec4<f32>, @location(0) lpos : vec3<f32> };
@vertex
fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
           @location(2) col : vec3<f32>, @builtin(instance_index) ii : u32) -> VSOut {
  var out : VSOut;
  out.clip = cam.view_proj * models[ii] * vec4<f32>(pos, 1.0);
  out.lpos = pos;
  return out;
}
@fragment
fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
  // globals.time is 0 here; produce a stable warm color.
  let flick = 0.5 + 0.5 * sin(in.lpos.x * 7.0 + globals.time);
  return vec4<f32>(mix(vec3<f32>(0.95,0.35,0.05), vec3<f32>(1.0,0.9,0.4), flick), 1.0);
}