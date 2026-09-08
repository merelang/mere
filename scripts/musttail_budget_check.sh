#!/bin/sh
# scripts/musttail_budget_check.sh — a `musttail` the target cannot honour is not a
# slower program, it is a BUILD THAT DIES.
#
# LLVM promises `musttail` at every optimisation level, and past a certain return size
# the target cannot keep the promise: clang stops with "failed to perform tail call
# elimination on a call site marked musttail". -O1 and above optimise the call away
# before the check, so THE FAILURE IS A -O0 ONE -- which is the build a sanitiser needs,
# and why ASan was given up on during the Q-129 hunt. The emitter therefore refuses to
# mark a call `musttail` when its return is wider than `musttail_leaf_budget`.
#
# This gate asks the question in BOTH directions, because a bound with only one is a
# number that outlives its reason:
#
#   1. THE PROPERTY. With the shipped budget, `mere -ll` on a return of every width from
#      1 to 20 must build at -O0. That is what the bound is for.
#   2. THE BOUND ITSELF. With MERE_MUSTTAIL_LEAF_BUDGET raised, the emitter marks them
#      all `musttail` and the target is asked where ITS line is. That line is pinned per
#      architecture below. If it moves -- LLVM learning to forward a wider return, or a
#      new one refusing a narrower -- this FAILS and says so, rather than leaving the
#      budget quietly wrong in whichever direction.
#
# The shipped budget is the MINIMUM over the ABIs, so on a machine whose line is higher
# (arm64 forwards twice what x86-64 does) the budget is deliberately conservative and
# this gate says by how much instead of treating it as a failure.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
[ -x "$MERE" ] || { echo "musttail_budget: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v clang >/dev/null 2>&1 || { echo "musttail_budget: SKIP — no clang, and only a real target backend can answer this"; exit 0; }

# The measured line, per architecture: the widest return, in 8-byte leaves, whose
# `musttail` this target still forwards at -O0. Both were swept 1..20 on 2026-09-08
# (arm64: Apple clang 21 / x86-64: Ubuntu clang 18.1.3 in the CI image).
PINNED_arm64=8
PINNED_x86_64=4
SHIPPED=4

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MAX=20
i=1
while [ "$i" -le "$MAX" ]; do
  init=""; flds=""
  j=0
  while [ "$j" -lt "$i" ]; do
    [ -z "$flds" ] || { flds="$flds, "; init="$init, "; }
    flds="${flds}f$j: float"; init="${init}f$j = x"
    j=$((j + 1))
  done
  { echo "type w = { $flds };"
    echo "let rec go = fn (i: int) -> fn (x: float) -> if i <= 0 then w { $init } else go (i - 1) (x + 1.0);"
    echo "let r = go 10 0.0;"
    echo "let _ = print (str_of_float r.f0);"
    echo "0"; } > "$TMP/w$i.mere"
  i=$((i + 1))
done

fail=0

# --- 1. the property: with the shipped budget, everything builds at -O0 -------------
bad=""
i=1
while [ "$i" -le "$MAX" ]; do
  if ! "$MERE" -ll "$TMP/w$i.mere" > "$TMP/w$i.ll" 2>"$TMP/w$i.emit"; then
    echo "FAIL musttail_budget: mere -ll refused a $i-leaf return"; sed -n '1,3p' "$TMP/w$i.emit"; fail=1
  elif ! clang -O0 -w "$TMP/w$i.ll" -lm -o "$TMP/w$i.bin" 2>"$TMP/w$i.cc"; then
    bad="$bad $i"
  fi
  i=$((i + 1))
done
if [ -n "$bad" ]; then
  echo "FAIL musttail_budget: -O0 build refused for return width(s):$bad"
  echo "    $(grep -i 'error' "$TMP/w${bad##* }.cc" | head -1)"
  fail=1
else
  echo "musttail_budget: every return width 1..$MAX builds at -O0 with the shipped budget"
fi

# --- 2. the bound: where does THIS target actually stop? ----------------------------
arch="$(uname -m)"
case "$arch" in
  arm64|aarch64) pinned=$PINNED_arm64; arch=arm64 ;;
  x86_64|amd64)  pinned=$PINNED_x86_64; arch=x86_64 ;;
  *) pinned="" ;;
esac
line=0
i=1
while [ "$i" -le "$MAX" ]; do
  MERE_MUSTTAIL_LEAF_BUDGET=$MAX "$MERE" -ll "$TMP/w$i.mere" > "$TMP/f$i.ll" 2>/dev/null || break
  # The probe is only meaningful if the emitter actually marked the self call.
  grep -q 'musttail call %w' "$TMP/f$i.ll" || {
    echo "FAIL musttail_budget: raising the budget did not produce a musttail at width $i"
    fail=1; break; }
  if clang -O0 -w "$TMP/f$i.ll" -lm -o "$TMP/f$i.bin" 2>/dev/null; then line=$i; else break; fi
  i=$((i + 1))
done
if [ -z "$pinned" ]; then
  echo "musttail_budget: $arch is not in the pinned table; this target forwards up to $line leaves"
elif [ "$line" -ne "$pinned" ]; then
  echo "FAIL musttail_budget: $arch forwards up to $line leaves, the table says $pinned"
  echo "    The table is stale. If every supported ABI now forwards more, raise"
  echo "    musttail_leaf_budget in lib/codegen_llvm.ml (it is the MINIMUM over ABIs)."
  fail=1
else
  echo "musttail_budget: $arch forwards up to $line leaves, as pinned (shipped budget $SHIPPED)"
fi
if [ "$line" -lt "$SHIPPED" ] && [ -n "$pinned" ]; then
  echo "FAIL musttail_budget: the shipped budget $SHIPPED is above this target's line $line"
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "musttail_budget_check: ok"
