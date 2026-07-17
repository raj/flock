# Multi-viewport / per-region clear test (headless, readback).
#
# Two Camera2D with side-by-side viewports and distinct clear colors. Reads the
# offscreen result back and asserts the left half is red and the right half blue —
# proving each viewport clears its own region.
#
#   crystal run examples/split_screen_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32
HALF = (SIZE // 2)

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer2D.new(gpu)

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(
  viewport: Flock::Viewport.new(0.0f32, 0.0f32, HALF.to_f32, SIZE.to_f32),
  clear_color: Flock::Color::RED, order: 0))
world.add(world.spawn, Flock::Camera2D.new(
  viewport: Flock::Viewport.new(HALF.to_f32, 0.0f32, HALF.to_f32, SIZE.to_f32),
  clear_color: Flock::Color::BLUE, order: 1))

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
src.texture = target_tex
src.mip_level = 0_u32
src.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32)
src.aspect = LibWGPU::TextureAspect::All
layout = LibWGPU::TexelCopyBufferLayout.new
layout.offset = 0_u64
layout.bytes_per_row = row_bytes
layout.rows_per_image = SIZE
dst = LibWGPU::TexelCopyBufferInfo.new
dst.layout = layout
dst.buffer = readback
ext = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)

enc_desc = LibWGPU::CommandEncoderDescriptor.new
enc_desc.label = WGPU.empty_string_view
encoder = LibWGPU.device_create_command_encoder(device, pointerof(enc_desc))
LibWGPU.command_encoder_copy_texture_to_buffer(encoder, pointerof(src), pointerof(dst), pointerof(ext))
cmd_desc = LibWGPU::CommandBufferDescriptor.new
cmd_desc.label = WGPU.empty_string_view
cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)

WGPU.map_buffer_read(instance, readback, buf_size)
pixels = LibWGPU.buffer_get_mapped_range(readback, 0_u64, buf_size).as(UInt8*)

def px(pixels : UInt8*, x : Int, y : Int, row_bytes : UInt32)
  o = y * row_bytes.to_i + x * 4
  {pixels[o], pixels[o + 1], pixels[o + 2]}
end

left = px(pixels, (HALF // 2).to_i, (SIZE // 2).to_i, row_bytes)
right = px(pixels, (HALF + HALF // 2).to_i, (SIZE // 2).to_i, row_bytes)
LibWGPU.buffer_unmap(readback)

puts "left half  = #{left}"
puts "right half = #{right}"

ok = left[0] > 200 && left[2] < 60 &&  # left red
     right[2] > 200 && right[0] < 60   # right blue

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
renderer.release
gpu.release

puts ok ? "✅ per-region clear (split-screen) OK" : "❌ regions not cleared as expected"
exit(ok ? 0 : 1)
