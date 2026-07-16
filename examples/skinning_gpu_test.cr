# Headless readback test for glTF GPU skinning. A vertical bar is skinned to 2 joints:
# its bottom vertices follow the root joint (static), its top vertices follow a child
# joint that an animation rotates 90° about Z. Loaded via load_gltf_scene and driven by
# Flock::GpuSkinnedModel (skinning in the vertex shader; only joint matrices are
# uploaded per frame), the image at t=0 (straight) must differ substantially from t=1
# (bent) — matching the CPU-skinning result exactly.
#
#   crystal run examples/skinning_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128_u32
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

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(
  instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))
renderer = Flock::Renderer3D.new(gpu)

scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.3, 0.9, 0.4))
File.delete(path) rescue nil
raise "expected 1 skin" unless scene.skins.size == 1

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(0.0, 1.0, 4.5), target: Flock::Vec3.new(0.0, 1.0, 0.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
model = Flock::GpuSkinnedModel.spawn(scene, world, renderer, gpu)

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
row_bytes = SIZE * 4
buf_size = (row_bytes * SIZE).to_u64

snapshot = ->(t : Float32) do
  model.time = t
  model.apply
  renderer.render_into(world, target_view)
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
  bytes = Bytes.new(buf_size.to_i)
  bytes.copy_from(pixels, buf_size.to_i)
  LibWGPU.buffer_unmap(readback)
  LibWGPU.buffer_release(readback)
  bytes
end

img0 = snapshot.call(0.0f32)  # straight (bind pose)
img1 = snapshot.call(1.0f32)  # bent 90°

# Count green (lit) pixels and how many differ between the two poses.
def lit_count(b : Bytes)
  n = 0
  (0...(b.size // 4)).each { |i| n += 1 if b[i * 4].to_i + b[i * 4 + 1].to_i + b[i * 4 + 2].to_i > 40 }
  n
end

def changed(a : Bytes, b : Bytes)
  n = 0
  (0...(a.size // 4)).each do |i|
    o = i * 4
    d = (a[o].to_i - b[o].to_i).abs + (a[o + 1].to_i - b[o + 1].to_i).abs + (a[o + 2].to_i - b[o + 2].to_i).abs
    n += 1 if d > 40
  end
  n
end

l0 = lit_count(img0); l1 = lit_count(img1); ch = changed(img0, img1)
puts "lit@t0=#{l0}, lit@t1=#{l1}, changed pixels=#{ch}"
# Both poses render the bar, and skinning visibly deforms it (many pixels change).
ok = l0 > 200 && l1 > 200 && ch > 400

LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
renderer.release
gpu.release

puts ok ? "✅ glTF GPU skinning OK" : "❌ skinning did not deform the mesh as expected"
exit(ok ? 0 : 1)
