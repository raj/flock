# A backend-agnostic Flock scene: identical source runs on the native renderer AND the
# web (WASM+WebGPU) backend. It uses only the shared core — `Flock::Sprite2D` +
# `Flock::Transform2D` + `Flock::Color` + App/World/Time — and takes the one target-
# specific bit (loading a texture → an id) as an injected `load_texture` proc.
#
# Used by examples/shared_scene_native.cr (native) and web/main.cr (web).
require "../src/flock"

module SharedScene
  WIDTH  = 800.0f32
  HEIGHT = 600.0f32

  struct Velocity
    include Flock::Component
    property v : Flock::Vec2

    def initialize(@v : Flock::Vec2)
    end
  end

  # Adds the scene's entities + systems to `app`. `load_texture` maps an asset name to a
  # renderer texture id (native: a Renderer2D bank id; web: a JS texture id).
  def self.setup(app : Flock::App, load_texture : String -> Int32) : Nil
    app.add_startup do |_world, cmd|
      tex = load_texture.call("sprite.png")
      120.times do
        s = 20.0f32 + rand.to_f32 * 34.0f32
        cmd.spawn(
          Flock::Transform2D.at(rand.to_f32 * WIDTH, rand.to_f32 * HEIGHT),
          Flock::Sprite2D.new(
            Flock::Vec2.new(s, s),
            Flock::Color.new(0.45 + rand * 0.55, 0.45 + rand * 0.55, 0.45 + rand * 0.55),
            tex),
          Velocity.new(Flock::Vec2.new((rand.to_f32 - 0.5f32) * 260.0f32, (rand.to_f32 - 0.5f32) * 260.0f32)))
      end
    end

    app.add_system(Flock::Schedule::Update) do |world, _cmd|
      dt = world.resource(Flock::Time).delta.to_f32
      world.query(Flock::Transform2D, Velocity) do |_e, tf, vel|
        p = tf.value.position + vel.value.v * dt
        v = vel.value.v
        if p.x < 0 || p.x > WIDTH
          v = Flock::Vec2.new(-v.x, v.y); p = Flock::Vec2.new(p.x.clamp(0.0f32, WIDTH), p.y)
        end
        if p.y < 0 || p.y > HEIGHT
          v = Flock::Vec2.new(v.x, -v.y); p = Flock::Vec2.new(p.x, p.y.clamp(0.0f32, HEIGHT))
        end
        tf.value.position = p
        vel.value.v = v
      end
    end
  end
end
