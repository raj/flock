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

Requires `wasm-ld` + `wasm-opt`, and the [`wesh`](../../..) shard's patched crystal-js
(the WASI sysroot is fetched automatically on first build). If `wesh` lives elsewhere,
set `WESH=/path/to/wesh`.

```sh
web/build.sh                 # → web/app.wasm + web/app.mjs
```

## Run

WebGPU requires a secure context, so serve over HTTP (not `file://`) and open in Chrome:

```sh
cd web && python3 -m http.server 8000
# open http://localhost:8000/  in Chrome
```

## Status / next steps

Done: ECS core in WASM, per-frame instance streaming, WebGPU instanced-quad renderer.
Next: a `WebPlugins` backend paralleling `DefaultPlugins` (so unchanged game code runs on
either target), textures/text, DOM input + Web Gamepad API, and WebAudio.
