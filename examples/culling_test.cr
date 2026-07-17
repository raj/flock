# Headless test for frustum culling. Two cubes share the scene: one in front of the
# camera, one far off to the side (out of the frustum). We assert Renderer3D culled
# exactly the off-screen one (last_drawn == 1, last_culled == 1) and that the visible
# cube still renders at the center; a control render with culling disabled draws both.
#
#   crystal run examples/culling_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.9, 0.5, 0.2))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
# In view (origin).
a = world.spawn
world.add(a, Flock::Transform3D.new(Flock::Vec3.new(0, 0, 0)))
world.add(a, Flock::MeshRenderer.new(cube))
# Far off to the side — outside the frustum.
b = world.spawn
world.add(b, Flock::Transform3D.new(Flock::Vec3.new(1000.0, 0, 0)))
world.add(b, Flock::MeshRenderer.new(cube))

# Offscreen target.
target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

renderer.render_into(world, target.view)
drawn = renderer.last_drawn
culled = renderer.last_culled

# Control: disable culling, both should be drawn.
renderer.cull = false
renderer.render_into(world, target.view)
drawn_nocull = renderer.last_drawn
renderer.cull = true
renderer.render_into(world, target.view) # restore the culled image for readback

# Read center pixel to confirm the visible cube rendered.
center = target.read.rgb(64, 64)

puts "with culling:  drawn=#{drawn}, culled=#{culled}"
puts "without cull:  drawn=#{drawn_nocull}"
puts "center = #{center}"

ok = drawn == 1 && culled == 1 && drawn_nocull == 2 &&
     center[0].to_i + center[1].to_i + center[2].to_i > 40 # visible cube rendered

Flock.release_all(target, cube, renderer, gpu)

puts ok ? "✅ frustum culling OK" : "❌ culling did not behave as expected"
exit(ok ? 0 : 1)
