#!/bin/sh
# scripts/linebreak_conformance.sh — run contrib/unicode/linebreak.mere against the
# UCD's own line break conformance suite.
#
# **This gate is a different shape from the others in this repository, and it is
# worth saying why before the numbers.** url_parity, encoding_parity and
# unicode_parity all compare against somebody else's implementation — node's URL,
# TextDecoder and Intl.Segmenter. UAX #14 has none: `Intl.Segmenter` has no `line`
# granularity and `Intl.v8BreakIterator` is gone. So this compares against the
# Unicode Consortium's own test file instead.
#
# That is weaker in one specific way and stronger in another, and both matter:
#
#   * **Weaker**: the file is derived from the same rules the implementation reads,
#     so a shared misreading of the prose would agree with itself. An independent
#     implementation would not.
#   * **Stronger**: it is exhaustive over the pair table — 19,338 cases, every
#     class against every class with and without an intervening combining mark and
#     space — which no hand-written corpus and no sampling of another
#     implementation would reach.
#
# The file is vendored (see scripts/gen_ucd_testdata.sh) rather than fetched,
# so this runs offline and cannot fail for network reasons, and so its version
# cannot drift from the table's.
#
# Usage:
#   sh scripts/linebreak_conformance.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"
DATA="$ROOT/test/data/LineBreakTest.txt"

[ -x "$MERE" ] || { echo "linebreak_conformance: $MERE not found — run 'dune build'" >&2; exit 1; }
[ -f "$DATA" ] || {
  echo "linebreak_conformance: $DATA missing — run scripts/gen_ucd_testdata.sh" >&2
  exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Each line is `× 0041 ÷ 0042 ÷`: the marks are the answer, the hex is the input.
# Split into two files so the comparison is a plain diff.
awk '
  /^[×÷]/ {
    cps = ""; brk = ""
    n = split($0, t, /[ \t]+/)
    for (i = 1; i <= n; i++) {
      if (t[i] == "×") brk = brk "x"
      else if (t[i] == "÷") brk = brk "/"
      else if (t[i] != "") cps = (cps == "" ? t[i] : cps " " t[i])
    }
    print cps > CORPUS
    print brk > WANT
  }
' CORPUS="$TMP/corpus.txt" WANT="$TMP/want.txt" "$DATA"

cases=$(wc -l < "$TMP/corpus.txt" | tr -d ' ')

cat > "$ROOT/examples/.lb_conf_tmp.mere" <<'MERE'
import "../contrib/unicode/linebreak.mere";

let _hv = fn (b: int) ->
  if b >= 48 && b <= 57 then b - 48
  else if b >= 65 && b <= 70 then b - 55
  else b - 87;

let rec _hex = fn (s: str) -> fn (i: int) -> fn (n: int) -> fn (acc: int) ->
  if i >= n then acc else _hex s (i + 1) n (acc * 16 + _hv (ord (char_at s i)));

let _build = fn (line: str) ->
  list_fold (list_map (str_split line " ")
                      (fn (h: str) -> str_of_codepoint (_hex h 0 (str_len h) 0)))
            "" (fn (a: str) -> fn (b: str) -> a ++ b);

// `x` for a prohibited position and `/` for an opportunity, which is the test
// file's own notation with its two characters swapped for ASCII.
let _show = fn (s: str) ->
  list_fold (list_map (LineBreak.opportunities s)
                      (fn (b: bool) -> if b then "/" else "x"))
            "" (fn (a: str) -> fn (b: str) -> a ++ b);

let rec _go = fn (lines: str list) ->
  match lines with
  | Nil -> 0
  | Cons (line, rest) ->
    let _ = if str_len line == 0 then () else print (_show (_build line)) in
    _go rest;

let _ = _go (read_lines "CORPUS_PATH");
0
MERE
sed -i.bak "s|CORPUS_PATH|$TMP/corpus.txt|" "$ROOT/examples/.lb_conf_tmp.mere"
rm -f "$ROOT/examples/.lb_conf_tmp.mere.bak"
( ulimit -t 900; "$MERE" "$ROOT/examples/.lb_conf_tmp.mere" ) | sed '$d' > "$TMP/ours.txt"
rm -f "$ROOT/examples/.lb_conf_tmp.mere"

if diff -q "$TMP/want.txt" "$TMP/ours.txt" >/dev/null; then
  version=$(sed -n '1s/^# //p' "$DATA")
  echo "  ok    line breaks  ($cases conformance cases, all agreeing — $version)"
  echo "linebreak_conformance: ok"
  exit 0
fi

echo "  FAIL  line breaks" >&2
paste -d'\t' "$TMP/corpus.txt" "$TMP/want.txt" "$TMP/ours.txt" \
  | awk -F'\t' '$2 != $3 { n++; if (n <= 10) printf "        %-46s\n          want=%s\n          ours=%s\n", substr($1, 1, 46), $2, $3 }
                END { printf "        %d of '"$cases"' cases differ\n", n }' >&2
echo "linebreak_conformance: FAILED" >&2
exit 1
