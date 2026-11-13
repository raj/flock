# Audio-only entry specs — gated behind FLOCK_AUDIO_IT (empty file without
# it). Uses the SDL dummy driver so no real audio device is needed; validates
# that require "flock/audio" pulls SDL3 streams + vorbis WITHOUT wgpu, that
# SdlAudioPlugin initializes the subsystem and the device, and that playback
# + loop re-queue work end to end.

{% if env("FLOCK_AUDIO_IT") %}
  require "sdl3"
  require "../spec_helper"
  require "../../src/flock/audio"

  describe "Flock audio-only entry (flock/audio)" do
    fixture = File.expand_path("../fixtures/sine440_1s.ogg", __DIR__)

    it "requires without wgpu and exposes Audio + Sound.load_ogg" do
      # Compile-time proof: these constants/methods exist after the require.
      Flock::Sound.load_ogg(fixture).spec.freq.should eq 44_100
      Flock::Audio.name.should eq "Flock::Audio"
    end

    it "SdlAudioPlugin inserts an Audio resource and ticks reap" do
      app = Flock::App.new
      app.add_plugin(Flock::SdlAudioPlugin.new)
      app.startup

      audio = app.world.resource?(Flock::Audio)
      audio.should_not be_nil

      snd = Flock::Sound.load_ogg(fixture)
      pb = audio.not_nil!.play(snd, loop: true, bus: :music)
      pb.active?.should be_true
      audio.not_nil!.playing_count.should be > 0

      # Simulate a few frames: the Last system runs on update.
      3.times { app.update }
      audio.not_nil!.playing_count.should be > 0 # loop kept alive by re-queue

      audio.not_nil!.stop_all
      audio.not_nil!.playing_count.should eq 0
    end
  end
{% end %}
