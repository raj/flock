// Renderer + browser services for the Flock web backend. The ECS (WASM) computes sprite
// instances and calls globalThis.__flockDraw; we draw them as instanced textured quads (with UV
// sub-rects / atlas support). Two graphics backends implement the same tiny interface
// ({ init, resize, white, texture, draw }): WebGPU when available, else WebGL2 — so the game runs
// on WebViews without WebGPU (older iOS/Android). The audio / text / gamepad / input / loop
// services are backend-agnostic.
import init, { flock_init, flock_frame, flock_key, flock_gamepad } from "./app.mjs";

// Render resolution comes from the canvas element's width/height attributes (set by the
// page), so the engine isn't hardwired to one size. Falls back to 800x600.
const _canvas0 = document.getElementById("c");
const WIDTH = (_canvas0 && _canvas0.width) || 800, HEIGHT = (_canvas0 && _canvas0.height) || 600;
const MAX = 512, FLOATS = 12, STRIDE = FLOATS * 4;
const CLEAR = [0.04, 0.04, 0.07, 1];

// Scales the canvas's CSS size to fit the window while preserving aspect (contain), so the
// game fills the screen. The internal framebuffer stays WIDTH x HEIGHT (× dpr).
function fitStyle(canvas) {
  const s = Math.min(window.innerWidth / WIDTH, window.innerHeight / HEIGHT);
  canvas.style.width = Math.round(WIDTH * s) + "px";
  canvas.style.height = Math.round(HEIGHT * s) + "px";
}

// Backend-agnostic state.
const textures = [];         // id -> backend texture handle (id 0 = solid white)
const sounds = [];           // id -> AudioBuffer | null
const textCache = new Map(); // text string -> texture id (glyph cache)
const playing = new Map();   // handle -> AudioBufferSourceNode
let handleSeq = 1;
let audioCtx, masterGain;
let gfx = null;              // the selected graphics backend

