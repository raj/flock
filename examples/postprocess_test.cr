# Headless readback test for HDR post-processing / tonemapping (Renderer3D tonemap:). A
# white sphere is lit by a very bright directional light, producing radiance well above 1.0.
# Rendered without tonemapping (Tonemap::None) the scene writes straight to LDR RGBA8 and
# the bright side clips to a flat, fully-saturated white. With ACES tonemapping the scene
# renders to an HDR (rgba16float) target and a fullscreen pass compresses the highlights, so
# far fewer pixels are blown out and the shading gradient is preserved.
#
#   crystal run examples/postprocess_test.cr   # exit 0 if OK
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
sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 48, rings: 24, color: Flock::Color.new(1.0, 1.0, 1.0))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(0.1, 0.1, 0.1), ground: Flock::Color.new(0.1, 0.1, 0.1)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
# Very bright light toward the camera -> radiance far above 1.0 on the facing hemisphere.
lw = world.spawn
world.add(lw, Flock::Transform3D.new)
world.add(lw, Flock::Light.directional(Flock::Vec3.new(0.0, 0.0, -1.0), Flock::Color.new(1.0, 1.0, 1.0), 2.5))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sphere))

# Counts fully-saturated (blown-out) pixels for a renderer at the given tonemap mode.
def saturated(gpu, world, tonemap : Flock::Tonemap) : Int32
  renderer = Flock::Renderer3D.new(gpu, 1, tonemap)
  td = LibWGPU::TextureDescriptor.new
  td.label = WGPU.empty_string_view
  td.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::CopySrc
  td.dimension = LibWGPU::TextureDimension::N2D
  td.size = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
  td.format = LibWGPU::TextureFormat::RGBA8Unorm
  td.mip_level_count = 1_u32; td.sample_count = 1_u32
  tt = LibWGPU.device_create_texture(gpu.device, pointerof(td))
  tv = LibWGPU.texture_create_view(tt, Pointer(LibWGPU::TextureViewDescriptor).null)
  renderer.render_into(world, tv)

  rb = SIZE * 4
  bs = (rb * SIZE).to_u64
  bd = LibWGPU::BufferDescriptor.new
  bd.label = WGPU.empty_string_view
  bd.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
  bd.size = bs; bd.mapped_at_creation = 0_u32
  rbk = LibWGPU.device_create_buffer(gpu.device, pointerof(bd))
  src = LibWGPU::TexelCopyTextureInfo.new
  src.texture = tt; src.mip_level = 0_u32
  src.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32); src.aspect = LibWGPU::TextureAspect::All
  lay = LibWGPU::TexelCopyBufferLayout.new
  lay.offset = 0_u64; lay.bytes_per_row = rb; lay.rows_per_image = SIZE
  dst = LibWGPU::TexelCopyBufferInfo.new; dst.layout = lay; dst.buffer = rbk
  ext = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
  ed = LibWGPU::CommandEncoderDescriptor.new; ed.label = WGPU.empty_string_view
  enc = LibWGPU.device_create_command_encoder(gpu.device, pointerof(ed))
  LibWGPU.command_encoder_copy_texture_to_buffer(enc, pointerof(src), pointerof(dst), pointerof(ext))
  cd = LibWGPU::CommandBufferDescriptor.new; cd.label = WGPU.empty_string_view
  cmd = LibWGPU.command_encoder_finish(enc, pointerof(cd))
  cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
  LibWGPU.queue_submit(gpu.queue, 1_u64, cmds.to_unsafe)
  WGPU.map_buffer_read(gpu.instance, rbk, bs)
  px = LibWGPU.buffer_get_mapped_range(rbk, 0_u64, bs).as(UInt8*)
  blown = 0
  (0...(SIZE * SIZE)).each do |i|
    o = i.to_i * 4
    blown += 1 if px[o] >= 250 && px[o + 1] >= 250 && px[o + 2] >= 250
  end
  LibWGPU.buffer_unmap(rbk)
  LibWGPU.buffer_release(rbk)
  LibWGPU.texture_view_release(tv)
  LibWGPU.texture_release(tt)
  renderer.release
  blown
end

none = saturated(gpu, world, Flock::Tonemap::None)
aces = saturated(gpu, world, Flock::Tonemap::Aces)
sphere.release
gpu.release

puts "blown-out pixels: none=#{none}, ACES=#{aces}"
ok = none > 300 &&            # without tonemapping the bright side clips badly
     aces < none * 0.3        # ACES recovers most of the blown highlights

puts ok ? "✅ HDR tonemapping OK" : "❌ tonemapping did not recover the highlights"
exit(ok ? 0 : 1)
