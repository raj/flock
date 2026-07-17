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
      emissive sun + lit planets + a 2D HUD overlay). Also done: **normal matrix** for
      non-uniform scale (`Mat4#normal_matrix`, group0 binding 3); **OBJ loading**
      (`Mesh.load_obj`, `examples/obj_test.cr`); **instanced meshes** (draws grouped by
      (mesh, material), one instanced `draw_indexed` per group, `examples/instancing_test.cr`);
      **unified 2D+3D in one frame** (`Render2D3DPlugin`: 3D scene then 2D overlay, one present;
      `Renderer2D#render_into load_previous:`, `examples/render_2d3d_test.cr`); **glTF loading**
      (`Mesh.load_gltf` — `.gltf` with `.bin`/base64 data-URI buffers and binary `.glb`;
      POSITION/NORMAL/indices via accessors/bufferViews, `examples/gltf_test.cr`);
      **frustum culling** (per-mesh bounding sphere via `Mesh.build`; `Flock::Frustum` extracts
      6 planes from the view-projection and drops off-screen instances; `Renderer3D#last_drawn`/
      `last_culled`, toggle via `#cull`; `examples/culling_test.cr`, `spec/math_spec`).
      **glTF enrichment**: node transforms baked (TRS/matrix hierarchy), material
      `baseColorFactor` per primitive (`examples/gltf_nodes_test.cr`), and **base-color
      textures** — vertices carry UVs (STRIDE 44), Renderer3D has a group1 texture/sampler +
      white default, `MeshRenderer#texture`, `Mesh.load_gltf_textured` extracts the image
      (external / data-URI / bufferView) via `Texture.from_encoded` (sdl3-cr `IMG_Load_IO`).
      Verified (`examples/texture3d_test.cr`, `gltf_texture_test.cr`). **Per-instance params**:
      `MeshRenderer#tint` (rgba) feeds a per-instance storage buffer (group0 binding 4); many
      entities share one mesh/material/texture yet render in different colors within a single
      instanced draw (`examples/instance_tint_test.cr`; solar-system planets now share one
      sphere, tinted per planet). **PBR**: the built-in shader is metallic-roughness (GGX
      specular + Fresnel) with a base-color texture, a metallic-roughness map (G=rough, B=metal)
      and a tangent-space normal map (derivative TBN — no stored tangents); `MeshRenderer`
      carries the maps + `metallic`/`roughness` factors (per-instance). `Mesh.load_gltf_pbr`
      extracts all three maps + factors from a glTF material. Verified (`examples/pbr_test.cr`,
      `gltf_pbr_test.cr`). **glTF node animation**: `Mesh.load_gltf_scene` keeps the node
      hierarchy (geometry unbaked, one Mesh per mesh-node) and parses TRS keyframe animations
      (LINEAR/STEP, quaternion nlerp); `Flock::AnimatedModel` spawns an entity per node and
      `update`/`apply` writes each node's world matrix into a `Transform3D#matrix_override`.
      Verified (`examples/anim_test.cr`). **Skinning (CPU)**: `load_gltf_scene` parses `skins`
      (joints + inverse-bind matrices) and per-vertex JOINTS_0/WEIGHTS_0; `Flock::SkinnedModel`
      computes joint matrices from the animated hierarchy each frame and rewrites the mesh
      vertex buffer on the CPU (Σ weight · jointMatrix · bindVertex) — reuses the whole existing
      pipeline (no skinned shader). Verified (`examples/skinning_test.cr`). Animation
      interpolation covers STEP, LINEAR (quaternion nlerp along the shorter arc) and
      **CUBICSPLINE** (Hermite with in/out tangents; `examples/cubicspline_test.cr`).
      **Ambient probe**: `Flock::AmbientLight` (hemisphere sky/ground by world normal) tints
      the PBR ambient term — a cheap IBL stand-in; neutral gray when absent
      (`examples/ambient_test.cr`). **GPU skinning**: `Flock::GpuSkinnedModel` + a dedicated
      skinned pipeline (2nd vertex buffer for joints/weights, joint matrices in group2) skin
      pos/normal in the vertex shader; only joint matrices upload per frame. Additive — the
      rigid path is untouched. Matches CPU skinning pixel-for-pixel (`examples/skinning_gpu_test.cr`).
      **Prefiltered IBL**: `Renderer3D#build_ibl` CPU-precomputes an irradiance cubemap
      (diffuse), a roughness-mip prefiltered specular cubemap and a BRDF LUT from a
      sky/horizon/ground environment; the PBR shader samples them (split-sum) via group2 when
      an `IblEnvironment` resource is present (flagged in globals; hemisphere ambient otherwise
      → no regression). Verified (`examples/ibl_test.cr`: a metallic sphere reflects the env).
      **The planned 3D roadmap above is complete; genuinely-missing 3D features are tracked
      in "3D — remaining" below.**

