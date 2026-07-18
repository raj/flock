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

def setup(world : Flock::World, cmd : Flock::Commands)
  gpu = world.resource(Flock::GpuContext)
  renderer = world.resource(Flock::Renderer3D)

  sun_mat = renderer.build_material(File.read("examples/assets/shaders/sun.wgsl"))
  planet_mat = renderer.build_material(File.read("examples/assets/shaders/planet.wgsl"))

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

  # One shared unit sphere for every planet: same mesh + material, per-instance size
  # (Transform3D scale) and color (MeshRenderer#tint) -> all planets in ONE instanced draw.
  planet_sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 32, rings: 16, color: Flock::Color::WHITE)
  planets.each_with_index do |(radius, size, speed, spin, color), i|
    cmd.spawn(
      Flock::Transform3D.new(Flock::Vec3.new(radius, 0, 0), scale: Flock::Vec3.new(size, size, size)),
      Flock::MeshRenderer.new(planet_sphere, planet_mat, tint: color),
      Orbit.new(radius: radius, speed: speed, angle: i.to_f * 1.1, spin: spin),
    )
  end
end

# Advance orbits + self-rotation.
def advance_orbits(world : Flock::World, cmd : Flock::Commands)
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
def orbit_camera(world : Flock::World, cmd : Flock::Commands)
  t = world.resource(Flock::Time).elapsed
  world.query(CameraRig, Flock::Camera3D) do |_e, _rig, camp|
    r = 30.0
    camp.value.position = Flock::Vec3.new(Math.cos(t * 0.15) * r, 12.0, Math.sin(t * 0.15) * r)
  end
end

app = Flock::App.new
# Window + unified 3D-then-2D renderer: the 3D scene with a 2D HUD overlay on top.
app.add_plugin(Flock::WindowPlugin.new("Flock — Solar System", 900, 650))
app.add_plugin(Flock::Render2D3DPlugin.new)

app.add_startup(&->setup(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->advance_orbits(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->orbit_camera(Flock::World, Flock::Commands))

app.run
