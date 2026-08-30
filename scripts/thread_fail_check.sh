#!/bin/sh
# scripts/thread_fail_check.sh — what a spawned thread's failure does to the
# program, asked of every backend, many times.
#
# A plugin host reached for `spawn` as a way to survive somebody else's code, and
# the four backends turned out to answer three different ways. C and LLVM end the
# process. Wasm prints the failure and exits 0. The interpreter runs on and says
# nothing on either stream -- BY DEFAULT. It has not lost the failure: `spawn`
# records `T_died` with the message and re-raises into a domain nobody joins, and
# `MERE_THREAD_REPORT=1` names it, message and all:
#
#   mere: 2 thread(s) neither joined nor detached at exit
#     thread 1: died: fail: boom, never joined
#
# Both halves are asserted, because either alone reads as the wrong thing. "The
# interpreter is silent" is what the default looks like and it is not what the
# interpreter knows; "the interpreter reports it" is true of a run nobody makes.
#
# WHY THIS IS NOT A test/parity CASE. Its stdout is not a function of the program
# on C, and on LLVM neither is its exit status: the failing thread races the main
# thread's last write and nothing flushes what is lost (measured 2026-08-30: C
# exits 1 every time but keeps its stdout in 9 runs of 20; LLVM exits 1 in 18 runs
# of 20 and 0 in the other 2). A DIVERGE pin there would be pinning a coin flip,
# which is what scripts/determinism_check.sh exists to keep out of that harness.
# scripts/parity.sh compares exit status in its main loop as of v0.1.360, and this
# case is exactly the one it still cannot hold.
#
# So this gate asserts what IS stable, and each assertion is one a FIX would break:
#
#   interp  exits 0 on every run, and stderr is empty -- the default silence
#   interp  under MERE_THREAD_REPORT=1, names the death and its message
#   C       ends the process at least once in $RUNS runs
#   wasm    exits 0 every run and the failure appears in its output
#
# and from those, that the backends disagree at all.
#
# WHY "AT LEAST ONCE" FOR C AND NOTHING AT ALL FOR LLVM. The first version of this
# gate asserted "C exits 1 every run", having measured exactly that 20 times out of
# 20. It failed on its next run. Measured again over 60: C exits 0 in 5 of them,
# and LLVM -- which had shown 2 zeroes in 20 earlier -- showed none at all. The
# proportions move with machine load, so neither backend can carry an "always"
# and neither can carry a "sometimes" either, since a run of ten can miss a
# minority answer. What survives is that a nonzero appears at all, which at the
# observed rate would be missed with probability around 0.08^$RUNS. LLVM is only
# REPORTED, so a change in it is visible to a reader with no assertion watching.
#
# Usage: scripts/thread_fail_check.sh
set -u

MERE=${MERE:-./_build/default/bin/mere.exe}
CASE=test/threadfail/spawned_fail.mere
RUNS=${RUNS:-10}
CC="${CC:-clang}"; command -v "$CC" >/dev/null 2>&1 || CC=cc
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -x "$MERE" ] || { echo "thread_fail_check: $MERE not found — run dune build first" >&2; exit 1; }
[ -f "$CASE" ] || { echo "thread_fail_check: $CASE is missing" >&2; exit 1; }

fail=0
asserted=0

# codes <command...> : prints the sorted distinct exit codes seen over $RUNS runs,
# space separated, and leaves the last run's stderr in $TMP/last.err.
codes() {
  : > "$TMP/codes"
  i=0
  while [ "$i" -lt "$RUNS" ]; do
    sh "$ROOT/scripts/bounded.sh" 20 "$@" > "$TMP/last.out" 2> "$TMP/last.err"
    echo $? >> "$TMP/codes"
    i=$((i + 1))
  done
  sort -u "$TMP/codes" | tr '\n' ' '
}

# --- interpreter ------------------------------------------------------------
i_codes="$(codes "$MERE" "$CASE")"
i_err="$(cat "$TMP/last.err")"
echo "interp  exit codes over $RUNS runs: $i_codes"

asserted=$((asserted + 1))
[ "$i_codes" = "0 " ] || { echo "FAIL  interp: want only 0, got: $i_codes"; fail=1; }

