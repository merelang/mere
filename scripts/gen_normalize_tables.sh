#!/bin/sh
# scripts/gen_normalize_tables.sh — generate contrib/unicode/nfc_table.mere.
#
# Normalization needs three tables, and the third one is derived rather than
# read:
#
#   ccc            UnicodeData.txt field 3, for canonical ordering
#   decomposition  UnicodeData.txt field 5, canonical mappings only
#   composition    the INVERSE of the decompositions, minus the exclusions
#
# **The composition table is where normalization goes wrong**, because a
# decomposition is not automatically a composition. Four kinds of mapping are
# excluded from the inverse, and the generator applies all four and reports the
# count of each so the arithmetic is visible rather than assumed:
#
#   * **singletons** — a one-code-point decomposition never composes back;
#   * **non-starter decompositions** — where the first code point has ccc != 0;
#   * **script-specific exclusions** — the list in CompositionExclusions.txt;
#   * **compatibility decompositions** — the `<...>` tagged ones, which are not
#     canonical at all and must not even be decomposed by NFD.
#
# Hangul is not in any of these tables. Its composition and decomposition are
# arithmetic on the code point, so the implementation does that directly and the
# table stays 11,172 entries smaller.
#
# Canonical decompositions are stored PAIRWISE and applied recursively rather
# than pre-expanded: the longest canonical mapping in the UCD is two code points,
# so a fully expanded table would need variable-length values to buy a recursion
# that is at most a few levels deep.
#
# Shape as settled in gen_jis_index.sh: fixed-width hexadecimal literals, binary
# searched, NUL-free because a str is strlen-based on the LLVM backend.
#
# The Unicode version is pinned to node's, because node's String.prototype.normalize
# is one of the two gates and the UCD's NormalizationTest.txt is the other.
#
# Needs network. Maintenance command, not a gate.
#
# Usage:
#   sh scripts/gen_normalize_tables.sh          # write the file
#   sh scripts/gen_normalize_tables.sh --check  # fail if it would change

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/contrib/unicode/nfc_table.mere"
UNICODE_VERSION=17.0

command -v node >/dev/null 2>&1 || { echo "gen_normalize_tables: node absent" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "gen_normalize_tables: curl absent" >&2; exit 1; }

have=$(node -p 'process.versions.unicode')
if [ "$have" != "$UNICODE_VERSION" ]; then
  echo "gen_normalize_tables: node implements Unicode $have, this script pins $UNICODE_VERSION" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

base="https://www.unicode.org/Public/$UNICODE_VERSION.0/ucd"
for f in UnicodeData.txt CompositionExclusions.txt; do
  curl -sSfL "$base/$f" -o "$TMP/$f" || {
    echo "gen_normalize_tables: could not fetch $f (needs network)" >&2; exit 1; }
done
# UnicodeData.txt carries no version header of its own — it is the file every
# other one is derived from — so CompositionExclusions.txt is what gets checked.
head -3 "$TMP/CompositionExclusions.txt" | grep -q "$UNICODE_VERSION" || {
  echo "gen_normalize_tables: CompositionExclusions.txt is not $UNICODE_VERSION:" >&2
  head -1 "$TMP/CompositionExclusions.txt" >&2; exit 1; }

cat > "$TMP/gen.js" <<'NODE'
const fs = require("fs");

// UnicodeData.txt: cp;name;gc;ccc;bidi;decomposition;...
const ccc = new Map();
const decomp = new Map();       // cp -> [a] or [a, b], canonical only
let compat = 0;
for (const line of fs.readFileSync(process.env.UD, "utf8").split("\n")) {
  const f = line.split(";");
  if (f.length < 6) continue;
  const cp = parseInt(f[0], 16);
  const k = +f[3];
  if (k !== 0) ccc.set(cp, k);
  const d = f[5].trim();
  if (!d) continue;
  if (d.startsWith("<")) { compat++; continue; }   // compatibility, not canonical
  const parts = d.split(/\s+/).map((x) => parseInt(x, 16));
  if (parts.length > 2) throw new Error("U+" + f[0] + " has a canonical mapping of " +
    parts.length + " code points; the pairwise storage assumes at most two");
  decomp.set(cp, parts);
}

