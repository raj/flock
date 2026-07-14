# Flock — design plan

**Flock** is a data-oriented (Data-Oriented Design) game engine in Crystal, inspired by
Bevy, built on top of [`wgpu-cr`](../wgpu-cr) for rendering and **SDL3** for the
platform (window, input, gamepads, audio, timing).

Guiding goals:

- **Easy to use**: one-line startup (`DefaultPlugins`), ergonomic API.
- **Performant ECS**: sparse sets, cache-friendly `struct` components, mutation via pointer.
- **Textured 2D rendering** + **2D/3D cameras** + **viewports** + **wgpu-style shaders** (WGSL).
- **Gamepads** (SDL_Gamepad, hotplug) and **audio** (SDL3 mixing).
- A **playable example**: Space Invaders.

> History: this plan fixes flaws of the first draft — broken component mutation,
> `String`-indexed storage, suboptimal query, dead `@free_ids` for lack of
> `despawn`, no resources/singletons, flat systems.

## Architecture decisions

- **Components = `struct`** (cache-friendly dense arrays). Mutation via **pointer access**:
  the query yields `Pointer(T)` and `pos.value.x += v` **mutates in place** (Crystal semantics
  verified: `ptr.value.field = …` writes into the dense array).
- **Rendering = textured sprites** from phase 1 (PNG via SDL_image, sampler + texture bind group).
- **wgpu-style shaders**: `Shader` abstraction (WGSL file/string → module) + `Material`
  (shader + pipeline + bind group + uniforms), with access to raw `LibWGPU` handles for
  advanced cases. The default sprite is a built-in material.
- **2D and 3D cameras + viewports**: generic camera abstraction (view-projection matrix +
  screen sub-region). 2D rendering consumes it in phase 1; 3D math (perspective, look_at)
  is provided, 3D mesh rendering comes later.
- **Platform = SDL3.** Choice made at implementation time: **minimal embedded homegrown
  FFI binding** (`src/flock/platform/lib_sdl.cr`, linked to Homebrew SDL3) rather than the
  `Hadeweka/SDL-Crystal-Bindings` shard — fully controlled linking, surface reduced to what
  Flock uses, no `shards install`. Extractable into `../sdl3-cr` or replaceable by the
  shard later. *(To confirm with the user.)*
