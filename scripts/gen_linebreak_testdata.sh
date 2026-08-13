#!/bin/sh
# scripts/gen_linebreak_testdata.sh — vendor the UCD's line break conformance suite.
#
# UAX #14 has no oracle in node: Intl.Segmenter has no `line` granularity and
# Intl.v8BreakIterator is gone. What it has instead is the Unicode Consortium's
# own conformance file, 19,338 cases derived from the rules — not an independent
# implementation, but normative and exhaustive over the pair table, which is more
# than a hand-written corpus would ever be.
#
# It is vendored rather than fetched by the gate, for two reasons: a gate that
# needs the network fails for reasons that have nothing to do with the code, and
# the file's version has to match the table's or the two disagree about characters
# assigned in between. Comments are stripped — they are 82% of the file — and the
# version header is kept so the vendored copy says what it is.
#
# Needs network. Maintenance command, not a gate.
#
# Usage:
#   sh scripts/gen_linebreak_testdata.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/test/data/LineBreakTest.txt"
UNICODE_VERSION=17.0

command -v curl >/dev/null 2>&1 || { echo "gen_linebreak_testdata: curl absent" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -sSfL "https://www.unicode.org/Public/$UNICODE_VERSION.0/ucd/auxiliary/LineBreakTest.txt" \
  -o "$TMP/full.txt" || {
  echo "gen_linebreak_testdata: could not fetch (needs network)" >&2; exit 1; }

head -1 "$TMP/full.txt" | grep -q "$UNICODE_VERSION" || {
  echo "gen_linebreak_testdata: fetched file is not $UNICODE_VERSION:" >&2
  head -1 "$TMP/full.txt" >&2; exit 1; }

{
  sed -n '1,6p' "$TMP/full.txt"
  echo "#"
  echo "# Comments stripped by scripts/gen_linebreak_testdata.sh. Regenerate with it."
  echo "#"
  grep -v '^#' "$TMP/full.txt" | grep -v '^[[:space:]]*$' | sed 's/	#.*//'
} > "$OUT"

echo "gen_linebreak_testdata: wrote $OUT ($(grep -c '^[×÷]' "$OUT" | tr -d ' ') cases, $(wc -c < "$OUT" | tr -d ' ') bytes)"
