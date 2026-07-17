# Regression test for normalized-integer glTF accessors. A single-joint (identity) skinned
# quad stores WEIGHTS_0 as NORMALIZED UNSIGNED_BYTE [255,0,0,0] — i.e. weight 1.0. Without
# de-normalization the shader sees weight 255, scaling every vertex 255x off-screen (center
# = black); with it, the quad renders normally (center = lit green). Common in optimized
# exports (Draco/gltfpack), so this path must work.
#
#   crystal run examples/gltf_normalized_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 64_u32
LE = IO::ByteFormat::LittleEndian

io = IO::Memory.new
# POSITION (0,48): quad.
[-0.6f32, -0.6f32, 0.0f32, 0.6f32, -0.6f32, 0.0f32,
 0.6f32, 0.6f32, 0.0f32, -0.6f32, 0.6f32, 0.0f32].each { |f| io.write_bytes(f, LE) }
# JOINTS_0 (48,32) u16 vec4: joint 0.
16.times { io.write_bytes(0u16, LE) }
# WEIGHTS_0 (80,16) UNSIGNED_BYTE vec4, normalized: [255,0,0,0] == 1.0 after de-normalization.
4.times { io.write_byte(255u8); io.write_byte(0u8); io.write_byte(0u8); io.write_byte(0u8) }
# indices (96,12).
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| io.write_bytes(i, LE) }
# inverseBindMatrices (108,64): identity.
[1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32].each { |f| io.write_bytes(f, LE) }
buf = io.to_slice
uri = "data:application/octet-stream;base64,#{Base64.strict_encode(buf)}"

json = %({
  "asset":{"version":"2.0"},
  "scene":0,"scenes":[{"nodes":[0]}],
  "nodes":[{"mesh":0,"skin":0}],
  "skins":[{"joints":[0],"inverseBindMatrices":4}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0,"JOINTS_0":1,"WEIGHTS_0":2},"indices":3}]}],
  "buffers":[{"uri":"#{uri}","byteLength":#{buf.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},
    {"buffer":0,"byteOffset":48,"byteLength":32},
    {"buffer":0,"byteOffset":80,"byteLength":16},
    {"buffer":0,"byteOffset":96,"byteLength":12},
    {"buffer":0,"byteOffset":108,"byteLength":64}
  ],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5123,"count":4,"type":"VEC4"},
    {"bufferView":2,"componentType":5121,"normalized":true,"count":4,"type":"VEC4"},
    {"bufferView":3,"componentType":5123,"count":6,"type":"SCALAR"},
    {"bufferView":4,"componentType":5126,"count":1,"type":"MAT4"}
  ]
})
path = File.tempname("flock_norm", ".gltf")
File.write(path, json)

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.1, 0.9, 0.1))
File.delete(path) rescue nil

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 2.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
model = Flock::GpuSkinnedModel.spawn(scene, world, renderer, gpu)
model.apply

td = LibWGPU::TextureDescriptor.new
td.label = WGPU.empty_string_view
td.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::CopySrc
td.dimension = LibWGPU::TextureDimension::N2D
td.size = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
td.format = LibWGPU::TextureFormat::RGBA8Unorm
td.mip_level_count = 1_u32; td.sample_count = 1_u32
tt = LibWGPU.device_create_texture(device, pointerof(td))
tv = LibWGPU.texture_create_view(tt, Pointer(LibWGPU::TextureViewDescriptor).null)
renderer.render_into(world, tv)

rb = SIZE * 4
bs = (rb * SIZE).to_u64
bd = LibWGPU::BufferDescriptor.new
bd.label = WGPU.empty_string_view
bd.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
bd.size = bs; bd.mapped_at_creation = 0_u32
rbk = LibWGPU.device_create_buffer(device, pointerof(bd))
src = LibWGPU::TexelCopyTextureInfo.new
src.texture = tt; src.mip_level = 0_u32
src.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32); src.aspect = LibWGPU::TextureAspect::All
lay = LibWGPU::TexelCopyBufferLayout.new
lay.offset = 0_u64; lay.bytes_per_row = rb; lay.rows_per_image = SIZE
dst = LibWGPU::TexelCopyBufferInfo.new; dst.layout = lay; dst.buffer = rbk
ext = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
ec = LibWGPU::CommandEncoderDescriptor.new; ec.label = WGPU.empty_string_view
enc = LibWGPU.device_create_command_encoder(device, pointerof(ec))
LibWGPU.command_encoder_copy_texture_to_buffer(enc, pointerof(src), pointerof(dst), pointerof(ext))
cd = LibWGPU::CommandBufferDescriptor.new; cd.label = WGPU.empty_string_view
cmd = LibWGPU.command_encoder_finish(enc, pointerof(cd))
cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)
WGPU.map_buffer_read(instance, rbk, bs)
px = LibWGPU.buffer_get_mapped_range(rbk, 0_u64, bs).as(UInt8*)
o = 32 * rb.to_i + 32 * 4
center = {px[o].to_i, px[o + 1].to_i, px[o + 2].to_i}
LibWGPU.buffer_unmap(rbk)

LibWGPU.buffer_release(rbk); LibWGPU.texture_view_release(tv); LibWGPU.texture_release(tt)
renderer.release; gpu.release

puts "center = #{center} (expect lit green; black => weight not de-normalized)"
ok = center[1] > 100 && center[1] > center[0] && center[1] > center[2]

puts ok ? "✅ normalized accessors OK" : "❌ normalized WEIGHTS_0 not de-normalized (mesh flew off-screen)"
exit(ok ? 0 : 1)
