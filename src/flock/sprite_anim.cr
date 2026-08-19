module Flock
  # A regular grid of frames on a spritesheet texture: `uv(i)` gives the sub-rect (uv_min,
  # uv_size) of frame `i` (row-major, 0-based). Backend-agnostic (just UV math).
  struct SpriteSheet
    property cols : Int32
    property rows : Int32

    def initialize(@cols : Int32, @rows : Int32 = 1)
      raise "SpriteSheet needs cols > 0 and rows > 0 (got #{@cols}x#{@rows})" if @cols <= 0 || @rows <= 0
    end

    def count : Int32
      @cols * @rows
    end

    # UV sub-rect of frame `i` (wraps if out of range).
    def uv(i : Int32) : Tuple(Vec2, Vec2)
      i = i % count if count > 0
      c = i % @cols
      r = i // @cols
      {Vec2.new(c.to_f32 / @cols, r.to_f32 / @rows),
       Vec2.new(1.0f32 / @cols, 1.0f32 / @rows)}
    end
  end

  # Frame-based sprite-sheet animation (core, portable — not tied to Aseprite). Plays a list of
  # `frames` (indices into `sheet`) at `fps`, looping / ping-ponging / once. The
  # `SpriteAnimationPlugin` system advances it each frame and writes the current frame's UV to
  # the entity's `Sprite2D` (so it works identically on native + web).
  #
  #   sheet = Flock::SpriteSheet.new(cols: 8, rows: 1)
  #   cmd.spawn(Flock::Transform2D.at(x, y),
  #     Flock::Sprite2D.new(size, tex: run_texture),
  #     Flock::SpriteAnimation.new(sheet, (0..7).to_a, fps: 12))
  struct SpriteAnimation
    include Component
    property sheet : SpriteSheet
    property frames : Array(Int32)
    property fps : Float32
    property loops : Bool     # restart at the end (ignored by ping_pong)
    property ping_pong : Bool # bounce back and forth
    property playing : Bool
    property cursor : Int32 # index INTO `frames`
    property timer : Float32
    property forward : Bool # ping-pong sweep direction

    def initialize(@sheet : SpriteSheet, @frames : Array(Int32), fps : Number = 12,
                   @loops : Bool = true, @ping_pong : Bool = false, @playing : Bool = true)
      @fps = fps.to_f32
      @cursor = 0
      @timer = 0.0f32
      @forward = true
    end

    # The sheet-frame index currently shown.
    def current : Int32
      @frames[@cursor]? || 0
    end

    # Current frame's UV sub-rect (from the sheet).
    def uv : Tuple(Vec2, Vec2)
      @sheet.uv(current)
    end

    # Advances by `dt` seconds, stepping across as many frames as elapsed.
    def step(dt : Float32) : Nil
      return unless @playing && @fps > 0.0f32 && @frames.size > 1
      spf = 1.0f32 / @fps
      @timer += dt
      while @timer >= spf
        @timer -= spf
        advance
      end
    end

    private def advance : Nil
      last = @frames.size - 1
      if @ping_pong
        if @forward
          @cursor >= last ? (@cursor = last - 1; @forward = false) : (@cursor += 1)
        else
          @cursor <= 0 ? (@cursor = 1; @forward = true) : (@cursor -= 1)
        end
      elsif @cursor >= last
        if @loops
          @cursor = 0
        else
          @cursor = last
          @playing = false
        end
      else
        @cursor += 1
      end
    end
  end

  # Advances every `SpriteAnimation` and writes the current frame's UV to its `Sprite2D`.
  class SpriteAnimationPlugin < Plugin
    def build(app : App) : Nil
      app.add_system(Flock::Schedule::Update) do |world, _cmd|
        dt = world.resource(Time).delta.to_f32
        world.query(SpriteAnimation, Sprite2D) do |_e, an, sp|
          a = an.value
          a.step(dt)
          u = a.uv
          s = sp.value
          s.uv_min = u[0]
          s.uv_size = u[1]
          sp.value = s
          an.value = a
        end
      end
    end
  end
end
