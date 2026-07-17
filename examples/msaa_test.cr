# Headless readback test for MSAA anti-aliasing (Renderer3D sample_count). A flat white
# quad is rotated 30° around Z so its silhouette edges are diagonal, on a black background.
# The scene is rendered twice: once with sample_count = 1 (aliased) and once with 4 (MSAA).
# The quad faces the camera, so its interior is uniformly lit — any pixel whose luminance
# falls *between* black and the full quad color must be an anti-aliased edge sample. MSAA
# must produce many more such partial-coverage pixels than the aliased render.
#
#   crystal run examples/msaa_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
quad = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.9, 0.9, 0.9))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
# Flat ambient so the camera-facing quad is a single uniform color (no interior gradients).
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
q = world.spawn
world.add(q, Flock::Transform3D.new(
  rotation: Flock::Vec3.new(0.0, 0.0, 0.52), scale: Flock::Vec3.new(2.0, 2.0, 0.1)))
world.add(q, Flock::MeshRenderer.new(quad))

# Counts pixels with partial (anti-aliased) coverage — luminance strictly between the
# black background and the full quad color — for a renderer at the given sample count.
def count_edge_pixels(gpu, world, sample_count : Int32) : Int32
  renderer = Flock::Renderer3D.new(gpu, sample_count)
  tdesc = LibWGPU::TextureDescriptor.new
  tdesc.label = WGPU.empty_string_view
  tdesc.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::CopySrc
  tdesc.dimension = LibWGPU::TextureDimension::N2D
  tdesc.size = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
  tdesc.format = LibWGPU::TextureFormat::RGBA8Unorm
  tdesc.mip_level_count = 1_u32
  tdesc.sample_count = 1_u32
  tt = LibWGPU.device_create_texture(gpu.device, pointerof(tdesc))
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

  edge = 0
  (0...SIZE).each do |y|
    (0...SIZE).each do |x|
      o = y.to_i * rb.to_i + x.to_i * 4
      # Green channel: 0 on background, ~230 on the quad. Partial coverage lands between.
      g = px[o + 1].to_i
      edge += 1 if g > 30 && g < 200
    end
  end
  LibWGPU.buffer_unmap(rbk)
  LibWGPU.buffer_release(rbk)
  LibWGPU.texture_view_release(tv)
  LibWGPU.texture_release(tt)
  renderer.release
  edge
end

aa = count_edge_pixels(gpu, world, 1)
msaa = count_edge_pixels(gpu, world, 4)
quad.release
gpu.release

puts "partial-coverage edge pixels: aliased=#{aa}, MSAA 4x=#{msaa}"
ok = msaa > aa * 3 && msaa > 100

puts ok ? "✅ MSAA anti-aliasing OK" : "❌ MSAA did not smooth edges as expected"
exit(ok ? 0 : 1)
