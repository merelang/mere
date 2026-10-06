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
# v0.1.621 (Q-201): LLVM's and Wasm's copiers recursed too, and there a list of
# 100,000 carried out of a `region` block overflowed the stack. They walk the
# spine the same way now. test/deep_list/region_out_long_list.mere carries four
# long values out of region blocks (ints, strs, a list of tuples, a tree along
# its last field) and runs on C, LLVM and Wasm; its --poison turns each
# backend's loop back into a call to itself. (LLVM and Wasm have no
# `region R loop`, so the first program stays C's.)
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


# --- carried out of a region block: C, LLVM, Wasm --------------------------
want2="45000150000
600000
45000450000
10000100000"
RO=test/deep_list/region_out_long_list.mere
run_c() { $CC -O1 -w "$1" -o "$TMP/ro" -lm && (ulimit -s 8192 2>/dev/null; "$TMP/ro" 2>&1 || true); }
run_ll() { $CC -O0 -w "$1" -o "$TMP/rol" -lm && (ulimit -s 8192 2>/dev/null; "$TMP/rol" 2>&1 || true); }
run_w() { wat2wasm --enable-tail-call --enable-threads "$1" -o "$TMP/ro.wasm" && (node scripts/run_wasm.js "$TMP/ro.wasm" 2>&1 || true); }
# the spine step made a call to the function itself again, per backend
poison_ll() {
  perl -0pe 's{(define \S+ \@(__mcopy_\w+)\(.*?\n\})}{ my ($b, $f) = ($1, $2);
    $b =~ s/  store ptr (%t\d+), ptr %slotp\n  (%t(\d+)) = extractvalue (%\S+) (%t\d+), (\d+)\n  store ptr \2, ptr %curp\n  br label %mc_loop/  $2 = extractvalue $4 $5, $6\n  %pz$3 = call ptr \@$f(ptr %r, ptr $2)\n  store ptr %pz$3, ptr $1\n  br label %mc_done/g; $b }gse' "$1"
}
poison_w() {
  perl -0pe 's{(\(func \$(__mcopy_\w+) (?:(?!\(func ).)*?\(i64\.extend_i32_u \(local\.get \$head\)\)\))}{ my ($b, $f) = ($1, $2);
    $b =~ s/\(local\.set \$slot \(i32\.add \(local\.get \$tp\) \(i32\.const (\d+)\)\)\)\n(\s*)\(local\.set \$v \(i64\.load offset=\d+ \(local\.get \$ts\)\)\)\n\s*\(br \$lp\)/(i64.store offset=$1 (local.get \$tp) (call \$$f (i64.load offset=$1 (local.get \$ts))))\n$2(br \$done)/g; $b }gse' "$1"
}
check_leg() {  # name, emit flag, ext, runner, poisoner
  name=$1; flag=$2; ext=$3; runner=$4; poisoner=$5
  "$MERE" "$flag" "$RO" > "$TMP/ro.$ext"
  got2="$($runner "$TMP/ro.$ext")"
  if [ "$got2" = "$want2" ]; then echo "  ok    $name   $(echo "$got2" | tr '\n' ' ')"
  else echo "  FAIL  $name   got: $(echo "$got2" | tr '\n' ' ' | cut -c1-100)"; fail=1; fi
  if [ "${POISON:-}" = 1 ] && [ -n "$poisoner" ]; then
    $poisoner "$TMP/ro.$ext" > "$TMP/rop.$ext"
    if cmp -s "$TMP/ro.$ext" "$TMP/rop.$ext"; then
      echo "  FAIL  poison $name  the spine loop was not found to undo"; fail=1
    else
      pgot2="$($runner "$TMP/rop.$ext")"
      if [ "$pgot2" = "$want2" ]; then echo "  FAIL  poison $name  the recursive copier still passed"; fail=1
      else echo "  ok    poison $name  the recursive copier fails: $(echo "$pgot2" | head -1 | cut -c1-60)"; fi
    fi
  fi
}
[ "${1:-}" = "--poison" ] && POISON=1
check_leg c -c c run_c ""
check_leg llvm -ll ll run_ll poison_ll
if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  check_leg wasm -w wat run_w poison_w
else
  echo "  SKIP  wasm   (wat2wasm / node not found)"
fi

[ $fail -eq 0 ] && echo "deep_list_check: ok" || { echo "deep_list_check: FAILED"; exit 1; }
