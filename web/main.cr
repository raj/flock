# Flock — Web/WASM entry point. The ECS core (World/query/Component + math) runs in
# WebAssembly; each frame it fills a flat instance buffer and hands it to a WebGPU
# renderer in JS (see renderer.js). Native rendering (wgpu-native/SDL3) is not used here.
#
# Build: web/build.sh  → web/app.wasm + web/app.mjs
require "js"
require "../src/flock"

WIDTH  = 800.0f32
HEIGHT = 600.0f32
MAX    =    220

# A colored box moving in the 2D plane (top-left origin, pixels).
struct Body
  include Flock::Component
  property pos : Flock::Vec2
  property vel : Flock::Vec2
  property size : Flock::Vec2
  property color : Flock::Vec3

  def initialize(@pos : Flock::Vec2, @vel : Flock::Vec2, @size : Flock::Vec2, @color : Flock::Vec3)
  end
end

WORLD  = Flock::World.new
BUFFER = Slice(Float32).new(MAX * 8) # per instance: x,y,w,h, r,g,b,a

module Game
  extend self
  include ::JS::ExpandMethods # enables @[JS::Method] bodies

  def setup
    MAX.times do
      s = 12.0f32 + rand.to_f32 * 34.0f32
      e = WORLD.spawn
      WORLD.add(e, Body.new(
        Flock::Vec2.new(rand.to_f32 * WIDTH, rand.to_f32 * HEIGHT),
        Flock::Vec2.new((rand.to_f32 - 0.5f32) * 320.0f32, (rand.to_f32 - 0.5f32) * 320.0f32),
        Flock::Vec2.new(s, s),
        Flock::Vec3.new(0.3f32 + rand.to_f32 * 0.7f32, 0.3f32 + rand.to_f32 * 0.7f32, 0.3f32 + rand.to_f32 * 0.7f32)))
    end
  end

  # Integrate motion + bounce off the walls.
  def step(dt : Float32)
    WORLD.query(Body) do |_e, b|
      p = b.value.pos + b.value.vel * dt
      v = b.value.vel
      w = b.value.size.x
      if p.x < 0 || p.x + w > WIDTH
        v = Flock::Vec2.new(-v.x, v.y)
        p = Flock::Vec2.new(p.x.clamp(0.0f32, WIDTH - w), p.y)
      end
      if p.y < 0 || p.y + w > HEIGHT
        v = Flock::Vec2.new(v.x, -v.y)
        p = Flock::Vec2.new(p.x, p.y.clamp(0.0f32, HEIGHT - w))
      end
      b.value.pos = p
      b.value.vel = v
    end
  end

  # Writes the current sprites into BUFFER (x,y,w,h,r,g,b,a); returns the count.
  def fill : Int32
    i = 0
    WORLD.query(Body) do |_e, b|
      o = i * 8
      bd = b.value
      BUFFER[o] = bd.pos.x; BUFFER[o + 1] = bd.pos.y
      BUFFER[o + 2] = bd.size.x; BUFFER[o + 3] = bd.size.y
      BUFFER[o + 4] = bd.color.x; BUFFER[o + 5] = bd.color.y; BUFFER[o + 6] = bd.color.z; BUFFER[o + 7] = 1.0f32
      i += 1
    end
    i
  end

  # Reads BUFFER out of WASM linear memory and calls the JS WebGPU renderer.
  @[JS::Method]
  def push_frame(ptr : Int32, count : Int32) : Nil
    <<-JS
      if (__memory.buffer.byteLength === 0) __memory = new DataView(__exports.memory.buffer);
      const f = new Float32Array(__exports.memory.buffer, #{ptr}, #{count} * 8);
      if (globalThis.__flockDraw) globalThis.__flockDraw(f, #{count});
    JS
  end
end

# --- Exports called from renderer.js ---

JS.export def flock_init : Int32
  Game.setup
  MAX
end

JS.export def flock_frame(dt_ms : Int32) : Int32
  Game.step(dt_ms.to_f32 / 1000.0f32)
  count = Game.fill
  Game.push_frame(BUFFER.to_unsafe.address.to_i64!.to_i32!, count)
  count
end
