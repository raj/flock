#!/usr/bin/env bash
# Compile web/main.cr (Flock ECS core + WebPlugins) to WebAssembly + ESM glue, using the
# crystal-js toolchain from the `wesh` shard. Outputs web/app.wasm + web/app.mjs.
#
#   web/build.sh [--release]     # --release runs wasm-opt -Oz + JS mangle (needs uglifyjs)
#
# Requires wasm-ld + wasm-opt (+ uglifyjs for --release); the WASI sysroot is fetched by
# crystal-js on first run. The wesh checkout is found via $WESH or a few common paths.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Discover the wesh shard (provides the patched crystal-js toolchain).
find_wesh() {
  for p in "${WESH:-}" "$HERE/../../../wesh" "$HERE/../../wesh" "$HOME/Documents/code/crystal/wesh"; do
    [ -n "$p" ] && [ -f "$p/lib/js/scripts/build.sh" ] && { (cd "$p" && pwd); return 0; }
  done
  return 1
}
WESH="$(find_wesh)" || {
  echo "wesh/crystal-js not found. Set WESH=/path/to/wesh (a checkout of the wesh shard)." >&2
  exit 1
}

export CRYSTAL_PATH="$WESH/lib:$(crystal env CRYSTAL_PATH)"
cd "$HERE"
bash "$WESH/lib/js/scripts/build.sh" "$HERE/main.cr" --esm -o app.wasm "$@"

# Patch: the generated glue's clock_time_get uses __memory without refreshing it after a
# WASM memory growth (unlike fd_write). App#update grows the heap, then Time#tick's clock
# read hits a detached ArrayBuffer. Add the same guard the other imports use.
GUARD='if (__memory.buffer.byteLength === 0) __memory = new DataView(__exports.memory.buffer); '
perl -0pi -e "s/(__memory\.setBigUint64\(time_ptr)/${GUARD}\$1/" app.mjs

BYTES=$(stat -f%z app.wasm 2>/dev/null || stat -c%s app.wasm)
GZ=$(gzip -c app.wasm | wc -c | tr -d ' ')
echo "built: web/app.wasm ($((BYTES / 1024)) KiB, ~$((GZ / 1024)) KiB gzip) + web/app.mjs (wesh: $WESH)"
