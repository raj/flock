# Readback test for 3D multi-camera viewport + order (split-screen). Two Camera3D cover the
# left and right halves of the frame, each aimed at a different cube: the left camera (order
# 0) at a RED cube, the right camera (order 1) at a BLUE cube. The left half must read red
# and the right half blue, proving per-camera viewport/order rendering.
#
#   crystal run examples/split_screen_3d_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
redcube = Flock::Mesh.cube(gpu, color: Flock::Color.new(1.0, 0.1, 0.1))
bluecube = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.1, 0.1, 1.0))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))

half = SIZE.to_f32 / 2.0f32
# Left camera (order 0): left half, looks at the red cube (x = -3).
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(-3.0, 0.0, 3.0), target: Flock::Vec3.new(-3.0, 0.0, 0.0), fov_y: 0.9f32,
  viewport: Flock::Viewport.new(0.0f32, 0.0f32, half, SIZE.to_f32), order: 0,
  clear_color: Flock::Color.new(0.0, 0.0, 0.0)))
# Right camera (order 1): right half, looks at the blue cube (x = +3).
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(3.0, 0.0, 3.0), target: Flock::Vec3.new(3.0, 0.0, 0.0), fov_y: 0.9f32,
  viewport: Flock::Viewport.new(half, 0.0f32, half, SIZE.to_f32), order: 1))

er = world.spawn
world.add(er, Flock::Transform3D.new(position: Flock::Vec3.new(-3.0, 0.0, 0.0)))
world.add(er, Flock::MeshRenderer.new(redcube))
eb = world.spawn
world.add(eb, Flock::Transform3D.new(position: Flock::Vec3.new(3.0, 0.0, 0.0)))
world.add(eb, Flock::MeshRenderer.new(bluecube))

td = LibWGPU::TextureDescriptor.new
td.label = WGPU.empty_string_view
td.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::CopySrc
td.dimension = LibWGPU::TextureDimension::N2D
td.size = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
td.format = LibWGPU::TextureFormat::RGBA8Unorm
td.mip_level_count = 1_u32; td.sample_count = 1_u32
tt = LibWGPU.device_create_texture(device, pointerof(td))
tv = LibWGPU.texture_create_view(tt, Pointer(LibWGPU::TextureViewDescriptor).null)
renderer.render_into(world, tv)

rb = SIZE * 4
bs = (rb * SIZE).to_u64
bd = LibWGPU::BufferDescriptor.new
bd.label = WGPU.empty_string_view
bd.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
bd.size = bs; bd.mapped_at_creation = 0_u32
readback = LibWGPU.device_create_buffer(device, pointerof(bd))
src = LibWGPU::TexelCopyTextureInfo.new
src.texture = tt; src.mip_level = 0_u32
src.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32); src.aspect = LibWGPU::TextureAspect::All
lay = LibWGPU::TexelCopyBufferLayout.new
lay.offset = 0_u64; lay.bytes_per_row = rb; lay.rows_per_image = SIZE
dst = LibWGPU::TexelCopyBufferInfo.new; dst.layout = lay; dst.buffer = readback
ext = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
ed = LibWGPU::CommandEncoderDescriptor.new; ed.label = WGPU.empty_string_view
enc = LibWGPU.device_create_command_encoder(device, pointerof(ed))
LibWGPU.command_encoder_copy_texture_to_buffer(enc, pointerof(src), pointerof(dst), pointerof(ext))
cd = LibWGPU::CommandBufferDescriptor.new; cd.label = WGPU.empty_string_view
cmd = LibWGPU.command_encoder_finish(enc, pointerof(cd))
cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)
WGPU.map_buffer_read(instance, readback, bs)
px = LibWGPU.buffer_get_mapped_range(readback, 0_u64, bs).as(UInt8*)
def at(px : UInt8*, x : Int32, y : Int32, rb : UInt32)
  o = y * rb.to_i + x * 4
  {px[o].to_i, px[o + 1].to_i, px[o + 2].to_i}
end
left = at(px, 32, 64, rb)  # left-half center
right = at(px, 96, 64, rb) # right-half center
LibWGPU.buffer_unmap(readback)

LibWGPU.buffer_release(readback); LibWGPU.texture_view_release(tv); LibWGPU.texture_release(tt)
redcube.release; bluecube.release; renderer.release; gpu.release

puts "left half = #{left} (expect red), right half = #{right} (expect blue)"
ok = left[0] > 100 && left[0] > left[2] * 2 &&   # left viewport -> red cube
     right[2] > 100 && right[2] > right[0] * 2    # right viewport -> blue cube

puts ok ? "✅ 3D split-screen (viewport + order) OK" : "❌ multi-camera viewport/order not rendered"
exit(ok ? 0 : 1)
