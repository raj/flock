# Headless readback test for textured 3D meshes. A white cube is drawn with a solid
# BLUE 1x1 base-color texture (via Texture.from_pixels) assigned to MeshRenderer#texture;
# we assert the rendered center is blue (texture modulates the vertex color) — proving
# Renderer3D's UV attribute + group1 texture/sampler path works.
#
#   crystal run examples/texture3d_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(
  instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))
renderer = Flock::Renderer3D.new(gpu)

cube = Flock::Mesh.cube(gpu, Flock::Color::WHITE) # white vertices; texture provides color
blue = Flock::Texture.from_pixels(gpu, 1, 1, Bytes[0_u8, 0_u8, 255_u8, 255_u8])

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(cube, texture: blue))

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
ko = 2 * row_bytes.to_i + 2 * 4
corner = {pixels[ko], pixels[ko + 1], pixels[ko + 2]}
LibWGPU.buffer_unmap(readback)

puts "center = #{center}, corner = #{corner}"
ok = center[2] > 60 && center[2].to_i > center[0].to_i && # blue from the texture
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
blue.release
cube.release
renderer.release
gpu.release

puts ok ? "✅ textured 3D mesh OK" : "❌ 3D texture not sampled as expected"
exit(ok ? 0 : 1)
