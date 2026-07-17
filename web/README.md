# Flock on the Web (WebAssembly + WebGPU)

A proof-of-concept web target for Flock. The **ECS core** (World/query/Component + math)
is compiled to **WebAssembly** and drives the simulation in the browser; rendering is done
with **WebGPU** (available in Chrome). The native backend (wgpu-native + SDL3) is not used
here — it's replaced by a thin browser backend.

```
web/main.cr      Crystal entry: Flock ECS runs in WASM, fills a sprite-instance buffer,
                 hands it to JS each frame (@[JS::Method] reads WASM memory).
web/renderer.js  WebGPU renderer: instanced quads, driven by the WASM instance data.
web/index.html   Canvas + module loader.
web/build.sh     Compiles main.cr → app.wasm + app.mjs (crystal-js toolchain).
```

## How it works

- Only Flock's **native-free core** (`require "../src/flock"`) is compiled — no wgpu/SDL.
  The demo defines its own `Body` component and movement system on `Flock::World`.
- Crystal↔JS interop uses [`crystal-js`](https://github.com/lbguilherme/crystal-js) (via the
  neighboring `wesh` shard): `JS.export` exposes `flock_init`/`flock_frame` to JS, and a
  `@[JS::Method]` reads the instance buffer out of WASM linear memory and calls the renderer.
- Each frame JS calls `flock_frame(dt_ms)` → the ECS steps and streams
  `{x,y,w,h, r,g,b,a}` per sprite → WebGPU draws them as instanced quads.

## Build

Requires `wasm-ld` + `wasm-opt` (+ `uglifyjs` for `--release`), and the `wesh` shard's
patched crystal-js (the WASI sysroot is fetched automatically on first build). `build.sh`
auto-discovers `wesh` via `$WESH` or common sibling paths.

```sh
web/build.sh                 # debug   → web/app.wasm + web/app.mjs (~982 KiB)
web/build.sh --release       # wasm-opt -Oz + JS mangle           (~156 KiB, ~50 KiB gzip)
```

## Run

WebGPU requires a secure context, so serve over HTTP (not `file://`) and open in Chrome:

```sh
web/dev.sh                 # dev server: serves web/, rebuilds on .cr changes, live-reloads
# or a plain static server:
cd web && python3 -m http.server 8000
# then open http://localhost:8000/ in Chrome
```

## Status

Done: ECS core in WASM; the `WebPlugins` backend (App/Plugin/Schedule reused from native);
WebGPU instanced-quad rendering with per-texture batching; textures (procedural, text, and
image files) with atlas UV sub-rects + mipmaps; keyboard + Web Gamepad + pointer/touch input;
WebAudio (oscillator beeps + decoded audio files); HiDPI; a `--release` build.

Controls (demo): arrow keys / gamepad left stick / drag to move the white square; Space (or
gamepad button 0) plays a sound.

Next (nice-to-have): glyph/text caching, audio volume/mixing parity, a shared Sprite/asset
abstraction so the identical source runs native + web, and a live-reload dev server.
