# Headless test for frustum culling. Two cubes share the scene: one in front of the
# camera, one far off to the side (out of the frustum). We assert Renderer3D culled
# exactly the off-screen one (last_drawn == 1, last_culled == 1) and that the visible
# cube still renders at the center; a control render with culling disabled draws both.
#
#   crystal run examples/culling_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.9, 0.5, 0.2))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
# In view (origin).
a = world.spawn
world.add(a, Flock::Transform3D.new(Flock::Vec3.new(0, 0, 0)))
world.add(a, Flock::MeshRenderer.new(cube))
# Far off to the side — outside the frustum.
b = world.spawn
world.add(b, Flock::Transform3D.new(Flock::Vec3.new(1000.0, 0, 0)))
world.add(b, Flock::MeshRenderer.new(cube))

# Offscreen target.
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
drawn = renderer.last_drawn
culled = renderer.last_culled

# Control: disable culling, both should be drawn.
renderer.cull = false
renderer.render_into(world, target_view)
drawn_nocull = renderer.last_drawn
renderer.cull = true
renderer.render_into(world, target_view) # restore the culled image for readback

# Read center pixel to confirm the visible cube rendered.
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
ed = LibWGPU::CommandEncoderDescriptor.new; ed.label = WGPU.empty_string_view
enc = LibWGPU.device_create_command_encoder(device, pointerof(ed))
LibWGPU.command_encoder_copy_texture_to_buffer(enc, pointerof(src), pointerof(dst), pointerof(ext))
cd = LibWGPU::CommandBufferDescriptor.new; cd.label = WGPU.empty_string_view
cmd = LibWGPU.command_encoder_finish(enc, pointerof(cd))
cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)
WGPU.map_buffer_read(instance, readback, buf_size)
pixels = LibWGPU.buffer_get_mapped_range(readback, 0_u64, buf_size).as(UInt8*)
co = 64 * row_bytes.to_i + 64 * 4
center = {pixels[co], pixels[co + 1], pixels[co + 2]}
LibWGPU.buffer_unmap(readback)

puts "with culling:  drawn=#{drawn}, culled=#{culled}"
puts "without cull:  drawn=#{drawn_nocull}"
puts "center = #{center}"

ok = drawn == 1 && culled == 1 && drawn_nocull == 2 &&
     center[0].to_i + center[1].to_i + center[2].to_i > 40 # visible cube rendered

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
cube.release
renderer.release
gpu.release

puts ok ? "✅ frustum culling OK" : "❌ culling did not behave as expected"
exit(ok ? 0 : 1)
