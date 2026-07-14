# Per-sprite material test (headless, readback).
#
# Renders two sprites: one with the default material (red tint) and one with a
# custom SpriteMaterial whose fragment shader forces blue. Reads back both regions
# and asserts they differ — proving per-sprite material dispatch works.
#
#   crystal run examples/material_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64_u32

# Custom sprite material: same instancing convention (group0 = view-proj + instances),
# but the fragment ignores the texture/tint and outputs a constant blue.
CUSTOM_WGSL = <<-SHADER
struct Instance { model : mat4x4<f32>, color : vec4<f32>, uv : vec4<f32> };
@group(0) @binding(0) var<uniform> u_vp : mat4x4<f32>;
@group(0) @binding(1) var<storage, read> instances : array<Instance>;
const QUAD = array<vec2<f32>, 6>(
  vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, -0.5), vec2<f32>(0.5, 0.5),
  vec2<f32>(-0.5, -0.5), vec2<f32>(0.5, 0.5), vec2<f32>(-0.5, 0.5));
@vertex
fn vs_main(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> @builtin(position) vec4<f32> {
  return u_vp * instances[ii].model * vec4<f32>(QUAD[vi], 0.0, 1.0);
}
@fragment
fn fs_main() -> @location(0) vec4<f32> {
  return vec4<f32>(0.2, 0.4, 1.0, 1.0);
}
SHADER

instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(
  instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))

renderer = Flock::Renderer2D.new(gpu)
blue_material = renderer.build_material(CUSTOM_WGSL)

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))

# Left: default material, red tint.
a = world.spawn
world.add(a, Flock::Transform2D.at(-16, 0))
world.add(a, Flock::Sprite.new(Flock::Vec2.new(24, 24), Flock::Color::RED))

# Right: custom material (forces blue).
b = world.spawn
world.add(b, Flock::Transform2D.at(16, 0))
world.add(b, Flock::Sprite.new(Flock::Vec2.new(24, 24), Flock::Color::WHITE, material: blue_material))

# --- Offscreen target ---
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

renderer.render_into(target_view, SIZE, SIZE, world)

# --- Readback ---
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

left = px(pixels, 16, 32, row_bytes)  # default sprite (red)
right = px(pixels, 48, 32, row_bytes) # custom material (blue)
LibWGPU.buffer_unmap(readback)

puts "left (default) = #{left}"
puts "right (custom) = #{right}"

ok = left[0] > 200 && left[2] < 60 && # left red
     right[2] > 200 && right[0] < 90  # right blue (custom shader)

LibWGPU.buffer_release(readback)
LibWGPU.texture_view_release(target_view)
LibWGPU.texture_release(target_tex)
renderer.release
gpu.release

puts ok ? "✅ per-sprite material OK" : "❌ materials not applied as expected"
exit(ok ? 0 : 1)
