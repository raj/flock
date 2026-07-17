# Headless test for glTF scene import: KHR_lights_punctual lights and glTF cameras.
# Builds a minimal .gltf with a directional/point/spot light and a perspective camera at
# posed nodes, loads them via Mesh.load_gltf_lights / load_gltf_cameras, asserts the parsed
# values, then renders a white sphere lit ONLY by the imported (red) directional light and
# checks the sphere reads red — proving import -> render works end to end.
#
#   crystal run examples/gltf_scene_import_test.cr   # exit 0 if OK
require "../src/flock/gpu"

json = <<-JSON
{
  "asset":{"version":"2.0"},
  "extensions":{"KHR_lights_punctual":{"lights":[
    {"type":"directional","color":[1.0,0.1,0.1],"intensity":2.0},
    {"type":"point","color":[0.1,1.0,0.1],"intensity":3.0,"range":5.0},
    {"type":"spot","color":[0.1,0.1,1.0],"intensity":4.0,"range":8.0,"spot":{"innerConeAngle":0.2,"outerConeAngle":0.5}}
  ]}},
  "cameras":[{"type":"perspective","perspective":{"yfov":0.8,"znear":0.5,"zfar":200.0}}],
  "nodes":[
    {"extensions":{"KHR_lights_punctual":{"light":0}}},
    {"translation":[1.0,2.0,3.0],"extensions":{"KHR_lights_punctual":{"light":1}}},
    {"translation":[0.0,5.0,0.0],"extensions":{"KHR_lights_punctual":{"light":2}}},
    {"translation":[4.0,0.0,0.0],"camera":0}
  ],
  "scenes":[{"nodes":[0,1,2,3]}],
  "scene":0
}
JSON

path = File.tempname("flock_scene", ".gltf")
File.write(path, json)

ok = true
def check(cond, msg)
  unless cond
    puts "  ✗ #{msg}"
    return false
  end
  true
end

lights = Flock::Mesh.load_gltf_lights(path)
ok &&= check(lights.size == 3, "expected 3 lights, got #{lights.size}")

l0, p0 = lights[0]
ok &&= check(l0.kind.directional?, "light 0 should be directional")
ok &&= check((l0.color.r - 1.0).abs < 1e-4 && l0.color.g < 0.2, "light 0 color red")
ok &&= check((l0.intensity - 2.0).abs < 1e-4, "light 0 intensity 2")
ok &&= check((l0.direction.z + 1.0).abs < 1e-4, "light 0 aims -Z, got #{l0.direction}")

l1, p1 = lights[1]
ok &&= check(l1.kind.point?, "light 1 should be point")
ok &&= check((p1.x - 1.0).abs < 1e-4 && (p1.y - 2.0).abs < 1e-4 && (p1.z - 3.0).abs < 1e-4, "light 1 at (1,2,3), got #{p1}")
ok &&= check((l1.range - 5.0).abs < 1e-4, "light 1 range 5")
ok &&= check(l1.color.g > 0.9, "light 1 color green")

l2, p2 = lights[2]
ok &&= check(l2.kind.spot?, "light 2 should be spot")
ok &&= check((p2.y - 5.0).abs < 1e-4, "light 2 at y=5")
ok &&= check((l2.inner - 0.2).abs < 1e-4 && (l2.outer - 0.5).abs < 1e-4, "light 2 cone 0.2/0.5")
ok &&= check((l2.range - 8.0).abs < 1e-4, "light 2 range 8")

cams = Flock::Mesh.load_gltf_cameras(path)
ok &&= check(cams.size == 1, "expected 1 camera, got #{cams.size}")
cam = cams[0]
ok &&= check((cam.position.x - 4.0).abs < 1e-4, "camera at x=4, got #{cam.position}")
ok &&= check((cam.target.z - -1.0).abs < 1e-4, "camera aims -Z (target z=-1), got #{cam.target}")
ok &&= check((cam.fov_y - 0.8).abs < 1e-4, "camera fov 0.8")
ok &&= check((cam.near - 0.5).abs < 1e-4 && (cam.far - 200.0).abs < 1e-4, "camera near/far")

File.delete(path)

