// Dev server for the Flock web demo: serves web/, watches sources, rebuilds the WASM on
// .cr changes, and live-reloads the browser (SSE). Usage: node web/dev.mjs [port]
//   (or: web/dev.sh). Plain static hosting (python -m http.server) also works — the
//   reload snippet in index.html just no-ops when /__events is absent.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { watch } from "node:fs";
import { spawn } from "node:child_process";
import { extname, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const DIR = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.argv[2]) || 8000;
const clients = new Set();

const MIME = {
  ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript",
  ".wasm": "application/wasm", ".png": "image/png", ".jpeg": "image/jpeg",
  ".wav": "audio/wav", ".json": "application/json", ".css": "text/css",
};

const server = createServer(async (req, res) => {
  const url = req.url.split("?")[0];
  if (url === "/__events") {
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" });
    res.write("data: hello\n\n");
    clients.add(res);
    req.on("close", () => clients.delete(res));
    return;
  }
  try {
    const path = join(DIR, url === "/" ? "index.html" : decodeURIComponent(url));
    const body = await readFile(path);
    res.writeHead(200, { "content-type": MIME[extname(path)] || "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404); res.end("not found");
  }
});

function reload() { for (const c of clients) c.write("data: reload\n\n"); }

let building = false, pending = false, timer = null;
function rebuild() {
  if (building) { pending = true; return; }
  building = true;
  console.log("• rebuilding…");
  const p = spawn("bash", [join(DIR, "build.sh")], { stdio: "inherit" });
  p.on("close", (code) => {
    building = false;
    if (code === 0) { console.log("• reload"); reload(); }
    if (pending) { pending = false; rebuild(); }
  });
}

watch(DIR, { recursive: true }, (_ev, file) => {
  if (!file || file.startsWith("app.")) return; // ignore build outputs
  clearTimeout(timer);
  timer = setTimeout(() => {
    if (file.endsWith(".cr")) rebuild();              // Crystal → rebuild WASM, then reload
    else if (/\.(js|mjs|html|css|png|wav)$/.test(file)) reload(); // assets/JS → just reload
  }, 120);
});

server.listen(PORT, () => console.log(`Flock dev server → http://localhost:${PORT}/  (watching ${DIR})`));
