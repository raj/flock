# Headless test for compressed-music playback (SDL3_mixer via Flock::Music).
# Loads an MP3/OGG, plays it, and asserts the track is actually playing.
#
#   MUSIC_FILE=/path/to/tune.mp3 WGPU_FRAMES=10 crystal run examples/music_test.cr
#
# Exits 0 on success, 1 on failure (usable in CI once a fixture is provided).
require "../src/flock/gpu"

path = ENV["MUSIC_FILE"]? || abort("set MUSIC_FILE=/path/to/audio.(mp3|ogg|flac)")
ok = false

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — music test", 320, 240))
app.add_startup { |_w, cmd| cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.1, 0.1, 0.12))) }

app.add_startup do |world, _cmd|
  music = world.resource(Flock::Music)
  music.play(path, loop: true, volume: 0.5)
end

# After a few frames the streaming track must report playing.
app.add_system(Flock::Schedule::Update) do |world, _cmd|
  ok = world.resource(Flock::Music).playing?
end

app.run

if ok
  puts "OK: music track is playing (#{path})"
  exit 0
else
  puts "FAIL: music track not playing"
  exit 1
end
