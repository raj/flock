#!/usr/bin/env bash
# One-command mobile build: compile the game to WASM, copy the runtime into www/, and sync it into
# the native iOS/Android projects. Then open the app to run on a device.
#
#   web/mobile/build.sh [--release]
#   (cd web/mobile && npx cap open ios)      # or: android
#
# Requires the web toolchain (../build.sh) and, for `cap sync`, that the native projects exist
# (`npx cap add ios` / `add android` — see README.md).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> compiling the game to WASM"
"$HERE/../build.sh" "$@"

echo "==> copying the web runtime into www/"
node "$HERE/sync-web.mjs"

if [ -d "$HERE/ios" ] || [ -d "$HERE/android" ]; then
  echo "==> cap sync"
  (cd "$HERE" && npx cap sync)
  echo "done — open the app: (cd web/mobile && npx cap open ios)   # or android"
else
  echo "note: no native project yet. First run (in web/mobile):"
  echo "      npm install && npx cap add ios      # needs Xcode"
  echo "      npm install && npx cap add android  # needs Android Studio"
fi
