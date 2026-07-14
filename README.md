# Flock

A **data-oriented (ECS)** game engine in Crystal, inspired by Bevy, built on top of
[`wgpu-cr`](../wgpu-cr) (WebGPU rendering) and **SDL3** (window, input, gamepads, audio).

- **ECS**: sparse sets, cache-friendly `struct` components, mutation via pointer,
  multi-component `query` (driven by the smallest set), resources, deferred commands.
- **App / plugins / schedules**: `Startup / First / Update / Render / Last`.
- **2D rendering**: instanced textured sprites, 2D/3D cameras, viewports, alpha blending.
- **wgpu-style shaders**: `Shader` (WGSL) + `Material` (pipeline + uniform), raw handles accessible.
- **Input**: keyboard, **mouse** (position/buttons + `Camera2D#screen_to_world`),
  **gamepads** (SDL_Gamepad, hotplug, dead zone).
- **Audio**: WAV + procedural sounds, native SDL3 mixing.

See [`plan.md`](plan.md) for the detailed design.

## Prerequisites (macOS / Metal)

```sh
brew install sdl3 sdl3_image sdl3_ttf
```

`wgpu-native` is provided by the neighboring `../wgpu-cr` (downloaded by its `postinstall`).
Flock references it via relative path — no `shards install` required for the examples.

**Portability**: SDL linking goes through pkg-config and surface creation is dispatched
per platform (Metal on macOS, X11/Wayland on Linux, HWND on Windows). **macOS** is tested at runtime;
**Linux/Windows** are verified via cross-compilation but not yet validated on real hardware.

## Testing (ECS core + math, headless)

```sh
crystal spec        # 34 examples, no SDL or GPU
```

## Running the examples

```sh
crystal run examples/space_invaders.cr     # the game: keyboard + gamepad + sound
crystal run examples/window_app.cr         # 2D camera + colored sprites
crystal run examples/custom_shader.cr      # plasma effect (custom WGSL shader)
crystal run examples/mouse_demo.cr         # a square follows the mouse, red on click
crystal run examples/events_demo.cr        # wheel + text input (console)

# Headless smoke test (quits after N frames):
WGPU_FRAMES=120 crystal run examples/space_invaders.cr

# Headless readback tests (offscreen render + pixel assertions; exit 0 if OK):
crystal run examples/readback_test.cr    # a colored sprite
crystal run examples/text_test.cr        # text rendering (SDL_ttf)
crystal run examples/assets_test.cr      # asset cache (same key -> same instance)
```

## Assets (cache)

```crystal
assets = world.resource(Flock::Assets)          # provided by DefaultPlugins
tex = assets.texture("assets/player.png")       # loaded once, cached
fnt = assets.font("assets/Roboto.ttf", 24)
snd = assets.sound("assets/shoot.wav")
# centralized release on shutdown (assets.release, before the device)
```

## Text

```crystal
font = assets.font("/System/Library/Fonts/Supplemental/Arial.ttf", 40)
tex  = font.render_texture(gpu, "Score: 42")    # RGBA texture (white text)
cmd.spawn(Flock::Transform2D.at(0, 260),
  Flock::Sprite.new(Flock::Vec2.new(tex.width, tex.height), Flock::Color::WHITE, tex))
# The sprite tint colors the text. Cache it for text that changes often.
```

Space Invaders: **arrows / A-D** or **left stick** to move, **Space / A button** to shoot.

## Quick start

```crystal
require "../src/flock/gpu"

struct Position; include Flock::Component; property v : Flock::Vec2
  def initialize(@v = Flock::Vec2.new); end
end

app = Flock::App.new
app.add_plugin(Flock::DefaultPlugins.new("My game", 800, 600))

app.add_startup do |world, cmd|
  cmd.spawn(Flock::Camera2D.new(clear_color: Flock::Color.new(0.1, 0.1, 0.15)))
  cmd.spawn(
    Flock::Transform2D.at(0, 0),
    Flock::Sprite.new(Flock::Vec2.new(120, 120), Flock::Color::RED),
  )
end

app.add_system(Flock::Schedule::Update) do |world, _cmd|
  dt = world.resource(Flock::Time).delta.to_f32
  world.query(Flock::Transform2D) do |_e, tf|
    tf.value.position = tf.value.position + Flock::Vec2.new(30 * dt, 0)
  end
end

app.run
```

## Mutation idiom (`struct` components)

Components are `struct`s (data-oriented). `query` yields `Pointer(T)`.
In Crystal, **direct assignment** and **mutating methods** persist through
a pointer, but **not** compound assignment `+=`:

```crystal
world.query(Transform2D, Velocity) do |_e, tf, vel|
  tf.value.position = tf.value.position + vel.value.linear * dt  # ✅ direct setter
  # tf.value.position.x += ...                                    # ❌ does not persist
end
```

## Architecture

```
src/flock.cr              # headless core: math + ecs + app + time (no native deps)
src/flock/gpu.cr          # full entry point: + wgpu (rendering) + SDL3 (platform)
src/flock/ecs/            # entity, component, sparse_set, world, commands
src/flock/app/            # schedule, plugin, app
src/flock/math/math3d.cr  # Vec2, Vec3, Mat4 (ortho/perspective/look_at)
src/flock/platform/       # window, input, audio, gpu_context, gpu_errors (SDL3 binding: ../sdl3-cr)
src/flock/render/         # color, texture, font, camera, components, shader, material, renderer2d
src/flock/assets.cr       # Assets: texture/font/sound cache
examples/                 # space_invaders, window_app, custom_shader, mouse/events/readback…
spec/                     # headless core tests
```

## License

MIT
