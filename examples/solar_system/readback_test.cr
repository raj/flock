# Headless readback test for the solar-system 3D path: renders the sun sphere with
# a custom Material3D (emissive shader using the shared globals binding) into an
# offscreen target and asserts the center is warm (non-black, red>blue) while a
# corner stays background. Proves Renderer3D custom materials + sphere mesh work.
#
#   crystal run examples/solar_system/readback_test.cr   # exit 0 if OK
require "../../src/flock/gpu"

SIZE = 128_u32 # 128*4 = 512 bytes/row (multiple of 256)

SUN_WGSL = <<-WGSL
struct Camera { view_proj : mat4x4<f32> };
struct Globals { time : f32 };
@group(0) @binding(0) var<uniform> cam : Camera;
@group(0) @binding(1) var<storage, read> models : array<mat4x4<f32>>;
@group(0) @binding(2) var<uniform> globals : Globals;
struct VSOut { @builtin(position) clip : vec4<f32>, @location(0) lpos : vec3<f32> };
@vertex
fn vs_main(@location(0) pos : vec3<f32>, @location(1) nrm : vec3<f32>,
           @location(2) col : vec3<f32>, @builtin(instance_index) ii : u32) -> VSOut {
  var out : VSOut;
  out.clip = cam.view_proj * models[ii] * vec4<f32>(pos, 1.0);
  out.lpos = pos;
  return out;
}
@fragment
fn fs_main(in : VSOut) -> @location(0) vec4<f32> {
  // globals.time is 0 here; produce a stable warm color.
  let flick = 0.5 + 0.5 * sin(in.lpos.x * 7.0 + globals.time);
  return vec4<f32>(mix(vec3<f32>(0.95,0.35,0.05), vec3<f32>(1.0,0.9,0.4), flick), 1.0);
}
WGSL

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(
  instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))

renderer = Flock::Renderer3D.new(gpu)
sun_mat = renderer.build_material(SUN_WGSL)
sun = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 32, rings: 16, color: Flock::Color.new(1.0, 0.8, 0.3))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(0.0, 0.0, 3.0), clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sun, sun_mat))

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
src.texture = target_tex
src.mip_level = 0_u32
src.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32)
src.aspect = LibWGPU::TextureAspect::All
layout = LibWGPU::TexelCopyBufferLayout.new
layout.offset = 0_u64
layout.bytes_per_row = row_bytes
layout.rows_per_image = SIZE
dst = LibWGPU::TexelCopyBufferInfo.new
dst.layout = layout
dst.buffer = readback
ext = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)

enc_desc = LibWGPU::CommandEncoderDescriptor.new
enc_desc.label = WGPU.empty_string_view
encoder = LibWGPU.device_create_command_encoder(device, pointerof(enc_desc))
LibWGPU.command_encoder_copy_texture_to_buffer(encoder, pointerof(src), pointerof(dst), pointerof(ext))
cmd_desc = LibWGPU::CommandBufferDescriptor.new
cmd_desc.label = WGPU.empty_string_view
cmd = LibWGPU.command_encoder_finish(encoder, pointerof(cmd_desc))
cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)

WGPU.map_buffer_read(instance, readback, buf_size)
pixels = LibWGPU.buffer_get_mapped_range(readback, 0_u64, buf_size).as(UInt8*)

def px(pixels : UInt8*, x : Int, y : Int, row_bytes : UInt32)
  o = y * row_bytes.to_i + x * 4
  {pixels[o], pixels[o + 1], pixels[o + 2]}
end

center = px(pixels, (SIZE // 2).to_i, (SIZE // 2).to_i, row_bytes)
corner = px(pixels, 2, 2, row_bytes)
LibWGPU.buffer_unmap(readback)

puts "center = #{center}"
puts "corner = #{corner}"

# Center: emissive sun (warm, red>blue, bright). Corner: black background.
ok = center[0] > 80 && center[0].to_i > center[2].to_i &&
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
sun.release
renderer.release
gpu.release

puts ok ? "✅ solar-system 3D material OK" : "❌ sun not rendered as expected"
exit(ok ? 0 : 1)
