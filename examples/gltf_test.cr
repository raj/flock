# Headless readback test for glTF loading (Mesh.load_gltf). Builds a quad's binary
# buffer, wraps it BOTH as a `.gltf` (base64 data-URI) and a binary `.glb`, loads each,
# renders it lit, and asserts the quad shows at center while a corner stays background.
# Exercises the JSON/accessor/bufferView parsing, base64 + GLB container, index reading,
# and flat-normal computation (the quad has no NORMAL attribute).
#
#   crystal run examples/gltf_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128

# --- Build a quad's binary buffer: 4 positions (FLOAT VEC3) then 6 indices (USHORT). ---
bin_io = IO::Memory.new
[-0.6f32, -0.6f32, 0.0f32, 0.6f32, -0.6f32, 0.0f32,
 0.6f32, 0.6f32, 0.0f32, -0.6f32, 0.6f32, 0.0f32].each { |f| bin_io.write_bytes(f, IO::ByteFormat::LittleEndian) }
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| bin_io.write_bytes(i, IO::ByteFormat::LittleEndian) }
bin = bin_io.to_slice
b64 = Base64.strict_encode(bin)

VIEWS_ACC = <<-J
"bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":12}],
"accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},{"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}],
"meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}]
J

gltf_json = %({"asset":{"version":"2.0"},"buffers":[{"uri":"data:application/octet-stream;base64,#{b64}","byteLength":#{bin.size}}],#{VIEWS_ACC}})
glb_json = %({"asset":{"version":"2.0"},"buffers":[{"byteLength":#{bin.size}}],#{VIEWS_ACC}})

# --- Wrap glb_json + bin into a .glb container. ---
def build_glb(json : String, bin : Bytes) : Bytes
  jb = json.to_slice
  jpad = (4 - jb.size % 4) % 4
  bpad = (4 - bin.size % 4) % 4
  json_len = jb.size + jpad
  bin_len = bin.size + bpad
  total = 12 + 8 + json_len + 8 + bin_len
  io = IO::Memory.new
  le = IO::ByteFormat::LittleEndian
  io.write_bytes(0x46546C67_u32, le); io.write_bytes(2_u32, le); io.write_bytes(total.to_u32, le)
  io.write_bytes(json_len.to_u32, le); io.write_bytes(0x4E4F534A_u32, le)
  io.write(jb); jpad.times { io.write_byte(0x20_u8) }
  io.write_bytes(bin_len.to_u32, le); io.write_bytes(0x004E4942_u32, le)
  io.write(bin); bpad.times { io.write_byte(0x00_u8) }
  io.to_slice
end

gltf_path = File.tempname("flock_quad", ".gltf")
glb_path = File.tempname("flock_quad", ".glb")
File.write(gltf_path, gltf_json)
File.write(glb_path, build_glb(glb_json, bin))

# --- GPU + offscreen target. ---
gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

# Render `mesh` and read back {center, corner}.
render_sample = ->(mesh : Flock::Mesh) do
  world = Flock::World.new
  world.insert_resource(Flock::Time.new)
  world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), clear_color: Flock::Color::BLACK))
  e = world.spawn
  world.add(e, Flock::Transform3D.new)
  world.add(e, Flock::MeshRenderer.new(mesh))
  renderer.render_into(world, target.view)

  px = target.read
  center = px.rgb(64, 64)
  corner = px.rgb(2, 2)
  {center, corner}
end

gltf_mesh = Flock::Mesh.load_gltf(gpu, gltf_path, Flock::Color.new(0.9, 0.3, 0.8))
glb_mesh = Flock::Mesh.load_gltf(gpu, glb_path, Flock::Color.new(0.9, 0.3, 0.8))
File.delete(gltf_path) rescue nil
File.delete(glb_path) rescue nil

gltf_c, gltf_k = render_sample.call(gltf_mesh)
glb_c, glb_k = render_sample.call(glb_mesh)

puts ".gltf center = #{gltf_c}, corner = #{gltf_k}"
puts ".glb  center = #{glb_c}, corner = #{glb_k}"

lit = ->(c : Tuple(Int32, Int32, Int32)) { c[0].to_i + c[1].to_i + c[2].to_i > 60 && c[0] > 40 }
bg = ->(c : Tuple(Int32, Int32, Int32)) { c[0] < 20 && c[1] < 20 && c[2] < 20 }
ok = lit.call(gltf_c) && bg.call(gltf_k) && lit.call(glb_c) && bg.call(glb_k)

Flock.release_all(gltf_mesh, glb_mesh, target, renderer, gpu)

puts ok ? "✅ glTF loading OK (.gltf + .glb)" : "❌ glTF mesh not rendered as expected"
exit(ok ? 0 : 1)
