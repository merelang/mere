#!/bin/sh
# Compile main.mere → main.wat → main.wasm for the registry Worker.
set -e

MERE_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$(dirname "$0")/main.mere"
OUT_WAT="$(dirname "$0")/main.wat"
OUT_WASM="$(dirname "$0")/main.wasm"

(cd "$MERE_ROOT" && dune exec ./bin/mere.exe -- -w "$SRC") > "$OUT_WAT"
wat2wasm --enable-tail-call "$OUT_WAT" -o "$OUT_WASM"

echo "built:  $OUT_WASM ($(wc -c < "$OUT_WASM") bytes)"
echo ""
echo "next:"
echo "  local test:  node local_test.js"
echo "  deploy:      wrangler deploy"
