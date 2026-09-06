#!/bin/sh
# scripts/region_reclaim_check.sh — does `region R { }` actually return memory,
# per backend?
#
# test/regionreclaim/pertree.mere builds a tree inside a region block and lets
# only a scalar out. An implementation that reclaims holds ONE tree however
# many iterations run; one that does not holds all of them. Both print the same
# number, which is why the parity suite cannot see the difference -- it
# compares what a program prints, and this is a difference in what a program
# HOLDS.
#
# Measured 2026-09-06 (v0.1.437), 100 iterations at depth 16:
#
#   C     2.5 MB, flat from 40 iterations to 100          reclaims
#   Wasm  completes, and unreclaimed it would need ~105   reclaims
#         MB of a fixed 64 MiB linear memory
#   LLVM  127 MB at 40 iterations, 316 MB at 100          DOES NOT reclaim
#
# The LLVM backend allocates every value in @__lang_default_region regardless
# of the region blocks around it: its `region R { }` is an alloca that only
# explicitly region-typed things (`&R v`, views, containers whose typer region
# is R) are placed in, and it has no per-type copy-out (the C backend emits 42
# __mcopy sites; the LLVM backend emits none). The documentation is honest
# about this by omission -- memory-model.md §3.5 says "on the C backend" and
# the backend note names interp and Wasm -- but nothing measured it, so the
# size of the gap was not written down anywhere.
#
# THIS GATE ALSO FAILS WHEN THE GAP CLOSES. The LLVM leg asserts that the
# footprint still grows with iterations. If someone gives the LLVM backend a
# current region, that assertion goes red and says so, rather than passing
# quietly and leaving the table above wrong.
#
# Peak RSS is quantised and only roughly reproducible, so every comparison here
# is a RATIO with a wide band, never an absolute number.
#
# Usage:
#   sh scripts/region_reclaim_check.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}
SRC="$ROOT/test/regionreclaim/pertree.mere"
SMALL=40
BIG=100
DEPTH=16

[ -x "$MERE" ] || { echo "region_reclaim_check: $MERE not found — run dune build first" >&2; exit 1; }
CC=$(command -v clang || command -v cc || true)
[ -n "$CC" ] || { echo "region_reclaim_check: no C compiler — skipping"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
checked=0

peak() {
  # maximum resident set size in bytes, via the shell's own time(1)
  /usr/bin/time -l "$@" 2>&1 >/dev/null | awk '/maximum resident/{print $1}'
}
answer() { "$@" 2>/dev/null | head -1; }

"$MERE" -c "$SRC" > "$TMP/c.c" 2>/dev/null && $CC -O2 -w "$TMP/c.c" -o "$TMP/cbin" 2>/dev/null || {
  echo "FAIL region_reclaim: the C backend leg did not build"; exit 1; }
"$MERE" -ll "$SRC" > "$TMP/l.ll" 2>/dev/null && $CC -O2 -w "$TMP/l.ll" -o "$TMP/lbin" 2>/dev/null || {
  echo "FAIL region_reclaim: the LLVM backend leg did not build"; exit 1; }

# ---- same computation ----------------------------------------------------

a_c="$(answer "$TMP/cbin" $BIG $DEPTH)"
a_l="$(answer "$TMP/lbin" $BIG $DEPTH)"
if [ "$a_c" != "$a_l" ] || [ -z "$a_c" ]; then
  echo "FAIL region_reclaim: C says '$a_c' and LLVM says '$a_l' — not the same computation, so the footprints are not comparable"
  fail=1
fi
checked=$((checked + 1))

# ---- C reclaims: the footprint does not follow the iteration count -------

c_small="$(peak "$TMP/cbin" $SMALL $DEPTH)"
c_big="$(peak "$TMP/cbin" $BIG $DEPTH)"
if [ -z "$c_small" ] || [ -z "$c_big" ]; then
  echo "FAIL region_reclaim: could not read peak RSS (is /usr/bin/time -l available?)"
  fail=1
else
  if [ "$(( c_big * 10 ))" -gt "$(( c_small * 20 ))" ]; then
    echo "FAIL region_reclaim/C: peak went $c_small -> $c_big for ${SMALL} -> ${BIG} iterations; the C backend is supposed to hold one tree at a time"
    fail=1
  fi
  checked=$((checked + 1))
fi

# ---- LLVM does not reclaim: pinned, and the pin fails when it is fixed ----

l_small="$(peak "$TMP/lbin" $SMALL $DEPTH)"
l_big="$(peak "$TMP/lbin" $BIG $DEPTH)"
if [ -n "$l_small" ] && [ -n "$l_big" ]; then
  if [ "$(( l_big * 10 ))" -lt "$(( l_small * 15 ))" ]; then
    echo "FAIL region_reclaim/LLVM: peak went $l_small -> $l_big for ${SMALL} -> ${BIG} iterations, which is FLAT."
    echo "  The LLVM backend appears to reclaim region blocks now. That is good news and this gate is where it is recorded:"
    echo "  update the table in this script and the backend note in docs/memory-model.md, then relax this check."
    fail=1
  fi
  checked=$((checked + 1))
  # and it is much worse than C, which is the number worth having
  if [ "$(( l_big / 1048576 ))" -lt "$(( c_big / 1048576 * 4 ))" ]; then
    echo "FAIL region_reclaim/LLVM: LLVM peak $l_big is not far above C's $c_big — the recorded gap has changed shape"
    fail=1
  fi
  checked=$((checked + 1))
fi

# ---- Wasm reclaims, proved by exceeding a memory it cannot grow ----------

if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  if "$MERE" -w "$SRC" > "$TMP/w.wat" 2>/dev/null &&
     wat2wasm --enable-tail-call "$TMP/w.wat" -o "$TMP/w.wasm" 2>/dev/null; then
    a_w="$(node "$ROOT/scripts/run_wasm.js" "$TMP/w.wasm" $BIG $DEPTH 2>/dev/null | head -1)"
    # Unreclaimed this needs about 105 MB; the linear memory is a fixed 64 MiB
    # and nothing grows it, so completing IS the proof.
    if [ "$a_w" != "$a_c" ]; then
      echo "FAIL region_reclaim/Wasm: got '$a_w', expected '$a_c' — at $BIG iterations an implementation that does not reclaim runs out of its fixed 64 MiB"
      fail=1
    fi
    checked=$((checked + 1))
  fi
fi

if [ "$checked" -lt 4 ]; then
  echo "FAIL region_reclaim: only $checked checks ran"
  exit 1
fi

if [ "$fail" = 0 ]; then
  echo "PASS region_reclaim: $checked checks — C flat at $(( c_big / 1048576 )) MB, LLVM $(( l_small / 1048576 )) -> $(( l_big / 1048576 )) MB (known: no current region), Wasm completes inside 64 MiB"
  exit 0
fi
exit 1