// ============================================================ WebGPU backend
const WebGPUBackend = {
  name: "WebGPU",
  device: null, context: null, canvas: null, pipeline: null, instanceBuf: null,
  uniformBuf: null, group0: null, format: null, sampler: null, mipPipeline: null, mipSampler: null,

  // `device` is created by the selector before touching the canvas, so a failed WebGPU probe
  // never locks the canvas out of a WebGL2 fallback.
  async init(canvas, device) {
    this.device = device;
    this.canvas = canvas;
    // Capture validation errors (which WebGPU reports asynchronously) so a partial WebView
    // implementation triggers the WebGL2 fallback instead of silently rendering nothing.
    device.pushErrorScope("validation");
    this.context = canvas.getContext("webgpu");
    if (!this.context) throw new Error("WebGPU canvas context unavailable");
    this.format = navigator.gpu.getPreferredCanvasFormat();
    this.context.configure({ device, format: this.format, alphaMode: "premultiplied" });

    // Shared shader preamble (bindings + vertex stage). A material = this preamble + a
    // custom `fs`; the default material's fs is DEFAULT_FS. All pipelines share one
    // explicit layout so the group0/texture bind groups are valid for every pipeline.
    this.preamble = `
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
        let rect = inst[ii * 3u];
        let col  = inst[ii * 3u + 1u];
        let uvr  = inst[ii * 3u + 2u];
        let c = corners[vi];
        let p = rect.xy + c * rect.zw;
        let ndc = vec2<f32>(p.x / g.size.x * 2.0 - 1.0, 1.0 - p.y / g.size.y * 2.0);
        var o : VSOut;
        o.pos = vec4<f32>(ndc, 0.0, 1.0);
        o.uv = uvr.xy + c * uvr.zw;
        o.color = col;
        return o;
      }
    `;
    const DEFAULT_FS = `
      @fragment
      fn fs(i : VSOut) -> @location(0) vec4<f32> {
        let c = i.color * textureSample(tex, samp, i.uv);
        return vec4<f32>(c.rgb * c.a, c.a);
      }
    `;

    this.layout0 = device.createBindGroupLayout({ entries: [
      { binding: 0, visibility: GPUShaderStage.VERTEX, buffer: { type: "uniform" } },
      { binding: 1, visibility: GPUShaderStage.VERTEX, buffer: { type: "read-only-storage" } },
    ] });
    this.layout1 = device.createBindGroupLayout({ entries: [
      { binding: 0, visibility: GPUShaderStage.FRAGMENT, texture: {} },
      { binding: 1, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
    ] });
    this.pipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [this.layout0, this.layout1] });

    this._makePipeline = (fsSrc) => {
      const mod = device.createShaderModule({ code: this.preamble + fsSrc });
      return device.createRenderPipeline({
        layout: this.pipelineLayout,
        vertex: { module: mod, entryPoint: "vs" },
        fragment: {
          module: mod, entryPoint: "fs",
          targets: [{ format: this.format, blend: {
            color: { srcFactor: "one", dstFactor: "one-minus-src-alpha" },
            alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha" },
          } }],
        },
        primitive: { topology: "triangle-list" },
      });
    };

    this.pipeline = this._makePipeline(DEFAULT_FS);
    this.materials = [this.pipeline]; // index 0 = default; registerMaterial appends

    this.sampler = device.createSampler({ magFilter: "linear", minFilter: "linear", mipmapFilter: "linear" });
    this.uniformBuf = device.createBuffer({ size: 16, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
    this.instanceBuf = device.createBuffer({ size: MAX * FLOATS * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
    this.group0 = device.createBindGroup({
      layout: this.layout0,
      entries: [{ binding: 0, resource: { buffer: this.uniformBuf } }, { binding: 1, resource: { buffer: this.instanceBuf } }],
    });
    const err = await device.popErrorScope();
    if (err) throw new Error("WebGPU validation error: " + err.message);
    this.resize();
  },

  // Builds a custom-material pipeline from a WGSL fragment (a `@fragment fn fs(i:VSOut)`),
  // returns its id for use in Sprite2D#material. The GLSL arg is ignored here (WebGL2 uses it).
  registerMaterial(wgslFrag, _glslFrag) {
    this.materials.push(this._makePipeline(wgslFrag));
    return this.materials.length - 1;
  },

  resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    fitStyle(this.canvas);
    this.canvas.width = Math.round(WIDTH * dpr); this.canvas.height = Math.round(HEIGHT * dpr);
    this.device.queue.writeBuffer(this.uniformBuf, 0, new Float32Array([WIDTH, HEIGHT, 0, 0]));
  },

  white() { return this._bind(this._solid(1, 1, [255, 255, 255, 255])); },
  texture(w, h, src) { return this._bind(this._mipped(w, h, src)); },

  draw(floats, count, groups) {
    count = Math.min(count, MAX); // defensive: buffers are sized for MAX instances
    if (count > 0) this.device.queue.writeBuffer(this.instanceBuf, 0, floats, 0, count * FLOATS);
    const enc = this.device.createCommandEncoder();
    const pass = enc.beginRenderPass({
      colorAttachments: [{ view: this.context.getCurrentTexture().createView(),
        clearValue: { r: CLEAR[0], g: CLEAR[1], b: CLEAR[2], a: CLEAR[3] }, loadOp: "clear", storeOp: "store" }],
    });
    pass.setBindGroup(0, this.group0);
    let offset = 0;
    // groups: [textureId, materialId, count] triples (sorted by material then texture).
    for (let gi = 0; gi < groups.length; gi += 3) {
      const texId = groups[gi], matId = groups[gi + 1], n = groups[gi + 2];
      if (n <= 0) continue;
      pass.setPipeline(this.materials[matId] || this.pipeline);
      pass.setBindGroup(1, textures[texId] || textures[0]);
      pass.draw(6, n, 0, offset);
      offset += n;
    }
    pass.end();
    this.device.queue.submit([enc.finish()]);
  },

  // -- private texture helpers --
  _bind(tex) {
    return this.device.createBindGroup({
      layout: this.layout1,
      entries: [{ binding: 0, resource: tex.createView() }, { binding: 1, resource: this.sampler }],
    });
  },
  _solid(w, h, rgba) {
    const tex = this.device.createTexture({ size: [w, h, 1], format: "rgba8unorm",
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST });
    this.device.queue.writeTexture({ texture: tex }, new Uint8Array(rgba), { bytesPerRow: w * 4, rowsPerImage: h }, [w, h, 1]);
    return tex;
  },
  _mipped(w, h, { pixels, bitmap }) {
    const levels = 1 + Math.floor(Math.log2(Math.max(w, h)));
    const tex = this.device.createTexture({ size: [w, h, 1], format: "rgba8unorm", mipLevelCount: levels,
      usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT });
    if (bitmap) this.device.queue.copyExternalImageToTexture({ source: bitmap }, { texture: tex }, [w, h]);
    else this.device.queue.writeTexture({ texture: tex }, pixels, { bytesPerRow: w * 4, rowsPerImage: h }, [w, h, 1]);
    this._genMips(tex, levels);
    return tex;
  },
  _genMips(tex, levels) {
    const device = this.device;
    if (!this.mipPipeline) {
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
      this.mipPipeline = device.createRenderPipeline({ layout: "auto", vertex: { module: mod, entryPoint: "v" },
        fragment: { module: mod, entryPoint: "f", targets: [{ format: "rgba8unorm" }] }, primitive: { topology: "triangle-list" } });
      this.mipSampler = device.createSampler({ magFilter: "linear", minFilter: "linear" });
    }
    const enc = device.createCommandEncoder();
    for (let l = 1; l < levels; l++) {
      const bg = device.createBindGroup({ layout: this.mipPipeline.getBindGroupLayout(0),
        entries: [{ binding: 0, resource: tex.createView({ baseMipLevel: l - 1, mipLevelCount: 1 }) }, { binding: 1, resource: this.mipSampler }] });
      const pass = enc.beginRenderPass({ colorAttachments: [{ view: tex.createView({ baseMipLevel: l, mipLevelCount: 1 }),
        loadOp: "clear", storeOp: "store", clearValue: { r: 0, g: 0, b: 0, a: 0 } }] });
      pass.setPipeline(this.mipPipeline); pass.setBindGroup(0, bg); pass.draw(3); pass.end();
    }
    device.queue.submit([enc.finish()]);
  },
};

// ============================================================ WebGL2 backend
const WebGL2Backend = {
  name: "WebGL2",
  gl: null, canvas: null, prog: null, uSize: null, vao: null, quadBuf: null, instBuf: null,

  async init(canvas) {
    const gl = canvas.getContext("webgl2", { alpha: true, premultipliedAlpha: true, antialias: false });
    if (!gl) throw new Error("WebGL2 unavailable");
    this.gl = gl; this.canvas = canvas;

    // Vertex shader: per-vertex corner (0..1) + per-instance rect/color/uv -> pixel-space quad.
    const vs = `#version 300 es
      uniform vec2 uSize;
      layout(location=0) in vec2 aCorner;
      layout(location=1) in vec4 aRect;   // x, y, w, h  (per instance)
      layout(location=2) in vec4 aColor;  // r, g, b, a  (per instance)
      layout(location=3) in vec4 aUv;     // u, v, uw, uh (per instance)
      out vec2 vUv; out vec4 vColor;
      void main() {
        vec2 p = aRect.xy + aCorner * aRect.zw;
        vec2 ndc = vec2(p.x / uSize.x * 2.0 - 1.0, 1.0 - p.y / uSize.y * 2.0);
        gl_Position = vec4(ndc, 0.0, 1.0);
        vUv = aUv.xy + aCorner * aUv.zw;
        vColor = aColor;
      }`;
    const fs = `#version 300 es
      precision mediump float;
      uniform sampler2D uTex;
      in vec2 vUv; in vec4 vColor;
      out vec4 o;
      void main() {
        vec4 c = vColor * texture(uTex, vUv);
        o = vec4(c.rgb * c.a, c.a); // premultiplied
      }`;
    this.vsSrc = vs;                       // reused to build custom-material programs
    this.fsHeader = `#version 300 es\n      precision mediump float;\n      uniform sampler2D uTex;\n      in vec2 vUv; in vec4 vColor;\n      out vec4 o;\n`;
    this.prog = this._program(vs, fs);
    this.uSize = gl.getUniformLocation(this.prog, "uSize");
    gl.useProgram(this.prog);
    gl.uniform1i(gl.getUniformLocation(this.prog, "uTex"), 0);
    // Material 0 = default; registerMaterial appends {prog, uSize}.
    this.materials = [{ prog: this.prog, uSize: this.uSize }];

    this.vao = gl.createVertexArray();
    gl.bindVertexArray(this.vao);

    // Static unit quad (2 triangles), matching the WebGPU corner order.
    this.quadBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.quadBuf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

    // Per-instance data (pointers re-specified per texture-group in draw, to offset).
    this.instBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.instBuf);
    gl.bufferData(gl.ARRAY_BUFFER, MAX * STRIDE, gl.DYNAMIC_DRAW);
    for (const loc of [1, 2, 3]) { gl.enableVertexAttribArray(loc); gl.vertexAttribDivisor(loc, 1); }

    gl.bindVertexArray(null);
    gl.disable(gl.DEPTH_TEST);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA); // premultiplied
    this.resize();
  },

  resize() {
    const gl = this.gl, dpr = Math.min(window.devicePixelRatio || 1, 2);
    fitStyle(this.canvas);
    this.canvas.width = Math.round(WIDTH * dpr); this.canvas.height = Math.round(HEIGHT * dpr);
    gl.viewport(0, 0, this.canvas.width, this.canvas.height);
  },

  white() { return this._tex(1, 1, { pixels: new Uint8Array([255, 255, 255, 255]) }, false); },
  texture(w, h, src) { return this._tex(w, h, src, true); },

  // Builds a custom-material program from a GLSL fragment body (statements setting `o`,
  // with `vUv`, `vColor`, `uTex` in scope). Returns its id for Sprite2D#material.
  registerMaterial(_wgslFrag, glslBody) {
    const gl = this.gl;
    const fs = this.fsHeader + "      void main() {\n" + glslBody + "\n      }";
    const prog = this._program(this.vsSrc, fs);
    gl.useProgram(prog);
    gl.uniform1i(gl.getUniformLocation(prog, "uTex"), 0);
    this.materials.push({ prog, uSize: gl.getUniformLocation(prog, "uSize") });
    return this.materials.length - 1;
  },

  draw(floats, count, groups) {
    const gl = this.gl;
    gl.clearColor(CLEAR[0], CLEAR[1], CLEAR[2], CLEAR[3]);
    gl.clear(gl.COLOR_BUFFER_BIT);
    count = Math.min(count, MAX); // defensive: buffers are sized for MAX instances
    if (count <= 0) return;
    gl.bindVertexArray(this.vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.instBuf);
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, floats, 0, count * FLOATS);
    gl.activeTexture(gl.TEXTURE0);
    let offset = 0;
    // groups: [textureId, materialId, count] triples.
    for (let gi = 0; gi < groups.length; gi += 3) {
      const texId = groups[gi], matId = groups[gi + 1], n = groups[gi + 2];
      if (n <= 0) continue;
      const mat = this.materials[matId] || this.materials[0];
      gl.useProgram(mat.prog);
      gl.uniform2f(mat.uSize, WIDTH, HEIGHT);
      // WebGL2 has no baseInstance, so offset the instance attributes into the buffer instead.
      const base = offset * STRIDE;
      gl.vertexAttribPointer(1, 4, gl.FLOAT, false, STRIDE, base + 0);
      gl.vertexAttribPointer(2, 4, gl.FLOAT, false, STRIDE, base + 16);
      gl.vertexAttribPointer(3, 4, gl.FLOAT, false, STRIDE, base + 32);
      gl.bindTexture(gl.TEXTURE_2D, textures[texId] || textures[0]);
      gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, n);
      offset += n;
    }
    gl.bindVertexArray(null);
  },

  // -- private --
  _tex(w, h, { pixels, bitmap }, mip) {
    const gl = this.gl, t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false); // straight alpha; shader premultiplies
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    if (bitmap) gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
    else gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    if (mip) {
      gl.generateMipmap(gl.TEXTURE_2D); // WebGL2 allows mipmaps on NPOT textures
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    } else {
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    }
    return t;
  },
  _program(vsSrc, fsSrc) {
    const gl = this.gl;
    const compile = (type, src) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, src.trim());
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error("shader: " + gl.getShaderInfoLog(s));
      return s;
    };
    const vs = compile(gl.VERTEX_SHADER, vsSrc), fs = compile(gl.FRAGMENT_SHADER, fsSrc);
    const p = gl.createProgram();
    gl.attachShader(p, vs); gl.attachShader(p, fs);
    gl.linkProgram(p);
    gl.deleteShader(vs); gl.deleteShader(fs); // freed once the program is deleted
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error("link: " + gl.getProgramInfoLog(p));
    return p;
  },
};

