#!/bin/sh
# scripts/thread_leak_check.sh — check the thread-leak report against programs
# whose leaks are known.
#
# `MERE_THREAD_REPORT=1` makes the interpreter say, at exit, which threads were
# neither joined nor detached and what each was waiting for. That report is only
# worth having if it is quiet about well-formed programs, so this gate is built
# around the negative cases as much as the positive ones: a joined worker, a
# deliberately detached blocker, and a program with no threads at all must all
# report nothing. A diagnostic that fires on everything gets switched off.
#
# The expected answer lives in each program's first line (`//! leaks: N ...`)
# rather than in this script, so adding a case does not mean editing the gate --
# and a program whose expectation and behaviour disagree is a FAIL rather than a
# silently-updated number.
#
# Every run is bounded (scripts/bounded.sh). These programs terminate by
# construction -- the leaked thread blocks, the main one does not -- but a gate
# about threads blocking forever is the last place to assume that.
#
# Usage: sh scripts/thread_leak_check.sh [file.mere ...]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MERE="$ROOT/_build/default/bin/mere.exe"
[ -x "$MERE" ] || { echo "thread_leak_check: $MERE not found — run 'dune build'" >&2; exit 1; }
LIMIT="${MERE_THREADLEAK_TIMEOUT:-30}"

if [ $# -gt 0 ]; then FILES="$*"; else FILES="$(ls "$ROOT"/test/threadleak/*.mere)"; fi

TMP="${TMPDIR:-/tmp}/mere_threadleak.$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

for f in $FILES; do
  name="$(basename "$f" .mere)"
  want="$(sed -n '1s|^//! leaks: *||p' "$f")"
  if [ -z "$want" ]; then
    echo "FAIL $name  (no \`//! leaks:\` line — the gate does not guess)"; fail=$((fail + 1)); continue
  fi

  # THE DEFAULT MUST STAY SILENT. The report is opt-in, and a diagnostic that
  # leaked onto stderr without being asked for would change what every program
  # that spawns anything prints. Checked first, because if this is wrong the
  # rest of the comparison is measuring the wrong thing.
  sh "$ROOT/scripts/bounded.sh" "$LIMIT" "$MERE" "$f" > "$TMP/off.out" 2> "$TMP/off.err" && orc=0 || orc=$?
  if [ "$orc" = 201 ]; then
    echo "FAIL $name  (did not finish within ${LIMIT}s with the report off)"; fail=$((fail + 1)); continue
  fi
  if grep -q "neither joined nor detached" "$TMP/off.err"; then
    echo "FAIL $name  (reported without MERE_THREAD_REPORT being set)"; fail=$((fail + 1)); continue
  fi

  MERE_THREAD_REPORT=1 sh "$ROOT/scripts/bounded.sh" "$LIMIT" "$MERE" "$f" \
    > "$TMP/on.out" 2> "$TMP/on.err" && rc=0 || rc=$?
  if [ "$rc" = 201 ]; then
    echo "FAIL $name  (did not finish within ${LIMIT}s with the report on)"; fail=$((fail + 1)); continue
  fi

  # AND THE REPORT MUST NOT MOVE STDOUT. It goes to stderr precisely so that
  # turning it on does not change the program's output; comparing the two runs
  # is how that stays true.
  if ! cmp -s "$TMP/off.out" "$TMP/on.out"; then
    echo "FAIL $name  (stdout differs between report off and report on)"
    diff "$TMP/off.out" "$TMP/on.out" | head -4 | sed 's/^/    /'
    fail=$((fail + 1)); continue
  fi

  n="$(grep -c 'thread [0-9]*:' "$TMP/on.err" || true)"
  case "$want" in
    0) got="0" ;;
    *) why="$(sed -n 's/^  thread [0-9]*: //p' "$TMP/on.err" | head -1)"; got="$n $why" ;;
  esac
  if [ "$got" = "$want" ]; then
    echo "PASS $name  [$got]"; pass=$((pass + 1))
  else
    echo "FAIL $name  (want \`$want\`, got \`$got\`)"
    sed 's/^/    /' "$TMP/on.err" | head -4
    fail=$((fail + 1))
  fi
done

echo "----"
echo "thread_leak_check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
