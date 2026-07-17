# Headless readback test for instanced meshes. Two entities SHARE one Mesh object at
# x = -2 and x = +2; Renderer3D groups them into a single instanced draw call, using
# per-instance model matrices. We assert both a left and a right cube render (proving
# distinct per-instance transforms) with a background gap between them.
#
#   crystal run examples/instancing_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)

renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color.new(0.3, 0.9, 0.4)) # ONE mesh, shared

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(
  position: Flock::Vec3.new(0.0, 0.0, 7.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))

# Two instances of the SAME mesh, left and right.
[-2.0, 2.0].each do |x|
  e = world.spawn
  world.add(e, Flock::Transform3D.new(Flock::Vec3.new(x, 0.0, 0.0)))
  world.add(e, Flock::MeshRenderer.new(cube))
end

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
px = target.read

def lit?(px : Flock::Pixels, x : Int32, y : Int32) : Bool
  r, g, b = px.rgb(x, y)
  r + g + b > 40
end

mid = SIZE // 2
# Any lit pixel in the left third / right third at the vertical center?
left = (4...(SIZE // 3)).any? { |x| lit?(px, x, mid) }
right = ((2 * SIZE // 3)...(SIZE - 4)).any? { |x| lit?(px, x, mid) }
center_dark = !lit?(px, mid, mid)
corner_dark = !lit?(px, 2, 2)

puts "left lit = #{left}, right lit = #{right}, center dark = #{center_dark}, corner dark = #{corner_dark}"

ok = left && right && center_dark && corner_dark

target.release
cube.release
renderer.release
gpu.release

puts ok ? "✅ instanced meshes OK" : "❌ instancing not rendered as expected"
exit(ok ? 0 : 1)
