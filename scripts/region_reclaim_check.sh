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
# Measured at 100 iterations, depth 16:
#
#              v0.1.437          v0.1.443
#   C          2.5 MB flat       2.5 MB flat       reclaims
#   Wasm       completes         completes         reclaims (unreclaimed needs
#                                                  ~105 MB of a fixed 64 MiB)
#   LLVM       127 -> 316 MB     5.8 MB flat       reclaims as of v0.1.443
#
# THE LLVM COLUMN IS WHY THIS FILE EXISTS. When it was written the backend
# allocated every value in @__lang_default_region whatever region blocks were
# around it, and had no per-type copy-out; the gate pinned that as a KNOWN gap
# and was written to go red if the gap ever closed, rather than pass quietly
# and leave its own table wrong. v0.1.443 closed it, the gate went red, and
# this table is the update it asked for.
#
# What the LLVM leg asserts now is the opposite of what it asserted then: the
# footprint must NOT follow the iteration count. Same shape of check, other
# direction -- which is the point of having written the first one as a
# measurement rather than as a permission.
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

# Peak RSS in BYTES, measured by a wrapper this gate compiles itself.
#
# /usr/bin/time is not a portable answer: its resident-set flag is -l on the
# BSDs and -v on GNU, the label differs with it, and the Ubuntu image the CI
# runs on does not ship the binary at all -- which is how the first version of
# this gate passed here and failed there. getrusage(RUSAGE_CHILDREN) is POSIX
# and needs no package; the only platform difference left is the UNIT of
# ru_maxrss, and that is a compile-time question the C file answers rather than
# something the shell guesses.
cat > "$TMP/peak.c" <<'CEOF'
#include <stdio.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc < 2) return 2;
  pid_t p = fork();
  if (p == 0) {
    freopen("/dev/null", "w", stdout);
    execv(argv[1], &argv[1]);
    _exit(127);
  }
  int st = 0;
  if (waitpid(p, &st, 0) < 0) return 2;
  struct rusage ru;
  if (getrusage(RUSAGE_CHILDREN, &ru) < 0) return 2;
#ifdef __APPLE__
  long long bytes = (long long)ru.ru_maxrss;
#else
  long long bytes = (long long)ru.ru_maxrss * 1024;
#endif
  fprintf(stderr, "%lld\n", bytes);
  return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}
CEOF
$CC -O1 -w "$TMP/peak.c" -o "$TMP/peak" 2>/dev/null || {
  echo "FAIL region_reclaim: could not build the peak-RSS wrapper"; exit 1; }

peak() { "$TMP/peak" "$@" 2>&1 >/dev/null | tail -1; }
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
  echo "FAIL region_reclaim: the peak-RSS wrapper returned nothing"
  fail=1
else
  if [ "$(( c_big * 10 ))" -gt "$(( c_small * 20 ))" ]; then
    echo "FAIL region_reclaim/C: peak went $c_small -> $c_big for ${SMALL} -> ${BIG} iterations; the C backend is supposed to hold one tree at a time"
    fail=1
  fi
  checked=$((checked + 1))
fi

# ---- LLVM reclaims too, as of v0.1.443 -----------------------------------

l_small="$(peak "$TMP/lbin" $SMALL $DEPTH)"
l_big="$(peak "$TMP/lbin" $BIG $DEPTH)"
if [ -n "$l_small" ] && [ -n "$l_big" ]; then
  if [ "$(( l_big * 10 ))" -gt "$(( l_small * 20 ))" ]; then
    echo "FAIL region_reclaim/LLVM: peak went $l_small -> $l_big for ${SMALL} -> ${BIG} iterations."
    echo "  The footprint is following the iteration count again, which is what v0.1.443 stopped:"
    echo "  values are reaching @__lang_default_region instead of the current region, or a block is not"
    echo "  making itself current. See @__lang_alloc and the Region_block arm in codegen_llvm.ml."
    fail=1
  fi
  checked=$((checked + 1))
  # Within a small factor of C. Not equal: the two runtimes size their blocks
  # differently, and a band that demanded equality would be measuring that.
  if [ "$l_big" -gt "$(( c_big * 8 ))" ]; then
    echo "FAIL region_reclaim/LLVM: LLVM peak $l_big is more than 8x C's $c_big — flat, but holding far more per iteration"
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
  echo "PASS region_reclaim: $checked checks — C flat at $(( c_big / 1048576 )) MB, LLVM flat at $(( l_big / 1048576 )) MB, Wasm completes inside 64 MiB"
  exit 0
fi
exit 1
