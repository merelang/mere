#!/bin/sh
# scripts/llvm_musttail_opt_check.sh -- LLVM IR that holds a `musttail` builds
# with the optimiser on (v0.1.701).
#
# parity.sh compiles LLVM IR at -O0, where nothing rewrites a call. At -O1 and
# above, TailRecursionElimination turns `x = call @f(..); y = add x, k; ret y`
# into an accumulator loop, and adds the accumulator after EVERY return in the
# function -- the one right behind a `musttail` call included. The backend then
# stops: "failed to perform tail call elimination on a call site marked
# musttail". mere-ruby's LLVM build failed this way at -O1 and -O2; the IR
# emitter marks such self-calls `notail` in a function that holds a musttail.
#
# This builds test/parity/musttail_beside_accumulator.mere at -O1 and -O2 and
# compares the answer with the interpreter's.
#
# --poison: the same IR with `notail` taken off must NOT build, or the program
# does not have the shape.
#
# Usage: sh scripts/llvm_musttail_opt_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
LLVM_CC="${LLVM_CC:-clang}"
SRC="$ROOT/test/parity/musttail_beside_accumulator.mere"
[ -x "$MERE" ] || { echo "llvm_musttail_opt: $MERE not found -- run 'dune build'" >&2; exit 1; }
command -v "$LLVM_CC" >/dev/null 2>&1 || { echo "FAIL llvm_musttail_opt: no $LLVM_CC"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ref=$("$MERE" "$SRC" 2>&1) || { echo "FAIL llvm_musttail_opt: the interpreter refused it"; exit 1; }
"$MERE" -ll "$SRC" > "$T/p.ll" || { echo "FAIL llvm_musttail_opt: mere -ll refused it"; exit 1; }
grep -q 'musttail call' "$T/p.ll" || { echo "FAIL llvm_musttail_opt: the IR holds no musttail -- the test lost its shape"; exit 1; }
if [ "${1:-}" = --poison ]; then
  sed 's/= notail call /= call /' "$T/p.ll" > "$T/q.ll"
  cmp -s "$T/p.ll" "$T/q.ll" && { echo "FAIL llvm_musttail_opt --poison: no notail to take off"; exit 1; }
  if "$LLVM_CC" -w -O1 "$T/q.ll" -o "$T/q" -lm 2>/dev/null; then
    echo "llvm_musttail_opt --poison: POISON PASSED -- the IR builds without notail, so the program does not have the shape"; exit 1
  fi
  echo "llvm_musttail_opt --poison: ok (without notail the backend refuses the musttail)"
  exit 0
fi
bad=0
for o in -O1 -O2; do
  if ! "$LLVM_CC" -w $o "$T/p.ll" -o "$T/l" -lm 2> "$T/cc.err"; then
    echo "  FAIL  $o: the IR did not build: $(grep -m1 'error' "$T/cc.err")"; bad=1; continue
  fi
  out=$("$T/l" 2>&1)
  [ "$out" = "$ref" ] || { echo "  FAIL  $o: [$out] against the interpreter's [$ref]"; bad=1; }
done
[ "$bad" = 0 ] || { echo "FAIL llvm_musttail_opt"; exit 1; }
echo "llvm_musttail_opt: ok (-O1 and -O2 build and agree with the interpreter)"
