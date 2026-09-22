#!/bin/sh
# scripts/diagnostic_position_check.sh — a diagnostic points where the person
# can act.
#
# Two classes were pointing somewhere else, and both had the right answer in
# hand already:
#
#   1. a failure raised INSIDE a prelude function (`assert`, `divmod`,
#      `list_max` are written in Mere) put the caret on a line of `<prelude>`,
#      a text nobody can open. The innermost frame that is not the prelude's
#      was in the stack the whole time.
#   2. declaring a type twice produced a good sentence and NO position at all
#      (`Top_type` carries none), while the parser's table held both.
#
# WHAT IS CHECKED: for each, the caret is in the user's file, and for (2) the
# message also names the first declaration's line — one location is not enough
# when the error is about a pair.
#
# Usage:
#   sh scripts/diagnostic_position_check.sh            # check
#   sh scripts/diagnostic_position_check.sh --poison   # check that it can go red
#
# THE POISONS are two:
#   1. a builtin implemented in OCaml (`char_at`) must STILL point at the user's
#      file — a gate that passed with everything pointing at the prelude would
#      not be reading the caret at all;
#   2. a type declared ONCE must produce no redeclaration error — otherwise the
#      second check is passing on an error that fires for any program.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "diagnostic_position: $MERE not built" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/diag_pos.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail=0

# The first `-->` line of a run, as a bare location.
caret() { "$MERE" "$1" 2>&1 | grep -- '-->' | head -1 | sed 's/.*--> //'; }
caret_check() { "$MERE" check "$1" 2>&1 | grep -- '-->' | head -1 | sed 's/.*--> //'; }

for pair in "assert:let _ = assert false \"boom\";" \
            "divmod:let _ = divmod 1 0;" \
            "list_max:let _ = list_max Nil;"; do
  name=${pair%%:*}; code=${pair#*:}
  printf '%s\nprint "ok"\n' "$code" > "$tmp/$name.mere"
  loc=$(caret "$tmp/$name.mere")
  case "$loc" in
    "$tmp/$name.mere"*) printf '  ok    %s\n' "a failure inside \`$name\` points at the caller" ;;
    *prelude*) printf '  FAIL  %s (%s)\n' "\`$name\` still points at the prelude" "$loc"; fail=1 ;;
    *) printf '  FAIL  %s (%s)\n' "\`$name\` points somewhere unexpected" "$loc"; fail=1 ;;
  esac
done

cat > "$tmp/redecl.mere" <<'EOF'
type t = A | B;

type t = C | D;
print_int 1
EOF
out=$("$MERE" check "$tmp/redecl.mere" 2>&1)
loc=$(printf '%s' "$out" | grep -- '-->' | head -1 | sed 's/.*--> //')
case "$loc" in
  "$tmp/redecl.mere:3:"*) printf '  ok    %s\n' "the redeclaration caret is on the second declaration" ;;
  "") printf '  FAIL  %s\n' "the redeclaration error still has no position"; fail=1 ;;
  *) printf '  FAIL  %s (%s)\n' "the redeclaration caret is in the wrong place" "$loc"; fail=1 ;;
esac
if printf '%s' "$out" | grep -q 'first declared on line 1'; then
  printf '  ok    %s\n' "and the message names the first declaration"
else
  printf '  FAIL  %s\n' "the message does not name the first declaration"
  fail=1
fi

if [ "${1:-}" = "--poison" ]; then
  pfail=0
  printf 'print (char_at "ab" 99)\n' > "$tmp/builtin.mere"
  loc=$(caret "$tmp/builtin.mere")
  case "$loc" in
    "$tmp/builtin.mere"*) printf '  ok    %s\n' "POISON 1 (an OCaml builtin): still points at the user" ;;
    *) printf '  FAIL  %s (%s)\n' "POISON 1: the caret moved for a builtin too" "$loc"; pfail=1 ;;
  esac
  printf 'type t = A | B;\nprint_int 1\n' > "$tmp/once.mere"
  if "$MERE" check "$tmp/once.mere" 2>&1 | grep -q 'declared twice'; then
    printf '  FAIL  %s\n' "POISON 2: a type declared once was reported as declared twice"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 2: a type declared once is not reported"
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "diagnostic_position --poison: ok (the gate can go red)"
  else
    echo "diagnostic_position --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "diagnostic_position: ok"; else echo "diagnostic_position: FAILED"; fi
exit "$fail"
