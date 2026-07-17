# Readback test for 3D multi-camera viewport + order (split-screen). Two Camera3D cover the
# left and right halves of the frame, each aimed at a different cube: the left camera (order
# 0) at a RED cube, the right camera (order 1) at a BLUE cube. The left half must read red
# and the right half blue, proving per-camera viewport/order rendering.
#
#   crystal run examples/split_screen_3d_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
redcube = Flock::Mesh.cube(gpu, color: Flock::Color.new(1.0, 0.1, 0.1))
bluecube = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.1, 0.1, 1.0))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))

half = SIZE.to_f32 / 2.0f32
# Left camera (order 0): left half, looks at the red cube (x = -3).
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(-3.0, 0.0, 3.0), target: Flock::Vec3.new(-3.0, 0.0, 0.0), fov_y: 0.9f32,
  viewport: Flock::Viewport.new(0.0f32, 0.0f32, half, SIZE.to_f32), order: 0,
  clear_color: Flock::Color.new(0.0, 0.0, 0.0)))
# Right camera (order 1): right half, looks at the blue cube (x = +3).
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(3.0, 0.0, 3.0), target: Flock::Vec3.new(3.0, 0.0, 0.0), fov_y: 0.9f32,
  viewport: Flock::Viewport.new(half, 0.0f32, half, SIZE.to_f32), order: 1))

er = world.spawn
world.add(er, Flock::Transform3D.new(position: Flock::Vec3.new(-3.0, 0.0, 0.0)))
world.add(er, Flock::MeshRenderer.new(redcube))
eb = world.spawn
world.add(eb, Flock::Transform3D.new(position: Flock::Vec3.new(3.0, 0.0, 0.0)))
world.add(eb, Flock::MeshRenderer.new(bluecube))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
px = target.read

left = px.rgb(32, 64)  # left-half center
right = px.rgb(96, 64) # right-half center

Flock.release_all(target, redcube, bluecube, renderer, gpu)

puts "left half = #{left} (expect red), right half = #{right} (expect blue)"
ok = left[0] > 100 && left[0] > left[2] * 2 &&   # left viewport -> red cube
     right[2] > 100 && right[2] > right[0] * 2    # right viewport -> blue cube

puts ok ? "✅ 3D split-screen (viewport + order) OK" : "❌ multi-camera viewport/order not rendered"
exit(ok ? 0 : 1)
