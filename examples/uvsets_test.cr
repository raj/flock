# Headless readback test for multiple UV sets (MeshRenderer#tex_coords / glTF TEXCOORD_1).
# A camera-facing quad carries two UV sets: TEXCOORD_0 samples the LEFT (red) texel of a
# 2x1 red/blue texture, TEXCOORD_1 the RIGHT (blue) texel. Rendering the base texture with
# tex_coords = 0 (use uv0) must read red; with the base bit set (use uv1) must read blue.
#
#   crystal run examples/uvsets_test.cr   # exit 0 if OK
require "../src/flock/gpu"

SIZE = 64

gpu = Flock.headless_context(SIZE, SIZE)
renderer = Flock::Renderer3D.new(gpu)

# 2x1 texture: left texel red, right texel blue (Nearest, so UVs pick exact texels).
tex = Flock::Texture.from_pixels(gpu, 2, 1, Bytes[255_u8, 0_u8, 0_u8, 255_u8, 0_u8, 0_u8, 255_u8, 255_u8])

# A camera-facing quad. Vertex = pos3 + normal3 + color3 + uv0(2) + uv1(2) = 13 floats.
# uv0 = (0.25, 0.5) -> left (red) texel; uv1 = (0.75, 0.5) -> right (blue) texel.
def vtx(x, y)
  [x.to_f32, y.to_f32, 0.0f32, 0.0f32, 0.0f32, 1.0f32, 1.0f32, 1.0f32, 1.0f32,
   0.25f32, 0.5f32, 0.75f32, 0.5f32]
end

verts = [vtx(-1.5, -1.5), vtx(1.5, -1.5), vtx(1.5, 1.5), vtx(-1.5, 1.5)].flatten
mesh = Flock::Mesh.build(gpu, verts, [0u32, 1u32, 2u32, 0u32, 2u32, 3u32])

world = Flock::World.new
world.insert_resource(Flock::Time.new)
world.insert_resource(Flock::AmbientLight.new(sky: Flock::Color.new(1.0, 1.0, 1.0), ground: Flock::Color.new(1.0, 1.0, 1.0)))
world.add(world.spawn, Flock::Camera3D.new(position: Flock::Vec3.new(0.0, 0.0, 3.0), fov_y: 0.9f32, clear_color: Flock::Color::BLACK))
e = world.spawn
world.add(e, Flock::Transform3D.new)
world.add(e, Flock::MeshRenderer.new(mesh, texture: tex)) # tex_coords defaults to 0 (uv0)

target = Flock::RenderTarget.new(gpu, SIZE, SIZE)

render_center = ->do
  renderer.render_into(world, target.view)
  px = target.read
  px.rgb(32, 32)
end

uv0 = render_center.call # base uses TEXCOORD_0 -> red

# Flip the base texture to TEXCOORD_1 (bit 0) -> blue.
world.query(Flock::Transform3D, Flock::MeshRenderer) do |_e, _tf, mr|
  v = mr.value; v.tex_coords = 1_u32; mr.value = v
end
uv1 = render_center.call # base uses TEXCOORD_1 -> blue

target.release
mesh.release; tex.release; renderer.release; gpu.release

puts "TEXCOORD_0 center = #{uv0} (expect red)   TEXCOORD_1 center = #{uv1} (expect blue)"
ok = uv0[0] > 150 && uv0[0] > uv0[2] * 2 &&  # uv0 -> red
     uv1[2] > 150 && uv1[2] > uv1[0] * 2     # uv1 -> blue

puts ok ? "✅ multiple UV sets OK" : "❌ UV-set selection did not switch textures"
exit(ok ? 0 : 1)
