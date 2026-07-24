# Sprite scissor-clipping readback test (headless).
#
# Draws a 60×60 white sprite centered at the origin, clipped to its LEFT half via a
# world-space ClipRect. Asserts the left half is drawn (white) and the right half is
# clipped away (background) — proving Sprite2D#clip → framebuffer scissor works.
#
#   crystal run examples/clip_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
r2 = Flock::Renderer2D.new(gpu)

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
# White sprite spanning world [-30, 30]²; clip to the left half (x ∈ [-30, 0]).
world.add(e, Flock::Sprite2D.new(Flock::Vec2.new(60, 60), Flock::Color::WHITE,
  clip: Flock::ClipRect.new(Flock::Vec2.new(-30, -30), Flock::Vec2.new(0, 30))))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
r2.render_into(target.view, SIZE.to_u32, SIZE.to_u32, world)
px = target.read

cx = SIZE // 2
left = px.rgb(cx - 18, cx)  # inside the clip (left half) → white
right = px.rgb(cx + 18, cx) # outside the clip (right half) → background
puts "left(-18)  = #{left}"
puts "right(+18) = #{right}"

Flock.release_all(target, r2, gpu)

ok = left[0] > 200 && left[1] > 200 && left[2] > 200 &&        # drawn
     right[0] < 40 && right[1] < 40 && right[2] < 40           # clipped away

puts ok ? "✅ sprite clipping OK" : "❌ clip unexpected"
exit(ok ? 0 : 1)
