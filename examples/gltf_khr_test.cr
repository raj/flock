# glTF KHR extension parsing test (headless, no GPU context needed — pure helpers).
#   crystal run examples/gltf_khr_test.cr   # exit 0 if OK
require "../src/flock/gpu"

ok = true
report = ->(name : String, pass : Bool) { ok = false unless pass; puts "#{pass ? "✓" : "✗"} #{name}" }
close = ->(a : Float32, b : Float32) { (a - b).abs < 1e-5 }

# KHR_texture_transform: parse offset/scale/rotation.
tt = Flock::Mesh.read_texture_transform(JSON.parse(%({"offset":[0.5,0.25],"scale":[2.0,3.0],"rotation":0.0})))
report.call("texture_transform parsed", close.call(tt[0], 0.5f32) && close.call(tt[2], 2.0f32) && close.call(tt[3], 3.0f32))

# defaults when fields absent
d = Flock::Mesh.read_texture_transform(JSON.parse("{}"))
report.call("defaults: no offset, unit scale", close.call(d[0], 0.0f32) && close.call(d[2], 1.0f32) && close.call(d[3], 1.0f32))

# apply: scale then offset (rotation 0).
u, v = Flock::Mesh.apply_uv_transform(0.5f32, 0.5f32, tt) # (0.5*2+0.5, 0.5*3+0.25) = (1.5, 1.75)
report.call("apply scale+offset", close.call(u, 1.5f32) && close.call(v, 1.75f32))

# apply: 90° rotation of (1,0) → (0,-1) (unit scale, no offset).
rt = {0.0f32, 0.0f32, 1.0f32, 1.0f32, (Math::PI / 2).to_f32}
ru, rv = Flock::Mesh.apply_uv_transform(1.0f32, 0.0f32, rt)
report.call("apply rotation 90°", close.call(ru, 0.0f32) && close.call(rv, -1.0f32))

# KHR_materials_emissive_strength.
es = Flock::Mesh.read_emissive_strength(JSON.parse(%({"extensions":{"KHR_materials_emissive_strength":{"emissiveStrength":5.0}}})))
report.call("emissive_strength parsed", close.call(es, 5.0f32))
report.call("emissive_strength default 1", close.call(Flock::Mesh.read_emissive_strength(JSON.parse("{}")), 1.0f32))

puts ok ? "✅ glTF KHR extensions OK" : "❌ KHR parse unexpected"
exit(ok ? 0 : 1)
