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
    z : Float32, tex : Int32, mat : Int32, x : Float32, y : Float32, w : Float32, h : Float32,
    r : Float32, g : Float32, b : Float32, a : Float32,
    u : Float32, v : Float32, uw : Float32, uh : Float32

  # --- JS bridges (WebGPU renderer / text / audio live in renderer.js) ---

  # Hands the grouped instance buffer to the WebGPU renderer (12 floats/instance).
  # Camera is passed as ints (JS::Method can't take Float32): position in pixels, zoom ×1000
  # (0 = no camera → renderer defaults to centering [0,W]x[0,H] at zoom 1).
  @[JS::Method]
  def draw(ptr : Int32, count : Int32, groups_ptr : Int32, group_count : Int32,
           camx : Int32, camy : Int32, zoom_milli : Int32) : Nil
    <<-JS
      if (__memory.buffer.byteLength === 0) __memory = new DataView(__exports.memory.buffer);
      const f = new Float32Array(__exports.memory.buffer, #{ptr}, #{count} * 12);
      const g = new Int32Array(__exports.memory.buffer, #{groups_ptr}, #{group_count} * 3);
      if (globalThis.__flockDraw) globalThis.__flockDraw(f, #{count}, g, #{camx}, #{camy}, #{zoom_milli} / 1000);
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

  # Registers a custom sprite material and returns its id (0 = default / unsupported).
  # `wgsl_frag` is a `@fragment fn fs(i : VSOut) -> @location(0) vec4<f32>` (WebGPU);
  # `glsl_body` is the GLSL `main()` body setting `o` from `vUv`/`vColor`/`uTex` (WebGL2).
  @[JS::Method]
  def register_material(wgsl_frag : String, glsl_body : String) : Int32
    <<-JS
      return (globalThis.__flockRegisterMaterial ? globalThis.__flockRegisterMaterial(#{wgsl_frag}, #{glsl_body}) : 0) | 0;
    JS
  end

  # Registers one of Flock's built-in Sprite2D material shaders (see SpriteShaders,
  # e.g. `:glow`, `:ring`, `:disc`, `:vignette`) and returns its id.
  def register_builtin(name : Symbol) : Int32
    wgsl, glsl = Flock::SpriteShaders.core(name)
    register_material(Flock::SpriteShaders.web_wgsl(wgsl), Flock::SpriteShaders.web_glsl(glsl))
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
      # Unified, backend-agnostic resources (same API as native): game code uses these.
      app.world.insert_resource(Flock::Input.new)
      app.world.insert_resource(Flock::Audio.new)
      app.world.insert_resource(Flock::Text.new)
      app.world.insert_resource(Flock::Materials.new)
      # Advance the unified input's edge state at the end of each frame.
      app.add_system(Flock::Schedule::Last) { |w, _c| w.resource(Flock::Input).advance }
      app.add_system(Flock::Schedule::Render) do |world, _cmd|
        # Collect instances, then order by texture for batched draws.
        items = [] of Inst
        world.query(Flock::Transform2D, Flock::Sprite2D) do |_e, tf, sp|
          next if items.size >= MAX
          p = tf.value.position; s = sp.value.size; c = sp.value.color
          uv = sp.value.uv_min; uz = sp.value.uv_size
          items << Inst.new(sp.value.z, sp.value.texture, sp.value.material, p.x, p.y, s.x, s.y, c.r, c.g, c.b, c.a, uv.x, uv.y, uz.x, uz.y)
        end
        # Order by layer (z), then (material, texture): correct back-to-front layering
        # (matches the native renderer) with contiguous draw groups.
        items.sort_by! { |it| {it.z, it.mat, it.tex} }

        groups = 0
        cur_tex = -1
        cur_mat = -1
        cur_count = 0
        items.each_with_index do |it, i|
          o = i * FLOATS
          BUFFER[o] = it.x; BUFFER[o + 1] = it.y; BUFFER[o + 2] = it.w; BUFFER[o + 3] = it.h
          BUFFER[o + 4] = it.r; BUFFER[o + 5] = it.g; BUFFER[o + 6] = it.b; BUFFER[o + 7] = it.a
          BUFFER[o + 8] = it.u; BUFFER[o + 9] = it.v; BUFFER[o + 10] = it.uw; BUFFER[o + 11] = it.uh
          if (it.tex != cur_tex || it.mat != cur_mat)
            if cur_count > 0 && groups < 42
              GROUPS[groups * 3] = cur_tex; GROUPS[groups * 3 + 1] = cur_mat; GROUPS[groups * 3 + 2] = cur_count; groups += 1
            end
            cur_tex = it.tex; cur_mat = it.mat; cur_count = 0
          end
          cur_count += 1
        end
        if cur_count > 0 && groups < 42
          GROUPS[groups * 3] = cur_tex; GROUPS[groups * 3 + 1] = cur_mat; GROUPS[groups * 3 + 2] = cur_count; groups += 1
        end

        # Camera (backend-agnostic Camera2D): pass its center + zoom, or a zoom<=0 sentinel
        # when there's none (renderer.js then centers on [0,W]x[0,H] at zoom 1).
        camx = 0; camy = 0; zoom_milli = 0
        world.query(Flock::Camera2D) do |_e, cam|
          next unless cam.value.active
          camx = cam.value.position.x.to_i
          camy = cam.value.position.y.to_i
          zoom_milli = (cam.value.zoom * 1000).to_i
        end

        Flock::Web.draw(BUFFER.to_unsafe.address.to_i64!.to_i32!, items.size,
          GROUPS.to_unsafe.address.to_i64!.to_i32!, groups, camx, camy, zoom_milli)
      end
    end
  end

  # DOM keyCode → shared Flock::Key (only the codes renderer.js forwards today + letters).
  def dom_to_key(code : Int32) : Flock::Key?
    case code
    when 32 then Flock::Key::Space
    when 37 then Flock::Key::Left
    when 38 then Flock::Key::Up
    when 39 then Flock::Key::Right
    when 40 then Flock::Key::Down
    when 13 then Flock::Key::Return
    when  8 then Flock::Key::Backspace
    when  9 then Flock::Key::Tab
    when 27 then Flock::Key::Escape
    when 65..90 then Flock::Key.new(4 + (code - 65)) # A..Z
    else         nil
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
  w = Flock::Web.app.world
  w.resource(Flock::Web::Input).set(code, down != 0)                       # legacy raw-code input
  if key = Flock::Web.dom_to_key(code)
    w.resource(Flock::Input).set_key(key, down != 0)                       # unified input
  end
  0
end

JS.export def flock_pointer(x : Int32, y : Int32, down : Int32) : Int32
  Flock::Web.app.world.resource(Flock::Input).set_pointer(x.to_f32, y.to_f32, down != 0)
  0
end

JS.export def flock_gamepad(ax : Int32, ay : Int32, buttons : Int32, connected : Int32) : Int32
  Flock::Web.app.world.resource(Flock::Web::Input).set_gamepad(ax, ay, buttons, connected != 0)
  0
end

# --- Unified, backend-agnostic resources (web implementations) ---
# Same class names + API as the native backend (Flock::Input / Flock::Audio / Flock::Text).
# Native and web are separate compile targets, so game code referencing these is portable.
module Flock
  # Keyboard + pointer input (web). Mirrors the native Flock::Input surface game code uses.
  class Input < Resource
    KEYS = 256
    @down = Array(Bool).new(KEYS, false)
    @prev = Array(Bool).new(KEYS, false)
    getter text_input : String = ""
    getter mouse_x : Float32 = 0.0f32
    getter mouse_y : Float32 = 0.0f32
    getter? mouse_down : Bool = false

    def set_key(key : Flock::Key, down : Bool) : Nil
      v = key.value
      @down[v] = down if 0 <= v < KEYS
    end

    def pressed?(key : Flock::Key) : Bool
      v = key.value
      (0 <= v < KEYS) && @down[v]
    end

    def just_pressed?(key : Flock::Key) : Bool
      v = key.value
      (0 <= v < KEYS) && @down[v] && !@prev[v]
    end

    def set_pointer(x : Float32, y : Float32, down : Bool) : Nil
      @mouse_x = x; @mouse_y = y; @mouse_down = down
    end

    def append_text(s : String) : Nil
      @text_input += s
    end

    # End-of-frame: snapshot for edge detection + clear the per-frame text buffer.
    def advance : Nil
      @prev = @down.dup
      @text_input = ""
    end
  end

  # Audio (web). `beep` matches native's signature; delegates to the WebAudio bridge.
  class Audio < Resource
    def beep(frequency : Number, ms : Number, volume : Number = 0.25) : Nil
      Flock::Web.beep(frequency.to_i, ms.to_i)
    end
  end

  # Text→texture facade (web). `texture` matches native's; delegates to canvas make_text.
  class Text < Resource
    @cache = {} of String => Int32

    def texture(str : String, px : Number = 24) : Int32
      @cache[str] ||= Flock::Web.make_text(str)
    end
  end

  # Custom-material registry (web). Same API as native's Flock::Materials; wraps the shared
  # shader cores into web fragments (WebGPU WGSL + WebGL2 GLSL).
  class Materials < Resource
    @builtins = {} of Symbol => Int32
    @customs = {} of String => Int32

    def builtin(name : Symbol) : Int32
      @builtins[name] ||= Flock::Web.register_builtin(name)
    end

    def register(wgsl_core : String, glsl_core : String) : Int32
      @customs[wgsl_core] ||= Flock::Web.register_material(
        Flock::SpriteShaders.web_wgsl(wgsl_core), Flock::SpriteShaders.web_glsl(glsl_core))
    end
  end
end
