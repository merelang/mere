#!/bin/sh
# scripts/durable_check.sh — progress survives SIGKILL, and the gate proves the
# kill actually landed on work.
#
# The program under test (test/durable/jobs.mere) runs N independent jobs and
# appends each finished one to a kvlog with an fsync. A restart replays the log
# and skips what is already there. What is durable is the PROGRESS, not the
# computation: a job that was running when the process died runs again from its
# start.
#
# WHAT MAKES THIS A GATE RATHER THAN A DEMONSTRATION:
#
# 1. The answer is compared against an uninterrupted reference run. A resumed
#    computation that converges to a different number is the failure this
#    exists to catch.
#
# 2. A kill that lands after the program has already finished proves nothing --
#    "a kill is not an abort". So the gate counts the attempts that were killed
#    while still working, and fails if there were none. Without that check a
#    machine fast enough to finish inside the delay would report success while
#    testing nothing.
#
# 3. The negative control runs the SAME kill schedule against the same program
#    with its log turned off. It must NOT finish. If it does, the schedule is
#    not interrupting anything and check 2 was passing for the wrong reason.
#
# The kill is SIGKILL, so the program gets no chance to flush or tidy: whatever
# is on disk is whatever fsync had already committed, including a record torn
# half-way through an append (kvlog's replay stops at a torn tail, which is the
# case this schedule is most likely to produce).
#
# Usage:
#   sh scripts/durable_check.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE=${MERE:-$ROOT/_build/default/bin/mere.exe}
SRC="$ROOT/test/durable/jobs.mere"

