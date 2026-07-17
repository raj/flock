# Test that the renderer's texture bind-group cache evicts entries when a texture is
# released (Texture#on_release), so a scene that churns dynamic textures (e.g. per-frame
# text) doesn't leak a bind group + retained view per texture. Uses Renderer3D's cache
# count. Simulates several "frames" of one-shot textures and asserts the cache stays bounded.
#
#   crystal run examples/tex_cache_evict_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 32

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
quad = Flock::Mesh.cube(gpu, color: Flock::Color::WHITE)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0)))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(quad))

start = renderer.cached_texture_groups

# 8 "frames": each makes a fresh 1x1 texture, renders with it, then releases it. Without
# eviction the cache would grow by one every frame.
max_seen = 0
8.times do |i|
  tex = Flock::Texture.from_pixels(gpu, 1, 1, Bytes[(i * 30).to_u8, 80_u8, 200_u8, 255_u8])
  world.query(Flock::Transform3D, Flock::MeshRenderer) do |_e, _tf, mr|
    m = mr.value; m.texture = tex; mr.value = m
  end
  renderer.render_into(world, target.view)
  max_seen = Math.max(max_seen, renderer.cached_texture_groups)
  tex.release # <- fires on_release -> evicts its cached bind group
end

after = renderer.cached_texture_groups

target.release
quad.release; renderer.release; gpu.release

puts "cache: start=#{start} max-during=#{max_seen} after=#{after} (8 dynamic textures)"
# Each frame adds one entry then releasing evicts it, so the cache never accumulates:
# after == start, and it never held more than ~one dynamic entry at a time.
ok = after == start && max_seen <= start + 1

puts ok ? "✅ texture cache eviction OK" : "❌ cache grew with dynamic textures (leak)"
exit(ok ? 0 : 1)
