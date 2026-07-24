# SpriteBatch readback test (headless): many quads from ONE entity render in a SINGLE
# instanced draw call, each at its own position/color.
#
#   crystal run examples/sprite_batch_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 96
gpu = Flock.headless_context(SIZE, SIZE)
r2 = Flock::Renderer2D.new(gpu)

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))

# One batch entity, two white-textured quads: red at world (-20,0), green at (+20,0).
items = [
  Flock::BatchItem.new(Flock::Vec2.new(-20, 0), Flock::Vec2.new(20, 20), Flock::Color::RED),
  Flock::BatchItem.new(Flock::Vec2.new(20, 0), Flock::Vec2.new(20, 20), Flock::Color.new(0.0, 1.0, 0.0)),
]
world.add(world.spawn, Flock::Transform2D.at(0, 0))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
world.add(e, Flock::SpriteBatch.new(items))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
r2.render_into(target.view, SIZE.to_u32, SIZE.to_u32, world)
px = target.read

cx = SIZE // 2
left = px.rgb(cx - 20, cx)  # red quad
right = px.rgb(cx + 20, cx) # green quad
puts "left = #{left}  right = #{right}  draws = #{r2.last_draw_calls}"

Flock.release_all(target, r2, gpu)

ok = left[0] > 200 && left[1] < 60 &&              # red
     right[1] > 200 && right[0] < 60 &&            # green
     r2.last_draw_calls == 1                        # both quads in ONE instanced draw
puts ok ? "✅ sprite batch OK" : "❌ sprite batch unexpected"
exit(ok ? 0 : 1)
