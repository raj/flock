# Headless readback test for native texture mipmaps (Texture from_pixels mipmaps:). A
# high-frequency 1px checkerboard fills a screen-filling quad, so each screen pixel covers
# several texels (heavy minification). The same quad is drawn with a mipmapped texture and
# a non-mipmapped one, sampling a central block each time. Without mipmaps the block shows
# strong minification aliasing (high variance); with a mip chain the sampler reads a coarse,
# averaged level and the block is a near-uniform mid-gray (low variance).
#
#   crystal run examples/mipmap_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128
TEX  = 512

gpu = Flock.headless_context(SIZE, SIZE)

# 1px black/white checkerboard.
checker = Bytes.new(TEX * TEX * 4)
(0...TEX).each do |y|
  (0...TEX).each do |x|
    o = (y * TEX + x) * 4
    v = ((x + y) & 1) == 0 ? 255_u8 : 0_u8
    checker[o] = v; checker[o + 1] = v; checker[o + 2] = v; checker[o + 3] = 255_u8
  end
end
tex_flat = Flock::Texture.from_pixels(gpu, TEX, TEX, checker, filter: Flock::SamplerFilter::Linear, mipmaps: false)
tex_mip = Flock::Texture.from_pixels(gpu, TEX, TEX, checker, filter: Flock::SamplerFilter::Linear, mipmaps: true)

renderer = Flock::Renderer3D.new(gpu)
quad = Flock::Mesh.cube(gpu, color: Flock::Color.new(1.0, 1.0, 1.0))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(
  sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
q = world.spawn
world.add(q, Flock::Transform3D.new(scale: Flock::Vec3.new(6.0, 6.0, 0.1))) # fills the frame
world.add(q, Flock::MeshRenderer.new(quad, texture: tex_flat))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

# Renders the scene and returns {mean, variance} of the green channel over a central block.
render_stats = ->{
  renderer.render_into(world, target.view)
  px = target.read
  vals = [] of Float64
  (44...84).each do |y|
    (44...84).each do |x|
      vals << px.rgb(x, y)[1].to_f64
    end
  end
  mean = vals.sum / vals.size
  var = vals.sum { |v| (v - mean) ** 2 } / vals.size
  {mean, var}
}

flat_mean, flat_var = render_stats.call

# Swap in the mipmapped texture and re-render.
world.query(Flock::Transform3D, Flock::MeshRenderer) do |_e, _tf, mr|
  m = mr.value
  m.texture = tex_mip
  mr.value = m
end
mip_mean, mip_var = render_stats.call

target.release
tex_flat.release
tex_mip.release
quad.release
renderer.release
gpu.release

puts "no-mip: mean=#{flat_mean.round(1)} var=#{flat_var.round(1)}   mipped: mean=#{mip_mean.round(1)} var=#{mip_var.round(1)}"
# The mipped block is a uniform averaged mid-tone (the base-0.5 gray, brightened by the
# scene lighting); the aliased block is a noisy mix of the black/white texels. Variance is
# the anti-aliasing signal.
ok = flat_var > 200.0 &&              # without mips the minified checker aliases badly
     mip_var < flat_var * 0.1 &&      # mips smooth it out dramatically
     (140.0..235.0).includes?(mip_mean) # and converge to a uniform mid-tone (not pure 0/255)

puts ok ? "✅ native mipmaps OK" : "❌ mipmaps did not reduce minification aliasing"
exit(ok ? 0 : 1)
