module Flock
  # A lightweight, ref-counted reference to a loaded asset. Typed by T (Texture / Sound), so
  # `assets.get(handle)` returns the right type. Copyable; equality is by id.
  struct Handle(T)
    getter id : UInt32

    def initialize(@id : UInt32)
    end

    def ==(other : Handle(T)) : Bool
      @id == other.id
    end
  end

  # One tracked asset: its source path, ref-count, last-seen mtime, a version bumped on each
  # hot-reload, and the loaded object (texture OR sound).
  class AssetEntry
    property key : String
    property path : String
    property refs : Int32 = 0
    property mtime : Int64 = 0_i64
    property version : Int32 = 0
    property texture : Texture?
    property sound : Sound?

    def initialize(@key : String, @path : String)
    end
  end

  # Asset manager (resource): cache by key + centralized release.
  # Avoids reloading the same file twice (otherwise each `Texture.load` creates
  # a new GPU texture). Released before the GpuContext (default release_order).
  #
  #   assets = world.resource(Flock::Assets)
  #   tex = assets.texture("assets/player.png")   # loaded once, cached
  #   fnt = assets.font("assets/Roboto.ttf", 24)
  #   snd = assets.sound("assets/shoot.wav")
  class Assets < Resource
    @textures = {} of String => Texture
    @fonts = {} of Tuple(String, Float32) => Font
    @sounds = {} of String => Sound
    @atlases = {} of Tuple(String, Float32) => GlyphAtlas

    # --- Ref-counted handle server (load/get/retain/release + hot-reload) ---
    @entries = {} of UInt32 => AssetEntry
    @id_by_key = {} of String => UInt32
    @next_handle = 0_u32
    @placeholder : Texture?

    def initialize(@gpu : GpuContext)
    end

    # Loads (or reuses) a texture by path, returning a ref-counted Handle. Loading the same
    # path again returns the same handle and bumps its ref-count.
    def load(type : Texture.class, path : String) : Handle(Texture)
      Handle(Texture).new(load_entry("tex:#{path}", path) { |e| e.texture = Texture.load(@gpu, path) })
    end

    def load(type : Sound.class, path : String) : Handle(Sound)
      Handle(Sound).new(load_entry("snd:#{path}", path) { |e| e.sound = Sound.load(path) })
    end

    private def load_entry(key : String, path : String, & : AssetEntry ->) : UInt32
      if id = @id_by_key[key]?
        @entries[id].refs += 1
        return id
      end
      id = (@next_handle += 1)
      e = AssetEntry.new(key, path)
      yield e
      e.refs = 1
      e.mtime = mtime_of(path)
      @entries[id] = e
      @id_by_key[key] = id
      id
    end

    # Resolves a texture handle to its Texture (a shared white placeholder if freed/missing).
    def get(handle : Handle(Texture)) : Texture
      e = @entries[handle.id]?
      (e && (t = e.texture)) ? t : placeholder
    end

    # Resolves a sound handle (nil if freed/missing).
    def get(handle : Handle(Sound)) : Sound?
      (e = @entries[handle.id]?) ? e.sound : nil
    end

    # The current hot-reload version of a handle (bumped on each reload; -1 if freed).
    def version(handle : Handle) : Int32
      (e = @entries[handle.id]?) ? e.version : -1
    end

    def alive?(handle : Handle) : Bool
      @entries.has_key?(handle.id)
    end

    def ref_count(handle : Handle) : Int32
      (e = @entries[handle.id]?) ? e.refs : 0
    end

    # Adds a reference (pair with `release`).
    def retain(handle : Handle) : Nil
      (e = @entries[handle.id]?).try { |x| x.refs += 1 }
    end

    # Drops a reference; frees the GPU/audio resource and forgets the asset at zero refs.
    def release(handle : Handle) : Nil
      e = @entries[handle.id]?
      return unless e
      e.refs -= 1
      return if e.refs > 0
      e.texture.try &.release
      @entries.delete(handle.id)
      @id_by_key.delete(e.key)
    end

    # Reloads any tracked asset whose file changed on disk (in place: the handle stays valid,
    # its version bumps). Call from a system (see AssetHotReloadPlugin). Returns the count.
    def poll_hot_reload : Int32
      n = 0
      @entries.each_value do |e|
        m = mtime_of(e.path)
        next unless m > e.mtime
        e.mtime = m
        if e.texture
          old = e.texture
          e.texture = Texture.load(@gpu, e.path)
          old.try &.release
          e.version += 1; n += 1
        elsif e.sound
          e.sound = Sound.load(e.path)
          e.version += 1; n += 1
        end
      end
      n
    end

    private def mtime_of(path : String) : Int64
      (info = File.info?(path)) ? info.modification_time.to_unix : 0_i64
    end

    private def placeholder : Texture
      @placeholder ||= Texture.white(@gpu)
    end

    # Texture loaded from a file (PNG/JPG…), cached by path.
    def texture(path : String) : Texture
      @textures[path] ||= Texture.load(@gpu, path)
    end

    # Font, cached by (path, size).
    def font(path : String, size : Number) : Font
      @fonts[{path, size.to_f32}] ||= Font.load(path, size)
    end

    # WAV sound, cached by path.
    def sound(path : String) : Sound
      @sounds[path] ||= Sound.load(path)
    end

    # Glyph atlas for a (font, size), cached. Rasterizes every printable glyph once; text
    # then draws as batched quads (see GlyphAtlas / TextLabel).
    def glyph_atlas(path : String, size : Number) : GlyphAtlas
      @atlases[{path, size.to_f32}] ||= GlyphAtlas.new(@gpu, path, size)
    end

    # Registers an already-created texture (e.g. text rendering) under a key, to
    # reuse it and release it with the others.
    def store_texture(key : String, texture : Texture) : Texture
      # Release a different texture previously stored under this key (e.g. re-rendered text)
      # so overwriting doesn't leak its GPU handle. Texture#release is idempotent.
      if (old = @textures[key]?) && !old.same?(texture)
        old.release
      end
      @textures[key] = texture
    end

    def release : Nil
      @textures.each_value &.release
      @fonts.each_value &.release
      @atlases.each_value &.texture.release
      @entries.each_value do |e|
        e.texture.try &.release
      end
      @placeholder.try &.release
      @textures.clear
      @fonts.clear
      @sounds.clear
      @atlases.clear
      @entries.clear
      @id_by_key.clear
    end
  end

  # Inserts the Assets resource at startup (from the GpuContext).
  class AssetsPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        world.insert_resource(Assets.new(world.resource(GpuContext)))
      end
    end
  end

  # Polls handle-loaded assets for on-disk changes each frame and reloads them in place
  # (native hot-reload). Handles stay valid; their `version` bumps. Add after AssetsPlugin.
  class AssetHotReloadPlugin < Plugin
    def build(app : App) : Nil
      app.add_system(Flock::Schedule::Last) do |world, _cmd|
        world.resource?(Assets).try &.poll_hot_reload
      end
    end
  end
end
