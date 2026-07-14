# Audio test (headless, silent): volume, loop, and stop.
#   crystal run examples/audio_test.cr   # exit 0 if OK
require "../src/flock/gpu"

abort "SDL_Init(AUDIO) failed" unless LibSDL.init(LibSDL::INIT_AUDIO)

audio = begin
  Flock::Audio.new
rescue ex
  puts "audio device unavailable, skipping: #{ex.message}"
  exit 0
end

beep = Flock::Sound.beep(440.0, 0.05, 0.0) # amplitude 0 -> silent

# One-shot: playing then stopped.
pb = audio.play(beep, volume: 0.0)
ok = audio.playing_count == 1
audio.stop(pb)
ok &&= audio.playing_count == 0

# Loop: survives several reaps, until stopped.
loop_pb = audio.play(beep, volume: 0.0, loop: true)
5.times { audio.reap }
ok &&= audio.playing_count == 1 && loop_pb.loop?
audio.stop(loop_pb)
ok &&= audio.playing_count == 0

# Master volume: applies without error.
audio.master_volume = 0.5
ok &&= audio.master_volume == 0.5f32

audio.stop_all
LibSDL.quit

puts ok ? "✅ audio volume/loop/stop OK" : "❌ audio behavior unexpected"
exit(ok ? 0 : 1)
