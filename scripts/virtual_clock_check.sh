#!/bin/sh
# scripts/virtual_clock_check.sh — check the virtual clock against programs
# whose timing behaviour is known.
#
# Under MERE_VIRTUAL_CLOCK=1 the interpreter advances a virtual clock instead of
# waiting: when every live thread is parked, time jumps to the earliest pending
# deadline. Three claims fall out, and each is checked here:
#
#   1. IT IS VIRTUAL. Every case's waits add up to 30-65 virtual seconds and the
#      whole run is wall-bounded far below that (scripts/bounded.sh). A clock
#      that is secretly real does not pass slowly -- it gets killed and FAILs.
#   2. IT IS DETERMINISTIC. Each passing case runs twice and the two stdouts
#      must be byte-identical. Timer firing order is the point of the feature;
#      a flaky gate for a determinism feature would be self-refuting.
#   3. IT IS OFF BY DEFAULT. The deadlock case is also run WITHOUT the variable
#      under a short bound and must really block (exit 201): a virtual clock
#      that leaks into default runs would change what production programs do.
#
# Expectations live in each program's first line (`//! expect: ok` compared
# against <case>.expected, or `//! expect: fail <text>` matched against stderr),
# so adding a case does not mean editing this script.
#
# Usage: sh scripts/virtual_clock_check.sh [file.mere ...]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MERE="$ROOT/_build/default/bin/mere.exe"
[ -x "$MERE" ] || { echo "virtual_clock_check: $MERE not found — run 'dune build'" >&2; exit 1; }
LIMIT="${MERE_VCLOCK_TIMEOUT:-15}"

if [ $# -gt 0 ]; then FILES="$*"; else FILES="$(ls "$ROOT"/test/vclock/*.mere)"; fi

TMP="${TMPDIR:-/tmp}/mere_vclock.$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

for f in $FILES; do
  name="$(basename "$f" .mere)"
  directive="$(sed -n '1s|^//! expect: *||p' "$f")"
  case "$directive" in
    ok)
      MERE_VIRTUAL_CLOCK=1 sh "$ROOT/scripts/bounded.sh" "$LIMIT" "$MERE" "$f" \
        > "$TMP/1.out" 2> "$TMP/1.err" && rc=0 || rc=$?
      if [ "$rc" = 201 ]; then
        echo "FAIL $name  (outlived ${LIMIT}s — the virtual clock is not virtual)"; fail=$((fail + 1)); continue
      fi
      if [ "$rc" != 0 ]; then
        echo "FAIL $name  (exit $rc)"; sed 's/^/    /' "$TMP/1.err" | head -3; fail=$((fail + 1)); continue
      fi
      MERE_VIRTUAL_CLOCK=1 sh "$ROOT/scripts/bounded.sh" "$LIMIT" "$MERE" "$f" \
        > "$TMP/2.out" 2> /dev/null || true
      if ! cmp -s "$TMP/1.out" "$TMP/2.out"; then
        echo "FAIL $name  (two runs differ — the clock is not deterministic)"
        diff "$TMP/1.out" "$TMP/2.out" | head -4 | sed 's/^/    /'
        fail=$((fail + 1)); continue
      fi
      exp="${f%.mere}.expected"
      if [ ! -f "$exp" ]; then
        echo "FAIL $name  (no .expected file next to the case)"; fail=$((fail + 1)); continue
      fi
      if cmp -s "$TMP/1.out" "$exp"; then
        echo "PASS $name"; pass=$((pass + 1))
      else
        echo "FAIL $name  (stdout differs from ${exp#$ROOT/})"
        diff "$exp" "$TMP/1.out" | head -6 | sed 's/^/    /'
        fail=$((fail + 1))
      fi
      ;;
    fail\ *)
      want="${directive#fail }"
      MERE_VIRTUAL_CLOCK=1 sh "$ROOT/scripts/bounded.sh" "$LIMIT" "$MERE" "$f" \
        > "$TMP/f.out" 2> "$TMP/f.err" && rc=0 || rc=$?
      if [ "$rc" = 201 ]; then
        echo "FAIL $name  (hung instead of failing)"; fail=$((fail + 1)); continue
      fi
      if [ "$rc" = 0 ]; then
        echo "FAIL $name  (succeeded; this program is supposed to fail)"; fail=$((fail + 1)); continue
      fi
      if grep -q "$want" "$TMP/f.err"; then
        echo "PASS $name  [failed naming: $want]"; pass=$((pass + 1))
      else
        echo "FAIL $name  (failed, but without \`$want\` in stderr)"
        sed 's/^/    /' "$TMP/f.err" | head -3; fail=$((fail + 1))
      fi
      # The same program, clock off, short bound: it must REALLY block.
      sh "$ROOT/scripts/bounded.sh" 3 "$MERE" "$f" > /dev/null 2>&1 && orc=0 || orc=$?
      if [ "$orc" = 201 ]; then
        echo "PASS $name(off)  [blocks for real without the variable]"; pass=$((pass + 1))
      else
        echo "FAIL $name(off)  (exit $orc without MERE_VIRTUAL_CLOCK — the clock leaked into the default)"
        fail=$((fail + 1))
      fi
      ;;
    *)
      echo "FAIL $name  (no \`//! expect:\` line — the gate does not guess)"; fail=$((fail + 1)) ;;
  esac
done

echo "----"
echo "virtual_clock_check: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
