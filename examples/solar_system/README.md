# Solar System — 3D example

A glowing sun and six orbiting planets, rendered in 3D with per-object custom shaders.

```sh
crystal run examples/solar_system/main.cr
WGPU_FRAMES=180 crystal run examples/solar_system/main.cr   # headless smoke
crystal run examples/solar_system/readback_test.cr          # offscreen pixel check (exit 0/1)
```

## What it shows

- **Unified 2D + 3D** via `Render2D3DPlugin`: the 3D scene (`Renderer3D` + `Camera3D`)
  is drawn first, then a 2D HUD overlay (`Renderer2D` + `Camera2D`, a translucent banner)
  on top, presented as one frame.
- **Sphere meshes** (`Mesh.sphere`) for the sun and planets.
- **Custom shaders** (`Renderer3D#build_material` → `Material3D`, assigned to
  `MeshRenderer#material`):
  - the **sun** uses an emissive, animated shader (turbulence driven by `globals.time`);
  - the **planets** use directional lighting + procedural latitude bands.
  Every material shares the renderer's `group0` (camera + model matrices + `globals`),
  so custom WGSL only has to declare those three bindings and the pos/normal/color
  vertex inputs.
- **ECS-driven motion**: an `Orbit` component holds each body's orbit radius/speed and
  self-spin; an Update system advances them; the camera slowly circles the scene.
