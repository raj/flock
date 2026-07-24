# Asset server test (headless): ref-counted Handle(T), dedup, hot-reload, and free→placeholder.
#
#   crystal run examples/asset_server_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 32
gpu = Flock.headless_context(SIZE, SIZE)
assets = Flock::Assets.new(gpu)

# Work on a private copy so the hot-reload touch doesn't disturb the repo asset.
src = "#{__DIR__}/assets/sprite.png"
tmp = File.tempname("flock_asset", ".png")
File.copy(src, tmp)

ok = true
report = ->(name : String, pass : Bool) { ok = false unless pass; puts "#{pass ? "✓" : "✗"} #{name}" }

# load + dedup + ref-count
h1 = assets.load(Flock::Texture, tmp)
h2 = assets.load(Flock::Texture, tmp) # same path → same handle, refs=2
report.call("dedup: same handle", h1 == h2)
report.call("ref_count == 2", assets.ref_count(h1) == 2)
tex = assets.get(h1)
report.call("get returns a real texture", tex.id > 0_u64)
report.call("version starts at 0", assets.version(h1) == 0)

# hot-reload: bump the file's mtime into the future, then poll.
future = Time.utc + 5.seconds
File.utime(future, future, tmp)
reloaded = assets.poll_hot_reload
report.call("poll reloaded 1", reloaded == 1)
report.call("version bumped to 1", assets.version(h1) == 1)
report.call("still a real texture after reload", assets.get(h1).id > 0_u64)

# ref-count release: first release keeps it alive, second frees it.
assets.release(h1)
report.call("alive after 1 release (refs 2→1)", assets.alive?(h1))
assets.release(h2)
report.call("freed after 2nd release", !assets.alive?(h2))

# get on a freed handle → shared white placeholder (same object each call).
p1 = assets.get(h1)
p2 = assets.get(h2)
report.call("freed → placeholder (stable)", p1.id == p2.id)
report.call("placeholder differs from original", p1.id != tex.id)

# async load: handle returns immediately (placeholder), the pump finishes it. The texture is
# only assigned by pump (main thread), so it's never ready before we pump — MT or not.
ha = assets.load_async(Flock::Texture, tmp)
report.call("async: not ready before pump", !assets.ready?(ha))
report.call("async: get is placeholder before pump", assets.get(ha).id == p1.id)
# Spin the pump (yielding so a worker fiber can read the file under -Dpreview_mt).
tries = 0
until assets.ready?(ha) || tries > 10_000
  assets.pump_async
  Fiber.yield
  tries += 1
end
report.call("async: ready after pump", assets.ready?(ha))
report.call("async: real texture after pump", assets.get(ha).id > 0_u64 && assets.get(ha).id != p1.id)

File.delete(tmp)
Flock.release_all(assets, gpu)

puts ok ? "✅ asset server OK" : "❌ asset server failed"
exit(ok ? 0 : 1)
