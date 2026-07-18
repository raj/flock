# Headless readback test for glTF morph targets (Flock::MorphModel). A quad sits on the
# LEFT; a single morph target displaces every vertex +1.2 in X, and a "weights" animation
# ramps the weight 0 -> 1 over 1s. At weight 0 the quad covers the left of the frame; at
# weight 1 the blended vertices move it to the right. Sampling a left and a right pixel at
# each weight proves the CPU vertex blend + weights animation work.
#
#   crystal run examples/morph_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

path = "examples/assets/gltf/morph.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.9, 0.9, 0.2))
raise "no morph parts parsed" if scene.morphs.empty?

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
morph = Flock::MorphModel.spawn(scene, world, gpu)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

# Renders at morph time `t` and returns luminance at a left column and a right column.
render_lr = ->(t : Float32) do
  morph.time = t
  morph.apply(world)
  renderer.render_into(world, target.view)
  px = target.read
  lum = ->(x : Int32) {
    c = px.rgb(x, 64)
    c[0] + c[1] + c[2]
  }
  l = lum.call(36); r = lum.call(92)
  {l, r}
end

base_l, base_r = render_lr.call(0.0f32)     # weight 0 -> quad on the left
morph_l, morph_r = render_lr.call(1.0f32)   # weight 1 -> quad shifted right

Flock.release_all(target, renderer, gpu)

puts "weight 0: left=#{base_l} right=#{base_r}   weight 1: left=#{morph_l} right=#{morph_r}"
ok = base_l > 150 && base_r < 40 &&   # unmorphed: quad on the left
     morph_r > 150 && morph_l < 40    # morphed: quad moved to the right

puts ok ? "✅ glTF morph targets OK" : "❌ morph blend did not move the mesh as expected"
exit(ok ? 0 : 1)
