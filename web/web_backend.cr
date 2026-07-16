# WebPlugins — a browser backend for Flock, paralleling the native DefaultPlugins.
# It reuses Flock's native-free core (App / Plugin / Schedule / World / Time) and wires
# up browser equivalents: 2D sprite components, a keyboard Input resource, and a render
# system that streams sprite instances to a WebGPU renderer in JS (renderer.js). The
# frame loop is driven from JS (requestAnimationFrame → flock_frame → App#update), since
# the browser can't use the native blocking runner.
#
# Game code stays structured exactly like the native side: build an App, add plugins and
# systems on schedules, query components.
require "js"
require "../src/flock"

module Flock::Web
  extend self
  include ::JS::ExpandMethods # enables @[JS::Method] bodies

  MAX = 512 # max sprites per frame

  # 2D transform (native-free; the native Transform2D/Sprite pull in wgpu texture types).
  struct Transform2D
    include Flock::Component
    property position : Flock::Vec2

    def initialize(@position : Flock::Vec2 = Flock::Vec2.new)
    end
  end

  # A colored sprite (rectangle). `color` is RGB in 0..1.
  struct Sprite
    include Flock::Component
    property size : Flock::Vec2
    property color : Flock::Vec3

    def initialize(@size : Flock::Vec2, @color : Flock::Vec3)
    end
  end

  # Keyboard state, fed from JS (DOM key events). Codes are KeyboardEvent.keyCode.
  ARROW_LEFT  = 37
  ARROW_UP    = 38
  ARROW_RIGHT = 39
  ARROW_DOWN  = 40
  SPACE       = 32

  class Input < Flock::Resource
    KEYS = 256
    @down = Array(Bool).new(KEYS, false)

    def set(code : Int32, down : Bool) : Nil
      @down[code] = down if 0 <= code < KEYS
    end

    def pressed?(code : Int32) : Bool
      (0 <= code < KEYS) && @down[code]
    end
  end

  BUFFER = Slice(Float32).new(MAX * 8) # per instance: x,y,w,h, r,g,b,a

  # Hands the filled instance buffer to the JS WebGPU renderer (reads WASM memory).
  @[JS::Method]
  def draw(ptr : Int32, count : Int32) : Nil
    <<-JS
      if (__memory.buffer.byteLength === 0) __memory = new DataView(__exports.memory.buffer);
      const f = new Float32Array(__exports.memory.buffer, #{ptr}, #{count} * 8);
      if (globalThis.__flockDraw) globalThis.__flockDraw(f, #{count});
    JS
  end

  # Inserts the Input resource and registers the render system (Schedule::Render).
  class WebPlugins < Flock::Plugin
    def build(app : Flock::App) : Nil
      app.world.insert_resource(Input.new)
      app.add_system(Flock::Schedule::Render) do |world, _cmd|
        i = 0
        world.query(Transform2D, Sprite) do |_e, tf, sp|
          if i < MAX
            o = i * 8
            p = tf.value.position; s = sp.value.size; c = sp.value.color
            BUFFER[o] = p.x; BUFFER[o + 1] = p.y
            BUFFER[o + 2] = s.x; BUFFER[o + 3] = s.y
            BUFFER[o + 4] = c.x; BUFFER[o + 5] = c.y; BUFFER[o + 6] = c.z; BUFFER[o + 7] = 1.0f32
            i += 1
          end
        end
        Flock::Web.draw(BUFFER.to_unsafe.address.to_i64!.to_i32!, i)
      end
    end
  end

  # The running App (set by `launch`, driven by the exported frame functions).
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
  Flock::Web.app.update # First -> FixedUpdate -> Update -> Render (streams sprites) -> Last
  0
end

JS.export def flock_key(code : Int32, down : Int32) : Int32
  Flock::Web.app.world.resource(Flock::Web::Input).set(code, down != 0)
  0
end
