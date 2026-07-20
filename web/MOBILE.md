# flock-mobile — shipping a Flock game to iOS/Android

## Strategy

Flock's web target already runs the ECS core in **WebAssembly** and renders **2D** sprites in
the browser. To reach mobile we **package that web build in the system WebView** with **Capacitor**
(it generates real Xcode / Android Studio projects that wrap the WebView) and add a **WebGL2
fallback renderer** so it runs even where WebView WebGPU is unavailable.

This gives one 2D codebase → **web + App Store + Play Store**, reusing everything.

- **Rendering** stays browser-side: WebGPU when the WebView supports it, **WebGL2 otherwise**.
  Capacitor/Tauri/PWA all use the *system* WebView, so WebGPU availability is the same everywhere
  — the WebGL2 fallback, not the packager, is what unlocks reach (older iOS/Android).
- **Native (Metal/Vulkan via wgpu-native + SDL3) is a separate, later track** — it needs Crystal
  cross-compiled to arm64 iOS/Android (no official target yet) and would unlock 3D. Out of scope here.

## Compatibility reality (why the WebGL2 fallback matters)

- **WebGPU in the WebView**: iOS Safari/WKWebView gained WebGPU in iOS 18 and broadened through
  2025; Android WebView follows Chrome (WebGPU since Chrome 113). So **recent devices: yes**, older:
  no. WebGL2 is available on essentially every iOS 15+/Android 5+ WebView → the safety net.
- The renderer picks the best available backend at startup; the game code is unchanged.

## Steps (each its own commit)

1. **WebGL2 fallback renderer** *(the key unlock)*. Refactor `web/renderer.js` into a backend
   interface (`init` / `texture` / `draw` / `resize`) with two implementations — the existing
   WebGPU one and a new WebGL2 one (instanced textured quads, same instance format
   `{x,y,w,h}{r,g,b,a}{u,v,uw,uh}`, premultiplied-alpha blend, NPOT mipmaps). Auto-select WebGPU →
   WebGL2. The audio / text / gamepad / input / loop services stay backend-agnostic.

2. **Capacitor packaging**. A `web/mobile/` npm project with `capacitor.config`, pointing its
   `webDir` at the built `web/` bundle. `npx cap add ios` / `add android` generate the native
   projects; `npx cap sync` copies the build in. PWA manifest + `<meta viewport>` for standalone.

3. **Mobile UX**. Safe-area / notch (`viewport-fit=cover` + env() insets), orientation lock,
   fullscreen, disable page zoom/scroll; optional **on-screen virtual controls** (stick + buttons)
   that feed the same `flock_key`/`flock_gamepad` path the touch drag already uses.

4. **Tooling**. A `flock mobile build ios|android` command (in flock-cli) that runs the web build
   then `cap sync`, plus docs (`web/mobile/README.md`) for the one-time `cap add` + open-in-Xcode/
   Android-Studio + run-on-device flow.

## Verification

- WebGL2 backend: JS validated (`node --check`); rendered path checked in a browser (headless
  Chrome/SwiftShader if buildable here, else documented manual check) — the demo must draw
  identically under WebGL2 with `navigator.gpu` forced off.
- Capacitor: config validated; the native-project generation + device run is a manual step
  (needs Xcode/Android SDK), documented.

## Non-goals (for now)

- 3D on mobile (needs native wgpu-native/SDL3 + Crystal-on-mobile — the separate native track).
- Push notifications / IAP / native plugins (Capacitor can add them later if a game needs them).
