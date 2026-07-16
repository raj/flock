// WebGPU renderer + browser services for the Flock web backend. The ECS (WASM, see
// web_backend.cr + main.cr) computes sprite instances and calls globalThis.__flockDraw;
// we draw them as instanced textured quads with WebGPU (Chrome). Also exposes texture /
// text-rasterization / WebAudio / gamepad helpers used by the WASM side.
import init, { flock_init, flock_frame, flock_key, flock_gamepad } from "./app.mjs";

const WIDTH = 800, HEIGHT = 600, MAX = 512;
let device, context, pipeline, instanceBuf, uniformBuf, group0, format, sampler;
const textures = []; // id -> { bindGroup }  (id 0 = solid white)

async function initGPU() {
  if (!navigator.gpu) throw new Error("WebGPU unavailable — use Chrome (or a WebGPU-enabled browser).");
  const adapter = await navigator.gpu.requestAdapter();
  device = await adapter.requestDevice();

  const canvas = document.getElementById("c");
  canvas.width = WIDTH; canvas.height = HEIGHT;
  context = canvas.getContext("webgpu");
  format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: "premultiplied" });

  const shader = device.createShaderModule({ code: `
    struct Globals { size : vec2<f32> };
    @group(0) @binding(0) var<uniform> g : Globals;
    @group(0) @binding(1) var<storage, read> inst : array<vec4<f32>>;
    @group(1) @binding(0) var tex : texture_2d<f32>;
    @group(1) @binding(1) var samp : sampler;

    struct VSOut { @builtin(position) pos : vec4<f32>, @location(0) uv : vec2<f32>, @location(1) color : vec4<f32> };

    @vertex
    fn vs(@builtin(vertex_index) vi : u32, @builtin(instance_index) ii : u32) -> VSOut {
      var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0),
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 1.0));
      let rect = inst[ii * 2u];        // x, y, w, h (pixels, top-left origin)
      let col  = inst[ii * 2u + 1u];   // r, g, b, a
      let c = corners[vi];
      let p = rect.xy + c * rect.zw;
      let ndc = vec2<f32>(p.x / g.size.x * 2.0 - 1.0, 1.0 - p.y / g.size.y * 2.0);
      var o : VSOut;
      o.pos = vec4<f32>(ndc, 0.0, 1.0);
      o.uv = c;
      o.color = col;
      return o;
    }

    @fragment
    fn fs(i : VSOut) -> @location(0) vec4<f32> {
      let t = textureSample(tex, samp, i.uv);
      let c = i.color * t;
      return vec4<f32>(c.rgb * c.a, c.a);   // premultiplied
    }
  ` });

  pipeline = device.createRenderPipeline({
    layout: "auto",
    vertex: { module: shader, entryPoint: "vs" },
    fragment: {
      module: shader, entryPoint: "fs",
      targets: [{ format, blend: {
        color: { srcFactor: "one", dstFactor: "one-minus-src-alpha" },
        alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha" },
      } }],
    },
    primitive: { topology: "triangle-list" },
  });

  sampler = device.createSampler({ magFilter: "linear", minFilter: "linear" });
  uniformBuf = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  device.queue.writeBuffer(uniformBuf, 0, new Float32Array([WIDTH, HEIGHT, 0, 0]));
  instanceBuf = device.createBuffer({ size: MAX * 8 * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
  group0 = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [{ binding: 0, resource: { buffer: uniformBuf } }, { binding: 1, resource: { buffer: instanceBuf } }],
  });

  // Texture id 0 = 1x1 white (solid color path).
  registerTexture(1, 1, new Uint8Array([255, 255, 255, 255]));
}

// Uploads RGBA8 pixels as a texture, builds its group1 bind group, returns the id.
function registerTexture(w, h, rgba) {
  const tex = device.createTexture({
    size: [w, h, 1], format: "rgba8unorm",
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
  });
  device.queue.writeTexture({ texture: tex }, rgba, { bytesPerRow: w * 4, rowsPerImage: h }, [w, h, 1]);
  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(1),
    entries: [{ binding: 0, resource: tex.createView() }, { binding: 1, resource: sampler }],
  });
  const id = textures.length;
  textures.push({ bindGroup });
  return id;
}

