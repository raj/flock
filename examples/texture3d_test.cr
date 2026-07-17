# Headless readback test for textured 3D meshes. A white cube is drawn with a solid
# BLUE 1x1 base-color texture (via Texture.from_pixels) assigned to MeshRenderer#texture;
# we assert the rendered center is blue (texture modulates the vertex color) — proving
# Renderer3D's UV attribute + group1 texture/sampler path works.
#
#   crystal run examples/texture3d_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

cube = Flock::Mesh.cube(gpu, Flock::Color::WHITE) # white vertices; texture provides color
blue = Flock::Texture.from_pixels(gpu, 1, 1, Bytes[0_u8, 0_u8, 255_u8, 255_u8])

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(cube, texture: blue))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
px = target.read

center = px.rgb(64, 64)
corner = px.rgb(2, 2)

puts "center = #{center}, corner = #{corner}"
ok = center[2] > 60 && center[2].to_i > center[0].to_i && # blue from the texture
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20

Flock.release_all(target, blue, cube, renderer, gpu)

puts ok ? "✅ textured 3D mesh OK" : "❌ 3D texture not sampled as expected"
exit(ok ? 0 : 1)
