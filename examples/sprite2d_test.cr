# Readback test for the backend-agnostic Sprite2D on the native renderer: registers a
# green texture in Renderer2D's bank and draws a Sprite2D that references it by id; the
# center must read green (texture-bank resolution), the corner black.
#
#   crystal run examples/sprite2d_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64_u32

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(
  instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))

renderer = Flock::Renderer2D.new(gpu)
green = renderer.register_texture(Flock::Texture.from_pixels(gpu, 1, 1, Bytes[0_u8, 255_u8, 0_u8, 255_u8]))

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
world.add(e, Flock::Sprite2D.new(Flock::Vec2.new(40, 40), Flock::Color::WHITE, green))

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

renderer.render_into(target_view, SIZE, SIZE, world)

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
layout = LibWGPU::TexelCopyBufferLayout.new
layout.offset = 0_u64; layout.bytes_per_row = row_bytes; layout.rows_per_image = SIZE
dst = LibWGPU::TexelCopyBufferInfo.new; dst.layout = layout; dst.buffer = readback
ext = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
enc_desc = LibWGPU::CommandEncoderDescriptor.new; enc_desc.label = WGPU.empty_string_view
encoder = LibWGPU.device_create_command_encoder(device, pointerof(enc_desc))
LibWGPU.command_encoder_copy_texture_to_buffer(encoder, pointerof(src), pointerof(dst), pointerof(ext))
cmd_desc = LibWGPU::CommandBufferDescriptor.new; cmd_desc.label = WGPU.empty_string_view
cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)

WGPU.map_buffer_read(instance, readback, buf_size)
pixels = LibWGPU.buffer_get_mapped_range(readback, 0_u64, buf_size).as(UInt8*)

def px(pixels : UInt8*, x : Int, y : Int, row_bytes : UInt32)
  o = y * row_bytes.to_i + x * 4
  {pixels[o], pixels[o + 1], pixels[o + 2]}
end

cx = (SIZE // 2).to_i
center = px(pixels, cx, cx, row_bytes)
corner = px(pixels, 2, 2, row_bytes)
LibWGPU.buffer_unmap(readback)

puts "center = #{center}, corner = #{corner}"
ok = center[1] > 200 && center[0] < 60 && center[2] < 60 && # green center (from the bank texture)
     corner[0] < 60 && corner[1] < 60 && corner[2] < 60      # black corner

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
renderer.release
gpu.release

puts ok ? "✅ native Sprite2D (shared component) OK" : "❌ Sprite2D not rendered as expected"
exit(ok ? 0 : 1)
