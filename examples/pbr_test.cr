# Headless test for the PBR shading path (metallic-roughness + normal maps), using
# procedural textures so it's deterministic. Two checks:
#   1. Normal map: a tilted normal map changes the shading vs a flat one.
#   2. Metallic: a metallic surface renders differently from a matte one (its diffuse
#      is suppressed), proving MeshRenderer#metallic feeds the shader.
#
#   crystal run examples/pbr_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.85, 0.5, 0.2))

flat_n = Flock::Texture.from_pixels(gpu, 1, 1, Bytes[128_u8, 128_u8, 255_u8, 255_u8]) # (0,0,1)
tilt_n = Flock::Texture.from_pixels(gpu, 1, 1, Bytes[235_u8, 235_u8, 130_u8, 255_u8]) # strong tilt

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

sample = ->(normal_map : Flock::Texture?, metallic : Float32) do
  world = Flock::World.new
  world.insert_resource(Flock::Time.new)
  world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), clear_color: Flock::Color::BLACK))
  e = world.spawn
  world.add(e, Flock::Transform3D.new)
  world.add(e, Flock::MeshRenderer.new(cube, normal_map: normal_map, metallic: metallic, roughness: 0.4f32))
  renderer.render_into(world, target.view)

  px = target.read
  px.rgb(64, 64)
end

def diff(a, b)
  (a[0] - b[0]).abs + (a[1] - b[1]).abs + (a[2] - b[2]).abs
end

flat = sample.call(flat_n, 0.0f32)
tilt = sample.call(tilt_n, 0.0f32)
matte = sample.call(nil, 0.0f32)
metal = sample.call(nil, 1.0f32)

puts "normal flat=#{flat} tilted=#{tilt} (diff #{diff(flat, tilt)})"
puts "matte=#{matte} metallic=#{metal} (diff #{diff(matte, metal)})"

ok = diff(flat, tilt) > 8 && diff(matte, metal) > 8

flat_n.release
tilt_n.release
cube.release
target.release
renderer.release
gpu.release

puts ok ? "✅ PBR (normal map + metallic) OK" : "❌ PBR maps had no visible effect"
exit(ok ? 0 : 1)
