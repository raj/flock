# Headless readback test for the hemisphere ambient probe (Flock::AmbientLight). A white
# sphere is lit with sky=blue / ground=red ambient. The top of the sphere (normal up)
# must read bluish and the bottom (normal down, unlit by the directional light) reddish,
# proving the ambient term is directional (driven by the world normal).
#
#   crystal run examples/ambient_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 48, rings: 24, color: Flock::Color.new(0.5, 0.5, 0.5))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(0.2, 0.4, 1.0), ground: Flock::Color.new(1.0, 0.3, 0.2)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sphere))

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

def lit?(pixels : UInt8*, x : Int, y : Int, rb : UInt32)
  o = y * rb.to_i + x * 4
  pixels[o].to_i + pixels[o + 1].to_i + pixels[o + 2].to_i > 40
end

def px(pixels : UInt8*, x : Int, y : Int, rb : UInt32)
  o = y * rb.to_i + x * 4
  {pixels[o].to_i, pixels[o + 1].to_i, pixels[o + 2].to_i}
end

# First lit pixel scanning down from the top, and up from the bottom, at center column.
top_y = (0...SIZE).find { |y| lit?(pixels, 64, y.to_i, row_bytes) } || 0
bot_y = (0...SIZE).reverse_each.find { |y| lit?(pixels, 64, y.to_i, row_bytes) } || 0
top = px(pixels, 64, (top_y + 3).to_i, row_bytes)  # just inside the top edge (normal up)
bot = px(pixels, 64, (bot_y - 3).to_i, row_bytes)   # just inside the bottom edge (normal down)
LibWGPU.buffer_unmap(readback)

puts "top(sky) = #{top}, bottom(ground) = #{bot}"
ok = top[2] > top[0] &&        # top is bluish (sky)
     bot[0] > bot[2] &&        # bottom is reddish (ground)
     bot[0] > bot[1]

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
sphere.release
renderer.release
gpu.release

puts ok ? "✅ hemisphere ambient probe OK" : "❌ ambient probe not directional as expected"
exit(ok ? 0 : 1)
