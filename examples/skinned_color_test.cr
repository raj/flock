# Headless readback test for vertex colors on skinned meshes (glTF COLOR_0). A single-joint
# skinned quad carries a GREEN COLOR_0; load_gltf_scene is given a RED fallback color. If
# per-vertex colors flow through the skinning path, the rendered quad reads green (not red).
#
#   crystal run examples/skinned_color_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64

path = "examples/assets/gltf/skinned_color.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

# RED fallback — the green COLOR_0 must override it if vertex colors flow through skinning.
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.9, 0.1, 0.1))

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

puts "skinned quad center = #{center} (expect green, not the red fallback)"
ok = center[1] > 150 && center[1] > center[0] * 2 && center[1] > center[2] * 2

puts ok ? "✅ vertex colors on skinned meshes OK" : "❌ COLOR_0 did not reach the skinned mesh"
exit(ok ? 0 : 1)
