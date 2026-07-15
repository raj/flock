module Flock
  # Streaming background music (OGG/MP3/FLAC/Opus/…) via SDL3_mixer. Complements
  # `Audio`, which handles short sound effects (decoded WAV/PCM). Music is a single
  # track: `play` replaces whatever was playing.
  #
  #   music = world.resource(Flock::Music)
  #   music.play("assets/theme.ogg")            # loops by default
  #   music.play("assets/win.mp3", loop: false, volume: 0.6)
  #   music.pause; music.resume; music.stop
  #
  # SDL3_mixer decodes on the fly (low memory). It opens its own logical device on
  # the default output; SDL mixes it with the sound-effect streams.
  class Music < Resource
    @mixer : LibMIX::Mixer
    @track : LibMIX::Track
    @current : LibMIX::Audio
    getter volume : Float32 = 1.0f32

    def initialize
      raise "MIX_Init: #{String.new(LibMIX.get_error)}" unless LibMIX.init
      @mixer = LibMIX.create_mixer_device(LibSDL::AUDIO_DEVICE_DEFAULT_PLAYBACK, Pointer(Void).null)
      raise "MIX_CreateMixerDevice: #{String.new(LibMIX.get_error)}" if @mixer.null?
      @track = LibMIX.create_track(@mixer)
      raise "MIX_CreateTrack: #{String.new(LibMIX.get_error)}" if @track.null?
      @current = Pointer(Void).null.as(LibMIX::Audio)
    end

    # Plays `path` (OGG/MP3/FLAC/Opus/…), replacing any current music. `loop`
    # repeats it forever; `volume` (0..1) sets this track's gain.
    def play(path : String, loop : Bool = true, volume : Number = 1.0) : Nil
      stop
      audio = LibMIX.load_audio(@mixer, path.to_unsafe, false)
      raise "MIX_LoadAudio #{path}: #{String.new(LibMIX.get_error)}" if audio.null?
      @current = audio
      @volume = volume.to_f32
      LibMIX.set_track_audio(@track, audio)
      LibMIX.set_track_gain(@track, @volume)
      LibMIX.play_track(@track, 0_u32)
      LibMIX.set_track_loops(@track, loop ? -1 : 0)
    end

    def pause : Nil
      LibMIX.pause_track(@track)
    end

    def resume : Nil
      LibMIX.resume_track(@track)
    end

    # Stops the music and frees the decoded audio.
    def stop : Nil
      LibMIX.stop_track(@track, 0_i64)
      unless @current.null?
        LibMIX.destroy_audio(@current)
        @current = Pointer(Void).null.as(LibMIX::Audio)
      end
    end

    def playing? : Bool
      LibMIX.track_playing(@track)
    end

    def paused? : Bool
      LibMIX.track_paused(@track)
    end

    # Sets this track's gain (0..1).
    def volume=(v : Number) : Nil
      @volume = v.to_f32
      LibMIX.set_track_gain(@track, @volume)
    end

    def release : Nil
      stop
      LibMIX.destroy_track(@track) unless @track.null?
      LibMIX.destroy_mixer(@mixer) unless @mixer.null?
      LibMIX.quit
    end
  end

  # Initializes SDL3_mixer and inserts the Music resource at startup (after SDL
  # audio init by WindowPlugin).
  class MusicPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        world.insert_resource(Music.new)
      end
    end
  end
end
