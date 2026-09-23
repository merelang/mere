#!/bin/sh
# scripts/unused_check.sh — the unused-binding warning, pinned.
#
# Two questions, and the second one is the one that gets forgotten:
#
#   1. Does it report the bindings nothing reads?   (test/unused/cases.mere)
#   2. Does it STAY SILENT on a file that did not type-check?
#      (test/unused/with_error.mere) — in a half-inferred tree, "nothing reads
#      this" is usually "the line that reads it is the one being typed", and a
#      compiler that says otherwise teaches people to ignore its warnings.
#
# The count is pinned rather than the messages, because the messages are already
# pinned by the unit tests; what this holds is the ANSWER SET — which names are
# in it and which are deliberately not.
#
# Usage:
#   sh scripts/unused_check.sh            # check
#   sh scripts/unused_check.sh --poison   # check that it can go red
#
# THE POISONS are two, because the rule has two halves that fail differently:
#
#   1. take the `_` off `_ignored` — the count must GO UP. A gate that did not
#      move here would be reading a number the checker prints rather than one it
#      computes, and the `_` convention could stop working unnoticed.
#   2. add a use of `dead_one` — the count must GO DOWN. A gate that did not
#      move here would be matching on the shape of the source rather than on
#      whether anything reads the name, which is the entire question.
#
# and a control: the unpoisoned run must be green.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
CASES="$ROOT/test/unused/cases.mere"
WITH_ERR="$ROOT/test/unused/with_error.mere"

[ -x "$MERE" ] || { echo "unused_check: $MERE not built" >&2; exit 2; }
[ -f "$CASES" ] || { echo "unused_check: $CASES missing" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/unused_check.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

EXPECTED=3

# The count of warnings, not of lines that mention one: the code frame repeats
# the message under the caret, so a line count is exactly twice the answer and
# looks like a plausible number.
count() {   # file -> how many unused-binding warnings
  "$MERE" check "$1" 2>&1 | grep -c '^warning: unused binding' || true
}

# A file that does not compile cannot be asked this question; say so rather than
# reporting its silence as a pass.
compiles() { "$MERE" check "$1" >/dev/null 2>&1; }

# Q-146: the TOP-LEVEL half, which is silent unless the file said what its
# surface is. Before `pub` at file level (v0.1.514) there was no way to tell a
# library's API from its insides -- `import` splices, so every export of every
# file was reachable -- and reporting would have fired on all of them.
count_top() {   # file -> how many unused TOP-LEVEL warnings
  "$MERE" check "$1" 2>&1 | grep -c '^warning: unused top-level binding' || true
}

fail=0

# --- Q-146: three directions -----------------------------------------------
mkdir -p "$tmp"
cat > "$tmp/marked.mere" <<'EOF'
let dead_helper = fn (n: int) -> n * 7;
let used_helper = fn (n: int) -> n + 1;
pub let api = fn (n: int) -> used_helper n;
print_int (api 41)
EOF
cat > "$tmp/unmarked.mere" <<'EOF'
let dead_helper = fn (n: int) -> n * 7;
let api = fn (n: int) -> n + 1;
print_int (api 41)
EOF
t_marked=$(count_top "$tmp/marked.mere")
t_unmarked=$(count_top "$tmp/unmarked.mere")
if [ "$t_marked" = "1" ]; then
  printf '  ok    %s\n' "a file that marks its exports reports the one nothing reads"
else
  printf '  FAIL  %s\n' "expected 1 top-level report in the marked file, got $t_marked"; fail=1
fi
if [ "$t_unmarked" = "0" ]; then
  printf '  ok    %s\n' "a file that marks nothing stays silent (it cannot tell surface from dead code)"
else
  printf '  FAIL  %s\n' "a file with no pub reported $t_unmarked top-level bindings"; fail=1
fi
# ...and the name that IS read must not be in the answer.
# ⚠ Only the WARNING lines: the code frame prints the neighbouring source under
# the caret, so grepping the whole output finds the binding as context and
# reports a failure that is not there.
if "$MERE" check "$tmp/marked.mere" 2>&1 | grep '^warning: unused top-level' | grep -q 'used_helper'; then
  printf '  FAIL  %s\n' "a top-level binding that IS read was reported"; fail=1
else
  printf '  ok    %s\n' "a top-level binding that is read is not reported"
fi

if [ "${1:-}" = "--poison" ]; then
  if ! compiles "$CASES"; then
    echo "  FAIL  CONTROL: the fixture does not compile"
    exit 1
  fi
  got=$(count "$CASES")
  if [ "$got" = "$EXPECTED" ]; then
    printf '  ok    %s\n' "CONTROL: the fixture reports $EXPECTED"
  else
    printf '  FAIL  %s (got %s)\n' "CONTROL: the fixture reports $EXPECTED" "$got"
    fail=1
  fi

  sed 's/let _ignored/let ignored/' "$CASES" > "$tmp/p1.mere"
  got=$(count "$tmp/p1.mere")
  if [ "$got" -gt "$EXPECTED" ]; then
    printf '  ok    %s (%s > %s)\n' "POISON 1 (drop the underscore): count rose" "$got" "$EXPECTED"
  else
    printf '  FAIL  %s (got %s, wanted > %s)\n' "POISON 1 (drop the underscore)" "$got" "$EXPECTED"
    fail=1
  fi

  sed 's|^  used_one;|  used_one + dead_one;|' "$CASES" > "$tmp/p2.mere"
  got=$(count "$tmp/p2.mere")
  if [ "$got" -lt "$EXPECTED" ]; then
    printf '  ok    %s (%s < %s)\n' "POISON 2 (read the dead binding): count fell" "$got" "$EXPECTED"
  else
    printf '  FAIL  %s (got %s, wanted < %s)\n' "POISON 2 (read the dead binding)" "$got" "$EXPECTED"
    fail=1
  fi

  if [ "$fail" = 0 ]; then echo "unused_check --poison: ok (the gate can go red)"
  else echo "unused_check --poison: FAILED"; fi
  exit "$fail"
fi

if ! compiles "$CASES"; then
  echo "  FAIL  the fixture does not compile (the question cannot be asked)"
  exit 1
fi

got=$(count "$CASES")
if [ "$got" = "$EXPECTED" ]; then
  printf '  ok    %s\n' "$EXPECTED unread bindings reported, and no more"
else
  printf '  FAIL  %s (got %s)\n' "expected $EXPECTED unread bindings" "$got"
  "$MERE" check "$CASES" 2>&1 | grep '^warning: unused binding' | sed 's/^/        /'
  fail=1
fi

# The silent half. The file must still be REFUSED — if it ever compiles, this
# case has stopped testing what it says it does.
if compiles "$WITH_ERR"; then
  printf '  FAIL  %s\n' "the type-error fixture compiles (it must not)"
  fail=1
else
  got=$(count "$WITH_ERR")
  if [ "$got" = "0" ]; then
    printf '  ok    %s\n' "a file that does not type-check reports no unused bindings"
  else
    printf '  FAIL  %s (got %s)\n' "a file that does not type-check must report none" "$got"
    fail=1
  fi
fi

if [ "$fail" = 0 ]; then echo "unused_check: ok"; else echo "unused_check: FAILED"; fi
exit "$fail"
