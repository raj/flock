# Headless readback test for glTF enrichment: NODE TRANSFORMS + MATERIAL base color.
# A quad mesh is placed by a node whose translation shifts it left of the origin, and
# its primitive references a blue material (baseColorFactor). We pass a RED fallback
# color to load_gltf, then assert the rendered quad is (a) left of center — proving the
# node transform was baked — and (b) blue, not red — proving the material color wins.
#
#   crystal run examples/gltf_nodes_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

# Self-contained fixture: a quad placed by a node translation, referencing a blue
# material (baseColorFactor). See examples/assets/gltf/.
path = "examples/assets/gltf/gltf_nodes.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

# RED fallback — the blue material must override it.
mesh = Flock::Mesh.load_gltf(gpu, path, Flock::Color.new(0.9, 0.1, 0.1))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 4.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(mesh))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

renderer.render_into(world, target.view)

px = target.read
left = px.rgb(15, 64)     # where the node-translated quad lands
center = px.rgb(64, 64)    # empty (quad moved left)
corner = px.rgb(120, 120)

puts "left(quad)  = #{left}"
puts "center      = #{center}"
puts "corner      = #{corner}"

ok = left[2] > 60 && left[2].to_i > left[0].to_i && # quad is blue (material), not red (fallback)
     center[0] < 20 && center[1] < 20 && center[2] < 20 && # node shifted it away from center
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20

Flock.release_all(target, mesh, renderer, gpu)

puts ok ? "✅ glTF node transforms + material color OK" : "❌ node/material enrichment not as expected"
exit(ok ? 0 : 1)
