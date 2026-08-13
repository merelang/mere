#!/bin/sh
# scripts/gen_linebreak_table.sh — generate contrib/unicode/lb_table.mere.
#
# UAX #14 needs more than one property per code point, because several of its
# rules are written in terms of other things: LB15a/15b test General_Category Pi
# and Pf, LB19a and LB30 test East_Asian_Width, LB30b tests an unassigned
# Extended_Pictographic, and LB1's resolution of SA depends on the general
# category too. So four UCD files go in and one class plus four flag bits comes
# out.
#
#   Line_Break              LineBreak.txt
#   East_Asian_Width        EastAsianWidth.txt          (LB19a, LB30)
#   General_Category        extracted/DerivedGeneralCategory.txt  (LB15a/b, LB30b, LB1)
#   Extended_Pictographic   emoji/emoji-data.txt        (LB30b)
#
# **LB1's resolution is done here, not at run time.** AI, SG and XX become AL,
# CJ becomes NS, and SA becomes CM when its general category is Mn or Mc and AL
# otherwise. Those are the choices the UCD's own LineBreakTest.txt assumes, which
# is what this is checked against — the rule itself says the criteria are outside
# the algorithm, so a table that resolves differently is not wrong, it is a
# different tailoring. Doing it in the generator means the rules read the way they
# are written in the standard, with no resolution noise in front of them.
#
# CB is deliberately NOT resolved: LB20 is written in terms of it.
#
# Shape as settled in gen_jis_index.sh and reused in gen_unicode_tables.sh: a
# fixed-width hexadecimal literal, binary searched, NUL-free by construction
# because a str is strlen-based on the LLVM backend. Fifteen characters per
# range — six start, six end, two class, one flags.
#
# The Unicode version is pinned to node's, for the reason the grapheme table is:
# the harness compares against the UCD test file of the same version, and mixing
# vintages produces differences that are neither a bug nor interesting.
#
# Needs network. Maintenance command, not a gate.
#
# Usage:
#   sh scripts/gen_linebreak_table.sh          # write the file
#   sh scripts/gen_linebreak_table.sh --check  # fail if it would change

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/contrib/unicode/lb_table.mere"
UNICODE_VERSION=17.0

command -v node >/dev/null 2>&1 || { echo "gen_linebreak_table: node absent" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "gen_linebreak_table: curl absent" >&2; exit 1; }

have=$(node -p 'process.versions.unicode')
if [ "$have" != "$UNICODE_VERSION" ]; then
  echo "gen_linebreak_table: node implements Unicode $have, this script pins $UNICODE_VERSION" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

base="https://www.unicode.org/Public/$UNICODE_VERSION.0/ucd"
fetch() {
  curl -sSfL "$base/$1" -o "$TMP/$2" || {
    echo "gen_linebreak_table: could not fetch $1 (needs network)" >&2; exit 1; }
  head -12 "$TMP/$2" | grep -q "$UNICODE_VERSION" || {
    echo "gen_linebreak_table: $1 does not declare $UNICODE_VERSION:" >&2
    head -3 "$TMP/$2" >&2; exit 1; }
}
fetch LineBreak.txt lb.txt
fetch EastAsianWidth.txt eaw.txt
fetch extracted/DerivedGeneralCategory.txt gc.txt
fetch emoji/emoji-data.txt emoji.txt

cat > "$TMP/gen.js" <<'NODE'
const fs = require("fs");
const MAX = 0x110000;

