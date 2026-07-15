# Improvement ideas — Flock & sdl3-cr

Sorted by impact. `[ ]` to do. Covers `flock/` and the neighboring shard `sdl3-cr/`.

## Flock

### Correctness / robustness (priority)
- [x] **Release GPU resources.** `Resource#release` (+ ordering) + `World#shutdown` called
      by `App#run`; `GpuContext`/`Renderer2D`/`Material`/`Texture` release their handles.
- [x] **Capture wgpu errors.** `Flock.request_device` creates the device with the
      `uncaptured error` + `device lost` callbacks (logged to STDERR); the runner calls
      `instance_process_events` per frame to flush them. Verified: an invalid buffer
      triggers `[wgpu][Validation]`.
- [x] **Recover a lost surface.** `Renderer2D#render` decodes the status of
      `surface_get_current_texture`: renders on `SuccessOptimal`/`Suboptimal`, reconfigures via
      `GpuContext#reconfigure_to_window` on `Outdated`/`Lost`, skips on Timeout/Error/transient.
- [x] **Automated rendering tests (readback).** `examples/readback_test.cr`: offscreen render
      → `copy_texture_to_buffer` → map → pixel assertions (red center / black corner), exit 0/1.
      `Renderer2D#render_into` separates rendering from surface acquisition. Already caught a
      real bug: `Sprite.size` was not applied to the model (1×1 quads).

### Missing features
- [x] **Mouse**: `Input#mouse_position` (framebuffer pixels, HiDPI) + `mouse_pressed?` /
      `just_pressed?` / `just_released?` (`MouseButton`), + `Camera2D#screen_to_world`. Verified
      (`spec/camera_spec.cr`, `examples/mouse_demo.cr`). Wheel exposed (`Input#mouse_wheel`,
      via events). Remaining: cursor (hide/capture/relative mode).
- [x] **Text / font rendering** via SDL_ttf: `Flock::Font.load` + `font.render_texture(gpu,
      text)` → `Texture` drawn as a sprite (tintable). Verified by `examples/text_test.cr`
      (readback); title integrated into Space Invaders. Remaining: per-string cache, glyph atlas.
- [x] **Per-sprite materials** — `SpriteMaterial` (built via `Renderer2D#build_material(wgsl)`)
      shares an explicit pipeline layout so a `Sprite#material` swaps the shader while reusing
      the uniform/instance/texture bind groups. Batched by (z, material, texture). Verified
      (`examples/material_test.cr`: custom fragment forces blue via readback).
- [x] **Fixed timestep**: `FixedUpdate` schedule run 0..N times/frame via an accumulator
      (`App#advance_fixed`, bounded by `MAX_FIXED_STEPS`), configurable fixed step
      (`app.fixed_dt=`/`fixed_hz`), `add_fixed_system`, `Time#fixed_delta`. Verified
      (`spec/app_spec.cr`, deterministic); Space Invaders movement moved to FixedUpdate.
- [x] **Events / states** Bevy-style: `Events(T)` per-type frame queue (`send_event`/
      `each_event`, `App#add_event` clears each frame) + `State(S)` machine (`add_state`,
      `set_state` deferred to next frame, `add_system_in_state`). Verified
      (`spec/events_state_spec.cr`); Space Invaders gained an Escape pause state with an
      OnEnter/OnExit "PAUSED" overlay. `add_on_enter`/`add_on_exit` run once per transition
      (OnEnter(initial) at startup). Events are double-buffered with per-reader cursors
      (`EventReader(T)`): each event read exactly once, across frames.
- [x] **Audio** volume/loop/stop: `play(sound, volume:, loop:)` returns a `Playback` handle;
      per-playback `volume` (`SDL_SetAudioStreamGain`) + `Audio#master_volume=`, `loop:` re-queues
      seamlessly, `stop(pb)`/`stop_all`. Verified (`examples/audio_test.cr`). Minor nuance left:
      one-shots are reclaimed at `queued==0` (input side), which can clip the very tail.
- [x] **Compressed music (OGG/MP3/FLAC/Opus)** via SDL3_mixer 3.x: `Flock::Music` resource
      (`MusicPlugin`, in DefaultPlugins) — `play(path, loop:, volume:)`/`pause`/`resume`/`stop`/
      `playing?`/`volume=`. Streams on the fly (`MIX_LoadAudio predecode=false`) on its own logical
      device; SDL mixes it with the SFX streams. Bound in sdl3-cr as `lib LibMIX`. Verified
      (`examples/music_test.cr`: plays an MP3 headless, asserts the track is playing). Remaining:
      route paths through `Assets`; crossfade between tracks.

