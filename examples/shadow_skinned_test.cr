# Readback test: a GPU-skinned mesh casts a shadow. A single-joint (identity) skinned quad
# floats horizontally above a ground slab, lit by a directional light. The scene is rendered
# with the light casting shadows and not; the ground point directly under the skinned quad
# must be markedly darker with shadows on (proving the skinned depth pass writes the caster
# into the shadow map), while a far control point stays lit either way.
#
#   crystal run examples/shadow_skinned_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128_u32
LE = IO::ByteFormat::LittleEndian

io = IO::Memory.new
# POSITION (0,48): a horizontal quad at y=2 (an elevated occluder).
[-1.2f32, 2.0f32, -1.2f32, 1.2f32, 2.0f32, -1.2f32,
 1.2f32, 2.0f32, 1.2f32, -1.2f32, 2.0f32, 1.2f32].each { |f| io.write_bytes(f, LE) }
# JOINTS_0 (48,32) u16x4: joint 0.
16.times { io.write_bytes(0u16, LE) }
# WEIGHTS_0 (80,64) f32x4: [1,0,0,0].
4.times { io.write_bytes(1.0f32, LE); io.write_bytes(0.0f32, LE); io.write_bytes(0.0f32, LE); io.write_bytes(0.0f32, LE) }
# indices (144,12).
[0u16, 1u16, 2u16, 0u16, 2u16, 3u16].each { |i| io.write_bytes(i, LE) }
# inverseBindMatrices (156,64): identity.
[1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 1f32].each { |f| io.write_bytes(f, LE) }
buf = io.to_slice
uri = "data:application/octet-stream;base64,#{Base64.strict_encode(buf)}"
json = %({
  "asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],
  "nodes":[{"mesh":0,"skin":0}],
  "skins":[{"joints":[0],"inverseBindMatrices":4}],
  "meshes":[{"primitives":[{"attributes":{"POSITION":0,"JOINTS_0":1,"WEIGHTS_0":2},"indices":3}]}],
  "buffers":[{"uri":"#{uri}","byteLength":#{buf.size}}],
  "bufferViews":[
    {"buffer":0,"byteOffset":0,"byteLength":48},{"buffer":0,"byteOffset":48,"byteLength":32},
    {"buffer":0,"byteOffset":80,"byteLength":64},{"buffer":0,"byteOffset":144,"byteLength":12},
    {"buffer":0,"byteOffset":156,"byteLength":64}],
  "accessors":[
    {"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"},
    {"bufferView":1,"componentType":5123,"count":4,"type":"VEC4"},
    {"bufferView":2,"componentType":5126,"count":4,"type":"VEC4"},
    {"bufferView":3,"componentType":5123,"count":6,"type":"SCALAR"},
    {"bufferView":4,"componentType":5126,"count":1,"type":"MAT4"}]
})
path = File.tempname("flock_skinsh", ".gltf")
File.write(path, json)

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.7, 0.7, 0.7))
File.delete(path) rescue nil
ground = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.75, 0.75, 0.75))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(0.08, 0.08, 0.08), ground: Flock::Color.new(0.08, 0.08, 0.08)))
cam = Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 7.0, 9.0), target: Flock::Vec3.new(0.0, 0.5, 0.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK)
world.add(world.spawn, cam)
lw = world.spawn
world.add(lw, Flock::Transform3D.new)
world.add(lw, Flock::Light.directional(Flock::Vec3.new(0.15, -1.0, 0.1), Flock::Color::WHITE, 1.4, casts_shadows: true))
g = world.spawn
world.add(g, Flock::Transform3D.new(position: Flock::Vec3.new(0.0, 0.0, 0.0), scale: Flock::Vec3.new(16.0, 0.2, 16.0)))
world.add(g, Flock::MeshRenderer.new(ground))
model = Flock::GpuSkinnedModel.spawn(scene, world, renderer, gpu)
model.apply

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

vp = cam.view_projection(1.0f32)
def project(vp : Flock::Mat4, p : Flock::Vec3) : {Int32, Int32}
  num = vp.transform_point(p); m = vp.m
  w = m[3] * p.x + m[7] * p.y + m[11] * p.z + m[15]
  {((num.x / w * 0.5 + 0.5) * SIZE).to_i.clamp(0, SIZE.to_i - 1),
   ((0.5 - num.y / w * 0.5) * SIZE).to_i.clamp(0, SIZE.to_i - 1)}
end
under = project(vp, Flock::Vec3.new(0.3, 0.02, 0.2)) # ground under the elevated quad
far = project(vp, Flock::Vec3.new(-5.5, 0.02, 0.0))   # ground far from the occluder

render_lum = ->do
  renderer.render_into(world, tv)
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
  lum = ->(pt : {Int32, Int32}) { o = pt[1] * rb.to_i + pt[0] * 4; px[o].to_i + px[o + 1].to_i + px[o + 2].to_i }
  r = {lum.call(under), lum.call(far)}
  LibWGPU.buffer_unmap(readback)
  r
end

on_under, on_far = render_lum.call
world.query(Flock::Transform3D, Flock::Light) do |_e, _tf, lt|
  l = lt.value; l.casts_shadows = false; lt.value = l
end
off_under, off_far = render_lum.call

LibWGPU.buffer_release(readback); LibWGPU.texture_view_release(tv); LibWGPU.texture_release(tt)
ground.release; renderer.release; gpu.release

puts "under quad: shadows on=#{on_under} off=#{off_under}   far control: on=#{on_far} off=#{off_far}"
ok = off_under > 120 &&               # lit ground under the quad with shadows off
     on_under < off_under * 0.6 &&     # skinned quad darkens it with shadows on
     on_far > 120                      # far point stays lit

puts ok ? "✅ skinned mesh casts a shadow OK" : "❌ skinned caster did not cast a shadow"
exit(ok ? 0 : 1)
