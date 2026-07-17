# Configurable sampler test (headless, readback).
#
# A 2x2 red/blue checker texture sampled with LINEAR filtering: the center of the
# quad (uv 0.5) blends the texels into purple. NEAREST would give a pure color.
# Asserts the center has both red and blue -> linear filtering is active.
#
#   crystal run examples/sampler_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64

gpu = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer2D.new(gpu)

# 2x2 checker: red / blue on top row, blue / red on bottom.
checker = Bytes[
  255_u8, 0_u8, 0_u8, 255_u8, 0_u8, 0_u8, 255_u8, 255_u8,
  0_u8, 0_u8, 255_u8, 255_u8, 255_u8, 0_u8, 0_u8, 255_u8,
]
tex = Flock::Texture.from_pixels(gpu, 2, 2, checker, Flock::SamplerFilter::Linear)

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
world.add(e, Flock::Sprite.new(Flock::Vec2.new(40, 40), Flock::Color::WHITE, tex))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(target.view, SIZE.to_u32, SIZE.to_u32, world)
px = target.read

center = px.rgb(SIZE // 2, SIZE // 2)

puts "center = #{center}"
ok = center[0] > 60 && center[2] > 60 # both red and blue -> linear blend (not a pure texel)

target.release
tex.release
renderer.release
gpu.release

puts ok ? "✅ configurable sampler (linear) OK" : "❌ linear filtering not applied"
exit(ok ? 0 : 1)
