# Readback test for the backend-agnostic Sprite2D on the native renderer: registers a
# green texture in Renderer2D's bank and draws a Sprite2D that references it by id; the
# center must read green (texture-bank resolution), the corner black.
#
#   crystal run examples/sprite2d_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64

gpu = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer2D.new(gpu)
green = renderer.register_texture(Flock::Texture.from_pixels(gpu, 1, 1, Bytes[0_u8, 255_u8, 0_u8, 255_u8]))

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
world.add(e, Flock::Sprite2D.new(Flock::Vec2.new(40, 40), Flock::Color::WHITE, green))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(target.view, SIZE.to_u32, SIZE.to_u32, world)
px = target.read

cx = SIZE // 2
center = px.rgb(cx, cx)
corner = px.rgb(2, 2)

puts "center = #{center}, corner = #{corner}"
ok = center[1] > 200 && center[0] < 60 && center[2] < 60 && # green center (from the bank texture)
     corner[0] < 60 && corner[1] < 60 && corner[2] < 60      # black corner

target.release
renderer.release
gpu.release

puts ok ? "✅ native Sprite2D (shared component) OK" : "❌ Sprite2D not rendered as expected"
exit(ok ? 0 : 1)
