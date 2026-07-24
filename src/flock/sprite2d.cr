module Flock
  # An axis-aligned clip rectangle in WORLD space (same space as `Transform2D` positions).
  # A `Sprite2D` carrying one is scissor-clipped to it: only the part of the quad inside the
  # rect is drawn. Both renderers convert it to framebuffer pixels via the active `Camera2D`.
  # Used by flock-ui scroll views to clip children to their container.
  struct ClipRect
    include JSON::Serializable
    property min : Vec2
    property max : Vec2

    def initialize(@min : Vec2, @max : Vec2)
    end

    # From a bottom-left origin + size (world units).
    def self.xywh(x : Float32, y : Float32, w : Float32, h : Float32) : ClipRect
      new(Vec2.new(x, y), Vec2.new(x + w, y + h))
    end
  end

  # Backend-agnostic 2D sprite: a tinted textured quad whose `texture` is an integer
  # asset id (0 = solid white), resolved by whichever renderer draws it — the native
  # Renderer2D (id → GPU Texture via its texture bank) or the web backend (id → WebGPU
  # texture). This lets the same game source (spawning `Sprite2D` + `Transform2D`) run on
  # both targets. `uv_min`/`uv_size` select an atlas sub-rect; `z` is the draw order.
  struct Sprite2D
    include Component
    include JSON::Serializable
    property size : Vec2
    property color : Color
    property texture : Int32
    property uv_min : Vec2
    property uv_size : Vec2
    property z : Float32
    # Custom-material id (0 = the renderer's default sprite shader). Resolved per
    # backend: native → Renderer2D#register_material bank; web → a renderer.js pipeline
    # from Flock::Web.register_material. Lets one Sprite2D carry a custom fragment shader
    # on both targets (WebGL2 falls back to the default shader).
    property material : Int32
    # Optional world-space scissor rect. When set, the sprite is clipped to it (both
    # backends). nil = no clipping (drawn in full).
    property clip : ClipRect?

    def initialize(@size : Vec2, @color : Color = Color::WHITE, @texture : Int32 = 0,
                   @uv_min : Vec2 = Vec2.new(0, 0), @uv_size : Vec2 = Vec2.new(1, 1),
                   @z : Float32 = 0.0f32, @material : Int32 = 0, @clip : ClipRect? = nil)
    end
  end
end
