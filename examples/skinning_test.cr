# Headless readback test for glTF skinning (CPU). A vertical bar is skinned to 2 joints:
# its bottom vertices follow the root joint (static), its top vertices follow a child
# joint that an animation rotates 90° about Z. Loaded via load_gltf_scene and driven by
# Flock::SkinnedModel, the rendered image at t=0 (straight) must differ substantially
# from t=1 (bent) — proving the mesh is deformed by the joint hierarchy on the CPU.
#
#   crystal run examples/skinning_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128
LE = IO::ByteFormat::LittleEndian

io = IO::Memory.new
# positions (0, 48): a thin vertical bar, y 0..2
[-0.2f32, 0.0f32, 0.0f32, 0.2f32, 0.0f32, 0.0f32,
 0.2f32, 2.0f32, 0.0f32, -0.2f32, 2.0f32, 0.0f32].each { |f| io.write_bytes(f, LE) }
# JOINTS_0 (48, 32) UNSIGNED_SHORT vec4: bottom verts -> joint 0, top verts -> joint 1
[0u16, 0u16, 0u16, 0u16, 0u16, 0u16, 0u16, 0u16,
 1u16, 0u16, 0u16, 0u16, 1u16, 0u16, 0u16, 0u16].each { |v| io.write_bytes(v, LE) }
# WEIGHTS_0 (80, 64) FLOAT vec4: full weight on the first joint slot
4.times { io.write_bytes(1.0f32, LE); io.write_bytes(0.0f32, LE); io.write_bytes(0.0f32, LE); io.write_bytes(0.0f32, LE) }
# indices (144, 12)
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| io.write_bytes(i, LE) }
# inverseBindMatrices (156, 128): joint0 identity, joint1 translate(0,-1,0) (column-major)
[1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32].each { |f| io.write_bytes(f, LE) }
[1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, -1f32, 0f32, 1f32].each { |f| io.write_bytes(f, LE) }
# anim times (284, 8)
[0.0f32, 1.0f32].each { |f| io.write_bytes(f, LE) }
# anim rotations (292, 32): identity, then 90° about Z (quat 0,0,sin45,cos45)
[0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0.70710677f32, 0.70710677f32].each { |f| io.write_bytes(f, LE) }
buf = io.to_slice
uri = "data:application/octet-stream;base64,#{Base64.strict_encode(buf)}"

json = %({
  "asset":{"version":"2.0"},
  "scene":0,
  "scenes":[{"nodes":[0,2]}],
  "nodes":[
    {"translation":[0,0,0],"children":[1]},
    {"translation":[0,1,0]},
    {"mesh":0,"skin":0}
  ],
  "skins":[{"joints":[0,1],"inverseBindMatrices":4}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0,"JOINTS_0":1,"WEIGHTS_0":2},"indices":3}]}],
  "animations":[{"samplers":[{"input":5,"output":6,"interpolation":"LINEAR"}],
                 "channels":[{"sampler":0,"target":{"node":1,"path":"rotation"}}]}],
  "buffers":[{"uri":"#{uri}","byteLength":#{buf.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},
    {"buffer":0,"byteOffset":48,"byteLength":32},
    {"buffer":0,"byteOffset":80,"byteLength":64},
    {"buffer":0,"byteOffset":144,"byteLength":12},
    {"buffer":0,"byteOffset":156,"byteLength":128},
    {"buffer":0,"byteOffset":284,"byteLength":8},
    {"buffer":0,"byteOffset":292,"byteLength":32}
  ],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5123,"count":4,"type":"VEC4"},
    {"bufferView":2,"componentType":5126,"count":4,"type":"VEC4"},
    {"bufferView":3,"componentType":5123,"count":6,"type":"SCALAR"},
    {"bufferView":4,"componentType":5126,"count":2,"type":"MAT4"},
    {"bufferView":5,"componentType":5126,"count":2,"type":"SCALAR"},
    {"bufferView":6,"componentType":5126,"count":2,"type":"VEC4"}
  ]
})

path = File.tempname("flock_skin", ".gltf")
File.write(path, json)

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.3, 0.9, 0.4))
File.delete(path) rescue nil
raise "expected 1 skin" unless scene.skins.size == 1

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(0.0, 1.0, 4.5), target: Flock::Vec3.new(0.0, 1.0, 0.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
model = Flock::SkinnedModel.spawn(scene, world, gpu)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

snapshot = ->(t : Float32) do
  model.time = t
  model.apply
  renderer.render_into(world, target.view)
  target.read
end

img0 = snapshot.call(0.0f32)  # straight (bind pose)
img1 = snapshot.call(1.0f32)  # bent 90°

# Count green (lit) pixels and how many differ between the two poses.
def lit_count(px : Flock::Pixels)
  n = 0
  px.height.times do |y|
    px.width.times do |x|
      r, g, b = px.rgb(x, y)
      n += 1 if r + g + b > 40
    end
  end
  n
end

def changed(a : Flock::Pixels, b : Flock::Pixels)
  n = 0
  a.height.times do |y|
    a.width.times do |x|
      ar, ag, ab = a.rgb(x, y)
      br, bg, bb = b.rgb(x, y)
      d = (ar - br).abs + (ag - bg).abs + (ab - bb).abs
      n += 1 if d > 40
    end
  end
  n
end

l0 = lit_count(img0); l1 = lit_count(img1); ch = changed(img0, img1)
puts "lit@t0=#{l0}, lit@t1=#{l1}, changed pixels=#{ch}"
# Both poses render the bar, and skinning visibly deforms it (many pixels change).
ok = l0 > 200 && l1 > 200 && ch > 400

target.release
renderer.release
gpu.release

puts ok ? "✅ glTF skinning (CPU) OK" : "❌ skinning did not deform the mesh as expected"
exit(ok ? 0 : 1)
