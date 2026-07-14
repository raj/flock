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
- [ ] **Per-sprite materials** — `Material` only does fullscreen; the renderer has a single
      pipeline. Allow a `Sprite` to reference a custom material (batch by material
      then texture).
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
- [ ] **3D rendering** of meshes consuming `Camera3D` (the perspective/look_at math is ready).

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

## Suggested next steps

- **Reliability track**: (1) resource release + wgpu error callback, (2) pixel-readback
  rendering test, (3) mouse.
- **Expansion track**: (1) sdl3-cr linking portability (Linux/Windows), (2) text
  rendering, (3) per-sprite materials.
