#!/bin/sh
# contrib/site/build_full.sh — full docs site build wrapper
#
# Mere の read_file / write_file は UTF-8 string ベースで binary .wasm を
# copy できないため、 binary file は shell 側で wat2wasm + cp。
# それ以外 (HTML / WAT / markdown 変換 / index / search.json / sitemap /
# .nojekyll) は build.mere が担当。
#
# Usage:
#   sh contrib/site/build_full.sh [input_dir=docs] [output_dir=_site] [--dev|--watch]

INPUT_DIR="${1:-docs}"
OUTPUT_DIR="${2:-_site}"
MODE_FLAG="${3:-}"

set -e

# 1. Mere SSG: markdown → HTML + style.css + index + search + sitemap + nojekyll
#    + playground/*.html + *.wat を copy
dune exec mere -- contrib/site/build.mere "$INPUT_DIR" "$OUTPUT_DIR" $MODE_FLAG

# 2. playground asset 生成 — .wat を wat2wasm で .wasm に compile
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
fi

echo "Full build complete."
