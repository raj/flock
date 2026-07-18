# Headless readback test for glTF base-color TEXTURES. Builds a 2x2 green BMP, embeds
# it as a data-URI image referenced by a material's baseColorTexture, and a quad with
# TEXCOORD_0. `Mesh.load_gltf_textured` returns {mesh, texture}; rendered via
# MeshRenderer#texture, the quad must show green (from the embedded image), proving
# glTF texture extraction + Texture.from_encoded + the 3D texture pipeline.
#
#   crystal run examples/gltf_texture_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

# Self-contained fixture: a quad with TEXCOORD_0 and a material whose baseColorTexture
# is an embedded 2x2 green BMP data-URI. See examples/assets/gltf/.
path = "examples/assets/gltf/gltf_texture.gltf"

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

mesh, tex = Flock::Mesh.load_gltf_textured(gpu, path, Flock::Color.new(0.9, 0.1, 0.1))
abort "expected a base-color texture" unless tex

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(mesh, texture: tex))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

renderer.render_into(world, target.view)

px = target.read
center = px.rgb(64, 64)

puts "center = #{center}"
# Green from the embedded texture (not the red fallback color).
ok = center[1] > 60 && center[1].to_i > center[0].to_i && center[1].to_i > center[2].to_i

target.release
tex.try &.release
Flock.release_all(mesh, renderer, gpu)

puts ok ? "✅ glTF base-color texture OK" : "❌ glTF texture not applied as expected"
exit(ok ? 0 : 1)
