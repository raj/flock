# Regression test for normalized-integer glTF accessors. A single-joint (identity) skinned
# quad stores WEIGHTS_0 as NORMALIZED UNSIGNED_BYTE [255,0,0,0] — i.e. weight 1.0. Without
# de-normalization the shader sees weight 255, scaling every vertex 255x off-screen (center
# = black); with it, the quad renders normally (center = lit green). Common in optimized
# exports (Draco/gltfpack), so this path must work.
#
#   crystal run examples/gltf_normalized_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64

path = "examples/assets/gltf/gltf_normalized.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.1, 0.9, 0.1))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 2.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
model = Flock::GpuSkinnedModel.spawn(scene, world, renderer, gpu)
model.apply

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)

px = target.read
center = px.rgb(32, 32)

Flock.release_all(target, renderer, gpu)

puts "center = #{center} (expect lit green; black => weight not de-normalized)"
ok = center[1] > 100 && center[1] > center[0] && center[1] > center[2]

puts ok ? "✅ normalized accessors OK" : "❌ normalized WEIGHTS_0 not de-normalized (mesh flew off-screen)"
exit(ok ? 0 : 1)
