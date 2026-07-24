# Post-processing readback test (headless, no window).
#
# Renders a bright white quad on black into an offscreen scene target, then runs the PostStack
# twice: passthrough (no effects) vs a Bloom effect. Asserts that bloom spreads light into
# pixels just OUTSIDE the quad that are black without it, while keeping the center bright.
#
#   crystal run examples/postfx_test.cr   # exit 0 if OK, 1 otherwise
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
r2 = Flock::Renderer2D.new(gpu)

# Scene: black clear + a 40×40 white sprite at the center.
world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
world.add(e, Flock::Sprite.new(Flock::Vec2.new(40, 40), Flock::Color::WHITE))

# Render the scene once into a sample-able offscreen target.
scene = Flock::PostTarget.new(gpu, SIZE.to_u32, SIZE.to_u32, gpu.format)
r2.render_into(scene.view, SIZE.to_u32, SIZE.to_u32, world)

cx = SIZE // 2
off_x = cx + 26 # 6 px beyond the quad edge (quad half-width = 20)

run = ->(effects : Array(Flock::PostEffect)) do
  stack = Flock::PostStack.new(gpu, effects, Flock::Tonemap::None)
  dst = Flock::RenderTarget.new(gpu, SIZE, SIZE, gpu.format)
  stack.run(scene.view, dst.view, SIZE.to_u32, SIZE.to_u32, gpu.format, Flock::Tonemap::None)
  px = dst.read
  center = px.rgba(cx, cx)
  edge = px.rgba(off_x, cx)
  stack.release
  dst.release
  {center, edge}
end

plain_center, plain_edge = run.call([] of Flock::PostEffect)
bloom_center, bloom_edge = run.call([Flock::Bloom.new(threshold: 0.2f32, intensity: 3.0f32).as(Flock::PostEffect)])

plain_edge_lum = plain_edge[0] + plain_edge[1] + plain_edge[2]
bloom_edge_lum = bloom_edge[0] + bloom_edge[1] + bloom_edge[2]

puts "passthrough: center=#{plain_center} edge(+#{off_x - cx})=#{plain_edge}"
puts "bloom:       center=#{bloom_center} edge(+#{off_x - cx})=#{bloom_edge}"

Flock.release_all(scene, r2, gpu)

ok = plain_center[0] > 200 &&      # scene preserved (bright center)
     bloom_center[0] > 200 &&      # bloom keeps the center bright
     plain_edge_lum < 30 &&        # outside the quad is black without bloom
     bloom_edge_lum > 60           # bloom spread light there

if ok
  puts "✅ post-fx OK (bloom edge lum #{bloom_edge_lum} > passthrough #{plain_edge_lum})"
  exit 0
else
  puts "❌ post-fx unexpected"
  exit 1
end
