# Headless readback test for per-instance tint. Two entities share ONE white cube mesh
# (drawn in a single instanced call) but carry different MeshRenderer#tint values — red
# on the left, blue on the right. We assert the left cube reads red and the right cube
# reads blue, proving the per-instance param buffer (group0 binding 4) is applied.
#
#   crystal run examples/instance_tint_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 128

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
cube = Flock::Mesh.cube(gpu, Flock::Color::WHITE) # one shared mesh; tint provides color

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 7.0), fov_y: 0.7f32, clear_color: Flock::Color::BLACK))
l = world.spawn
world.add(l, Flock::Transform3D.new(Flock::Vec3.new(-2.0, 0, 0)))
world.add(l, Flock::MeshRenderer.new(cube, tint: Flock::Color.new(1.0, 0.15, 0.15))) # red
r = world.spawn
world.add(r, Flock::Transform3D.new(Flock::Vec3.new(2.0, 0, 0)))
world.add(r, Flock::MeshRenderer.new(cube, tint: Flock::Color.new(0.15, 0.3, 1.0))) # blue

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)
raise "expected a single instanced draw group" unless renderer.last_drawn == 2

px = target.read

def scan(px : Flock::Pixels, xs : Range, y : Int32, &block : Int32, Int32, Int32 -> Bool) : Bool
  xs.any? do |x|
    r, g, b = px.rgb(x, y)
    block.call(r, g, b)
  end
end

mid = SIZE // 2
left_red = scan(px, 4...(SIZE // 3), mid) { |r, g, b| r > 60 && r > g && r > b }
right_blue = scan(px, (2 * SIZE // 3)...(SIZE - 4), mid) { |r, g, b| b > 60 && b > r && b > g }

puts "left red = #{left_red}, right blue = #{right_blue}, drawn = #{renderer.last_drawn}"
ok = left_red && right_blue

Flock.release_all(target, cube, renderer, gpu)

puts ok ? "✅ per-instance tint OK" : "❌ per-instance tint not applied as expected"
exit(ok ? 0 : 1)