// Picks the best available backend (WebGPU, else WebGL2). If WebGPU init fails after the canvas
// has been bound to a "webgpu" context (a context type can't be released), the canvas is swapped
// for a fresh clone so WebGL2 can bind — the failure mode of a flaky/partial WebView WebGPU.
async function selectBackend() {
  let canvas = document.getElementById("c");
  if (navigator.gpu) {
    try {
      const adapter = await navigator.gpu.requestAdapter();
      if (adapter) {
        const device = await adapter.requestDevice();
        await WebGPUBackend.init(canvas, device);
        return WebGPUBackend;
      }
    } catch (e) {
      console.warn("WebGPU init failed, falling back to WebGL2:", e);
      const fresh = canvas.cloneNode(false); // copies id/width/height, not the context
      canvas.replaceWith(fresh);
      canvas = fresh;
    }
  }
  await WebGL2Backend.init(canvas);
  return WebGL2Backend;
}

// ============================================================ backend-agnostic services

// Registers a texture built by the active backend and returns its id.
function registerTexture(w, h, src) {
  const id = textures.length;
  textures.push(gfx.texture(w, h, src));
  return id;
}

globalThis.__flockCheckerboard = () => {
  const N = 64, cell = 8, px = new Uint8Array(N * N * 4);
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    const on = ((x / cell | 0) + (y / cell | 0)) % 2 === 0;
    const o = (y * N + x) * 4, v = on ? 235 : 120;
    px[o] = v; px[o + 1] = v; px[o + 2] = 255; px[o + 3] = 255;
  }
  return registerTexture(N, N, { pixels: px });
};

