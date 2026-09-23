#!/bin/sh
# scripts/doc_cmd_check.sh — `mere doc` says what a file exports and what was
# written about it.
#
# Q-169. The compiler had both halves and neither had an exit: `--decls` knows
# every top-level name and its inferred type, and `doc_above` (v0.1.506, hover)
# knows the comment block a definition was written under. `mere doc` is those
# two joined, so what this checks is the JOIN, not new analysis.
#
# ⚠ THE UNDOCUMENTED CASE IS THE ONE THAT MATTERS. A tool that prints only
# documented names merges "this file does not export that" with "nobody wrote a
# comment about it", and the second is what a reader is trying to find out. Both
# directions are checked, and the poison removes the comment to prove the first
# direction is reading the source rather than the name.
#
# Usage:
#   sh scripts/doc_cmd_check.sh            # check
#   sh scripts/doc_cmd_check.sh --poison   # check that it can go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "doc_cmd: $MERE not built" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
MODE="${1:-}"
fail=0

cat > "$T/a.mere" <<'EOF'
// A point on the grid.
type point = P of int * int;

// Doubles its argument.
// And keeps going on a second line.
let dbl = fn (n: int) -> n * 2;

let plain = fn (n: int) -> n + 1;

print_int (dbl 4 + plain 1)
EOF

out=$("$MERE" doc "$T/a.mere" 2>&1) || { echo "doc_cmd: \`mere doc\` failed: $out" >&2; exit 2; }

if printf '%s' "$out" | grep -q 'Doubles its argument.' \
   && printf '%s' "$out" | grep -q 'And keeps going on a second line.'; then
  printf '  ok    %s\n' "a documented value shows every line of its block"
else
  printf '  FAIL  %s\n' "the comment block above a value did not come out"
  fail=1
fi

if printf '%s' "$out" | grep -q 'A point on the grid.'; then
  printf '  ok    %s\n' "a type's block comes out too"
else
  printf '  FAIL  %s\n' "the comment above a type declaration did not come out"
  fail=1
fi

# ⚠ Present WITHOUT a block, not absent.
if printf '%s' "$out" | grep -q '^  plain : '; then
  printf '  ok    %s\n' "an undocumented value is listed, so \"no comment\" and \"not exported\" stay different"
else
  printf '  FAIL  %s\n' "an undocumented value was left out of the output"
  fail=1
fi

# The one thing that must NOT leak: another file's names.
cat > "$T/lib.mere" <<'EOF'
// Not this file's business.
let imported_helper = fn (n: int) -> n;
EOF
cat > "$T/b.mere" <<'EOF'
import "lib.mere";
// Mine.
let mine = fn (n: int) -> imported_helper n;
print_int (mine 1)
EOF
outb=$("$MERE" doc "$T/b.mere" 2>&1) || outb=""
if printf '%s' "$outb" | grep -q 'imported_helper'; then
  printf '  FAIL  %s\n' "an imported name was documented as if this file exported it"
  fail=1
else
  printf '  ok    %s\n' "an imported file's names are not this file's surface"
fi

# --- the JSON form -----------------------------------------------------------
j=$("$MERE" doc --json "$T/a.mere" 2>&1) || { echo "doc_cmd: --json failed" >&2; exit 2; }
if printf '%s' "$j" | grep -q '"doc":"Doubles its argument.' ; then
  printf '  ok    %s\n' "--json carries the block on the value"
else
  printf '  FAIL  %s\n' "--json has no doc for a documented value"
  fail=1
fi
# ⚠ Added, never instead of: the fields other readers already use must survive.
missing=""
for k in '"name"' '"type"' '"status"' '"note"' '"mere"' '"types"'; do
  printf '%s' "$j" | grep -q "$k" || missing="$missing $k"
done
if [ -z "$missing" ]; then
  printf '  ok    %s\n' "the fields --decls --json already had are all still there"
else
  printf '  FAIL  %s\n' "--json lost fields other readers use:$missing"
  fail=1
fi
if [ "$("$MERE" doc --json "$T/a.mere" 2>/dev/null)" = "$("$MERE" --decls --json "$T/a.mere" 2>/dev/null)" ]; then
  printf '  ok    %s\n' "\`doc --json\` and \`--decls --json\` are one answer, not two"
else
  printf '  FAIL  %s\n' "the two JSON spellings disagree — that is two answers about one program"
  fail=1
fi

if [ "$MODE" = "--poison" ]; then
  pfail=0
  # POISON 1: take the comment away — the text must stop claiming it.
  sed '/Doubles its argument/d;/And keeps going/d' "$T/a.mere" > "$T/p1.mere"
  if "$MERE" doc "$T/p1.mere" 2>&1 | grep -q 'Doubles its argument.'; then
    printf '  FAIL  %s\n' "POISON 1: the doc survived its own deletion — it is not read from the source"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 1 (comment deleted): the output stops claiming it"
  fi
  # POISON 2: a comment that is NOT directly above must not be picked up.
  cat > "$T/p2.mere" <<'EOF'
// FLOATING far from anything.

let x = fn (n: int) -> n;
print_int (x 1)
EOF
  if "$MERE" doc "$T/p2.mere" 2>&1 | grep -q 'FLOATING'; then
    printf '  FAIL  %s\n' "POISON 2: a comment with a blank line under it was attached anyway"
    pfail=1
  else
    printf '  ok    %s\n' "POISON 2 (blank line between): a detached comment is not documentation"
  fi
  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "doc_cmd --poison: ok (the gate can go red)"
  else
    echo "doc_cmd --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "doc_cmd: ok"; else echo "doc_cmd: FAILED"; fi
exit "$fail"
