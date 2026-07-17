# Headless readback test for prefiltered image-based lighting. A fully metallic, smooth
# sphere is placed in a blue IBL environment; its specular reflection must read blue
# (the prefiltered environment). A control render WITHOUT the IBL resource stays much
# darker, proving the IBL contribution.
#
#   crystal run examples/ibl_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 48, rings: 24, color: Flock::Color::WHITE)

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sphere, metallic: 1.0f32, roughness: 0.12f32))

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
row_bytes = SIZE * 4
buf_size = (row_bytes * SIZE).to_u64

center = ->do
  renderer.render_into(world, target_view)
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
  o = 64 * row_bytes.to_i + 64 * 4
  c = {pixels[o].to_i, pixels[o + 1].to_i, pixels[o + 2].to_i}
  LibWGPU.buffer_unmap(readback)
  LibWGPU.buffer_release(readback)
  c
end

no_ibl = center.call # no IblEnvironment resource -> flag off

ibl = renderer.build_ibl(
  sky: Flock::Color.new(0.15, 0.35, 1.0),
  horizon: Flock::Color.new(0.2, 0.4, 1.0),
  ground: Flock::Color.new(0.2, 0.4, 1.0))
world.insert_resource(ibl)
with_ibl = center.call

puts "center without IBL = #{no_ibl}"
puts "center with IBL    = #{with_ibl}"
# With IBL the metallic sphere reflects the blue environment (blue-dominant, brighter).
ok = with_ibl[2] > 80 && with_ibl[2] > with_ibl[0] && with_ibl[2] > no_ibl[2] + 20

ibl.release
sphere.release
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
renderer.release
gpu.release

puts ok ? "✅ prefiltered IBL OK" : "❌ IBL reflection not as expected"
exit(ok ? 0 : 1)
