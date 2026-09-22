#!/bin/sh
# scripts/syntax_hint_check.sh — the first layer a newcomer hits says what to
# write instead.
#
# The compiler's SEMANTIC errors carry `help:` lines; its SYNTACTIC ones carried
# none, in either the lexer or the parser, although the syntax layer is the one
# a reader meets first. Worse, several of its messages were actively
# misleading: `var x = 1;` and `def f(n):` both came back as `trailing input`,
# and Python's `a and b` as `expected ';' or 'in' after let binding`, because
# `and` is Mere's keyword for a mutual-recursion group.
#
# WHAT IS CHECKED: every row of the catalogue — a spelling from another
# language, and the sentence Mere answers it with. One table, read from three
# places (the lexer's refused character, the parser's failing token, and the
# typer's unbound name), so a row that stops working stops working here.
#
# Usage:
#   sh scripts/syntax_hint_check.sh            # check
#   sh scripts/syntax_hint_check.sh --poison   # check that it can go red
#
# THE POISONS are three, and the first two are the risk this design took on:
#   1. `!=` and `let rec ... and` are CORRECT Mere. A program that uses them
#      must get no hint — the table must answer about a position, not a word.
#   2. `var`, `case`, `val` and `mut` are real identifiers in the Mere
#      repositories (`let var = list_sum ...`, `fn (case: int) -> case * 2`,
#      `fn val ->`, `&mut R v`, and — in mere-ruby — as TUPLE PATTERN binders,
#      `let (val, j) = ...` and `let (classes, var, prefix, r2) = ...`). A file
#      that BINDS one of them and then fails to parse for an unrelated reason
#      must not be told about another language's keyword.
#   3. a `mere` that prints the same errors with the `help:` lines stripped
#      must make the catalogue go red — or the catalogue is not reading them.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-$ROOT/_build/default/bin/mere.exe}"
[ -x "$MERE" ] || { echo "syntax_hint: $MERE not built" >&2; exit 2; }

tmp="${TMPDIR:-/tmp}/syntax_hint.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT INT TERM

# Each row: a name, the sentence that must come back, and the program.
# The program is written with \n for newlines so a row stays on one line.
catalogue() {
  bin="$1"
  n=0
  while IFS='|' read -r name want prog; do
    [ -n "$name" ] || continue
    # shellcheck disable=SC2059
    printf "$prog\n" > "$tmp/case.mere"
    out=$("$bin" check "$tmp/case.mere" 2>&1)
    if printf '%s' "$out" | grep -qF "$want"; then
      [ "${QUIET:-0}" = 1 ] || printf '  ok    %-12s %s\n' "$name" "$want"
    else
      got=$(printf '%s' "$out" | grep -o 'help:.*' | head -1)
      [ "${QUIET:-0}" = 1 ] || printf '  FAIL  %-12s wanted %s, got: %s\n' \
        "$name" "$want" "${got:-<no hint>}"
      n=$((n + 1))
    fi
  done <<'EOF'
plus_eq|`+=`|let x = 1;\nlet _ = x += 1;
hash|comments are `//`|# a comment\nlet x = 1;
bang|negation is `not x`|let t = true;\nlet _ = !t;
dollar|string interpolation|let y = 1;\nlet x = $y;
at|Mere has no attributes|let x = @foo;
arrow|`=>`|let f = fn (n: int) => n + 1;
braces_fn|no braces for blocks|let f = fn (x) { x + 1 };
braces_if|no braces for blocks|let f = fn (n: int) -> if (n > 0) { 1 } else { 0 };
braces_match|no braces for blocks|let f = fn (n: int) -> match n { 1 -> 1 };
eq|comparison is `==`|let f = fn (n: int) -> if n = 1 then 1 else 0;
mut|`mut`|let mut x = 1;
var|`var`|var x = 1;
def|`def`|def f(n):\n  return n
return|`return`|let f = fn (n: int) -> return n;
case|`case`|let f = fn (n: int) -> case n of 1 -> 1;
elif|`elif`|let x = 1;\nlet _ = if x > 0 then print "a" elif x < 0 then print "b" else print "c";
pyand|boolean `and` is `&&`|let f = fn (a: bool) -> fn (b: bool) -> a and b;
semi|`;`|let x = 1;\n; let y = 2;
EOF
  return "$n"
}

catalogue "$MERE"
fail=$?

# Correct programs, and programs that bind the words, must stay silent.
silent() {
  name="$1"; shift
  printf '%s\n' "$1" > "$tmp/quiet.mere"
  got=$("$MERE" check "$tmp/quiet.mere" 2>&1 | grep -o 'help: `.*' | head -1)
  if [ -z "$got" ]; then
    printf '  ok    %s\n' "$name"
    return 0
  fi
  printf '  FAIL  %s (%s)\n' "$name" "$got"
  return 1
}

silent "\`!=\` is a comparison, not an attempt at \`!\`" \
  'let f = fn (n: int) -> n != 1;
let _ = print_int (if f 2 then 1 else 0);' || fail=$((fail + 1))
silent "\`and\` joins a rec group" \
  'let rec ev = fn (n: int) -> if n == 0 then true else od (n - 1)
and od = fn (n: int) -> if n == 0 then false else ev (n - 1);
let _ = print_int (if ev 4 then 1 else 0);' || fail=$((fail + 1))

if [ "${1:-}" = "--poison" ]; then
  pfail=0

  # POISON 1 and 2: a file that binds the word keeps its own meaning, even
  # while it is failing to parse for an unrelated reason.
  for pair in "var:let var = 4;\nlet _ = print_int (var + );" \
              "case:let case = fn (n: int) -> n * 2;\nlet _ = print_int (case 3;" \
              "val:let f = fn val -> val + ;" \
              "mut:let f = fn (db: &mut R DbHandle) -> db + ;" \
              "val:let f = fn (s: str) -> let (val, j) = scan s in val + j + ;" \
              "var:let f = fn (r: str) -> let (classes, var, p, r2) = parse r in var + ;"; do
    w=${pair%%:*}; prog=${pair#*:}
    # shellcheck disable=SC2059
    printf "$prog\n" > "$tmp/binds.mere"
    got=$("$MERE" check "$tmp/binds.mere" 2>&1 | grep -oF "help: \`$w\`" | head -1)
    if [ -z "$got" ]; then
      printf '  ok    %s\n' "POISON: a file that binds \`$w\` is not told about another language"
    else
      printf '  FAIL  %s\n' "POISON: \`$w\` was answered as a foreign keyword in a file that binds it"
      pfail=1
    fi
  done

  # POISON 3: strip the hints and the catalogue must notice.
  cat > "$tmp/stripped" <<EOF
#!/bin/sh
"$MERE" "\$@" 2>&1 | grep -v 'help:'
exit 1
EOF
  chmod +x "$tmp/stripped"
  QUIET=1 catalogue "$tmp/stripped"
  missed=$?
  if [ "$missed" -ge 18 ]; then
    printf '  ok    %s\n' "POISON: with the hints stripped, all $missed rows go red"
  else
    printf '  FAIL  %s\n' "POISON: with the hints stripped, only $missed rows went red"
    pfail=1
  fi

  if [ "$pfail" = 0 ] && [ "$fail" = 0 ]; then
    echo "syntax_hint --poison: ok (the gate can go red)"
  else
    echo "syntax_hint --poison: FAILED"; pfail=1
  fi
  exit "$pfail"
fi

if [ "$fail" = 0 ]; then echo "syntax_hint: ok"; else echo "syntax_hint: FAILED ($fail)"; fi
[ "$fail" = 0 ]
