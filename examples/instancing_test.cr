# Headless readback test for instanced meshes. Two entities SHARE one Mesh object at
# x = -2 and x = +2; Renderer3D groups them into a single instanced draw call, using
# per-instance model matrices. We assert both a left and a right cube render (proving
# distinct per-instance transforms) with a background gap between them.
#
#   crystal run examples/instancing_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.3, 0.9, 0.4)) # ONE mesh, shared

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(0.0, 0.0, 7.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))

# Two instances of the SAME mesh, left and right.
[-2.0, 2.0].each do |x|
  e = world.spawn
  world.add(e, Flock::Transform3D.new(Flock::Vec3.new(x, 0.0, 0.0)))
  world.add(e, Flock::MeshRenderer.new(cube))
end

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

def lit?(pixels : UInt8*, x : Int, y : Int, row_bytes : UInt32) : Bool
  o = y * row_bytes.to_i + x * 4
  pixels[o].to_i + pixels[o + 1].to_i + pixels[o + 2].to_i > 40
end

mid = SIZE // 2
# Any lit pixel in the left third / right third at the vertical center?
left = (4...(SIZE // 3)).any? { |x| lit?(pixels, x.to_i, mid.to_i, row_bytes) }
right = ((2 * SIZE // 3)...(SIZE - 4)).any? { |x| lit?(pixels, x.to_i, mid.to_i, row_bytes) }
center_dark = !lit?(pixels, mid.to_i, mid.to_i, row_bytes)
corner_dark = !lit?(pixels, 2, 2, row_bytes)
LibWGPU.buffer_unmap(readback)

puts "left lit = #{left}, right lit = #{right}, center dark = #{center_dark}, corner dark = #{corner_dark}"

ok = left && right && center_dark && corner_dark

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
cube.release
renderer.release
gpu.release

puts ok ? "✅ instanced meshes OK" : "❌ instancing not rendered as expected"
exit(ok ? 0 : 1)
