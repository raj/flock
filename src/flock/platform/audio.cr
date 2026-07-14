module Flock
  # Un son chargé/synthétisé en mémoire (PCM déjà décodé + son format).
  struct Sound
    getter spec : LibSDL::AudioSpec
    getter data : Bytes

    def initialize(@spec : LibSDL::AudioSpec, @data : Bytes)
    end

    # Charge un WAV depuis un fichier (ne nécessite pas de device audio).
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

    # Bip procédural (onde carrée) — utile pour un exemple sans fichier audio.
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

  # Lecture audio via SDL3. Un device de sortie est ouvert ; chaque `play` crée un
  # stream lié au device — SDL mixe nativement les streams simultanés. Les streams
  # terminés sont récupérés chaque frame (schedule Last).
  class Audio < Resource
    @spec : LibSDL::AudioSpec
    @device : LibSDL::AudioDeviceID
    @main : LibSDL::AudioStream
    @playing : Array(LibSDL::AudioStream) = [] of LibSDL::AudioStream

    def initialize
      @spec = LibSDL::AudioSpec.new(format: LibSDL::AUDIO_F32LE, channels: 2, freq: 48_000)
      @main = LibSDL.open_audio_device_stream(LibSDL::AUDIO_DEVICE_DEFAULT_PLAYBACK, pointerof(@spec), Pointer(Void).null, Pointer(Void).null)
      raise "SDL_OpenAudioDeviceStream: #{String.new(LibSDL.get_error)}" if @main.null?
      @device = LibSDL.get_audio_stream_device(@main)
      LibSDL.resume_audio_stream_device(@main)
    end

    def load(path : String) : Sound
      Sound.load(path)
    end

    def play(sound : Sound) : Nil
      src = sound.spec
      dst = @spec
      stream = LibSDL.create_audio_stream(pointerof(src), pointerof(dst))
      return if stream.null?
      LibSDL.bind_audio_stream(@device, stream)
      LibSDL.put_audio_stream_data(stream, sound.data.to_unsafe.as(Void*), sound.data.size)
      LibSDL.resume_audio_stream_device(stream)
      @playing << stream
    end

    # Récupère les streams dont la lecture est terminée.
    def reap : Nil
      @playing.reject! do |s|
        if LibSDL.get_audio_stream_queued(s) <= 0
          LibSDL.destroy_audio_stream(s)
          true
        else
          false
        end
      end
    end
  end

  # Ouvre le device audio au startup (après l'init SDL par WindowPlugin) et récupère
  # les streams finis chaque frame.
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
