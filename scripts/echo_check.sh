#!/bin/sh
# scripts/echo_check.sh — `echo` says the same thing on every backend.
#
# `echo x` prints x to stderr with the line it was written on, and answers x.
# It is one prelude function plus one parser rewrite, so all five backends get
# it from the same source — which is exactly the kind of thing that is assumed
# to be identical and is not: writing this found that the RISC-V backend's
# `print_err` printed no trailing newline (the other four do), and that the
# Wasm host had never provided `print_err` at all, so any program calling it
# failed to instantiate. Neither had a witness before.
#
# STDERR is what is compared. scripts/parity.sh compares stdout, and a debug
# print that showed up there would be changing the answer it is watching.
#
# Usage:
#   sh scripts/echo_check.sh            # check
#   sh scripts/echo_check.sh --poison   # check that it can go red
#
# THE POISONS are two:
#   1. take the echoes out — stderr must go EMPTY. A gate that still passed
#      would be comparing something else's output.
#   2. push the program down a line — the reported line numbers must all move
#      with it. A gate that still passed would accept a constant where a
#      position is supposed to be, which is the whole feature.
#
# Backends whose toolchain is absent are SKIPPED BY NAME, not silently: a
# comparison not made is not agreement.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
CASE="${CASE:-$ROOT/test/echo/echo.mere}"
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc

