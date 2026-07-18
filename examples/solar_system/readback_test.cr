# Headless readback test for the solar-system 3D path: renders the sun sphere with
# a custom Material3D (emissive shader using the shared globals binding) into an
# offscreen target and asserts the center is warm (non-black, red>blue) while a
# corner stays background. Proves Renderer3D custom materials + sphere mesh work.
#
#   crystal run examples/solar_system/readback_test.cr   # exit 0 if OK
require "../../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
sun_mat = renderer.build_material(File.read("examples/assets/shaders/sun_probe.wgsl"))
sun = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 32, rings: 16, color: Flock::Color.new(1.0, 0.8, 0.3))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(0.0, 0.0, 3.0), clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sun, sun_mat))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
px = target.read

center = px.rgb(SIZE // 2, SIZE // 2)
corner = px.rgb(2, 2)

puts "center = #{center}"
puts "corner = #{corner}"

# Center: emissive sun (warm, red>blue, bright). Corner: black background.
ok = center[0] > 80 && center[0] > center[2] &&
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20

Flock.release_all(target, sun, renderer, gpu)

puts ok ? "✅ solar-system 3D material OK" : "❌ sun not rendered as expected"
exit(ok ? 0 : 1)
