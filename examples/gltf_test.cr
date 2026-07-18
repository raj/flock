# Headless readback test for glTF loading (Mesh.load_gltf). Builds a quad's binary
# buffer, wraps it BOTH as a `.gltf` (base64 data-URI) and a binary `.glb`, loads each,
# renders it lit, and asserts the quad shows at center while a corner stays background.
# Exercises the JSON/accessor/bufferView parsing, base64 + GLB container, index reading,
# and flat-normal computation (the quad has no NORMAL attribute).
#
#   crystal run examples/gltf_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

# Self-contained fixtures: a quad wrapped BOTH as a `.gltf` (base64 data-URI buffer)
# and as a binary `.glb` container. See examples/assets/gltf/.
gltf_path = "examples/assets/gltf/gltf.gltf"
glb_path = "examples/assets/gltf/gltf.glb"

# --- GPU + offscreen target. ---
gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

# Render `mesh` and read back {center, corner}.
render_sample = ->(mesh : Flock::Mesh) do
  world = Flock::World.new
  world.insert_resource(Flock::Time.new)
  world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), clear_color: Flock::Color::BLACK))
  e = world.spawn
  world.add(e, Flock::Transform3D.new)
  world.add(e, Flock::MeshRenderer.new(mesh))
  renderer.render_into(world, target.view)

  px = target.read
  center = px.rgb(64, 64)
  corner = px.rgb(2, 2)
  {center, corner}
end

gltf_mesh = Flock::Mesh.load_gltf(gpu, gltf_path, Flock::Color.new(0.9, 0.3, 0.8))
glb_mesh = Flock::Mesh.load_gltf(gpu, glb_path, Flock::Color.new(0.9, 0.3, 0.8))

gltf_c, gltf_k = render_sample.call(gltf_mesh)
glb_c, glb_k = render_sample.call(glb_mesh)

puts ".gltf center = #{gltf_c}, corner = #{gltf_k}"
puts ".glb  center = #{glb_c}, corner = #{glb_k}"

lit = ->(c : Tuple(Int32, Int32, Int32)) { c[0].to_i + c[1].to_i + c[2].to_i > 60 && c[0] > 40 }
bg = ->(c : Tuple(Int32, Int32, Int32)) { c[0] < 20 && c[1] < 20 && c[2] < 20 }
ok = lit.call(gltf_c) && bg.call(gltf_k) && lit.call(glb_c) && bg.call(glb_k)

Flock.release_all(gltf_mesh, glb_mesh, target, renderer, gpu)

puts ok ? "✅ glTF loading OK (.gltf + .glb)" : "❌ glTF mesh not rendered as expected"
exit(ok ? 0 : 1)
