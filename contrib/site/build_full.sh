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

# 2. Regenerate playground/selfhost-fmt.wat from
#    contrib/site/playground/selfhost-fmt.mere — the Stage 50f-2 bridge
#    that wires `tokenize -> parse_expr -> format_expr` end-to-end with
#    the textarea via contrib/dom. The bridge transitively imports
#    parser.mere + fmt.mere + lexer.mere + ast.mere, so the resulting
#    Wasm carries the full self-host pipeline. The .wat file in
#    contrib/site/playground/ is a derived artifact.
PLAYGROUND_OUT="$OUTPUT_DIR/playground"
SELFHOST_SRC="contrib/site/playground/selfhost-fmt.mere"
if [ -f "$SELFHOST_SRC" ] && [ -d "$PLAYGROUND_OUT" ]; then
  dune exec mere -- -w "$SELFHOST_SRC" > "$PLAYGROUND_OUT/selfhost-fmt.wat"
  echo "  mere -w $SELFHOST_SRC -> playground/selfhost-fmt.wat"
fi

# Same idea for the REPL bridge — Phase 51.7 (Stage 51f). Pulls
# contrib/eval/eval.mere + contrib/parser/parser.mere + lexer + ast,
# so the resulting Wasm carries the full self-host PARSE + EVAL
# pipeline (the format pipe lives in the previous selfhost-fmt.wat).
SELFHOST_REPL_SRC="contrib/site/playground/selfhost-repl.mere"
if [ -f "$SELFHOST_REPL_SRC" ] && [ -d "$PLAYGROUND_OUT" ]; then
  dune exec mere -- -w "$SELFHOST_REPL_SRC" > "$PLAYGROUND_OUT/selfhost-repl.wat"
  echo "  mere -w $SELFHOST_REPL_SRC -> playground/selfhost-repl.wat"
fi

# Same idea for the type-checker bridge — Phase 52.7 (Stage 52g).
# Pulls contrib/typer/typer.mere + contrib/parser/parser.mere + lexer +
# ast, so the resulting Wasm carries the full self-host PARSE + TYPER
# pipeline. Closes §S2.B in the browser.
SELFHOST_TYCK_SRC="contrib/site/playground/selfhost-tyck.mere"
if [ -f "$SELFHOST_TYCK_SRC" ] && [ -d "$PLAYGROUND_OUT" ]; then
  dune exec mere -- -w "$SELFHOST_TYCK_SRC" > "$PLAYGROUND_OUT/selfhost-tyck.wat"
  echo "  mere -w $SELFHOST_TYCK_SRC -> playground/selfhost-tyck.wat"
fi

# Same idea for the codegen bridge — Phase 53.10 (Stage 53g). Pulls
# contrib/codegen/codegen_wasm.mere + contrib/parser/parser.mere +
# lexer + ast, so the resulting Wasm carries the full self-host PARSE
# + CODEGEN pipeline. Closes §S3 in the browser.
SELFHOST_COMPILE_SRC="contrib/site/playground/selfhost-compile.mere"
if [ -f "$SELFHOST_COMPILE_SRC" ] && [ -d "$PLAYGROUND_OUT" ]; then
  dune exec mere -- -w "$SELFHOST_COMPILE_SRC" > "$PLAYGROUND_OUT/selfhost-compile.wat"
  echo "  mere -w $SELFHOST_COMPILE_SRC -> playground/selfhost-compile.wat"
fi

# 3. Compile each .wat to .wasm via wat2wasm.
if [ -d "$PLAYGROUND_OUT" ]; then
  for wat in "$PLAYGROUND_OUT"/*.wat; do
    [ -f "$wat" ] || continue
    wasm="${wat%.wat}.wasm"
    if command -v wat2wasm > /dev/null 2>&1; then
      # --enable-tail-call: contrib demos with while / inner-lifted
      # closures emit `return_call[_indirect]` (Wasm tail-call proposal).
      # Enabled by default in Chrome / Safari / Firefox 129+ / Node 22+.
      wat2wasm --enable-tail-call "$wat" -o "$wasm" 2>&1 \
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
