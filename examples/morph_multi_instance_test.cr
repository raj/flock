# Regression: two nodes instance the SAME morph mesh (a mesh with morph targets), placed
# left and right. Before the fix only ONE MorphPart was created (keyed per mesh, paired with
# the first node), so only the left quad rendered. Now one MorphPart is created per referencing
# node, each with its own vertex buffer — both quads must render.
#
#   crystal run examples/morph_multi_instance_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 64
LE = IO::ByteFormat::LittleEndian

io = IO::Memory.new
# POSITION (0,48): a small quad centered at the origin.
[-0.4f32, -0.4f32, 0.0f32, 0.4f32, -0.4f32, 0.0f32,
 0.4f32, 0.4f32, 0.0f32, -0.4f32, 0.4f32, 0.0f32].each { |f| io.write_bytes(f, LE) }
# indices (48,12).
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| io.write_bytes(i, LE) }
# morph target POSITION delta (60,48): all zero (we only need the mesh to BE a morph mesh).
12.times { io.write_bytes(0.0f32, LE) }
buf = io.to_slice
uri = "data:application/octet-stream;base64,#{Base64.strict_encode(buf)}"

# Two nodes reference mesh 0 (a morph mesh), one shifted left, one shifted right.
json = %({
  "asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0,1]}],
  "nodes":[{"mesh":0,"translation":[-1.2,0.0,0.0]},{"mesh":0,"translation":[1.2,0.0,0.0]}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"targets":[{"POSITION":2}]}]}],
  "buffers":[{"uri":"#{uri}","byteLength":#{buf.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},
    {"buffer":0,"byteOffset":48,"byteLength":12},
    {"buffer":0,"byteOffset":60,"byteLength":48}],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"},
    {"bufferView":2,"componentType":5126,"count":4,"type":"VEC3"}]
})
path = File.tempname("flock_morphinst", ".gltf")
File.write(path, json)

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.1, 0.9, 0.1))
File.delete(path) rescue nil
raise "expected 2 morph parts, got #{scene.morphs.size}" unless scene.morphs.size == 2

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 1.2f32, clear_color: Flock::Color::BLACK))
model = Flock::MorphModel.spawn(scene, world, gpu)
model.apply(world)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target)
px = target.read

left = px.rgb(18, 32)[1]   # left node (x=-1.2 projects near pixel 18)
right = px.rgb(46, 32)[1]  # right node (x=+1.2 near pixel 46) -> present only if the 2nd instance spawned
center = px.rgb(32, 32)[1] # background between them
puts "green: left=#{left}, right=#{right}, center=#{center}"
ok = left > 120 && right > 120 && center < 40 # BOTH instances rendered

Flock.release_all(target, renderer, gpu)
puts ok ? "✅ multiple instances of one morph mesh OK" : "❌ second morph instance missing"
exit(ok ? 0 : 1)
