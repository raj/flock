# Headless readback test for OBJ loading (Mesh.load_obj). Writes a cube .obj (no
# normals -> exercises the flat-normal computation), loads it, renders it lit, and
# asserts the center is the cube's color while a corner stays background.
#
#   crystal run examples/obj_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

OBJ = <<-OBJ
# unit cube, no normals
v -0.5 -0.5 -0.5
v  0.5 -0.5 -0.5
v  0.5  0.5 -0.5
v -0.5  0.5 -0.5
v -0.5 -0.5  0.5
v  0.5 -0.5  0.5
v  0.5  0.5  0.5
v -0.5  0.5  0.5
f 1 2 3 4
f 5 8 7 6
f 1 5 6 2
f 2 6 7 3
f 3 7 8 4
f 4 8 5 1
OBJ

path = File.tempname("flock_cube", ".obj")
File.write(path, OBJ)

gpu = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer3D.new(gpu)
mesh = Flock::Mesh.load_obj(gpu, path, Flock::Color.new(0.2, 0.7, 0.9))
File.delete(path) rescue nil

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(2.0, 1.5, 2.5), clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(mesh))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

renderer.render_into(world, target.view)

px = target.read
center = px.rgb(SIZE // 2, SIZE // 2)
corner = px.rgb(2, 2)

puts "center = #{center}"
puts "corner = #{corner}"

# Center: the loaded cube (bluish, non-background). Corner: black background.
ok = center[2] > 40 && center[2].to_i > center[0].to_i && # bluish, non-background
     corner[0] < 20 && corner[1] < 20 && corner[2] < 20

Flock.release_all(target, mesh, renderer, gpu)

puts ok ? "✅ OBJ loading OK" : "❌ OBJ mesh not rendered as expected"
exit(ok ? 0 : 1)
