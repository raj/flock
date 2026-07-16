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
echo "built: web/app.wasm + web/app.mjs"
