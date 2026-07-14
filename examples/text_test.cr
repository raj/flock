# Text rendering test (headless, readback).
#
# Renders "HI" via SDL_ttf into a texture, draws it as a sprite into an offscreen
# target, reads back the pixels and checks that text pixels (bright) exist.
#
#   crystal run examples/text_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32
FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(
  instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))

renderer = Flock::Renderer2D.new(gpu)

# --- Text -> texture ---
font = Flock::Font.load(FONT, 48)
text_tex = font.render_texture(gpu, "HI")
puts "text texture: #{text_tex.width}x#{text_tex.height}"

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
world.add(e, Flock::Sprite.new(Flock::Vec2.new(text_tex.width, text_tex.height), Flock::Color::WHITE, text_tex))

# --- Offscreen target + render ---
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

# --- Readback ---
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

# Count the bright pixels (white glyphs on a black background).
bright = 0
(SIZE * SIZE).times do |i|
  o = i.to_i * 4
  bright += 1 if pixels[o] > 60 || pixels[o + 1] > 60 || pixels[o + 2] > 60
end
LibWGPU.buffer_unmap(readback)

puts "bright pixels (text) = #{bright}"

# Cleanup
LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
text_tex.release
font.release
renderer.release
gpu.release

if bright > 20
  puts "✅ text rendering OK"
  exit 0
else
  puts "❌ no text pixels detected"
  exit 1
end
