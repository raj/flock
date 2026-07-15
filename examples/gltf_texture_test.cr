# Headless readback test for glTF base-color TEXTURES. Builds a 2x2 green BMP, embeds
# it as a data-URI image referenced by a material's baseColorTexture, and a quad with
# TEXCOORD_0. `Mesh.load_gltf_textured` returns {mesh, texture}; rendered via
# MeshRenderer#texture, the quad must show green (from the embedded image), proving
# glTF texture extraction + Texture.from_encoded + the 3D texture pipeline.
#
#   crystal run examples/gltf_texture_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128_u32
LE = IO::ByteFormat::LittleEndian

# --- 2x2 green 24-bit BMP (bottom-up, rows padded to 4 bytes). ---
def build_bmp : Bytes
  w = 2; h = 2
  row = w * 3
  pad = (4 - row % 4) % 4
  pixels = row + pad
  img = pixels * h
  io = IO::Memory.new
  io.write("BM".to_slice)                 # signature
  io.write_bytes((54 + img).to_u32, LE)   # file size
  io.write_bytes(0_u32, LE)               # reserved
  io.write_bytes(54_u32, LE)              # pixel data offset
  io.write_bytes(40_u32, LE)              # DIB header size
  io.write_bytes(w.to_i32, LE); io.write_bytes(h.to_i32, LE)
  io.write_bytes(1_u16, LE); io.write_bytes(24_u16, LE) # planes, bpp
  io.write_bytes(0_u32, LE)               # no compression
  io.write_bytes(img.to_u32, LE)          # image size
  io.write_bytes(2835_i32, LE); io.write_bytes(2835_i32, LE) # ppm
  io.write_bytes(0_u32, LE); io.write_bytes(0_u32, LE)       # palette
  h.times do
    w.times { io.write_byte(0_u8); io.write_byte(255_u8); io.write_byte(0_u8) } # BGR = green
    pad.times { io.write_byte(0_u8) }
  end
  io.to_slice
end

bmp_uri = "data:image/bmp;base64,#{Base64.strict_encode(build_bmp)}"

# --- Geometry buffer: 4 positions (VEC3) + 4 uvs (VEC2) + 6 indices (USHORT). ---
gio = IO::Memory.new
[-0.6f32, -0.6f32, 0.0f32, 0.6f32, -0.6f32, 0.0f32,
 0.6f32, 0.6f32, 0.0f32, -0.6f32, 0.6f32, 0.0f32].each { |f| gio.write_bytes(f, LE) }
[0.0f32, 1.0f32, 1.0f32, 1.0f32, 1.0f32, 0.0f32, 0.0f32, 0.0f32].each { |f| gio.write_bytes(f, LE) }
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| gio.write_bytes(i, LE) }
geom = gio.to_slice
geom_uri = "data:application/octet-stream;base64,#{Base64.strict_encode(geom)}"

json = %({
  "asset":{"version":"2.0"},
  "images":[{"uri":"#{bmp_uri}"}],
  "textures":[{"source":0}],
  "materials":[{"pbrMetallicRoughness":{"baseColorTexture":{"index":0}}}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0,"TEXCOORD_0":1},"indices":2,"material":0}]}],
  "buffers":[{"uri":"#{geom_uri}","byteLength":#{geom.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},
    {"buffer":0,"byteOffset":48,"byteLength":32},
    {"buffer":0,"byteOffset":80,"byteLength":12}
  ],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5126,"count":4,"type":"VEC2"},
    {"bufferView":2,"componentType":5123,"count":6,"type":"SCALAR"}
  ]
})

path = File.tempname("flock_tex", ".gltf")
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

mesh, tex = Flock::Mesh.load_gltf_textured(gpu, path, Flock::Color.new(0.9, 0.1, 0.1))
File.delete(path) rescue nil
abort "expected a base-color texture" unless tex

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(mesh, texture: tex))

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
center = {pixels[co], pixels[co + 1], pixels[co + 2]}
LibWGPU.buffer_unmap(readback)

puts "center = #{center}"
# Green from the embedded texture (not the red fallback color).
ok = center[1] > 60 && center[1].to_i > center[0].to_i && center[1].to_i > center[2].to_i

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
tex.try &.release
mesh.release
renderer.release
gpu.release

puts ok ? "✅ glTF base-color texture OK" : "❌ glTF texture not applied as expected"
exit(ok ? 0 : 1)