# --- End-to-end: render a white sphere lit only by the imported directional (red) light. ---
SIZE = 64_u32
instance = WGPU.create_instance
adapter = WGPU.request_adapter(instance)
device = Flock.request_device(instance, adapter)
queue = LibWGPU.device_get_queue(device)
gpu = Flock::GpuContext.new(instance, adapter, device, queue,
  WGPU.null(LibWGPU::Surface), LibWGPU::TextureFormat::RGBA8Unorm,
  SIZE, SIZE, Pointer(Void).null.as(LibSDL::Window), Pointer(Void).null.as(LibSDL::MetalView))
renderer = Flock::Renderer3D.new(gpu)
sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 32, rings: 16, color: Flock::Color.new(0.9, 0.9, 0.9))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(0.02, 0.02, 0.02), ground: Flock::Color.new(0.02, 0.02, 0.02)))
# Camera facing the sphere; the imported directional light travels -Z (lights the front).
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
l, pos = lights[0]
lw = world.spawn
world.add(lw, Flock::Transform3D.new(position: pos))
world.add(lw, l)
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sphere))

td = LibWGPU::TextureDescriptor.new
td.label = WGPU.empty_string_view
td.usage = LibWGPU::TextureUsage::RenderAttachment | LibWGPU::TextureUsage::CopySrc
td.dimension = LibWGPU::TextureDimension::N2D
td.size = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
td.format = LibWGPU::TextureFormat::RGBA8Unorm
td.mip_level_count = 1_u32; td.sample_count = 1_u32
tt = LibWGPU.device_create_texture(device, pointerof(td))
tv = LibWGPU.texture_create_view(tt, Pointer(LibWGPU::TextureViewDescriptor).null)
renderer.render_into(world, tv)

rb = SIZE * 4
bs = (rb * SIZE).to_u64
bd = LibWGPU::BufferDescriptor.new
bd.label = WGPU.empty_string_view
bd.usage = LibWGPU::BufferUsage::MapRead | LibWGPU::BufferUsage::CopyDst
bd.size = bs; bd.mapped_at_creation = 0_u32
rbk = LibWGPU.device_create_buffer(device, pointerof(bd))
src = LibWGPU::TexelCopyTextureInfo.new
src.texture = tt; src.mip_level = 0_u32
src.origin = LibWGPU::Origin3D.new(x: 0_u32, y: 0_u32, z: 0_u32); src.aspect = LibWGPU::TextureAspect::All
lay = LibWGPU::TexelCopyBufferLayout.new
lay.offset = 0_u64; lay.bytes_per_row = rb; lay.rows_per_image = SIZE
dst = LibWGPU::TexelCopyBufferInfo.new; dst.layout = lay; dst.buffer = rbk
ext = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
ed = LibWGPU::CommandEncoderDescriptor.new; ed.label = WGPU.empty_string_view
enc = LibWGPU.device_create_command_encoder(device, pointerof(ed))
LibWGPU.command_encoder_copy_texture_to_buffer(enc, pointerof(src), pointerof(dst), pointerof(ext))
cd = LibWGPU::CommandBufferDescriptor.new; cd.label = WGPU.empty_string_view
cmd = LibWGPU.command_encoder_finish(enc, pointerof(cd))
cmds = StaticArray(LibWGPU::CommandBuffer, 1).new(cmd)
LibWGPU.queue_submit(queue, 1_u64, cmds.to_unsafe)
WGPU.map_buffer_read(instance, rbk, bs)
px = LibWGPU.buffer_get_mapped_range(rbk, 0_u64, bs).as(UInt8*)
o = 32 * rb.to_i + 32 * 4
center = {px[o].to_i, px[o + 1].to_i, px[o + 2].to_i}
LibWGPU.buffer_unmap(rbk)

ok &&= check(center[0] > 60 && center[0] > center[1] * 2 && center[0] > center[2] * 2,
  "sphere lit red by imported light, got #{center}")

LibWGPU.buffer_release(rbk); LibWGPU.texture_view_release(tv); LibWGPU.texture_release(tt)
sphere.release; renderer.release; gpu.release

puts "imported #{lights.size} lights + #{cams.size} camera; lit-sphere center = #{center}"
puts ok ? "✅ glTF scene import (lights + cameras) OK" : "❌ glTF scene import failed"
exit(ok ? 0 : 1)
