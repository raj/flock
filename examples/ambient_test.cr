# Headless readback test for the hemisphere ambient probe (Flock::AmbientLight). A white
# sphere is lit with sky=blue / ground=red ambient. The top of the sphere (normal up)
# must read bluish and the bottom (normal down, unlit by the directional light) reddish,
# proving the ambient term is directional (driven by the world normal).
#
#   crystal run examples/ambient_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 48, rings: 24, color: Flock::Color.new(0.5, 0.5, 0.5))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(0.2, 0.4, 1.0), ground: Flock::Color.new(1.0, 0.3, 0.2)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sphere))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
px = target.read

def lit?(px : Flock::Pixels, x : Int32, y : Int32)
  r, g, b = px.rgb(x, y)
  r + g + b > 40
end

# First lit pixel scanning down from the top, and up from the bottom, at center column.
top_y = (0...SIZE).find { |y| lit?(px, 64, y) } || 0
bot_y = (0...SIZE).reverse_each.find { |y| lit?(px, 64, y) } || 0
top = px.rgb(64, top_y + 3)  # just inside the top edge (normal up)
bot = px.rgb(64, bot_y - 3)  # just inside the bottom edge (normal down)

puts "top(sky) = #{top}, bottom(ground) = #{bot}"
ok = top[2] > top[0] &&        # top is bluish (sky)
     bot[0] > bot[2] &&        # bottom is reddish (ground)
     bot[0] > bot[1]

target.release
sphere.release
renderer.release
gpu.release

puts ok ? "✅ hemisphere ambient probe OK" : "❌ ambient probe not directional as expected"
exit(ok ? 0 : 1)
