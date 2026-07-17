# Headless readback test for glTF enrichment: NODE TRANSFORMS + MATERIAL base color.
# A quad mesh is placed by a node whose translation shifts it left of the origin, and
# its primitive references a blue material (baseColorFactor). We pass a RED fallback
# color to load_gltf, then assert the rendered quad is (a) left of center — proving the
# node transform was baked — and (b) blue, not red — proving the material color wins.
#
#   crystal run examples/gltf_nodes_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128_u32

bin_io = IO::Memory.new
[-0.4f32, -0.4f32, 0.0f32, 0.4f32, -0.4f32, 0.0f32,
 0.4f32, 0.4f32, 0.0f32, -0.4f32, 0.4f32, 0.0f32].each { |f| bin_io.write_bytes(f, IO::ByteFormat::LittleEndian) }
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| bin_io.write_bytes(i, IO::ByteFormat::LittleEndian) }
bin = bin_io.to_slice
b64 = Base64.strict_encode(bin)

json = %({
  "asset":{"version":"2.0"},
  "scene":0,
  "scenes":[{"nodes":[0]}],
  "nodes":[{"mesh":0,"translation":[-1.2,0.0,0.0]}],
  "materials":[{"pbrMetallicRoughness":{"baseColorFactor":[0.2,0.4,0.9,1.0]}}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1,"material":0}]}],
  "buffers":[{"uri":"data:application/octet-stream;base64,#{b64}","byteLength":#{bin.size}}],
  "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":12}],
  "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},{"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}]
})

path = File.tempname("flock_nodes", ".gltf")
File.write(path, json)

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

# RED fallback — the blue material must override it.
mesh = Flock::Mesh.load_gltf(gpu, path, Flock::Color.new(0.9, 0.1, 0.1))
File.delete(path) rescue nil

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(mesh))

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
ed = LibWGPU::CommandEncoderDescriptor.new; ed.label = WGPU.empty_string_view
enc = LibWGPU.device_create_command_encoder(device, pointerof(ed))
LibWGPU.command_encoder_copy_texture_to_buffer(enc, pointerof(src), pointerof(dst), pointerof(ext))
cd = LibWGPU::CommandBufferDescriptor.new; cd.label = WGPU.empty_string_view
cmd = LibWGPU.command_encoder_finish(enc, pointerof(cd))
cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)
WGPU.map_buffer_read(instance, readback, buf_size)
pixels = LibWGPU.buffer_get_mapped_range(readback, 0_u64, buf_size).as(UInt8*)

def px(pixels : UInt8*, x : Int, y : Int, row_bytes : UInt32)
  o = y * row_bytes.to_i + x * 4
  {pixels[o], pixels[o + 1], pixels[o + 2]}
end

left = px(pixels, 15, 64, row_bytes)     # where the node-translated quad lands
center = px(pixels, 64, 64, row_bytes)    # empty (quad moved left)
corner = px(pixels, 120, 120, row_bytes)
LibWGPU.buffer_unmap(readback)

puts "left(quad)  = #{left}"
puts "center      = #{center}"
puts "corner      = #{corner}"

ok = left[2] > 60 && left[2].to_i > left[0].to_i && # quad is blue (material), not red (fallback)
     center[0] < 20 && center[1] < 20 && center[2] < 20 && # node shifted it away from center
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
mesh.release
renderer.release
gpu.release

puts ok ? "✅ glTF node transforms + material color OK" : "❌ node/material enrichment not as expected"
exit(ok ? 0 : 1)
