# Audio bus / spatial / pitch test (headless, silent).
#   crystal run examples/audio_bus_test.cr   # exit 0 if OK (or skips w/o an audio device)
require "../src/flock/gpu"

abort "SDL_Init(AUDIO) failed" unless LibSDL.init(LibSDL::INIT_AUDIO)

audio = begin
  Flock::Audio.new
rescue ex
  puts "audio device unavailable, skipping: #{ex.message}"
  exit 0
end

V = Flock::Vec2
beep = Flock::Sound.beep(440.0, 0.05, 0.0) # silent (amplitude 0)

ok = true
report = ->(name : String, pass : Bool) { ok = false unless pass; puts "#{pass ? "✓" : "✗"} #{name}" }

# --- Mixing bus ---
audio.bus_volume(:music, 0.3)
m = audio.play(beep, volume: 1.0, bus: :music)
report.call("bus assigned", m.bus == :music)
report.call("bus volume stored", audio.bus_volume(:music) == 0.3f32)
report.call("default bus is 1.0", audio.bus_volume(:sfx) == 1.0f32)
audio.stop(m)

# --- Spatial attenuation ---
audio.listener = V.new(0, 0)
near = audio.play_spatial(beep, at: V.new(0, 0), max_distance: 100.0)
report.call("at listener → full gain", near.spatial_gain == 1.0f32)

audio.listener = V.new(80, 0) # 80 of 100 away → 1 - 0.8 = 0.2
audio.update_spatial
report.call("attenuates with distance", (near.spatial_gain - 0.2f32).abs < 1e-4)

audio.listener = V.new(500, 0) # past max_distance → silent
audio.update_spatial
report.call("silent past max_distance", near.spatial_gain == 0.0f32)
audio.stop(near)

# --- Pitch effect ---
p = audio.play(beep, pitch: 2.0)
report.call("pitch at play", p.pitch == 2.0f32)
audio.pitch(p, 0.5)
report.call("pitch changed live", p.pitch == 0.5f32)
audio.stop(p)

audio.stop_all
audio.release

puts ok ? "✅ audio bus/spatial/pitch OK" : "❌ audio unexpected"
exit(ok ? 0 : 1)
