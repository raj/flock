# Headless readback test for multiple UV sets (MeshRenderer#tex_coords / glTF TEXCOORD_1).
# A camera-facing quad carries two UV sets: TEXCOORD_0 samples the LEFT (red) texel of a
# 2x1 red/blue texture, TEXCOORD_1 the RIGHT (blue) texel. Rendering the base texture with
# tex_coords = 0 (use uv0) must read red; with the base bit set (use uv1) must read blue.
#
#   crystal run examples/uvsets_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

# 2x1 texture: left texel red, right texel blue (Nearest, so UVs pick exact texels).
tex = Flock::Texture.from_pixels(gpu, 2, 1, Bytes[255_u8, 0_u8, 0_u8, 255_u8, 0_u8, 0_u8, 255_u8, 255_u8])

# A camera-facing quad. Vertex = pos3 + normal3 + color3 + uv0(2) + uv1(2) = 13 floats.
# uv0 = (0.25, 0.5) -> left (red) texel; uv1 = (0.75, 0.5) -> right (blue) texel.
def vtx(x, y)
  [x.to_f32, y.to_f32, 0.0f32, 0.0f32, 0.0f32, 1.0f32, 1.0f32, 1.0f32, 1.0f32,
   0.25f32, 0.5f32, 0.75f32, 0.5f32]
end

verts = [vtx(-1.5, -1.5), vtx(1.5, -1.5), vtx(1.5, 1.5), vtx(-1.5, 1.5)].flatten
mesh = Flock::Mesh.build(gpu, verts, [0u32, 1u32, 2u32, 0u32, 2u32, 3u32])

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(mesh, texture: tex)) # tex_coords defaults to 0 (uv0)

td = LibWGPU::TextureDescriptor.new
td.label = WGPU.empty_string_view
td.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::CopySrc
td.dimension = LibWGPU::TextureDimension::N2D
td.size = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
td.format = LibWGPU::TextureFormat::RGBA8Unorm
td.mip_level_count = 1_u32; td.sample_count = 1_u32
tt = LibWGPU.device_create_texture(device, pointerof(td))
tv = LibWGPU.texture_create_view(tt, Pointer(LibWGPU::TextureViewDescriptor).null)

rb = SIZE * 4
bs = (rb * SIZE).to_u64
bd = LibWGPU::BufferDescriptor.new
bd.label = WGPU.empty_string_view
bd.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
bd.size = bs; bd.mapped_at_creation = 0_u32
readback = LibWGPU.device_create_buffer(device, pointerof(bd))

render_center = ->do
  renderer.render_into(world, tv)
  src = LibWGPU::TexelCopyTextureInfo.new
  src.texture = tt; src.mip_level = 0_u32
  src.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32); src.aspect = LibWGPU::TextureAspect::All
  lay = LibWGPU::TexelCopyBufferLayout.new
  lay.offset = 0_u64; lay.bytes_per_row = rb; lay.rows_per_image = SIZE
  dst = LibWGPU::TexelCopyBufferInfo.new; dst.layout = lay; dst.buffer = readback
  ext = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
  ec = LibWGPU::CommandEncoderDescriptor.new; ec.label = WGPU.empty_string_view
  enc = LibWGPU.device_create_command_encoder(device, pointerof(ec))
  LibWGPU.command_encoder_copy_texture_to_buffer(enc, pointerof(src), pointerof(dst), pointerof(ext))
  cc = LibWGPU::CommandBufferDescriptor.new; cc.label = WGPU.empty_string_view
  cmd = LibWGPU.command_encoder_finish(enc, pointerof(cc))
  cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
  LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)
  WGPU.map_buffer_read(instance, readback, bs)
  px = LibWGPU.buffer_get_mapped_range(readback, 0_u64, bs).as(UInt8*)
  o = 32 * rb.to_i + 32 * 4
  c = {px[o].to_i, px[o + 1].to_i, px[o + 2].to_i}
  LibWGPU.buffer_unmap(readback)
  c
end

uv0 = render_center.call # base uses TEXCOORD_0 -> red

# Flip the base texture to TEXCOORD_1 (bit 0) -> blue.
world.query(Flock::Transform3D, Flock::MeshRenderer) do |_e, _tf, mr|
  v = mr.value; v.tex_coords = 1_u32; mr.value = v
end
uv1 = render_center.call # base uses TEXCOORD_1 -> blue

LibWGPU.buffer_release(readback); LibWGPU.texture_view_release(tv); LibWGPU.texture_release(tt)
mesh.release; tex.release; renderer.release; gpu.release

puts "TEXCOORD_0 center = #{uv0} (expect red)   TEXCOORD_1 center = #{uv1} (expect blue)"
ok = uv0[0] > 150 && uv0[0] > uv0[2] * 2 &&  # uv0 -> red
     uv1[2] > 150 && uv1[2] > uv1[0] * 2     # uv1 -> blue

puts ok ? "✅ multiple UV sets OK" : "❌ UV-set selection did not switch textures"
exit(ok ? 0 : 1)
