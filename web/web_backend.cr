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

  # Sprites use the shared, native-free `Flock::Sprite2D` (+ `Flock::Transform2D`), so the
  # same scene source renders on native and web. On web, `Sprite2D#texture` is a renderer
  # texture id from `checkerboard`/`make_text`/`load_image`; on native it's a Renderer2D
  # bank id. `texture = 0` is solid white on both.

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

  FLOATS = 12                            # per instance: x,y,w,h, r,g,b,a, u,v,uw,uh
  BUFFER = Slice(Float32).new(MAX * FLOATS)
  GROUPS = Slice(Int32).new(128)         # draw groups: [textureId, count] pairs (sorted by texture)

  private record Inst,
    tex : Int32, x : Float32, y : Float32, w : Float32, h : Float32,
    r : Float32, g : Float32, b : Float32, a : Float32,
    u : Float32, v : Float32, uw : Float32, uh : Float32

  # --- JS bridges (WebGPU renderer / text / audio live in renderer.js) ---

  # Hands the grouped instance buffer to the WebGPU renderer (12 floats/instance).
  @[JS::Method]
  def draw(ptr : Int32, count : Int32, groups_ptr : Int32, group_pairs : Int32) : Nil
    <<-JS
      if (__memory.buffer.byteLength === 0) __memory = new DataView(__exports.memory.buffer);
      const f = new Float32Array(__exports.memory.buffer, #{ptr}, #{count} * 12);
      const g = new Int32Array(__exports.memory.buffer, #{groups_ptr}, #{group_pairs} * 2);
      if (globalThis.__flockDraw) globalThis.__flockDraw(f, #{count}, g);
    JS
  end

  # Loads an image from `url` (async, fetch → createImageBitmap → texture w/ mipmaps).
  # Returns a texture id immediately; the sprite shows white until the image arrives.
  @[JS::Method]
  def load_image(url : String) : Int32
    <<-JS
      return (globalThis.__flockLoadImage ? globalThis.__flockLoadImage(#{url}) : 0) | 0;
    JS
  end

  # Loads an audio file from `url` (async, fetch → decodeAudioData). Returns a sound id.
  @[JS::Method]
  def load_sound(url : String) : Int32
    <<-JS
      return (globalThis.__flockLoadSound ? globalThis.__flockLoadSound(#{url}) : 0) | 0;
    JS
  end

  # Plays a loaded sound (no-op until decoded). `volume` 0..100, `loop` repeats.
  # Returns a playback handle for `stop_sound` (0 if it couldn't start).
  @[JS::Method]
  def play_sound(id : Int32, volume : Int32 = 100, loop : Int32 = 0) : Int32
    <<-JS
      return (globalThis.__flockPlaySound ? globalThis.__flockPlaySound(#{id}, #{volume} / 100, #{loop}) : 0) | 0;
    JS
  end

  @[JS::Method]
  def stop_sound(handle : Int32) : Nil
    <<-JS
      if (globalThis.__flockStopSound) globalThis.__flockStopSound(#{handle});
    JS
  end

  # Master output volume (0..100), applied to all sounds + beeps.
  @[JS::Method]
  def master_volume(percent : Int32) : Nil
    <<-JS
      if (globalThis.__flockMasterVolume) globalThis.__flockMasterVolume(#{percent} / 100);
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
        # Collect instances, then order by texture for batched draws.
        items = [] of Inst
        world.query(Flock::Transform2D, Flock::Sprite2D) do |_e, tf, sp|
          next if items.size >= MAX
          p = tf.value.position; s = sp.value.size; c = sp.value.color
          uv = sp.value.uv_min; uz = sp.value.uv_size
          items << Inst.new(sp.value.texture, p.x, p.y, s.x, s.y, c.r, c.g, c.b, c.a, uv.x, uv.y, uz.x, uz.y)
        end
        items.sort_by! &.tex

        pairs = 0
        cur_tex = -1
        cur_count = 0
        items.each_with_index do |it, i|
          o = i * FLOATS
          BUFFER[o] = it.x; BUFFER[o + 1] = it.y; BUFFER[o + 2] = it.w; BUFFER[o + 3] = it.h
          BUFFER[o + 4] = it.r; BUFFER[o + 5] = it.g; BUFFER[o + 6] = it.b; BUFFER[o + 7] = it.a
          BUFFER[o + 8] = it.u; BUFFER[o + 9] = it.v; BUFFER[o + 10] = it.uw; BUFFER[o + 11] = it.uh
          if it.tex != cur_tex
            if cur_tex >= 0
              GROUPS[pairs * 2] = cur_tex; GROUPS[pairs * 2 + 1] = cur_count; pairs += 1
            end
            cur_tex = it.tex; cur_count = 0
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
