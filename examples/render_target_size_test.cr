# Regression: render into a RenderTarget SMALLER than the GPU/window framebuffer. Before the
# fix, render_into always sized the depth/MSAA attachments to gpu.width/height, so a target of
# a different size mismatched the color attachment and wgpu rejected the pass. Here the GPU
# framebuffer is 128 but the target is 64; the lit cube must still render.
#
#   crystal run examples/render_target_size_test.cr   # exit 0 if OK
require "../src/flock/gpu"

gpu = Flock.headless_context(128, 128) # framebuffer 128x128
renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.9, 0.4, 0.2))

world = Flock::World.new
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
c = world.spawn
world.add(c, Flock::Transform3D.new)
world.add(c, Flock::MeshRenderer.new(cube))

target = Flock::RenderTarget.new(gpu, 64, 64) # smaller than the framebuffer
renderer.render_into(world, target)           # RenderTarget overload -> sizes depth/MSAA to 64
px = target.read

center = px.rgb(32, 32)
corner = px.rgb(2, 2)
puts "center=#{center} corner=#{corner}"
# Center: the lit cube (reddish). Corner: cleared background (black).
ok = center[0] > 60 && center[0] > center[2] &&
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20

Flock.release_all(target, cube, renderer, gpu)
puts ok ? "✅ render into a smaller RenderTarget OK" : "❌ off-size target did not render"
exit(ok ? 0 : 1)
