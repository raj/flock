# Solar system — 3D demo: a glowing sun and orbiting planets, each with a custom
# shader (emissive animated sun; lit planets with procedural bands). Shows the 3D
# renderer (Renderer3D + Camera3D + Material3D) and the ECS driving the orbits.
#
#   crystal run examples/solar_system/main.cr
#   WGPU_FRAMES=180 crystal run examples/solar_system/main.cr   # headless smoke
#
# 3D uses Render3DPlugin (owns the frame) instead of DefaultPlugins (which is 2D).
require "../../src/flock/gpu"

# --- Components ---

# Orbit around the origin (the sun) + self-rotation. radius 0 = fixed (the sun).
struct Orbit
  include Flock::Component
  property radius : Float64
  property speed : Float64  # orbital angular velocity (rad/s)
  property angle : Float64  # current orbital angle
  property spin : Float64   # self-rotation velocity (rad/s)

  def initialize(@radius : Float64, @speed : Float64, @angle : Float64 = 0.0, @spin : Float64 = 0.6)
  end
end

# Marks the camera entity so the demo can slowly orbit it.
struct CameraRig
  include Flock::Component
end

# --- Shaders (WGSL). Both share group0 = camera(0) + models(1) + globals(2). ---

# Sun: emissive, animated turbulence driven by globals.time (no lighting).
SUN_WGSL = <<-WGSL
struct Camera { view_proj : mat4x4<f32> };
struct Globals { time : f32 };
@group(0) @binding(0) var<uniform> cam : Camera;
@group(0) @binding(1) var<storage, read> models : array<mat4x4<f32>>;
@group(0) @binding(2) var<uniform> globals : Globals;

struct VSOut {
  @builtin(position) clip : vec4<f32>,
  @location(0) lpos : vec3<f32>,
  @location(1) color : vec3<f32>,
};

@vertex
fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
           @location(2) col : vec3<f32>, @builtin(instance_index) ii : u32) -> VSOut {
  var out : VSOut;
  out.clip = cam.view_proj * models[ii] * vec4<f32>(pos, 1.0);
  out.lpos = pos;
  out.color = col;
  return out;
}

@fragment
fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
  let t = globals.time;
  let p = in.lpos * 7.0;
  let w = sin(p.x + t * 1.7) * sin(p.y * 1.3 - t * 1.1) * sin(p.z * 0.8 + t * 2.1);
  let flick = 0.5 + 0.5 * w;
  let hot = vec3<f32>(1.0, 0.9, 0.4);
  let cool = vec3<f32>(0.95, 0.35, 0.05);
  let base = mix(cool, hot, flick);
  return vec4<f32>(base * (0.9 + 0.35 * flick), 1.0);
}
WGSL

# Planet: directional lighting (from the sun) + procedural latitude bands.
PLANET_WGSL = <<-WGSL
struct Camera { view_proj : mat4x4<f32> };
struct Globals { time : f32 };
@group(0) @binding(0) var<uniform> cam : Camera;
@group(0) @binding(1) var<storage, read> models : array<mat4x4<f32>>;
@group(0) @binding(2) var<uniform> globals : Globals;
@group(0) @binding(3) var<storage, read> normals : array<mat4x4<f32>>;

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
  out.color = col;
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
WGSL

app = Flock::App.new
# Window + unified 3D-then-2D renderer: the 3D scene with a 2D HUD overlay on top.
app.add_plugin(Flock::WindowPlugin.new("Flock — Solar System", 900, 650))
app.add_plugin(Flock::Render2D3DPlugin.new)

app.add_startup do |world, cmd|
  gpu = world.resource(Flock::GpuContext)
  renderer = world.resource(Flock::Renderer3D)

  sun_mat = renderer.build_material(SUN_WGSL)
  planet_mat = renderer.build_material(PLANET_WGSL)

  # Camera looking at the sun, slightly from above.
  cmd.spawn(
    CameraRig.new,
    Flock::Camera3D.new(
      position: Flock::Vec3.new(0, 12, 26),
      target: Flock::Vec3.new(0, 0, 0),
      fov_y: 0.75f32,
      clear_color: Flock::Color.new(0.02, 0.02, 0.05)),
  )

  # 2D HUD overlay (drawn on top of the 3D scene by Render2D3DPlugin): a 2D camera
  # that does NOT clear, plus a translucent banner across the top of the window.
  cmd.spawn(Flock::Camera2D.new(clear_color: nil))
  cmd.spawn(
    Flock::Transform2D.at(0, 300),
    Flock::Sprite.new(Flock::Vec2.new(900, 44), Flock::Color.new(0.2, 0.6, 1.0, 0.28), z: 100.0f32))

  # The sun: a big emissive sphere at the origin (radius 0 orbit = stays put).
  sun_mesh = Flock::Mesh.sphere(gpu, radius: 2.4, segments: 48, rings: 24, color: Flock::Color.new(1.0, 0.8, 0.3))
  cmd.spawn(
    Flock::Transform3D.new(Flock::Vec3.new(0, 0, 0)),
    Flock::MeshRenderer.new(sun_mesh, sun_mat),
    Orbit.new(radius: 0.0, speed: 0.0, spin: 0.15),
  )

  # Planets: {orbit radius, size, orbital speed, spin, color}.
  planets = [
    {5.0, 0.45, 1.05, 1.4, Flock::Color.new(0.7, 0.7, 0.75)},   # mercury-ish
    {7.4, 0.7, 0.78, 1.0, Flock::Color.new(0.9, 0.7, 0.4)},     # venus-ish
    {9.8, 0.75, 0.62, 1.2, Flock::Color.new(0.3, 0.55, 0.95)},  # earth-ish
    {12.4, 0.55, 0.5, 1.3, Flock::Color.new(0.85, 0.4, 0.25)},  # mars-ish
    {16.0, 1.5, 0.34, 0.8, Flock::Color.new(0.8, 0.65, 0.45)},  # jupiter-ish
    {20.0, 1.2, 0.26, 0.7, Flock::Color.new(0.85, 0.8, 0.6)},   # saturn-ish
  ]

  planets.each_with_index do |(radius, size, speed, spin, color), i|
    mesh = Flock::Mesh.sphere(gpu, radius: size, segments: 32, rings: 16, color: color)
    cmd.spawn(
      Flock::Transform3D.new(Flock::Vec3.new(radius, 0, 0)),
      Flock::MeshRenderer.new(mesh, planet_mat),
      Orbit.new(radius: radius, speed: speed, angle: i.to_f * 1.1, spin: spin),
    )
  end
end

# Advance orbits + self-rotation.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  dt = world.resource(Flock::Time).delta
  world.query(Flock::Transform3D, Orbit) do |_e, tf, orb|
    o = orb.value
    o.angle = o.angle + o.speed * dt
    orb.value.angle = o.angle
    x = Math.cos(o.angle) * o.radius
    z = Math.sin(o.angle) * o.radius
    tf.value.position = Flock::Vec3.new(x, 0.0, z)
    spin_y = tf.value.rotation.y + o.spin * dt
    tf.value.rotation = Flock::Vec3.new(0.0, spin_y, 0.0)
  end
end

# Slowly orbit the camera around the system for a cinematic look.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  t = world.resource(Flock::Time).elapsed
  world.query(CameraRig, Flock::Camera3D) do |_e, _rig, camp|
    r = 30.0
    camp.value.position = Flock::Vec3.new(Math.cos(t * 0.15) * r, 12.0, Math.sin(t * 0.15) * r)
  end
end

app.run
