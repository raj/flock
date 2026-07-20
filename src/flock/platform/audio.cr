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

    # Plays `sound`. `volume` (0..1) scales this playback; `loop` repeats it until
    # stopped. Returns a Playback handle (for `stop`).
    def play(sound : Sound, volume : Number = 1.0, loop : Bool = false) : Playback
      vol = volume.to_f32
      src = sound.spec
      stream = LibSDL.create_audio_stream(pointerof(src), pointerof(@spec))
      pb = Playback.new(stream, sound, loop, vol)
      if stream.null?
        # Stream creation failed: the handle isn't playing and isn't tracked in
        # @playing, so mark it inactive to reflect its real state.
        pb.active = false
        return pb
      end

      LibSDL.set_audio_stream_gain(stream, vol * @master_volume)
      LibSDL.put_audio_stream_data(stream, sound.data.to_unsafe.as(Void*), sound.data.size)
      LibSDL.bind_audio_stream(@device, stream)
      LibSDL.resume_audio_stream_device(stream)
      @playing << pb
      pb
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
      @playing.each { |pb| LibSDL.set_audio_stream_gain(pb.stream, pb.volume * @master_volume) }
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
        world.resource?(Audio).try &.reap
      end
    end
  end
end
