module Flock
  # One quad within a `SpriteBatch`: position (center, in the batch entity's space), size, tint
  # and atlas UV sub-rect. No per-item rotation (batches are for axis-aligned quads — tiles,
  # particles, glyph runs).
  struct BatchItem
    property pos : Vec2
    property size : Vec2
    property color : Color
    property uv_min : Vec2
    property uv_size : Vec2

    def initialize(@pos : Vec2, @size : Vec2, @color : Color = Color::WHITE,
                   @uv_min : Vec2 = Vec2.new(0, 0), @uv_size : Vec2 = Vec2.new(1, 1))
    end
  end

  # A batch of many quads sharing ONE texture + material, drawn from a SINGLE entity as one
  # instanced draw call — instead of spawning an entity per quad. Use for tilemap layers,
  # particle systems, or bitmap-text runs where thousands of quads share a sheet. The
  # renderer (native + web) expands its `items` into instances; the entity's `Transform2D`
  # offsets the whole batch. Backend-agnostic (`texture` is a bank id, like `Sprite2D`).
  struct SpriteBatch
    include Component
    property items : Array(BatchItem)
    property texture : Int32  # texture-bank id (0 = white)
    property material : Int32 # custom-material id (0 = default sprite shader)
    property z : Float32

    def initialize(@items : Array(BatchItem) = [] of BatchItem, @texture : Int32 = 0,
                   @material : Int32 = 0, @z : Float32 = 0.0f32)
    end
  end
end
