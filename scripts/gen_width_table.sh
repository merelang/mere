#!/bin/sh
# scripts/gen_width_table.sh — contrib/unicode/width_table.mere, from the UCD.
#
# How wide a code point is ON A TERMINAL: 0 for a combining mark, 2 for the
# East Asian wide and fullwidth forms, 1 for everything else -- and a fourth
# answer, AMBIGUOUS, for the code points the standard explicitly refuses to
# decide (EastAsianWidth=A: ±, ※, the box-drawing set). Those are 1 or 2
# depending on the terminal's own configuration, so the table reports that they
# are ambiguous and the caller picks.
#
# WHY THIS IS ITS OWN TABLE AND NOT A COLUMN OF lb_table. The line-break
# generator already reads EastAsianWidth.txt -- and throws away exactly the
# distinction needed here. It keeps one bit, `flag_eastasian`, set for F, W and
# H together, because UAX #14's LB19a and LB30 ask "is this East Asian?" and
# nothing more. But H is halfwidth katakana, which is East Asian AND one column
# wide. Deriving a width from that bit gets every halfwidth form wrong.
#
# THE THREE ORACLES this table is checked against, because one is not enough:
#
#   1. the UCD itself, which is where these bytes come from;
#   2. `Reline::Unicode.get_mbchar_width` (Ruby), a named implementation that
#      a Japanese terminal user's editor actually agrees with --
#      scripts/width_check.sh runs the comparison;
#   3. the TERMINAL, asked by printing a character and reading the cursor
#      column back with ESC[6n. That is the only oracle for the ambiguous
#      set, because there the answer is a property of the terminal and not of
#      Unicode. scripts/width_probe_terminal.sh does that one, and it needs a
#      tty so it is not a gate.
#
# The Unicode version is pinned to node's, the same way the line-break and
# grapheme tables are: mixing vintages produces differences that are neither a
# bug nor interesting.
#
# Needs network. Maintenance command, not a gate.
#
# Usage:
#   sh scripts/gen_width_table.sh          # write the file
#   sh scripts/gen_width_table.sh --check  # fail if it would change

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/contrib/unicode/width_table.mere"
UNICODE_VERSION=17.0

command -v node >/dev/null 2>&1 || { echo "gen_width_table: node absent" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "gen_width_table: curl absent" >&2; exit 1; }

have=$(node -p 'process.versions.unicode')
if [ "$have" != "$UNICODE_VERSION" ]; then
  echo "gen_width_table: node implements Unicode $have, this script pins $UNICODE_VERSION" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

base="https://www.unicode.org/Public/$UNICODE_VERSION.0/ucd"
fetch() {
  curl -sSfL "$base/$1" -o "$TMP/$2" || {
    echo "gen_width_table: could not fetch $1 (needs network)" >&2; exit 1; }
  head -12 "$TMP/$2" | grep -q "$UNICODE_VERSION" || {
    echo "gen_width_table: $1 does not declare $UNICODE_VERSION:" >&2
    head -3 "$TMP/$2" >&2; exit 1; }
}
fetch EastAsianWidth.txt eaw.txt
fetch extracted/DerivedGeneralCategory.txt gc.txt
fetch emoji/emoji-data.txt emoji.txt

cat > "$TMP/gen.js" <<'NODE'
const fs = require("fs");
const MAX = 0x110000;

// A UCD data file: "start..end ; VALUE # comment", one value per line.
const each = (path, fn) => {
  for (const line of fs.readFileSync(path, "utf8").split("\n")) {
    const body = line.split("#")[0].trim();
    if (!body) continue;
    const [range, value] = body.split(";").map((x) => x.trim());
    if (value === undefined) continue;
    const [a, b] = range.split("..");
    fn(parseInt(a, 16), parseInt(b === undefined ? a : b, 16), value);
  }
};

// EastAsianWidth.txt's own default is N for unassigned code points, EXCEPT for
// three ranges the file's header calls out as W by default (the CJK and
// Tangut planes). Missing that makes unassigned CJK one column instead of two.
const eaw = new Array(MAX).fill("N");
const wideByDefault = [
  [0x3400, 0x4DBF], [0x4E00, 0x9FFF], [0xF900, 0xFAFF],
  [0x20000, 0x2FFFD], [0x30000, 0x3FFFD],
];
for (const [s, e] of wideByDefault) for (let c = s; c <= e; c++) eaw[c] = "W";
each(process.env.EAW, (s, e, v) => { for (let c = s; c <= e; c++) eaw[c] = v; });

