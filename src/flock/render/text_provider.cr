module Flock
  # Portable text→texture facade: `world.resource(Flock::Text).texture(str, px)` returns a
  # Renderer2D texture-bank id for a Sprite2D. Same API as the web backend's `Flock::Text`,
  # so game code is identical on both targets. Cached by (px, string).
  #
  # Native rasterizes with SDL_ttf (a default system font; set `font_path` to change it).
  class Text < Resource
    property font_path : String
    @cache : Hash(Tuple(Int32, String), Tuple(Int32, Float32, Float32)) = {} of Tuple(Int32, String) => Tuple(Int32, Float32, Float32)

    def initialize(@gpu : GpuContext, @renderer : Renderer2D, @assets : Assets,
                   @font_path : String = "/System/Library/Fonts/Supplemental/Arial.ttf")
    end

    def texture(str : String, px : Number = 24) : Int32
      measure(str, px)[0]
    end

    # Rasterizes + measures: returns {texture-bank id, width px, height px}. Cached.
    def measure(str : String, px : Number = 24) : Tuple(Int32, Float32, Float32)
      key = {px.to_i, str}
      cached = @cache[key]?
      return cached if cached
      res = begin
        tex = @assets.font(@font_path, px.to_i).render_texture(@gpu, str)
        {@renderer.register_texture(tex), tex.width.to_f32, tex.height.to_f32}
      rescue
        {0, (str.size.to_f32 * px.to_f32 * 0.5f32), px.to_f32} # font unavailable
      end
      @cache[key] = res
      res
    end
  end

  # Inserts the Text resource once the GPU/Renderer2D/Assets resources exist.
  class TextPlugin < Plugin
    def build(app : App) : Nil
      app.add_startup do |world, _cmd|
        world.insert_resource(Text.new(world.resource(GpuContext), world.resource(Renderer2D), world.resource(Assets)))
      end
    end
  end
end
