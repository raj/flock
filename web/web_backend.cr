# WebPlugins — a browser backend for Flock, paralleling the native DefaultPlugins.
# Reuses Flock's native-free core (App / Plugin / Schedule / World / Time) and wires up
# browser equivalents: 2D sprite components (solid or textured), a keyboard+gamepad Input
# resource, WebGPU rendering (renderer.js), text-as-texture and WebAudio — all via
# crystal-js interop. The frame loop is driven from JS (requestAnimationFrame).
require "js"
require "../src/flock"

module Flock::Web
  extend self
  include ::JS::ExpandMethods # enables @[JS::Method] bodies

  MAX = 512 # max sprites per frame

  struct Transform2D
    include Flock::Component
    property position : Flock::Vec2

    def initialize(@position : Flock::Vec2 = Flock::Vec2.new)
    end
  end

  # A sprite: `color` tints, `texture` (a JS renderer texture id; 0 = solid white).
  struct Sprite
    include Flock::Component
    property size : Flock::Vec2
    property color : Flock::Vec3
    property texture : Int32

    def initialize(@size : Flock::Vec2, @color : Flock::Vec3, @texture : Int32 = 0)
    end
  end

  # Keyboard (DOM keyCodes) + gamepad (left stick + buttons, polled from JS each frame).
  ARROW_LEFT  = 37
  ARROW_UP    = 38
  ARROW_RIGHT = 39
  ARROW_DOWN  = 40
  SPACE       = 32

  class Input < Flock::Resource
    KEYS = 256
    @down = Array(Bool).new(KEYS, false)
    getter gamepad_x : Float32 = 0.0f32
    getter gamepad_y : Float32 = 0.0f32
    getter? gamepad_connected : Bool = false
    @buttons : UInt32 = 0_u32

    def set(code : Int32, down : Bool) : Nil
      @down[code] = down if 0 <= code < KEYS
    end

    def pressed?(code : Int32) : Bool
      (0 <= code < KEYS) && @down[code]
    end

    # Called from JS with the left-stick axes (×1000) + a button bitmask.
    def set_gamepad(ax : Int32, ay : Int32, buttons : Int32, connected : Bool) : Nil
      @gamepad_x = ax / 1000.0f32
      @gamepad_y = ay / 1000.0f32
      @buttons = buttons.to_u32
      @gamepad_connected = connected
    end

    def gamepad_button?(index : Int32) : Bool
      (@buttons & (1_u32 << index)) != 0
    end
  end

  BUFFER = Slice(Float32).new(MAX * 8)  # per instance: x,y,w,h, r,g,b,a
  GROUPS = Slice(Int32).new(128)        # draw groups: [textureId, count] pairs (sorted by texture)

  # --- JS bridges (WebGPU renderer / text / audio live in renderer.js) ---

  # Hands the grouped instance buffer to the WebGPU renderer.
  @[JS::Method]
  def draw(ptr : Int32, count : Int32, groups_ptr : Int32, group_pairs : Int32) : Nil
    <<-JS
      if (__memory.buffer.byteLength === 0) __memory = new DataView(__exports.memory.buffer);
      const f = new Float32Array(__exports.memory.buffer, #{ptr}, #{count} * 8);
      const g = new Int32Array(__exports.memory.buffer, #{groups_ptr}, #{group_pairs} * 2);
      if (globalThis.__flockDraw) globalThis.__flockDraw(f, #{count}, g);
    JS
  end

  # Rasterizes `text` to a texture (canvas 2D) and returns its renderer texture id.
  @[JS::Method]
  def make_text(text : String) : Int32
    <<-JS
      return (globalThis.__flockMakeText ? globalThis.__flockMakeText(#{text}) : 0) | 0;
    JS
  end

  # Registers a procedural checkerboard texture and returns its id.
  @[JS::Method]
  def checkerboard : Int32
    <<-JS
      return (globalThis.__flockCheckerboard ? globalThis.__flockCheckerboard() : 0) | 0;
    JS
  end

  # Plays a short beep via WebAudio (must follow a user gesture per autoplay policy).
  @[JS::Method]
  def beep(freq : Int32, ms : Int32) : Nil
    <<-JS
      if (globalThis.__flockBeep) globalThis.__flockBeep(#{freq}, #{ms});
    JS
  end

  # Inserts Input and registers the render system (groups sprites by texture).
  class WebPlugins < Flock::Plugin
    def build(app : Flock::App) : Nil
      app.world.insert_resource(Input.new)
      app.add_system(Flock::Schedule::Render) do |world, _cmd|
        # Collect {texture, x,y,w,h,r,g,b,a}, then order by texture for batched draws.
        items = [] of Tuple(Int32, Float32, Float32, Float32, Float32, Float32, Float32, Float32)
        world.query(Transform2D, Sprite) do |_e, tf, sp|
          next if items.size >= MAX
          p = tf.value.position; s = sp.value.size; c = sp.value.color
          items << {sp.value.texture, p.x, p.y, s.x, s.y, c.x, c.y, c.z}
        end
        items.sort_by! &.[0]

        pairs = 0
        cur_tex = -1
        cur_count = 0
        items.each_with_index do |it, i|
          o = i * 8
          BUFFER[o] = it[1]; BUFFER[o + 1] = it[2]; BUFFER[o + 2] = it[3]; BUFFER[o + 3] = it[4]
          BUFFER[o + 4] = it[5]; BUFFER[o + 5] = it[6]; BUFFER[o + 6] = it[7]; BUFFER[o + 7] = 1.0f32
          if it[0] != cur_tex
            if cur_tex >= 0
              GROUPS[pairs * 2] = cur_tex; GROUPS[pairs * 2 + 1] = cur_count; pairs += 1
            end
            cur_tex = it[0]; cur_count = 0
          end
          cur_count += 1
        end
        if cur_tex >= 0 && pairs < 64
          GROUPS[pairs * 2] = cur_tex; GROUPS[pairs * 2 + 1] = cur_count; pairs += 1
        end

        Flock::Web.draw(BUFFER.to_unsafe.address.to_i64!.to_i32!, items.size,
          GROUPS.to_unsafe.address.to_i64!.to_i32!, pairs)
      end
    end
  end

  @@app : Flock::App? = nil

  def launch(app : Flock::App) : Nil
    @@app = app
  end

  def app : Flock::App
    @@app.not_nil!
  end
end

# --- Exports called from renderer.js ---

JS.export def flock_init : Int32
  Flock::Web.app.startup
  0
end

JS.export def flock_frame(dt_ms : Int32) : Int32
  Flock::Web.app.update
  0
end

JS.export def flock_key(code : Int32, down : Int32) : Int32
  Flock::Web.app.world.resource(Flock::Web::Input).set(code, down != 0)
  0
end

JS.export def flock_gamepad(ax : Int32, ay : Int32, buttons : Int32, connected : Int32) : Int32
  Flock::Web.app.world.resource(Flock::Web::Input).set_gamepad(ax, ay, buttons, connected != 0)
  0
end
