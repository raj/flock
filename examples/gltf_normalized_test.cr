# Regression test for normalized-integer glTF accessors. A single-joint (identity) skinned
# quad stores WEIGHTS_0 as NORMALIZED UNSIGNED_BYTE [255,0,0,0] — i.e. weight 1.0. Without
# de-normalization the shader sees weight 255, scaling every vertex 255x off-screen (center
# = black); with it, the quad renders normally (center = lit green). Common in optimized
# exports (Draco/gltfpack), so this path must work.
#
#   crystal run examples/gltf_normalized_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 64
LE = IO::ByteFormat::LittleEndian

io = IO::Memory.new
# POSITION (0,48): quad.
[-0.6f32, -0.6f32, 0.0f32, 0.6f32, -0.6f32, 0.0f32,
 0.6f32, 0.6f32, 0.0f32, -0.6f32, 0.6f32, 0.0f32].each { |f| io.write_bytes(f, LE) }
# JOINTS_0 (48,32) u16 vec4: joint 0.
16.times { io.write_bytes(0u16, LE) }
# WEIGHTS_0 (80,16) UNSIGNED_BYTE vec4, normalized: [255,0,0,0] == 1.0 after de-normalization.
4.times { io.write_byte(255u8); io.write_byte(0u8); io.write_byte(0u8); io.write_byte(0u8) }
# indices (96,12).
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| io.write_bytes(i, LE) }
# inverseBindMatrices (108,64): identity.
[1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32].each { |f| io.write_bytes(f, LE) }
buf = io.to_slice
uri = "data:application/octet-stream;base64,#{Base64.strict_encode(buf)}"

json = %({
  "asset":{"version":"2.0"},
  "scene":0,"scenes":[{"nodes":[0]}],
  "nodes":[{"mesh":0,"skin":0}],
  "skins":[{"joints":[0],"inverseBindMatrices":4}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0,"JOINTS_0":1,"WEIGHTS_0":2},"indices":3}]}],
  "buffers":[{"uri":"#{uri}","byteLength":#{buf.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},
    {"buffer":0,"byteOffset":48,"byteLength":32},
    {"buffer":0,"byteOffset":80,"byteLength":16},
    {"buffer":0,"byteOffset":96,"byteLength":12},
    {"buffer":0,"byteOffset":108,"byteLength":64}
  ],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5123,"count":4,"type":"VEC4"},
    {"bufferView":2,"componentType":5121,"normalized":true,"count":4,"type":"VEC4"},
    {"bufferView":3,"componentType":5123,"count":6,"type":"SCALAR"},
    {"bufferView":4,"componentType":5126,"count":1,"type":"MAT4"}
  ]
})
path = File.tempname("flock_norm", ".gltf")
File.write(path, json)

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.1, 0.9, 0.1))
File.delete(path) rescue nil

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

target.release
renderer.release; gpu.release

puts "center = #{center} (expect lit green; black => weight not de-normalized)"
ok = center[1] > 100 && center[1] > center[0] && center[1] > center[2]

puts ok ? "✅ normalized accessors OK" : "❌ normalized WEIGHTS_0 not de-normalized (mesh flew off-screen)"
exit(ok ? 0 : 1)
