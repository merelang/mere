#!/bin/sh
# scripts/ffi_header_check.sh — the C side of an `extern fn` includes a header
# the compiler wrote, instead of copying the layout.
#
# Q-120. `extern fn` carries float, record-by-value and `bytes` on the C and
# LLVM backends. What it does not carry is a way for the author of the other
# side to KNOW what those look like: the `mu_` field prefix, the field order,
# and the fact that a boundary `int` is C's 32-bit `int` and not `long long`
# are all the generator's choices. Shims wrote them out by hand:
#
#     typedef struct { double mu_x, mu_y, mu_z; } v3;   /* copied */
#
# which is an ABI held together by two people agreeing. An `extern` declaration
# is a promise, not a check.
#
# WHAT IS CHECKED
#   A. a shim that INCLUDES `mere --ffi-header` links and computes right
#   B. generating the header twice gives the same bytes
#   C. ⚠ THE POINT: reorder the record's fields in the MERE source and the
#      shim's answer changes. That is what says the shim is bound to the
#      generated layout rather than to a copy that happens to agree today.
#   D. the header carries only what the boundary reaches -- an internal record
#      does not leak into a file the other side compiles against
#
# Usage:
#   sh scripts/ffi_header_check.sh            # check
#   sh scripts/ffi_header_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "ffi_header: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
command -v "$CC" >/dev/null 2>&1 || { echo "ffi_header: no C compiler — skipping"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MODE="${1:-}"
fail=0

# `secret` is declared and used only inside the program: it must NOT reach the
# header. `v3` is at the boundary: it must.
write_prog() { # $1 = field order for v3
  cat > "$T/p.mere" <<EOF
type v3 = { $1 };
type secret = { hidden: int };
extern fn my_dot: v3 -> v3 -> float;
extern fn my_bytes_sum: bytes -> int;
let s = secret { hidden = 1 };
let a = v3 { x = 1.0, y = 2.0, z = 3.0 };
let b = v3 { x = 4.0, y = 5.0, z = 6.0 };
print_int (int_of_float (my_dot a b) + my_bytes_sum (bytes_of_str "abc") + s.hidden)
EOF
}
# The shim NEVER writes the struct out: it includes the header and reads fields
# by name. Whatever order the header gives, `mu_x` is x.
# ⚠ WEIGHTED, NOT A DOT PRODUCT. The first version summed x*x + y*y + z*z,
# which is the same number however the fields are permuted -- so POISON 1, where
# a hand-copied struct has the WRONG order, still came out right and the gate
# could not tell a copy from the header. The weights make the order readable.
cat > "$T/shim.c" <<'EOF'
#include "mere_extern.h"
double my_dot(v3 a, v3 b) { (void)b; return a.mu_x * 100.0 + a.mu_y * 10.0 + a.mu_z; }
int my_bytes_sum(mere_bytes* b) {
  int t = 0; for (long long i = 0; i < b->len; i++) t += b->data[i];
  return t;
}
EOF

build_and_run() { # -> prints the program's output, or nothing
  "$MERE" --ffi-header "$T/p.mere" > "$T/mere_extern.h" 2>/dev/null || return 1
  "$MERE" -c "$T/p.mere" > "$T/p.c" 2>/dev/null || return 1
  ( cd "$T" && "$CC" -w -O0 -o prog p.c shim.c -lm ) 2>/dev/null || return 1
  "$T/prog" 2>/dev/null | tail -1
}

# --- A: it links and computes -----------------------------------------------
write_prog "x: float, y: float, z: float"
got=$(build_and_run)
# weighted = 100*1 + 10*2 + 3 = 123, bytes "abc" = 97+98+99 = 294, hidden 1 => 418
if [ "$got" = "418" ]; then
  printf '  ok    %s\n' "a shim that includes the generated header links and computes (418)"
else
  printf '  FAIL  %s\n' "the shim gave \"$got\", wanted 418"
  fail=1
fi

# --- D: only what the boundary reaches --------------------------------------
if grep -q 'struct v3' "$T/mere_extern.h" && grep -q 'mere_bytes' "$T/mere_extern.h"; then
  if grep -q 'secret' "$T/mere_extern.h"; then
    printf '  FAIL  %s\n' "an internal record leaked into the header"
    fail=1
  else
    printf '  ok    %s\n' "the header carries the boundary types and not the internal one"
  fi
else
  printf '  FAIL  %s\n' "the header is missing a type the boundary uses"
  fail=1
fi

# --- B: regenerating gives the same bytes -----------------------------------
"$MERE" --ffi-header "$T/p.mere" > "$T/h2" 2>/dev/null
if cmp -s "$T/mere_extern.h" "$T/h2"; then
  printf '  ok    %s\n' "generating it twice gives the same bytes"
else
  printf '  FAIL  %s\n' "the header is not a function of the program"
  fail=1
fi

# --- C: ⚠ the shim is bound to the generated layout -------------------------
# Reordering the fields in the MERE source moves them in the struct. The shim
# reads by NAME, so it still computes the dot product -- and the program's own
# literals are positional-by-name too, so the answer must stay 418. What this
# proves is that the shim compiled against a layout it did not choose: with a
# hand-copied struct the field order would now disagree and the answer would
# not be 418.
write_prog "z: float, x: float, y: float"
got=$(build_and_run)
if [ "$got" = "418" ]; then
  printf '  ok    %s\n' "reordering the record in the Mere source keeps the shim right"
else
  printf '  FAIL  %s\n' "after reordering the shim gave \"$got\", wanted 418"
  fail=1
fi

if [ "$MODE" = "--poison" ]; then
  pfail=0
  # POISON 1: ⚠ A HAND-COPIED STRUCT IS WHAT THIS REPLACES, so show it breaking.
  # Same shim, but writing the layout out in the order the source USED to have.
  cat > "$T/hand.c" <<'EOF'
struct mere_bytes { long long len; unsigned char data[]; };
typedef struct { double mu_x, mu_y, mu_z; } v3;   /* copied, and now stale */
double my_dot(v3 a, v3 b) { (void)b; return a.mu_x * 100.0 + a.mu_y * 10.0 + a.mu_z; }
int my_bytes_sum(struct mere_bytes* b) {
  int t = 0; for (long long i = 0; i < b->len; i++) t += b->data[i];
  return t;
}
EOF
  write_prog "z: float, x: float, y: float"
  "$MERE" -c "$T/p.mere" > "$T/p.c" 2>/dev/null
  if ( cd "$T" && "$CC" -w -O0 -o handprog p.c hand.c -lm ) 2>/dev/null; then
    hgot=$("$T/handprog" 2>/dev/null | tail -1)
    if [ "$hgot" = "418" ]; then
      printf '  FAIL  %s\n' "POISON 1: a stale hand-copied struct still gave the right answer — the fixture cannot tell a copy from the header"
      pfail=1
    else
      printf '  ok    %s\n' "POISON 1 (hand-copied, stale order): the answer changes ($hgot), which is what the header prevents"
    fi
  else
    printf '  ok    %s\n' "POISON 1 (hand-copied, stale order): it does not even build"
  fi
  # POISON 2: an empty header must not compile. If the shim builds without it,
  # direction A is passing for a reason that has nothing to do with the header.
  write_prog "x: float, y: float, z: float"
  "$MERE" -c "$T/p.mere" > "$T/p.c" 2>/dev/null
  : > "$T/mere_extern.h"
  if ( cd "$T" && "$CC" -w -O0 -o emptyprog p.c shim.c -lm ) 2>/dev/null; then
    printf '  FAIL  %s\n' "POISON 2: the shim built with an EMPTY header — it is not reading it"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 2 (empty header): the shim stops compiling, so it really includes it"
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "ffi_header --poison: ok (the gate can go red)"
  else
    echo "ffi_header --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "ffi_header: ok"; else echo "ffi_header: FAILED"; fi
exit "$fail"