[ -x "$MERE" ] || { echo "durable_check: $MERE not found — run dune build first" >&2; exit 1; }
CC=$(command -v clang || command -v cc || true)
[ -n "$CC" ] || { echo "durable_check: no C compiler — skipping"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

BIN="$TMP/jobs"
"$MERE" -c "$SRC" > "$TMP/jobs.c" 2>"$TMP/emit.err" || {
  echo "FAIL durable_check: the C backend refused the program — $(head -1 "$TMP/emit.err")"; exit 1; }
$CC -O2 -w "$TMP/jobs.c" -o "$BIN" 2>>"$TMP/emit.err" || {
  echo "FAIL durable_check: the emitted C did not build — $(tail -1 "$TMP/emit.err")"; exit 1; }

JOBS=8
WORK=20000000
LOG="$TMP/jobs.log"
ATTEMPTS=12

# a fractional sleep without depending on a shell that has one
nap() { perl -e "select(undef,undef,undef,$1)" 2>/dev/null || sleep 1; }

# ---- the reference: never interrupted ------------------------------------

ref_out="$("$BIN" "$LOG" $JOBS $WORK 0 2>&1)"
REF="$(printf '%s\n' "$ref_out" | awk '/^answer /{print $2}')"
ref_ran="$(printf '%s\n' "$ref_out" | awk '/^ran /{print $2}')"
[ -n "$REF" ] || { echo "FAIL durable_check: the reference run printed no answer"; exit 1; }
[ "$ref_ran" = "$JOBS" ] || {
  echo "FAIL durable_check: the reference ran $ref_ran jobs, expected $JOBS (a stale log from an earlier run?)"; exit 1; }

# ---- durable, killed repeatedly ------------------------------------------

run_killed() {
  # $1 = log path ("" for the no-log control), $2 = mode. Echoes the answer
  # when an attempt survives to print one; sets $killed_working as a side
  # effect through a file, because the loop body runs in this shell.
  _log="$1"; _mode="$2"
  : > "$TMP/killed_working"
  _n=0
  while [ $_n -lt $ATTEMPTS ]; do
    _n=$((_n + 1))
    "$BIN" "$_log" $JOBS $WORK "$_mode" > "$TMP/att.out" 2>&1 &
    _pid=$!
    nap 0.30
    if kill -0 "$_pid" 2>/dev/null; then
      kill -9 "$_pid" 2>/dev/null
      echo x >> "$TMP/killed_working"
      wait "$_pid" 2>/dev/null
    else
      wait "$_pid" 2>/dev/null
      _a="$(awk '/^answer /{print $2}' "$TMP/att.out")"
      if [ -n "$_a" ]; then echo "$_a"; return 0; fi
    fi
  done
  return 1
}

rm -f "$LOG"
GOT="$(run_killed "$LOG" 0)" || GOT=""
KILLED_WORKING="$(wc -l < "$TMP/killed_working" | tr -d ' ')"

fail=0

if [ -z "$GOT" ]; then
  echo "FAIL durable_check: the durable runner never finished in $ATTEMPTS attempts"
  fail=1
elif [ "$GOT" != "$REF" ]; then
  echo "FAIL durable_check: resumed answer $GOT, uninterrupted answer $REF"
  fail=1
fi

if [ "$KILLED_WORKING" -lt 1 ]; then
  echo "FAIL durable_check: no attempt was killed while it was still working — the schedule tested nothing (this machine finishes inside the delay; raise WORK)"
  fail=1
fi

# ---- the negative control: same schedule, no log -------------------------

CTRL="$(run_killed "$TMP/unused.log" 1)" || CTRL=""
CTRL_KILLED="$(wc -l < "$TMP/killed_working" | tr -d ' ')"

if [ -n "$CTRL" ]; then
  echo "FAIL durable_check: the runner with its log turned off ALSO finished, so the kills are not interrupting the work and the durable result proves nothing"
  fail=1
fi
if [ "$CTRL_KILLED" -lt "$ATTEMPTS" ]; then
  echo "FAIL durable_check: the control survived $((ATTEMPTS - CTRL_KILLED)) of $ATTEMPTS attempts without being killed — it should never finish"
  fail=1
fi

# ---- durable COMPUTATION, not just durable progress ----------------------
#
# jobs.mere records finished jobs, so what survives is a boundary between
# pieces. fold.mere is one computation with a running state, checkpointed
# part-way through: what survives is a point INSIDE the work. The gate asks
# the same three questions, and one more that only makes sense here -- the
# resumed process must report starting somewhere other than zero, which is
# what tells a resume from a restart that happened to be fast.

FBIN="$TMP/fold"
FLOG="$TMP/fold.log"
FN=4000; FWORK=60000; FCKPT=200

if "$MERE" -c "$ROOT/test/durable/fold.mere" > "$TMP/fold.c" 2>"$TMP/fold.err" &&
   $CC -O2 -w "$TMP/fold.c" -o "$FBIN" 2>>"$TMP/fold.err"; then

  fref="$("$FBIN" "$FLOG" $FN $FWORK $FCKPT 0 2>&1 | awk '/^answer /{print $2, $3}')"
  rm -f "$FLOG"
  [ -n "$fref" ] || { echo "FAIL durable_check/fold: the reference run printed no answer"; fail=1; }

  run_fold_killed() {
    : > "$TMP/fkilled"; : > "$TMP/ffrom"
    _n=0
    while [ $_n -lt $ATTEMPTS ]; do
      _n=$((_n + 1))
      "$FBIN" "$1" $FN $FWORK $FCKPT "$2" > "$TMP/fatt.out" 2>&1 &
      _pid=$!
      nap 0.30
      if kill -0 "$_pid" 2>/dev/null; then
        kill -9 "$_pid" 2>/dev/null; echo x >> "$TMP/fkilled"; wait "$_pid" 2>/dev/null
      else
        wait "$_pid" 2>/dev/null
        awk '/^from /{print $2}' "$TMP/fatt.out" >> "$TMP/ffrom"
        _a="$(awk '/^answer /{print $2, $3}' "$TMP/fatt.out")"
        if [ -n "$_a" ]; then echo "$_a"; return 0; fi
      fi
    done
    return 1
  }

  rm -f "$FLOG"
  fgot="$(run_fold_killed "$FLOG" 0)" || fgot=""
  fkilled="$(wc -l < "$TMP/fkilled" | tr -d ' ')"
  ffrom="$(tail -1 "$TMP/ffrom" 2>/dev/null)"

  if [ -z "$fgot" ]; then
    echo "FAIL durable_check/fold: the checkpointing fold never finished in $ATTEMPTS attempts"
    fail=1
  elif [ "$fgot" != "$fref" ]; then
    echo "FAIL durable_check/fold: resumed answer '$fgot', uninterrupted answer '$fref'"
    fail=1
  fi
  if [ "$fkilled" -lt 1 ]; then
    echo "FAIL durable_check/fold: no attempt was killed while working — the schedule tested nothing"
    fail=1
  fi
  # The one question only a mid-computation checkpoint can be asked.
  if [ -z "$ffrom" ] || [ "$ffrom" = 0 ]; then
    echo "FAIL durable_check/fold: the run that finished started at index '${ffrom:-none}' — it restarted rather than resumed, so the checkpoint carried nothing"
    fail=1
  fi

  fctrl="$(run_fold_killed "$TMP/unused_fold.log" 1)" || fctrl=""
  if [ -n "$fctrl" ]; then
    echo "FAIL durable_check/fold: the run with checkpointing off ALSO finished — the kills are not interrupting the fold"
    fail=1
  fi
else
  echo "FAIL durable_check/fold: did not build — $(head -1 "$TMP/fold.err")"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "PASS durable_check: jobs resumed to $GOT after $KILLED_WORKING kills mid-work; fold resumed mid-computation from index $ffrom; neither control ever finishes"
  exit 0
fi
exit 1
