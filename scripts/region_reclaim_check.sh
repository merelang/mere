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

# ---- perbigvec: one LARGE value per iteration, both sides of the trade ----
#
# pertree asks whether a block reclaims. This asks whether it reclaims in the
# shape an editor, a renderer or a pager has: a multi-megabyte value built and
# dropped once per iteration.
#
# That case was different, and the bookkeeping is why it took measuring to see.
# Releasing a grown region used to free the whole chain and re-seed at 1 MiB --
# so every block WAS freed, the counters agreed, and the process grew anyway,
# because the next iteration asks malloc for those megabytes again and malloc
# does not hand the same pages back. Forty iterations of a 5 MiB Vec reached
# 216 MB with a release counter reading 40 of 40. Since v0.1.475 the release
# keeps the largest block: the same loop is 13.7 MB and flat.
#
# BOTH DIRECTIONS ARE PINNED HERE, because the fix is a trade and a trade with
# only one side measured drifts:
#
#   under __LANG_REGION_KEEP_MAX   the footprint must NOT follow the iterations
#   over it                        the footprint MUST, because a program that
#                                  builds one enormous value and then stops
#                                  using regions should not hold it forever
#
# The second is not a wish -- it is the cap doing its job, and a future change
# that removes the cap turns this red and asks for the decision again rather
# than silently retaining hundreds of megabytes per cached region.

BIGSRC="$ROOT/test/regionreclaim/perbigvec.mere"
if [ -f "$BIGSRC" ]; then
  if "$MERE" -c "$BIGSRC" > "$TMP/bv.c" 2>/dev/null && $CC -O2 -w "$TMP/bv.c" -o "$TMP/bvbin" 2>/dev/null; then
    # 5 MiB of int per iteration: comfortably under the 16 MiB keep cap.
    UNDER=655360
    b_small="$(peak "$TMP/bvbin" 10 $UNDER)"
    b_big="$(peak "$TMP/bvbin" 40 $UNDER)"
    if [ -n "$b_small" ] && [ -n "$b_big" ]; then
      if [ "$(( b_big * 10 ))" -gt "$(( b_small * 20 ))" ]; then
        echo "FAIL region_reclaim/perbigvec: peak went $b_small -> $b_big for 10 -> 40 iterations."
        echo "  A region under the keep cap is supposed to reuse its largest block rather than"
        echo "  free the chain and re-seed at 1 MiB. See __lang_region_block_release in codegen_c.ml."
        fail=1
      fi
      checked=$((checked + 1))
    fi

    # 32 MiB of int per iteration: over the cap, so the region gives it back and
    # the footprint follows the iteration count. Asserting the OTHER direction.
    OVER=4194304
    o_small="$(peak "$TMP/bvbin" 4 $OVER)"
    o_big="$(peak "$TMP/bvbin" 16 $OVER)"
    if [ -n "$o_small" ] && [ -n "$o_big" ]; then
      if [ "$(( o_big * 10 ))" -le "$(( o_small * 12 ))" ]; then
        echo "FAIL region_reclaim/perbigvec: peak went $o_small -> $o_big for 4 -> 16 iterations of a"
        echo "  32 MiB value -- flat, which means __LANG_REGION_KEEP_MAX is no longer bounding what a"
        echo "  recycled region holds. Eight regions are cached per thread, so an unbounded keep means"
        echo "  eight times the largest value the program ever built, held for the rest of the run."
        echo "  If that is now the intended trade, change this leg deliberately."
        fail=1
      fi
      checked=$((checked + 1))
    fi
  else
    echo "FAIL region_reclaim/perbigvec: the leg did not build"
    fail=1
  fi
fi

# ---- percall: Q-127's remaining half, closed on C and open on LLVM --------
#
# Same shape as pertree, but the thing built inside the block is a CONTAINER returned
# by a function. It used to grow on both compiled backends: a container's region is in
# its type, the body allocated through its own scheme's copy of that variable, and the
# call site bound a different copy -- the type said the block, the value was in the
# default region.
#
# v0.1.464 passes the region IN, as a leading argument, on the C backend, and v0.1.466
# does the same on LLVM. Across the same 10 -> 100 iterations:
#
#            before        after
#   C        9 -> 80 MB    2.7 -> 4.3 MB
#   LLVM     9 -> 80 MB    3.3 -> 3.3 MB
#
# Both legs now assert FLAT. Between those two versions the LLVM leg asserted the old
# behaviour and went red the moment it changed, which is how this table got updated
# instead of quietly rotting -- v0.1.443's LLVM leg is the precedent, and this one was
# itself what told me each half had landed.
#
# The Wasm leg asserts completion, for an unrelated reason: one bump for every region,
# nothing stores this vector into anything older than the block, so no high-water mark
# is raised (Q-132) and the rollback takes it. Three legs, three separate claims -- and
# all three must still agree on the ANSWER, which is checked first.

