#!/bin/sh
# scripts/bigstr_check.sh — the string axis past what a 32-bit offset can name.
#
# Mere's int is 64-bit. Until v0.1.274 the runtimes that serve it were not: the
# C backend returned `str_len` through an `int` and took `str_repeat`'s count as
# one, and the LLVM backend truncated the same values in its IR. Nothing caught
# it, because every string in every test was small -- the axis had never been
# asked. A 2.15GB string is one byte of address past the boundary, and the
# answers were: a negative length, and a match offset that came back negative.
#
# Not part of scripts/parity.sh on purpose. One run costs about six seconds and
# 4.3GB of resident memory per backend, and the parity gate runs on every change;
# a gate that is too expensive to run is one people stop running.
#
# The Wasm backend is not here: its memory is a fixed 64MB, so a 2GB string is
# not a value that backend can hold. Asking it this question would measure the
# memory limit, not the width -- a different axis, and one that already has its
# own answer ("out of memory", checked in test/parity/fail/).
#
# Usage: sh scripts/bigstr_check.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-clang}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/big.mere" <<'EOF'
// 2,150,000,000 bytes: past 2^31, so a 32-bit length or offset goes negative.
let s = str_repeat "a" 2150000000;
let s2 = s ++ "needle";
let _ = print (str_of_int (str_len s2));
let _ = print (str_of_int (str_index_of s2 "needle"));
0
EOF

# 2150000000 + 6, and the needle sits at 2150000000
want="2150000006
2150000000
0"

fail=0
report() {
  if [ "$2" = "$want" ]; then
    printf "  ok    %-8s %s\n" "$1" "$(echo "$2" | tr '\n' ' ')"
  else
    printf "  FAIL  %-8s got: %s\n" "$1" "$(echo "$2" | tr '\n' ' ')"
    fail=1
  fi
}

report interp "$("$MERE" "$TMP/big.mere")"

"$MERE" -c "$TMP/big.mere" > "$TMP/big.c"
$CC -O2 -w "$TMP/big.c" -o "$TMP/big_c" -lm
report c "$("$TMP/big_c")"

"$MERE" -ll "$TMP/big.mere" > "$TMP/big.ll"
$CC -O2 -w "$TMP/big.ll" -o "$TMP/big_ll" -lm
report llvm "$("$TMP/big_ll")"

if [ "$fail" = 0 ]; then echo "bigstr_check: ok"; else echo "bigstr_check: FAILED"; exit 1; fi
