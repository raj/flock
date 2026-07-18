# Headless test for glTF PBR extraction (Mesh.load_gltf_pbr): a glTF references a
# base-color, a metallic-roughness, and a normal texture (embedded BMP data-URIs) plus
# metallic/roughness factors. We assert all three maps are decoded, the factors are
# parsed, and the result renders (non-black center) through the PBR pipeline.
#
#   crystal run examples/gltf_pbr_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

# Self-contained fixture: a quad whose material references base-color, metallic-roughness,
# and normal textures (embedded BMP data-URIs) plus metallic/roughness factors.
# See examples/assets/gltf/.
path = "examples/assets/gltf/gltf_pbr.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

pbr = Flock::Mesh.load_gltf_pbr(gpu, path, Flock::Color::WHITE)

maps_ok = !pbr[:base_color].nil? && !pbr[:metallic_roughness].nil? && !pbr[:normal].nil?
factors_ok = (pbr[:metallic] - 0.25f32).abs < 1e-4 && (pbr[:roughness] - 0.75f32).abs < 1e-4
puts "maps: base=#{!pbr[:base_color].nil?} mr=#{!pbr[:metallic_roughness].nil?} normal=#{!pbr[:normal].nil?}"
puts "factors: metallic=#{pbr[:metallic]} roughness=#{pbr[:roughness]}"

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(pbr[:mesh], texture: pbr[:base_color],
  metallic_roughness: pbr[:metallic_roughness], normal_map: pbr[:normal],
  metallic: pbr[:metallic], roughness: pbr[:roughness]))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)

px = target.read
center = px.rgb(64, 64)

puts "center = #{center}"
renders_ok = center[0] + center[1] + center[2] > 40 && center[1] > center[0] # greenish base
ok = maps_ok && factors_ok && renders_ok

target.release
pbr[:base_color].try &.release
pbr[:metallic_roughness].try &.release
pbr[:normal].try &.release
pbr[:mesh].release
Flock.release_all(renderer, gpu)

puts ok ? "✅ glTF PBR maps + factors OK" : "❌ glTF PBR extraction not as expected"
exit(ok ? 0 : 1)
