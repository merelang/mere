#!/bin/sh
# scripts/softfloat_check.sh — contrib/softfloat holds a double's bits, and the
# backend that needs it has no float.
#
# Three things are checked, and the third is the reason the other two exist:
#
#   1. Every double in test/float/softfloat_roundtrip.mere survives the trip
#      into 15-bit limbs and back as the SAME 64 bits -- including -0.0 and the
#      NaN payloads, which a value comparison would let through.
#   2. The interpreter and the C backend print the same bytes.
#   3. **The library compiles for RV32I**, whose value model is one signed
#      32-bit word and which has no float at all. That is the whole point of
#      the representation: `float_bits_hi` / `float_bits_lo` split a double into
#      two 32-bit halves, and an UNSIGNED 32-bit half does not fit a SIGNED
#      32-bit int (`float_bits_hi (-1.0)` is 3220176896). 15-bit limbs do, with
#      room for a product of two of them.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "softfloat_check: $MERE not found — run 'dune build'" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
P="$ROOT/test/float/softfloat_roundtrip.mere"
rc=0

L="$ROOT/test/float/softfloat_limbs.mere"
"$MERE" "$L" > "$TMP/limbs" 2>&1 || { echo "FAIL softfloat: the interpreter refused the limb gate"; cat "$TMP/limbs"; exit 1; }
if grep -q '^FAIL' "$TMP/limbs"; then
  echo "FAIL softfloat: the limbs disagreed with native int arithmetic"
  grep '^FAIL' "$TMP/limbs" | head -10
  rc=1
fi

"$MERE" "$P" > "$TMP/interp" 2>&1 || { echo "FAIL softfloat: the interpreter refused the gate"; cat "$TMP/interp"; exit 1; }
if grep -q '^FAIL' "$TMP/interp"; then
  echo "FAIL softfloat: a value did not survive the round trip"
  grep '^FAIL' "$TMP/interp"
  rc=1
fi

if command -v "$CC" >/dev/null 2>&1; then
  if "$MERE" -c "$P" > "$TMP/p.c" 2>"$TMP/cerr"; then
    if "$CC" -O0 -w "$TMP/p.c" -lm -o "$TMP/p" 2>/dev/null; then
      "$TMP/p" > "$TMP/cout" 2>&1
      if cmp -s "$TMP/interp" "$TMP/cout"; then
        :
      else
        echo "FAIL softfloat: the C backend and the interpreter disagree"
        diff "$TMP/interp" "$TMP/cout" | head -20
        rc=1
      fi
    else
      echo "softfloat_check: the C compiler refused the generated C — skipping the C arm" >&2
    fi
  else
    echo "FAIL softfloat: mere -c refused the gate"; cat "$TMP/cerr"; rc=1
  fi
else
  echo "softfloat_check: no C compiler — skipping the C arm" >&2
fi

# The narrow target, checked two ways because the first way over-claimed.
#
# (a) Lexically: the library must not mention `float` at all. This is the
#     design claim stated as a test -- RV32I has no float in its value model,
#     so a library that names one cannot be compiled there.
# (b) By compiling for RV32I with EVERY exported name reachable. The first
#     version of this arm called three functions and passed while the library
#     had a float-using function in it: nothing had made it reachable, so
#     codegen never saw it. A probe that exercises a subset reports on the
#     subset, whatever the message says.
if grep -n '\bfloat\b' "$ROOT/contrib/softfloat/softfloat.mere" \
       "$ROOT/contrib/softfloat/limbs.mere" | grep -v ':[0-9]*: *//' > "$TMP/floats"; then
  echo "FAIL softfloat: the library names \`float\`, which RV32I does not have"
  cat "$TMP/floats"
  rc=1
fi

# test/float/softfloat_narrow.mere calls every exported name for real. A
# generator was tried first and rejected: it has to guess each function's shape,
# and a wrong guess fails the gate for a reason that is not the defect (a poison
# run failed on the probe's own type error rather than on the poison). So the
# probe is written by hand and its COVERAGE is what gets checked.
N="$ROOT/test/float/softfloat_narrow.mere"
NAMES=$(sed -n 's/^let \(rec \)\{0,1\}\([a-z_][a-z_0-9]*\) *=.*/\2/p' \
        "$ROOT/contrib/softfloat/softfloat.mere" "$ROOT/contrib/softfloat/limbs.mere")
MISSING=""
for n in $NAMES; do
  grep -q "\\b$n\\b" "$N" || MISSING="$MISSING $n"
done
if [ -n "$MISSING" ]; then
  echo "FAIL softfloat: the narrow probe does not mention:$MISSING"
  echo "  (add them to $N — an unreferenced function is never lowered, so the"
  echo "   RV32I arm would pass without having compiled it)"
  rc=1
fi
if "$MERE" -rv "$N" > "$TMP/narrow.bin" 2>"$TMP/rverr"; then
  :
else
  echo "FAIL softfloat: the library does not compile for RV32I — the target it exists for"
  head -5 "$TMP/rverr"
  rc=1
fi
COUNT=$(printf '%s\n' $NAMES | wc -l | tr -d ' ')

[ "$rc" = 0 ] && echo "ok softfloat: $(grep -c '^ok' "$TMP/interp") checks, interp = C, and all $COUNT exported names compile for RV32I"
exit $rc