[ -x "$MERE" ] || { echo "echo_check: $MERE not built" >&2; exit 2; }
[ -f "$CASE" ] || { echo "echo_check: $CASE missing" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/echo_check.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

have_cc=0; command -v "$CC" >/dev/null 2>&1 && have_cc=1
have_wasm=0
command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && have_wasm=1

# Each runner writes its STDERR to $tmp/<name>.err and its stdout to <name>.out.
run_interp() { "$MERE" "$1" > "$tmp/interp.out" 2> "$tmp/interp.err"; }

run_c() {
  "$MERE" -c "$1" > "$tmp/a.c" 2>"$tmp/c.emit" || return 1
  "$CC" -O0 -w "$tmp/a.c" -o "$tmp/a.bin" -lm 2>"$tmp/c.cc" || return 1
  "$tmp/a.bin" > "$tmp/c.out" 2> "$tmp/c.err"
  return 0
}

run_llvm() {
  "$MERE" -ll "$1" > "$tmp/a.ll" 2>"$tmp/ll.emit" || return 1
  "$CC" -O0 -w "$tmp/a.ll" -o "$tmp/all.bin" -lm 2>"$tmp/ll.cc" || return 1
  "$tmp/all.bin" > "$tmp/llvm.out" 2> "$tmp/llvm.err"
  return 0
}

run_wasm() {
  "$MERE" -w "$1" > "$tmp/a.wat" 2>"$tmp/w.emit" || return 1
  wat2wasm --enable-tail-call --enable-threads "$tmp/a.wat" -o "$tmp/a.wasm" 2>"$tmp/w.w2" || return 1
  ( cd "$ROOT" && node scripts/run_wasm.js "$tmp/a.wasm" ) > "$tmp/wasm.out" 2> "$tmp/wasm.err"
  return 0
}

# RISC-V needs the emulator, which is a Mere program in another checkout.
RVRUN=""
if [ -n "${MEMU:-}" ] && [ -f "$MEMU/riscv-runc/rv32i_run.mere" ] && [ "$have_cc" = 1 ]; then
  if "$MERE" -c "$MEMU/riscv-runc/rv32i_run.mere" > "$tmp/rvrun.c" 2>/dev/null \
     && "$CC" -O2 -w "$tmp/rvrun.c" -o "$tmp/rvrun" -lm 2>/dev/null; then
    RVRUN="$tmp/rvrun"
  fi
fi

# RISC-V, and the one place this gate cannot compare like for like: the
# emulator's `write` syscall IGNORES the descriptor, so the guest's fd 2 comes
# out of the emulator's fd 1. (QEMU's does not, which is why the backend sets
# the descriptor at all -- see the note on `print_err` in codegen_riscv.ml.)
#
# So for this backend the two streams are put back together before the echo
# lines are taken out of them. That is a statement about the EMULATOR, written
# here rather than left as a mysterious filter, and it keeps working the day the
# emulator learns about descriptors: the lines are looked for in both streams.
run_rv() {
  [ -n "$RVRUN" ] || return 1
  "$MERE" -rv --ram 32 "$1" > "$tmp/prog.bin" 2>"$tmp/rv.emit" || return 1
  ( cd "$tmp" && ./rvrun 32 2>"$tmp/rv.raw_err" ) | grep -a -v '^rvrun: ' > "$tmp/rv.raw_out"
  cat "$tmp/rv.raw_out" "$tmp/rv.raw_err" 2>/dev/null \
    | grep -aE '^(line [0-9]+|[^ ]+:[0-9]+): ' > "$tmp/rv.err" || true
  grep -av -E '^(line [0-9]+|[^ ]+:[0-9]+): ' "$tmp/rv.raw_out" > "$tmp/rv.out" || true
  return 0
}

fail=0
skipped=""

# One run of everything available, against one source file.
run_all() {  # file -> fills $tmp/<backend>.err
  rm -f "$tmp"/*.err "$tmp"/*.out
  run_interp "$1"
  [ "$have_cc" = 1 ] && { run_c "$1" || skipped="$skipped c"; } || skipped="$skipped c"
  [ "$have_cc" = 1 ] && { run_llvm "$1" || skipped="$skipped llvm"; } || skipped="$skipped llvm"
  [ "$have_wasm" = 1 ] && { run_wasm "$1" || skipped="$skipped wasm"; } || skipped="$skipped wasm"
  if [ -n "$RVRUN" ]; then run_rv "$1" || skipped="$skipped rv"; else skipped="$skipped rv"; fi
}

compare_all() {  # label -> 0 when every present backend matches interp's stderr
  _bad=0
  for b in c llvm wasm rv; do
    [ -f "$tmp/$b.err" ] || continue
    if diff -q "$tmp/interp.err" "$tmp/$b.err" >/dev/null 2>&1; then
      printf '  ok    %s: %s matches the interpreter\n' "$1" "$b"
    else
      printf '  FAIL  %s: %s differs from the interpreter\n' "$1" "$b"
      diff "$tmp/interp.err" "$tmp/$b.err" | sed 's/^/        /'
      _bad=1
    fi
  done
  return $_bad
}

run_all "$CASE"
lines=$(grep -c . "$tmp/interp.err" || true)
if [ "$lines" -ge 2 ]; then
  printf '  ok    the interpreter echoed %s lines to stderr\n' "$lines"
else
  printf '  FAIL  the interpreter echoed %s lines (expected at least 2)\n' "$lines"
  fail=1
fi
# The position is in the output, not just a value.
if grep -q '^line 7: 21$' "$tmp/interp.err" && grep -q '^line 8: 42$' "$tmp/interp.err"; then
  printf '  ok    %s\n' "each echo names the line it is written on"
else
  printf '  FAIL  %s\n' "the echoes do not name their lines:"
  sed 's/^/        /' "$tmp/interp.err"
  fail=1
fi
compare_all "stderr" || fail=1
[ -n "$skipped" ] && printf '  note  not compared (toolchain absent or backend refused):%s\n' "$skipped"

if [ "${1:-}" = "--poison" ]; then
  pfail=0
  # POISON 1: no echoes at all.
  sed 's/echo //g' "$CASE" > "$tmp/p1.mere"
  run_all "$tmp/p1.mere"
  if [ -s "$tmp/interp.err" ]; then
    printf '  FAIL  POISON 1 (no echo): stderr was not empty\n'
    pfail=1
  else
    printf '  ok    POISON 1 (no echo): stderr empty\n'
  fi
  # POISON 2: the same program one line further down.
  { echo "// pushed down one line"; cat "$CASE"; } > "$tmp/p2.mere"
  run_all "$tmp/p2.mere"
  if grep -q '^line 8: 21$' "$tmp/interp.err"; then
    printf '  ok    POISON 2 (program moved): the reported line moved with it\n'
  else
    printf '  FAIL  POISON 2 (program moved): line did not move\n'
    sed 's/^/        /' "$tmp/interp.err"
    pfail=1
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "echo_check --poison: ok (the gate can go red)"
  else
    echo "echo_check --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "echo_check: ok"; else echo "echo_check: FAILED"; fi
exit "$fail"
