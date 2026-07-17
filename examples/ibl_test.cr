# Headless readback test for prefiltered image-based lighting. A fully metallic, smooth
# sphere is placed in a blue IBL environment; its specular reflection must read blue
# (the prefiltered environment). A control render WITHOUT the IBL resource stays much
# darker, proving the IBL contribution.
#
#   crystal run examples/ibl_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 48, rings: 24, color: Flock::Color::WHITE)

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sphere, metallic: 1.0f32, roughness: 0.12f32))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

center = ->do
  renderer.render_into(world, target.view)
  px = target.read
  px.rgb(64, 64)
end

no_ibl = center.call # no IblEnvironment resource -> flag off

ibl = renderer.build_ibl(
  sky: Flock::Color.new(0.15, 0.35, 1.0),
  horizon: Flock::Color.new(0.2, 0.4, 1.0),
  ground: Flock::Color.new(0.2, 0.4, 1.0))
world.insert_resource(ibl)
with_ibl = center.call

puts "center without IBL = #{no_ibl}"
puts "center with IBL    = #{with_ibl}"
# With IBL the metallic sphere reflects the blue environment (blue-dominant, brighter).
ok = with_ibl[2] > 80 && with_ibl[2] > with_ibl[0] && with_ibl[2] > no_ibl[2] + 20

Flock.release_all(ibl, sphere, target, renderer, gpu)

puts ok ? "✅ prefiltered IBL OK" : "❌ IBL reflection not as expected"
exit(ok ? 0 : 1)
