#!/bin/sh
# scripts/warnings_as_errors_check.sh — `--warnings-as-errors` fails on a
# warning, and on nothing else.
#
# v0.1.503 gave the compiler warnings worth acting on and no way to make a
# machine act on them. This gate is the other half: it holds BOTH directions,
# because a flag that fails on everything passes the obvious test.
#
#   1. a file with a warning: flag -> exit 1, no flag -> exit 0
#   2. a file with no warning: flag -> exit 0
#   3. MORE WARNINGS THAN THE TERMINAL PRINTS: the CLI shows ten blocks and
#      then a count, and a warning it had no room for is still a warning. A
#      file with twelve of them must fail.
#
# Usage:
#   sh scripts/warnings_as_errors_check.sh            # check
#   sh scripts/warnings_as_errors_check.sh --poison   # check that it can go red
#
# THE POISONS are two, one per direction:
#   1. the clean file must NOT fail with the flag — a gate that passed here
#      would accept a flag that fails on every file;
#   2. the warning file must NOT fail without the flag — a gate that passed
#      here would accept warnings having become errors by themselves.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "warnings_as_errors: $MERE not built" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/werror_check.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

cat > "$tmp/warn.mere" <<'EOF'
let f = fn (n: int) ->
  let never_read = 1;
  n;
print_int (f 41)
EOF

cat > "$tmp/clean.mere" <<'EOF'
let f = fn (n: int) -> n + 1;
print_int (f 41)
EOF

# Twelve unread bindings: more than the terminal's ten-block limit.
{
  echo 'let f = fn (n: int) ->'
  i=1
  while [ "$i" -le 12 ]; do echo "  let dead_$i = $i;"; i=$((i + 1)); done
  echo '  n;'
  echo 'print_int (f 41)'
} > "$tmp/many.mere"

status() {  # file [flag] -> exit status
  if [ $# = 2 ]; then "$MERE" check "$2" "$1" >/dev/null 2>&1
  else "$MERE" check "$1" >/dev/null 2>&1; fi
  echo $?
}

fail=0

# The control the rest rests on: the warning file must actually warn.
if "$MERE" check "$tmp/warn.mere" 2>&1 | grep -q 'unused binding'; then
  printf '  ok    %s\n' "the fixture warns at all"
else
  printf '  FAIL  %s\n' "the fixture produces no warning (nothing to turn into an error)"
  exit 1
fi

if [ "$(status "$tmp/warn.mere" --warnings-as-errors)" = 1 ]; then
  printf '  ok    %s\n' "a warning fails the run with the flag"
else
  printf '  FAIL  %s\n' "a warning did not fail the run with the flag"
  fail=1
fi
if [ "$(status "$tmp/warn.mere")" = 0 ]; then
  printf '  ok    %s\n' "the same file passes without the flag"
else
  printf '  FAIL  %s\n' "the file failed without the flag (the flag is not what did it)"
  fail=1
fi
if [ "$(status "$tmp/clean.mere" --warnings-as-errors)" = 0 ]; then
  printf '  ok    %s\n' "a file with no warning passes with the flag"
else
  printf '  FAIL  %s\n' "a clean file failed with the flag"
  fail=1
fi
n=$("$MERE" check "$tmp/many.mere" 2>&1 | grep -c '^warning: unused binding')
shown_all=$("$MERE" check "$tmp/many.mere" 2>&1 | grep -c 'and .* more warning')
if [ "$n" = 12 ] || [ "$shown_all" = 1 ]; then
  if [ "$(status "$tmp/many.mere" --warnings-as-errors)" = 1 ]; then
    printf '  ok    %s\n' "twelve warnings (more than the terminal prints) still fail"
  else
    printf '  FAIL  %s\n' "twelve warnings did not fail — the count is of what was PRINTED"
    fail=1
  fi
else
  printf '  FAIL  %s (got %s blocks, %s summary lines)\n' \
    "the twelve-warning fixture is not what it claims" "$n" "$shown_all"
  fail=1
fi

if [ "${1:-}" = "--poison" ]; then
  pfail=0
  if [ "$(status "$tmp/clean.mere" --warnings-as-errors)" = 0 ]; then
    printf '  ok    %s\n' "POISON 1: the flag does not fail a clean file"
  else
    printf '  FAIL  %s\n' "POISON 1: the flag fails everything"
    pfail=1
  fi
  if [ "$(status "$tmp/warn.mere")" = 0 ]; then
    printf '  ok    %s\n' "POISON 2: warnings alone do not fail a run"
  else
    printf '  FAIL  %s\n' "POISON 2: warnings fail a run without the flag"
    pfail=1
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "warnings_as_errors --poison: ok (both directions hold)"
  else
    echo "warnings_as_errors --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "warnings_as_errors: ok"; else echo "warnings_as_errors: FAILED"; fi
exit "$fail"
