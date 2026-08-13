#!/bin/sh
# scripts/unicode_parity.sh — check contrib/unicode against somebody else's
# implementation of UAX #29.
#
# node's `Intl.Segmenter` is that implementation. Unlike the URL and Encoding
# oracles it is not a second reading of a specification this code also reads —
# it is ICU, and ICU is what browsers ship — so agreement here is the strongest
# evidence available that the segmentation is right.
#
# **The Unicode version is asserted, not assumed.** The table is generated from a
# pinned UCD version and `Intl.Segmenter` follows whatever node's ICU implements;
# two vintages would differ for reasons that are neither a bug nor interesting.
# So a node upgrade fails here with one line instead of a page of diffs. This is
# url_parity's node 22/24 lesson applied before being bitten rather than after.
#
# The corpus is generated, and generated ONCE: the harness writes it to a file
# that both sides then read. Writing the same list of code points twice, in two
# languages, is how the two lists come to disagree.
#
# Four sections, none of them hand-picked:
#
#   pairs      every ordered pair from a set covering all 18 classes
#   triples    every ordered triple from the classes the non-local rules need
#   quads      every ordered quadruple from a smaller such set — this is what
#              reaches RI RI RI RI, ExtPict ZWJ ExtPict ZWJ, and
#              Consonant Linker Consonant Linker
#   ranges     the first and last code point of every range in the generated
#              table, each paired with a combining mark. 1,631 ranges, so a
#              mis-parsed or shifted range shows up as a segmentation difference
#              rather than waiting for a character nobody tested
#
# Skips (exit 0) when node is absent.
#
# Usage:
#   sh scripts/unicode_parity.sh

NODE_MIN=24
UNICODE_VERSION=17.0

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"
TABLE="$ROOT/contrib/unicode/gcb_table.mere"

command -v node >/dev/null 2>&1 || { echo "unicode_parity: node absent, skipping"; exit 0; }
[ -x "$MERE" ] || { echo "unicode_parity: $MERE not found — run 'dune build'" >&2; exit 1; }
[ -f "$TABLE" ] || { echo "unicode_parity: $TABLE missing — run gen_unicode_tables.sh" >&2; exit 1; }

NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
if [ "$NODE_MAJOR" -lt "$NODE_MIN" ]; then
  echo "unicode_parity: node $(node -v) is below the v${NODE_MIN} floor, skipping"
  exit 0
fi

have=$(node -p 'process.versions.unicode')
if [ "$have" != "$UNICODE_VERSION" ]; then
  echo "unicode_parity: node implements Unicode $have, the table is $UNICODE_VERSION" >&2
  echo "  The oracle and the table have to be the same vintage. Re-run" >&2
  echo "  'sh scripts/gen_unicode_tables.sh' with its pin updated to $have." >&2
  exit 1
fi
echo "unicode_parity: oracle is node $(node -v), Unicode $have"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- corpus and expected answers, both from the oracle side -----------------
# The answer for each input is the length of each cluster in code points, which
# is the segmentation itself and needs no characters printed — a corpus that
# contains U+0000 would otherwise be unprintable on some backends.

cat > "$TMP/gen.js" <<'NODE'
const fs = require("fs");
const seg = new Intl.Segmenter("en", { granularity: "grapheme" });

// One representative per class, plus extras where a class has shapes that behave
// differently. Chosen for coverage, not for taste; U+0000 is left out so the
// corpus stays printable on every backend.
const REPS = [
  0x41,     // Other, ASCII
  0x0D,     // CR
  0x0A,     // LF
  0x09,     // Control
  0x0300,   // Extend (combining acute)
  0x200D,   // ZWJ
  0x1F1EF,  // Regional_Indicator
  0x0600,   // Prepend
  0x0903,   // SpacingMark
  0x1100,   // L
  0x1161,   // V
  0x11A8,   // T
  0xAC00,   // LV
  0xAC01,   // LVT
  0x1F600,  // ExtPict
  0x094D,   // Linker (Devanagari virama)
  0x0915,   // Consonant
  0x1F3FD,  // Extend that is also an emoji modifier
  0x0E33,   // Thai SARA AM, a SpacingMark that reads as prepended
  0x3042,   // Other, non-ASCII
  0xFE0F,   // Extend, variation selector
  0x0483,   // Extend, ccc=0
];

// The non-local rules need sequences, and only these classes take part in them.
const SEQ = [0x1F1EF, 0x1F600, 0x200D, 0x0300, 0x094D, 0x0915, 0x41, 0x0D];
// 0x0300 is in here because GB11 is `ExtPict Extend* ZWJ × ExtPict`, and the
// Extend in the middle only appears at length four.
const QUAD = [0x1F1EF, 0x1F600, 0x200D, 0x0300, 0x094D, 0x0915, 0x41];

const inputs = [];
for (const a of REPS) for (const b of REPS) inputs.push([a, b]);
for (const a of SEQ) for (const b of SEQ) for (const c of SEQ) inputs.push([a, b, c]);
for (const a of QUAD) for (const b of QUAD) for (const c of QUAD) for (const d of QUAD)
  inputs.push([a, b, c, d]);

