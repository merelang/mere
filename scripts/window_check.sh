#!/bin/sh
# scripts/window_check.sh — the window capability, checked without a display.
#
# Draw a known pattern with contrib/raster, put it on the window, read the
# window's pixels back, compare. "It looked right" is not evidence; a readback is.
#
# It runs under SDL's `dummy` video driver, which has a software renderer and a
# real event queue but no display — so this works in CI and does not open a window
# on your desktop while you are working.
#
# The readback is only evidence because `Window.capture` poisons the pixel block
# before asking for it: `show` wrote the image into that same block, so a readback
# that did nothing would hand back exactly what was written and every pixel would
# match. Checked by making the runtime's readback a no-op — 3072 of 3072 pixels
# then differ.
#
# Skips (exit 0) when SDL2 is absent, the way qemu_virt.sh skips without QEMU:
# this is a capability with an external dependency, not a reason to fail a build.
#
# Usage:
#   sh scripts/window_check.sh
#
# Prerequisites: dune-built mere.exe, a C compiler, SDL2 (macOS: brew install sdl2,
#   Debian/Ubuntu: apt install libsdl2-dev).

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc

[ -x "$MERE" ] || { echo "window_check: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "window_check: no C compiler" >&2; exit 0; }
command -v sdl2-config >/dev/null 2>&1 || {
  echo "window_check: sdl2-config not found — skipping (this check is optional)"
  exit 0
}

TMP="${TMPDIR:-/tmp}/mere_window.$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT

SRC="$ROOT/test/window/window_check.mere"
"$MERE" -c "$SRC" > "$TMP/w.c"
$CC -O0 -w $(sdl2-config --cflags) "$TMP/w.c" -o "$TMP/w" $(sdl2-config --libs) -lm

# The dummy driver: a software renderer and an event queue, no display.
got=$(SDL_VIDEODRIVER=dummy "$TMP/w" 2>&1 || true)

expected='renderer size = 64x48
show -> true
pixels compared = 3072, mismatches = 0
poll (empty) -> Nothing
close -> true
0'

if [ "$got" != "$expected" ]; then
  echo "window_check: output differs"
  echo "  expected:"; printf '%s\n' "$expected" | sed 's/^/    /'
  echo "  got:";      printf '%s\n' "$got"      | sed 's/^/    /'
  exit 1
fi

echo "window_check: ok  (SDL $(sdl2-config --version), driver dummy, 3072 pixels, 0 mismatches)"
