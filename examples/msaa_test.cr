# Headless readback test for MSAA anti-aliasing (Renderer3D sample_count). A flat white
# quad is rotated 30° around Z so its silhouette edges are diagonal, on a black background.
# The scene is rendered twice: once with sample_count = 1 (aliased) and once with 4 (MSAA).
# The quad faces the camera, so its interior is uniformly lit — any pixel whose luminance
# falls *between* black and the full quad color must be an anti-aliased edge sample. MSAA
# must produce many more such partial-coverage pixels than the aliased render.
#
#   crystal run examples/msaa_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
quad = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.9, 0.9, 0.9))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
# Flat ambient so the camera-facing quad is a single uniform color (no interior gradients).
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
q = world.spawn
world.add(q, Flock::Transform3D.new(
  rotation: Flock::Vec3.new(0.0, 0.0, 0.52), scale: Flock::Vec3.new(2.0, 2.0, 0.1)))
world.add(q, Flock::MeshRenderer.new(quad))

# Counts pixels with partial (anti-aliased) coverage — luminance strictly between the
# black background and the full quad color — for a renderer at the given sample count.
def count_edge_pixels(gpu, world, sample_count : Int32) : Int32
  renderer = Flock::Renderer3D.new(gpu, sample_count)
  target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
  renderer.render_into(world, target.view)
  px = target.read

  edge = 0
  (0...SIZE).each do |y|
    (0...SIZE).each do |x|
      # Green channel: 0 on background, ~230 on the quad. Partial coverage lands between.
      g = px.rgb(x, y)[1]
      edge += 1 if g > 30 && g < 200
    end
  end
  target.release
  renderer.release
  edge
end

aa = count_edge_pixels(gpu, world, 1)
msaa = count_edge_pixels(gpu, world, 4)
Flock.release_all(quad, gpu)

puts "partial-coverage edge pixels: aliased=#{aa}, MSAA 4x=#{msaa}"
ok = msaa > aa * 3 && msaa > 100

puts ok ? "✅ MSAA anti-aliasing OK" : "❌ MSAA did not smooth edges as expected"
exit(ok ? 0 : 1)
