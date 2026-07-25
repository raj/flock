module Flock
  # A sound loaded/synthesized in memory (already-decoded PCM + its format).
  struct Sound
    getter spec : LibSDL::AudioSpec
    getter data : Bytes

    def initialize(@spec : LibSDL::AudioSpec, @data : Bytes)
    end

    # Loads a WAV from a file (does not require an audio device).
    def self.load(path : String) : Sound
      spec = LibSDL::AudioSpec.new
      buf = Pointer(UInt8).null
      len = 0_u32
      unless LibSDL.load_wav(path.to_unsafe, pointerof(spec), pointerof(buf), pointerof(len))
        raise "SDL_LoadWAV #{path}: #{String.new(LibSDL.get_error)}"
      end
      data = Bytes.new(len)
      data.copy_from(buf, len)
      LibSDL.sdl_free(buf.as(Void*))
      Sound.new(spec, data)
    end

    # Procedural beep (square wave) — useful for an example without an audio file.
    def self.beep(frequency : Number = 440.0, seconds : Number = 0.12,
                  volume : Number = 0.25, sample_rate : Int32 = 48_000) : Sound
      n = (seconds * sample_rate).to_i
      samples = Array(Float32).new(n) do |i|
        phase = (i.to_f * frequency / sample_rate) % 1.0
        (phase < 0.5 ? volume : -volume).to_f32
      end
      data = Bytes.new(n * 4)
      data.copy_from(samples.to_unsafe.as(UInt8*), n * 4)
      spec = LibSDL::AudioSpec.new(format: LibSDL::AUDIO_F32LE, channels: 1, freq: sample_rate)
      Sound.new(spec, data)
    end
  end

  # A handle to a running (or looping) playback, returned by `Audio#play`. Pass it
  # to `Audio#stop`. `loop?` playbacks keep going until stopped.
  class Playback
    getter stream : LibSDL::AudioStream
    getter sound : Sound
    property? loop : Bool
    property volume : Float32
    property? active : Bool = true
    # Mixing bus this playback belongs to (its volume multiplies in). Default :sfx.
    property bus : Symbol = :sfx
    # Spatial emitter position (nil = non-spatial / 2D UI sound); `max_distance` past which it's
    # silent; `spatial_gain` is the computed distance attenuation (1 = full).
    property emitter : Vec2? = nil
    property max_distance : Float32 = 500.0f32
    property spatial_gain : Float32 = 1.0f32
    property pitch : Float32 = 1.0f32

    def initialize(@stream : LibSDL::AudioStream, @sound : Sound, @loop : Bool, @volume : Float32)
    end
  end

  # Audio playback via SDL3. An output device is opened; each `play` creates a stream
  # bound to the device — SDL natively mixes simultaneous streams. One-shot playbacks
  # are reclaimed when finished; looping ones are re-queued; all react to `master_volume`.
  class Audio < Resource
    getter master_volume : Float32 = 1.0f32

    @spec : LibSDL::AudioSpec
    @device : LibSDL::AudioDeviceID
    @main : LibSDL::AudioStream
    @playing : Array(Playback) = [] of Playback
    @beeps : Hash(Tuple(Int32, Int32), Sound) = {} of Tuple(Int32, Int32) => Sound
    # Named mixing buses (volume multiplier, default 1.0) + the spatial listener position.
    @buses : Hash(Symbol, Float32) = {} of Symbol => Float32
    property listener : Vec2 = Vec2.new

    def initialize
      @spec = LibSDL::AudioSpec.new(format: LibSDL::AUDIO_F32LE, channels: 2, freq: 48_000)
      @main = LibSDL.open_audio_device_stream(LibSDL::AUDIO_DEVICE_DEFAULT_PLAYBACK, pointerof(@spec), Pointer(Void).null, Pointer(Void).null)
      raise "SDL_OpenAudioDeviceStream: #{String.new(LibSDL.get_error)}" if @main.null?
      @device = LibSDL.get_audio_stream_device(@main)
      LibSDL.resume_audio_stream_device(@main)
    end

    # Release before GpuContext (which calls SDL_Quit): stop live playbacks + the device.
    def release_order : Int32
      50
    end

    def release : Nil
      stop_all
      LibSDL.destroy_audio_stream(@main) unless @main.null?
      @main = Pointer(Void).null.as(LibSDL::AudioStream)
    end

    def load(path : String) : Sound
      Sound.load(path)
    end

    # Portable 8-bit-style beep: `frequency` Hz for `ms` milliseconds. Same signature as
    # the web backend's `Flock::Audio#beep`, so game code is identical on both. Cached.
    def beep(frequency : Number, ms : Number, volume : Number = 0.25) : Nil
      key = {frequency.to_i, ms.to_i}
      snd = (@beeps[key] ||= Sound.beep(frequency.to_f, ms.to_f / 1000.0, volume.to_f))
      play(snd)
    end

    # Volume (0..1) of a named mixing bus (default 1.0). Buses multiply between the master and
    # each playback's own volume (e.g. separate :music / :sfx sliders).
    def bus_volume(name : Symbol) : Float32
      @buses[name]? || 1.0f32
    end

    def bus_volume(name : Symbol, v : Number) : Nil
      @buses[name] = v.to_f32
      @playing.each { |pb| apply_gain(pb) if pb.bus == name }
    end

    # Plays `sound`. `volume` (0..1) scales this playback; `loop` repeats until stopped; `bus`
    # picks a mixing bus; `pitch` is a playback-speed/pitch ratio (1 = normal). Returns a handle.
    def play(sound : Sound, volume : Number = 1.0, loop : Bool = false,
             bus : Symbol = :sfx, pitch : Number = 1.0) : Playback
      vol = volume.to_f32
      src = sound.spec
      stream = LibSDL.create_audio_stream(pointerof(src), pointerof(@spec))
      pb = Playback.new(stream, sound, loop, vol)
      pb.bus = bus
      pb.pitch = pitch.to_f32
      if stream.null?
        # Stream creation failed: the handle isn't playing and isn't tracked in
        # @playing, so mark it inactive to reflect its real state.
        pb.active = false
        return pb
      end

      apply_gain(pb)
      LibSDL.set_audio_stream_frequency_ratio(stream, pb.pitch) if pb.pitch != 1.0f32
      LibSDL.put_audio_stream_data(stream, sound.data.to_unsafe.as(Void*), sound.data.size)
      LibSDL.bind_audio_stream(@device, stream)
      LibSDL.resume_audio_stream_device(stream)
      @playing << pb
      pb
    end

    # Plays `sound` at a world position: its volume attenuates with distance to `listener`
    # (linear, silent past `max_distance`), recomputed each frame by `update_spatial`.
    def play_spatial(sound : Sound, at : Vec2, volume : Number = 1.0, loop : Bool = false,
                     bus : Symbol = :sfx, max_distance : Number = 500.0, pitch : Number = 1.0) : Playback
      pb = play(sound, volume, loop, bus, pitch)
      return pb unless pb.active?
      pb.emitter = at
      pb.max_distance = max_distance.to_f32
      pb.spatial_gain = attenuation(at, pb.max_distance)
      apply_gain(pb)
      pb
    end

    # Recomputes distance attenuation for every spatial playback from the current `listener`.
    # Call once per frame after moving the listener (wired into AudioPlugin's Last system).
    def update_spatial : Nil
      @playing.each do |pb|
        if e = pb.emitter
          pb.spatial_gain = attenuation(e, pb.max_distance)
          apply_gain(pb)
        end
      end
    end

    private def attenuation(pos : Vec2, max_distance : Float32) : Float32
      return 1.0f32 if max_distance <= 0.0f32
      d = (pos - @listener).length
      (1.0f32 - d / max_distance).clamp(0.0f32, 1.0f32)
    end

    # Sets a playback's live gain = master × bus × its volume × spatial attenuation.
    private def apply_gain(pb : Playback) : Nil
      return if pb.stream.null?
      LibSDL.set_audio_stream_gain(pb.stream, @master_volume * bus_volume(pb.bus) * pb.volume * pb.spatial_gain)
    end

    # Changes a live playback's pitch/speed ratio (1 = normal).
    def pitch(pb : Playback, ratio : Number) : Nil
      return unless pb.active?
      pb.pitch = ratio.to_f32
      LibSDL.set_audio_stream_frequency_ratio(pb.stream, pb.pitch)
    end

    # Stops (and frees) a playback.
    def stop(pb : Playback) : Nil
      return unless pb.active?
      pb.active = false
      LibSDL.destroy_audio_stream(pb.stream)
      @playing.delete(pb)
    end

    def stop_all : Nil
      @playing.each do |pb|
        pb.active = false
        LibSDL.destroy_audio_stream(pb.stream)
      end
      @playing.clear
    end

    # Master gain (0..1) applied on top of each playback's own volume.
    def master_volume=(v : Number) : Nil
      @master_volume = v.to_f32
      @playing.each { |pb| apply_gain(pb) }
    end

    def playing_count : Int32
      @playing.size
    end

    # Per-frame: re-queue looping playbacks, reclaim finished one-shots.
    def reap : Nil
      @playing.reject! do |pb|
        if pb.loop?
          # keep at least one copy queued for a seamless loop.
          if LibSDL.get_audio_stream_queued(pb.stream) < pb.sound.data.size
            LibSDL.put_audio_stream_data(pb.stream, pb.sound.data.to_unsafe.as(Void*), pb.sound.data.size)
          end
          false
        elsif LibSDL.get_audio_stream_queued(pb.stream) <= 0
          LibSDL.destroy_audio_stream(pb.stream)
          pb.active = false
          true
        else
          false
        end
      end
    end
  end

  # Opens the audio device at startup (after SDL init by WindowPlugin) and reclaims
  # finished streams each frame.
  class AudioPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        world.insert_resource(Audio.new)
      end
      app.add_system(Schedule::Last) do |world, _cmd|
        if a = world.resource?(Audio)
          a.update_spatial
          a.reap
        end
      end
    end
  end
end
