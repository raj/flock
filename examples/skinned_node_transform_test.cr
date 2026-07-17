# Regression test for the glTF skinned-mesh-node transform. A skinned quad's MESH NODE is
# translated +2 in X, with a single identity joint. Per the glTF spec the joint matrix is
# inverse(worldMeshNode)·worldJoint·inverseBind, so the quad renders at x = -2 (the mesh
# node transform is removed, not applied). The old code (worldJoint·inverseBind) left it at
# x = 0. We assert the quad is on the LEFT and the center is background — only true with the
# fix.
#
#   crystal run examples/skinned_node_transform_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 64
LE = IO::ByteFormat::LittleEndian

io = IO::Memory.new
# POSITION (0,48): a quad centered at the origin.
[-0.5f32, -0.5f32, 0.0f32, 0.5f32, -0.5f32, 0.0f32,
 0.5f32, 0.5f32, 0.0f32, -0.5f32, 0.5f32, 0.0f32].each { |f| io.write_bytes(f, LE) }
# JOINTS_0 (48,32) u16x4: joint 0.
16.times { io.write_bytes(0u16, LE) }
# WEIGHTS_0 (80,64) f32x4: [1,0,0,0].
4.times { io.write_bytes(1.0f32, LE); io.write_bytes(0.0f32, LE); io.write_bytes(0.0f32, LE); io.write_bytes(0.0f32, LE) }
# indices (144,12).
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| io.write_bytes(i, LE) }
# inverseBindMatrices (156,64): identity.
[1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32].each { |f| io.write_bytes(f, LE) }
buf = io.to_slice
uri = "data:application/octet-stream;base64,#{Base64.strict_encode(buf)}"
json = %({
  "asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1]}],
  "nodes":[{},{"mesh":0,"skin":0,"translation":[2.0,0.0,0.0]}],
  "skins":[{"joints":[0],"inverseBindMatrices":4}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0,"JOINTS_0":1,"WEIGHTS_0":2},"indices":3}]}],
  "buffers":[{"uri":"#{uri}","byteLength":#{buf.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":32},
    {"buffer":0,"byteOffset":80,"byteLength":64},{"buffer":0,"byteOffset":144,"byteLength":12},
    {"buffer":0,"byteOffset":156,"byteLength":64}],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5123,"count":4,"type":"VEC4"},
    {"bufferView":2,"componentType":5126,"count":4,"type":"VEC4"},
    {"bufferView":3,"componentType":5123,"count":6,"type":"SCALAR"},
    {"bufferView":4,"componentType":5126,"count":1,"type":"MAT4"}]
})
path = File.tempname("flock_skinnode", ".gltf")
File.write(path, json)

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.1, 0.9, 0.1))
File.delete(path) rescue nil

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