### 3D — remaining (not yet in the engine)

Real 3D features never planned, ordered by rendering impact. Confirmed absent in the code.

- [x] **Lighting system.** `Light` components (directional / point / spot) with color,
      intensity, range and spot cones. Attach a `Light` (+ `Transform3D` for position) to any
      entity; `Renderer3D` packs them into a lights storage buffer (group0 binding 5, up to
      `MAX_LIGHTS = 16`) and the PBR shader loops over them with per-light attenuation and spot
      falloff. With no `Light` entities the shader keeps its legacy hard-coded directional light,
      so existing scenes/tests are unchanged. See `examples/lights_test.cr` (directional/point/spot
      readbacks verified).
- [x] **Shadows (shadow mapping).** Directional shadow caster: set `casts_shadows: true` on a
      directional `Light`. `Renderer3D` fits an orthographic light frustum to the drawn scene AABB,
      renders a depth-only pass into a 2048² `Depth32Float` shadow map (`SHADOW_WGSL`), and the PBR
      shader (group3: light-vp + `texture_depth_2d` + `sampler_comparison`) applies a 3×3 PCF shadow
      factor to that light only. No caster → group3 is bound but unused, so lit/legacy scenes are
      unchanged. See `examples/shadow_test.cr` (shadows-on vs -off readback). *Spot/point shadows and
      shadow-frustum fitting to off-screen casters are future work.*
- [x] **Transparency / alpha blending.** Set `transparent: true` on a `MeshRenderer`. Opaque
      meshes still batch/instance as before; translucent ones are collected separately, sorted
      back-to-front by camera distance, and drawn after all opaque geometry with a blended
      pipeline variant (standard `SrcAlpha`/`OneMinusSrcAlpha`, depth test on, depth-write off).
      `tint`/base-texture alpha drives opacity. See `examples/transparency_test.cr` (transparent
      vs opaque readback proving the panel behind shows through). *Transparent meshes don't cast
      shadows and always use the built-in shader (custom materials render opaque) — future work.*
- [x] **Anti-aliasing (MSAA).** Configurable sample count on `Renderer3D` (`Render3DPlugin`
      defaults to 4×; `sample_count: 1` disables). When on, all rigid/transparent/skinned pipelines
      and the depth buffer are multisampled, geometry renders into an internal MSAA color target
      and resolves into the frame target each frame. `sample_count = 1` keeps the direct
      (non-resolved) path, so readback tests are unchanged. The shadow depth pass stays single-sample.
      See `examples/msaa_test.cr` (0 partial-coverage edge pixels aliased vs 220 at 4×).
- [x] **Native texture mipmaps.** `Texture.from_pixels` / `from_surface` take `mipmaps:`; a full
      box-filtered mip chain is generated on the CPU and each level uploaded via `queue_write_texture`
      (no extra usage / render pass). `Texture.load` and `from_encoded` (real images / glTF textures)
      default to `mipmaps: true`; procedural/1×1 textures stay single-mip. The 3D sampler's
      `lod_max_clamp` was raised so the whole chain is usable (single-mip textures still sample
      level 0). See `examples/mipmap_test.cr` (minified checkerboard variance 3065 → 0 with mips).
- [x] **Post-processing / tonemapping.** Opt-in via `Renderer3D`/`Render3DPlugin` `tonemap:`
      (`Tonemap::Aces` / `Reinhard`; `None` = the direct LDR path). When on, geometry renders to an
      HDR `rgba16float` target (MSAA resolves into it) and a fullscreen triangle pass tonemaps it into
      the frame target. `None` keeps the byte-for-byte LDR path (all readbacks unchanged). See
      `examples/postprocess_test.cr` (a bright light blows 6852 pixels to white without tonemapping
      vs 0 with ACES). *Bloom / FXAA / exposure control remain as future extensions of the post pass.*
