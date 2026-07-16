# Headless test for glTF PBR extraction (Mesh.load_gltf_pbr): a glTF references a
# base-color, a metallic-roughness, and a normal texture (embedded BMP data-URIs) plus
# metallic/roughness factors. We assert all three maps are decoded, the factors are
# parsed, and the result renders (non-black center) through the PBR pipeline.
#
#   crystal run examples/gltf_pbr_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128_u32
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

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(
  instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))
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

tdesc = LibWGPU::TextureDescriptor.new
tdesc.label = WGPU.empty_string_view
tdesc.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::CopySrc
tdesc.dimension = LibWGPU::TextureDimension::N2D
tdesc.size = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
tdesc.format = LibWGPU::TextureFormat::RGBA8Unorm
tdesc.mip_level_count = 1_u32
tdesc.sample_count = 1_u32
target_tex = LibWGPU.device_create_texture(device, pointerof(tdesc))
target_view = LibWGPU.texture_create_view(target_tex, Pointer(LibWGPU::TextureViewDescriptor).null)
renderer.render_into(world, target_view)

row_bytes = SIZE * 4
buf_size = (row_bytes * SIZE).to_u64
bdesc = LibWGPU::BufferDescriptor.new
bdesc.label = WGPU.empty_string_view
bdesc.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
bdesc.size = buf_size
bdesc.mapped_at_creation = 0_u32
readback = LibWGPU.device_create_buffer(device, pointerof(bdesc))
src = LibWGPU::TexelCopyTextureInfo.new
src.texture = target_tex; src.mip_level = 0_u32
src.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32); src.aspect = LibWGPU::TextureAspect::All
lay = LibWGPU::TexelCopyBufferLayout.new
lay.offset = 0_u64; lay.bytes_per_row = row_bytes; lay.rows_per_image = SIZE
dst = LibWGPU::TexelCopyBufferInfo.new; dst.layout = lay; dst.buffer = readback
ext = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
edd = LibWGPU::CommandEncoderDescriptor.new; edd.label = WGPU.empty_string_view
enc = LibWGPU.device_create_command_encoder(device, pointerof(edd))
LibWGPU.command_encoder_copy_texture_to_buffer(enc, pointerof(src), pointerof(dst), pointerof(ext))
cdd = LibWGPU::CommandBufferDescriptor.new; cdd.label = WGPU.empty_string_view
cmd = LibWGPU.command_encoder_finish(enc, pointerof(cdd))
cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)
WGPU.map_buffer_read(instance, readback, buf_size)
pixels = LibWGPU.buffer_get_mapped_range(readback, 0_u64, buf_size).as(UInt8*)
co = 64 * row_bytes.to_i + 64 * 4
center = {pixels[co].to_i, pixels[co + 1].to_i, pixels[co + 2].to_i}
LibWGPU.buffer_unmap(readback)

puts "center = #{center}"
renders_ok = center[0] + center[1] + center[2] > 40 && center[1] > center[0] # greenish base
ok = maps_ok && factors_ok && renders_ok

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
pbr[:base_color].try &.release
pbr[:metallic_roughness].try &.release
pbr[:normal].try &.release
pbr[:mesh].release
renderer.release
gpu.release

puts ok ? "✅ glTF PBR maps + factors OK" : "❌ glTF PBR extraction not as expected"
exit(ok ? 0 : 1)
