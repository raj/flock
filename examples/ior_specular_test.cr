# KHR_materials_ior + KHR_materials_specular readback test (headless).
#
# A BLACK dielectric cube shows only its specular reflectance (F0). Raising the index of
# refraction raises F0 → brighter; dropping the specular factor to 0 kills it → darker.
#
#   crystal run examples/ior_specular_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 96
gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color::BLACK) # black base → only F0 specular visible

brightness = ->(ior : Float32, specular : Float32) do
  world = Flock::World.new
  world.add(world.spawn, Flock::Camera3D.new(
    position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
  c = world.spawn
  world.add(c, Flock::Transform3D.new)
  world.add(c, Flock::MeshRenderer.new(cube, metallic: 0.0f32, roughness: 0.2f32, ior: ior, specular: specular))
  target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
  renderer.render_into(world, target.view)
  px = target.read
  sum = 0_i64
  px.data.each { |b| sum += b }
  target.release
  sum
end

default_ior = brightness.call(1.5f32, 1.0f32) # F0 = 0.04
high_ior = brightness.call(3.0f32, 1.0f32)    # F0 = (2/4)^2 = 0.25 → brighter
no_spec = brightness.call(1.5f32, 0.0f32)     # specular off → darker
puts "ior1.5=#{default_ior}  ior3.0=#{high_ior}  spec0=#{no_spec}"

Flock.release_all(cube, renderer, gpu)

ok = high_ior > default_ior && # higher IOR reflects more
     no_spec < default_ior     # specular factor 0 removes the dielectric highlight
puts ok ? "✅ KHR_materials_ior + specular OK" : "❌ ior/specular unexpected"
exit(ok ? 0 : 1)
