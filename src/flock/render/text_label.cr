module Flock
  # An ECS text label backed by a GlyphAtlas: draws its string as batched glyph quads
  # (child Sprite2D entities), rebuilt ONLY when the text changes (via change detection),
  # so dynamic text is cheap and never allocates a per-string GPU texture.
  #
  #   atlas = world.resource(Assets).glyph_atlas(gpu, FONT, 32)
  #   cmd.spawn(Flock::Transform2D.at(0, 200), Flock::TextLabel.new(atlas, "Score: 0"))
  #
  # To change it, write the field and flag the change:
  #   world.query(Flock::TextLabel) do |e, tl|
  #     t = tl.value; t.text = "Score: #{score}"; tl.value = t
  #     world.mark_changed(e, Flock::TextLabel)
  #   end
  #
  # The label's `Transform2D` is the top-left origin (native world; text flows down/right).
  struct TextLabel
    include Component
    property atlas : GlyphAtlas
    property text : String
    property color : Color
    property z : Float32
    # Spawned glyph child entities (managed by TextLabelPlugin; despawned on rebuild).
    property glyphs : Array(Entity)

    def initialize(@atlas : GlyphAtlas, @text : String, @color : Color = Color::WHITE, @z : Float32 = 5.0f32)
      @glyphs = [] of Entity
    end
  end

  # Rebuilds each TextLabel's glyph sprites when it is added or its text changes.
  class TextLabelPlugin < Plugin
    def build(app : App) : Nil
      app.add_system(Schedule::Update) do |world, cmd|
        renderer = world.resource(Renderer2D)
        world.query(TextLabel, Transform2D) do |e, tl, tf|
          next unless world.added?(e, TextLabel) || world.changed?(e, TextLabel)
          label = tl.value

          # Register the atlas texture in the renderer bank once.
          label.atlas.tex_id = renderer.register_texture(label.atlas.texture) if label.atlas.tex_id == 0

          label.glyphs.each { |ge| cmd.despawn(ge) }
          label.glyphs.clear

          origin = tf.value.position
          label.atlas.each_quad(label.text, 0.0f32, 0.0f32) do |x, y, w, h, u, v, uw, uh|
            # Glyph top-left (y-down) → native Sprite2D (center anchor, y-up).
            cx = origin.x + x + w * 0.5f32
            cy = origin.y - (y + h * 0.5f32)
            ge = cmd.spawn(
              Transform2D.at(cx, cy),
              Sprite2D.new(Vec2.new(w, h), label.color, label.atlas.tex_id,
                uv_min: Vec2.new(u, v), uv_size: Vec2.new(uw, uh), z: label.z))
            label.glyphs << ge
          end
        end
      end
    end
  end
end