- [~] **glTF completeness.** Loaded today: POSITION/NORMAL/TEXCOORD_0/JOINTS/WEIGHTS, base-color +
      metallic-roughness + normal maps, `baseColorFactor`/`metallicFactor`/`roughnessFactor`, node
      TRS animation + skinning. **Done:** **emissive** (map + `emissiveFactor`) + **occlusion**
      textures, **alpha modes** — `alphaMode: BLEND` maps to the transparent pass, `MASK` to a shader
      alpha-cutoff discard (`MeshRenderer#emissive`/`emissive_factor`/`occlusion`/`alpha_cutoff`;
      `Mesh.load_gltf_pbr` reads them). See `examples/gltf_material_test.cr`. **Scene import:**
      `Mesh.load_gltf_lights` imports `KHR_lights_punctual` (directional/point/spot with color,
      intensity, range, spot cones) as posed `Light`s; `Mesh.load_gltf_cameras` imports glTF cameras
      as `Camera3D`s (world pose, yfov/near/far). See `examples/gltf_scene_import_test.cr`.
      **Morph targets:** `load_gltf_scene` parses primitive `targets` (POSITION + NORMAL deltas)
      and `weights` animation channels; `MorphModel` CPU-blends `base + Σ weight[i]·target[i]` and
      re-uploads the vertex buffer each frame (see `examples/morph_test.cr`). **Not yet:** multiple
      UV sets, vertex colors on skinned meshes, GPU morph blending, other KHR extensions.
- [~] **Camera / misc polish.** **Done:** `OrbitCamera` (arcball: target/distance/yaw/pitch, dolly,
      clamps) and `FlyCamera` (position/yaw/pitch, WASD move + mouse look) controller helpers — pure,
      input-agnostic structs that write into a `Camera3D` (see `spec/camera_controller_spec.cr` and
      `examples/orbit_camera.cr`). Skinned normals now use the inverse-transpose of the skin 3×3
      (correct under non-uniform scale, was approximate). **Not yet:** frustum culling of
      skinned/animated meshes still uses the bind-pose bounds (can mis-cull when heavily deformed).

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

- [x] **Forward wgpu-native detailed logs.** wgpu-cr binds `wgpuSetLogCallback`/`wgpuSetLogLevel`
      (wgpu.h extras) + `WGPU.set_log_stderr(level)`. Flock forwards the internal log to STDERR
      opt-in via `FLOCK_WGPU_LOG` (`trace`/`debug`/`info`/`warn`/`error`, or `1`=warn), set once
      from `Flock.request_device` so headless/readback usage is covered too. This surfaces the
      real cause behind terse "Validation Error" messages. Default (unset): no output.

## Web / WASM export (`web/`, branch `web-wasm`)

Ship a Flock scene as HTML/WebAssembly. **Working spike done** (`web/`):
- [x] **Toolchain**: `web/build.sh` compiles Flock's native-free core to `wasm32-wasi` via the
      `wesh` shard's patched `crystal-js` (`wasm-ld` + `wasm-opt` + auto WASI sysroot) →
      `app.wasm` + `app.mjs`.
- [x] **ECS in the browser**: `web/main.cr` runs `Flock::World`/query/Component + math in WASM;
      each frame it fills a sprite-instance buffer and hands it to JS via a `@[JS::Method]` that
      reads WASM linear memory. `JS.export` exposes `flock_init`/`flock_frame`.
- [x] **WebGPU renderer**: `web/renderer.js` draws the instances as instanced quads with WebGPU
      (Chrome). Verified end-to-end in Chrome (screenshotted).
- [x] **WebPlugins backend** (`web/web_backend.cr`): parallels `DefaultPlugins` — reuses the
      native-free App/Plugin/Schedule/World/Time core and adds browser equivalents (2D sprite
      components, a keyboard `Input` resource fed from DOM events, a `Render`-schedule system
      that streams instances to WebGPU). Games keep the native structure: `App.new
      .add_plugin(WebPlugins.new).add_startup{…}.add_system(Update){…}`, driven from
      requestAnimationFrame. `web/main.cr` demos it (bouncing squares + arrow-key player);
      verified in Chrome (input moves the player). One glue fix: `build.sh` patches the
      generated `clock_time_get` to refresh a detached memory view after WASM heap growth.
