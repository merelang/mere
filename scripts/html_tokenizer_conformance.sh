#!/bin/sh
# scripts/html_tokenizer_conformance.sh — the HTML tokenizer against the standard's
# own test suite.
#
# html5lib-tests is what every HTML parser is measured against, maintained
# alongside the specification. Same kind of evidence as the UCD conformance files
# used for line breaking and normalization: the cases the people who wrote the
# standard thought were worth writing down, rather than the ones we thought to try.
#
# The vendored copy lives in test/data/html5lib (see gen_html5lib_testdata.sh).
#
# WHAT IS COUNTED. Every case in those files is run. Cases the tokenizer does not
# yet cover are NOT quietly dropped: they are counted, and their categories are
# printed. The pass count is pinned exactly rather than as a floor — a floor lets a
# regression hide behind a new pass, and the number moving in either direction is
# something to look at.
#
# Cases needing a non-Data initial state (RCDATA / RAWTEXT / script data / PLAINTEXT)
# are skipped with a reason, because the entry point takes no state argument yet.
# `doubleEscaped` cases are skipped the same way.
#
# Usage:
#   sh scripts/html_tokenizer_conformance.sh

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MERE="$ROOT/_build/default/bin/mere.exe"
DATA="$ROOT/test/data/html5lib"

[ -x "$MERE" ] || { echo "html_tokenizer: $MERE not found — run 'dune build'" >&2; exit 1; }
[ -d "$DATA" ] || { echo "html_tokenizer: $DATA missing — run gen_html5lib_testdata.sh" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "html_tokenizer: python3 needed to read the JSON" >&2; exit 0; }

# The exact number of cases expected to pass. Raise it when the tokenizer grows;
# a drop is a regression and a rise without a code change is a suite that moved.
EXPECT_PASS=${EXPECT_PASS:-1807}

TMP="${TMPDIR:-/tmp}/mere_html.$$"; mkdir -p "$TMP"; trap 'rm -rf "$TMP"' EXIT

python3 "$ROOT/scripts/html_tokenizer_cases.py" "$DATA" "$TMP/cases.txt" "$TMP/expected.txt" "$TMP/meta.txt"
"$MERE" "$ROOT/test/html/tokenize_cases.mere" "$TMP/cases.txt" > "$TMP/got.txt"
python3 "$ROOT/scripts/html_tokenizer_cases.py" --compare "$TMP/expected.txt" "$TMP/got.txt" "$TMP/meta.txt" "$EXPECT_PASS"
