# Headless readback test for 3D alpha blending (MeshRenderer#transparent). A red opaque
# panel sits behind a blue panel. The blue panel is rendered twice — once transparent
# (tint alpha 0.5), once opaque — and the overlap pixel is sampled both times. When the
# blue panel is transparent the red panel must show through (red channel present); when
# opaque it must fully hide the red. This proves back-to-front alpha blending works.
#
#   crystal run examples/transparency_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
red = Flock::Mesh.cube(gpu, color: Flock::Color.new(1.0, 0.1, 0.1))
blue = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.1, 0.1, 1.0))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
# Bright, flat ambient so the panel base colors dominate (blend result is easy to read).
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(0.9, 0.9, 0.9), ground: Flock::Color.new(0.9, 0.9, 0.9)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))

# Opaque red panel behind.
rp = world.spawn
world.add(rp, Flock::Transform3D.new(position: Flock::Vec3.new(0.0, 0.0, -1.0), scale: Flock::Vec3.new(3.0, 3.0, 0.1)))
world.add(rp, Flock::MeshRenderer.new(red))

# Blue panel in front. `transparent` is flipped between the two renders.
bp = world.spawn
world.add(bp, Flock::Transform3D.new(position: Flock::Vec3.new(0.0, 0.0, 0.5), scale: Flock::Vec3.new(1.5, 1.5, 0.1)))
world.add(bp, Flock::MeshRenderer.new(blue, tint: Flock::Color.new(1.0, 1.0, 1.0, 0.5), transparent: true))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

# Renders and returns the center pixel {r, g, b}.
render_center = ->{
  renderer.render_into(world, target.view)
  target.read.rgb(64, 64)
}

# Render 1: blue panel transparent -> red shows through.
trans = render_center.call

# Render 2: same blue panel, opaque -> red hidden.
world.query(Flock::Transform3D, Flock::MeshRenderer) do |_e, _tf, mr|
  m = mr.value
  if m.transparent
    m.transparent = false
    mr.value = m
  end
end
opaque = render_center.call

Flock.release_all(target, red, blue, renderer, gpu)

puts "overlap transparent = #{trans}, opaque = #{opaque}"
ok = trans[2] > 60 &&                 # blue visible through the translucent panel
     trans[0] > 60 &&                 # red shows through the translucent panel
     opaque[0] < trans[0] * 0.5 &&    # opaque panel hides most of the red
     opaque[2] > 60                   # opaque panel is blue

puts ok ? "✅ alpha blending OK" : "❌ transparency did not blend as expected"
exit(ok ? 0 : 1)
