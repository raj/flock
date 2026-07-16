#!/usr/bin/env bash
# Dev server with live-reload (rebuilds WASM on .cr changes). Usage: web/dev.sh [port]
exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dev.mjs" "$@"
