module Flock
  # Immediate-mode debug drawing: call `line`/`rect`/`circle`/… each frame from any system; the
  # renderer draws them (as thin quads) on top of the scene, and `GizmosPlugin` clears them at
  # end of frame. World-space, 2D. Native only (a debug tool). No persistence — re-issue every
  # frame while you want them visible.
  #
  #   world.resource(Flock::Gizmos).circle(pos, 20, Flock::Color::RED)
  class Gizmos < Resource
    record Line, a : Vec2, b : Vec2, color : Color, thickness : Float32
    getter lines : Array(Line) = [] of Line
    property default_thickness : Float32 = 2.0f32

    def line(a : Vec2, b : Vec2, color : Color = Color::WHITE, thickness : Number = @default_thickness) : Nil
      @lines << Line.new(a, b, color, thickness.to_f32)
    end

    # A ray from `origin` along `dir` (its length).
    def ray(origin : Vec2, dir : Vec2, color : Color = Color::WHITE, thickness : Number = @default_thickness) : Nil
      line(origin, Vec2.new(origin.x + dir.x, origin.y + dir.y), color, thickness)
    end

    # Axis-aligned rectangle outline (4 edges) centered at `center`.
    def rect(center : Vec2, size : Vec2, color : Color = Color::WHITE, thickness : Number = @default_thickness) : Nil
      hx = size.x * 0.5f32
      hy = size.y * 0.5f32
      tl = Vec2.new(center.x - hx, center.y + hy)
      tr = Vec2.new(center.x + hx, center.y + hy)
      br = Vec2.new(center.x + hx, center.y - hy)
      bl = Vec2.new(center.x - hx, center.y - hy)
      line(tl, tr, color, thickness); line(tr, br, color, thickness)
      line(br, bl, color, thickness); line(bl, tl, color, thickness)
    end

    # Circle outline (a `segments`-gon).
    def circle(center : Vec2, radius : Number, color : Color = Color::WHITE,
               segments : Int32 = 24, thickness : Number = @default_thickness) : Nil
      r = radius.to_f32
      prev = Vec2.new(center.x + r, center.y)
      (1..segments).each do |i|
        t = (i.to_f32 / segments) * (Math::PI.to_f32 * 2.0f32)
        cur = Vec2.new(center.x + Math.cos(t) * r, center.y + Math.sin(t) * r)
        line(prev, cur, color, thickness)
        prev = cur
      end
    end

    # A small "+" cross at `p` (marks a point).
    def cross(p : Vec2, size : Number = 6.0, color : Color = Color::WHITE, thickness : Number = @default_thickness) : Nil
      h = size.to_f32 * 0.5f32
      line(Vec2.new(p.x - h, p.y), Vec2.new(p.x + h, p.y), color, thickness)
      line(Vec2.new(p.x, p.y - h), Vec2.new(p.x, p.y + h), color, thickness)
    end

    def clear : Nil
      @lines.clear
    end
  end

  # Inserts the `Gizmos` resource and clears it each frame (after Render, so a frame's gizmos
  # are drawn then reset — immediate mode). Add after a render plugin.
  class GizmosPlugin < Plugin
    def build(app : App) : Nil
      app.world.insert_resource(Gizmos.new)
      app.add_system(Flock::Schedule::Last) { |world, _cmd| world.resource?(Gizmos).try &.clear }
    end
  end
end
