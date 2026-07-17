# Headless readback test for the Flock lighting system (Flock::Light). A white sphere is
# lit by a single RED directional light travelling into the screen (so the camera-facing
# front is lit). Ambient is near-black, so the direct light dominates: the sphere's center
# must read strongly red (r > g and r > b), proving Light components drive the PBR shader.
#
#   crystal run examples/lights_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 48, rings: 24, color: Flock::Color.new(0.8, 0.8, 0.8))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
# Near-black ambient so the direct light is what colors the sphere.
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(0.02, 0.02, 0.02), ground: Flock::Color.new(0.02, 0.02, 0.02)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))

# Red directional light travelling into the screen (-z): L = -dir = +z lights the front.
lw = world.spawn
world.add(lw, Flock::Transform3D.new)
world.add(lw, Flock::Light.directional(Flock::Vec3.new(0.0, 0.0, -1.0), Flock::Color.new(1.0, 0.1, 0.1), 3.0))

e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sphere))

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

renderer.render_into(world, target_view)

row_bytes = SIZE * 4
buf_size = (row_bytes * SIZE).to_u64
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

def px(pixels : UInt8*, x : Int, y : Int, rb : UInt32)
  o = y * rb.to_i + x * 4
  {pixels[o].to_i, pixels[o + 1].to_i, pixels[o + 2].to_i}
end

center = px(pixels, 64, 64, row_bytes)
LibWGPU.buffer_unmap(readback)

puts "center = #{center}"
ok = center[0] > 60 &&              # visibly lit
     center[0] > center[1] * 2 &&   # strongly red
     center[0] > center[2] * 2

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
sphere.release
renderer.release
gpu.release

puts ok ? "✅ directional light OK" : "❌ light did not color the sphere as expected"
exit(ok ? 0 : 1)
