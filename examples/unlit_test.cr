# KHR_materials_unlit readback test (headless): an unlit mesh outputs its flat base color
# (no lighting), so it's brighter/uniform vs the same mesh shaded.
#
#   crystal run examples/unlit_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 96
gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.9, 0.2, 0.2)) # base color 0.9 red

render = ->(unlit : Bool) do
  world = Flock::World.new
  world.add(world.spawn, Flock::Camera3D.new(
    position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
  c = world.spawn
  world.add(c, Flock::Transform3D.new)
  world.add(c, Flock::MeshRenderer.new(cube, unlit: unlit))
  target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
  renderer.render_into(world, target.view)
  px = target.read.rgb(SIZE // 2, SIZE // 2)
  target.release
  px
end

lit = render.call(false)
unlit = render.call(true)
puts "lit center   = #{lit}"
puts "unlit center = #{unlit}"

Flock.release_all(cube, renderer, gpu)

# Unlit = flat base (0.9*255 ≈ 229), unaffected by lighting; the lit one is shaded (dimmer).
ok = unlit[0] > 210 &&           # ~full base red
     unlit[0] > lit[0] + 10 &&   # brighter than the shaded version
     unlit[1] < 90 && unlit[2] < 90 # still red (base color preserved)

puts ok ? "✅ KHR_materials_unlit OK" : "❌ unlit unexpected"
exit(ok ? 0 : 1)
