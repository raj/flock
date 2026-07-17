# Headless readback test for unified 2D + 3D in one frame. Renders a 3D cube
# (Renderer3D, clears), then a 2D white sprite on top (Renderer2D overlay mode),
# into the same target. Asserts: the 3D cube shows at center (green), the 2D sprite
# shows at the top-left (white, high blue), and an empty corner stays background.
#
#   crystal run examples/render_2d3d_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)

r3 = Flock::Renderer3D.new(gpu)
r2 = Flock::Renderer2D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.2, 0.8, 0.3))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
# 3D scene.
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
c = world.spawn
world.add(c, Flock::Transform3D.new)
world.add(c, Flock::MeshRenderer.new(cube))
# 2D overlay: a white sprite in the top-left area (world y up; -45,+45 -> screen ~19,19).
world.add(world.spawn, Flock::Camera2D.new(clear_color: nil))
s = world.spawn
world.add(s, Flock::Transform2D.at(-45.0, 45.0))
world.add(s, Flock::Sprite.new(Flock::Vec2.new(24, 24), Flock::Color::WHITE))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

# The unified composition: 3D first (clears), then 2D on top (load_previous).
r3.render_into(world, target.view)
r2.render_into(target.view, SIZE.to_u32, SIZE.to_u32, world, load_previous: true)
px = target.read

center = px.rgb(64, 64)    # 3D cube (green)
sprite = px.rgb(19, 19)    # 2D overlay (white)
corner = px.rgb(120, 120)  # background

puts "center(3D) = #{center}"
puts "sprite(2D) = #{sprite}"
puts "corner      = #{corner}"

ok = center[1] > 60 && center[1].to_i > center[2].to_i && # 3D cube: green, non-bg
     sprite[2] > 90 && sprite[0] > 90 &&                  # 2D sprite: white (high blue+red)
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20    # background

target.release
cube.release
r2.release
r3.release
gpu.release

puts ok ? "✅ unified 2D + 3D OK" : "❌ 2D/3D composition not as expected"
exit(ok ? 0 : 1)
