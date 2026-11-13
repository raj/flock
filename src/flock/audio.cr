# Flock — audio-only entry point: SDL3 streams + Ogg Vorbis decoding,
# WITHOUT the platform layer's window/input or any wgpu dependency.
#
# The consumer must require the SDL3 binding first (shard `sdl3`, or a
# relative require of sdl3-cr) — same convention as the platform files:
#
#   require "sdl3"                # or "../../sdl3-cr/src/sdl3"
#   require "flock/audio"         # this file
#   app.add_plugin(Flock::SdlAudioPlugin.new)
#
# For apps without a Flock::App, Flock::Audio can be instantiated directly
# (call #reap periodically from any loop to keep loops looping and reclaim
# finished one-shots).

require "../flock"            # core (math, ecs, app, time) — platform files assume it
require "./platform/audio"
require "./platform/vorbis"

module Flock
  # Opens the audio device at startup (initializing the SDL audio subsystem
  # on demand — safe without any window) and reclaims finished streams each
  # frame on Schedule::Last.
  class SdlAudioPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        LibSDL.init_sub_system(LibSDL::INIT_AUDIO) unless LibSDL.was_init(LibSDL::INIT_AUDIO) != 0
        world.insert_resource(Audio.new)
      end
      app.add_system(Schedule::Last) do |world, _cmd|
        if a = world.resource?(Audio)
          a.update_spatial
          a.reap(world.resource(Time).delta.to_f32)
        end
      end
    end
  end
end
