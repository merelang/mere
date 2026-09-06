#!/bin/sh
# scripts/inc_check.sh — contrib/inc recomputes the right nodes, and only those.
#
# Two consumers, because one cannot show whether an engine generalises: an
# aggregate (leaves -> groups -> root, a fan-in tree) and a build graph
# (headers -> objects -> archives -> binary, where one header is read by many
# objects and a node is reachable by more than one route).
#
# THE ORACLE IS FREE. Recomputing everything is the reference implementation,
# and the incremental answer has to equal it after EVERY edit -- not only at
# the end, because an invalidation that arrives one edit late still converges.
#
# WHY THE COUNT IS CHECKED TOO. Comparing answers cannot tell an incremental
# engine from a cache that always misses: mode 3 recomputes every node on every
# edit and prints exactly what the oracle prints. That is not a hypothetical --
# it runs here, and the gate asserts both that its output matches AND that its
# count is far higher. A gate that only compared transcripts would be green for
# an engine that had stopped being one.
#
# THE NEGATIVE CONTROL IS PART OF THE GATE. Mode 2 stores the new leaf value
# and never tells its readers, which is the bug this whole module exists to not
# have. The gate requires mode 2 to DIFFER from the oracle. If it ever matches,
# the comparison has stopped being able to fail and everything else here is
# worthless.
#
# The aggregate's count is asserted EXACTLY, not as a bound: one settle over
# n + n/g + 1 nodes, then three nodes per edit (a leaf, its group, the root).
# A bound would have passed for a range of wrong engines.
#
# Usage:
#   sh scripts/inc_check.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}
AGG="$ROOT/test/inc/agg.mere"
BUILD="$ROOT/test/inc/build.mere"

[ -x "$MERE" ] || { echo "inc_check: $MERE not found — run dune build first" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
checked=0

# $1 label  $2.. command
answers() { "$@" 2>&1 | grep -E '^(root|bin) '; }
count()   { "$@" 2>&1 | awk '/^recomputes /{print $2}'; }

N=256; G=16; E=20
NG=$(( (N + G - 1) / G ))
EXPECT=$(( N + NG + 1 + 3 * E ))

# ---- interpreter ---------------------------------------------------------

oracle="$(answers "$MERE" "$AGG" $N $G $E 0)"
engine="$(answers "$MERE" "$AGG" $N $G $E 1)"
stale="$(answers  "$MERE" "$AGG" $N $G $E 2)"
allrc="$(answers  "$MERE" "$AGG" $N $G $E 3)"

[ -n "$oracle" ] || { echo "FAIL agg: the oracle produced no answers at all"; fail=1; }
checked=$((checked + 1))

if [ "$engine" = "$oracle" ]; then :; else
  echo "FAIL agg/interp: the engine's transcript differs from recomputing everything"; fail=1
fi
checked=$((checked + 1))

if [ "$stale" = "$oracle" ]; then
  echo "FAIL agg/interp: dropping invalidation produced the RIGHT answers — this comparison cannot detect the bug it exists for"
  fail=1
fi
checked=$((checked + 1))

if [ "$allrc" = "$oracle" ]; then :; else
  echo "FAIL agg/interp: recompute-everything disagreed with the oracle, so the two are not the same computation"; fail=1
fi
checked=$((checked + 1))

c_engine="$(count "$MERE" "$AGG" $N $G $E 1)"
c_all="$(count    "$MERE" "$AGG" $N $G $E 3)"
if [ "$c_engine" != "$EXPECT" ]; then
  echo "FAIL agg/interp: recomputed $c_engine nodes, expected exactly $EXPECT (one settle over $((N + NG + 1)) nodes, then 3 per edit)"
  fail=1
fi
checked=$((checked + 1))

if [ "$c_all" -le $((c_engine * 4)) ]; then
  echo "FAIL agg/interp: recompute-everything cost $c_all against the engine's $c_engine — too close to tell them apart, so the counter is not discriminating"
  fail=1
fi
checked=$((checked + 1))

b_oracle="$(answers "$MERE" "$BUILD" 8 32 4 10 0)"
b_engine="$(answers "$MERE" "$BUILD" 8 32 4 10 1)"
b_count="$(count    "$MERE" "$BUILD" 8 32 4 10 1)"
if [ "$b_engine" = "$b_oracle" ]; then :; else
  echo "FAIL build/interp: the engine's transcript differs from recomputing everything"; fail=1
fi
checked=$((checked + 1))

# 45 nodes, 11 settles if nothing were shared: 495. A header is read by about a
# quarter of the objects, so the real figure is a third of that. The band is
# wide on purpose -- what is being asserted is "much less than everything, and
# more than the graph itself", not a fitted constant.
if [ "$b_count" -ge 400 ] || [ "$b_count" -le 45 ]; then
  echo "FAIL build/interp: recomputed $b_count nodes, expected between 46 and 399 (45 = one settle, 495 = every node every time)"
  fail=1
fi
checked=$((checked + 1))

# ---- compiled ------------------------------------------------------------
#
# The engine is Maps of int keys holding lists, walked recursively. That is a
# different set of code paths on a compiled backend than in the interpreter,
# and "the library works" is a claim about both.

CC=$(command -v clang || command -v cc || true)
if [ -n "$CC" ]; then
  for prog in agg build; do
    src="$ROOT/test/inc/$prog.mere"
    if "$MERE" -c "$src" > "$TMP/$prog.c" 2>"$TMP/$prog.err" &&
       $CC -O1 -w "$TMP/$prog.c" -o "$TMP/$prog.bin" 2>>"$TMP/$prog.err"; then
      if [ "$prog" = agg ]; then a0="$(answers "$TMP/$prog.bin" $N $G $E 0)"; a1="$(answers "$TMP/$prog.bin" $N $G $E 1)"
      else a0="$(answers "$TMP/$prog.bin" 8 32 4 10 0)"; a1="$(answers "$TMP/$prog.bin" 8 32 4 10 1)"; fi
      if [ "$a1" = "$a0" ] && [ -n "$a0" ]; then :; else
        echo "FAIL $prog/C: compiled engine and compiled oracle disagree"; fail=1
      fi
      checked=$((checked + 1))
      # and the compiled answer is the interpreted answer
      if [ "$prog" = agg ] && [ "$a1" != "$engine" ]; then
        echo "FAIL agg/C: the compiled engine disagrees with the interpreted one"; fail=1
      fi
      checked=$((checked + 1))
    else
      echo "FAIL $prog/C: did not build — $(head -1 "$TMP/$prog.err")"
      fail=1
    fi
  done
else
  echo "inc_check: no C compiler — the compiled half is not being measured"
fi

# A gate whose subject failed to build reports fewer checks, not fewer
# failures, so the count is part of the verdict.
if [ "$checked" -lt 8 ]; then
  echo "FAIL inc_check: only $checked checks ran"
  exit 1
fi

if [ "$fail" = 0 ]; then
  echo "PASS inc_check: $checked checks — agg recomputed exactly $EXPECT of $(( (N + NG + 1) * (E + 1) )), build $b_count of 495, dropped invalidation is detected"
  exit 0
fi
exit 1