// The three non-local rules at length: a pair count is not the same question as
// a run of six, and a state machine that gets the pair right can still drift.
for (let n = 1; n <= 8; n++) inputs.push(new Array(n).fill(0x1F1EF));
for (let n = 1; n <= 5; n++) {
  const zwj = [0x1F600];
  for (let i = 1; i < n; i++) zwj.push(0x200D, 0x1F600);
  inputs.push(zwj);
  const withExtend = [0x1F600];
  for (let i = 1; i < n; i++) withExtend.push(0x0300, 0x200D, 0x1F600);
  inputs.push(withExtend);
  const conj = [0x0915];
  for (let i = 1; i < n; i++) conj.push(0x094D, 0x0915);
  inputs.push(conj);
  const hangul = [0x1100];
  for (let i = 1; i < n; i++) hangul.push(0x1161, 0x11A8);
  inputs.push(hangul);
}

// Every range in the generated table, at both ends, paired with a combining mark
// and with an ASCII letter. The table is read out of the generated file rather
// than re-derived, so this checks the file that is actually compiled in.
const src = fs.readFileSync(process.env.TABLE, "utf8");
const m = src.match(/let _t = "([0-9A-F]*)";/);
if (!m) throw new Error("could not find the table literal in " + process.env.TABLE);
const lit = m[1];
if (lit.length % 14 !== 0) throw new Error("table literal is not a whole number of 14-char entries");
let ranges = 0;
for (let i = 0; i < lit.length; i += 14) {
  const s = parseInt(lit.slice(i, i + 6), 16);
  const e = parseInt(lit.slice(i + 6, i + 12), 16);
  ranges++;
  for (const cp of (s === e ? [s] : [s, e])) {
    if (cp >= 0xd800 && cp <= 0xdfff) continue;   // lone surrogates are not text
    inputs.push([0x41, cp]);
    inputs.push([cp, 0x0300]);
  }
}

const corpus = [], want = [];
for (const seqIn of inputs) {
  corpus.push(seqIn.map((c) => c.toString(16).toUpperCase()).join(" "));
  const s = seqIn.map((c) => String.fromCodePoint(c)).join("");
  want.push([...seg.segment(s)].map((x) => [...x.segment].length).join(" "));
}
fs.writeFileSync(process.env.CORPUS, corpus.join("\n") + "\n");
fs.writeFileSync(process.env.WANT, want.join("\n") + "\n");
process.stderr.write(inputs.length + " inputs (" + ranges + " table ranges)\n");
NODE

TABLE="$TABLE" CORPUS="$TMP/corpus.txt" WANT="$TMP/want.txt" \
  node "$TMP/gen.js" 2> "$TMP/gen.log"
counts=$(cat "$TMP/gen.log")

# --- our answers ------------------------------------------------------------

cat > "$ROOT/examples/.uni_parity_tmp.mere" <<'MERE'
import "../contrib/unicode/grapheme.mere";

let _hv = fn (b: int) ->
  if b >= 48 && b <= 57 then b - 48
  else if b >= 65 && b <= 70 then b - 55
  else b - 87;

let rec _hex = fn (s: str) -> fn (i: int) -> fn (n: int) -> fn (acc: int) ->
  if i >= n then acc else _hex s (i + 1) n (acc * 16 + _hv (ord (char_at s i)));

let _cp = fn (h: str) -> _hex h 0 (str_len h) 0;

// "41 300" -> the string those code points spell.
let _build = fn (line: str) ->
  list_fold (list_map (str_split line " ") (fn (h: str) -> str_of_codepoint (_cp h)))
            "" (fn (acc: str) -> fn (piece: str) -> acc ++ piece);

let _lengths = fn (s: str) ->
  str_join " " (list_map (Grapheme.clusters s) (fn (c: str) -> show (utf8_len c)));

let rec _go = fn (lines) ->
  match lines with
  | Nil -> 0
  | Cons (line, rest) ->
    let _ = if str_len line == 0 then () else print (_lengths (_build line)) in
    _go rest;

let _ = _go (read_lines "CORPUS_PATH");
0
MERE
sed -i.bak "s|CORPUS_PATH|$TMP/corpus.txt|" "$ROOT/examples/.uni_parity_tmp.mere"
rm -f "$ROOT/examples/.uni_parity_tmp.mere.bak"
( ulimit -t 600; "$MERE" "$ROOT/examples/.uni_parity_tmp.mere" ) | sed '$d' > "$TMP/ours.txt"
rm -f "$ROOT/examples/.uni_parity_tmp.mere"

if diff -q "$TMP/want.txt" "$TMP/ours.txt" >/dev/null; then
  echo "  ok    grapheme clusters  ($counts, all agreeing)"
  echo "unicode_parity: ok"
  exit 0
fi

echo "  FAIL  grapheme clusters" >&2
paste -d'\t' "$TMP/corpus.txt" "$TMP/want.txt" "$TMP/ours.txt" \
  | awk -F'\t' '$2 != $3 { printf "        U+%-28s node=%-14s ours=%s\n", $1, $2, $3 }' \
  | head -20 >&2
echo "unicode_parity: FAILED" >&2
exit 1
