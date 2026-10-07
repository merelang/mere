#!/bin/sh
# sys_info_check.sh -- sys_os / sys_arch answer for the ABI each backend runs
# under (v0.1.642).
#
# A program that names errno or socket constants by number has to know whose
# numbers they are: mere-ruby's tables were macOS's, fixed, and on RISC-V (a
# Linux program) or a Linux host they were wrong. The interpreter, C and LLVM
# answer for this machine (C through the preprocessor of the compiler the
# emitted C meets, so a cross-compiled C program answers for its target), Wasm
# answers "wasi" / "wasm32", and RISC-V "linux" and its width.
#
# The host's answer is uname's, in sys_os's names. --poison makes the C
# program answer for some other machine and checks that the gate notices.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
[ -x "$MERE" ] || { echo "sys_info: $MERE not found -- run 'dune build'" >&2; exit 1; }
CC="${CC:-cc}"
MODE="${1:-}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0

case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) os=unknown ;; esac
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; x86_64|amd64) arch=x86_64 ;; *) arch="$(uname -m)" ;; esac
host="$os $arch"

printf 'let _ = print (sys_os ());\nprint (sys_arch ())\n' > "$TMP/s.mere"
check() {  # $1 = backend, $2 = wanted, $3 = got
  if [ "$3" = "$2" ]; then echo "  ok    $1: $3"
  else echo "  FAIL  $1: got [$3], wanted [$2]"; rc=1; fi
}
line() { tr '\n' ' ' | sed 's/ $//'; }

check interp "$host" "$("$MERE" "$TMP/s.mere" 2>&1 | line)"

"$MERE" -c "$TMP/s.mere" > "$TMP/c.c" 2>/dev/null || { echo "  FAIL  C: did not emit"; exit 1; }
if [ "$MODE" = "--poison" ]; then
  # the preprocessor asked about some other machine
  sed 's/defined(__APPLE__)/defined(__no_such_os__)/; s/defined(__linux__)/defined(__no_such_os__)/' "$TMP/c.c" > "$TMP/p.c"
  $CC -O1 -w "$TMP/p.c" -o "$TMP/c" 2>/dev/null || { echo "  FAIL  poison: C did not build"; exit 1; }
  got="$("$TMP/c" | line)"
  if [ "$got" = "$host" ]; then echo "sys_info: POISON FAILED -- C still answered [$got]"; exit 1; fi
  echo "sys_info: poison ok -- the C program asked about another machine answered [$got]"; exit 0
fi
$CC -O1 -w "$TMP/c.c" -o "$TMP/c" 2>/dev/null || { echo "  FAIL  C: did not build"; exit 1; }
check C "$host" "$("$TMP/c" | line)"

if command -v clang >/dev/null 2>&1 && "$MERE" -ll "$TMP/s.mere" > "$TMP/l.ll" 2>/dev/null \
   && clang -w "$TMP/l.ll" -o "$TMP/l" -lm 2>/dev/null; then
  check LLVM "$host" "$("$TMP/l" | line)"
else echo "  -     LLVM not checked (no clang)"; fi

if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 \
   && "$MERE" -w "$TMP/s.mere" > "$TMP/w.wat" 2>/dev/null \
   && wat2wasm --enable-tail-call --enable-threads "$TMP/w.wat" -o "$TMP/w.wasm" 2>/dev/null; then
  check Wasm "wasi wasm32" "$(node "$ROOT/scripts/run_wasm.js" "$TMP/w.wasm" | line)"
else echo "  -     Wasm not checked (no wat2wasm/node)"; fi

if [ -n "${MEMU:-}" ] && [ -f "$MEMU/riscv-runc/rv64i_run.mere" ]; then
  for w in 64 32; do
    "$MERE" -c "$MEMU/riscv-runc/rv${w}i_run.mere" > "$TMP/r$w.c" 2>/dev/null \
      && $CC -O2 -w "$TMP/r$w.c" -o "$TMP/rvrun$w" -lm 2>/dev/null \
      || { echo "  FAIL  RV$w: the emulator did not build"; rc=1; continue; }
    flag=-rv64; [ "$w" = 32 ] && flag=-rv
    "$MERE" $flag --ram 16 "$TMP/s.mere" > "$TMP/prog.bin" 2>/dev/null || { echo "  FAIL  RV$w: did not build"; rc=1; continue; }
    check "RV$w" "linux riscv$w" "$(cd "$TMP" && ./rvrun$w 16 2>/dev/null | grep -av '^rvrun' | line)"
  done
else echo "  -     RISC-V not checked (set MEMU to a memu checkout)"; fi

if [ "$rc" = 0 ]; then echo "sys_info: ok"; else echo "sys_info: FAILED"; fi
exit "$rc"
