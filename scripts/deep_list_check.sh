#!/bin/sh
# scripts/deep_list_check.sh -- a long list is copied without a C frame per
# element (v0.1.605).
#
# The C backend's copiers (__mcopy_<tag> on store, __mdeep_<tag> for a region
# loop's carry) recursed into a recursive variant's every node, and a list's
# spine is one node per element: three million elements stored into a map ran
# out of the default 8 MB stack ("stack overflow (recursion too deep)"), and
# mere-ruby's `Array.new(10_000_000)` out of its 512 MB one. A constructor whose
# payload ENDS in the type itself is now walked as a loop along that field.
#
# The program stores a 3M-element int list and a 3M-element str list into maps
# and carries a 3M-element list through a region loop, under an 8 MB stack.
#
# --poison builds the program with the copier made recursive again (the loop's
# `continue` turned back into a call) and requires it to fail.
#
# The LLVM copier still recurses -- a 10M-element list carried out of a region
# overflows there -- and Wasm's is not measured (open).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-clang}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
want="4500001500000
3000000
4500001500000"

fail=0
"$MERE" -c test/deep_list/copy_long_list.mere > "$TMP/dl.c"
$CC -O1 -w "$TMP/dl.c" -o "$TMP/dl" -lm
got="$(ulimit -s 8192 2>/dev/null; "$TMP/dl" 2>&1 || true)"
if [ "$got" = "$want" ]; then
  echo "  ok    c       $(echo "$got" | tr '\n' ' ')"
else
  echo "  FAIL  c       got: $(echo "$got" | tr '\n' ' ')"
  fail=1
fi

if [ "${1:-}" = "--poison" ]; then
  # the spine step: `v = __next; continue;` becomes a recursive call for the rest
  perl -0pe 's/\*__slot = (list_int__mk\(__t, p\));\n(\s*)__slot = &p->payload\.Cons\.f1;\n\s*v = __next;\n\s*continue;/p->payload.Cons.f1 = __mcopy_list_int(r, __next);\n$2*__slot = $1;\n$2return __head;/' "$TMP/dl.c" > "$TMP/dlp.c"
  if cmp -s "$TMP/dl.c" "$TMP/dlp.c"; then
    echo "  FAIL  poison  the spine loop was not found to undo"; fail=1
  else
    $CC -O0 -w "$TMP/dlp.c" -o "$TMP/dlp" -lm
    pgot="$(ulimit -s 8192 2>/dev/null; "$TMP/dlp" 2>&1 || true)"
    if [ "$pgot" = "$want" ]; then
      echo "  FAIL  poison  the recursive copier still passed"; fail=1
    else
      echo "  ok    poison  the recursive copier fails: $(echo "$pgot" | head -1)"
    fi
  fi
fi

[ $fail -eq 0 ] && echo "deep_list_check: ok" || { echo "deep_list_check: FAILED"; exit 1; }
