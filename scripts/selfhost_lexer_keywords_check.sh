#!/bin/sh
# scripts/selfhost_lexer_keywords_check.sh -- the self-hosted lexer reads every
# reserved word the compiler's lexer reserves as a keyword, not an identifier
# (v0.1.578, Q-153).
#
# The operators' half of this is selfhost_lexer_ops_check.sh. This is the other
# half: `view`, `region`, `import`, `trait` and eight more came out of
# contrib/parser/lexer.mere as identifiers, and its parser matched `TIdent
# "import"` -- a program the compiler refuses (a word it reserves, used as a
# name) went through. The word list is DERIVED from lib/lexer.ml's `keywords`
# table, so a word added there is asked about here without anyone remembering.
#
# --poison: a word the self-hosted lexer does not know, planted in a copy of
# the table, must fail by name; and a floor on how many words were derived.
#
# Usage: sh scripts/selfhost_lexer_keywords_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MERE="$ROOT/_build/default/bin/mere.exe"
LEXER_ML="${KW_LEXER_ML-$ROOT/lib/lexer.ml}"
[ -x "$MERE" ] || { echo "selfhost_lexer_keywords: $MERE not found -- run 'dune build'" >&2; exit 1; }

if [ "${1-}" = "--poison" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  sed 's/^  ("let", T_let);/  ("let", T_let);\n  ("zzkw", T_let);/' "$LEXER_ML" > "$tmp/lexer.ml"
  grep -q '"zzkw"' "$tmp/lexer.ml" || { echo "FAIL selfhost_lexer_keywords --poison: could not plant the word"; exit 1; }
  out=$(KW_LEXER_ML="$tmp/lexer.ml" sh "$0" 2>&1)
  if [ $? -eq 0 ]; then echo "POISON NOT CAUGHT: a word the self-hosted lexer reads as a name passed"; exit 1; fi
  printf '%s' "$out" | grep -qF '`zzkw`' || { echo "POISON CAUGHT FOR THE WRONG REASON"; printf '%s\n' "$out"; exit 1; }
  : > "$tmp/empty.ml"
  out=$(KW_LEXER_ML="$tmp/empty.ml" sh "$0" 2>&1)
  if [ $? -eq 0 ]; then echo "POISON NOT CAUGHT: deriving no words passed"; exit 1; fi
  echo "selfhost_lexer_keywords --poison: 2 caught"; exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# `_` is the wildcard, which both lexers read as its own token
sed -n 's/^  ("\([a-z][a-z]*\)", T_[a-z_]*);$/\1/p' "$LEXER_ML" > "$TMP/words"
n=$(grep -c . "$TMP/words")
[ "$n" -ge 25 ] || { echo "FAIL selfhost_lexer_keywords: only $n words derived from $LEXER_ML (floor 25) -- the table changed shape"; exit 1; }
{
  echo 'import "contrib/parser/lexer.mere";'
  echo 'let t = fn (w: str) -> print (match tokenize w with | Cons ((_, tok), _) -> token_str tok | Nil -> "none");'
  while IFS= read -r w; do printf 'let _ = t "%s";\n' "$w"; done < "$TMP/words"
  echo '()'
} > "$ROOT/_selfhost_lexer_kw.mere"
( cd "$ROOT" && "$MERE" ./_selfhost_lexer_kw.mere ) > "$TMP/names" 2>"$TMP/err"
rc=$?
rm -f "$ROOT/_selfhost_lexer_kw.mere"
[ "$rc" -eq 0 ] || { echo "FAIL selfhost_lexer_keywords: the probe program did not run: $(head -1 "$TMP/err")"; exit 1; }
[ "$(grep -c . "$TMP/names")" -eq "$n" ] || { echo "FAIL selfhost_lexer_keywords: $n words asked, $(grep -c . "$TMP/names") answers"; exit 1; }
fails=0
paste -d ' ' "$TMP/names" "$TMP/words" > "$TMP/pairs"
while IFS= read -r line; do
  name=${line%% *}; w=${line#* }
  case "$name" in
    Ident*) echo "FAIL selfhost_lexer_keywords: \`$w\` is reserved by lib/lexer.ml and read as $name by contrib/parser/lexer.mere"; fails=$((fails + 1)) ;;
  esac
done < "$TMP/pairs"
[ "$fails" -eq 0 ] || exit 1
echo "selfhost_lexer_keywords: ok ($n reserved words from lib/lexer.ml, none read as a name)"
