# Headless readback test for the Flock lighting system (Flock::Light). A white sphere is
# lit by a single RED directional light travelling into the screen (so the camera-facing
# front is lit). Ambient is near-black, so the direct light dominates: the sphere's center
# must read strongly red (r > g and r > b), proving Light components drive the PBR shader.
#
#   crystal run examples/lights_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 48, rings: 24, color: Flock::Color.new(0.8, 0.8, 0.8))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
# Near-black ambient so the direct light is what colors the sphere.
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(0.02, 0.02, 0.02), ground: Flock::Color.new(0.02, 0.02, 0.02)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))

# Red directional light travelling into the screen (-z): L = -dir = +z lights the front.
lw = world.spawn
world.add(lw, Flock::Transform3D.new)
world.add(lw, Flock::Light.directional(Flock::Vec3.new(0.0, 0.0, -1.0), Flock::Color.new(1.0, 0.1, 0.1), 3.0))

e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sphere))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
px = target.read

center = px.rgb(64, 64)

puts "center = #{center}"
ok = center[0] > 60 &&              # visibly lit
     center[0] > center[1] * 2 &&   # strongly red
     center[0] > center[2] * 2

Flock.release_all(target, sphere, renderer, gpu)

puts ok ? "✅ directional light OK" : "❌ light did not color the sphere as expected"
exit(ok ? 0 : 1)