globalThis.__flockMakeText = (text) => {
  const cached = textCache.get(text);
  if (cached !== undefined) return cached;
  const cv = document.createElement("canvas"), ctx = cv.getContext("2d");
  ctx.font = "bold 44px system-ui, sans-serif";
  const w = Math.max(1, Math.ceil(ctx.measureText(text).width) + 16), h = 60;
  cv.width = w; cv.height = h;
  const c2 = cv.getContext("2d");
  c2.font = "bold 44px system-ui, sans-serif"; c2.textBaseline = "middle"; c2.fillStyle = "white";
  c2.fillText(text, 8, h / 2);
  const img = c2.getImageData(0, 0, w, h);
  const id = registerTexture(w, h, { pixels: new Uint8Array(img.data.buffer) });
  textCache.set(text, id);
  return id;
};

// Async image load: reserve a white slot now, swap in the image texture when it arrives.
globalThis.__flockLoadImage = (url) => {
  const id = textures.length;
  textures.push(gfx.white());
  (async () => {
    try {
      // Keep straight (non-premultiplied) alpha — the shaders premultiply, so this avoids a
      // double-premultiply on translucent images (and keeps both backends identical).
      const bmp = await createImageBitmap(await (await fetch(url)).blob(), { premultiplyAlpha: "none" });
      textures[id] = gfx.texture(bmp.width, bmp.height, { bitmap: bmp });
    } catch (e) { console.error("image load failed:", url, e); }
  })();
  return id;
};

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

