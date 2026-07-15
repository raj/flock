# Headless readback test for unified 2D + 3D in one frame. Renders a 3D cube
# (Renderer3D, clears), then a 2D white sprite on top (Renderer2D overlay mode),
# into the same target. Asserts: the 3D cube shows at center (green), the 2D sprite
# shows at the top-left (white, high blue), and an empty corner stays background.
#
#   crystal run examples/render_2d3d_test.cr   # exit 0 if OK
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

r3 = Flock::Renderer3D.new(gpu)
r2 = Flock::Renderer2D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.2, 0.8, 0.3))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
# 3D scene.
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
c = world.spawn
world.add(c, Flock::Transform3D.new)
world.add(c, Flock::MeshRenderer.new(cube))
# 2D overlay: a white sprite in the top-left area (world y up; -45,+45 -> screen ~19,19).
world.add(world.spawn, Flock::Camera2D.new(clear_color: nil))
s = world.spawn
world.add(s, Flock::Transform2D.at(-45.0, 45.0))
world.add(s, Flock::Sprite.new(Flock::Vec2.new(24, 24), Flock::Color::WHITE))

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

# The unified composition: 3D first (clears), then 2D on top (load_previous).
r3.render_into(world, target_view)
r2.render_into(target_view, SIZE, SIZE, world, load_previous: true)

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

center = px(pixels, 64, 64, row_bytes)   # 3D cube (green)
sprite = px(pixels, 19, 19, row_bytes)    # 2D overlay (white)
corner = px(pixels, 120, 120, row_bytes)  # background
LibWGPU.buffer_unmap(readback)

puts "center(3D) = #{center}"
puts "sprite(2D) = #{sprite}"
puts "corner      = #{corner}"

ok = center[1] > 60 && center[1].to_i > center[2].to_i && # 3D cube: green, non-bg
     sprite[2] > 90 && sprite[0] > 90 &&                  # 2D sprite: white (high blue+red)
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20    # background

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
cube.release
r2.release
r3.release
gpu.release

puts ok ? "✅ unified 2D + 3D OK" : "❌ 2D/3D composition not as expected"
exit(ok ? 0 : 1)
