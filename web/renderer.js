// WebGPU renderer for the Flock web demo. The ECS (compiled to WebAssembly, see
// main.cr) computes the sprite instances each frame and hands us a Float32Array via
// globalThis.__flockDraw; we draw them as instanced quads with WebGPU (Chrome).
import init, { flock_init, flock_frame, flock_key } from "./app.mjs";

const WIDTH = 800, HEIGHT = 600, MAX = 220;
let device, context, pipeline, instanceBuf, uniformBuf, bindGroup, format;

async function initGPU() {
  if (!navigator.gpu) throw new Error("WebGPU unavailable — use Chrome (or a WebGPU-enabled browser).");
  const adapter = await navigator.gpu.requestAdapter();
  device = await adapter.requestDevice();

  const canvas = document.getElementById("c");
  canvas.width = WIDTH; canvas.height = HEIGHT;
  context = canvas.getContext("webgpu");
  format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "opaque" });

  // Instanced quads: geometry lives in the shader (6 vertices), per-instance
  // {x,y,w,h} + {r,g,b,a} come from a storage buffer indexed by instance_index.
  const shader = device.createShaderModule({ code: `
    struct Globals { size : vec2<f32> };
    @group(0) @binding(0) var<uniform> g : Globals;
    @group(0) @binding(1) var<storage, read> inst : array<vec4<f32>>;

    struct VSOut { @builtin(position) pos : vec4<f32>, @location(0) color : vec4<f32> };

    @vertex
    fn vs(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> VSOut {
      var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 1.0));
      let rect = inst[ii * 2u];        // x, y, w, h (pixels, top-left origin)
      let col  = inst[ii * 2u + 1u];   // r, g, b, a
      let p = rect.xy + corners[vi] * rect.zw;
      let ndc = vec2<f32>(p.x / g.size.x * 2.0 - 1.0, 1.0 - p.y / g.size.y * 2.0);
      var o : VSOut;
      o.pos = vec4<f32>(ndc, 0.0, 1.0);
      o.color = col;
      return o;
    }

    @fragment
    fn fs(i : VSOut) -> @location(0) vec4<f32> { return i.color; }
  ` });

  pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: { module: shader, entryPoint: "vs" },
    fragment: { module: shader, entryPoint: "fs", targets: [{ format }] },
    primitive: { topology: "triangle-list" },
  });

  uniformBuf = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  device.queue.writeBuffer(uniformBuf, 0, new Float32Array([WIDTH, HEIGHT, 0, 0]));
  instanceBuf = device.createBuffer({ size: MAX * 8 * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
  bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [
      { binding: 0, resource: { buffer: uniformBuf } },
      { binding: 1, resource: { buffer: instanceBuf } },
    ],
  });
}

// Called from WASM (main.cr push_frame) with the per-frame instance data.
globalThis.__flockDraw = (floats, count) => {
  device.queue.writeBuffer(instanceBuf, 0, floats, 0, count * 8);
  const enc = device.createCommandEncoder();
  const pass = enc.beginRenderPass({
    colorAttachments: [{
      view: context.getCurrentTexture().createView(),
      clearValue: { r: 0.04, g: 0.04, b: 0.07, a: 1 },
      loadOp: "clear", storeOp: "store",
    }],
  });
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.draw(6, count, 0, 0);
  pass.end();
  device.queue.submit([enc.finish()]);
};

async function main() {
  const status = document.getElementById("status");
  try {
    await initGPU();
    await init();   // instantiate the WASM module
    flock_init();   // run the App's Startup schedule (spawns the scene)
    status.textContent = "running — App/ECS in WASM · WebGPU render · arrow keys move the white square";

    // Forward keyboard to the WebPlugins Input resource (arrow keys / space).
    const key = (e, down) => {
      if ([32, 37, 38, 39, 40].includes(e.keyCode)) { flock_key(e.keyCode, down); e.preventDefault(); }
    };
    window.addEventListener("keydown", (e) => key(e, 1));
    window.addEventListener("keyup", (e) => key(e, 0));
    let last = performance.now();
    const loop = (now) => {
      const dt = Math.min(50, now - last); last = now;
      flock_frame(Math.round(dt)); // steps the ECS, then calls __flockDraw
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  } catch (e) {
    status.textContent = "error: " + e.message;
    console.error(e);
  }
}

main();
