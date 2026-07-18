# Readback test: a GPU-skinned caster above a small ground casts a shadow (frustum fit). A single-joint skinned quad HIGH above a SMALL ground (outside the rigid AABB), so the
# floats horizontally above a ground slab, lit by a directional light. The scene is rendered
# with the light casting shadows and not; the ground point directly under the skinned quad
# must be markedly darker with shadows on (proving the skinned depth pass writes the caster
# into the shadow map), while a far control point stays lit either way.
#
#   crystal run examples/shadow_skinned_fit_test.cr   # exit 0 if OK
require "../src/flock/gpu"
SIZE = 128

path = "examples/assets/gltf/shadow_skinned_fit.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.7, 0.7, 0.7))
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

Flock.release_all(target, ground, renderer, gpu)

puts "under quad: shadows on=#{on_under} off=#{off_under}   far control: on=#{on_far} off=#{off_far}"
ok = off_under > 120 &&               # lit ground under the quad with shadows off
     on_under < off_under * 0.6 &&     # skinned quad darkens it with shadows on
     on_far > 120                      # far point stays lit

puts ok ? "✅ skinned caster above a small ground casts a shadow (frustum fit) OK" : "❌ skinned caster did not cast a shadow"
exit(ok ? 0 : 1)
