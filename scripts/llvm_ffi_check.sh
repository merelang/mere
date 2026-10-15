#!/bin/sh
# scripts/llvm_ffi_check.sh -- the externs the compiler implements itself, on
# the LLVM backend (v0.1.670).
#
# WHAT THIS IS. The C backend emits about a hundred `extern fn`s itself (the
# byte arena, sockets, readiness, fd_*, file_* metadata, proc_*, the crypto
# helpers). The LLVM backend had none of them, so a program that declared one
# emitted and did not link -- mere-ruby among them. Now `mere --ffi-c` prints
# the same C runtime, behind a wrapper per extern that takes Mere's types, and
# clang links it beside the IR. This asks whether the result answers what the
# C backend's program answers:
#
#   1. test/llvmffi/native_probe.mere on C and on LLVM: the whole transcript,
#      which includes several negative ints coming back from `int` functions
#      (what a bare `declare i64` of one does not promise).
#   2. The four probes that already have expected transcripts -- fdio,
#      filestat, proclimit, procsig -- built as LLVM (MERE_BACKEND=llvm).
#   3. `--ffi-c` refuses the HTTP server's externs by name (they run each
#      request in the C runtime's region), and prints a comment for a program
#      that declares none, which still links.
#   4. A user's own C side (test/llvmffi/user_shim.c, built -O2): `int` crosses
#      as C's 32-bit int and a returned `str` is a bare C string, as the C
#      backend's prototypes have it. LLVM declared both as Mere has them and
#      read -5 as 4294967291 and the string as "".
#
# --poison: the companion's wrappers return the runtime's `int` zero-extended,
# and the user extern's `int` answer is zero-extended in the IR. Both probes
# must go red, or nothing here sees why the conversions exist.
#
# Usage: sh scripts/llvm_ffi_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
LLVM_CC="${LLVM_CC:-clang}"
[ -x "$MERE" ] || { echo "llvm_ffi: $MERE not found -- run 'dune build'" >&2; exit 1; }
command -v "$LLVM_CC" >/dev/null 2>&1 || { echo "FAIL llvm_ffi: no $LLVM_CC"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
P="$ROOT/test/llvmffi/native_probe.mere"
fail=0

"$MERE" -c "$P" > "$T/c.c" 2>/dev/null && "$CC" -O1 -w "$T/c.c" -o "$T/c" -lm \
  || { echo "FAIL llvm_ffi: the C reference did not build"; exit 1; }
"$MERE" -ll "$P" > "$T/l.ll" 2>/dev/null || { echo "FAIL llvm_ffi: mere -ll refused the probe"; exit 1; }
"$MERE" --ffi-c "$P" > "$T/l_ffi.c" 2>/dev/null || { echo "FAIL llvm_ffi: mere --ffi-c refused the probe"; exit 1; }
if [ "${1:-}" = --poison ]; then
  sed 's/return (long long)__mrt_/return (long long)(unsigned int)__mrt_/' "$T/l_ffi.c" > "$T/q.c"
  cmp -s "$T/l_ffi.c" "$T/q.c" && { echo "FAIL llvm_ffi --poison: the poison did not apply"; exit 1; }
  mv "$T/q.c" "$T/l_ffi.c"
fi
"$LLVM_CC" -O1 -w "$T/l.ll" "$T/l_ffi.c" -o "$T/l" -lm -lpthread 2>"$T/link.err" \
  || { echo "FAIL llvm_ffi: the IR and its runtime did not link"; sed -n '1,5p' "$T/link.err"; exit 1; }
want=$(sh "$ROOT/scripts/bounded.sh" 30 "$T/c" 2>&1); got=$(sh "$ROOT/scripts/bounded.sh" 30 "$T/l" 2>&1)

# the user's own C side, built as its author would
SHIM="$ROOT/test/llvmffi/user_shim"
"$LLVM_CC" -O2 -w -c "$SHIM.c" -o "$T/shim.o" || { echo "FAIL llvm_ffi: the user shim did not compile"; exit 1; }
"$MERE" -c "$SHIM.mere" > "$T/u.c" 2>/dev/null && "$CC" -O1 -w "$T/u.c" "$T/shim.o" -o "$T/uc" \
  || { echo "FAIL llvm_ffi: the user-shim C reference did not build"; exit 1; }
"$MERE" -ll "$SHIM.mere" > "$T/u.ll" 2>/dev/null || { echo "FAIL llvm_ffi: mere -ll refused the user-shim probe"; exit 1; }
if [ "${1:-}" = --poison ]; then
  sed 's/= sext i32 /= zext i32 /' "$T/u.ll" > "$T/uq.ll"
  cmp -s "$T/u.ll" "$T/uq.ll" && { echo "FAIL llvm_ffi --poison: the user-shim poison did not apply"; exit 1; }
  mv "$T/uq.ll" "$T/u.ll"
fi
"$LLVM_CC" -O1 -w "$T/u.ll" "$T/shim.o" -o "$T/ul" || { echo "FAIL llvm_ffi: the user-shim IR did not link"; exit 1; }
uwant=$("$T/uc" 2>&1); ugot=$("$T/ul" 2>&1)

if [ "${1:-}" = --poison ]; then
  [ "$want" != "$got" ] && [ "$uwant" != "$ugot" ] \
    && { echo "llvm_ffi --poison: ok (a zero-extended int answer goes red, from the runtime and from a user's C)"; exit 0; }
  echo "llvm_ffi --poison: POISON PASSED -- native probe red: $([ "$want" != "$got" ] && echo yes || echo no), user shim red: $([ "$uwant" != "$ugot" ] && echo yes || echo no)"; exit 1
fi
if [ "$uwant" = "$ugot" ]; then echo "  ok    a user's extern fns: C's int and C's string at the boundary ($(echo $ugot))"
else echo "  FAIL  user shim: C [$(echo $uwant)] LLVM [$(echo $ugot)]"; fail=1; fi
if [ "$want" = "$got" ]; then echo "  ok    native_probe ($(printf '%s\n' "$want" | wc -l | tr -d ' ') lines agree with C)"
else echo "  FAIL  native_probe (C, then LLVM):"; printf '%s\n' "$want" > "$T/w"; printf '%s\n' "$got" > "$T/g"
     diff "$T/w" "$T/g" | head -10 | sed 's/^/        /'; fail=1; fi

for s in fdio filestat proclimit procsig; do
  out=$(MERE_BACKEND=llvm sh "$ROOT/scripts/${s}_check.sh" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then echo "  ok    $s on LLVM: $(printf '%s\n' "$out" | tail -1)"
  else echo "  FAIL  $s on LLVM:"; printf '%s\n' "$out" | tail -8 | sed 's/^/        /'; fail=1; fi
done

printf 'extern fn http_serve: int -> (str -> str) -> unit;\nprint "x"\n' > "$T/h.mere"
if "$MERE" --ffi-c "$T/h.mere" > /dev/null 2> "$T/h.err"; then
  echo "  FAIL  --ffi-c accepted http_serve, whose server runs in the C runtime's region"; fail=1
elif grep -q 'http_serve' "$T/h.err"; then echo "  ok    --ffi-c refuses http_serve by name"
else echo "  FAIL  --ffi-c refused http_serve without naming it: $(head -1 "$T/h.err")"; fail=1; fi

printf 'print "plain"\n' > "$T/n.mere"
"$MERE" -ll "$T/n.mere" > "$T/n.ll" && "$MERE" --ffi-c "$T/n.mere" > "$T/n_ffi.c" \
  && "$LLVM_CC" -w "$T/n.ll" "$T/n_ffi.c" -o "$T/n" 2>/dev/null && [ "$("$T/n")" = plain ] \
  && echo "  ok    a program with no native externs: --ffi-c is a comment, and it still links" \
  || { echo "  FAIL  a program with no native externs did not build with its --ffi-c"; fail=1; }

[ "$fail" = 0 ] || { echo "FAIL llvm_ffi"; exit 1; }
echo "llvm_ffi: ok (the native runtime on LLVM answers as C's does)"
