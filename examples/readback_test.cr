# Test de rendu par readback (headless, sans fenêtre).
#
# Rend un sprite rouge sur fond noir dans une texture offscreen, copie la texture
# vers un buffer, la mappe, et vérifie la couleur des pixels (centre = rouge, coin
# = noir). Base réutilisable pour des tests GPU automatisés.
#
#   crystal run examples/readback_test.cr   # exit 0 si OK, 1 sinon
require "../src/flock/gpu"

SIZE = 64_u32 # 64*4 = 256 octets/ligne (déjà aligné pour copy_texture_to_buffer)

# --- Contexte GPU headless (pas de surface/fenêtre) ---
instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = WGPU.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)

gpu = Flock::GpuContext.new(
  instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))

renderer = Flock::Renderer2D.new(gpu)

# --- Scène : caméra (clear noir) + sprite rouge 40x40 au centre ---
world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
world.add(e, Flock::Sprite.new(Flock::Vec2.new(40, 40), Flock::Color::RED))

# --- Cible offscreen (RGBA8, rendable + copiable) ---
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

# --- Rendu ---
renderer.render_into(target_view, SIZE, SIZE, world)

# --- Copie texture -> buffer ---
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

# --- Map + lecture ---
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

puts "centre (#{cx},#{cx}) = #{center}"
puts "coin   (2,2)   = #{corner}"

ok = center[0] > 200 && center[1] < 60 && center[2] < 60 && # centre rouge
     corner[0] < 60 && corner[1] < 60 && corner[2] < 60     # coin noir

# Nettoyage
LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
renderer.release
gpu.release

if ok
  puts "✅ readback OK (draws=#{renderer.last_draw_calls}, sprites=#{renderer.last_sprites})"
  exit 0
else
  puts "❌ couleurs inattendues"
  exit 1
end
