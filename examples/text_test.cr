# Text rendering test (headless, readback).
#
# Renders "HI" via SDL_ttf into a texture, draws it as a sprite into an offscreen
# target, reads back the pixels and checks that text pixels (bright) exist.
#
#   crystal run examples/text_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128
FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"

gpu = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer2D.new(gpu)

# --- Text -> texture ---
font = Flock::Font.load(FONT, 48)
text_tex = font.render_texture(gpu, "HI")
puts "text texture: #{text_tex.width}x#{text_tex.height}"

world = Flock::World.new
world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform2D.at(0, 0))
world.add(e, Flock::Sprite.new(Flock::Vec2.new(text_tex.width, text_tex.height), Flock::Color::WHITE, text_tex))

# --- Offscreen target + render ---
target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(target.view, SIZE.to_u32, SIZE.to_u32, world)
px = target.read

# Count the bright pixels (white glyphs on a black background).
bright = 0
(0...SIZE).each do |y|
  (0...SIZE).each do |x|
    r, g, b = px.rgb(x, y)
    bright += 1 if r > 60 || g > 60 || b > 60
  end
end

puts "bright pixels (text) = #{bright}"

# Cleanup
target.release
text_tex.release
font.release
renderer.release
gpu.release

if bright > 20
  puts "✅ text rendering OK"
  exit 0
else
  puts "❌ no text pixels detected"
  exit 1
end
