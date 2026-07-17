# Headless readback test for vertex colors on skinned meshes (glTF COLOR_0). A single-joint
# skinned quad carries a GREEN COLOR_0; load_gltf_scene is given a RED fallback color. If
# per-vertex colors flow through the skinning path, the rendered quad reads green (not red).
#
#   crystal run examples/skinned_color_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 64
LE = IO::ByteFormat::LittleEndian

io = IO::Memory.new
# POSITION (0, 48): a quad.
[-0.6f32, -0.6f32, 0.0f32, 0.6f32, -0.6f32, 0.0f32,
 0.6f32, 0.6f32, 0.0f32, -0.6f32, 0.6f32, 0.0f32].each { |f| io.write_bytes(f, LE) }
# COLOR_0 (48, 48) VEC3: green.
4.times { io.write_bytes(0.0f32, LE); io.write_bytes(1.0f32, LE); io.write_bytes(0.0f32, LE) }
# JOINTS_0 (96, 32) u16 vec4: joint 0.
16.times { io.write_bytes(0u16, LE) }
# WEIGHTS_0 (128, 64) f32 vec4: [1,0,0,0].
4.times { io.write_bytes(1.0f32, LE); io.write_bytes(0.0f32, LE); io.write_bytes(0.0f32, LE); io.write_bytes(0.0f32, LE) }
# indices (192, 12).
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| io.write_bytes(i, LE) }
# inverseBindMatrices (204, 64) MAT4: identity.
[1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32].each { |f| io.write_bytes(f, LE) }
buf = io.to_slice
uri = "data:application/octet-stream;base64,#{Base64.strict_encode(buf)}"

json = %({
  "asset":{"version":"2.0"},
  "scene":0,
  "scenes":[{"nodes":[0]}],
  "nodes":[{"mesh":0,"skin":0}],
  "skins":[{"joints":[0],"inverseBindMatrices":5}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0,"COLOR_0":1,"JOINTS_0":2,"WEIGHTS_0":3},"indices":4}]}],
  "buffers":[{"uri":"#{uri}","byteLength":#{buf.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},
    {"buffer":0,"byteOffset":48,"byteLength":48},
    {"buffer":0,"byteOffset":96,"byteLength":32},
    {"buffer":0,"byteOffset":128,"byteLength":64},
    {"buffer":0,"byteOffset":192,"byteLength":12},
    {"buffer":0,"byteOffset":204,"byteLength":64}
  ],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":2,"componentType":5123,"count":4,"type":"VEC4"},
    {"bufferView":3,"componentType":5126,"count":4,"type":"VEC4"},
    {"bufferView":4,"componentType":5123,"count":6,"type":"SCALAR"},
    {"bufferView":5,"componentType":5126,"count":1,"type":"MAT4"}
  ]
})

path = File.tempname("flock_skincol", ".gltf")
File.write(path, json)

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

# RED fallback — the green COLOR_0 must override it if vertex colors flow through skinning.
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.9, 0.1, 0.1))
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

Flock.release_all(target, renderer, gpu)

puts "skinned quad center = #{center} (expect green, not the red fallback)"
ok = center[1] > 150 && center[1] > center[0] * 2 && center[1] > center[2] * 2

puts ok ? "✅ vertex colors on skinned meshes OK" : "❌ COLOR_0 did not reach the skinned mesh"
exit(ok ? 0 : 1)
