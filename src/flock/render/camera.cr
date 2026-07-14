module Flock
  # Sous-région d'écran où rend une caméra, en pixels (nil = plein framebuffer).
  struct Viewport
    property x : Float32
    property y : Float32
    property width : Float32
    property height : Float32

    def initialize(@x : Float32, @y : Float32, @width : Float32, @height : Float32)
    end
  end

  # Caméra 2D orthographique. `position` est le point du monde au centre de la vue,
  # `zoom` > 1 rapproche, `rotation` en radians. Espace monde en pixels par défaut
  # (1 unité = 1 pixel à zoom 1).
  struct Camera2D
    include Component
    property position : Vec2
    property zoom : Float32
    property rotation : Float32
    property viewport : Viewport?
    property order : Int32
    property clear_color : Color?
    property active : Bool

    def initialize(@position : Vec2 = Vec2.new, @zoom : Float32 = 1.0f32,
                   @rotation : Float32 = 0.0f32, @viewport : Viewport? = nil,
                   @order : Int32 = 0, @clear_color : Color? = Color::BLACK,
                   @active : Bool = true)
    end

    # Matrice view-projection pour une cible de dimensions (w, h) en pixels.
    def view_projection(w : Float32, h : Float32) : Mat4
      hw = (w * 0.5f32) / @zoom
      hh = (h * 0.5f32) / @zoom
      proj = Mat4.orthographic(-hw, hw, -hh, hh, -1.0, 1.0)
      view = Mat4.rotation_z(-@rotation) * Mat4.translation(Vec3.new(-@position.x, -@position.y, 0))
      proj * view
    end
  end

  # Caméra 3D perspective. Fournie pour l'abstraction ; le rendu de meshes 3D qui
  # la consomme arrive dans une phase ultérieure.
  struct Camera3D
    include Component
    property position : Vec3
    property target : Vec3
    property up : Vec3
    property fov_y : Float32
    property near : Float32
    property far : Float32
    property viewport : Viewport?
    property order : Int32
    property clear_color : Color?
    property active : Bool

    def initialize(@position : Vec3 = Vec3.new(0, 0, 5), @target : Vec3 = Vec3.new,
                   @up : Vec3 = Vec3.new(0, 1, 0), @fov_y : Float32 = 1.0f32,
                   @near : Float32 = 0.1f32, @far : Float32 = 1000.0f32,
                   @viewport : Viewport? = nil, @order : Int32 = 0,
                   @clear_color : Color? = Color::BLACK, @active : Bool = true)
    end

    def view_projection(aspect : Float32) : Mat4
      proj = Mat4.perspective(@fov_y, aspect, @near, @far)
      view = Mat4.look_at(@position, @target, @up)
      proj * view
    end
  end
end
