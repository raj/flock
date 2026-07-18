struct Instance { model : mat4x4<f32>, color : vec4<f32>, uv : vec4<f32> };
@group(0) @binding(0) var<uniform> u_vp : mat4x4<f32>;
@group(0) @binding(1) var<storage, read> instances : array<Instance>;
const QUAD = array<vec2<f32>, 6>(
  vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, -0.5), vec2<f32>(0.5, 0.5),
  vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, 0.5), vec2<f32>(-0.5, 0.5));
@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> @builtin(position) vec4<f32> {
  return u_vp * instances[ii].model * vec4<f32>(QUAD[vi], 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4<f32> {
  return vec4<f32>(0.2, 0.4, 1.0, 1.0);
}