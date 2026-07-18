@group(0) @binding(0) var<uniform> u : vec4<f32>; // x=time, y=aspect

@vertex
fn vs_main(@builtin(vertex_index) vi : u32) -> @builtin(position) vec4<f32> {
  var p = array<vec2<f32>, 3>(
    vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
  return vec4<f32>(p[vi], 0.0, 1.0);
}

@fragment
fn fs_main(@builtin(position) frag : vec4<f32>) -> @location(0) vec4<f32> {
  let t = u.x;
  let uv = frag.xy / 300.0;
  let c = 0.5 + 0.5 * sin(vec3<f32>(
    uv.x * 3.0 + t,
    uv.y * 3.0 + t * 1.3,
    (uv.x + uv.y) * 3.0 + t * 0.7));
  return vec4<f32>(c, 1.0);
}