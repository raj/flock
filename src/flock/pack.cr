require "compress/deflate"

module Flock
  # A `.flkpack` asset archive: one file bundling many assets by logical key, each blob stored
  # raw or DEFLATE-compressed. A shipped game is then a binary + a pack instead of a tree of
  # loose files. `Assets#mount` serves packed bytes transparently (game code addresses assets by
  # the same logical key whether they live loose on disk or in the pack).
  #
  # Layout (little-endian):
  #   "FLKPACK1" (8 bytes) · count : u32
  #   count × index entry: key_len u16 · key bytes · flags u8 (bit0 = deflate) ·
  #                        offset u64 (into the blob region) · stored u64 · raw u64
  #   blob region: the stored (possibly compressed) bytes, concatenated
  #
  # Native only (the DEFLATE codec is a C lib that doesn't link on the wasm target; the web
  # backend loads assets via fetch). No preprocessing: blobs are the original file bytes,
  # decoded at load like a loose file.
  MAGIC = "FLKPACK1"

  # Builds a `.flkpack`: add assets by logical key, then `write`.
  #
  #   w = Flock::PackWriter.new
  #   w.add_dir("assets")          # keys = paths relative to "assets"
  #   w.write("game.flkpack")
  class PackWriter
    @entries = [] of Tuple(String, Bytes)

    # Adds raw bytes under a logical key (overwrites a duplicate key).
    def add_bytes(key : String, bytes : Bytes) : self
      @entries.reject! { |(k, _b)| k == key }
      @entries << {key, bytes}
      self
    end

    # Adds a file, keyed by `key` (defaults to the path).
    def add_file(path : String, key : String = path) : self
      add_bytes(key, File.open(path, "rb", &.getb_to_end))
    end

    # Adds every file under `dir` recursively, keyed by its path relative to `dir`
    # (forward slashes), e.g. `add_dir("assets")` → keys like "sprites/player.png".
    def add_dir(dir : String) : self
      Dir.glob(File.join(dir, "**", "*")).sort.each do |path|
        next unless File.file?(path)
        key = Path[path].relative_to(dir).to_posix.to_s
        add_file(path, key)
      end
      self
    end

    def keys : Array(String)
      @entries.map(&.[0])
    end

    # Writes the archive to `path`. Each blob is DEFLATE-compressed when that actually shrinks
    # it (else stored raw). Returns the total bytes written.
    def write(path : String) : Int64
      stored = @entries.map do |(_k, raw)|
        comp = Pack.deflate(raw)
        comp.size < raw.size ? {1_u8, comp} : {0_u8, raw}
      end
      File.open(path, "wb") do |io|
        io.write(MAGIC.to_slice)
        io.write_bytes(@entries.size.to_u32, IO::ByteFormat::LittleEndian)
        offset = 0_u64
        @entries.each_with_index do |(key, raw), i|
          flags, blob = stored[i]
          kb = key.to_slice
          io.write_bytes(kb.size.to_u16, IO::ByteFormat::LittleEndian)
          io.write(kb)
          io.write_byte(flags)
          io.write_bytes(offset, IO::ByteFormat::LittleEndian)
          io.write_bytes(blob.size.to_u64, IO::ByteFormat::LittleEndian)
          io.write_bytes(raw.size.to_u64, IO::ByteFormat::LittleEndian)
          offset += blob.size
        end
        stored.each { |(_f, blob)| io.write(blob) }
      end
      File.size(path).to_i64
    end
  end

  # Opens a `.flkpack` for reading; serves blobs by logical key (`read`), inflating on demand.
  class Pack
    # Upper bound for one decompressed asset (1 GiB): packs are game assets, and this
    # guards `read?` against a hostile header claiming a huge `raw` size.
    MAX_ENTRY_BYTES = 1_u64 << 30

    record Entry, flags : UInt8, offset : UInt64, stored : UInt64, raw : UInt64

    @entries : Hash(String, Entry)
    @base : Int64

    def self.open(path : String) : Pack
      io = File.new(path, "rb")
      magic = Bytes.new(8)
      io.read_fully(magic)
      raise "not a flkpack: #{path}" unless String.new(magic) == MAGIC
      count = io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      entries = {} of String => Entry
      count.times do
        klen = io.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        kb = Bytes.new(klen)
        io.read_fully(kb)
        flags = io.read_byte || 0_u8
        offset = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        stored = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        raw = io.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
        entries[String.new(kb)] = Entry.new(flags, offset, stored, raw)
      end
      new(io, entries, io.pos)
    end

    def initialize(@io : File, @entries : Hash(String, Entry), @base : Int64)
    end

    def keys : Array(String)
      @entries.keys
    end

    def has?(key : String) : Bool
      @entries.has_key?(key)
    end

    # Returns the (decompressed) bytes stored under `key`, or nil if absent.
    # Sizes read from the pack header are validated against the real file size so a
    # corrupt or hostile pack cannot request an arbitrary allocation (zip-bomb guard).
    def read?(key : String) : Bytes?
      e = @entries[key]?
      return nil unless e
      file_size = @io.size
      if e.offset < 0 || e.stored < 0 || e.raw < 0 || e.stored > file_size || e.raw > MAX_ENTRY_BYTES
        raise "pack entry '#{key}' has out-of-range sizes (stored=#{e.stored}, raw=#{e.raw}, file=#{file_size})"
      end
      if e.offset > file_size - e.stored
        raise "pack entry '#{key}' overruns the pack file"
      end
      @io.seek(@base + e.offset.to_i64)
      blob = Bytes.new(e.stored.to_i32)
      @io.read_fully(blob)
      (e.flags & 1_u8) != 0 ? Pack.inflate(blob, e.raw.to_i32) : blob
    end

    def read(key : String) : Bytes
      read?(key) || raise "no asset '#{key}' in pack"
    end

    def close : Nil
      @io.close
    end
  end

  class Pack
    # DEFLATE-compress bytes (raw deflate stream).
    def self.deflate(bytes : Bytes) : Bytes
      io = IO::Memory.new
      Compress::Deflate::Writer.open(io) { |d| d.write(bytes) }
      io.to_slice
    end

    # Inflate `raw_size` bytes from a raw deflate stream.
    def self.inflate(bytes : Bytes, raw_size : Int) : Bytes
      dst = Bytes.new(raw_size)
      Compress::Deflate::Reader.open(IO::Memory.new(bytes)) { |r| r.read_fully(dst) }
      dst
    end
  end
end