PCSRC="$ROOT/test/regionreclaim/percall.mere"
PCSMALL=10
PCBIG=100
PCN=100000
# Not "if it builds": a leg that quietly does not run is a leg that reports the
# question answered. The first version of this section skipped on a build failure
# and then referenced its own unset variables in the PASS line, so `set -u` killed
# the gate with a shell error instead of a sentence -- which is how it behaved the
# first time it was poisoned, and it was the poison's real finding.
pc_c_small=0; pc_c_big=0
if [ ! -f "$PCSRC" ]; then
  echo "FAIL region_reclaim/percall: $PCSRC is missing — the leg that measures Q-127 cannot run"
  fail=1
else
  if ! ("$MERE" -c "$PCSRC" > "$TMP/pc.c" 2>/dev/null && $CC -O2 -w "$TMP/pc.c" -o "$TMP/pcbin" 2>/dev/null); then
    echo "FAIL region_reclaim/percall: the C leg did not build"
    fail=1
  elif ! ("$MERE" -ll "$PCSRC" > "$TMP/pc.ll" 2>/dev/null && $CC -O2 -w "$TMP/pc.ll" -o "$TMP/pclbin" 2>/dev/null); then
    echo "FAIL region_reclaim/percall: the LLVM leg did not build (emitting is not building — mere -ll exits 0 on IR the assembler rejects)"
    fail=1
  else
    # Same computation first: two footprints are not comparable until the two
    # programs agree about what they computed.
    pa_c="$(answer "$TMP/pcbin" $PCSMALL $PCN)"
    pa_l="$(answer "$TMP/pclbin" $PCSMALL $PCN)"
    if [ "$pa_c" != "$pa_l" ] || [ -z "$pa_c" ]; then
      echo "FAIL region_reclaim/percall: C says '$pa_c' and LLVM says '$pa_l' — passing the region in changed an ANSWER, which it must never do"
      fail=1
    fi
    checked=$((checked + 1))

    pc_c_small="$(peak "$TMP/pcbin" $PCSMALL $PCN)"
    pc_c_big="$(peak "$TMP/pcbin" $PCBIG $PCN)"
    pc_l_small="$(peak "$TMP/pclbin" $PCSMALL $PCN)"
    pc_l_big="$(peak "$TMP/pclbin" $PCBIG $PCN)"
    if [ -z "$pc_c_small" ] || [ -z "$pc_c_big" ] || [ -z "$pc_l_big" ] || [ -z "$pc_l_small" ]; then
      echo "FAIL region_reclaim/percall: the peak-RSS wrapper returned nothing"
      fail=1
      pc_c_small=0; pc_c_big=0
    else
      # C reclaims: ten times the iterations must not cost twice the memory.
      if [ "$(( pc_c_big * 10 ))" -gt "$(( pc_c_small * 20 ))" ]; then
        echo "FAIL region_reclaim/percall/C: peak went $pc_c_small -> $pc_c_big for ${PCSMALL} -> ${PCBIG} iterations."
        echo "  A callee-built container has stopped being reclaimed by the caller's block."
        echo "  The region is no longer reaching the callee: see direct_region_params /"
        echo "  Typer.region_args_for, and check that the call still takes the __direct path."
        fail=1
      fi
      checked=$((checked + 1))
      # LLVM too, since v0.1.466.
      if [ "$(( pc_l_big * 10 ))" -gt "$(( pc_l_small * 20 ))" ]; then
        echo "FAIL region_reclaim/percall/LLVM: peak went $pc_l_small -> $pc_l_big for ${PCSMALL} -> ${PCBIG} iterations."
        echo "  A callee-built container has stopped being reclaimed on the LLVM backend."
        echo "  The region is no longer reaching the callee: see emit_fn_def's rps and"
        echo "  Typer.region_args_for at the 1-argument direct call site."
        fail=1
      fi
      checked=$((checked + 1))
    fi
  fi
  if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
    if "$MERE" -w "$PCSRC" > "$TMP/pw.wat" 2>/dev/null &&
       wat2wasm --enable-tail-call "$TMP/pw.wat" -o "$TMP/pw.wasm" 2>/dev/null; then
      pc_w="$(node "$ROOT/scripts/run_wasm.js" "$TMP/pw.wasm" $PCBIG $PCN 2>/dev/null | head -1)"
      # Unreclaimed this needs ~80 MB of a fixed 64 MiB, so completing is the proof.
      if [ "$pc_w" != "10000000" ]; then
        echo "FAIL region_reclaim/percall/Wasm: got '$pc_w', expected 10000000 — Wasm stopped reclaiming a callee-built container, or ran out of its fixed 64 MiB"
        fail=1
      fi
      checked=$((checked + 1))
    fi
  fi
fi

if [ "$checked" -lt 7 ]; then
  echo "FAIL region_reclaim: only $checked checks ran"
  exit 1
fi

if [ "$fail" = 0 ]; then
  echo "PASS region_reclaim: $checked checks — C flat at $(( c_big / 1048576 )) MB, LLVM flat at $(( l_big / 1048576 )) MB, Wasm completes inside 64 MiB; a callee-built container is reclaimed on C ($(( pc_c_small / 1048576 )) -> $(( pc_c_big / 1048576 )) MB), LLVM ($(( pc_l_small / 1048576 )) -> $(( pc_l_big / 1048576 )) MB) and Wasm (Q-127 closed on both compiled backends)"
  exit 0
fi
exit 1
