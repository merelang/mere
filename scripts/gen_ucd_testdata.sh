#!/bin/sh
# scripts/gen_ucd_testdata.sh — vendor the UCD's own conformance suites.
#
# Two files, for two algorithms that both have one:
#
#   auxiliary/LineBreakTest.txt   UAX #14, 19,338 cases
#   NormalizationTest.txt         UAX #15, 20,034 cases
#
# UAX #14 has no oracle in node at all — Intl.Segmenter has no `line` granularity
# and Intl.v8BreakIterator is gone — so its conformance file is the only gate
# available. Normalization does have one (String.prototype.normalize) and gets both:
# the independent implementation in scripts/unicode_parity.sh and the exhaustive
# file here. Neither is a substitute for the other, and the normalization slice is
# the one place in this repository where both kinds are pointed at the same code.
#
# Only the columns a gate reads are kept. NormalizationTest.txt has five — source,
# NFC, NFD, NFKC, NFKD — and NFKC/NFKD are dropped because nothing implements them
# yet; vendoring a megabyte of data no gate looks at would be storing a promise
# rather than a test. Regenerate when NFKC lands.
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
#   sh scripts/gen_ucd_testdata.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LB_OUT="$ROOT/test/data/LineBreakTest.txt"
NF_OUT="$ROOT/test/data/NormalizationTest.txt"
UNICODE_VERSION=17.0

command -v curl >/dev/null 2>&1 || { echo "gen_ucd_testdata: curl absent" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

base="https://www.unicode.org/Public/$UNICODE_VERSION.0/ucd"

fetch() {
  curl -sSfL "$base/$1" -o "$TMP/$2" || {
    echo "gen_ucd_testdata: could not fetch $1 (needs network)" >&2; exit 1; }
  head -1 "$TMP/$2" | grep -q "$UNICODE_VERSION" || {
    echo "gen_ucd_testdata: $1 is not $UNICODE_VERSION:" >&2
    head -1 "$TMP/$2" >&2; exit 1; }
}

fetch auxiliary/LineBreakTest.txt lb.txt
{
  sed -n '1,6p' "$TMP/lb.txt"
  echo "#"
  echo "# Comments stripped by scripts/gen_ucd_testdata.sh. Regenerate with it."
  echo "#"
  grep -v '^#' "$TMP/lb.txt" | grep -v '^[[:space:]]*$' | sed 's/	#.*//'
} > "$LB_OUT"
echo "gen_ucd_testdata: wrote $LB_OUT ($(grep -c '^[×÷]' "$LB_OUT" | tr -d ' ') cases, $(wc -c < "$LB_OUT" | tr -d ' ') bytes)"

fetch NormalizationTest.txt nf.txt
{
  sed -n '1,6p' "$TMP/nf.txt"
  echo "#"
  echo "# Comments stripped and the NFKC/NFKD columns dropped by"
  echo "# scripts/gen_ucd_testdata.sh — nothing implements them yet. The three that"
  echo "# remain are source; NFC; NFD. Regenerate to get all five back."
  echo "#"
  grep -E '^([0-9A-Fa-f]|@)' "$TMP/nf.txt" \
    | sed 's/[[:space:]]*#.*//' \
    | awk -F';' '/^@/ { print; next } { print $1 ";" $2 ";" $3 ";" }'
} > "$NF_OUT"
echo "gen_ucd_testdata: wrote $NF_OUT ($(grep -c '^[0-9A-Fa-f]' "$NF_OUT" | tr -d ' ') cases, $(wc -c < "$NF_OUT" | tr -d ' ') bytes)"
