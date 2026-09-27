#!/bin/sh
# scripts/fma_check.sh -- `fma` and `f64x2_fma` against the machine's fma(3).
#
# fma is correctly rounded by definition (IEEE-754's fusedMultiplyAdd), like
# + - * / and sqrt, so there is exactly one right answer and every backend is
# held to it bit for bit. The oracle is test/fma/fma_ref.c: the same inputs
# through the C library's fma. On the Wasm backend the answer is computed in
# software ($__lang_fma, in integers), because Wasm has no fma instruction --
# which is the leg this gate exists for.
#
# The inputs (test/fma/fma_bits.mere) are six families: every triple of 22
# special values, fully random bit patterns, products at the edges of the
# exponent range, exact cancellation, near cancellation, and ties decided by a
# single sticky bit. The last one is there because random inputs essentially
# never land on a tie; measured while writing the software fma, dropping the
# sticky bit for a shifted-out c passed 20 million random cases and failed
# 10,272 of 20 million with the ties in.
#
# POISON. The same program with `fma` redefined as `a * b + c` must NOT match
# the oracle; if it did, the inputs would not tell one rounding from two, and
# a backend that quietly computed the unfused expression would pass.
#
# ALSO: the emitted Wasm must contain $__lang_fma (the software path is the
# one being measured, not something that happened to agree), and the RISC-V
# backends must refuse the name -- they have no double-precision unit and the
# software floats there have no room for a 106-bit product.
#
# Usage: sh scripts/fma_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
P="$ROOT/test/fma/fma_bits.mere"
[ -x "$MERE" ] || { echo "fma_check: $MERE not found -- run 'dune build'" >&2; exit 1; }
command -v "$CC" >/dev/null 2>&1 || { echo "FAIL fma_check: no C compiler"; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0
fail() { echo "FAIL fma_check: $*"; fails=$((fails + 1)); }

"$CC" -O2 -w "$ROOT/test/fma/fma_ref.c" -lm -o "$TMP/ref" || { echo "FAIL fma_check: the oracle did not build"; exit 1; }
"$TMP/ref" > "$TMP/want" || { echo "FAIL fma_check: the oracle did not run"; exit 1; }
[ "$(wc -l < "$TMP/want")" -eq 6 ] || { echo "FAIL fma_check: the oracle printed $(wc -l < "$TMP/want") lines, want 6"; exit 1; }

# which families differ, by name
compare() { # leg file
  if ! cmp -s "$2" "$TMP/want"; then
    fam=$(diff "$2" "$TMP/want" | sed -n 's/^< \([a-z]*\) .*/\1/p' | tr '\n' ' ')
    fail "$1 differs from fma(3)${fam:+ in: $fam}"
    return 1
  fi
  return 0
}

legs=""
"$MERE" "$P" > "$TMP/interp" 2>"$TMP/err" || { fail "interp refused: $(head -1 "$TMP/err")"; }
compare interp "$TMP/interp" && legs="$legs interp"

if "$MERE" -c "$P" > "$TMP/p.c" 2>"$TMP/err"; then
  for o in -O0 -O2; do
    if "$CC" $o -w "$TMP/p.c" -lm -o "$TMP/pc"; then
      "$TMP/pc" > "$TMP/c" 2>&1; compare "C$o" "$TMP/c" && legs="$legs C$o"
    else fail "the emitted C did not build at $o"; fi
  done
else fail "mere -c refused: $(head -1 "$TMP/err")"; fi

if "$MERE" -ll "$P" > "$TMP/p.ll" 2>"$TMP/err"; then
  if "$CC" -O2 -w "$TMP/p.ll" -lm -o "$TMP/pl" 2>"$TMP/err"; then
    "$TMP/pl" > "$TMP/llvm" 2>&1; compare LLVM "$TMP/llvm" && legs="$legs LLVM"
  else fail "the emitted LLVM IR did not build: $(head -1 "$TMP/err")"; fi
else fail "mere -ll refused: $(head -1 "$TMP/err")"; fi

if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  if "$MERE" -w "$P" > "$TMP/p.wat" 2>"$TMP/err"; then
    grep -q 'func \$__lang_fma' "$TMP/p.wat" || fail "the Wasm has no \$__lang_fma -- the software path was not what ran"
    grep -q 'func \$mere_f64x2_fma_v' "$TMP/p.wat" || fail "the Wasm has no \$mere_f64x2_fma_v"
    if wat2wasm --enable-tail-call "$TMP/p.wat" -o "$TMP/p.wasm" 2>"$TMP/err"; then
      node "$ROOT/scripts/run_wasm.js" "$TMP/p.wasm" > "$TMP/wasm" 2>&1
      compare Wasm "$TMP/wasm" && legs="$legs Wasm"
    else fail "wat2wasm rejected the module: $(head -1 "$TMP/err")"; fi
  else fail "mere -w refused: $(head -1 "$TMP/err")"; fi
else
  fail "wat2wasm or node absent -- the software fma is the leg this gate exists for, and it did not run"
fi

# poison: the unfused expression under the same name must be caught
{ printf 'let fma = fn (a: float) -> fn (b: float) -> fn (c: float) -> a * b + c;\n'
  printf 'let f64x2_fma = fn (a: f64x2) -> fn (b: f64x2) -> fn (c: f64x2) -> f64x2_add (f64x2_mul a b) c;\n'
  cat "$P"; } > "$TMP/poison.mere"
"$MERE" "$TMP/poison.mere" > "$TMP/poison" 2>"$TMP/err" || fail "the poison did not run: $(head -1 "$TMP/err")"
if cmp -s "$TMP/poison" "$TMP/want"; then
  fail "POISON PASSED: a*b+c under the name fma matched fma(3) -- the inputs cannot tell one rounding from two"
fi
npois=$(diff "$TMP/poison" "$TMP/want" | grep -c '^<')

# RISC-V refuses by name
printf 'print (show (fma 2.0 3.0 1.0))\n' > "$TMP/rv.mere"
if "$MERE" -rv "$TMP/rv.mere" > "$TMP/rv.bin" 2>"$TMP/rv.err"; then
  fail "the RV32IM backend accepted fma"
else
  grep -q 'fma' "$TMP/rv.err" || fail "the RV32IM refusal does not name fma: $(head -1 "$TMP/rv.err")"
fi

[ "$fails" -eq 0 ] || exit 1
echo "fma_check: ok (6 families match fma(3) on$legs; the unfused poison differs in $npois of 6; RV refuses)"
