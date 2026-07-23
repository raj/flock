module Flock
  # Portable text→texture facade: `world.resource(Flock::Text).texture(str, px)` returns a
  # Renderer2D texture-bank id for a Sprite2D. Same API as the web backend's `Flock::Text`,
  # so game code is identical on both targets. Cached by (px, string).
  #
  # Native rasterizes with SDL_ttf (a default system font; set `font_path` to change it).
  class Text < Resource
    property font_path : String
    @cache : Hash(Tuple(Int32, String), Int32) = {} of Tuple(Int32, String) => Int32

    def initialize(@gpu : GpuContext, @renderer : Renderer2D, @assets : Assets,
                   @font_path : String = "/System/Library/Fonts/Supplemental/Arial.ttf")
    end

    def texture(str : String, px : Number = 24) : Int32
      key = {px.to_i, str}
      cached = @cache[key]?
      return cached if cached
      id = begin
        @renderer.register_texture(@assets.font(@font_path, px.to_i).render_texture(@gpu, str))
      rescue
        0 # font unavailable → solid white
      end
      @cache[key] = id
      id
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
