# Vorbis decoding specs — gated behind FLOCK_AUDIO_IT: without the variable the
# file compiles empty (no vorbisfile/SDL3 link needed), so the default CI job
# stays native-free. Decoding is pure (no device), but it links the same
# libraries as the audio layer, hence the gate.

{% if env("FLOCK_AUDIO_IT") %}
  require "sdl3" # LibSDL::AudioSpec + AUDIO_S16LSB (shard: sdl3-cr)
  require "../spec_helper"
  require "../../src/flock/platform/audio"   # Sound (assumes LibSDL defined)
  require "../../src/flock/platform/vorbis"  # Sound.load_ogg

  describe "Flock::Sound.load_ogg" do
    fixture = File.expand_path("../fixtures/sine440_1s.ogg", __DIR__)

    it "decodes the fixture (stereo 44.1kHz, ~1s)" do
      snd = Flock::Sound.load_ogg(fixture)
      snd.spec.freq.should eq 44_100
      snd.spec.channels.should eq 2
      snd.data.size.should be > 170_000   # ~176 400 bytes for 1s S16 stereo
      snd.data.size.should be < 190_000
      snd.duration.should be_close(1.0, 0.05)
    end

    it "produces non-silent signed PCM" do
      snd = Flock::Sound.load_ogg(fixture)
      samples = snd.data.to_unsafe.as(Int16*)
      non_zero = 0
      0.step(by: 997, to: snd.data.size // 2 - 1) do |i|
        non_zero += 1 unless samples[i].zero?
      end
      non_zero.should be > 50 # a sine must produce energy
    end

    it "raises with context on a non-ogg file" do
      path = File.join(Dir.tempdir, "not_an_ogg_#{Time.utc.to_unix_ms}.bin")
      File.write(path, "definitely not ogg data")
      begin
        expect_raises(Exception, /ov_fopen/) { Flock::Sound.load_ogg(path) }
      ensure
        File.delete(path)
      end
    end
  end
{% end %}