// --- Services the WASM side calls (via @[JS::Method]) ---

globalThis.__flockCheckerboard = () => {
  const N = 64, cell = 8, px = new Uint8Array(N * N * 4);
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    const on = ((x / cell | 0) + (y / cell | 0)) % 2 === 0;
    const o = (y * N + x) * 4, v = on ? 235 : 120;
    px[o] = v; px[o + 1] = v; px[o + 2] = 255; px[o + 3] = 255;
  }
  return registerTexture(N, N, px);
};

globalThis.__flockMakeText = (text) => {
  const cv = document.createElement("canvas");
  const ctx = cv.getContext("2d");
  ctx.font = "bold 44px system-ui, sans-serif";
  const w = Math.max(1, Math.ceil(ctx.measureText(text).width) + 16), h = 60;
  cv.width = w; cv.height = h;
  const c2 = cv.getContext("2d");
  c2.font = "bold 44px system-ui, sans-serif";
  c2.textBaseline = "middle";
  c2.fillStyle = "white";
  c2.fillText(text, 8, h / 2);
  const img = c2.getImageData(0, 0, w, h);
  return registerTexture(w, h, new Uint8Array(img.data.buffer));
};

let audioCtx = null;
globalThis.__flockBeep = (freq, ms) => {
  if (!audioCtx) return;
  const t = audioCtx.currentTime;
  const osc = audioCtx.createOscillator(), gain = audioCtx.createGain();
  osc.frequency.value = freq; osc.type = "square";
  gain.gain.setValueAtTime(0.15, t);
  gain.gain.exponentialRampToValueAtTime(0.001, t + ms / 1000);
  osc.connect(gain).connect(audioCtx.destination);
  osc.start(t); osc.stop(t + ms / 1000);
};

globalThis.__flockDraw = (floats, count, groups) => {
  if (count > 0) device.queue.writeBuffer(instanceBuf, 0, floats, 0, count * 8);
  const enc = device.createCommandEncoder();
  const pass = enc.beginRenderPass({
    colorAttachments: [{
      view: context.getCurrentTexture().createView(),
      clearValue: { r: 0.04, g: 0.04, b: 0.07, a: 1 }, loadOp: "clear", storeOp: "store",
    }],
  });
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, group0);
  let offset = 0;
  for (let gi = 0; gi < groups.length; gi += 2) {
    const texId = groups[gi], n = groups[gi + 1];
    if (n <= 0) continue;
    const t = textures[texId] || textures[0];
    pass.setBindGroup(1, t.bindGroup);
    pass.draw(6, n, 0, offset);
    offset += n;
  }
  pass.end();
  device.queue.submit([enc.finish()]);
};

function pollGamepad() {
  const gps = navigator.getGamepads ? navigator.getGamepads() : [];
  const gp = gps && gps[0];
  if (!gp) { flock_gamepad(0, 0, 0, 0); return; }
  const ax = Math.round((gp.axes[0] || 0) * 1000), ay = Math.round((gp.axes[1] || 0) * 1000);
  let mask = 0;
  gp.buttons.forEach((b, i) => { if (i < 16 && b.pressed) mask |= (1 << i); });
  flock_gamepad(ax, ay, mask, 1);
}

async function main() {
  const status = document.getElementById("status");
  try {
    await initGPU();
    await init();
    flock_init();
    status.textContent = "running — textured sprites + text · arrow keys / gamepad move · Space beeps";

    const key = (e, down) => {
      if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      if ([32, 37, 38, 39, 40].includes(e.keyCode)) { flock_key(e.keyCode, down); e.preventDefault(); }
    };
    window.addEventListener("keydown", (e) => key(e, 1));
    window.addEventListener("keyup", (e) => key(e, 0));

    let last = performance.now();
    const loop = (now) => {
      const dt = Math.min(50, now - last); last = now;
      pollGamepad();
      flock_frame(Math.round(dt));
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  } catch (e) {
    status.textContent = "error: " + e.message;
    console.error(e);
  }
}

main();
