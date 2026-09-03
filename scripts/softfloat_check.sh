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
# What this gate does NOT see: the 15-bit limb width exists so that a product of
# two limbs fits a SIGNED 32-BIT int, and both arms here run on backends whose
# int is 63 or 64 bits. A schoolbook loop that accumulated a column before
# carrying would be arithmetically right on both and overflow on the target.
# Compiling for RV32I (check 3) proves the code is expressible there, not that
# the widths hold. That one is checked by running the library on a 32-bit
# machine, which needs an emulator this repository does not depend on --
# see docs/bare-metal.md for the ones that do.
#
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

C2="$ROOT/test/float/softfloat_conv.mere"
"$MERE" "$C2" > "$TMP/conv" 2>&1 || { echo "FAIL softfloat: the interpreter refused the conv gate"; cat "$TMP/conv"; exit 1; }
if grep -q '^FAIL' "$TMP/conv"; then
  echo "FAIL softfloat: a conversion disagreed with the hardware"
  grep '^FAIL' "$TMP/conv" | head -8
  rc=1
fi

Q="$ROOT/test/float/softfloat_sqrt.mere"
"$MERE" "$Q" > "$TMP/sqrt" 2>&1 || { echo "FAIL softfloat: the interpreter refused the sqrt gate"; cat "$TMP/sqrt"; exit 1; }
if grep -q '^FAIL' "$TMP/sqrt"; then
  echo "FAIL softfloat: a square root did not match the hardware bit for bit"
  grep '^FAIL' "$TMP/sqrt" | head -8
  rc=1
fi

D="$ROOT/test/float/softfloat_div.mere"
"$MERE" "$D" > "$TMP/div" 2>&1 || { echo "FAIL softfloat: the interpreter refused the div gate"; cat "$TMP/div"; exit 1; }
if grep -q '^FAIL' "$TMP/div"; then
  echo "FAIL softfloat: a quotient did not match the hardware bit for bit"
  grep '^FAIL' "$TMP/div" | head -8
  rc=1
fi

M2="$ROOT/test/float/softfloat_mul.mere"
"$MERE" "$M2" > "$TMP/mul" 2>&1 || { echo "FAIL softfloat: the interpreter refused the mul gate"; cat "$TMP/mul"; exit 1; }
if grep -q '^FAIL' "$TMP/mul"; then
  echo "FAIL softfloat: a product did not match the hardware bit for bit"
  grep '^FAIL' "$TMP/mul" | head -8
  rc=1
fi

A="$ROOT/test/float/softfloat_add.mere"
"$MERE" "$A" > "$TMP/add" 2>&1 || { echo "FAIL softfloat: the interpreter refused the add gate"; cat "$TMP/add"; exit 1; }
if grep -q '^FAIL' "$TMP/add"; then
  echo "FAIL softfloat: a sum did not match the hardware bit for bit"
  grep '^FAIL' "$TMP/add" | head -8
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

# The decimal conversions against the hardware's strtod/printf. Compiled via the
# C backend rather than interpreted: the battery ends with two thousand
# full-range patterns, and the interpreter takes minutes where the binary takes
# a second -- a gate nobody runs is not a gate.
DC="$ROOT/test/float/softfloat_dec.mere"
"$MERE" -c "$DC" > "$TMP/dec.c" 2>"$TMP/decerr" || { echo "FAIL softfloat: the C backend refused the dec gate"; head -3 "$TMP/decerr"; exit 1; }
$CC -O2 -w -o "$TMP/dec" "$TMP/dec.c" 2>"$TMP/decerr" || { echo "FAIL softfloat: cc refused the dec gate"; head -3 "$TMP/decerr"; exit 1; }
"$TMP/dec" > "$TMP/dec.out" 2>&1
if grep -q FAIL "$TMP/dec.out"; then
  echo "FAIL softfloat: a decimal conversion disagreed with the hardware"
  grep FAIL "$TMP/dec.out" | head -5
  rc=1
