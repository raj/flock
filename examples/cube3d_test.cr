# 3D mesh rendering test (headless, readback).
#
# Renders a lit cube through a Camera3D into an offscreen target (with depth buffer),
# reads the pixels back, and asserts the cube is visible at the center (non-background,
# roughly its color) while a corner stays background — proving Renderer3D + Camera3D
# + depth work.
#
#   crystal run examples/cube3d_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.9, 0.4, 0.2))

world = Flock::World.new
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
c = world.spawn
world.add(c, Flock::Transform3D.new)
world.add(c, Flock::MeshRenderer.new(cube))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
px = target.read

center = px.rgb(SIZE // 2, SIZE // 2)
corner = px.rgb(2, 2)
puts "center = #{center}"
puts "corner = #{corner}"

# Center: the lit cube (reddish, non-black). Corner: cleared background (black).
ok = center[0] > 60 && center[0] > center[2] && # reddish, non-background
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20 # background

Flock.release_all(target, cube, renderer, gpu)

puts ok ? "✅ 3D mesh rendering OK" : "❌ cube not rendered as expected"
exit(ok ? 0 : 1)
