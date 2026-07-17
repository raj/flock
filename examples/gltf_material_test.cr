# Headless readback test for the glTF material-completeness additions to MeshRenderer:
# emissive (map x factor, added after lighting), ambient occlusion (R channel attenuates
# the ambient term), and alpha MASK (hard cutout via alpha_cutoff / discard). Each is
# checked in isolation against a control render.
#
#   crystal run examples/gltf_material_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

# Renders `world` and returns the center pixel {r, g, b}.
render_center = ->(world : Flock::World) do
  renderer.render_into(world, target.view)
  target.read.rgb(32, 32)
end

def base_world
  w = Flock::World.new
  w.insert_resource(Flock::Time.new)
  w.add(w.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
  w
end

# --- A. Emissive: a BLACK sphere in a black scene glows red purely from emissive. ---
sphere_black = Flock::Mesh.sphere(gpu, radius: 1.0, segments: 32, rings: 16, color: Flock::Color.new(0.0, 0.0, 0.0))
wa = base_world
wa.insert_resource(Flock::AmbientLight.new(sky: Flock::Color::BLACK, ground: Flock::Color::BLACK))
ea = wa.spawn
wa.add(ea, Flock::Transform3D.new)
wa.add(ea, Flock::MeshRenderer.new(sphere_black, emissive_factor: Flock::Color.new(0.9, 0.05, 0.05)))
emissive = render_center.call(wa)

# Control: same scene, no emissive -> center stays dark.
wa2 = base_world
wa2.insert_resource(Flock::AmbientLight.new(sky: Flock::Color::BLACK, ground: Flock::Color::BLACK))
ea2 = wa2.spawn
wa2.add(ea2, Flock::Transform3D.new)
wa2.add(ea2, Flock::MeshRenderer.new(sphere_black))
emissive_off = render_center.call(wa2)

# --- B. Occlusion: a camera-facing quad, bright ambient, occlusion map dims the ambient. ---
quad = Flock::Mesh.cube(gpu, color: Flock::Color.new(0.8, 0.8, 0.8))
occ_dark = Flock::Texture.from_pixels(gpu, 1, 1, Bytes[64_u8, 64_u8, 64_u8, 255_u8]) # R=0.25
# A light pointing away from the camera-facing front (no direct contribution) makes the
# center purely ambient, so occlusion's effect on the ambient term is unambiguous.
away = Flock::Light.directional(Flock::Vec3.new(0.0, 0.0, 1.0), Flock::Color::WHITE, 1.0)
wb = base_world
wb.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
lb = wb.spawn; wb.add(lb, Flock::Transform3D.new); wb.add(lb, away)
eb = wb.spawn
wb.add(eb, Flock::Transform3D.new(scale: Flock::Vec3.new(4.0, 4.0, 0.1)))
wb.add(eb, Flock::MeshRenderer.new(quad, occlusion: occ_dark))
occluded = render_center.call(wb)

wb2 = base_world
wb2.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
lb2 = wb2.spawn; wb2.add(lb2, Flock::Transform3D.new); wb2.add(lb2, away)
eb2 = wb2.spawn
wb2.add(eb2, Flock::Transform3D.new(scale: Flock::Vec3.new(4.0, 4.0, 0.1)))
wb2.add(eb2, Flock::MeshRenderer.new(quad)) # no occlusion (white)
unoccluded = render_center.call(wb2)

# --- C. Alpha MASK: a translucent-textured quad is fully discarded above its cutoff. ---
faded = Flock::Texture.from_pixels(gpu, 1, 1, Bytes[255_u8, 255_u8, 255_u8, 76_u8]) # alpha ~0.3
wc = base_world # clear color is black background
wc.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
ec = wc.spawn
wc.add(ec, Flock::Transform3D.new(scale: Flock::Vec3.new(4.0, 4.0, 0.1)))
wc.add(ec, Flock::MeshRenderer.new(quad, texture: faded, alpha_cutoff: 0.6f32)) # 0.3 < 0.6 -> discard
masked = render_center.call(wc)

wc2 = base_world
wc2.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
ec2 = wc2.spawn
wc2.add(ec2, Flock::Transform3D.new(scale: Flock::Vec3.new(4.0, 4.0, 0.1)))
wc2.add(ec2, Flock::MeshRenderer.new(quad, texture: faded)) # cutoff 0 -> kept
unmasked = render_center.call(wc2)

Flock.release_all(target, sphere_black, quad, occ_dark, faded, renderer, gpu)

puts "emissive: on=#{emissive} off=#{emissive_off}"
puts "occlusion: occluded=#{occluded} unoccluded=#{unoccluded}"
puts "alpha mask: masked=#{masked} unmasked=#{unmasked}"

emissive_ok = emissive[0] > 150 && emissive[0] > emissive[1] * 3 && emissive_off[0] < 30
occlusion_ok = occluded[0] < unoccluded[0] * 0.6 && unoccluded[0] > 150
mask_ok = masked[0] < 20 && unmasked[0] > 60 # discarded -> black bg; kept -> lit quad

ok = emissive_ok && occlusion_ok && mask_ok
puts "emissive=#{emissive_ok} occlusion=#{occlusion_ok} mask=#{mask_ok}"
puts ok ? "✅ glTF material completeness OK" : "❌ emissive/occlusion/alpha-mask not as expected"
exit(ok ? 0 : 1)
