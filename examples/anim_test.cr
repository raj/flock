# Headless readback test for glTF node animation. A quad's node has a translation
# animation from x=-1.2 (t=0) to x=+1.2 (t=1). Loaded as a scene and driven by
# Flock::AnimatedModel: at t=0 the quad sits left (center empty); at t=0.5 the sampled
# translation is 0 so it sits at the center. Proves keyframe sampling + node posing.
#
#   crystal run examples/anim_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128
LE = IO::ByteFormat::LittleEndian

io = IO::Memory.new
# positions (offset 0, 48B): a small centered quad
[-0.4f32, -0.4f32, 0.0f32, 0.4f32, -0.4f32, 0.0f32,
 0.4f32, 0.4f32, 0.0f32, -0.4f32, 0.4f32, 0.0f32].each { |f| io.write_bytes(f, LE) }
# indices (offset 48, 12B)
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| io.write_bytes(i, LE) }
# anim input times (offset 60, 8B)
[0.0f32, 1.0f32].each { |f| io.write_bytes(f, LE) }
# anim output translations (offset 68, 24B): x from -1.2 to +1.2
[-1.2f32, 0.0f32, 0.0f32, 1.2f32, 0.0f32, 0.0f32].each { |f| io.write_bytes(f, LE) }
buf = io.to_slice
uri = "data:application/octet-stream;base64,#{Base64.strict_encode(buf)}"

json = %({
  "asset":{"version":"2.0"},
  "scene":0,
  "scenes":[{"nodes":[0]}],
  "nodes":[{"mesh":0,"translation":[-1.2,0.0,0.0]}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
  "animations":[{"samplers":[{"input":2,"output":3,"interpolation":"LINEAR"}],
                 "channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}]}],
  "buffers":[{"uri":"#{uri}","byteLength":#{buf.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},
    {"buffer":0,"byteOffset":48,"byteLength":12},
    {"buffer":0,"byteOffset":60,"byteLength":8},
    {"buffer":0,"byteOffset":68,"byteLength":24}
  ],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"},
    {"bufferView":2,"componentType":5126,"count":2,"type":"SCALAR"},
    {"bufferView":3,"componentType":5126,"count":2,"type":"VEC3"}
  ]
})

path = File.tempname("flock_anim", ".gltf")
File.write(path, json)

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.3, 0.9, 0.4))
File.delete(path) rescue nil
raise "expected 1 animation" unless scene.animations.size == 1
raise "expected duration ~1s" unless (scene.animations[0].duration - 1.0f32).abs < 1e-4

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
model = Flock::AnimatedModel.spawn(scene, world)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

center_at = ->(t : Float32) do
  model.time = t
  model.apply(world)
  renderer.render_into(world, target.view)
  target.read.rgb(64, 64)
end

start = center_at.call(0.0f32)  # quad at x=-1.2 -> center empty
mid = center_at.call(0.5f32)    # translation sampled to 0 -> center has quad

puts "center@t=0 = #{start} (expect empty), center@t=0.5 = #{mid} (expect green)"
ok = (start[0] + start[1] + start[2] < 30) &&              # empty at start
     (mid[1] > 60 && mid[1] > mid[0] && mid[1] > mid[2])   # green quad centered

target.release
renderer.release
gpu.release

puts ok ? "✅ glTF node animation OK" : "❌ animation sampling not as expected"
exit(ok ? 0 : 1)
