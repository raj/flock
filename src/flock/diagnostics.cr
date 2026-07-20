module Flock
  # Drop-in performance/scene monitor. Collected into a resource every frame, so any project can
  # read the numbers directly (`world.resource(Flock::Diagnostics)`) to build its own HUD, and/or
  # let `DiagnosticsPlugin` print them to the console or draw a small on-screen overlay.
  #
  # What is measured (all reliable regardless of the project):
  #   * fps + frame time (min / avg / max over a rolling window)
  #   * sprite count (Sprite + Sprite2D)
  #   * 3D mesh instances in the scene + their triangle total
  #   * 2D draw calls, and 3D instances drawn / frustum-culled (from the renderers' own counters)
  #
  # Not measured: true CPU/GPU utilisation percentages. A real GPU timer needs the wgpu
  # TimestampQuery feature requested at device-creation time (before any plugin runs), and a
  # portable OS CPU% isn't available; with vsync (Fifo) a "% of frame budget" would sit near 100%
  # and mislead. The frame-time min/avg/max window is the honest performance signal instead.
  class Diagnostics < Resource
    # Rolling-window results (recomputed every `window` seconds).
    getter fps : Float64 = 0.0
    getter frame_ms_avg : Float64 = 0.0
    getter frame_ms_min : Float64 = 0.0
    getter frame_ms_max : Float64 = 0.0

    # Per-frame scene stats.
    getter sprites : Int32 = 0
    getter mesh_instances : Int32 = 0
    getter triangles : Int64 = 0_i64
    getter draw_calls_2d : Int32 = 0
    getter drawn_3d : Int32 = 0
    getter culled_3d : Int32 = 0

    @accum_time : Float64 = 0.0
    @accum_frames : Int32 = 0
    @min : Float64 = Float64::INFINITY
    @max : Float64 = 0.0

    def initialize(@window : Float64 = 0.5)
    end

    # Samples one frame. Returns true when the rolling window just rolled over (a fresh
    # fps/frame-time result is available) — used to pace console output.
    def sample(world : World) : Bool
      dt = world.resource(Time).delta
      ms = dt * 1000.0
      @accum_time += dt
      @accum_frames += 1
      @min = ms if ms < @min
      @max = ms if ms > @max

      count_scene(world)

      if @accum_time >= @window && @accum_frames > 0
        @frame_ms_avg = (@accum_time / @accum_frames) * 1000.0
        @fps = @accum_frames / @accum_time
        @frame_ms_min = @min == Float64::INFINITY ? 0.0 : @min
        @frame_ms_max = @max
        @accum_time = 0.0
        @accum_frames = 0
        @min = Float64::INFINITY
        @max = 0.0
        return true
      end
      false
    end

    private def count_scene(world : World) : Nil
      @sprites = world.storage(Sprite).size + world.storage(Sprite2D).size

      meshes = 0
      tris = 0_i64
      world.query(Transform3D, MeshRenderer) do |_e, _tf, mr|
        meshes += 1
        tris += (mr.value.mesh.index_count // 3).to_i64
      end
      # GPU-skinned and morph meshes are their own components (no MeshRenderer), so count them
      # too — otherwise a skinned character (e.g. the fox) contributes zero triangles.
      world.query(GpuSkinnedMesh) do |_e, sk|
        meshes += 1
        tris += (sk.value.mesh.index_count // 3).to_i64
      end
      world.query(GpuMorphMesh) do |_e, mo|
        meshes += 1
        tris += (mo.value.mesh.index_count // 3).to_i64
      end
      @mesh_instances = meshes
      @triangles = tris

      @draw_calls_2d = world.resource?(Renderer2D).try(&.last_draw_calls) || 0
      if r3 = world.resource?(Renderer3D)
        @drawn_3d = r3.last_drawn
        @culled_3d = r3.last_culled
      end
    end

    # A compact one-line report (the 3D section is omitted for a 2D-only scene).
    def summary : String
      String.build do |s|
        s << "FPS #{fps.round(1)}"
        s << "  frame #{frame_ms_avg.round(2)}ms (min #{frame_ms_min.round(2)} / max #{frame_ms_max.round(2)})"
        s << "  sprites #{sprites}"
        s << "  2D-draws #{draw_calls_2d}" if draw_calls_2d > 0
        if mesh_instances > 0
          s << "  meshes #{mesh_instances}  tris #{triangles}"
          s << "  drawn #{drawn_3d}/culled #{culled_3d}" if drawn_3d > 0 || culled_3d > 0
        end
      end
    end
  end

  # Inserts a `Diagnostics` resource and reports it. `console` (default) prints a line every
  # `interval` seconds; `overlay` additionally draws the text on screen (needs a TTF font — pass
  # `font:` or set FLOCK_DIAG_FONT; a few common system fonts are tried otherwise). If the font
  # can't be loaded the overlay is skipped with a warning and the console output still works.
  #
  #   app.add_plugin(Flock::DiagnosticsPlugin.new)                       # console only
  #   app.add_plugin(Flock::DiagnosticsPlugin.new(overlay: true))        # + on-screen overlay
  class DiagnosticsPlugin < Plugin
    def initialize(*, @console : Bool = true, @overlay : Bool = false,
                   @font : String? = nil, @font_size : Int32 = 16,
                   @interval : Float64 = 0.5, @color : Color = Color.new(0.6, 1.0, 0.7))
    end

    def build(app : App) : Nil
      app.world.insert_resource(Diagnostics.new(@interval))

      # Sample after Render so the renderers' per-frame counters are already current.
      console = @console
      app.add_system(Schedule::Last) do |world, _cmd|
        rolled = world.resource(Diagnostics).sample(world)
        puts "[flock] #{world.resource(Diagnostics).summary}" if console && rolled
      end

      setup_overlay(app) if @overlay
    end

    # Common desktop font locations, tried in order when no explicit font is given.
    FONT_CANDIDATES = [
      "/System/Library/Fonts/Supplemental/Arial.ttf",
      "/System/Library/Fonts/SFNSMono.ttf",
      "/Library/Fonts/Arial.ttf",
      "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
      "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    ]

    private def resolve_font : String?
      (path = @font || ENV["FLOCK_DIAG_FONT"]?) && (return path if File.exists?(path))
      FONT_CANDIDATES.find { |p| File.exists?(p) }
    end

    private def setup_overlay(app : App) : Nil
      path = resolve_font
      unless path
        STDERR.puts "[flock] diagnostics overlay: no TTF font found (pass font: or set FLOCK_DIAG_FONT); console only"
        return
      end
      size = @font_size
      color = @color
      app.add_startup do |world, cmd|
        gpu = world.resource(GpuContext)
        begin
          font = Font.load(path, size)
        rescue ex
          STDERR.puts "[flock] diagnostics overlay: could not load font #{path.inspect} (#{ex.message}); console only"
          next
        end
        # A single high-z sprite carries the text; positioned each frame in the top-left corner.
        entity = cmd.spawn(Transform2D.new, Sprite.new(Vec2.new(1, 1), color, z: 10_000.0f32))
        world.insert_resource(Overlay.new(font, entity, color))
      end
      app.add_system(Schedule::Update) do |world, _cmd|
        world.resource?(Overlay).try &.refresh(world)
      end
    end

    # Overlay state: owns the font + the currently displayed text texture, and keeps the
    # single overlay sprite pinned to the top-left corner of the active Camera2D's view.
    class Overlay < Resource
      MARGIN = 8.0f32

      @last_text : String = ""
      @texture : Texture? = nil

      def initialize(@font : Font, @entity : Entity, @color : Color)
      end

      def refresh(world : World) : Nil
        gpu = world.resource(GpuContext)
        text = world.resource(Diagnostics).summary
        if text != @last_text
          @last_text = text
          fresh = @font.render_texture(gpu, text) # white glyphs; the sprite tints them
          @texture.try(&.release)
          @texture = fresh
        end
        tex = @texture
        return unless tex

        # Camera2D is world-space, +Y up, screen-centered; find the active one (default 0,0/zoom 1).
        cam_pos = Vec2.new
        zoom = 1.0f32
        found = false
        world.query(Camera2D) do |_e, cam|
          unless found
            cam_pos = cam.value.position
            zoom = cam.value.zoom
            found = true
          end
        end
        zoom = 1.0f32 if zoom <= 0.0f32

        # Native-pixel size = texture px / zoom; place the (centered) sprite MARGIN from the
        # top-left corner of the visible region.
        tw = tex.width.to_f32 / zoom
        th = tex.height.to_f32 / zoom
        m = MARGIN / zoom
        left = cam_pos.x - (gpu.width.to_f32 / 2.0f32) / zoom
        top = cam_pos.y + (gpu.height.to_f32 / 2.0f32) / zoom
        cx = left + m + tw / 2.0f32
        cy = top - m - th / 2.0f32

        if tp = world.storage(Transform2D).get_ptr(@entity)
          tp.value = Transform2D.new(position: Vec2.new(cx, cy))
        end
        if sp = world.storage(Sprite).get_ptr(@entity)
          s = sp.value
          s.texture = tex
          s.size = Vec2.new(tw, th)
          s.color = @color
          sp.value = s
        end
      end

      def release : Nil
        @texture.try(&.release)
        @font.release
      end
    end
  end
end
