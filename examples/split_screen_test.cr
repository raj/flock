# Multi-viewport / per-region clear test (headless, readback).
#
# Two Camera2D with side-by-side viewports and distinct clear colors. Reads the
# offscreen result back and asserts the left half is red and the right half blue —
# proving each viewport clears its own region.
#
#   crystal run examples/split_screen_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128
HALF = (SIZE // 2)

gpu = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer2D.new(gpu)

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(
  viewport: Flock::Viewport.new(0.0f32, 0.0f32, HALF.to_f32, SIZE.to_f32),
  clear_color: Flock::Color::RED, order: 0))
world.add(world.spawn, Flock::Camera2D.new(
  viewport: Flock::Viewport.new(HALF.to_f32, 0.0f32, HALF.to_f32, SIZE.to_f32),
  clear_color: Flock::Color::BLUE, order: 1))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

renderer.render_into(target.view, target.width, target.height, world)

px = target.read

left = px.rgb((HALF // 2).to_i, (SIZE // 2).to_i)
right = px.rgb((HALF + HALF // 2).to_i, (SIZE // 2).to_i)

puts "left half  = #{left}"
puts "right half = #{right}"

ok = left[0] > 200 && left[2] < 60 &&  # left red
     right[2] > 200 && right[0] < 60   # right blue

target.release
renderer.release
gpu.release

puts ok ? "✅ per-region clear (split-screen) OK" : "❌ regions not cleared as expected"
exit(ok ? 0 : 1)
