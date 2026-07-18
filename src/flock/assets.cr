module Flock
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

    def initialize(@gpu : GpuContext)
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
      @textures.clear
      @fonts.clear
      @sounds.clear
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
end
