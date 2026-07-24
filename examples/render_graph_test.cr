# Render graph test (headless): a 4-node graph (paint → copy → copy → present) whose 1st and
# 3rd transient resources have non-overlapping lifetimes, so the pool ALIASES them (3 logical
# textures → 2 physical). Verifies topo order, the alias count, and a correct final image.
#
#   crystal run examples/render_graph_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64
gpu = Flock.headless_context(SIZE, SIZE)
fmt = gpu.format

# Two reusable fullscreen passes: paint solid red, and copy tex0 → output.
red = Flock::FullscreenPass.new(gpu, "@fragment fn fs_main(i : VSOut) -> @location(0) vec4<f32> { return vec4<f32>(1.0, 0.0, 0.0, 1.0); }", fmt)
copy = Flock::FullscreenPass.new(gpu, "@fragment fn fs_main(i : VSOut) -> @location(0) vec4<f32> { return textureSample(tex0, samp, i.uv); }", fmt)
zero = StaticArray(Float32, 16).new(0.0f32)
dummy = Flock::Texture.white(gpu) # input for the no-read paint node (never sampled)

surface = Flock::RenderTarget.new(gpu, SIZE, SIZE, fmt)

g = Flock::RenderGraph.new(gpu)
g.import("surface", surface.view)
g.texture("a", SIZE, SIZE, fmt)
g.texture("b", SIZE, SIZE, fmt)
g.texture("c", SIZE, SIZE, fmt)
g.node("geo", writes: ["a"]) { |c| red.run(dummy.view, dummy.view, c.view("a"), zero) }
g.node("mid", reads: ["a"], writes: ["b"]) { |c| copy.run(c.view("a"), c.view("a"), c.view("b"), zero) }
g.node("mid2", reads: ["b"], writes: ["c"]) { |c| copy.run(c.view("b"), c.view("b"), c.view("c"), zero) }
g.node("present", reads: ["c"], writes: ["surface"]) { |c| copy.run(c.view("c"), c.view("c"), c.view("surface"), zero) }

stats = g.run

ok = true
report = ->(name : String, pass : Bool) { ok = false unless pass; puts "#{pass ? "✓" : "✗"} #{name}" }
report.call("topo order geo→mid→mid2→present", stats.order == ["geo", "mid", "mid2", "present"])
report.call("3 logical transients", stats.transient_logical == 3)
report.call("2 physical (a and c aliased)", stats.transient_physical == 2)

px = surface.read
center = px.rgb(SIZE // 2, SIZE // 2)
puts "surface center = #{center}"
report.call("final image is red (aliasing correct)", center[0] > 200 && center[1] < 40 && center[2] < 40)

red.release
copy.release
dummy.release
surface.release
Flock.release_all(gpu)

puts ok ? "✅ render graph OK" : "❌ render graph failed"
exit(ok ? 0 : 1)
