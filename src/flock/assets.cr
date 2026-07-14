module Flock
  # Gestionnaire d'assets (ressource) : cache par clé + libération centralisée.
  # Évite de recharger deux fois le même fichier (chaque `Texture.load` crée sinon
  # une nouvelle texture GPU). Libéré avant le GpuContext (release_order par défaut).
  #
  #   assets = world.resource(Flock::Assets)
  #   tex = assets.texture("assets/player.png")   # chargé une fois, mis en cache
  #   fnt = assets.font("assets/Roboto.ttf", 24)
  #   snd = assets.sound("assets/shoot.wav")
  class Assets < Resource
    @textures = {} of String => Texture
    @fonts = {} of Tuple(String, Float32) => Font
    @sounds = {} of String => Sound

    def initialize(@gpu : GpuContext)
    end

    # Texture chargée depuis un fichier (PNG/JPG…), mise en cache par chemin.
    def texture(path : String) : Texture
      @textures[path] ||= Texture.load(@gpu, path)
    end

    # Police, mise en cache par (chemin, taille).
    def font(path : String, size : Number) : Font
      @fonts[{path, size.to_f32}] ||= Font.load(path, size)
    end

    # Son WAV, mis en cache par chemin.
    def sound(path : String) : Sound
      @sounds[path] ||= Sound.load(path)
    end

    # Enregistre une texture déjà créée (ex. rendu de texte) sous une clé, pour la
    # réutiliser et la libérer avec les autres.
    def store_texture(key : String, texture : Texture) : Texture
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

  # Insère la ressource Assets au startup (à partir du GpuContext).
  class AssetsPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        world.insert_resource(Assets.new(world.resource(GpuContext)))
      end
    end
  end
end
