#!/bin/sh
# contrib/site/build_full.sh — full docs site build wrapper
#
# Mere's read_file / write_file are UTF-8 string-based and can't copy
# binary .wasm, so binary files are produced via wat2wasm + cp at the
# shell layer. Everything else (HTML / WAT / markdown conversion / index /
# search.json / sitemap / .nojekyll) is handled by build.mere.
#
# Usage:
#   sh contrib/site/build_full.sh [input_dir=docs] [output_dir=_site] [--dev|--watch]

INPUT_DIR="${1:-docs}"
OUTPUT_DIR="${2:-_site}"
MODE_FLAG="${3:-}"

set -e

# 1. Mere SSG: markdown -> HTML + style.css + index + search + sitemap + nojekyll
#    + copies playground/*.html + *.wat
dune exec mere -- contrib/site/build.mere "$INPUT_DIR" "$OUTPUT_DIR" $MODE_FLAG

# 2. Playground asset generation: compile .wat to .wasm via wat2wasm
PLAYGROUND_OUT="$OUTPUT_DIR/playground"
if [ -d "$PLAYGROUND_OUT" ]; then
  for wat in "$PLAYGROUND_OUT"/*.wat; do
    [ -f "$wat" ] || continue
    wasm="${wat%.wat}.wasm"
    if command -v wat2wasm > /dev/null 2>&1; then
      wat2wasm "$wat" -o "$wasm" 2>&1 \
        && echo "  wat2wasm $(basename "$wat") -> $(basename "$wasm")"
    else
      echo "  warning: wat2wasm not in PATH, skipping $wat" >&2
    fi
  done

  # 3. Copy contrib/dom/dom.glue.js next to the playground HTML so
  #    counter.html's `import "./dom.glue.js"` resolves on the deployed
  #    site. The SSG itself only walks contrib/site/playground/, so
  #    sibling contrib/ libs need to be staged from the shell layer.
  if [ -f contrib/dom/dom.glue.js ]; then
    cp contrib/dom/dom.glue.js "$PLAYGROUND_OUT/dom.glue.js"
    echo "  cp contrib/dom/dom.glue.js -> playground/dom.glue.js"
  fi
fi

echo "Full build complete."
