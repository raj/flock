# Regression test for the glTF skinned-mesh-node transform. A skinned quad's MESH NODE is
# translated +2 in X, with a single identity joint. Per the glTF spec the joint matrix is
# inverse(worldMeshNode)·worldJoint·inverseBind, so the quad renders at x = -2 (the mesh
# node transform is removed, not applied). The old code (worldJoint·inverseBind) left it at
# x = 0. We assert the quad is on the LEFT and the center is background — only true with the
# fix.
#
#   crystal run examples/skinned_node_transform_test.cr   # exit 0 if OK
require "../src/flock/gpu"
SIZE = 64

path = "examples/assets/gltf/skinned_node_transform.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.1, 0.9, 0.1))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 1.2f32, clear_color: Flock::Color::BLACK))
model = Flock::GpuSkinnedModel.spawn(scene, world, renderer, gpu)
model.apply

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
px = target.read

left = px.rgb(8, 32)[1]    # where x=-2 projects (quad expected here with the fix)
center = px.rgb(32, 32)[1] # x=0 (background with the fix; quad with the old code)

Flock.release_all(target, renderer, gpu)

puts "green: left(x=-2)=#{left}, center(x=0)=#{center}"
ok = left > 120 && center < 40 # quad shifted left by the removed mesh-node transform

puts ok ? "✅ skinned mesh-node transform removed (glTF spec) OK" : "❌ mesh-node transform not handled"
exit(ok ? 0 : 1)
