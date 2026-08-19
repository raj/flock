module Flock
  # A glyph atlas: printable ASCII + Latin-1 supplement glyphs are rasterized ONCE (via
  # SDL3_ttf) into a single texture, with per-glyph UV + metrics. Text is then drawn as
  # batched quads that sample the atlas (one texture, arbitrary/changing strings — no
  # per-string GPU texture). Chars outside the pre-rasterized set are skipped with a
  # one-time warning (see `warn_missing`).
  #
  #   atlas = world.resource(Assets).glyph_atlas(gpu, "/…/Arial.ttf", 32)
  #   size  = atlas.measure("Score: 42")        # {w, h} in pixels
  #   atlas.each_quad("Score: 42", 0, 0) do |x, y, w, h, u, v, uw, uh|
  #     # x,y = glyph top-left (y-down); u,v,uw,uh = atlas sub-rect (0..1)
  #   end
  #
  # See `TextLabel` for a ready-made ECS component that renders + caches dynamic text.
  class GlyphAtlas
    struct Glyph
      property u : Float32 = 0.0f32
      property v : Float32 = 0.0f32
      property uw : Float32 = 0.0f32
      property uh : Float32 = 0.0f32
      property w : Float32 = 0.0f32 # ink size (px)
      property h : Float32 = 0.0f32
      property advance : Float32 = 0.0f32 # pen advance (px)
      property minx : Float32 = 0.0f32    # left bearing
      property top : Float32 = 0.0f32     # y offset from the line top to the ink top

      def initialize
      end
    end

    getter texture : Texture
    getter px : Float32
    getter line_height : Float32
    getter ascent : Float32
    # Renderer2D texture-bank id (set by Assets after registration); 0 until registered.
    property tex_id : Int32 = 0

    ATLAS_W = 512

    def initialize(gpu : GpuContext, path : String, size : Number)
      @px = size.to_f32
      Font.ensure_init
      font = LibSDL.ttf_open_font(path.to_unsafe, @px)
      raise "TTF_OpenFont #{path}: #{String.new(LibSDL.get_error)}" if font.null?
      white = LibSDL::Color.new(r: 255_u8, g: 255_u8, b: 255_u8, a: 255_u8)

      # Pass 1: metrics + ink bitmap for each supported char: printable ASCII plus the
      # Latin-1 supplement (accented Latin letters, «», °, µ, €…). C0 controls (127-159)
      # are skipped; anything beyond renders as blank and falls to the missing-glyph path.
      records = [] of {Char, Int32, Int32, Int32, Int32, Int32, Bytes?} # c, minx, maxy, advance, w, h, pixels
      ascent = 0
      descent = 0
      ((32..126).each.to_a + (160..255).each.to_a).each do |code|
        c = code.chr
        LibSDL.ttf_get_glyph_metrics(font, code.to_u32, out minx, out _maxx, out miny, out maxy, out adv)
        ascent = maxy if maxy > ascent
        descent = miny if miny < descent
        s = c.to_s
        surf = LibSDL.ttf_render_text_blended(font, s.to_unsafe, s.bytesize.to_u64, white)
        if surf.null?
          records << {c, minx, maxy, adv, 0, 0, nil}
        else
          conv = LibSDL.convert_surface(surf, LibSDL::PIXELFORMAT_RGBA32)
          LibSDL.destroy_surface(surf)
          sv = conv.value
          w = sv.w; h = sv.h; pitch = sv.pitch
          src = sv.pixels.as(UInt8*)
          buf = Bytes.new(w * h * 4)
          h.times { |r| (buf.to_unsafe + r * w * 4).copy_from(src + r * pitch, w * 4) }
          LibSDL.destroy_surface(conv)
          records << {c, minx, maxy, adv, w, h, buf}
        end
      end
      LibSDL.ttf_close_font(font)

      @line_height = (ascent - descent).to_f32
      @ascent = ascent.to_f32

      # Pack (shelf) to compute positions + atlas height.
      pos = {} of Char => Tuple(Int32, Int32)
      x = 1; y = 1; row_h = 0
      records.each do |(c, _minx, _maxy, _adv, w, h, _px)|
        next if w <= 0
        if x + w + 1 > ATLAS_W
          y += row_h + 1; x = 1; row_h = 0
        end
        pos[c] = {x, y}
        x += w + 1
        row_h = h if h > row_h
      end
      atlas_h = y + row_h + 1

      # Blit ink into the atlas buffer (zero-initialized = transparent) + fill glyph table.
      atlas = Bytes.new(ATLAS_W * atlas_h * 4)
      @glyphs = {} of Char => Glyph
      records.each do |(c, minx, maxy, adv, w, h, buf)|
        g = Glyph.new
        g.advance = adv.to_f32
        g.minx = minx.to_f32
        g.w = w.to_f32
        g.h = h.to_f32
        g.top = (ascent - maxy).to_f32
        if (b = buf) && w > 0
          gx, gy = pos[c]
          h.times do |r|
            (atlas.to_unsafe + ((gy + r) * ATLAS_W + gx) * 4).copy_from(b.to_unsafe + r * w * 4, w * 4)
          end
          g.u = gx.to_f32 / ATLAS_W
          g.v = gy.to_f32 / atlas_h
          g.uw = w.to_f32 / ATLAS_W
          g.uh = h.to_f32 / atlas_h
        end
        @glyphs[c] = g
      end

      @texture = Texture.from_pixels(gpu, ATLAS_W, atlas_h, atlas,
        SamplerFilter::Linear, SamplerWrap::Clamp, false, false)
    end

    def glyph(c : Char) : Glyph?
      @glyphs[c]?
    end

    # Notifies (once per char) that `c` has no atlas entry — the char will be silently
    # skipped at render time. Loud feedback instead of invisible text truncation.
    private def warn_missing(c : Char) : Nil
      @warned ||= Set(Char).new
      return if @warned.includes?(c)
      @warned << c
      STDERR.puts "[flock] GlyphAtlas: no glyph for #{c.inspect} (0x#{c.ord.to_s(16)}) — char skipped in measure/render"
    end

    # Pixel size of `text` (handles `\n`).
    def measure(text : String) : Tuple(Float32, Float32)
      w = 0.0f32
      maxw = 0.0f32
      lines = 1
      text.each_char do |c|
        if c == '\n'
          maxw = Math.max(maxw, w); w = 0.0f32; lines += 1
        elsif g = @glyphs[c]?
          w += g.advance
        else
          warn_missing(c)
        end
      end
      {Math.max(maxw, w), @line_height * lines}
    end

    # Yields a quad per visible glyph: (x, y top-left, w, h, u, v, uw, uh). y grows DOWN.
    def each_quad(text : String, ox : Float32, oy : Float32, & : Float32, Float32, Float32, Float32, Float32, Float32, Float32, Float32 ->) : Nil
      pen = ox
      line = 0
      text.each_char do |c|
        if c == '\n'
          pen = ox; line += 1; next
        end
        g = @glyphs[c]?
        if g.nil?
          warn_missing(c)
          next
        end
        if g.w > 0
          yield pen + g.minx, oy + line * @line_height + g.top, g.w, g.h, g.u, g.v, g.uw, g.uh
        end
        pen += g.advance
      end
    end
  end
end
