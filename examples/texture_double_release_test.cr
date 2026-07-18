# Regression: Texture#release is idempotent. glTF PBR loading de-duplicates textures (one
# packed ORM map can back several material slots), so the same Texture object may be released
# more than once. A double release must NOT double-free the GPU handle nor fire the on_release
# callbacks twice.
#
#   crystal run examples/texture_double_release_test.cr   # exit 0 if OK
require "../src/flock/gpu"

gpu = Flock.headless_context(32, 32)
tex = Flock::Texture.from_pixels(gpu, 1, 1, Bytes[200_u8, 100_u8, 50_u8, 255_u8])

fired = 0
tex.on_release { fired += 1 }

tex.release
tex.release # must be a no-op (idempotent) — no double-free, no second callback
tex.release

gpu.release

puts "on_release fired #{fired} time(s) across 3 release calls"
ok = fired == 1
puts ok ? "✅ Texture#release idempotent OK" : "❌ double release is not guarded (fired #{fired})"
exit(ok ? 0 : 1)
