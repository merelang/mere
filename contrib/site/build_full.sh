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

# 2. Regenerate playground/selfhost-fmt.wat from contrib/fmt/fmt.mere so
#    the Wasm artifact tracks the canonical fmt source. The .wat file in
#    contrib/site/playground/ is committed for review readability but is
#    a derived artifact.
PLAYGROUND_OUT="$OUTPUT_DIR/playground"
if [ -f contrib/fmt/fmt.mere ] && [ -d "$PLAYGROUND_OUT" ]; then
  dune exec mere -- -w contrib/fmt/fmt.mere > "$PLAYGROUND_OUT/selfhost-fmt.wat"
  echo "  mere -w contrib/fmt/fmt.mere -> playground/selfhost-fmt.wat"
fi

# 3. Compile each .wat to .wasm via wat2wasm.
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

  # 4. Copy contrib/dom/dom.glue.js next to the playground HTML so
  #    counter.html's `import "./dom.glue.js"` resolves on the deployed
  #    site. The SSG itself only walks contrib/site/playground/, so
  #    sibling contrib/ libs need to be staged from the shell layer.
  if [ -f contrib/dom/dom.glue.js ]; then
    cp contrib/dom/dom.glue.js "$PLAYGROUND_OUT/dom.glue.js"
    echo "  cp contrib/dom/dom.glue.js -> playground/dom.glue.js"
  fi
fi

echo "Full build complete."
