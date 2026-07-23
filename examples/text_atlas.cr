# Glyph-atlas text: draws strings as batched quads sampling one atlas texture (no
# per-string GPU texture), and updates a label every few frames — rebuilt only on change
# via the ECS change detection.
#
#   crystal run examples/text_atlas.cr
#   WGPU_FRAMES=120 crystal run examples/text_atlas.cr   # headless smoke
require "../src/flock/gpu"

FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — text atlas", 800, 600))
app.add_plugin(Flock::TextLabelPlugin.new)

app.add_startup do |world, cmd|
  cmd.spawn(Flock::Camera2D.new(position: Flock::Vec2.new(400, 300),
    clear_color: Flock::Color.new(0.05, 0.06, 0.09)))
  atlas = world.resource(Flock::Assets).glyph_atlas(FONT, 40)
  cmd.spawn(Flock::Transform2D.at(80, 460), Flock::TextLabel.new(atlas, "Hello, Flock!", Flock::Color.new(0.65, 0.9, 1.0)))
  cmd.spawn(Flock::Transform2D.at(80, 380), Flock::TextLabel.new(atlas, "score: 0"))
  cmd.spawn(Flock::Transform2D.at(80, 300), Flock::TextLabel.new(atlas, "The quick brown fox\njumps over 13 lazy dogs.", Flock::Color.new(0.8, 0.82, 0.9)))
rescue ex
  puts "font unavailable: #{ex.message}"
end

# Dynamic text: bump a counter and rewrite the "score" label (rebuilt only when it changes).
frame = 0
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  frame += 1
  world.query(Flock::TextLabel) do |e, tl|
    next unless tl.value.text.starts_with?("score")
    t = tl.value
    t.text = "score: #{frame // 20}"
    tl.value = t
    world.mark_changed(e, Flock::TextLabel)
  end
end

app.run
