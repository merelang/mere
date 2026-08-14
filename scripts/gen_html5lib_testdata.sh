#!/bin/sh
# scripts/gen_html5lib_testdata.sh — vendor the HTML standard's own tokenizer tests.
#
# html5lib-tests is the suite every HTML parser is measured against, maintained
# alongside the specification. It is the same kind of evidence as the UCD's
# conformance files: not somebody's idea of what to check, but the cases the people
# who wrote the standard thought were worth writing down.
#
# Vendored rather than fetched by the gate, for the reasons gen_ucd_testdata.sh
# gives: a gate that needs the network fails for reasons that have nothing to do
# with the code, and a suite that moves under you turns a red build into an
# archaeology problem. The commit it came from is recorded below.
#
# Only the files the tokenizer can currently be held to are taken. Adding a file
# here without implementing what it covers would be vendoring a promise.
#
# Needs network. Maintenance command, not a gate.
#
# Usage:
#   sh scripts/gen_html5lib_testdata.sh

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/test/data/html5lib"
BASE="https://raw.githubusercontent.com/html5lib/html5lib-tests"
REF="master"

mkdir -p "$OUT"
for f in test1 test2 test3; do
  echo "fetching tokenizer/$f.test"
  curl -sSf --max-time 60 "$BASE/$REF/tokenizer/$f.test" -o "$OUT/$f.test"
done

echo "---"
for f in "$OUT"/*.test; do
  printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$(basename "$f")"
done
echo "Record these in scripts/html_tokenizer_conformance.sh if they change."
