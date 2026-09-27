#!/bin/sh
# scripts/selfhost_lexer_ops_check.sh -- the self-hosted lexer reads every
# operator the compiler's lexer reads, as one token.
#
# contrib/parser/lexer.mere is the second lexer in the repository, and it fell
# behind the first (Q-153): `|>`, the language's own pipe, came out as Pipe
# then Gt; `<|` and `<>` split the same way; `@@` and `?` failed outright. The
# self-host bootstrap stayed green throughout, because its corpus uses none of
# them. So the operator list is not written here. It is DERIVED from
# lib/lexer.ml -- every `| 'c' when ... s.[i + 1] = 'd'` arm is a two-character
# operator, every `| 'c' -> advance 1; ... T_...` arm a one-character one --
# and each is handed to the self-hosted `tokenize`, which must return exactly
# two tokens: the operator and Eof. A lex failure counts as not reading it.
#
# NOT CHECKED: that the two lexers give the SAME token. The self-hosted one
# has its own constructor names, and its parser does not read most of these
# operators yet; this asks only that the text is split where the compiler
# splits it. Reserved words are a separate gap (the self-hosted parser reads
# `import` as an identifier) and are not asked here.
#
# POISON (--poison): an operator the self-hosted lexer cannot read must fail,
# naming it; and a floor on how many operators were derived, so a change to
# lib/lexer.ml's layout cannot make this pass by finding none.
#
# Usage: sh scripts/selfhost_lexer_ops_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
LEXER_ML="${OPS_LEXER_ML-$ROOT/lib/lexer.ml}"
[ -x "$MERE" ] || { echo "selfhost_lexer_ops: $MERE not found -- run 'dune build'" >&2; exit 1; }

if [ "${1-}" = "--poison" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  # a two-character operator nobody has: the self-hosted lexer splits or fails on it
  awk '{print} /^      \| .\|. when i \+ 1 < len && s\.\[i \+ 1\] = .>. ->/ && !done {print "      | '"'"'~'"'"' when i + 1 < len && s.[i + 1] = '"'"'~'"'"' ->"; done=1}' "$LEXER_ML" > "$tmp/lexer.ml"
  grep -q "'~' when" "$tmp/lexer.ml" || { echo "FAIL selfhost_lexer_ops --poison: could not plant the operator"; exit 1; }
  out=$(OPS_LEXER_ML="$tmp/lexer.ml" sh "$0" 2>&1)
  if [ $? -eq 0 ]; then echo "POISON NOT CAUGHT: an operator the self-hosted lexer cannot read passed"; exit 1; fi
  printf '%s' "$out" | grep -qF '`~~`' || { echo "POISON CAUGHT FOR THE WRONG REASON"; printf '%s\n' "$out"; exit 1; }
  : > "$tmp/empty.ml"
  out=$(OPS_LEXER_ML="$tmp/empty.ml" sh "$0" 2>&1)
  if [ $? -eq 0 ]; then echo "POISON NOT CAUGHT: deriving no operators passed"; exit 1; fi
  echo "selfhost_lexer_ops --poison: 2 caught"; exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# `//` is excluded: that arm begins a comment in both lexers, and zero tokens is
# the right answer for it. `'\\'` is the one arm whose character is written
# as two, so the one-character pattern does not see it; it is asked for by name.
{
  sed -n "s/^      | '\(.\)' when i + 1 < len && s\.\[i + 1\] = '\(.\)' ->.*/\1\2/p" "$LEXER_ML"
  sed -n "s/^      | '\(.\)' -> advance 1; aux (i + 1) ((pos, T_[a-z_]*) :: acc).*/\1/p" "$LEXER_ML"
  grep -qF "| '\\\\' -> advance 1; aux (i + 1) ((pos, T_backslash)" "$LEXER_ML" && printf '%s\n' '\'
} | grep -vx '//' | awk '!seen[$0]++' > "$TMP/ops"
n=$(grep -c . "$TMP/ops")
[ "$n" -ge 30 ] || { echo "FAIL selfhost_lexer_ops: only $n operators derived from $LEXER_ML (floor 30) -- the arms changed shape"; exit 1; }

# One program asks about all of them. `\`, `"` and `{` are escaped for a Mere
# string literal; try_or keeps one failing operator from ending the run.
{
  echo 'import "contrib/parser/lexer.mere";'
  echo 'let t = fn (op: str) -> print (str_of_int (try_or (fn u -> list_len (tokenize op)) (0 - 1)));'
  while IFS= read -r op; do
    lit=$(printf '%s' "$op" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/{/\\{/g')
    printf 'let _ = t "%s";\n' "$lit"
  done < "$TMP/ops"
  echo '()'
} > "$ROOT/_selfhost_lexer_ops.mere"
( cd "$ROOT" && "$MERE" ./_selfhost_lexer_ops.mere ) > "$TMP/counts" 2>"$TMP/err"
rc=$?
rm -f "$ROOT/_selfhost_lexer_ops.mere"
[ "$rc" -eq 0 ] || { echo "FAIL selfhost_lexer_ops: the probe program did not run: $(head -1 "$TMP/err")"; exit 1; }
[ "$(grep -c . "$TMP/counts")" -eq "$n" ] || { echo "FAIL selfhost_lexer_ops: $n operators asked, $(grep -c . "$TMP/counts") answers"; exit 1; }

fails=0
paste -d ' ' "$TMP/counts" "$TMP/ops" > "$TMP/pairs"
while IFS= read -r line; do
  cnt=${line%% *}; op=${line#* }
  case "$cnt" in
    2) ;;
    -1) echo "FAIL selfhost_lexer_ops: \`$op\` -- contrib/parser/lexer.mere fails on it"; fails=$((fails + 1)) ;;
    *)  echo "FAIL selfhost_lexer_ops: \`$op\` -- contrib/parser/lexer.mere reads it as $((cnt - 1)) tokens, the compiler as 1"; fails=$((fails + 1)) ;;
  esac
done < "$TMP/pairs"
[ "$fails" -eq 0 ] || exit 1
echo "selfhost_lexer_ops: ok ($n operators from lib/lexer.ml, each one token in contrib/parser/lexer.mere)"