- **Low-level rendering = wgpu-cr**. wgpu surface created from the `CAMetalLayer` of
  `SDL_Metal_CreateView`/`SDL_Metal_GetLayer` (replaces wgpu-cr's Objective-C glue).
- macOS/Metal first. Prerequisites: `brew install sdl3 sdl3_image`; wgpu-native downloaded by
  wgpu-cr's postinstall.

## Directory tree

```
flock/
├── shard.yml
├── README.md
├── assets/                     # .png sprites, .wav sounds
├── src/
│   ├── flock.cr
│   └── flock/
│       ├── ecs/
│       │   ├── entity.cr       # struct Entity(id, generation)
│       │   ├── component.cr    # module Component + ComponentRegistry (dense integer ids)
│       │   ├── sparse_set.cr   # Storage (abstract) + SparseSet(T) (pointer access)
│       │   ├── world.cr        # spawn/despawn, storages, resources, query (yields pointers)
│       │   └── commands.cr     # deferred structural mutations
│       ├── app/
│       │   ├── schedule.cr     # enum Schedule (Startup, First, Update, Render, Last)
│       │   ├── plugin.cr       # abstract Plugin
│       │   └── app.cr          # App: plugins, systems per schedule, loop
│       ├── math/
│       │   └── math3d.cr       # Vec2, Vec3, Mat4 (ortho, perspective, look_at)
│       ├── time.cr             # Time resource (delta, elapsed)
│       ├── assets.cr           # Assets: texture/font/sound cache + release
│       ├── platform/
│       │   ├── window.cr       # WindowPlugin: SDL window + wgpu surface + GpuContext
│       │   ├── input.cr        # InputPlugin: keyboard + gamepads (Input, Gamepad)
│       │   └── audio.cr        # AudioPlugin: WAV loading/playback (Audio, Sound)
│       └── render/
│           ├── components.cr   # Transform2D, Transform3D, Sprite
│           ├── camera.cr       # Camera2D, Camera3D, Viewport, Projection
│           ├── texture.cr      # PNG (SDL_image) / surface -> wgpu texture
│           ├── font.cr         # Font (SDL_ttf): text -> texture
│           ├── shader.cr       # Shader: WGSL (file/string) -> wgpu module
│           ├── material.cr     # Material: shader + pipeline + bind group + uniforms
│           ├── renderer2d.cr   # instanced textured quad pipeline (default material)
│           └── render_plugin.cr
├── examples/
│   └── space_invaders.cr
└── spec/
    ├── spec_helper.cr
    ├── sparse_set_spec.cr
    ├── world_spec.cr
    ├── query_spec.cr
    └── math_spec.cr            # ortho/perspective/look_at
```

## Detailed design

### 1. ECS — core (`struct` components, mutation via pointer)

**Entity** (`ecs/entity.cr`): `struct Entity(id : UInt32, generation : UInt32)`. Id kept as
`UInt32` end to end (no more `.to_i` in the hot path).

**Component + registry** (`ecs/component.cr`) — dense integer id per type, no hashing:

```crystal
module Flock
  module ComponentRegistry
    @@count = 0
    def self.next_id : Int32; id = @@count; @@count += 1; id; end
    def self.count : Int32; @@count; end
  end

  # struct Position; include Flock::Component; ... end
  module Component
    macro included
      class_getter component_id : Int32 = Flock::ComponentRegistry.next_id
    end
  end
end
```

**Storage + SparseSet** (`ecs/sparse_set.cr`) — type-erased interface (needed for
`despawn`), sparse with `-1` sentinel (no nilable union), and **pointer access** for
in-place mutation:

```crystal
abstract class Storage
  abstract def remove_untyped(entity : Entity)
  abstract def size : Int32
end

class SparseSet(T) < Storage
  getter dense    = [] of T
  getter entities = [] of Entity
  @sparse = [] of Int32                 # -1 = absent

  def size : Int32; @dense.size; end
  def insert(entity, component : T)     # in-place update or push
  def index_of?(entity : Entity) : Int32?           # 1 lookup, generation check
  def get_ptr(entity : Entity) : Pointer(T)?        # @dense.to_unsafe + idx (nil if absent)
  def has?(entity : Entity) : Bool
  def remove(entity : Entity)           # swap-and-pop O(1)
  def remove_untyped(entity : Entity); remove(entity); end
end
```

> **Pointer note**: `get_ptr` returns a pointer into the dense array, valid as long as no
> insert/remove reallocates the array. Hence the rule: any structural mutation
> during iteration goes through `Commands` (deferred).

**World** (`ecs/world.cr`) — storages in `Array(Storage?)` indexed by `component_id` (O(1),
zero hash), real `despawn` feeding `@free_ids`, resources (singletons), and query by
pointers:

```crystal
class World
  @storages  = [] of Storage?
  @resources = {} of String => Resource
  # + next_entity_id / generations / free_ids

  def spawn : Entity                    # recycles via free_ids, bumps generation
  def despawn(entity : Entity)          # remove_untyped on all storages; id -> free_ids
  def storage(t : T.class) : SparseSet(T) forall T   # indexed by T.component_id; checks at
                                                     # compile time that T includes Flock::Component
  def add(entity, c : T) forall T
  def get(entity, t : T.class) : T? forall T
  def remove(entity, t : T.class) forall T

  def insert_resource(r : Resource)
  def resource(t : T.class) : T forall T             # raises if absent
  def resource?(t : T.class) : T? forall T

  # Query: driven by the SMALLEST entity set, 1 lookup per component,
  # yields POINTERS. In Crystal a macro is NOT callable on an instance:
  # so we generate a real `query` method overload per arity (1 to 8).
  #   world.query(A, B) { |e, a, b| p = a.value; p.x += b.value.dx; a.value = p }
end

abstract class Resource; end
```

Overload generation (driver = smallest entity list, one lookup per component):

```crystal
{% for n in 1..8 %}
  def query({% for i in 1..n %}t{{i}} : T{{i}}.class,{% end %}) : Nil forall {% ... %}
    {% for i in 1..n %} s{{i}} = storage(T{{i}}) {% end %}
    drv = s1.entities
    {% for i in 2..n %} drv = s{{i}}.entities if s{{i}}.entities.size < drv.size {% end %}
    drv.dup.each do |entity|            # dup: safe if the block despawns
      {% for i in 1..n %} p{{i}} = s{{i}}.get_ptr(entity); next unless p{{i}} {% end %}
      yield entity, {% for i in 1..n %}p{{i}},{% end %}
    end
  end
{% end %}
```

> **Mutation idiom**: the `ptr.value.x += v` sugar does NOT persist in Crystal (the
> compound-assign reads a copy). Use the struct write-back
> (`p = ptr.value; p.x += v; ptr.value = p`) or direct field assignment
> (`ptr.value.x = ptr.value.x + v`, which does mutate in place). Verified by test.

**Commands** (`ecs/commands.cr`) — deferred structural mutations (avoids invalidating an
in-progress query and dense pointers), applied at end of stage:

```crystal
class Commands
  def spawn(*components) : Entity       # overloads 0..8 (id reserved immediately, adds queued)
  def despawn(entity : Entity)
  def add(entity, component)
  def apply(world : World)              # drained by the App after each schedule
end
```

### 2. App, Schedule, Plugins

`schedule.cr`: `enum Schedule; Startup; First; FixedUpdate; Update; Render; Last; end`.
`FixedUpdate` runs 0..N times per frame via an accumulator (`App#advance_fixed`, fixed step
`fixed_dt`/`fixed_hz`, bounded by `MAX_FIXED_STEPS`) — for fps-independent physics
(systems use `Time#fixed_delta`).
`plugin.cr`: `abstract class Plugin; abstract def build(app : App); end`.

Events & states: `Events(T)` (per-type queue, double-buffered so events live 2 frames;
`send_event`/`each_event` for the simple case, `EventReader(T)` for a per-reader cursor that
reads each event exactly once across frames; `add_event` advances it each frame) and `State(S)` (state machine; `add_state`, `set_state` deferred to the
next frame, `add_system_in_state(value, schedule)` gates a system on the current state;
`add_on_enter`/`add_on_exit` run once per transition, OnEnter(initial) at startup).

`app.cr` — deliberately simple API:

```crystal
Flock::App.new
  .add_plugins(Flock::DefaultPlugins)          # Window + Render + Input + Audio + Time
  .add_startup { |w| ... }
  .add_system(Schedule::Update) { |w, cmd| ... }
  .run
# run: build plugins; Startup systems once;
#   loop: SDL_PollEvent -> Time.tick -> First/Update/Render/Last; commands.apply after each stage.
```

Systems = `Proc` (`World ->` or `World, Commands ->`). `DefaultPlugins` aggregates everything for
one-line startup. (Bevy-style typed system parameters remain a possible evolution.)

### 3. Math (`math/math3d.cr`)

`Vec2`, `Vec3`, `Mat4` (structs). Key functions:

- `Mat4.orthographic(left, right, bottom, top, near, far)` — 2D camera.
- `Mat4.perspective(fov_y, aspect, near, far)` — 3D camera.
- `Mat4.look_at(eye : Vec3, target : Vec3, up : Vec3)` — 3D view.
- multiplication `Mat4 * Mat4`, `Mat4 * Vec4`, translate/rotate/scale.

### 4. Time resource (`time.cr`)

`Time < Resource`: `delta`/`elapsed` (seconds) from `SDL_GetPerformanceCounter` /
`Frequency`. Basis for framerate-independent movement.

### 5. SDL3 platform

**Window** (`platform/window.cr`) — `WindowPlugin`:
`SDL_Init(VIDEO|GAMEPAD|AUDIO)`; `SDL_CreateWindow`; `make_surface` creates the wgpu surface
**per platform** (via `SDL_GetWindowProperties`): Metal/`CAMetalLayer` (macOS),
`SurfaceSourceXlibWindow`/`WaylandSurface` (Linux, runtime detection `SDL_GetCurrentVideoDriver`),
`SurfaceSourceWindowsHWND` (Windows) → `instance_create_surface` (then adapter/device/queue/
capabilities/`surface_configure` in `Fifo`). Reconfiguration on resize.
(macOS tested at runtime; Linux/Windows verified via cross-compilation.)
Publishes a `GpuContext < Resource` resource (instance, adapter, device, queue, surface,
format, window/framebuffer size).

**Input** (`platform/input.cr`) — `InputPlugin`, per-frame **polling** (simpler than
callbacks, constrained by non-capturing procs):

```crystal
input = world.resource(Flock::Input)
input.pressed?(Key::Left)            # SDL_GetKeyboardState
input.just_pressed?(Key::Space)      # diff with the previous frame
pad = input.gamepad?(0)
pad.try &.pressed?(Button::South)    # SDL_GetGamepadButton
pad.try &.axis(Axis::LeftX)          # SDL_GetGamepadAxis, deadzone applied

input.mouse_position                          # framebuffer pixels (HiDPI)
input.mouse_pressed?(MouseButton::Left)
camera.screen_to_world(input.mouse_position, gpu.width.to_f32, gpu.height.to_f32) # -> world
input.mouse_wheel                             # frame scroll (Vec2, via events)
input.text_input                              # UTF-8 typed text (start_text_input to enable)
```

Gamepads: `SDL_OpenGamepad` on `SDL_EVENT_GAMEPAD_ADDED`, close on `_REMOVED`
(hotplug), built-in SDL mappings. `Key`/`Button`/`Axis` = Flock enums decoupled from the raw binding.

**Audio** (`platform/audio.cr`) — `AudioPlugin`:

```crystal
audio = world.resource(Flock::Audio)
shoot = audio.load("assets/shoot.wav")   # SDL_LoadWAV -> decoded PCM (Sound)
audio.play(shoot)                        # optional volume
```

Logical device via `SDL_OpenAudioDeviceStream`; simultaneous playback via **native SDL3
mixing** (multiple `SDL_AudioStream`s bound to the same device). `Sound` = pre-decoded PCM (a single
decompression per file). `play(sound, volume:, loop:)` returns a `Playback` handle: per-playback
gain + `master_volume`, seamless looping, `stop`/`stop_all`. WAV now; OGG/MP3 via SDL3_mixer later.

### 6. Cameras & viewports (`render/camera.cr`)

Generic abstraction: a camera produces a **view-projection matrix** and renders into a
**viewport** (screen sub-region). Two ergonomic components, both `struct` +
`include Component`:

```crystal
struct Viewport                          # sub-region in pixels (nil = fullscreen)
  property x, y, width, height : Float32
end

struct Camera2D
  property position : Vec2               # target center
  property zoom : Float64                # 1.0 = neutral
  property rotation : Float64
  property viewport : Viewport?
  property order : Int32                 # render order (ascending)
  property clear_color : Color?          # nil = no clear (overlay)
  property active : Bool
  # view_projection(fb_size) : Mat4  -> ortho(viewport size) * inverse(camera transform)
end

struct Camera3D
  property position : Vec3
  property target   : Vec3               # (or orientation); up : Vec3
  property up       : Vec3
  property fov_y    : Float64
  property near, far : Float64
  property viewport : Viewport?
  property order    : Int32
  property clear_color : Color?
  property active   : Bool
  # view_projection(fb_size) : Mat4  -> perspective(fov, viewport aspect) * look_at(...)
end
```

The rendering system:

1. Gathers all active cameras (2D and 3D), sorted by `order`.
2. For each: computes the aspect ratio from its `viewport` (or the framebuffer); calls
   `render_pass_encoder_set_viewport` + `set_scissor_rect` (present in wgpu-cr); optional
   clear; pushes the view-projection matrix into the uniform; renders the visible scene.

Use cases covered: split-screen (2 cameras, 2 viewports), minimap (small overlay camera,
`clear_color = nil`), HUD. **Phase 1: only the 2D pass (Camera2D) is wired**;
Camera3D + perspective math are provided, the 3D mesh pass comes later.

### 7. Textured 2D rendering (`render/`)

**Components** (`render/components.cr`) — structs: `Transform2D` (position `Vec2`, rotation,
scale `Vec2`), `Transform3D` (Vec3 + rotation + scale, for upcoming 3D), `Sprite`
(`texture : TextureHandle`, `color : Color` tint, `size : Vec2`, `uv_rect` for atlases).

**Texture** (`render/texture.cr`): `IMG_Load` (SDL_image) → RGBA pixels →
`device_create_texture` + `queue_write_texture`; a shared `Sampler`. Cached by path
(`Hash(String, TextureHandle)`).

**Renderer2D** (`render/renderer2d.cr`) — instanced textured quads (chosen implementation,
simpler than vertex/index buffers):

- **Geometry in the shader**: the unit quad (6 pos+uv vertices) is a WGSL `const`
  indexed by `@builtin(vertex_index)`. No vertex/index buffer.
- **Instance storage buffer** rewritten per frame (`queue_write_buffer`): per entity
  (Transform2D, Sprite) → model matrix (16f) + tint (4f) + uv (4f) = 96 B. The shader reads
  `instances[@builtin(instance_index)]`. Capacity doubled on demand.
- uniform buffer: view-projection **of the current camera**; bind groups in **auto layout**
  (`render_pipeline_get_bind_group_layout`): group0 = uniform+storage, group1 = texture+sampler.
- **Layer-aware batching**: sprites sorted by `(z, texture)` then one
  `draw(6, count, 0, first_instance)` per contiguous run of the same texture → correct
  layering **and** minimal draws (N sprites of the same texture = 1 draw). Stats exposed:
  `Renderer2D#last_sprites` / `#last_draw_calls`.
- **alpha blending enabled**; `fs_main` = `texture * tint`.
- Per-frame path modeled on `triangle.cr` (`surface_get_current_texture` → render pass →
  submit → `surface_present`); the 1st frame (surface not ready yet) is skipped.

**RenderPlugin** (`render/render_plugin.cr`): creates Renderer2D + Sampler at Startup (from
`GpuContext`), registers the rendering system (iterates cameras) in `Schedule::Render`.

### 8. Shaders & materials — wgpu-style (`render/shader.cr`, `render/material.cr`)

Goal: expose wgpu's shader model (WGSL, pipeline, bind group, uniforms) in an
idiomatic way, without hiding the low level. Since wgpu-cr is a thin binding, `Shader` and
`Material` are thin typed conveniences on top of `device_create_shader_module` /
`device_create_render_pipeline`, with the `LibWGPU` handles remaining accessible.

**Shader** (`render/shader.cr`) — reuses the `triangle.cr` pattern (`WGPU.string_view` →
`ShaderSourceWGSL` → `device_create_shader_module`):

```crystal
struct Shader
  getter module : LibWGPU::ShaderModule
  def self.from_source(gpu : GpuContext, wgsl : String, *, vertex = "vs_main", fragment = "fs_main") : Shader
  def self.from_file(gpu : GpuContext, path : String, **kw) : Shader   # reads a .wgsl
end
```

**Material** (`render/material.cr`) — associates a shader with a pipeline config and
user uniforms; builds the matching `RenderPipeline` + bind group:

```crystal
class Material
  def self.build(gpu : GpuContext, shader : Shader, *,
                 blend      = Blend::AlphaBlend,        # or Opaque, Additive
                 topology   = Topology::TriangleList,
                 vertex_layout : VertexLayout = VertexLayout.sprite,  # pos+uv by default
                 bindings   : Array(Binding) = ...) : Material         # uniforms/textures/samplers
  def set_uniform(name : String, value)   # writes into the uniform buffer via queue_write_buffer
  getter pipeline : LibWGPU::RenderPipeline
  getter bind_group : LibWGPU::BindGroup
end
```

- **Default material**: Renderer2D provides a built-in one (textured sprite shader +
  tint + view-projection). The "easy" path: the user touches nothing.
- **Custom materials**: `Sprite` (and later `Mesh`) can reference a
  `MaterialHandle`. The renderer batches by material then by texture. Enables per-entity
  effects (dissolve, outline, animated tint…).
- **Post-processing**: `PostProcess` = fullscreen material whose fragment reads the scene
  texture (render into an intermediate texture then fullscreen pass). Near-term evolution;
  the Material abstraction makes it straightforward.
- **Low-level escape hatch**: `Shader#module`, `Material#pipeline`/`#bind_group` expose the
  `LibWGPU` handles — an advanced user drives the render pass by hand, "wgpu-style".

### 9. Example — Space Invaders (`examples/space_invaders.cr`)

Demonstrates ECS + camera + input (keyboard **and** gamepad) + audio + textured sprites:

- **Startup**: `Camera2D` (fullscreen); player, invader grid, loaded PNG sprites.
- **Game components**: `Player`, `Invader`, `Bullet`, `Velocity` (+ Transform2D, Sprite).
- **Update systems**: player input (keyboard/gamepad → movement, shooting via `Commands` +
  `audio.play(shoot)`); movement (`query(Transform2D, Velocity)` → Transform write-back:
  `tr = t.value; tr.position += … * Time.delta; t.value = tr`); group movement of
  the invaders; bullet×invader collisions
  (AABB → despawn of both + explosion); cleanup of off-screen bullets.
- **Render**: automatic (everything with Transform2D + Sprite, seen by the Camera2D).
- **Shader demo** (optional): custom material on the invaders (blinking/tint WGSL)
  to illustrate the shader API.

### 10. shard.yml & linking

```yaml
name: flock
version: 0.1.0
authors: [Raj Deenoo]
crystal: ">= 1.16.0"
license: MIT
dependencies:
  wgpu: { path: ../wgpu-cr }
  sdl-crystal-bindings: { github: Hadeweka/SDL-Crystal-Bindings, version: ~> 0.5.0 }
targets:
  space_invaders: { main: examples/space_invaders.cr }
```

`@[Link]` SDL3 (Homebrew), following the wgpu-cr/GLFW model:
`-L/opt/homebrew/lib -lSDL3 -lSDL3_image -Wl,-rpath,/opt/homebrew/lib`.

### 11. Tests (`spec/`)

`wgpu-cr/spec` model (standard Crystal spec, headless):

- `sparse_set_spec`: insert/get_ptr/remove, swap-and-pop, generation check.
- `world_spec`: spawn/despawn, id recycling + generation bump, resources.
- `query_spec`: driver = smallest set, **persistent mutation via pointer**, robustness to
  despawn during iteration (`dup`).
- `math_spec`: ortho/perspective/look_at (known values).
- Rendering/window: `WGPU_FRAMES=N` smoke test (headless), outside blocking CI.

## Implementation status (all phases delivered and verified)

All phases below are implemented. Core tested by `crystal spec` (29 examples,
headless); GPU/platform layers verified headless via `WGPU_FRAMES=N crystal run …`
(window + N frames + clean exit, no wgpu validation error).

- ✅ **1. ECS** — entity, component/registry, sparse_set (pointer), world, commands + specs.
- ✅ **2. Math** — Vec2/Vec3/Mat4 (ortho/perspective/look_at, translate/rotate/scale) + specs.
- ✅ **3. App/Schedule/Plugin + Time** — loop, plugins, `run_headless` + specs.
- ✅ **4. Window** — SDL3 + wgpu surface (via `SDL_Metal_GetLayer`), runner, resize.
- ✅ **5. Shaders & materials** — `Shader` (WGSL) + fullscreen `Material` (plasma example).
- ✅ **6. Cameras/viewports + Render2D** — instanced textured quads, blending, Camera2D/3D.
- ✅ **7. Input** — keyboard + gamepads (hotplug, dead zone).
- ✅ **8. Audio** — WAV + procedural sounds, SDL3 mixing.
- ✅ **9. Space Invaders** — playable assembly (`examples/space_invaders.cr`) + README.

Crystal discoveries that shaped the design (detailed above): (a) macros are
not callable on an instance → `query`/`Commands#spawn` are **method overloads**
generated per arity; (b) `ptr.value.x += v` does not persist, but direct
assignment `ptr.value.x = …` and **mutating methods** `ptr.value.move(…)` do.

Image loading: `Texture.load(gpu, path)` (PNG/JPG… via SDL_image, RGBA8 conversion)
**implemented and verified**; `Texture.from_pixels` for procedural textures.

Memory management: `Resource#release` + `World#shutdown` (called by `App#run`) release the
GPU/SDL handles in the right order (renderer before device). Assets: `Flock::Assets`
(via `AssetsPlugin`/DefaultPlugins) caches textures/fonts/sounds by key and releases them. Rendering tests: `render_into` +
`examples/readback_test.cr` (offscreen render → copy → map → pixel assertions, headless).
wgpu errors: `Flock.request_device` wires the `uncaptured error` / `device lost` callbacks
(→ STDERR), flushed by `instance_process_events` each frame. Surface: `render` decodes the
acquisition status and reconfigures (`reconfigure_to_window`) on `Outdated`/`Lost`.
Text: `Flock::Font` (SDL_ttf) renders a string into a `Texture` (via `Texture.from_surface`),
drawn as a tintable sprite; verified by `examples/text_test.cr`.

Per-sprite materials: `SpriteMaterial` (`Renderer2D#build_material(wgsl)`) shares an explicit
pipeline layout so a `Sprite#material` swaps the shader while reusing the uniform/instance/
texture bind groups; batched by (z, material, texture). Verified by `examples/material_test.cr`.

3D: `Mesh` (vertex/index buffers, `Mesh.cube`) + `MeshRenderer`/`Transform3D` + `Renderer3D`
(per-mesh draws via a model storage buffer, depth buffer, directional lighting) consume
`Camera3D`. Verified by `examples/cube3d.cr` / `cube3d_test.cr`.

Remaining (post-phase, non-blocking): compressed audio (OGG/MP3) via SDL3_mixer; mesh loading
(glTF/OBJ); web/WASM export (see todo).

## Implementation roadmap

1. ECS (entity, component/registry, sparse_set pointer, world, commands) + specs.
2. Math (Vec2/Vec3/Mat4, ortho/perspective/look_at) + specs.
3. App/Schedule/Plugins + Time (windowless loop).
4. Window (SDL3 + wgpu surface) → clear on screen.
5. Shaders & materials (WGSL Shader, Material/pipeline) + default sprite material.
6. Cameras/viewports + textured Render2D (SDL_image, sampler, bind group).
7. Input (keyboard + gamepads, hotplug, deadzone).
8. Audio (WAV, mixing).
9. Space Invaders + README.
10. (later) fullscreen post-processing; 3D mesh rendering consuming Camera3D.

## Verification

- `brew install sdl3 sdl3_image`; `cd flock && shards install`.
- `crystal spec`: ECS/world/query/math green (headless, no SDL/GPU).
- `WGPU_FRAMES=3 crystal run examples/space_invaders.cr`: window + a few frames + clean
  exit (smoke test).
- Interactive: player movable by keyboard **and** gamepad, audible shooting, invaders destroyed on
  contact; camera demo by adding a 2nd Camera2D with a reduced `viewport` (minimap).
