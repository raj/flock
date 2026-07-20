// Copies the built Flock web runtime (from ../, the web/ dir) into ./www so Capacitor can bundle
// it into the native iOS/Android projects. Run before `cap sync` (npm run sync does both).
import { cpSync, mkdirSync, rmSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const web = join(here, ".."); // the web/ dir
const www = join(here, "www");

// Runtime files the WebView needs. app.wasm/app.mjs come from web/build.sh; regenerate them first.
const files = ["index.html", "renderer.js", "app.mjs", "app.wasm", "manifest.webmanifest"];

rmSync(www, { recursive: true, force: true });
mkdirSync(www, { recursive: true });

if (!existsSync(join(web, "app.wasm"))) {
  console.warn("! web/app.wasm missing — run web/build.sh first to compile the game to WASM");
}
for (const f of files) {
  const src = join(web, f);
  if (existsSync(src)) cpSync(src, join(www, f));
}
if (existsSync(join(web, "assets"))) cpSync(join(web, "assets"), join(www, "assets"), { recursive: true });

console.log("web runtime -> www/  (now run `npx cap sync` to copy into ios/ + android/)");
