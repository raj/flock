# Regression test: a GPU-morph mesh AND a transparent mesh in the SAME scene. The morph
# pass binds group2 to its own (non-IBL) layout; the transparent pass must restore group2
# to the IBL group before drawing, or wgpu raises an "incompatible bind group" validation
# error. This test would crash before that fix; now it renders and the translucent red
# panel blends over the (green) morph quad behind it.
#
#   crystal run examples/mixed_pass_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64

path = "examples/assets/gltf/mixed_pass.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.1, 0.9, 0.1)) # green

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
Flock::GpuMorphModel.spawn(scene, world, renderer, gpu) # opaque, binds group2 to morph layout
# A translucent RED panel in front of the morph quad.
red = Flock::Mesh.cube(gpu, color: Flock::Color.new(1.0, 0.1, 0.1))
tp = world.spawn
world.add(tp, Flock::Transform3D.new(position: Flock::Vec3.new(0.0, 0.0, 0.6), scale: Flock::Vec3.new(1.4, 1.4, 0.1)))
world.add(tp, Flock::MeshRenderer.new(red, tint: Flock::Color.new(1.0, 1.0, 1.0, 0.5), transparent: true))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view) # <-- would raise a validation error before the group2 fix

px = target.read
center = px.rgb(32, 32)

Flock.release_all(target, red, renderer, gpu)

puts "center = #{center} (translucent red over green morph quad)"
# Both channels present: red panel (R) blended over the green morph quad (G) behind it.
ok = center[0] > 60 && center[1] > 40

puts ok ? "✅ morph + transparent in one scene OK" : "❌ mixed pass did not composite as expected"
exit(ok ? 0 : 1)
