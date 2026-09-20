#!/bin/sh
# scripts/unreachable_arm_check.sh — an arm no value can reach is reported, and
# an arm that IS reached is not.
#
# The other side of the exhaustiveness question this compiler has always asked.
# Exhaustiveness says which values no arm answers for; this says which arms no
# value reaches. Until v0.1.487 a duplicated constructor arm and an arm written
# after `_` were accepted in silence by `mere`, `mere check` and `mere check -c`
# alike — the arm simply was not there, and the error the reader eventually saw
# came from the arm they had NOT written the code in.
#
# THE NEGATIVE CASES ARE HALF OF THIS GATE. A check that fires on working code
# is worse than no check, because the first thing somebody does with it is
# delete a live arm. Four cases here must produce nothing: a guarded arm above
# the same constructor, a constructor whose payload pattern is refutable, an
# or-pattern only half of which is closed, and the defensive `_` after every
# constructor is already named (dead, reportable, and deliberately not
# reported — the noise would bury the findings that matter).
#
# Each case declares what it expects:
#   // expect-unreachable: <count>
#   // expect-lines: <line> <line>        (empty for none)
#
# The LINES are checked and not only the count: a check that warns about the
# wrong arm is the failure that costs the most, and a count alone cannot see it.
#
# Usage:
#   sh scripts/unreachable_arm_check.sh            # check
#   sh scripts/unreachable_arm_check.sh --poison   # check that it can go red
#
# THE POISONS are two, each aimed at one half of what the gate reads:
#   1. a case whose expected COUNT is raised by one must go red — otherwise the
#      gate is not reading the warnings at all;
#   2. a case whose expected LINE is moved by one must go red — otherwise it is
#      counting warnings without caring which arm they are about, which is the
#      half that catches a check gone wrong.
# with the clean run asserted green first, so "red" means the poison.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
CASES="$ROOT/test/unreachable_arm"

[ -x "$MERE" ] || { echo "unreachable_arm: $MERE not built" >&2; exit 2; }
[ -d "$CASES" ] || { echo "unreachable_arm: $CASES missing" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/unreachable_arm.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

header() { sed -n "s|^// $2: *||p" "$1" | head -1; }

# One `mere check` per case, read twice from the same captured output rather
# than by running it again: a gate that runs its subject once per question is a
# gate whose answers can disagree with each other.
run_one() { # file -> writes $tmp/err; echoes "count|lines"
  "$MERE" check "$1" >/dev/null 2>"$tmp/err"
  _c=$(grep -c '^warning: this arm cannot be reached' "$tmp/err")
  _l=$(grep -A1 '^warning: this arm cannot be reached' "$tmp/err" \
       | sed -n 's|^ *--> [^:]*:\([0-9][0-9]*\):.*|\1|p' | tr '\n' ' ' | sed 's| *$||')
  echo "$_c|$_l"
}

check_dir() { # dir -> prints failures, returns their count
  _bad=0
  for f in "$1"/*.mere; do
    [ -f "$f" ] || continue
    _name="$(basename "$f")"
    _want_n="$(header "$f" expect-unreachable)"
    _want_l="$(header "$f" expect-lines)"
    if [ -z "$_want_n" ]; then
      echo "  $_name: no expect-unreachable header"; _bad=$((_bad + 1)); continue
    fi
    _r="$(run_one "$f")"
    _got_n="${_r%%|*}"; _got_l="${_r#*|}"
    # An unrelated error would make a case answer 0 for the wrong reason, which
    # is how a negative case turns into a rubber stamp.
    if grep -qE '^(type|parse|lex) error' "$tmp/err"; then
      echo "  $_name: the case does not compile — its 0 means nothing"
      _bad=$((_bad + 1)); continue
    fi
    _problems=""
    [ "$_got_n" = "$_want_n" ] || _problems="$_problems count(got:$_got_n want:$_want_n)"
    [ "$_got_l" = "$_want_l" ] || _problems="$_problems lines(got:[$_got_l] want:[$_want_l])"
    if [ -n "$_problems" ]; then
      echo "  $_name:$_problems"; _bad=$((_bad + 1))
    fi
  done
  return $_bad
}

total="$(ls "$CASES"/*.mere | wc -l | tr -d ' ')"

if [ "${1:-}" = "--poison" ]; then
  fails=0
  out="$(check_dir "$CASES")"; n=$?
  if [ "$n" != 0 ]; then
    echo "poison: CONTROL IS NOT GREEN — $n case(s) fail before any poison:"
    echo "$out"; exit 1
  fi
  echo "poison: control green ($total cases)"

  mkdir -p "$tmp/p1" "$tmp/p2"
  cp "$CASES"/*.mere "$tmp/p1/"
  cp "$CASES"/*.mere "$tmp/p2/"

  # 1: one more warning expected than the check produces.
  sed -i.bak 's|^// expect-unreachable: 1$|// expect-unreachable: 2|' "$tmp/p1/dup_ctor.mere"
  rm -f "$tmp/p1"/*.bak
  out="$(check_dir "$tmp/p1")"; n=$?
  if [ "$n" = 1 ]; then
    echo "poison 1 (expected count +1): red on exactly that case — the gate reads the warnings"
  else
    echo "poison 1 (expected count +1): FAILED — expected exactly 1 red, got $n"
    echo "$out"; fails=$((fails + 1))
  fi

  # 2: the right number of warnings, about the wrong arm.
  sed -i.bak 's|^// expect-lines: 10$|// expect-lines: 11|' "$tmp/p2/dup_ctor.mere"
  rm -f "$tmp/p2"/*.bak
  out="$(check_dir "$tmp/p2")"; n=$?
  if [ "$n" = 1 ]; then
    echo "poison 2 (expected line moved): red on exactly that case — the gate reads WHICH arm"
  else
    echo "poison 2 (expected line moved): FAILED — expected exactly 1 red, got $n"
    echo "$out"; fails=$((fails + 1))
  fi

  [ "$fails" = 0 ] || exit 1
  echo "unreachable_arm: poison ok (2 poisons + control)"
  exit 0
fi

out="$(check_dir "$CASES")"; n=$?
if [ "$n" != 0 ]; then
  echo "unreachable_arm: $n/$total case(s) failed"
  echo "$out"
  exit 1
fi
echo "unreachable_arm: $total/$total ok (3 reported, 4 correctly silent)"

# AND THE TREE ITSELF. The check is only worth its noise if the tree it ships
# with is clean under it, and this is where that stops being a claim somebody
# made once. 836 sources were clean the day it landed; a new dead arm is a
# defect in whatever added it.
swept=0; dirty=0
for f in $(find "$ROOT/examples" "$ROOT/contrib" "$ROOT/test" "$ROOT/benchmarks" \
             -name '*.mere' -not -path '*/.build/*' 2>/dev/null | sort); do
  case "$f" in "$CASES"/*) continue ;; esac
  swept=$((swept + 1))
  c=$("$MERE" check "$f" 2>&1 | grep -c '^warning: this arm cannot be reached')
  if [ "$c" != "0" ]; then
    echo "  $f: $c unreachable arm(s)"
    dirty=$((dirty + 1))
  fi
done
if [ "$dirty" != 0 ]; then
  echo "unreachable_arm: $dirty of $swept shipped sources have a dead arm"
  exit 1
fi
echo "unreachable_arm: $swept shipped sources clean"
