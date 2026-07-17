# Headless test for glTF scene import: KHR_lights_punctual lights and glTF cameras.
# Builds a minimal .gltf with a directional/point/spot light and a perspective camera at
# posed nodes, loads them via Mesh.load_gltf_lights / load_gltf_cameras, asserts the parsed
# values, then renders a white sphere lit ONLY by the imported (red) directional light and
# checks the sphere reads red — proving import -> render works end to end.
#
#   crystal run examples/gltf_scene_import_test.cr   # exit 0 if OK
require "../src/flock/gpu"

json = <<-JSON
{
  "asset":{"version":"2.0"},
  "extensions":{"KHR_lights_punctual":{"lights":[
    {"type":"directional","color":[1.0,0.1,0.1],"intensity":2.0},
    {"type":"point","color":[0.1,1.0,0.1],"intensity":3.0,"range":5.0},
    {"type":"spot","color":[0.1,0.1,1.0],"intensity":4.0,"range":8.0,"spot":{"innerConeAngle":0.2,"outerConeAngle":0.5}}
  ]}},
  "cameras":[{"type":"perspective","perspective":{"yfov":0.8,"znear":0.5,"zfar":200.0}}],
  "nodes":[
    {"extensions":{"KHR_lights_punctual":{"light":0}}},
    {"translation":[1.0,2.0,3.0],"extensions":{"KHR_lights_punctual":{"light":1}}},
    {"translation":[0.0,5.0,0.0],"extensions":{"KHR_lights_punctual":{"light":2}}},
    {"translation":[4.0,0.0,0.0],"camera":0}
  ],
  "scenes":[{"nodes":[0,1,2,3]}],
  "scene":0
}
JSON

path = File.tempname("flock_scene", ".gltf")
File.write(path, json)

ok = true
def check(cond, msg)
  unless cond
    puts "  ✗ #{msg}"
    return false
  end
  true
end

lights = Flock::Mesh.load_gltf_lights(path)
ok &&= check(lights.size == 3, "expected 3 lights, got #{lights.size}")

l0, p0 = lights[0]
ok &&= check(l0.kind.directional?, "light 0 should be directional")
ok &&= check((l0.color.r - 1.0).abs < 1e-4 && l0.color.g < 0.2, "light 0 color red")
ok &&= check((l0.intensity - 2.0).abs < 1e-4, "light 0 intensity 2")
ok &&= check((l0.direction.z + 1.0).abs < 1e-4, "light 0 aims -Z, got #{l0.direction}")

l1, p1 = lights[1]
ok &&= check(l1.kind.point?, "light 1 should be point")
ok &&= check((p1.x - 1.0).abs < 1e-4 && (p1.y - 2.0).abs < 1e-4 && (p1.z - 3.0).abs < 1e-4, "light 1 at (1,2,3), got #{p1}")
ok &&= check((l1.range - 5.0).abs < 1e-4, "light 1 range 5")
ok &&= check(l1.color.g > 0.9, "light 1 color green")

l2, p2 = lights[2]
ok &&= check(l2.kind.spot?, "light 2 should be spot")
ok &&= check((p2.y - 5.0).abs < 1e-4, "light 2 at y=5")
ok &&= check((l2.inner - 0.2).abs < 1e-4 && (l2.outer - 0.5).abs < 1e-4, "light 2 cone 0.2/0.5")
ok &&= check((l2.range - 8.0).abs < 1e-4, "light 2 range 8")

cams = Flock::Mesh.load_gltf_cameras(path)
ok &&= check(cams.size == 1, "expected 1 camera, got #{cams.size}")
cam = cams[0]
ok &&= check((cam.position.x - 4.0).abs < 1e-4, "camera at x=4, got #{cam.position}")
ok &&= check((cam.target.z - -1.0).abs < 1e-4, "camera aims -Z (target z=-1), got #{cam.target}")
ok &&= check((cam.fov_y - 0.8).abs < 1e-4, "camera fov 0.8")
ok &&= check((cam.near - 0.5).abs < 1e-4 && (cam.far - 200.0).abs < 1e-4, "camera near/far")

File.delete(path)

# --- End-to-end: render a white sphere lit only by the imported directional (red) light. ---
SIZE = 64
gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)
sphere = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 32, rings: 16, color: Flock::Color.new(0.9, 0.9, 0.9))

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(0.02, 0.02, 0.02), ground: Flock::Color.new(0.02, 0.02, 0.02)))
# Camera facing the sphere; the imported directional light travels -Z (lights the front).
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
l, pos = lights[0]
lw = world.spawn
world.add(lw, Flock::Transform3D.new(position: pos))
world.add(lw, l)
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(sphere))

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)
renderer.render_into(world, target.view)

px = target.read
center = px.rgb(32, 32)

ok &&= check(center[0] > 60 && center[0] > center[1] * 2 && center[0] > center[2] * 2,
  "sphere lit red by imported light, got #{center}")

target.release
sphere.release; renderer.release; gpu.release

puts "imported #{lights.size} lights + #{cams.size} camera; lit-sphere center = #{center}"
puts ok ? "✅ glTF scene import (lights + cameras) OK" : "❌ glTF scene import failed"
exit(ok ? 0 : 1)
