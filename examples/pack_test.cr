# Asset packing test (headless): a .flkpack round-trips a raw blob AND renders an image
# byte-identically to loading it loose (proving mount + packed decode).
#
#   crystal run examples/pack_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 96
gpu = Flock.headless_context(SIZE, SIZE)
r2 = Flock::Renderer2D.new(gpu)
png = "#{__DIR__}/assets/sprite.png"

ok = true
report = ->(name : String, pass : Bool) { ok = false unless pass; puts "#{pass ? "✓" : "✗"} #{name}" }

# --- Build a pack: the image + a compressible raw blob ---
blob = ("FLOCK" * 400).to_slice # repetitive → should DEFLATE well
pack_path = File.tempname("flock", ".flkpack")
w = Flock::PackWriter.new
w.add_file(png, "sprite.png")
w.add_bytes("hello.txt", blob)
size = w.write(pack_path)
report.call("pack written", File.exists?(pack_path) && size > 0)
report.call("compressed (< raw sum)", size < (File.size(png) + blob.size))

pack = Flock::Pack.open(pack_path)
report.call("keys present", pack.keys.sort == ["hello.txt", "sprite.png"])
report.call("raw blob round-trips", pack.read("hello.txt") == blob)

# Render the sprite from a LOOSE load and from the PACK; the pixels must match.
draw = ->(tex : Flock::Texture) do
  world = Flock::World.new
  world.add(world.spawn, Flock::Camera2D.new(clear_color: Flock::Color::BLACK))
  id = r2.register_texture(tex)
  e = world.spawn
  world.add(e, Flock::Transform2D.at(0, 0))
  world.add(e, Flock::Sprite2D.new(Flock::Vec2.new(64, 64), Flock::Color::WHITE, id))
  target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
  r2.render_into(target.view, SIZE.to_u32, SIZE.to_u32, world)
  px = target.read
  target.release
  px.data.dup
end

loose = draw.call(Flock::Texture.load(gpu, png))

assets = Flock::Assets.new(gpu)
assets.mount(pack)
h = assets.load(Flock::Texture, "sprite.png") # resolves from the pack
packed = draw.call(assets.get(h))

report.call("packed image renders identically to loose", loose == packed)
report.call("something was drawn (not blank)", loose.any? { |b| b > 0 })

pack.close
File.delete(pack_path)
Flock.release_all(assets, r2, gpu)

puts ok ? "✅ asset packing OK" : "❌ asset packing failed"
exit(ok ? 0 : 1)
