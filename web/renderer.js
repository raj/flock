// WebGPU renderer + browser services for the Flock web backend. The ECS (WASM) computes
// sprite instances and calls globalThis.__flockDraw; we draw them as instanced textured
// quads (with UV sub-rects / atlas support) using WebGPU. Also exposes procedural + file
// texture loading (with mipmaps), text rasterization, WebAudio (beeps + decoded files),
// and Web Gamepad polling used by the WASM side.
import init, { flock_init, flock_frame, flock_key, flock_gamepad } from "./app.mjs";

const WIDTH = 800, HEIGHT = 600, MAX = 512, FLOATS = 12;
let device, context, pipeline, instanceBuf, uniformBuf, group0, format, sampler;
let mipPipeline, mipSampler, audioCtx, masterGain;
const textures = [];        // id -> { bindGroup }  (id 0 = solid white)
const sounds = [];          // id -> AudioBuffer | null
const textCache = new Map(); // text string -> texture id (glyph cache)
const playing = new Map();   // handle -> AudioBufferSourceNode
let handleSeq = 1;

async function initGPU() {
  if (!navigator.gpu) throw new Error("WebGPU unavailable — use Chrome (or a WebGPU-enabled browser).");
  const adapter = await navigator.gpu.requestAdapter();
  device = await adapter.requestDevice();

  const canvas = document.getElementById("c");
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
      let rect = inst[ii * 3u];        // x, y, w, h (pixels, top-left origin)
      let col  = inst[ii * 3u + 1u];   // r, g, b, a
      let uvr  = inst[ii * 3u + 2u];   // u, v, uw, uh (atlas sub-rect)
      let c = corners[vi];
      let p = rect.xy + c * rect.zw;
      let ndc = vec2<f32>(p.x / g.size.x * 2.0 - 1.0, 1.0 - p.y / g.size.y * 2.0);
      var o : VSOut;
      o.pos = vec4<f32>(ndc, 0.0, 1.0);
      o.uv = uvr.xy + c * uvr.zw;
      o.color = col;
      return o;
    }

    @fragment
    fn fs(i : VSOut) -> @location(0) vec4<f32> {
      let c = i.color * textureSample(tex, samp, i.uv);
      return vec4<f32>(c.rgb * c.a, c.a); // premultiplied
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

  sampler = device.createSampler({ magFilter: "linear", minFilter: "linear", mipmapFilter: "linear" });
  uniformBuf = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  instanceBuf = device.createBuffer({ size: MAX * FLOATS * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
  group0 = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [{ binding: 0, resource: { buffer: uniformBuf } }, { binding: 1, resource: { buffer: instanceBuf } }],
  });
  resize(); // sets canvas size (HiDPI) + uniform

  audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  masterGain = audioCtx.createGain();
  masterGain.connect(audioCtx.destination);

  textures.push({ bindGroup: makeBindGroup(makeSolid(1, 1, [255, 255, 255, 255])) }); // id 0 = white
}

// --- HiDPI canvas sizing ---
function resize() {
  const canvas = document.getElementById("c");
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  canvas.style.width = WIDTH + "px"; canvas.style.height = HEIGHT + "px";
  canvas.width = Math.round(WIDTH * dpr); canvas.height = Math.round(HEIGHT * dpr);
  // The world is WIDTH×HEIGHT; the canvas backing store is scaled by dpr, so the NDC
  // mapping still uses logical size — draw at full backing-store resolution.
  device.queue.writeBuffer(uniformBuf, 0, new Float32Array([WIDTH, HEIGHT, 0, 0]));
}

// --- Texture helpers ---
function mipLevels(w, h) { return 1 + Math.floor(Math.log2(Math.max(w, h))); }

function makeSolid(w, h, rgba) {
  const tex = device.createTexture({
    size: [w, h, 1], format: "rgba8unorm",
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST,
  });
  device.queue.writeTexture({ texture: tex }, new Uint8Array(rgba), { bytesPerRow: w * 4, rowsPerImage: h }, [w, h, 1]);
  return tex;
}

function makeBindGroup(tex) {
  return device.createBindGroup({
    layout: pipeline.getBindGroupLayout(1),
    entries: [{ binding: 0, resource: tex.createView() }, { binding: 1, resource: sampler }],
  });
}

