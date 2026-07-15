# Headless readback test for per-instance tint. Two entities share ONE white cube mesh
# (drawn in a single instanced call) but carry different MeshRenderer#tint values — red
# on the left, blue on the right. We assert the left cube reads red and the right cube
# reads blue, proving the per-instance param buffer (group0 binding 4) is applied.
#
#   crystal run examples/instance_tint_test.cr   # exit 0 if OK
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
cube = Flock::Mesh.cube(gpu, Flock::Color::WHITE) # one shared mesh; tint provides color

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 7.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
l = world.spawn
world.add(l, Flock::Transform3D.new(Flock::Vec3.new(-2.0, 0, 0)))
world.add(l, Flock::MeshRenderer.new(cube, tint: Flock::Color.new(1.0, 0.15, 0.15))) # red
r = world.spawn
world.add(r, Flock::Transform3D.new(Flock::Vec3.new(2.0, 0, 0)))
world.add(r, Flock::MeshRenderer.new(cube, tint: Flock::Color.new(0.15, 0.3, 1.0))) # blue

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
raise "expected a single instanced draw group" unless renderer.last_drawn == 2

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

def scan(pixels : UInt8*, xs : Range, y : Int, row_bytes : UInt32, &block : UInt8, UInt8, UInt8 -> Bool) : Bool
  xs.any? do |x|
    o = y * row_bytes.to_i + x * 4
    block.call(pixels[o], pixels[o + 1], pixels[o + 2])
  end
end

mid = (SIZE // 2).to_i
left_red = scan(pixels, 4...(SIZE // 3).to_i, mid, row_bytes) { |r, g, b| r > 60 && r > g && r > b }
right_blue = scan(pixels, (2 * SIZE // 3).to_i...(SIZE - 4).to_i, mid, row_bytes) { |r, g, b| b > 60 && b > r && b > g }
LibWGPU.buffer_unmap(readback)

puts "left red = #{left_red}, right blue = #{right_blue}, drawn = #{renderer.last_drawn}"
ok = left_red && right_blue

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
cube.release
renderer.release
gpu.release

puts ok ? "✅ per-instance tint OK" : "❌ per-instance tint not applied as expected"
exit(ok ? 0 : 1)
