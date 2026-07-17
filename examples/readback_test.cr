# Readback rendering test (headless, no window).
#
# Renders a red sprite on a black background into an offscreen texture, copies the
# texture to a buffer, maps it, and checks the pixel colors (center = red, corner
# = black). Reusable base for automated GPU tests.
#
#   crystal run examples/readback_test.cr   # exit 0 if OK, 1 otherwise
require "../src/flock/gpu"

SIZE = 64 # 64*4 = 256 bytes/row (already aligned for copy_texture_to_buffer)

# --- Headless GPU context (no surface/window) ---
gpu = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer2D.new(gpu)

# --- Scene: camera (black clear) + red 40x40 sprite at center ---
world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
world.add(e, Flock::Sprite.new(Flock::Vec2.new(40, 40), Flock::Color::RED))

# --- Offscreen target (RGBA8, renderable + copyable) ---
target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

# --- Render ---
renderer.render_into(target.view, SIZE.to_u32, SIZE.to_u32, world)

# --- Read back ---
px = target.read

cx = SIZE // 2
center = px.rgba(cx, cx)
corner = px.rgba(2, 2)

puts "center (#{cx},#{cx}) = #{center}"
puts "corner (2,2)   = #{corner}"

ok = center[0] > 200 && center[1] < 60 && center[2] < 60 && # red center
     corner[0] < 60 && corner[1] < 60 && corner[2] < 60     # black corner

# Cleanup
target.release
renderer.release
gpu.release

if ok
  puts "✅ readback OK (draws=#{renderer.last_draw_calls}, sprites=#{renderer.last_sprites})"
  exit 0
else
  puts "❌ unexpected colors"
  exit 1
end
