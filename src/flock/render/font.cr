module Flock
  # Police TrueType (via SDL3_ttf). Rend une chaîne en une `Texture` RGBA que l'on
  # dessine comme un `Sprite` (taille = dimensions de la texture).
  #
  #   font = Flock::Font.load("/System/Library/Fonts/Supplemental/Arial.ttf", 48)
  #   tex  = font.render_texture(gpu, "Score : 42")
  #   cmd.spawn(Flock::Transform2D.at(0, 0),
  #             Flock::Sprite.new(Flock::Vec2.new(tex.width, tex.height), Flock::Color::WHITE, tex))
  #
  # Le texte est rendu en blanc : la teinte du sprite le colore (texture × teinte).
  # `render_texture` alloue une texture GPU par appel — mettre en cache pour du texte
  # qui change souvent, et libérer via `Texture#release`.
  class Font
    @@initialized = false

    def initialize(@handle : LibSDL::Font)
    end

    def self.load(path : String, size : Number) : Font
      ensure_init
      handle = LibSDL.ttf_open_font(path.to_unsafe, size.to_f32)
      raise "TTF_OpenFont #{path}: #{String.new(LibSDL.get_error)}" if handle.null?
      new(handle)
    end

    private def self.ensure_init
      return if @@initialized
      raise "TTF_Init: #{String.new(LibSDL.get_error)}" unless LibSDL.ttf_init
      @@initialized = true
    end

    # Rend `text` (blanc par défaut) en une texture RGBA à teinter via le sprite.
    def render_texture(gpu : GpuContext, text : String, color : Color = Color::WHITE) : Texture
      fg = LibSDL::Color.new(
        r: to_u8(color.r), g: to_u8(color.g), b: to_u8(color.b), a: to_u8(color.a))
      surf = LibSDL.ttf_render_text_blended(@handle, text.to_unsafe, text.bytesize.to_u64, fg)
      raise "TTF_RenderText_Blended: #{String.new(LibSDL.get_error)}" if surf.null?
      tex = Texture.from_surface(gpu, surf)
      LibSDL.destroy_surface(surf)
      tex
    end

    def release : Nil
      LibSDL.ttf_close_font(@handle)
    end

    private def to_u8(v : Float32) : UInt8
      (v.clamp(0.0f32, 1.0f32) * 255).to_u8
    end
  end
end
