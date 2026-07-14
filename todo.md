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
- [ ] **Events / states** Bevy-style (`Events` inter-system, game state machine).
- [ ] **Audio**: `play` creates a stream per playback and reclaims it at `queued==0`, which can
      cut off the tail of the sound; add volume (`SDL_SetAudioStreamGain`), looping music, `stop`.

### Convenience / architecture
- [ ] **System ordering** within a schedule (labels, `before`/`after`, `run_if` conditions).
- [x] **Asset manager** (`Flock::Assets`, via `AssetsPlugin`/DefaultPlugins): cache by key
      for textures (`texture(path)`), fonts (`font(path, size)`) and sounds (`sound(path)`) +
      `store_texture`; centralized release (`release`, before the device). Verified
      (`examples/assets_test.cr`); Space Invaders title routed via the cache.
- [ ] **Multi-viewport / per-region clear**: the clear covers the whole attachment → a viewport
      cannot clear in its own color (true split-screen: scissor or separate passes).
- [ ] **Configurable sampler** (linear vs nearest, mipmaps) — currently nearest only.
- [x] **3D rendering** of meshes consuming `Camera3D`: `Mesh` (vertex/index buffers,
      `Mesh.cube`) + `MeshRenderer`/`Transform3D` components + `Renderer3D` (per-mesh draw via a
      model storage buffer, depth buffer, directional lighting). Verified (`examples/cube3d.cr`,
      `cube3d_test.cr` readback). Remaining: normal matrix for non-uniform scale, mesh loading
      (glTF/OBJ), instanced meshes.

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
- [ ] **Extend coverage** as Flock needs: mouse, `SDL_SetAudioStreamGain`,
      `SDL_RumbleGamepad`, window events (focus/minimize), `SDL_GetVersion`.
- [ ] **Fragile hardcoded constants.** `PIXELFORMAT_RGBA32`, event values… are frozen
      (and little-endian). Bind `SDL_GetVersion` + a sanity spec; ideally a generator
      from the headers (like wgpu-cr).
- [ ] **No tests.** Minimal headless spec (`SDL_Init(0)` + version) to detect a
      linking/ABI break.

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

## Suggested next steps

- **Reliability track**: (1) resource release + wgpu error callback, (2) pixel-readback
  rendering test, (3) mouse.
- **Expansion track**: (1) sdl3-cr linking portability (Linux/Windows), (2) text
  rendering, (3) per-sprite materials.