const gc = new Array(MAX).fill("Cn");
each(process.env.GC, (s, e, v) => { for (let c = s; c <= e; c++) gc[c] = v; });

// Emoji_Presentation, NOT Extended_Pictographic. The wider property includes
// every character that COULD be an emoji, and most of those (‼ ⁉ ℹ ↩ ⌨ ☀ ☘)
// default to TEXT presentation: a terminal draws them in one column unless a
// variation selector U+FE0F follows. Using Extended_Pictographic here made 350
// such characters two columns wide, which is what the Reline cross-check found.
const emojipres = new Array(MAX).fill(false);
each(process.env.EMOJI, (s, e, v) => {
  if (v === "Emoji_Presentation")
    for (let c = s; c <= e; c++) emojipres[c] = true;
});

// The four answers. AMB is separate from ONE so a caller can be told "the
// standard does not decide this" rather than being handed a guess that looks
// like a fact.
const ZERO = 0, ONE = 1, TWO = 2, AMB = 3;

const widthOf = (c) => {
  // C0 and C1 controls have no width a terminal agrees on; they are the
  // caller's problem (an editor renders them as ^X and counts its own two).
  // Reporting 0 rather than inventing a number keeps the arithmetic honest.
  if (c < 0x20 || (c >= 0x7f && c < 0xa0)) return ZERO;

  // U+00AD SOFT HYPHEN is Cf but every terminal prints it as one column.
  if (c === 0x00ad) return ONE;

  // Combining marks and format characters take no space of their own: they
  // attach to the base before them. This is what makes "á" (a + U+0301) one
  // column wide rather than two.
  const g = gc[c];
  if (g === "Mn" || g === "Me" || g === "Cf") return ZERO;

  // U+1160..U+11FF are conjoining Hangul jamo vowels and finals, which compose
  // onto the leading jamo before them and add nothing.
  if (c >= 0x1160 && c <= 0x11ff) return ZERO;

  const w = eaw[c];
  if (w === "W" || w === "F") return TWO;
  if (w === "A") return AMB;

  // An emoji whose DEFAULT presentation is emoji is two columns even where its
  // EastAsianWidth says otherwise -- the regional-indicator letters that make
  // flags are EAW=Neutral, and a flag is two columns on every terminal.
  if (emojipres[c]) return TWO;

  return ONE;
};

// Run-length: only ranges whose width differs from the default are stored.
const DEFAULT = ONE;
const ranges = [];
let start = 0, cur = widthOf(0);
for (let c = 1; c <= MAX; c++) {
  const k = c === MAX ? -1 : widthOf(c);
  if (k === cur) continue;
  if (cur !== DEFAULT) ranges.push([start, c - 1, cur]);
  start = c; cur = k;
}

const h = (v, w) => v.toString(16).toUpperCase().padStart(w, "0");
// Thirteen characters each: six start, six end, one width. NUL-free, because a
// str is strlen-based on the LLVM backend.
const body = ranges.map(([s, e, k]) => h(s, 6) + h(e, 6) + h(k, 1)).join("");

const tally = [0, 0, 0, 0];
for (let c = 0; c < MAX; c++) tally[widthOf(c)]++;

