# Headless test for the PBR shading path (metallic-roughness + normal maps), using
# procedural textures so it's deterministic. Two checks:
#   1. Normal map: a tilted normal map changes the shading vs a flat one.
#   2. Metallic: a metallic surface renders differently from a matte one (its diffuse
#      is suppressed), proving MeshRenderer#metallic feeds the shader.
#
#   crystal run examples/pbr_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.85, 0.5, 0.2))

flat_n = Flock::Texture.from_pixels(gpu, 1, 1, Bytes[128_u8, 128_u8, 255_u8, 255_u8]) # (0,0,1)
tilt_n = Flock::Texture.from_pixels(gpu, 1, 1, Bytes[235_u8, 235_u8, 130_u8, 255_u8]) # strong tilt

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

sample = ->(normal_map : Flock::Texture?, metallic : Float32) do
  world = Flock::World.new
  world.insert_resource(Flock::Time.new)
  world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), clear_color: Flock::Color::BLACK))
  e = world.spawn
  world.add(e, Flock::Transform3D.new)
  world.add(e, Flock::MeshRenderer.new(cube, normal_map: normal_map, metallic: metallic, roughness: 0.4f32))
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
  co = 64 * row_bytes.to_i + 64 * 4
  c = {pixels[co].to_i, pixels[co + 1].to_i, pixels[co + 2].to_i}
  LibWGPU.buffer_unmap(readback)
  LibWGPU.buffer_release(readback)
  c
end

def diff(a, b)
  (a[0] - b[0]).abs + (a[1] - b[1]).abs + (a[2] - b[2]).abs
end

flat = sample.call(flat_n, 0.0f32)
tilt = sample.call(tilt_n, 0.0f32)
matte = sample.call(nil, 0.0f32)
metal = sample.call(nil, 1.0f32)

puts "normal flat=#{flat} tilted=#{tilt} (diff #{diff(flat, tilt)})"
puts "matte=#{matte} metallic=#{metal} (diff #{diff(matte, metal)})"

ok = diff(flat, tilt) > 8 && diff(matte, metal) > 8

flat_n.release
tilt_n.release
cube.release
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
renderer.release
gpu.release

puts ok ? "✅ PBR (normal map + metallic) OK" : "❌ PBR maps had no visible effect"
exit(ok ? 0 : 1)
