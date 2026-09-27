#!/bin/sh
# scripts/keywords_doc_check.sh -- every reserved word the lexer has is listed
# where a person looks for the reserved words.
#
# `view` became a keyword with view-type declarations and was never written
# into docs/reserved-names.md; `let view = 5` failed with "expected pattern"
# and nothing anywhere said the name was taken (Q-084). The language
# reference's own Keywords block was missing four more: trait, impl, dyn and
# derive. A hand-kept list drifts from the table it copies, so this derives
# the words FROM the table -- `Lexer.keywords` in lib/lexer.ml -- and requires
# each one in both documents.
#
# Two places, checked separately, because each is where somebody looks:
#   docs/language-reference.md   the fenced block under "### Keywords"
#   docs/reserved-names.md       section 0, as `word` in backticks
#
# POISON (--poison): a lexer table with one word the documents do not have
# must fail, naming it; and a floor on how many words were read, so a change
# to the table's layout cannot make this pass by reading nothing.
#
# Usage: sh scripts/keywords_doc_check.sh [--poison]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEXER="${KW_LEXER-$ROOT/lib/lexer.ml}"
REF="$ROOT/docs/language-reference.md"
RES="$ROOT/docs/reserved-names.md"

if [ "${1-}" = "--poison" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  # awk, not sed: a newline in a sed replacement is GNU-only
  awk '{print} /^  \("view", T_view\);/{print "  (\"zzpoisonword\", T_view);"}' "$LEXER" > "$tmp/lexer.ml"
  grep -q zzpoisonword "$tmp/lexer.ml" || { echo "FAIL keywords_doc --poison: could not plant the word"; exit 1; }
  out=$(KW_LEXER="$tmp/lexer.ml" sh "$0" 2>&1)
  if [ $? -eq 0 ]; then echo "POISON NOT CAUGHT: an undocumented keyword passed"; exit 1; fi
  printf '%s' "$out" | grep -q 'zzpoisonword' || { echo "POISON CAUGHT FOR THE WRONG REASON"; printf '%s\n' "$out"; exit 1; }
  printf 'let keywords : (string * token) list = [\n]\n' > "$tmp/empty.ml"
  out=$(KW_LEXER="$tmp/empty.ml" sh "$0" 2>&1)
  if [ $? -eq 0 ]; then echo "POISON NOT CAUGHT: an empty table passed"; exit 1; fi
  echo "keywords_doc --poison: 2 caught"; exit 0
fi

# the words of `let keywords ... = [ ("w", T_x); ... ]`, `_` excluded (it is a
# pattern, and both documents spell it differently)
words=$(awk '/^let keywords : /{f=1; next} f && /^\]/{exit} f' "$LEXER" \
          | sed -n 's/^  ("\([a-z_]*\)", T_[a-z_]*);.*/\1/p' | grep -v '^_$')
n=$(printf '%s\n' "$words" | grep -c .)
[ "$n" -ge 25 ] || { echo "FAIL keywords_doc: only $n reserved words read from $LEXER (floor 25) -- the table moved or changed shape"; exit 1; }

refblock=$(awk '/^### Keywords/{f=1; next} f && /^```/{c++; if (c==2) exit; next} f && c==1' "$REF")
[ -n "$refblock" ] || { echo "FAIL keywords_doc: no fenced block under \"### Keywords\" in docs/language-reference.md"; exit 1; }
ressect=$(awk '/^## 0\. /{f=1; next} f && /^## /{exit} f' "$RES")
[ -n "$ressect" ] || { echo "FAIL keywords_doc: no section 0 in docs/reserved-names.md"; exit 1; }

fails=0
for w in $words; do
  printf '%s\n' "$refblock" | tr ' ' '\n' | grep -qx "$w" \
    || { echo "FAIL keywords_doc: \`$w\` is a reserved word and language-reference.md's Keywords block does not list it"; fails=$((fails + 1)); }
  printf '%s\n' "$ressect" | grep -qF "\`$w\`" \
    || { echo "FAIL keywords_doc: \`$w\` is a reserved word and reserved-names.md section 0 does not list it"; fails=$((fails + 1)); }
done
[ "$fails" -eq 0 ] || exit 1
echo "keywords_doc: ok ($n reserved words, each in language-reference.md and reserved-names.md)"
