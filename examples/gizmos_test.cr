# Gizmos debug-draw readback test (headless): a horizontal line + a circle render as thin
# quads; pixels on a stroke are the gizmo color, empty space is background.
#
#   crystal run examples/gizmos_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128
gpu = Flock.headless_context(SIZE, SIZE)
r2 = Flock::Renderer2D.new(gpu)

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))

giz = Flock::Gizmos.new
world.insert_resource(giz)
# Horizontal red line across the middle (world y=0 → framebuffer center row), thickness 6.
giz.line(Flock::Vec2.new(-40, 0), Flock::Vec2.new(40, 0), Flock::Color::RED, 6.0)
# A green circle near the top.
giz.circle(Flock::Vec2.new(0, 30), 12.0, Flock::Color.new(0.0, 1.0, 0.0))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
r2.render_into(target.view, SIZE.to_u32, SIZE.to_u32, world)
px = target.read

cx = SIZE // 2
on_line = px.rgb(cx, cx)      # world (0,0) → center: on the red line
off = px.rgb(cx, cx - 45)     # well above the line, outside the circle: background
puts "on_line=#{on_line}  off=#{off}  gizmo_lines=#{giz.lines.size}"

Flock.release_all(target, r2, gpu)

ok = on_line[0] > 200 && on_line[1] < 60 &&                 # red stroke
     (off[0] + off[1] + off[2]) < 30 &&                     # empty = background
     giz.lines.size == 1 + 24                               # 1 line + circle (24 segments)
puts ok ? "✅ gizmos OK" : "❌ gizmos unexpected"
exit(ok ? 0 : 1)
