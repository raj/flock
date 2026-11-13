# Ogg Vorbis decoding via libvorbisfile — feeds decoded PCM into the existing
# Sound/Audio (SDL3 stream) pipeline. Complements Sound.load (WAV) for games
# that ship compressed audio; requires no audio device to decode.
#
# The consumer must have required the SDL3 binding first (shard `sdl3`, or a
# relative require of sdl3-cr) — same convention as platform/audio.cr.

module Flock
  @[Link(pkg_config: "vorbisfile")]
  lib LibVorbisFile
    # Only the first three fields are read; the struct is intentionally
    # truncated (field-wise access, no sizeof dependency).
    struct VorbisInfo
      version : Int32
      channels : Int32
      rate : Int64 # C `long` — Int64 on LP64
    end

    fun ov_fopen = ov_fopen(path : UInt8*, vf : Void*) : Int32
    fun ov_info = ov_info(vf : Void*, link : Int32) : VorbisInfo*
    fun ov_read = ov_read(vf : Void*, buffer : UInt8*, length : Int32,
                          big_endian : Int32, word : Int32, sgned : Int32,
                          bitstream : Int32*) : Int64
    fun ov_clear = ov_clear(vf : Void*) : Int32
  end

  struct Sound
    # OggVorbis_File is opaque to callers (~192 bytes in practice). We never
    # touch its contents, only hand the pointer back to the library, so an
    # over-allocated heap block is safe and portable.
    private OGGVORBIS_FILE_SIZE = 4096

    # Bytes requested per ov_read call (amortizes FFI overhead).
    private OGG_CHUNK_BYTES = 32 * 1024

    # ov_read negative results other than EOF (data hole): skip forward.
    private OV_HOLE = -3

    # Decodes a whole .ogg file into 16-bit signed little-endian PCM (native
    # byte order on little-endian targets, matching AUDIO_S16LSB).
    # No audio device is needed — pure decode, safe in tests.
    def self.load_ogg(path : String) : Sound
      vf = Pointer(UInt8).malloc(OGGVORBIS_FILE_SIZE)
      code = LibVorbisFile.ov_fopen(path.to_unsafe, vf.as(Void*))
      raise "ov_fopen #{path}: #{code}" unless code == 0

      info = LibVorbisFile.ov_info(vf.as(Void*), 0)
      if info.null?
        LibVorbisFile.ov_clear(vf.as(Void*))
        raise "ov_info #{path}: no stream"
      end
      channels = info.value.channels
      rate = info.value.rate
      if channels <= 0 || rate <= 0
        LibVorbisFile.ov_clear(vf.as(Void*))
        raise "ov_info #{path}: invalid stream (#{rate}Hz #{channels}ch)"
      end

      chunks = [] of Bytes
      total = 0
      buf = Bytes.new(OGG_CHUNK_BYTES)
      loop do
        read = LibVorbisFile.ov_read(vf.as(Void*), buf.to_unsafe, buf.size,
          0, # little endian
          2, # word size: 16-bit
          1, # signed
          out bitstream)
        break if read == 0    # EOF
        next if read == OV_HOLE # corrupt frame: skip, keep decoding
        raise "ov_read #{path}: #{read}" if read < 0
        chunk = buf[0, read]
        chunks << (read == buf.size ? chunk.dup : chunk.dup)
        total += read
      end
      LibVorbisFile.ov_clear(vf.as(Void*))

      data = Bytes.new(total)
      offset = 0
      chunks.each do |chunk|
        chunk.copy_to(data[offset, chunk.size])
        offset += chunk.size
      end

      spec = LibSDL::AudioSpec.new(format: LibSDL::AUDIO_S16LSB,
                                   channels: channels.to_i32,
                                   freq: rate.to_i32)
      Sound.new(spec, data)
    end

    # Decoded duration in seconds (convenience for tests/UX).
    def duration : Float64
      @data.size.to_f / (@spec.freq * @spec.channels * 2)
    end
  end
end