const each = (path, fn) => {
  for (const line of fs.readFileSync(path, "utf8").split("\n")) {
    const hash = line.indexOf("#");
    const body = (hash >= 0 ? line.slice(0, hash) : line).trim();
    if (!body) continue;
    const parts = body.split(";").map((s) => s.trim());
    const m = parts[0].match(/^([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?$/);
    if (!m) continue;
    fn(parseInt(m[1], 16), m[2] ? parseInt(m[2], 16) : parseInt(m[1], 16), parts.slice(1));
  }
};

// LineBreak.txt's own default for unlisted code points, stated in its header.
const raw = new Array(MAX).fill("XX");
each(process.env.LB, (s, e, v) => { for (let c = s; c <= e; c++) raw[c] = v[0]; });

const eaw = new Array(MAX).fill("N");
each(process.env.EAW, (s, e, v) => { for (let c = s; c <= e; c++) eaw[c] = v[0]; });

const gc = new Array(MAX).fill("Cn");
each(process.env.GC, (s, e, v) => { for (let c = s; c <= e; c++) gc[c] = v[0]; });

const extpict = new Uint8Array(MAX);
each(process.env.EMOJI, (s, e, v) => {
  if (v[0] !== "Extended_Pictographic") return;
  for (let c = s; c <= e; c++) extpict[c] = 1;
});

// LB1. The criteria are outside the algorithm; these are the ones the UCD's own
// LineBreakTest.txt assumes, which is what the implementation is checked against.
const resolve = (c) => {
  const k = raw[c];
  if (k === "AI" || k === "SG" || k === "XX") return "AL";
  if (k === "CJ") return "NS";
  if (k === "SA") return (gc[c] === "Mn" || gc[c] === "Mc") ? "CM" : "AL";
  return k;
};

const CLASSES = ["AL", "BK", "CR", "LF", "NL", "SP", "ZW", "ZWJ", "CM", "WJ", "GL",
  "CL", "CP", "EX", "SY", "IS", "OP", "QU", "NS", "BB", "BA", "HY", "HH", "IN",
  "PR", "PO", "NU", "HL", "ID", "EB", "EM", "B2", "CB", "RI", "JL", "JV", "JT",
  "H2", "H3", "AK", "AS", "AP", "VF", "VI"];
const num = new Map(CLASSES.map((n, i) => [n, i]));

const FLAG_EASTASIAN = 1, FLAG_PI = 2, FLAG_PF = 4, FLAG_UNASSIGNED_PICT = 8;
const flagsOf = (c) => {
  let f = 0;
  const w = eaw[c];
  if (w === "F" || w === "W" || w === "H") f |= FLAG_EASTASIAN;
  if (gc[c] === "Pi") f |= FLAG_PI;
  if (gc[c] === "Pf") f |= FLAG_PF;
  if (extpict[c] && gc[c] === "Cn") f |= FLAG_UNASSIGNED_PICT;
  return f;
};

const keyOf = (c) => {
  const k = resolve(c);
  if (!num.has(k)) throw new Error("U+" + c.toString(16) + " resolved to unknown class " + k);
  return num.get(k) * 16 + flagsOf(c);
};

// AL with no flags is the default and is not stored, which is most of the space.
const DEFAULT = num.get("AL") * 16;
const ranges = [];
let start = 0, cur = keyOf(0);
for (let c = 1; c <= MAX; c++) {
  const k = c === MAX ? -1 : keyOf(c);
  if (k === cur) continue;
  if (cur !== DEFAULT) ranges.push([start, c - 1, cur]);
  start = c; cur = k;
}

const h = (v, w) => v.toString(16).toUpperCase().padStart(w, "0");
const body = ranges.map(([s, e, k]) =>
  h(s, 6) + h(e, 6) + h(Math.floor(k / 16), 2) + h(k % 16, 1)).join("");

const perClass = new Map();
for (let c = 0; c < MAX; c++) {
  const k = resolve(c);
  perClass.set(k, (perClass.get(k) || 0) + 1);
}

const L = [];
L.push("// contrib/unicode/lb_table.mere — GENERATED. Do not edit.");
L.push("//");
L.push("// Written by scripts/gen_linebreak_table.sh from the UCD. Run it to regenerate.");
L.push("//");
L.push("// Unicode " + process.env.UNICODE_VERSION + ", pinned to node's, because the harness");
L.push("// compares against the UCD test file of the same version.");
L.push("//");
L.push("// Four properties per code point, because several UAX #14 rules are written in");
L.push("// terms of things other than Line_Break:");
L.push("//   Line_Break            LineBreak.txt");
L.push("//   East_Asian_Width      EastAsianWidth.txt         (LB19a, LB30)");
L.push("//   General_Category      DerivedGeneralCategory.txt (LB15a/b, LB30b, LB1)");
L.push("//   Extended_Pictographic emoji-data.txt             (LB30b)");
L.push("//");
L.push("// LB1's resolution is applied HERE, not at run time: AI/SG/XX become AL, CJ");
L.push("// becomes NS, and SA becomes CM when its general category is Mn or Mc and AL");
L.push("// otherwise. Those are the choices the UCD's own LineBreakTest.txt assumes. CB is");
L.push("// deliberately left alone, because LB20 is written in terms of it. Resolving in");
L.push("// the generator lets the rules read the way the standard writes them.");
L.push("//");
L.push("// " + ranges.length + " ranges, fifteen characters each: six start, six end, two class,");
L.push("// one flags. AL with no flags is the unstored default. Binary searched over a");
L.push("// fixed-width hexadecimal literal — NUL-free, because a str is strlen-based on");
L.push("// the LLVM backend.");
L.push("//");
L.push("// Code points per resolved class:");
for (const n of CLASSES) if (perClass.get(n)) L.push("//   " + n.padEnd(4) + perClass.get(n));
L.push("");
L.push("module LbTable {");
L.push("");
L.push("  // `k_` prefixed because `in` is a Mere keyword and a bare `is` or `as`");
L.push("  // beside it would read as if it were one too.");
for (let i = 0; i < CLASSES.length; i++)
  L.push("  let k_" + CLASSES[i].toLowerCase() + " = " + i + ";");
L.push("");
L.push("  // Flag bits, as returned by `flags_of`.");
L.push("  let flag_eastasian = 1;");
L.push("  let flag_pi = 2;");
L.push("  let flag_pf = 4;");
L.push("  let flag_unassigned_pict = 8;");
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
L.push("  let _start_at = fn (k: int) -> _read (k * 15) 6 0;");
L.push("  let _end_at = fn (k: int) -> _read (k * 15 + 6) 6 0;");
L.push("  let _key_at = fn (k: int) -> _read (k * 15 + 12) 3 0;");
L.push("");
L.push("  let rec _find = fn (cp: int) -> fn (lo: int) -> fn (hi: int) ->");
L.push("    if lo > hi then _default");
L.push("    else");
L.push("      let mid = (lo + hi) / 2 in");
L.push("      if cp < _start_at mid then _find cp lo (mid - 1)");
L.push("      else if cp > _end_at mid then _find cp (mid + 1) hi");
L.push("      else _key_at mid;");
L.push("");
L.push("  // One search answers both questions; callers that want both should keep the");
L.push("  // key rather than searching twice.");
L.push("  let key_of = fn (cp: int) -> _find cp 0 (count - 1);");
L.push("  let class_of_key = fn (k: int) -> k / 16;");
L.push("  let flags_of_key = fn (k: int) -> k % 16;");
L.push("");
L.push("  let class_of = fn (cp: int) -> class_of_key (key_of cp);");
L.push("  let flags_of = fn (cp: int) -> flags_of_key (key_of cp);");
L.push("");
L.push("}");
L.push("");

process.stdout.write(L.join("\n"));
process.stderr.write(ranges.length + " ranges, " + body.length + " characters, " +
  new Set(ranges.map((r) => Math.floor(r[2] / 16))).size + " classes present\n");
NODE

LB="$TMP/lb.txt" EAW="$TMP/eaw.txt" GC="$TMP/gc.txt" EMOJI="$TMP/emoji.txt" \
  UNICODE_VERSION="$UNICODE_VERSION" node --stack-size=4000 "$TMP/gen.js" > "$TMP/lb_table.mere"

mkdir -p "$ROOT/contrib/unicode"

if [ "$1" = "--check" ]; then
  [ -f "$OUT" ] || { echo "gen_linebreak_table: $OUT does not exist" >&2; exit 1; }
  if diff -q "$OUT" "$TMP/lb_table.mere" >/dev/null; then
    echo "gen_linebreak_table: ok  (the checked-in table is what the UCD says)"
    exit 0
  fi
  echo "gen_linebreak_table: FAILED — the derived table differs from the checked-in file" >&2
  diff "$OUT" "$TMP/lb_table.mere" | head -5 | cut -c1-120 >&2
  exit 1
fi

cp "$TMP/lb_table.mere" "$OUT"
echo "gen_linebreak_table: wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