// Texture with a full mip chain: upload level 0 (from pixels or an ImageBitmap), then
// generate the smaller levels on the GPU.
function makeMipped(w, h, { pixels, bitmap }) {
  const levels = mipLevels(w, h);
  const tex = device.createTexture({
    size: [w, h, 1], format: "rgba8unorm", mipLevelCount: levels,
    usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT,
  });
  if (bitmap) device.queue.copyExternalImageToTexture({ source: bitmap }, { texture: tex }, [w, h]);
  else device.queue.writeTexture({ texture: tex }, pixels, { bytesPerRow: w * 4, rowsPerImage: h }, [w, h, 1]);
  generateMips(tex, levels);
  return tex;
}

function generateMips(tex, levels) {
  if (!mipPipeline) {
    const mod = device.createShaderModule({ code: `
      @group(0) @binding(0) var t : texture_2d<f32>;
      @group(0) @binding(1) var s : sampler;
      struct V { @builtin(position) pos : vec4<f32>, @location(0) uv : vec2<f32> };
      @vertex fn v(@builtin(vertex_index) i : u32) -> V {
        var p = array<vec2<f32>,3>(vec2<f32>(-1.0,-1.0), vec2<f32>(3.0,-1.0), vec2<f32>(-1.0,3.0));
        var o : V; o.pos = vec4<f32>(p[i], 0.0, 1.0); o.uv = p[i] * vec2<f32>(0.5,-0.5) + 0.5; return o;
      }
      @fragment fn f(inp : V) -> @location(0) vec4<f32> { return textureSample(t, s, inp.uv); }
    ` });
    mipPipeline = device.createRenderPipeline({ layout: "auto", vertex: { module: mod, entryPoint: "v" },
      fragment: { module: mod, entryPoint: "f", targets: [{ format: "rgba8unorm" }] }, primitive: { topology: "triangle-list" } });
    mipSampler = device.createSampler({ magFilter: "linear", minFilter: "linear" });
  }
  const enc = device.createCommandEncoder();
  for (let l = 1; l < levels; l++) {
    const bg = device.createBindGroup({
      layout: mipPipeline.getBindGroupLayout(0),
      entries: [{ binding: 0, resource: tex.createView({ baseMipLevel: l - 1, mipLevelCount: 1 }) }, { binding: 1, resource: mipSampler }],
    });
    const pass = enc.beginRenderPass({ colorAttachments: [{ view: tex.createView({ baseMipLevel: l, mipLevelCount: 1 }), loadOp: "clear", storeOp: "store", clearValue: { r: 0, g: 0, b: 0, a: 0 } }] });
    pass.setPipeline(mipPipeline); pass.setBindGroup(0, bg); pass.draw(3); pass.end();
  }
  device.queue.submit([enc.finish()]);
}

// --- Services the WASM side calls ---

globalThis.__flockCheckerboard = () => {
  const N = 64, cell = 8, px = new Uint8Array(N * N * 4);
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    const on = ((x / cell | 0) + (y / cell | 0)) % 2 === 0;
    const o = (y * N + x) * 4, v = on ? 235 : 120;
    px[o] = v; px[o + 1] = v; px[o + 2] = 255; px[o + 3] = 255;
  }
  const id = textures.length; textures.push({ bindGroup: makeBindGroup(makeMipped(N, N, { pixels: px })) });
  return id;
};

globalThis.__flockMakeText = (text) => {
  const cached = textCache.get(text);
  if (cached !== undefined) return cached; // glyph cache: reuse the texture for a repeated string
  const cv = document.createElement("canvas"), ctx = cv.getContext("2d");
  ctx.font = "bold 44px system-ui, sans-serif";
  const w = Math.max(1, Math.ceil(ctx.measureText(text).width) + 16), h = 60;
  cv.width = w; cv.height = h;
  const c2 = cv.getContext("2d");
  c2.font = "bold 44px system-ui, sans-serif"; c2.textBaseline = "middle"; c2.fillStyle = "white";
  c2.fillText(text, 8, h / 2);
  const img = c2.getImageData(0, 0, w, h);
  const id = textures.length; textures.push({ bindGroup: makeBindGroup(makeMipped(w, h, { pixels: new Uint8Array(img.data.buffer) })) });
  textCache.set(text, id);
  return id;
};

// Async image load: reserve a white slot now, swap in the image texture when it arrives.
globalThis.__flockLoadImage = (url) => {
  const id = textures.length;
  textures.push({ bindGroup: makeBindGroup(makeSolid(1, 1, [255, 255, 255, 255])) });
  (async () => {
    try {
      const bmp = await createImageBitmap(await (await fetch(url)).blob());
      textures[id] = { bindGroup: makeBindGroup(makeMipped(bmp.width, bmp.height, { bitmap: bmp })) };
    } catch (e) { console.error("image load failed:", url, e); }
  })();
  return id;
};

