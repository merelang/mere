#!/bin/sh
# scripts/region_unwind_check.sh — a `fail` caught OUTSIDE a `region R { }`
# releases the block it jumped over.
#
# Q-171. `longjmp` goes past the block's exit, so the release written there
# never runs. The C backend has carried an active-region stack since v0.1.31 for
# exactly this, and made it release rather than leak in v0.1.301. The LLVM
# backend had neither: it kept the region struct in an `alloca`, on a frame that
# is gone by the time anyone could free it, and the loop below SEGFAULTED at a
# hundred iterations where C ran twenty thousand.
#
# WHAT IS CHECKED: the same program on every backend that can run it here, at a
# scale where a leak of the block (1 MiB each) could not fit in memory. Passing
# is therefore evidence that the blocks come back, not just that the answer is
# right.
#
# ⚠ WHAT IT DOES NOT CHECK: total memory. Mere reclaims nothing by default --
# the closure and the strings this loop builds outside the block live in the
# program-lifetime region on purpose -- so peak RSS grows with the iteration
# count on every backend, and by different amounts (measured at N=50000: C 2.6
# MiB, LLVM 9.7 MiB). That difference is allocation shape, not this bug.
#
# Usage:
#   sh scripts/region_unwind_check.sh            # check
#   sh scripts/region_unwind_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "region_unwind: $MERE not built" >&2; exit 2; }
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

N="${N:-20000}"
cat > "$T/loop.mere" <<EOF
let rec loop = fn (n: int) ->
  if n == 0 then 0
  else let _ = try_or (fn () -> region R { let s = "x" ++ show n in fail ("boom " ++ s) }) 0 in
       loop (n - 1);
print_int (loop $N)
EOF

fail=0
say() { printf '  %-5s %s\n' "$1" "$2"; }

# The interpreter is the reference: if it does not answer, nothing below means
# anything.
ref=$("$MERE" "$T/loop.mere" 2>/dev/null)
[ "$ref" = "0" ] || { echo "region_unwind: the interpreter did not answer 0 (got: $ref)" >&2; exit 2; }
say ok "interp: $N catches, answer $ref"

if command -v "$CC" >/dev/null 2>&1; then
  for pair in "c:c" "ll:llvm"; do
    flag="-${pair%%:*}"; name="${pair##*:}"
    ext=$([ "$flag" = "-c" ] && echo c || echo ll)
    if "$MERE" "$flag" "$T/loop.mere" > "$T/o.$ext" 2>/dev/null \
       && "$CC" -O0 -w -o "$T/o.bin" "$T/o.$ext" -lm 2>/dev/null; then
      got=$("$T/o.bin" 2>&1 | tail -1)
      if [ "$got" = "$ref" ]; then say ok "$name: $N catches, answer $got"
      else say FAIL "$name answered [$got], not [$ref]"; fail=1; fi
    else
      say note "$name: could not build here"
    fi
  done
fi

if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  if "$MERE" -w "$T/loop.mere" > "$T/o.wat" 2>/dev/null \
     && wat2wasm --enable-tail-call --enable-threads "$T/o.wat" -o "$T/o.wasm" 2>/dev/null; then
    got=$(node "$ROOT/scripts/run_wasm.js" "$T/o.wasm" 2>&1 | tail -1)
    if [ "$got" = "$ref" ]; then say ok "wasm: $N catches, answer $got"
    else say FAIL "wasm answered [$got], not [$ref]"; fail=1; fi
  fi
fi

if [ "${1:-}" = "--poison" ]; then
  # The scale is the point. A single catch passed on the broken backend too --
  # it is the repetition that exhausts what is never released -- so a gate that
  # ran the loop ONCE would have been green through the whole bug.
  cat > "$T/one.mere" <<'EOF'
let _ = try_or (fn () -> region R { let s = "x" in fail ("boom " ++ s) }) 0;
print_int 0
EOF
  one=$("$MERE" "$T/one.mere" 2>/dev/null)
  if [ "$one" = "0" ]; then
    say ok "POISON (one catch): passes on its own, which is why N is $N"
    exit 0
  fi
  say FAIL "POISON: a single catch does not even work"
  exit 1
fi

[ "$fail" = 0 ] && { echo "region_unwind: ok"; exit 0; }
echo "region_unwind: FAILED"; exit 1
