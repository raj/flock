# Headless readback test for native texture mipmaps (Texture from_pixels mipmaps:). A
# high-frequency 1px checkerboard fills a screen-filling quad, so each screen pixel covers
# several texels (heavy minification). The same quad is drawn with a mipmapped texture and
# a non-mipmapped one, sampling a central block each time. Without mipmaps the block shows
# strong minification aliasing (high variance); with a mip chain the sampler reads a coarse,
# averaged level and the block is a near-uniform mid-gray (low variance).
#
#   crystal run examples/mipmap_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32
TEX  = 512

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)

# 1px black/white checkerboard.
checker = Bytes.new(TEX * TEX * 4)
(0...TEX).each do |y|
  (0...TEX).each do |x|
    o = (y * TEX + x) * 4
    v = ((x + y) & 1) == 0 ? 255_u8 : 0_u8
    checker[o] = v; checker[o + 1] = v; checker[o + 2] = v; checker[o + 3] = 255_u8
  end
end
tex_flat = Flock::Texture.from_pixels(gpu, TEX, TEX, checker, filter: Flock::SamplerFilter::Linear, mipmaps: false)
tex_mip = Flock::Texture.from_pixels(gpu, TEX, TEX, checker, filter: Flock::SamplerFilter::Linear, mipmaps: true)

renderer = Flock::Renderer3D.new(gpu)
quad = Flock::Mesh.cube(gpu, color: Flock::Color.new(1.0, 1.0, 1.0))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
q = world.spawn
world.add(q, Flock::Transform3D.new(scale: Flock::Vec3.new(6.0, 6.0, 0.1))) # fills the frame
world.add(q, Flock::MeshRenderer.new(quad, texture: tex_flat))

target_desc = LibWGPU::TextureDescriptor.new
target_desc.label = WGPU.empty_string_view
target_desc.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::CopySrc
target_desc.dimension = LibWGPU::TextureDimension::N2D
target_desc.size = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
target_desc.format = LibWGPU::TextureFormat::RGBA8Unorm
target_desc.mip_level_count = 1_u32
target_desc.sample_count = 1_u32
target_tex = LibWGPU.device_create_texture(device, pointerof(target_desc))
target_view = LibWGPU.texture_create_view(target_tex, Pointer(LibWGPU::TextureViewDescriptor).null)

row_bytes = SIZE * 4
buf_size = (row_bytes * SIZE).to_u64
bdesc = LibWGPU::BufferDescriptor.new
bdesc.label = WGPU.empty_string_view
bdesc.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
bdesc.size = buf_size
bdesc.mapped_at_creation = 0_u32
readback = LibWGPU.device_create_buffer(device, pointerof(bdesc))

# Renders the scene and returns {mean, variance} of the green channel over a central block.
render_stats = ->{
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
  vals = [] of Float64
  (44...84).each do |y|
    (44...84).each do |x|
      vals << px[y * row_bytes.to_i + x * 4 + 1].to_f64
    end
  end
  LibWGPU.buffer_unmap(readback)
  mean = vals.sum / vals.size
  var = vals.sum { |v| (v - mean) ** 2 } / vals.size
  {mean, var}
}

flat_mean, flat_var = render_stats.call

# Swap in the mipmapped texture and re-render.
world.query(Flock::Transform3D, Flock::MeshRenderer) do |_e, _tf, mr|
  m = mr.value
  m.texture = tex_mip
  mr.value = m
end
mip_mean, mip_var = render_stats.call

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
tex_flat.release
tex_mip.release
quad.release
renderer.release
gpu.release

puts "no-mip: mean=#{flat_mean.round(1)} var=#{flat_var.round(1)}   mipped: mean=#{mip_mean.round(1)} var=#{mip_var.round(1)}"
# The mipped block is a uniform averaged mid-tone (the base-0.5 gray, brightened by the
# scene lighting); the aliased block is a noisy mix of the black/white texels. Variance is
# the anti-aliasing signal.
ok = flat_var > 200.0 &&              # without mips the minified checker aliases badly
     mip_var < flat_var * 0.1 &&      # mips smooth it out dramatically
     (140.0..235.0).includes?(mip_mean) # and converge to a uniform mid-tone (not pure 0/255)

puts ok ? "✅ native mipmaps OK" : "❌ mipmaps did not reduce minification aliasing"
exit(ok ? 0 : 1)