const L = [];
L.push("// contrib/unicode/width_table.mere — GENERATED. Do not edit.");
L.push("//");
L.push("// Written by scripts/gen_width_table.sh from the UCD. Run it to regenerate.");
L.push("//");
L.push("// Unicode " + process.env.UNICODE_VERSION + ", pinned to node's, the same way the");
L.push("// line-break and grapheme tables are.");
L.push("//");
L.push("// How many columns a code point occupies on a terminal:");
L.push("//   0  combining marks, format characters, conjoining jamo, controls");
L.push("//   1  the default, and therefore not stored");
L.push("//   2  East Asian Wide and Fullwidth, and emoji presentation");
L.push("//   3  AMBIGUOUS — EastAsianWidth=A, which the standard declines to decide.");
L.push("//      One column on a Western terminal and two on an East Asian one. The");
L.push("//      table reports the ambiguity rather than guessing; Width.of_cp resolves");
L.push("//      it with the caller's preference.");
L.push("//");
L.push("// This is NOT derivable from lb_table's `flag_eastasian`, which sets one bit");
L.push("// for F, W and H together -- H is halfwidth katakana, East Asian and one");
L.push("// column wide. UAX #14 only ever asks \"is this East Asian?\"; a width needs");
L.push("// the distinction that question throws away.");
L.push("//");
L.push("// " + ranges.length + " ranges, thirteen characters each: six start, six end, one");
L.push("// width. Width 1 is the unstored default. Binary searched over a fixed-width");
L.push("// hexadecimal literal — NUL-free, because a str is strlen-based on the LLVM");
L.push("// backend.");
L.push("//");
L.push("// Code points per width:");
L.push("//   0   " + tally[0]);
L.push("//   1   " + tally[1] + "  (default, unstored)");
L.push("//   2   " + tally[2]);
L.push("//   amb " + tally[3]);
L.push("");
L.push("module WidthTable {");
L.push("");
L.push("  // The fourth answer is a separate value, not a width: a caller that treats");
L.push("  // it as a number gets 3 columns and will notice, which is better than");
L.push("  // silently getting 1 where the terminal uses 2.");
L.push("  let w_zero = 0;");
L.push("  let w_one = 1;");
L.push("  let w_two = 2;");
L.push("  let w_ambiguous = 3;");
L.push("");
L.push("  let count = " + ranges.length + ";");
L.push("  let _default = " + DEFAULT + ";");
L.push("");
L.push("  let _t = \"" + body + "\";");
L.push("");
L.push("  let _hexval = fn (b: int) -> if b >= 48 && b <= 57 then b - 48 else b - 55;");
L.push("");
L.push("  let rec _read = fn (i: int) -> fn (w: int) -> fn (acc: int) ->");
L.push("    if w <= 0 then acc");
L.push("    else _read (i + 1) (w - 1) (acc * 16 + _hexval (ord (char_at _t i)));");
L.push("");
L.push("  let _start_at = fn (k: int) -> _read (k * 13) 6 0;");
L.push("  let _end_at = fn (k: int) -> _read (k * 13 + 6) 6 0;");
L.push("  let _w_at = fn (k: int) -> _read (k * 13 + 12) 1 0;");
L.push("");
L.push("  let rec _find = fn (cp: int) -> fn (lo: int) -> fn (hi: int) ->");
L.push("    if lo > hi then _default");
L.push("    else");
L.push("      let mid = (lo + hi) / 2 in");
L.push("      if cp < _start_at mid then _find cp lo (mid - 1)");
L.push("      else if cp > _end_at mid then _find cp (mid + 1) hi");
L.push("      else _w_at mid;");
L.push("");
L.push("  // The raw answer, ambiguity included. `Width.of_cp` is the one to call.");
L.push("  let class_of = fn (cp: int) -> _find cp 0 (count - 1);");
L.push("");
L.push("}");
L.push("");

process.stdout.write(L.join("\n"));
process.stderr.write(ranges.length + " ranges, " + body.length + " characters; " +
  "zero=" + tally[0] + " two=" + tally[2] + " amb=" + tally[3] + "\n");
NODE

EAW="$TMP/eaw.txt" GC="$TMP/gc.txt" EMOJI="$TMP/emoji.txt" \
  UNICODE_VERSION="$UNICODE_VERSION" node --stack-size=4000 "$TMP/gen.js" > "$TMP/width_table.mere"

mkdir -p "$ROOT/contrib/unicode"

if [ "$1" = "--check" ]; then
  [ -f "$OUT" ] || { echo "gen_width_table: $OUT does not exist" >&2; exit 1; }
  if diff -q "$OUT" "$TMP/width_table.mere" >/dev/null; then
    echo "gen_width_table: ok  (the checked-in table is what the UCD says)"
    exit 0
  fi
  echo "gen_width_table: FAILED — the derived table differs from the checked-in file" >&2
  diff "$OUT" "$TMP/width_table.mere" | head -5 | cut -c1-120 >&2
  exit 1
fi

cp "$TMP/width_table.mere" "$OUT"
echo "gen_width_table: wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
