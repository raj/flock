# Readback test: a GPU-skinned caster above a small ground casts a shadow (frustum fit). A single-joint skinned quad HIGH above a SMALL ground (outside the rigid AABB), so the
# floats horizontally above a ground slab, lit by a directional light. The scene is rendered
# with the light casting shadows and not; the ground point directly under the skinned quad
# must be markedly darker with shadows on (proving the skinned depth pass writes the caster
# into the shadow map), while a far control point stays lit either way.
#
#   crystal run examples/shadow_skinned_fit_test.cr   # exit 0 if OK
require "../src/flock/gpu"
require "base64"

SIZE = 128
LE = IO::ByteFormat::LittleEndian

io = IO::Memory.new
# POSITION (0,48): a horizontal quad at y=2 (an elevated occluder).
[-0.9f32, 3.5f32, -0.9f32, 0.9f32, 3.5f32, -0.9f32,
 0.9f32, 3.5f32, 0.9f32, -0.9f32, 3.5f32, 0.9f32].each { |f| io.write_bytes(f, LE) }
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

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.7, 0.7, 0.7))
File.delete(path) rescue nil
ground = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.75, 0.75, 0.75))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(0.08, 0.08, 0.08), ground: Flock::Color.new(0.08, 0.08, 0.08)))
cam = Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 9.0, 11.0), target: Flock::Vec3.new(0.0, 0.5, 0.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK)
world.add(world.spawn, cam)
lw = world.spawn
world.add(lw, Flock::Transform3D.new)
world.add(lw, Flock::Light.directional(Flock::Vec3.new(0.15, -1.0, 0.1), Flock::Color::WHITE, 1.4, casts_shadows: true))
g = world.spawn
world.add(g, Flock::Transform3D.new(position: Flock::Vec3.new(0.0, 0.0, 0.0), scale: Flock::Vec3.new(3.0, 0.2, 3.0)))
world.add(g, Flock::MeshRenderer.new(ground))
model = Flock::GpuSkinnedModel.spawn(scene, world, renderer, gpu)
model.apply

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

vp = cam.view_projection(1.0f32)
def project(vp : Flock::Mat4, p : Flock::Vec3) : {Int32, Int32}
  num = vp.transform_point(p); m = vp.m
  w = m[3] * p.x + m[7] * p.y + m[11] * p.z + m[15]
  {((num.x / w * 0.5 + 0.5) * SIZE).to_i.clamp(0, SIZE.to_i - 1),
   ((0.5 - num.y / w * 0.5) * SIZE).to_i.clamp(0, SIZE.to_i - 1)}
end
under = project(vp, Flock::Vec3.new(0.2, 0.02, 0.15)) # small ground under the elevated quad
far = project(vp, Flock::Vec3.new(-1.2, 0.02, 0.0))    # ground left of the shadow (lit)

render_lum = ->do
  renderer.render_into(world, target.view)
  px = target.read
  lum = ->(pt : {Int32, Int32}) { c = px.rgb(pt[0], pt[1]); c[0] + c[1] + c[2] }
  {lum.call(under), lum.call(far)}
end

on_under, on_far = render_lum.call
world.query(Flock::Transform3D, Flock::Light) do |_e, _tf, lt|
  l = lt.value; l.casts_shadows = false; lt.value = l
end
off_under, off_far = render_lum.call

target.release
ground.release; renderer.release; gpu.release

puts "under quad: shadows on=#{on_under} off=#{off_under}   far control: on=#{on_far} off=#{off_far}"
ok = off_under > 120 &&               # lit ground under the quad with shadows off
     on_under < off_under * 0.6 &&     # skinned quad darkens it with shadows on
     on_far > 120                      # far point stays lit

puts ok ? "✅ skinned caster above a small ground casts a shadow (frustum fit) OK" : "❌ skinned caster did not cast a shadow"
exit(ok ? 0 : 1)
