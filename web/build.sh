#!/usr/bin/env bash
# Compile web/main.cr (Flock ECS core) to WebAssembly + ESM glue, using the crystal-js
# toolchain from the `wesh` shard. Outputs web/app.wasm + web/app.mjs.
#
#   web/build.sh [--release]
#
# Requires wasm-ld + wasm-opt; the WASI sysroot is fetched by crystal-js on first run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WESH="${WESH:-/Users/rajdeenoo/Documents/code/crystal/wesh}"

[ -f "$WESH/lib/js/scripts/build.sh" ] || {
  echo "wesh/crystal-js not found at $WESH (set WESH=/path/to/wesh). See web/README.md." >&2
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

echo "built: web/app.wasm + web/app.mjs"
