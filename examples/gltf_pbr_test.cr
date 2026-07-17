# Headless test for glTF PBR extraction (Mesh.load_gltf_pbr): a glTF references a
# base-color, a metallic-roughness, and a normal texture (embedded BMP data-URIs) plus
# metallic/roughness factors. We assert all three maps are decoded, the factors are
# parsed, and the result renders (non-black center) through the PBR pipeline.
#
#   crystal run examples/gltf_pbr_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128
LE = IO::ByteFormat::LittleEndian

def bmp(r : UInt8, g : UInt8, b : UInt8) : String
  io = IO::Memory.new
  img = 8 * 2 # 2px*3 + 2 pad, 2 rows
  io.write("BM".to_slice)
  io.write_bytes((54 + img).to_u32, LE); io.write_bytes(0_u32, LE); io.write_bytes(54_u32, LE)
  io.write_bytes(40_u32, LE); io.write_bytes(2_i32, LE); io.write_bytes(2_i32, LE)
  io.write_bytes(1_u16, LE); io.write_bytes(24_u16, LE); io.write_bytes(0_u32, LE)
  io.write_bytes(img.to_u32, LE); io.write_bytes(2835_i32, LE); io.write_bytes(2835_i32, LE)
  io.write_bytes(0_u32, LE); io.write_bytes(0_u32, LE)
  2.times do
    2.times { io.write_byte(b); io.write_byte(g); io.write_byte(r) } # BGR
    2.times { io.write_byte(0_u8) }
  end
  "data:image/bmp;base64,#{Base64.strict_encode(io.to_slice)}"
end

gio = IO::Memory.new
[-0.6f32, -0.6f32, 0.0f32, 0.6f32, -0.6f32, 0.0f32,
 0.6f32, 0.6f32, 0.0f32, -0.6f32, 0.6f32, 0.0f32].each { |f| gio.write_bytes(f, LE) }
[0.0f32, 1.0f32, 1.0f32, 1.0f32, 1.0f32, 0.0f32, 0.0f32, 0.0f32].each { |f| gio.write_bytes(f, LE) }
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| gio.write_bytes(i, LE) }
geom = gio.to_slice
geom_uri = "data:application/octet-stream;base64,#{Base64.strict_encode(geom)}"

json = %({
  "asset":{"version":"2.0"},
  "images":[{"uri":"#{bmp(60u8, 200u8, 90u8)}"},{"uri":"#{bmp(0u8, 180u8, 40u8)}"},{"uri":"#{bmp(128u8, 128u8, 255u8)}"}],
  "textures":[{"source":0},{"source":1},{"source":2}],
  "materials":[{
    "pbrMetallicRoughness":{"baseColorTexture":{"index":0},"metallicRoughnessTexture":{"index":1},"metallicFactor":0.25,"roughnessFactor":0.75},
    "normalTexture":{"index":2}
  }],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"indices":2,"material":0}]}],
  "buffers":[{"uri":"#{geom_uri}","byteLength":#{geom.size}}],
  "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":32},{"buffer":0,"byteOffset":80,"byteLength":12}],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5126,"count":4,"type":"VEC2"},
    {"bufferView":2,"componentType":5123,"count":6,"type":"SCALAR"}
  ]
})

path = File.tempname("flock_pbr", ".gltf")
File.write(path, json)

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

pbr = Flock::Mesh.load_gltf_pbr(gpu, path, Flock::Color::WHITE)
File.delete(path) rescue nil

maps_ok = !pbr[:base_color].nil? && !pbr[:metallic_roughness].nil? && !pbr[:normal].nil?
factors_ok = (pbr[:metallic] - 0.25f32).abs < 1e-4 && (pbr[:roughness] - 0.75f32).abs < 1e-4
puts "maps: base=#{!pbr[:base_color].nil?} mr=#{!pbr[:metallic_roughness].nil?} normal=#{!pbr[:normal].nil?}"
puts "factors: metallic=#{pbr[:metallic]} roughness=#{pbr[:roughness]}"

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(pbr[:mesh], texture: pbr[:base_color],
  metallic_roughness: pbr[:metallic_roughness], normal_map: pbr[:normal],
  metallic: pbr[:metallic], roughness: pbr[:roughness]))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)

px = target.read
center = px.rgb(64, 64)

puts "center = #{center}"
renders_ok = center[0] + center[1] + center[2] > 40 && center[1] > center[0] # greenish base
ok = maps_ok && factors_ok && renders_ok

target.release
pbr[:base_color].try &.release
pbr[:metallic_roughness].try &.release
pbr[:normal].try &.release
pbr[:mesh].release
Flock.release_all(renderer, gpu)

puts ok ? "✅ glTF PBR maps + factors OK" : "❌ glTF PBR extraction not as expected"
exit(ok ? 0 : 1)
