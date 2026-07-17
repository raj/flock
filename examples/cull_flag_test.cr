# Headless test for the per-instance frustum-culling opt-out (MeshRenderer#cull), used by
# deformed (skinned/morphed) meshes whose bind-pose bounds don't match their drawn shape.
# A cube is placed far off-screen (its bounding sphere is outside the frustum). With culling
# on (default) the renderer drops it; with cull: false it is drawn regardless. Verified via
# Renderer3D#last_drawn / #last_culled (no pixels needed).
#
#   crystal run examples/cull_flag_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64_u32

gpu, instance, device, queue = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu)

td = LibWGPU::TextureDescriptor.new
td.label = WGPU.empty_string_view
td.usage = LibWGPU::TextureUsage::RenderAttachment
td.dimension = LibWGPU::TextureDimension::N2D
td.size = LibWGPU::Extent3D.new(width: SIZE, height: SIZE, depth_or_array_layers: 1_u32)
td.format = LibWGPU::TextureFormat::RGBA8Unorm
td.mip_level_count = 1_u32; td.sample_count = 1_u32
tt = LibWGPU.device_create_texture(device, pointerof(td))
tv = LibWGPU.texture_create_view(tt, Pointer(LibWGPU::TextureViewDescriptor).null)

# Builds a world with one off-screen cube whose culling is toggled by `cull`.
def make_world(cube, cull : Bool)
  world = Flock::World.new
  world.insert_resource(Flock::Time.new)
  world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
  e = world.spawn
  world.add(e, Flock::Transform3D.new(position: Flock::Vec3.new(100.0, 0.0, 0.0)))
  world.add(e, Flock::MeshRenderer.new(cube, cull: cull))
  world
end

renderer.render_into(make_world(cube, true), tv)
culled_drawn = renderer.last_drawn
culled_culled = renderer.last_culled

renderer.render_into(make_world(cube, false), tv)
nocull_drawn = renderer.last_drawn
nocull_culled = renderer.last_culled

LibWGPU.texture_view_release(tv); LibWGPU.texture_release(tt)
cube.release; renderer.release; gpu.release

puts "cull:true  -> drawn=#{culled_drawn} culled=#{culled_culled}"
puts "cull:false -> drawn=#{nocull_drawn} culled=#{nocull_culled}"
ok = culled_drawn == 0 && culled_culled == 1 && # off-screen + culling on -> dropped
     nocull_drawn == 1 && nocull_culled == 0    # cull: false -> drawn anyway

puts ok ? "✅ per-instance cull opt-out OK" : "❌ cull flag did not control frustum culling"
exit(ok ? 0 : 1)
