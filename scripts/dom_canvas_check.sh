#!/bin/sh
# scripts/dom_canvas_check.sh -- contrib/dom's canvas blit (Q-122, v0.1.603),
# run under scripts/run_dom_headless.mjs: the frame a program puts is the frame
# the canvas got, pixel for pixel, and a frame shorter than w * h * 4 bytes is
# refused by name rather than drawn short.
#
# Exits 2 (skipped) without wat2wasm or node.
set -u
MERE=${MERE:-./_build/default/bin/mere.exe}
[ -x "$MERE" ] || { echo "dom_canvas: no compiler at $MERE (run dune build)"; exit 1; }
command -v wat2wasm >/dev/null 2>&1 || { echo "dom_canvas: SKIP (no wat2wasm)"; exit 2; }
command -v node     >/dev/null 2>&1 || { echo "dom_canvas: SKIP (no node)"; exit 2; }
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

build() {  # build <src.mere> <out.wasm>
  "$MERE" -w "$1" > "$tmp/m.wat" 2> "$tmp/err" \
    && wat2wasm --enable-tail-call --enable-threads "$tmp/m.wat" -o "$2" 2>> "$tmp/err"
}

if build test/dom/canvas_put_pixels.mere "$tmp/ok.wasm"; then
  out=$(node scripts/run_dom_headless.mjs "$tmp/ok.wasm" --wait 0 --settle 0 2>&1)
  want='image=2x2@0,0:ff0000ff00ff00ff0000ffffffffffff'
  if printf '%s\n' "$out" | grep -q "$want"; then
    echo "  ok    a 2x2 frame reaches the canvas pixel for pixel"
  else
    echo "  FAIL  the canvas did not get the frame (want $want)"; printf '%s\n' "$out" | sed 's/^/        /'; fail=1
  fi
else
  echo "  FAIL  the blit program did not build"; sed 's/^/        /' "$tmp/err"; fail=1
fi

# the same program asking for 2x3 from 16 bytes
sed 's/(bytes_of_bytebuf px) 2 2/(bytes_of_bytebuf px) 2 3/' test/dom/canvas_put_pixels.mere > test/dom/.short_$$.mere
if build test/dom/.short_$$.mere "$tmp/short.wasm"; then
  out=$(node scripts/run_dom_headless.mjs "$tmp/short.wasm" --wait 0 --settle 0 2>&1)
  if printf '%s\n' "$out" | grep -q "a 2x3 image needs 24 bytes, got 16"; then
    echo "  ok    a frame short of w * h * 4 bytes is refused by name"
  else
    echo "  FAIL  a short frame was not refused by name"; printf '%s\n' "$out" | sed 's/^/        /'; fail=1
  fi
else
  echo "  FAIL  the short-frame program did not build"; sed 's/^/        /' "$tmp/err"; fail=1
fi
rm -f test/dom/.short_$$.mere

[ "$fail" = 0 ] && echo "dom_canvas: ok" || { echo "dom_canvas: FAILED"; exit 1; }
