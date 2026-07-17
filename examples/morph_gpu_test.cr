# Headless readback test for glTF GPU morph targets (Flock::GpuMorphModel). A quad sits on the
# LEFT; a single morph target displaces every vertex +1.2 in X, and a "weights" animation
# ramps the weight 0 -> 1 over 1s. At weight 0 the quad covers the left of the frame; at
# weight 1 the blended vertices move it to the right. Sampling a left and a right pixel at
# each weight proves the GPU vertex blend + weights animation work.
#
#   crystal run examples/morph_gpu_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128_u32

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

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))
renderer = Flock::Renderer3D.new(gpu)

scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.9, 0.9, 0.2))
File.delete(path) rescue nil
raise "no morph parts parsed" if scene.morphs.empty?

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
morph = Flock::GpuMorphModel.spawn(scene, world, renderer, gpu)

td = LibWGPU::TextureDescriptor.new
td.label = WGPU.empty_string_view
td.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::CopySrc
td.dimension = LibWGPU::TextureDimension::N2D
td.size = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
td.format = LibWGPU::TextureFormat::RGBA8Unorm
td.mip_level_count = 1_u32; td.sample_count = 1_u32
tt = LibWGPU.device_create_texture(device, pointerof(td))
tv = LibWGPU.texture_create_view(tt, Pointer(LibWGPU::TextureViewDescriptor).null)

rb = SIZE * 4
bs = (rb * SIZE).to_u64
bdesc = LibWGPU::BufferDescriptor.new
bdesc.label = WGPU.empty_string_view
bdesc.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
bdesc.size = bs; bdesc.mapped_at_creation = 0_u32
readback = LibWGPU.device_create_buffer(device, pointerof(bdesc))

# Renders at morph time `t` and returns luminance at a left column and a right column.
render_lr = ->(t : Float32) do
  morph.time = t
  morph.apply
  renderer.render_into(world, tv)
  src = LibWGPU::TexelCopyTextureInfo.new
  src.texture = tt; src.mip_level = 0_u32
  src.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32); src.aspect = LibWGPU::TextureAspect::All
  lay = LibWGPU::TexelCopyBufferLayout.new
  lay.offset = 0_u64; lay.bytes_per_row = rb; lay.rows_per_image = SIZE
  dst = LibWGPU::TexelCopyBufferInfo.new; dst.layout = lay; dst.buffer = readback
  ext = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
  ed = LibWGPU::CommandEncoderDescriptor.new; ed.label = WGPU.empty_string_view
  enc = LibWGPU.device_create_command_encoder(device, pointerof(ed))
  LibWGPU.command_encoder_copy_texture_to_buffer(enc, pointerof(src), pointerof(dst), pointerof(ext))
  cd = LibWGPU::CommandBufferDescriptor.new; cd.label = WGPU.empty_string_view
  cmd = LibWGPU.command_encoder_finish(enc, pointerof(cd))
  cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
  LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)
  WGPU.map_buffer_read(instance, readback, bs)
  px = LibWGPU.buffer_get_mapped_range(readback, 0_u64, bs).as(UInt8*)
  lum = ->(x : Int32) {
    o = 64 * rb.to_i + x * 4
    px[o].to_i + px[o + 1].to_i + px[o + 2].to_i
  }
  l = lum.call(36); r = lum.call(92)
  LibWGPU.buffer_unmap(readback)
  {l, r}
end

base_l, base_r = render_lr.call(0.0f32)     # weight 0 -> quad on the left
morph_l, morph_r = render_lr.call(1.0f32)   # weight 1 -> quad shifted right

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(tv); LibWGPU.texture_release(tt)
renderer.release; gpu.release

puts "weight 0: left=#{base_l} right=#{base_r}   weight 1: left=#{morph_l} right=#{morph_r}"
ok = base_l > 150 && base_r < 40 &&   # unmorphed: quad on the left
     morph_r > 150 && morph_l < 40    # morphed: quad moved to the right

puts ok ? "✅ glTF GPU morph targets OK" : "❌ morph blend did not move the mesh as expected"
exit(ok ? 0 : 1)
