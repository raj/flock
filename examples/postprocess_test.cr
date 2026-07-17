# Headless readback test for HDR post-processing / tonemapping (Renderer3D tonemap:). A
# white sphere is lit by a very bright directional light, producing radiance well above 1.0.
# Rendered without tonemapping (Tonemap::None) the scene writes straight to LDR RGBA8 and
# the bright side clips to a flat, fully-saturated white. With ACES tonemapping the scene
# renders to an HDR (rgba16float) target and a fullscreen pass compresses the highlights, so
# far fewer pixels are blown out and the shading gradient is preserved.
#
#   crystal run examples/postprocess_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 48, rings: 24, color: Flock::Color.new(1.0, 1.0, 1.0))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(0.1, 0.1, 0.1), ground: Flock::Color.new(0.1, 0.1, 0.1)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
# Very bright light toward the camera -> radiance far above 1.0 on the facing hemisphere.
lw = world.spawn
world.add(lw, Flock::Transform3D.new)
world.add(lw, Flock::Light.directional(Flock::Vec3.new(0.0, 0.0, -1.0), Flock::Color.new(1.0, 1.0, 1.0), 2.5))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sphere))

# Counts fully-saturated (blown-out) pixels for a renderer at the given tonemap mode.
def saturated(gpu, world, tonemap : Flock::Tonemap) : Int32
  renderer = Flock::Renderer3D.new(gpu, 1, tonemap)
  target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
  renderer.render_into(world, target.view)
  px = target.read

  blown = 0
  (0...SIZE).each do |y|
    (0...SIZE).each do |x|
      r, g, b = px.rgb(x, y)
      blown += 1 if r >= 250 && g >= 250 && b >= 250
    end
  end
  target.release
  renderer.release
  blown
end

none = saturated(gpu, world, Flock::Tonemap::None)
aces = saturated(gpu, world, Flock::Tonemap::Aces)
Flock.release_all(sphere, gpu)

puts "blown-out pixels: none=#{none}, ACES=#{aces}"
ok = none > 300 &&            # without tonemapping the bright side clips badly
     aces < none * 0.3        # ACES recovers most of the blown highlights

puts ok ? "✅ HDR tonemapping OK" : "❌ tonemapping did not recover the highlights"
exit(ok ? 0 : 1)
