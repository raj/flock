# Headless readback test for glTF morph targets (Flock::MorphModel). A quad sits on the
# LEFT; a single morph target displaces every vertex +1.2 in X, and a "weights" animation
# ramps the weight 0 -> 1 over 1s. At weight 0 the quad covers the left of the frame; at
# weight 1 the blended vertices move it to the right. Sampling a left and a right pixel at
# each weight proves the CPU vertex blend + weights animation work.
#
#   crystal run examples/morph_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128

bin = IO::Memory.new
le = IO::ByteFormat::LittleEndian
# POSITION base (4 verts, quad on the left: x in [-1.0, -0.2]).
[-1.0f32, -0.4f32, 0.0f32, -0.2f32, -0.4f32, 0.0f32,
 -0.2f32, 0.4f32, 0.0f32, -1.0f32, 0.4f32, 0.0f32].each { |f| bin.write_bytes(f, le) }
# indices (2 triangles).
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| bin.write_bytes(i, le) }
# morph target POSITION delta: +1.2 X for every vertex.
[1.2f32, 0.0f32, 0.0f32, 1.2f32, 0.0f32, 0.0f32,
 1.2f32, 0.0f32, 0.0f32, 1.2f32, 0.0f32, 0.0f32].each { |f| bin.write_bytes(f, le) }
# animation times + weights (0 -> 1 over 1s).
[0.0f32, 1.0f32].each { |f| bin.write_bytes(f, le) } # times
[0.0f32, 1.0f32].each { |f| bin.write_bytes(f, le) } # weights
data = bin.to_slice
b64 = Base64.strict_encode(data)

json = %({
  "asset":{"version":"2.0"},
  "scene":0,
  "scenes":[{"nodes":[0]}],
  "nodes":[{"mesh":0}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"targets":[{"POSITION":2}]}]}],
  "animations":[{"samplers":[{"input":3,"output":4,"interpolation":"LINEAR"}],
                 "channels":[{"sampler":0,"target":{"node":0,"path":"weights"}}]}],
  "buffers":[{"uri":"data:application/octet-stream;base64,#{b64}","byteLength":#{data.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},
    {"buffer":0,"byteOffset":48,"byteLength":12},
    {"buffer":0,"byteOffset":60,"byteLength":48},
    {"buffer":0,"byteOffset":108,"byteLength":8},
    {"buffer":0,"byteOffset":116,"byteLength":8}
  ],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"},
    {"bufferView":2,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":3,"componentType":5126,"count":2,"type":"SCALAR"},
    {"bufferView":4,"componentType":5126,"count":2,"type":"SCALAR"}
  ]
})

path = File.tempname("flock_morph", ".gltf")
File.write(path, json)

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.9, 0.9, 0.2))
File.delete(path) rescue nil
raise "no morph parts parsed" if scene.morphs.empty?

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
morph = Flock::MorphModel.spawn(scene, world, gpu)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

# Renders at morph time `t` and returns luminance at a left column and a right column.
render_lr = ->(t : Float32) do
  morph.time = t
  morph.apply(world)
  renderer.render_into(world, target.view)
  px = target.read
  lum = ->(x : Int32) {
    c = px.rgb(x, 64)
    c[0] + c[1] + c[2]
  }
  l = lum.call(36); r = lum.call(92)
  {l, r}
end

base_l, base_r = render_lr.call(0.0f32)     # weight 0 -> quad on the left
morph_l, morph_r = render_lr.call(1.0f32)   # weight 1 -> quad shifted right

Flock.release_all(target, renderer, gpu)

puts "weight 0: left=#{base_l} right=#{base_r}   weight 1: left=#{morph_l} right=#{morph_r}"
ok = base_l > 150 && base_r < 40 &&   # unmorphed: quad on the left
     morph_r > 150 && morph_l < 40    # morphed: quad moved to the right

puts ok ? "✅ glTF morph targets OK" : "❌ morph blend did not move the mesh as expected"
exit(ok ? 0 : 1)
