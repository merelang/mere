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

# The whole parity corpus, not a hand-picked five. That suite exists because four
# backends should agree; RV32I is not one of the four, so nothing compared it
# against anything until now. Sweeping it found a `<` on a nullary variant
# answering from allocation order, a Map comparing non-string keys as strings, and
# a try_or that did not restore the catcher's registers.
#
# The reference is the C backend and not the interpreter: both are compiled
# programs, so neither is doing anything the other cannot.
#
# KNOWN DIFFERENCES, by name and reason. A program not in this list that differs
# fails the gate; a program IN it that stops differing also fails, so the list
# cannot quietly outlive its reasons.
KNOWN_DIFF="coll_edges float_edges str_edges region_growth graphql_stack_portable map_compact nul_in_str time_clock"
# coll_edges/float_edges/str_edges  64-bit values; this backend's int is 32 bits
# region_growth                     wants more RAM (and more time) than the sweep gives it
# graphql_stack_portable            under investigation
# map_compact                       map_bytes measures an arena; a Vec here has none
# nul_in_str                        a string with an embedded NUL; differs in the
#                                   bytes written, under investigation
# time_clock                        needs a clock, which a bare machine has none of

RVRUN=""
if [ -n "${MEMU:-}" ]; then
  [ -f "$MEMU/riscv-runc/rv32i_run.mere" ] || { echo "FAIL rv_exec: no rv32i_run.mere under MEMU=$MEMU"; exit 1; }
  "$MERE" -c "$MEMU/riscv-runc/rv32i_run.mere" > "$TMP/rvrun.c" 2>"$TMP/err" || {
    echo "FAIL rv_exec: the emulator did not compile"; head -5 "$TMP/err"; exit 1; }
  $CC -O2 -w -o "$TMP/rvrun" "$TMP/rvrun.c" || { echo "FAIL rv_exec: cc refused the emulator"; exit 1; }
  RVRUN="$TMP/rvrun"
fi

echoed=0; known=0
for p in "$ROOT"/test/parity/*.mere; do
  name=$(basename "$p" .mere)
  if "$MERE" -c "$p" > "$TMP/ref.c" 2>/dev/null && $CC -O1 -w -o "$TMP/ref" "$TMP/ref.c" 2>/dev/null; then
    ( ulimit -t 60; "$TMP/ref" ) > "$TMP/i.out" 2>&1
  else
    continue        # not a C-backend program; nothing to compare against here
  fi
  if "$MERE" -rv --ram 32 "$p" > "$TMP/prog.bin" 2>"$TMP/rverr"; then :; else
    continue        # refused for a named reason; scripts/host_matrix.sh covers those
  fi
  if [ -z "$RVRUN" ]; then pass=$((pass+1)); continue; fi
  ( cd "$TMP" && perl -e 'alarm 60; exec @ARGV' ./rvrun 32 2>/dev/null ) | grep -v '^rvrun: ' > "$TMP/r.out"
  # The reference prints the program's own final value and an RV32I binary does
  # not, so an output that matches except for that last line is the ONE accepted
  # shape -- spelled out rather than filtered, so a real difference in the last
  # line is still a difference.
  sed '$d' "$TMP/i.out" > "$TMP/i.trim"
  expected_diff=no
  for k in $KNOWN_DIFF; do [ "$k" = "$name" ] && expected_diff=yes; done
  if diff -q "$TMP/i.out" "$TMP/r.out" >/dev/null; then agree=yes
  elif diff -q "$TMP/i.trim" "$TMP/r.out" >/dev/null; then agree=yes; echoed=$((echoed+1))
  else agree=no; fi
  if [ "$agree" = yes ] && [ "$expected_diff" = yes ]; then
    printf '  FAIL  %s is in KNOWN_DIFF but now agrees — remove it from the list\n' "$name"
    fail=$((fail+1)); rc=1
  elif [ "$agree" = yes ]; then pass=$((pass+1))
  elif [ "$expected_diff" = yes ]; then known=$((known+1))
  else
    printf '  FAIL  %s (RV32I disagrees with the C backend)\n' "$name"
    # -a: these outputs can contain NUL, and without it diff says only "binary
    # files differ", which names nothing.
    diff -a "$TMP/i.out" "$TMP/r.out" | head -8 | sed 's/^/    /'
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
  echo "rv_exec: $pass passed, $fail failed, $known known-different (C backend vs RV32I on the Mere-written CPU)"
  echo "rv_exec: $echoed of those matched except the program's own final value, which only a compiled-in main prints"
fi
exit $rc
