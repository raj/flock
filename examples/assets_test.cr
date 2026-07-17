# Headless test of the asset cache: two identical `font(path, size)` -> same instance.
require "../src/flock/gpu"

FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"

gpu = Flock.headless_context(1, 1)

assets = Flock::Assets.new(gpu)
a = assets.font(FONT, 24)
b = assets.font(FONT, 24)  # same key -> cache
c = assets.font(FONT, 48)  # different size -> other instance

hit = a.same?(b)
distinct = !a.same?(c)
puts "font(24)==font(24) : #{hit}   font(24)!=font(48) : #{distinct}"

assets.release
gpu.release
ok = hit && distinct
puts ok ? "✅ asset cache OK" : "❌ cache FAILED"
exit(ok ? 0 : 1)