# The DEFAULT silence, asserted: making the interpreter report a dead thread
# without being asked breaks this line, which is how this gate finds out it was
# fixed rather than passing quietly through the change.
asserted=$((asserted + 1))
if [ -n "$i_err" ]; then
  echo "FAIL  interp now says something by default about the failed thread — the silence this gate pins is gone:"
  printf '    %s\n' "$i_err"
  fail=1
fi

# And the other half: the failure is recorded, with its message. A gate that only
# pinned the silence would read as "the interpreter loses it", which is false and
# would survive the interpreter actually starting to lose it.
MERE_THREAD_REPORT=1 sh "$ROOT/scripts/bounded.sh" 20 "$MERE" "$CASE" > "$TMP/r.out" 2> "$TMP/r.err"
r_all="$(cat "$TMP/r.out" "$TMP/r.err")"
asserted=$((asserted + 1))
case "$r_all" in
  *"died: fail: boom"*) ;;
  *) echo "FAIL  MERE_THREAD_REPORT=1 no longer names the dead thread and its message: [$r_all]"; fail=1 ;;
esac

# --- C ----------------------------------------------------------------------
if "$MERE" -c "$CASE" > "$TMP/a.c" 2>"$TMP/e" && "$CC" -O0 -w "$TMP/a.c" -o "$TMP/a" -lm 2>"$TMP/e"; then
  c_codes="$(codes "$TMP/a")"
  c_nonzero="$(grep -cv '^0$' "$TMP/codes")"
  echo "C       exit codes over $RUNS runs: $c_codes  (nonzero in $c_nonzero of $RUNS)"
  asserted=$((asserted + 1))
  [ "$c_nonzero" != 0 ] || {
    echo "FAIL  C never ended the process in $RUNS runs — a thread's failure stopped reaching the exit status"
    fail=1; }
else
  echo "FAIL  C: the case did not build"; sed 's/^/    /' "$TMP/e" | head -3; fail=1
fi

# --- LLVM: reported, not asserted -------------------------------------------
if "$MERE" -ll "$CASE" > "$TMP/a.ll" 2>"$TMP/e" && "$CC" -O0 -w "$TMP/a.ll" -o "$TMP/al" -lm 2>"$TMP/e"; then
  l_codes="$(codes "$TMP/al")"
  echo "LLVM    exit codes over $RUNS runs: $l_codes  (nonzero in $(grep -cv '^0$' "$TMP/codes") of $RUNS — reported, not asserted)"
else
  echo "LLVM    not built on this host (reported, not asserted)"
fi

# --- Wasm -------------------------------------------------------------------
if command -v wat2wasm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 \
   && "$MERE" -w "$CASE" > "$TMP/a.wat" 2>"$TMP/e" \
   && wat2wasm --enable-tail-call --enable-threads "$TMP/a.wat" -o "$TMP/a.wasm" 2>"$TMP/e"; then
  w_codes="$(codes node "$ROOT/scripts/run_wasm.js" "$TMP/a.wasm")"
  w_out="$(cat "$TMP/last.out")"
  echo "wasm    exit codes over $RUNS runs: $w_codes"
  asserted=$((asserted + 1))
  [ "$w_codes" = "0 " ] || { echo "FAIL  wasm: want only 0, got: $w_codes"; fail=1; }
  asserted=$((asserted + 1))
  case "$w_out" in
    *boom*) ;;
    *) echo "FAIL  wasm: the failure no longer appears in its output: [$w_out]"; fail=1 ;;
  esac
else
  echo "wasm    toolchain absent — SKIP (2 assertions not run)"
fi

# The point of the gate, stated as an assertion rather than left to the reader.
asserted=$((asserted + 1))
if [ "${c_codes:-}" = "$i_codes" ]; then
  echo "FAIL  interp and C now agree ($i_codes) — the split this gate exists to hold is gone"
  fail=1
fi

echo "thread_fail_check: $asserted assertion(s) ran"
if [ "$fail" != 0 ]; then echo "thread_fail_check: FAILED"; exit 1; fi
echo "thread_fail_check: ok  (three answers from four backends; the interpreter's is silence unless asked)"