fi
DCOUNT=$(grep -c '^ok' "$TMP/dec.out")

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
#     bits.mere is the one exemption, by name: it is the bridge between hardware
#     doubles and the limbs, so mentioning float is its whole job. The list of
#     files to check is a glob minus that one name rather than six paths spelled
#     out -- a seventh file added to the library is checked the day it appears,
#     which a hand-kept list would not do.
for f in "$ROOT"/contrib/softfloat/*.mere; do
  case "$(basename "$f")" in bits.mere) continue ;; esac
  # -H keeps the filename prefix that the comment filter below matches against,
  # and that a failure message needs in order to say which file. grep drops it
  # when handed a single path, which the six-path version never hit.
  # String literals are stripped before the grep: dec.mere's parse error says
  # "is not a valid float" because that is the message the interpreter and the
  # C runtime both produce, and a string cannot be a type. The rule is about
  # the TYPE appearing, and sed removing "..." spans keeps it about that.
  sed 's/"[^"]*"//g' "$f" | grep -n '\bfloat\b' | grep -v '^[0-9]*: *//' \
    | sed "s|^|$f:|" >> "$TMP/floats" || true
done
if [ -s "$TMP/floats" ]; then
  echo "FAIL softfloat: the library names \`float\`, which RV32I does not have"
  cat "$TMP/floats"
  rc=1
fi
# ...and the exemption has to still be earning it. A bits.mere that stopped
# mentioning float would mean the bridge had moved or gone, and the exemption
# above would be quietly excusing a file that no longer needs it.
if ! grep -q '\bfloat\b' "$ROOT/contrib/softfloat/bits.mere"; then
  echo "FAIL softfloat: bits.mere is exempt from the no-float rule but does not use float"
  rc=1
fi

# test/float/softfloat_narrow.mere calls every exported name for real. A
# generator was tried first and rejected: it has to guess each function's shape,
# and a wrong guess fails the gate for a reason that is not the defect (a poison
# run failed on the probe's own type error rather than on the poison). So the
# probe is written by hand and its COVERAGE is what gets checked.
N="$ROOT/test/float/softfloat_narrow.mere"
# The bridge gets its own probe: softfloat_narrow.mere's claim is a program with
# NO float in it, and bits.mere cannot be called without one.
NB="$ROOT/test/float/softfloat_narrow_bits.mere"
# Globbed and deduped rather than spelled out. The list this replaces named six
# paths and named div.mere and conv.mere TWICE, so the count it reported -- the
# number this gate prints as its headline -- was inflated by the repeats while
# the coverage loop simply checked those names a second time. A derived list
# cannot say a number the library does not have.
NAMES=$(sed -n 's/^let \(rec \)\{0,1\}\([a-z_][a-z_0-9]*\) *=.*/\2/p' \
        "$ROOT"/contrib/softfloat/*.mere | sort -u)
MISSING=""
for n in $NAMES; do
  grep -q "\\b$n\\b" "$N" || grep -q "\\b$n\\b" "$NB" || MISSING="$MISSING $n"
done
if [ -n "$MISSING" ]; then
  echo "FAIL softfloat: the narrow probe does not mention:$MISSING"
  echo "  (add them to $N or $NB — an unreferenced function is never lowered, so the"
  echo "   RV32I arm would pass without having compiled it)"
  rc=1
fi
if "$MERE" -rv "$N" > "$TMP/narrow.bin" 2>"$TMP/rverr" \
   && "$MERE" -rv "$NB" > "$TMP/narrow_bits.bin" 2>>"$TMP/rverr"; then
  :
else
  echo "FAIL softfloat: the library does not compile for RV32I — the target it exists for"
  head -5 "$TMP/rverr"
  rc=1
fi
COUNT=$(printf '%s\n' $NAMES | wc -l | tr -d ' ')

[ "$rc" = 0 ] && echo "ok softfloat: $(grep -c '^ok' "$TMP/interp") checks + $DCOUNT decimal-conversion checks, interp = C, and all $COUNT exported names compile for RV32I"
exit $rc
