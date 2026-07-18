# Headless readback test for glTF node animation. A quad's node has a translation
# animation from x=-1.2 (t=0) to x=+1.2 (t=1). Loaded as a scene and driven by
# Flock::AnimatedModel: at t=0 the quad sits left (center empty); at t=0.5 the sampled
# translation is 0 so it sits at the center. Proves keyframe sampling + node posing.
#
#   crystal run examples/anim_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

path = "examples/assets/gltf/anim.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.3, 0.9, 0.4))
raise "expected 1 animation" unless scene.animations.size == 1
raise "expected duration ~1s" unless (scene.animations[0].duration - 1.0f32).abs < 1e-4

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
model = Flock::AnimatedModel.spawn(scene, world)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

center_at = ->(t : Float32) do
  model.time = t
  model.apply(world)
  renderer.render_into(world, target.view)
  target.read.rgb(64, 64)
end

start = center_at.call(0.0f32)  # quad at x=-1.2 -> center empty
mid = center_at.call(0.5f32)    # translation sampled to 0 -> center has quad

puts "center@t=0 = #{start} (expect empty), center@t=0.5 = #{mid} (expect green)"
ok = (start[0] + start[1] + start[2] < 30) &&              # empty at start
     (mid[1] > 60 && mid[1] > mid[0] && mid[1] > mid[2])   # green quad centered

Flock.release_all(target, renderer, gpu)

puts ok ? "✅ glTF node animation OK" : "❌ animation sampling not as expected"
exit(ok ? 0 : 1)