const exclusions = new Set();
for (const line of fs.readFileSync(process.env.EXCL, "utf8").split("\n")) {
  const body = line.split("#")[0].trim();
  if (!body) continue;
  const m = body.match(/^([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?/);
  if (!m) continue;
  const s = parseInt(m[1], 16), e = m[2] ? parseInt(m[2], 16) : parseInt(m[1], 16);
  for (let c = s; c <= e; c++) exclusions.add(c);
}

// The inverse, with the four exclusions counted rather than merely applied.
const stats = { singleton: 0, nonStarter: 0, scriptExclusion: 0, kept: 0 };
const comp = [];
for (const [cp, parts] of decomp) {
  if (parts.length === 1) { stats.singleton++; continue; }
  if ((ccc.get(parts[0]) || 0) !== 0) { stats.nonStarter++; continue; }
  if (exclusions.has(cp)) { stats.scriptExclusion++; continue; }
  comp.push([parts[0], parts[1], cp]);
  stats.kept++;
}
comp.sort((a, b) => a[0] - b[0] || a[1] - b[1]);

// ccc as ranges; most of the code space is zero and is not stored.
const cccRanges = [];
{
  const cps = [...ccc.keys()].sort((a, b) => a - b);
  let i = 0;
  while (i < cps.length) {
    let j = i;
    while (j + 1 < cps.length && cps[j + 1] === cps[j] + 1 &&
           ccc.get(cps[j + 1]) === ccc.get(cps[i])) j++;
    cccRanges.push([cps[i], cps[j], ccc.get(cps[i])]);
    i = j + 1;
  }
}

const decompRows = [...decomp.entries()].sort((a, b) => a[0] - b[0])
  .map(([cp, p]) => [cp, p[0], p.length > 1 ? p[1] : 0]);

const h = (v, w) => v.toString(16).toUpperCase().padStart(w, "0");
const cccBody = cccRanges.map(([s, e, k]) => h(s, 6) + h(e, 6) + h(k, 2)).join("");
const decompBody = decompRows.map(([a, b, c]) => h(a, 6) + h(b, 6) + h(c, 6)).join("");
const compBody = comp.map(([a, b, c]) => h(a, 6) + h(b, 6) + h(c, 6)).join("");

const maxCcc = Math.max(...ccc.values());
if (maxCcc > 0xff) throw new Error("a ccc does not fit in two hex digits: " + maxCcc);

const L = [];
L.push("// contrib/unicode/nfc_table.mere — GENERATED. Do not edit.");
L.push("//");
L.push("// Written by scripts/gen_normalize_tables.sh from the UCD. Run it to regenerate.");
L.push("//");
L.push("// Unicode " + process.env.UNICODE_VERSION + ", pinned to node's, because node's");
L.push("// String.prototype.normalize is one of the two gates and the UCD's");
L.push("// NormalizationTest.txt is the other.");
L.push("//");
L.push("// Three tables. The third is DERIVED, and it is where normalization goes");
L.push("// wrong, because a decomposition is not automatically a composition:");
L.push("//");
L.push("//   ccc           " + cccRanges.length + " ranges (" + ccc.size +
       " code points, max " + maxCcc + ")");
L.push("//   decomposition " + decompRows.length + " canonical mappings, stored pairwise");
L.push("//   composition   " + stats.kept + " primary composites");
L.push("//");
L.push("// Excluded from the inverse, counted rather than assumed:");
L.push("//   singletons                  " + stats.singleton);
L.push("//   non-starter decompositions  " + stats.nonStarter);
L.push("//   script-specific exclusions  " + stats.scriptExclusion);
L.push("//   compatibility decompositions " + compat + " (never canonical; NFD ignores them)");
L.push("//");
L.push("// Hangul is in none of these: its composition and decomposition are");
L.push("// arithmetic on the code point, which the implementation does directly and");
L.push("// which keeps 11,172 entries out of the tables.");
L.push("//");
L.push("// Eighteen characters per decomposition or composition row, fourteen per ccc");
L.push("// range. Fixed width, binary searched, NUL-free because a str is");
L.push("// strlen-based on the LLVM backend.");
L.push("");
L.push("module NfcTable {");
L.push("");
L.push("  let ccc_count = " + cccRanges.length + ";");
L.push("  let decomp_count = " + decompRows.length + ";");
L.push("  let comp_count = " + stats.kept + ";");
L.push("");
L.push("  let _ccc = \"" + cccBody + "\";");
L.push("");
L.push("  let _decomp = \"" + decompBody + "\";");
L.push("");
L.push("  let _comp = \"" + compBody + "\";");
L.push("");
L.push("  let _hexval = fn (b: int) -> if b >= 48 && b <= 57 then b - 48 else b - 55;");
L.push("");
L.push("  let rec _read = fn (t: str) -> fn (i: int) -> fn (w: int) -> fn (acc: int) ->");
L.push("    if w <= 0 then acc");
L.push("    else _read t (i + 1) (w - 1) (acc * 16 + _hexval (ord (char_at t i)));");
L.push("");
L.push("  // --- ccc: ranges ------------------------------------------------------");
L.push("");
L.push("  let rec _find_ccc = fn (cp: int) -> fn (lo: int) -> fn (hi: int) ->");
L.push("    if lo > hi then 0");
L.push("    else");
L.push("      let mid = (lo + hi) / 2 in");
L.push("      let s = _read _ccc (mid * 14) 6 0 in");
L.push("      let e = _read _ccc (mid * 14 + 6) 6 0 in");
L.push("      if cp < s then _find_ccc cp lo (mid - 1)");
L.push("      else if cp > e then _find_ccc cp (mid + 1) hi");
L.push("      else _read _ccc (mid * 14 + 12) 2 0;");
L.push("");
L.push("  let ccc_of = fn (cp: int) -> _find_ccc cp 0 (ccc_count - 1);");
L.push("");
L.push("  // --- canonical decomposition: cp -> one or two code points -------------");
L.push("  // `0` in the second slot means the mapping is a singleton.");
L.push("");
L.push("  let rec _find_decomp = fn (cp: int) -> fn (lo: int) -> fn (hi: int) ->");
L.push("    if lo > hi then 0 - 1");
L.push("    else");
L.push("      let mid = (lo + hi) / 2 in");
L.push("      let k = _read _decomp (mid * 18) 6 0 in");
L.push("      if cp < k then _find_decomp cp lo (mid - 1)");
L.push("      else if cp > k then _find_decomp cp (mid + 1) hi");
L.push("      else mid;");
L.push("");
L.push("  // -1 when the code point has no canonical mapping.");
L.push("  let decomp_row = fn (cp: int) -> _find_decomp cp 0 (decomp_count - 1);");
L.push("  let decomp_first = fn (row: int) -> _read _decomp (row * 18 + 6) 6 0;");
L.push("  let decomp_second = fn (row: int) -> _read _decomp (row * 18 + 12) 6 0;");
L.push("");
L.push("  // --- primary composites: (first, second) -> composite -------------------");
L.push("  // Sorted by first then second, so one binary search answers both.");
L.push("");
L.push("  let rec _find_comp = fn (a: int) -> fn (b: int) -> fn (lo: int) ->");
L.push("                       fn (hi: int) ->");
L.push("    if lo > hi then 0 - 1");
L.push("    else");
L.push("      let mid = (lo + hi) / 2 in");
L.push("      let fa = _read _comp (mid * 18) 6 0 in");
L.push("      let fb = _read _comp (mid * 18 + 6) 6 0 in");
L.push("      if a < fa || (a == fa && b < fb) then _find_comp a b lo (mid - 1)");
L.push("      else if a > fa || (a == fa && b > fb) then _find_comp a b (mid + 1) hi");
L.push("      else _read _comp (mid * 18 + 12) 6 0;");
L.push("");
L.push("  // -1 when the pair does not compose.");
L.push("  let compose_pair = fn (a: int) -> fn (b: int) ->");
L.push("    _find_comp a b 0 (comp_count - 1);");
L.push("");
L.push("}");
L.push("");

process.stdout.write(L.join("\n"));
process.stderr.write("ccc " + cccRanges.length + " ranges, decomp " + decompRows.length +
  ", comp " + stats.kept + " (excluded: " + stats.singleton + " singleton, " +
  stats.nonStarter + " non-starter, " + stats.scriptExclusion + " script)\n");
NODE

UD="$TMP/UnicodeData.txt" EXCL="$TMP/CompositionExclusions.txt" \
  UNICODE_VERSION="$UNICODE_VERSION" node "$TMP/gen.js" > "$TMP/nfc_table.mere"

mkdir -p "$ROOT/contrib/unicode"

if [ "$1" = "--check" ]; then
  [ -f "$OUT" ] || { echo "gen_normalize_tables: $OUT does not exist" >&2; exit 1; }
  if diff -q "$OUT" "$TMP/nfc_table.mere" >/dev/null; then
    echo "gen_normalize_tables: ok  (the checked-in tables are what the UCD says)"
    exit 0
  fi
  echo "gen_normalize_tables: FAILED — the derived tables differ from the checked-in file" >&2
  diff "$OUT" "$TMP/nfc_table.mere" | head -5 | cut -c1-120 >&2
  exit 1
fi

cp "$TMP/nfc_table.mere" "$OUT"
echo "gen_normalize_tables: wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