- [x] **Textures + text**: `Sprite#texture` (a renderer texture id); the render system groups
      sprites by texture and the WebGPU renderer draws one batch per texture. `Flock::Web
      .checkerboard` (procedural) and `.make_text(str)` (rasterized on a 2D canvas → texture)
      register textures. Verified in Chrome (checkerboard sprites + a "FLOCK · WEB" text banner).
- [x] **Web Gamepad**: `renderer.js` polls `navigator.getGamepads()` each frame → `flock_gamepad`
      → the `Input` resource (`gamepad_x/y`, `gamepad_button?`); the demo player also moves with
      the left stick. (Wired + headless-validated; a physical pad isn't exercised in CI.)
- [x] **WebAudio**: `Flock::Web.beep(freq, ms)` plays a WebAudio oscillator (AudioContext created
      on the first key gesture per autoplay policy). The demo beeps on Space / gamepad button 0.
- [x] **Shared components**: `Color` + `Transform2D/3D` are now native-free core
      (`src/flock/{color,transform}.cr`) used by both targets; web uses `Flock::Transform2D` +
      `Flock::Color` (only `Flock::Web::Sprite`, which carries a texture id, stays web-specific).
- [x] **Atlas UV + mipmaps**: `Sprite#uv_min/uv_size` (sub-rect sampling); textures upload with a
      GPU-generated mip chain (verified in Chrome: a sprite showing a UV quarter of a test image).
- [x] **Load files**: `Flock::Web.load_image(url)` (fetch → `createImageBitmap`, async, mipmapped)
      and `load_sound(url)`/`play_sound(id)` (fetch → `decodeAudioData`). Demo loads
      `assets/sprite.png` + `assets/blip.wav`.
- [x] **Input/display**: pointer/touch drag → directional movement; HiDPI canvas
      (`devicePixelRatio` backing store) + window resize handling.
- [x] **Packaging**: `web/build.sh` auto-discovers the `wesh` checkout ($WESH or common paths),
      reports wasm/gzip size, and supports `--release` (wasm-opt -Oz + JS mangle): ~156 KiB /
      ~50 KiB gzip vs ~982 KiB debug.
- [x] **Glyph/text cache**: `make_text` reuses one texture per repeated string.
- [x] **Audio parity**: `play_sound(id, volume, loop)` → handle, `stop_sound`, `master_volume`,
      mixing through a master GainNode.
- [x] **Live-reload dev server**: `web/dev.mjs`/`dev.sh` serve + watch + rebuild on `.cr` + SSE reload.
- [x] **Shared source on both targets**: `Flock::Sprite2D` (native-free, texture = an id) is rendered
      by both the native `Renderer2D` (via a texture bank + `register_texture`) and the web backend.
      `examples/shared_scene.cr` (components + spawn + system, core-only, with an injected texture
      loader) runs unchanged on native (`examples/shared_scene_native.cr`) and web (`web/main.cr`).
      Verified: native `examples/sprite2d_test.cr` (readback) + web (Chrome). **Web target: feature-complete.**
      (Only cosmetic gap left: the native `Camera2D` is y-up / origin-center vs the web's top-left, so
      framing is vertically mirrored — a shared 2D coordinate convention would unify it.)
      wgpu-native + SDL3 remain native-only.

## Remaining work (open)

All the big-ticket items above are done. What's left, gathered from the `Remaining:`
notes buried in the completed entries plus the two open sections:

### Standalone (own sections above)
- [x] **Forward wgpu-native detailed logs** (Diagnostics) — done, opt-in via `FLOCK_WGPU_LOG`.
- [ ] **Web / WASM export** — deferred; real project (see the section above).

### Polish left on shipped features
- [ ] **Mouse**: cursor control (hide/capture/relative mode).
- [ ] **Text**: per-string texture cache + glyph atlas (native side; web already caches).
- [ ] **3D**: see the dedicated **"3D — remaining"** section. Lighting, directional shadow
      mapping, transparency, MSAA, native mipmaps, HDR post-processing/tonemapping, glTF
      material completeness (emissive/occlusion/alpha modes) and camera controllers + skinned
      normal matrix are done. Left: glTF morph targets / multiple UVs / `KHR_lights_punctual`,
      and deformed-mesh frustum culling.
- [ ] **Audio**: one-shots are reclaimed at `queued==0` (input side), which can clip the tail.

### Cross-platform validation
- [ ] **sdl3-cr surface setup**: X11/Wayland/HWND are cross-compile-verified only; validate
      at runtime on real Linux/Windows machines.
