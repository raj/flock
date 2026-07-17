# Readback rendering test (headless, no window).
#
# Renders a red sprite on a black background into an offscreen texture, copies the
# texture to a buffer, maps it, and checks the pixel colors (center = red, corner
# = black). Reusable base for automated GPU tests.
#
#   crystal run examples/readback_test.cr   # exit 0 if OK, 1 otherwise
require "../src/flock/gpu"

SIZE = 64_u32 # 64*4 = 256 bytes/row (already aligned for copy_texture_to_buffer)

# --- Headless GPU context (no surface/window) ---
gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer2D.new(gpu)

# --- Scene: camera (black clear) + red 40x40 sprite at center ---
world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
world.add(e, Flock::Sprite.new(Flock::Vec2.new(40, 40), Flock::Color::RED))

# --- Offscreen target (RGBA8, renderable + copyable) ---
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

# --- Render ---
renderer.render_into(target_view, SIZE, SIZE, world)

# --- Copy texture -> buffer ---
row_bytes = SIZE * 4      # 256
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

# --- Map + read ---
WGPU.map_buffer_read(instance, readback, buf_size)
pixels = LibWGPU.buffer_get_mapped_range(readback, 0_u64, buf_size).as(UInt8*)

def px(pixels : UInt8*, x : Int, y : Int, row_bytes : UInt32)
  o = y * row_bytes.to_i + x * 4
  {pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3]}
end

cx = (SIZE // 2).to_i
center = px(pixels, cx, cx, row_bytes)
corner = px(pixels, 2, 2, row_bytes)
LibWGPU.buffer_unmap(readback)

puts "center (#{cx},#{cx}) = #{center}"
puts "corner (2,2)   = #{corner}"

ok = center[0] > 200 && center[1] < 60 && center[2] < 60 && # red center
     corner[0] < 60 && corner[1] < 60 && corner[2] < 60     # black corner

# Cleanup
LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
renderer.release
gpu.release

if ok
  puts "✅ readback OK (draws=#{renderer.last_draw_calls}, sprites=#{renderer.last_sprites})"
  exit 0
else
  puts "❌ unexpected colors"
  exit 1
end
