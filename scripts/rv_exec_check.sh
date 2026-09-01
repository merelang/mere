#!/bin/sh
# scripts/rv_exec_check.sh — run hosted -rv programs and check what they print.
#
# scripts/parity.sh compares four backends by output; RV32I is not one of them,
# because running its output needs a machine. So everything about that backend
# that is a matter of RUNTIME behaviour rather than emitted instructions had no
# gate at all: `scripts/qemu_virt.sh` covers the bare-metal side, and this covers
# the hosted side.
#
# What that gap cost: a `try_or` whose thunk failed restored sp and fp and not the
# callee-saved registers, so the catching function's own named bindings came back
# holding whatever the failed callee had put there. Five lines of Mere show it. The
# suite had a try_or test whose thunk had no bindings of its own, so there was
# nothing to overwrite and all four backends agreed.
#
# Each program is run on the interpreter and on RV32I, and the two outputs must be
# identical -- so the expected values are not written down anywhere here.
#
# Needs a 32-bit machine: MEMU=<memu checkout>. Without it the programs are still
# COMPILED for RV32I, and this says the running half did not happen.
#
# Usage:
#   sh scripts/rv_exec_check.sh
#   MEMU=/path/to/memu sh scripts/rv_exec_check.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
CC="${CC:-cc}"
[ -x "$MERE" ] || { echo "rv_exec_check: $MERE not found — run 'dune build'" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0; pass=0; fail=0

PROGS="test/parity/try_or_saves_bindings.mere
test/parity/try_or_unwind.mere
test/parity/match_arm_stack.mere
test/parity/or_pattern.mere"

RVRUN=""
if [ -n "${MEMU:-}" ]; then
  [ -f "$MEMU/riscv-runc/rv32i_run.mere" ] || { echo "FAIL rv_exec: no rv32i_run.mere under MEMU=$MEMU"; exit 1; }
  "$MERE" -c "$MEMU/riscv-runc/rv32i_run.mere" > "$TMP/rvrun.c" 2>"$TMP/err" || {
    echo "FAIL rv_exec: the emulator did not compile"; head -5 "$TMP/err"; exit 1; }
  $CC -O2 -w -o "$TMP/rvrun" "$TMP/rvrun.c" || { echo "FAIL rv_exec: cc refused the emulator"; exit 1; }
  RVRUN="$TMP/rvrun"
fi

for p in $PROGS; do
  name=$(basename "$p" .mere)
  # The interpreter prints `()` for the program's own unit result; the RV32I
  # binary has no such thing to print, so it is dropped from both rather than
  # from one.
  "$MERE" "$ROOT/$p" 2>"$TMP/ierr" | grep -v '^()$' > "$TMP/i.out" || {
    echo "  FAIL  $name (the interpreter refused it)"; head -3 "$TMP/ierr"; fail=$((fail+1)); continue; }
  if "$MERE" -rv "$ROOT/$p" > "$TMP/prog.bin" 2>"$TMP/rverr"; then :; else
    echo "  FAIL  $name (-rv refused it)"; head -3 "$TMP/rverr"; fail=$((fail+1)); continue
  fi
  if [ -z "$RVRUN" ]; then
    printf '  ok    %s (built for RV32I; not run)\n' "$name"; pass=$((pass+1)); continue
  fi
  ( cd "$TMP" && perl -e 'alarm 120; exec @ARGV' ./rvrun 8 2>&1 ) | grep -v '^rvrun: ' > "$TMP/r.out"
  if diff -q "$TMP/i.out" "$TMP/r.out" >/dev/null; then
    printf '  ok    %s (%s lines identical)\n' "$name" "$(grep -c . "$TMP/i.out")"
    pass=$((pass+1))
  else
    printf '  FAIL  %s (RV32I disagrees with the interpreter)\n' "$name"
    diff "$TMP/i.out" "$TMP/r.out" | head -10 | sed 's/^/    /'
    fail=$((fail+1)); rc=1
  fi
done

# One case cannot be a differential: an `extern fn` that nothing implements has no
# behaviour on any other backend to compare against -- the interpreter refuses the
# program outright ("no interp mock implementation"). So its expectation is written
# out, and it is the only one here that is. What it pins is that the refusal is a
# `fail` and not an exit, which is what lets a program cope at all.
EXPECTED='pid=-1 other=99
still running'
name=extern_catchable
if "$MERE" -rv "$ROOT/test/rv/extern_catchable.mere" > "$TMP/prog.bin" 2>"$TMP/rverr"; then
  if [ -z "$RVRUN" ]; then
    printf '  ok    %s (built for RV32I; not run)\n' "$name"; pass=$((pass+1))
  else
    got=$( cd "$TMP" && perl -e 'alarm 120; exec @ARGV' ./rvrun 8 2>&1 | grep -v '^rvrun: ' )
    if [ "$got" = "$EXPECTED" ]; then
      printf '  ok    %s (an unimplemented extern is catchable)\n' "$name"; pass=$((pass+1))
    else
      printf '  FAIL  %s\n    expected: %s\n    got:      %s\n' "$name" "$EXPECTED" "$got"
      fail=$((fail+1)); rc=1
    fi
  fi
else
  printf '  FAIL  %s (-rv refused it)\n' "$name"; head -3 "$TMP/rverr"; fail=$((fail+1)); rc=1
fi

if [ -z "$RVRUN" ]; then
  echo "rv_exec: $pass built, $fail failed — nothing RAN; set MEMU=<memu checkout> for that half"
else
  echo "rv_exec: $pass passed, $fail failed (interpreter vs RV32I on the Mere-written CPU)"
fi
exit $rc
