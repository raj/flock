# Headless test for CUBICSPLINE animation interpolation (glTF). Builds a channel with
# two keyframes and out/in tangents chosen so the Hermite spline overshoots the linear
# midpoint, then checks the sampled endpoints and midpoint against the closed form.
#
#   crystal run examples/cubicspline_test.cr   # exit 0 if OK
require "../src/flock/gpu"

# VEC3 translation, keyframes at t=0 and t=1. CUBICSPLINE layout per keyframe:
# {in-tangent(3), value(3), out-tangent(3)}. Only the x component is exercised.
# k0: in=(0,0,0) v=(0,0,0) out=(2,0,0)   k1: in=(-2,0,0) v=(1,0,0) out=(0,0,0)
values = [
  0f32, 0f32, 0f32, 0f32, 0f32, 0f32, 2f32, 0f32, 0f32,
  -2f32, 0f32, 0f32, 1f32, 0f32, 0f32, 0f32, 0f32, 0f32,
]
ch = Flock::GltfChannel.new(0, "translation", [0f32, 1f32], values, "CUBICSPLINE")

s0 = ch.sample(0.0f32)[0]
s1 = ch.sample(1.0f32)[0]
# Hermite at t=0.5 (td=1): h00=0.5,h10=0.125,h01=0.5,h11=-0.125
# x = 0.5*0 + 0.125*1*2 + 0.5*1 + (-0.125)*1*(-2) = 0.25 + 0.5 + 0.25 = 1.0
sm = ch.sample(0.5f32)[0]

puts "sample(0)=#{s0}, sample(0.5)=#{sm}, sample(1)=#{s1}"
ok = (s0 - 0.0f32).abs < 1e-4 && (s1 - 1.0f32).abs < 1e-4 && (sm - 1.0f32).abs < 1e-4

# Also confirm a LINEAR channel gives the plain midpoint (0.5) for the same values-as-keys.
lin = Flock::GltfChannel.new(0, "translation", [0f32, 1f32], [0f32, 0f32, 0f32, 1f32, 0f32, 0f32], "LINEAR")
lm = lin.sample(0.5f32)[0]
puts "linear midpoint=#{lm} (expect 0.5)"
ok &&= (lm - 0.5f32).abs < 1e-4

puts ok ? "✅ CUBICSPLINE interpolation OK" : "❌ cubic spline sampling wrong"
exit(ok ? 0 : 1)
