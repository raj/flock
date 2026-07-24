# 3D + post-processing readback test (headless).
#
# Renders a lit cube through Renderer3D with an HDR/tonemap pipeline AND a PostStack (bloom),
# proving the 3D scene → HDR target → post effect chain → surface path works end to end.
# Asserts the cube is visible at the center and the background corner stays dark.
#
#   crystal run examples/postfx3d_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu, 1, Flock::Tonemap::Aces) # HDR path (required for 3D post)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.9, 0.4, 0.2))

world = Flock::World.new
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
c = world.spawn
world.add(c, Flock::Transform3D.new)
world.add(c, Flock::MeshRenderer.new(cube))

# The PostStack replaces Renderer3D's inline tonemap pass: bloom, then tonemap → surface.
stack = Flock::PostStack.new(gpu, [Flock::Bloom.new(threshold: 0.3f32, intensity: 2.0f32).as(Flock::PostEffect)], Flock::Tonemap::Aces)
world.insert_resource(stack)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
px = target.read

center = px.rgb(SIZE // 2, SIZE // 2)
corner = px.rgb(2, 2)
puts "center = #{center}"
puts "corner = #{corner}"

ok = center[0] > 60 && center[0] > center[2] && # lit cube (reddish, tonemapped)
     corner[0] < 40 && corner[1] < 40 && corner[2] < 40 # background stays dark

Flock.release_all(target, cube, renderer, gpu)

puts ok ? "✅ 3D + post-processing OK" : "❌ 3D post path unexpected"
exit(ok ? 0 : 1)
