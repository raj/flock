# Regression: a glTF node that gives a 4x4 `matrix` (instead of TRS) must be honored by the
# animated/scene path (load_gltf_scene -> world_matrices), not only the baked load_gltf path.
# The single mesh node here carries a column-major matrix translating the quad +1.6 in X, so
# it renders on the RIGHT of the frame. Before the fix the matrix was ignored (node collapsed
# to identity) and the quad rendered centered. We assert right-lit / center-dark.
#
#   crystal run examples/gltf_matrix_node_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 64
LE = IO::ByteFormat::LittleEndian

io = IO::Memory.new
# POSITION (0,48): a quad centered at the origin.
[-0.5f32, -0.5f32, 0.0f32, 0.5f32, -0.5f32, 0.0f32,
 0.5f32, 0.5f32, 0.0f32, -0.5f32, 0.5f32, 0.0f32].each { |f| io.write_bytes(f, LE) }
# indices (48,12).
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| io.write_bytes(i, LE) }
buf = io.to_slice
uri = "data:application/octet-stream;base64,#{Base64.strict_encode(buf)}"

# node 0: mesh 0 with a column-major matrix translating +1.6 in X (last column = translation).
json = %({
  "asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
  "nodes":[{"mesh":0,"matrix":[1,0,0,0, 0,1,0,0, 0,0,1,0, 1.6,0,0,1]}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
  "buffers":[{"uri":"#{uri}","byteLength":#{buf.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},
    {"buffer":0,"byteOffset":48,"byteLength":12}],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}]
})
path = File.tempname("flock_matnode", ".gltf")
File.write(path, json)

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.1, 0.9, 0.1))
File.delete(path) rescue nil

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 1.2f32, clear_color: Flock::Color::BLACK))
model = Flock::AnimatedModel.spawn(scene, world, Flock::Color.new(0.1, 0.9, 0.1))
model.apply(world)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target)
px = target.read

right = px.rgb(56, 32)[1]  # where x=+1.6 projects (quad expected here with the fix)
center = px.rgb(32, 32)[1] # x=0 (background with the fix; quad with the old TRS-only code)
puts "green: right(x=+1.6)=#{right}, center(x=0)=#{center}"
ok = right > 120 && center < 40 # quad shifted right by the node matrix

Flock.release_all(target, renderer, gpu)
puts ok ? "✅ glTF node matrix honored in the scene path OK" : "❌ node matrix ignored (TRS-only)"
exit(ok ? 0 : 1)
