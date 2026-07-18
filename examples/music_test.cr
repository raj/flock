# Headless test for compressed-music playback (SDL3_mixer via Flock::Music).
# Loads an MP3/OGG, plays it, and asserts the track is actually playing.
#
#   MUSIC_FILE=/path/to/tune.mp3 WGPU_FRAMES=10 crystal run examples/music_test.cr
#
# Exits 0 on success, 1 on failure (usable in CI once a fixture is provided).
require "../src/flock/gpu"

# Read-only capture: a runtime-initialized top-level constant (Bevy-style config).
MUSIC_PATH = ENV["MUSIC_FILE"]? || abort("set MUSIC_FILE=/path/to/audio.(mp3|ogg|flac)")

# Mutable across-frame flag: the last observed "is the track playing?" result.
class MusicCheck < Flock::Resource
  property ok : Bool

  def initialize(@ok : Bool = false)
  end
end

def setup(world : Flock::World, cmd : Flock::Commands)
  world.insert_resource(MusicCheck.new)
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.1, 0.1, 0.12)))
end

def start_music(world : Flock::World, cmd : Flock::Commands)
  music = world.resource(Flock::Music)
  music.play(MUSIC_PATH, loop: true, volume: 0.5)
end

# After a few frames the streaming track must report playing.
def check_playing(world : Flock::World, cmd : Flock::Commands)
  world.resource(MusicCheck).ok = world.resource(Flock::Music).playing?
end

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("Flock — music test", 320, 240))
app.add_startup(&->setup(Flock::World, Flock::Commands))
app.add_startup(&->start_music(Flock::World, Flock::Commands))
app.add_system(Flock::Schedule::Update, &->check_playing(Flock::World, Flock::Commands))

app.run

if app.world.resource(MusicCheck).ok
  puts "OK: music track is playing (#{MUSIC_PATH})"
  exit 0
else
  puts "FAIL: music track not playing"
  exit 1
end