### Convenience / architecture
- [x] **Bundles** (Bevy-style component groups): `include Flock::Bundle` + a `components`
      tuple; `spawn`/`add` expand it into the individual `SparseSet`s (bundles nest, and mix
      with plain components — `cmd.spawn(PlayerBundle.new(...), Velocity.new)`). Compile-time
      expansion (`{% if T < Flock::Bundle %}` in `World#add`), no runtime `Bundle` storage.
      Verified (`spec/bundle_spec.cr`); Space Invaders' player/invader/bullet spawns refactored
      into bundles. (Plugins already group systems/resources/asset-loading — the other half of
      the Bevy split.)
- [x] **System ordering** within a schedule: `add_system(schedule, label:, before:, after:,
      run_if:)` — stable topological sort by before/after labels, `run_if` gates a system
      (`add_system_in_state` now builds on it). Verified (`spec/system_order_spec.cr`).
- [x] **Asset manager** (`Flock::Assets`, via `AssetsPlugin`/DefaultPlugins): cache by key
      for textures (`texture(path)`), fonts (`font(path, size)`) and sounds (`sound(path)`) +
      `store_texture`; centralized release (`release`, before the device). Verified
      (`examples/assets_test.cr`); Space Invaders title routed via the cache.
- [x] **Multi-viewport / per-region clear**: each camera paints its own viewport with its own
      clear color via a scissored full-region quad (small no-blend clear pipeline). True
      split-screen. Verified (`examples/split_screen_test.cr` readback; `split_screen.cr` demo).
- [x] **Configurable sampler**: per-texture `filter` (Nearest/Linear) + `wrap` (Clamp/Repeat),
      passed to `Texture.from_pixels`/`load`; the renderer caches a GPU sampler per (filter, wrap).
      Verified (`examples/sampler_test.cr`: linear blends a 2×2 checker). Remaining: mipmap
      generation (needs level downsampling on upload).
- [x] **3D rendering** of meshes consuming `Camera3D`: `Mesh` (vertex/index buffers,
      `Mesh.cube`, `Mesh.sphere`) + `MeshRenderer`/`Transform3D` components + `Renderer3D`
      (per-mesh draw via a model storage buffer, depth buffer, directional lighting).
      **Per-mesh custom shaders** via `Renderer3D#build_material(wgsl)` → `Material3D` (assigned
      to `MeshRenderer#material`), sharing an explicit `group0` = camera + models + `globals`
      (exposes `time` for animation); draws grouped by material. Wired via `Render3DPlugin`.
      Verified (`examples/cube3d.cr`/`cube3d_test.cr`; `examples/solar_system/` — animated
      emissive sun + lit planets, with `readback_test.cr`). Remaining: normal matrix for
      non-uniform scale, mesh loading (glTF/OBJ), instanced meshes, unify 2D+3D in one frame.

## sdl3-cr

- [x] **Linking portability.** Moved from hardcoded `/opt/homebrew/lib` to
      `@[Link(pkg_config: "sdl3" / "sdl3-image" / "sdl3-ttf")]` annotations (portable macOS/Linux; Windows
      via vcpkg/msys2). Fallback to `-lSDL3*` if pkg-config is absent.
- [x] **Cross-platform surface setup.** `WindowPlugin#make_surface` dispatches per
      platform via `SDL_GetWindowProperties`: Metal (macOS), X11/Wayland (Linux, runtime
      detection via `SDL_GetCurrentVideoDriver`), HWND (Windows). macOS tested at runtime;
      Linux and Windows **verified via cross-compilation** (`crystal build --cross-compile`), not
      yet at runtime. Remaining: validate on real Linux/Windows machines.
- [x] **Expose event data.** `MouseWheelEvent` / `TextInputEvent` structs +
      type constants; the WindowPlugin runner dispatches events and routes wheel +
      text to `Input` (`mouse_wheel`, `text_input`, `start_text_input`). Verified
      (`examples/events_test.cr`, `events_demo.cr`). The infra makes it easy to add other types
      (event-driven keyboard/gamepad).