globalThis.__flockDraw = (floats, count, groups) => gfx.draw(floats, count, groups);

// Registers a custom sprite material and returns its id (0 if the backend can't build it).
// wgslFrag is used by the WebGPU backend, glslBody by WebGL2.
globalThis.__flockRegisterMaterial = (wgslFrag, glslBody) =>
  (gfx && gfx.registerMaterial ? gfx.registerMaterial(wgslFrag, glslBody) : 0) | 0;

function pollGamepad() {
  const gps = navigator.getGamepads ? navigator.getGamepads() : [];
  const gp = gps && gps[0];
  if (!gp) { flock_gamepad(0, 0, 0, 0); return; }
  const ax = Math.round((gp.axes[0] || 0) * 1000), ay = Math.round((gp.axes[1] || 0) * 1000);
  let mask = 0;
  gp.buttons.forEach((b, i) => { if (i < 16 && b.pressed) mask |= (1 << i); });
  flock_gamepad(ax, ay, mask, 1);
}

// On-screen d-pad + action button for touch devices, wired to the same arrow/space keys the game
// already reads (a reusable template — real games remap the codes). Hidden on mouse/desktop.
function setupVirtualControls() {
  if (!window.matchMedia || !window.matchMedia("(pointer: coarse)").matches) return;
  const base = "position:fixed;z-index:10;display:flex;align-items:center;justify-content:center;" +
    "font:600 22px system-ui;color:#dfe;background:#ffffff1f;border:1px solid #ffffff33;border-radius:12px;" +
    "-webkit-user-select:none;user-select:none;touch-action:none;backdrop-filter:blur(2px);";
  const hold = (el, code) => {
    const on = (e) => {
      e.preventDefault();
      // Release implicit pointer capture so sliding onto another button fires its enter/leave.
      try { el.releasePointerCapture(e.pointerId); } catch (_) {}
      flock_key(code, 1);
    };
    const off = (e) => { e.preventDefault(); flock_key(code, 0); };
    el.addEventListener("pointerdown", on);
    ["pointerup", "pointerleave", "pointercancel"].forEach((t) => el.addEventListener(t, off));
  };
  const dpad = document.createElement("div");
  dpad.style.cssText = "position:fixed;z-index:10;width:180px;height:180px;touch-action:none;" +
    "bottom:max(20px,env(safe-area-inset-bottom));left:max(20px,env(safe-area-inset-left));";
  document.body.appendChild(dpad);
  const key = (label, code, x, y) => {
    const b = document.createElement("div");
    b.textContent = label;
    b.style.cssText = base + `position:absolute;width:56px;height:56px;left:${x}px;top:${y}px;`;
    dpad.appendChild(b);
    hold(b, code);
  };
  key("▲", 38, 62, 0);   // up
  key("◀", 37, 0, 62);   // left
  key("▶", 39, 124, 62); // right
  key("▼", 40, 62, 124); // down

  const act = document.createElement("div");
  act.textContent = "A";
  act.style.cssText = base + "width:72px;height:72px;border-radius:50%;" +
    "bottom:max(28px,env(safe-area-inset-bottom));right:max(28px,env(safe-area-inset-right));";
  document.body.appendChild(act);
  hold(act, 32); // space
}

async function main() {
  const status = document.getElementById("status");
  try {
    gfx = await selectBackend();
    const canvas = document.getElementById("c"); // fresh node if selectBackend swapped it
    textures.push(gfx.white()); // id 0 = solid white

    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
    masterGain = audioCtx.createGain();
    masterGain.connect(audioCtx.destination);

    await init();
    flock_init();
    status.textContent = `running (${gfx.name}) — textures/text/images · atlas UV · mipmaps · keyboard/gamepad/touch · WebAudio`;
    window.addEventListener("resize", () => gfx.resize());

    const gesture = () => { if (audioCtx.state !== "running") audioCtx.resume(); };
    const key = (e, down) => { gesture(); if ([32, 37, 38, 39, 40].includes(e.keyCode)) { flock_key(e.keyCode, down); e.preventDefault(); } };
    window.addEventListener("keydown", (e) => key(e, 1));
    window.addEventListener("keyup", (e) => key(e, 0));

    // Touch / pointer: drag to move the player (mapped to the 4 arrow "keys" by direction).
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
    window.addEventListener("pointercancel", onUp); // interrupted drag mustn't leave keys held

    setupVirtualControls(); // touch-only on-screen d-pad + A button

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
