module Flock
  # Backend-agnostic 2D sprite: a tinted textured quad whose `texture` is an integer
  # asset id (0 = solid white), resolved by whichever renderer draws it — the native
  # Renderer2D (id → GPU Texture via its texture bank) or the web backend (id → WebGPU
  # texture). This lets the same game source (spawning `Sprite2D` + `Transform2D`) run on
  # both targets. `uv_min`/`uv_size` select an atlas sub-rect; `z` is the draw order.
  struct Sprite2D
    include Component
    property size : Vec2
    property color : Color
    property texture : Int32
    property uv_min : Vec2
    property uv_size : Vec2
    property z : Float32

    def initialize(@size : Vec2, @color : Color = Color::WHITE, @texture : Int32 = 0,
                   @uv_min : Vec2 = Vec2.new(0, 0), @uv_size : Vec2 = Vec2.new(1, 1),
                   @z : Float32 = 0.0f32)
    end
  end
end