- [x] **Extend coverage.** Mouse, `SDL_SetAudioStreamGain` (audio volume), `SDL_RumbleGamepad`
      (`Gamepad#rumble`, used in Space Invaders), `SDL_GetVersion` (`SDL3.linked_version`) are
      bound. **Window events** (focus/minimize/maximize/restore/resize) are bound too:
      `EVENT_WINDOW_*` constants + a `WindowEvent` struct (data1/data2), routed by the runner
      into a `Flock::WindowState` resource (`focused?`/`minimized?`/`maximized?`/`resized?`).
      Verified (`examples/window_events.cr`); Space Invaders auto-pauses on focus loss.
- [x] **Fragile hardcoded constants.** The numeric constants (`INIT_*`/`WINDOW_*`/`EVENT_*`/
      `AUDIO_*`/`PIXELFORMAT_RGBA32`) are now **generated** into `src/sdl3/constants.cr` by
      `scripts/generate_constants.cr` (`shards run sdl3-gen`): it compiles a probe against the
      installed SDL3 (`pkg-config --cflags`) so the C compiler evaluates the macros/bit-shifts/
      endianness/event-enum numbering — no drift. Generated file is checked in (consumers need
      no compiler). Types/structs/funs stay handwritten in `src/sdl3.cr`.
- [x] **Sanity test.** `spec/sdl3_spec.cr` links SDL3 (pkg-config) and asserts a v3 runtime
      via `SDL3.linked_version` — detects a linking/ABI break.

## Diagnostics

- [ ] **Forward wgpu-native detailed logs.** The uncaptured-error callback only gives a terse
      "Validation Error"; wgpu-native's own log has the real cause (e.g. "Bytes per row does not
      respect COPY_BYTES_PER_ROW_ALIGNMENT"). Bind `wgpuSetLogCallback`/`wgpuSetLogLevel` and
      forward to STDERR (opt-in via env, e.g. `FLOCK_WGPU_LOG`).

## Web / WASM export (later)

Ship a Flock game as HTML/WebAssembly. Feasible but a real project, deferred.
- [ ] **Toolchain**: Crystal → browser WASM is proven by the `wesh` shard
      (`/Users/rajdeenoo/Documents/code/crystal/wesh`): `crystal-js` interop + `wasm-ld` +
      `wasm-opt` + WASI sysroot. Confirmed: Flock's **headless core** (math/ECS/app/time, no
      native deps) already cross-compiles to `wasm32-wasi`.
- [ ] **Blocker**: rendering (wgpu-native) and platform (SDL3) are **native libs**, unavailable
      in the browser. Need a browser backend: WebGPU (or WebGL2) on a `<canvas>`, DOM input +
      Web Gamepad API, WebAudio, `requestAnimationFrame` — all via `crystal-js` JS interop.
- [ ] **Approach**: write a `WebPlugins` backend paralleling `DefaultPlugins` (the plugin split
      keeps game/ECS code unchanged). `wesh` binds the DOM (not canvas/WebGPU), so it only
      helps with the toolchain + surrounding HTML UI, not the game rendering.
- [ ] **Incremental spike**: (1) run the ECS core in-browser via the wesh toolchain (no render,
      state to `console.log`); (2) minimal canvas-2D/WebGL2 sprite backend for Space Invaders;
      (3) then WebGPU for parity with the native backend.

## Remaining work (open)

All the big-ticket items above are done. What's left, gathered from the `Remaining:`
notes buried in the completed entries plus the two open sections:

### Standalone (own sections above)
- [ ] **Forward wgpu-native detailed logs** (Diagnostics) — bind `wgpuSetLogCallback`/
      `wgpuSetLogLevel`, opt-in via `FLOCK_WGPU_LOG`.
- [ ] **Web / WASM export** — deferred; real project (see the section above).

### Polish left on shipped features
- [ ] **Mouse**: cursor control (hide/capture/relative mode).
- [ ] **Text**: per-string texture cache + glyph atlas (currently one texture per render).
- [ ] **Sampler**: mipmap generation (needs level downsampling on upload).
- [ ] **3D**: normal matrix for non-uniform scale; mesh loading (glTF/OBJ); instanced meshes.
- [ ] **Audio**: one-shots are reclaimed at `queued==0` (input side), which can clip the tail.

### Cross-platform validation
- [ ] **sdl3-cr surface setup**: X11/Wayland/HWND are cross-compile-verified only; validate
      at runtime on real Linux/Windows machines.
