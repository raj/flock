# Headless readback test for 3D alpha blending (MeshRenderer#transparent). A red opaque
# panel sits behind a blue panel. The blue panel is rendered twice — once transparent
# (tint alpha 0.5), once opaque — and the overlap pixel is sampled both times. When the
# blue panel is transparent the red panel must show through (red channel present); when
# opaque it must fully hide the red. This proves back-to-front alpha blending works.
#
#   crystal run examples/transparency_test.cr   # exit 0 if OK
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
renderer = Flock::Renderer3D.new(gpu)
red = Flock::Mesh.cube(gpu, color: Flock::Color.new(1.0, 0.1, 0.1))
blue = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.1, 0.1, 1.0))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
# Bright, flat ambient so the panel base colors dominate (blend result is easy to read).
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(0.9, 0.9, 0.9), ground: Flock::Color.new(0.9, 0.9, 0.9)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))

# Opaque red panel behind.
rp = world.spawn
world.add(rp, Flock::Transform3D.new(position: Flock::Vec3.new(0.0, 0.0, -1.0), scale: Flock::Vec3.new(3.0, 3.0, 0.1)))
world.add(rp, Flock::MeshRenderer.new(red))

# Blue panel in front. `transparent` is flipped between the two renders.
bp = world.spawn
world.add(bp, Flock::Transform3D.new(position: Flock::Vec3.new(0.0, 0.0, 0.5), scale: Flock::Vec3.new(1.5, 1.5, 0.1)))
world.add(bp, Flock::MeshRenderer.new(blue, tint: Flock::Color.new(1.0, 1.0, 1.0, 0.5), transparent: true))

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
bdesc = LibWGPU::BufferDescriptor.new
bdesc.label = WGPU.empty_string_view
bdesc.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
bdesc.size = buf_size
bdesc.mapped_at_creation = 0_u32
readback = LibWGPU.device_create_buffer(device, pointerof(bdesc))

# Renders and returns the center pixel {r, g, b}.
render_center = ->{
  renderer.render_into(world, target_view)
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
  px = LibWGPU.buffer_get_mapped_range(readback, 0_u64, buf_size).as(UInt8*)
  o = 64 * row_bytes.to_i + 64 * 4
  c = {px[o].to_i, px[o + 1].to_i, px[o + 2].to_i}
  LibWGPU.buffer_unmap(readback)
  c
}

# Render 1: blue panel transparent -> red shows through.
trans = render_center.call

# Render 2: same blue panel, opaque -> red hidden.
world.query(Flock::Transform3D, Flock::MeshRenderer) do |_e, _tf, mr|
  m = mr.value
  if m.transparent
    m.transparent = false
    mr.value = m
  end
end
opaque = render_center.call

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
red.release
blue.release
renderer.release
gpu.release

puts "overlap transparent = #{trans}, opaque = #{opaque}"
ok = trans[2] > 60 &&                 # blue visible through the translucent panel
     trans[0] > 60 &&                 # red shows through the translucent panel
     opaque[0] < trans[0] * 0.5 &&    # opaque panel hides most of the red
     opaque[2] > 60                   # opaque panel is blue

puts ok ? "✅ alpha blending OK" : "❌ transparency did not blend as expected"
exit(ok ? 0 : 1)