// Async audio load: reserve a sound id, decode into it when it arrives.
globalThis.__flockLoadSound = (url) => {
  const id = sounds.length; sounds.push(null);
  (async () => {
    try {
      const buf = await (await fetch(url)).arrayBuffer();
      sounds[id] = await audioCtx.decodeAudioData(buf);
    } catch (e) { console.error("sound load failed:", url, e); }
  })();
  return id;
};

// Plays a decoded sound at `vol` (0..1), optionally looping. WebAudio mixes concurrent
// sources automatically; all go through masterGain. Returns a handle (0 if it can't play).
globalThis.__flockPlaySound = (id, vol, loop) => {
  const buf = sounds[id];
  if (!buf || audioCtx.state !== "running") return 0;
  const src = audioCtx.createBufferSource(), g = audioCtx.createGain();
  src.buffer = buf; src.loop = !!loop; g.gain.value = vol;
  src.connect(g).connect(masterGain); src.start();
  const h = handleSeq++;
  playing.set(h, src);
  src.onended = () => playing.delete(h);
  return h;
};

globalThis.__flockStopSound = (h) => {
  const s = playing.get(h);
  if (s) { try { s.stop(); } catch (e) {} playing.delete(h); }
};

globalThis.__flockMasterVolume = (v) => { if (masterGain) masterGain.gain.value = v; };

globalThis.__flockBeep = (freq, ms) => {
  if (!audioCtx || audioCtx.state !== "running") return;
  const t = audioCtx.currentTime, osc = audioCtx.createOscillator(), gain = audioCtx.createGain();
  osc.frequency.value = freq; osc.type = "square";
  gain.gain.setValueAtTime(0.15, t); gain.gain.exponentialRampToValueAtTime(0.001, t + ms / 1000);
  osc.connect(gain).connect(masterGain); osc.start(t); osc.stop(t + ms / 1000);
};

globalThis.__flockDraw = (floats, count, groups) => {
  if (count > 0) device.queue.writeBuffer(instanceBuf, 0, floats, 0, count * FLOATS);
  const enc = device.createCommandEncoder();
  const pass = enc.beginRenderPass({
    colorAttachments: [{ view: context.getCurrentTexture().createView(), clearValue: { r: 0.04, g: 0.04, b: 0.07, a: 1 }, loadOp: "clear", storeOp: "store" }],
  });
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, group0);
  let offset = 0;
  for (let gi = 0; gi < groups.length; gi += 2) {
    const texId = groups[gi], n = groups[gi + 1];
    if (n <= 0) continue;
    pass.setBindGroup(1, (textures[texId] || textures[0]).bindGroup);
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
    status.textContent = "running — textures/text/images · atlas UV · mipmaps · keyboard/gamepad/touch · WebAudio";
    window.addEventListener("resize", resize);

    const gesture = () => { if (audioCtx.state !== "running") audioCtx.resume(); };
    const key = (e, down) => { gesture(); if ([32, 37, 38, 39, 40].includes(e.keyCode)) { flock_key(e.keyCode, down); e.preventDefault(); } };
    window.addEventListener("keydown", (e) => key(e, 1));
    window.addEventListener("keyup", (e) => key(e, 0));

    // Touch / pointer: drag to move the player (mapped to the 4 arrow "keys" by direction).
    const canvas = document.getElementById("c");
    let dragging = false, px = 0, py = 0;
    const clearDirs = () => [37, 38, 39, 40].forEach((k) => flock_key(k, 0));
    const onDown = (x, y) => { gesture(); dragging = true; px = x; py = y; };
    const onMove = (x, y) => {
      if (!dragging) return;
      clearDirs();
      const dx = x - px, dy = y - py, T = 4;
      if (dx < -T) flock_key(37, 1); if (dx > T) flock_key(39, 1);
      if (dy < -T) flock_key(38, 1); if (dy > T) flock_key(40, 1);
      px = x; py = y;
    };
    const onUp = () => { dragging = false; clearDirs(); };
    canvas.addEventListener("pointerdown", (e) => onDown(e.offsetX, e.offsetY));
    canvas.addEventListener("pointermove", (e) => onMove(e.offsetX, e.offsetY));
    window.addEventListener("pointerup", onUp);

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
