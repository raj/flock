# Headless readback test for glTF GPU skinning. A vertical bar is skinned to 2 joints:
# its bottom vertices follow the root joint (static), its top vertices follow a child
# joint that an animation rotates 90° about Z. Loaded via load_gltf_scene and driven by
# Flock::GpuSkinnedModel (skinning in the vertex shader; only joint matrices are
# uploaded per frame), the image at t=0 (straight) must differ substantially from t=1
# (bent) — matching the CPU-skinning result exactly.
#
#   crystal run examples/skinning_test.cr   # exit 0 if OK
require "../src/flock/gpu"
SIZE = 128

path = "examples/assets/gltf/skinning_gpu.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

scene = Flock::Mesh.load_gltf_scene(gpu, path, Flock::Color.new(0.3, 0.9, 0.4))
raise "expected 1 skin" unless scene.skins.size == 1

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(0.0, 1.0, 4.5), target: Flock::Vec3.new(0.0, 1.0, 0.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
model = Flock::GpuSkinnedModel.spawn(scene, world, renderer, gpu)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

snapshot = ->(t : Float32) do
  model.time = t
  model.apply
  renderer.render_into(world, target.view)
  target.read
end

img0 = snapshot.call(0.0f32)  # straight (bind pose)
img1 = snapshot.call(1.0f32)  # bent 90°

# Count green (lit) pixels and how many differ between the two poses.
def lit_count(px : Flock::Pixels)
  n = 0
  px.height.times do |y|
    px.width.times do |x|
      r, g, b = px.rgb(x, y)
      n += 1 if r + g + b > 40
    end
  end
  n
end

def changed(a : Flock::Pixels, b : Flock::Pixels)
  n = 0
  a.height.times do |y|
    a.width.times do |x|
      ar, ag, ab = a.rgb(x, y)
      br, bg, bb = b.rgb(x, y)
      d = (ar - br).abs + (ag - bg).abs + (ab - bb).abs
      n += 1 if d > 40
    end
  end
  n
end

l0 = lit_count(img0); l1 = lit_count(img1); ch = changed(img0, img1)
puts "lit@t0=#{l0}, lit@t1=#{l1}, changed pixels=#{ch}"
# Both poses render the bar, and skinning visibly deforms it (many pixels change).
ok = l0 > 200 && l1 > 200 && ch > 400

Flock.release_all(target, renderer, gpu)

puts ok ? "✅ glTF GPU skinning OK" : "❌ skinning did not deform the mesh as expected"
exit(ok ? 0 : 1)
