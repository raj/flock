# Headless readback test for shadow mapping. A gray sphere floats above a large flat
# ground slab, lit by a single white directional light angled so the sphere's shadow lands
# on open ground beside it. The scene is rendered twice — once with the light casting
# shadows, once without — and the SAME ground point (inside the shadow) is sampled. It must
# be much darker with shadows on, and near-identical to a lit control point with shadows off
# (proving the darkening is a cast shadow, not occlusion by the sphere).
#
#   crystal run examples/shadow_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 256_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
ground = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.7, 0.7, 0.7))
sphere = Flock::Mesh.sphere(gpu, radius: 0.8, segments: 48, rings: 24, color: Flock::Color.new(0.7, 0.7, 0.7))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
# Low ambient so the shadow is a clear darkening, but the lit ground stays bright.
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(0.06, 0.06, 0.06), ground: Flock::Color.new(0.06, 0.06, 0.06)))

cam = Flock::Camera3D.new(position: Flock::Vec3.new(-1.0, 5.0, 7.0),
  target: Flock::Vec3.new(1.0, 0.0, 0.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK)
world.add(world.spawn, cam)

# Shadow-casting directional light, travelling down and toward +x.
lw = world.spawn
world.add(lw, Flock::Transform3D.new)
world.add(lw, Flock::Light.directional(Flock::Vec3.new(0.9, -1.0, 0.0),
  Flock::Color.new(1.0, 1.0, 1.0), 1.6, casts_shadows: true))

# Large thin ground slab, top surface at y = 0.
g = world.spawn
world.add(g, Flock::Transform3D.new(
  position: Flock::Vec3.new(0.0, -0.1, 0.0), scale: Flock::Vec3.new(16.0, 0.2, 16.0)))
world.add(g, Flock::MeshRenderer.new(ground))

# Sphere floating above the origin; its shadow falls near (0.9, 0, 0).
s = world.spawn
world.add(s, Flock::Transform3D.new(position: Flock::Vec3.new(0.0, 1.0, 0.0)))
world.add(s, Flock::MeshRenderer.new(sphere))

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

vp = cam.view_projection(1.0f32)

# Projects a world point to a pixel (x, y) using the camera view-projection.
def project(vp : Flock::Mat4, p : Flock::Vec3) : {Int32, Int32}
  num = vp.transform_point(p)
  m = vp.m
  w = m[3] * p.x + m[7] * p.y + m[11] * p.z + m[15]
  px = ((num.x / w * 0.5 + 0.5) * SIZE).to_i
  py = ((0.5 - num.y / w * 0.5) * SIZE).to_i
  {px.clamp(0, SIZE.to_i - 1), py.clamp(0, SIZE.to_i - 1)}
end

shadow_px = project(vp, Flock::Vec3.new(0.9, 0.02, 0.0)) # ground inside the sphere shadow
lit_px = project(vp, Flock::Vec3.new(-4.0, 0.02, 0.0))   # ground far from the shadow

# Renders the world and returns the luminance at the shadow and control ground pixels.
render_and_sample = ->{
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
  pixels = LibWGPU.buffer_get_mapped_range(readback, 0_u64, buf_size).as(UInt8*)
  lum = ->(px : Int32, py : Int32) {
    o = py * row_bytes.to_i + px * 4
    pixels[o].to_i + pixels[o + 1].to_i + pixels[o + 2].to_i
  }
  sl = lum.call(shadow_px[0], shadow_px[1])
  ll = lum.call(lit_px[0], lit_px[1])
  LibWGPU.buffer_unmap(readback)
  {sl, ll}
}

# Render 1: shadows on.
on_shadow, on_lit = render_and_sample.call

# Render 2: same scene, but the caster no longer casts shadows.
world.query(Flock::Transform3D, Flock::Light) do |_e, _tf, lt|
  l = lt.value
  l.casts_shadows = false
  lt.value = l
end
off_shadow, off_lit = render_and_sample.call

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
ground.release
sphere.release
renderer.release
gpu.release

puts "shadow pixel: on=#{on_shadow} off=#{off_shadow}   lit control: on=#{on_lit} off=#{off_lit}"
ok = off_shadow > 120 &&              # with shadows off, that ground point is lit
     on_shadow < off_shadow * 0.5 &&  # with shadows on, it is markedly darker
     on_lit > 120                     # the far control point stays lit either way

puts ok ? "✅ shadow mapping OK" : "❌ shadow not cast onto the ground as expected"
exit(ok ? 0 : 1)
