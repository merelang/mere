#!/bin/sh
# scripts/gen_jis_index.sh — generate contrib/encoding/jis_index.mere.
#
# Shift_JIS and EUC-JP need two lookup tables — JIS X 0208 and JIS X 0212 — of
# 8,836 slots each. That is the first table in this project too large to write by
# hand, so it is not written by hand: this script derives both from the Encoding
# Standard's own published index files.
#
# **Why not node, which is the oracle everywhere else in contrib/encoding.**
# Because for these two encodings node is not the Standard. Its `shift_jis` is
# ICU's CP932, and the two differ in ways that were measured rather than guessed:
#
#   * `index jis0208` is IDENTICAL — all 8,836 slots agree, so the two-byte core
#     of Shift_JIS is not in question.
#   * `index jis0212` differs in 21 slots that ICU maps and the Standard does
#     not, starting at pointer 7708 (U+2170, the small Roman numerals). Those are
#     NEC/IBM extensions.
#   * Four single bytes are remapped by ICU: 0x1A→U+001C, 0x1C→U+007F,
#     0x7F→U+001A — a three-cycle out of CP932's history — and 0x80 is an error
#     rather than U+0080.
#
# A browser implements the Standard, so the Standard is what this follows, and
# the difference is recorded in scripts/encoding_parity.sh where the sweep has to
# account for it. Accepting 21 code points the Standard does not is the same
# failure mode contrib/url guards against: agreeing with an implementation
# instead of the specification, in the permissive direction.
#
# The index files carry their own `Identifier:` hash, which is pinned below —
# a data file that states its version is exactly what the oracle-version lesson
# asks for, so an upstream edit fails here rather than changing the tables
# silently.
#
# Two decisions visible in the output.
#
# **Fixed-width hexadecimal, four characters per slot.** Not for compactness —
# raw 16-bit values would be half the size — but because a `str` on the LLVM
# backend is strlen-based and a raw table is full of 0x00 bytes (U+00A2 is
# `00 A2`). The encoding of this table is decided by that backend's string
# representation. Hex is NUL-free by construction, and a slot is four O(1)
# `char_at` reads with no startup pass.
#
# **A hole is `0000`.** U+0000 is not a mapping either table produces, so the
# sentinel needs no separate presence bitmap.
#
# Measured before choosing this shape: a 35,344-character literal compiles and
# runs identically on interp, C, LLVM and Wasm, and `mere -rv` emits a
# 37,633-byte RV32I image from it — so the question of what a large literal does
# to a backend's rodata is answered rather than assumed. (RV32I was verified at
# emit; running it needs an emulator that lives in another repository.)
#
# Needs network, and says so: this is a maintenance command, not a gate.
#
# Usage:
#   sh scripts/gen_jis_index.sh          # write the file
#   sh scripts/gen_jis_index.sh --check  # fail if it would change

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/contrib/encoding/jis_index.mere"

# From the `Identifier:` line of each file, as fetched on 2026-08-13 (both dated
# 2024-09-18 upstream).
ID_0208=cbaa91f3deb7d0841faf5c33041fc15a285da0e87e64ab802c4bf04b7c4da861
ID_0212=83bf90dd1c591a4355730d8c4567efc499d74da7490531019ef22a879991cfb7

command -v node >/dev/null 2>&1 || { echo "gen_jis_index: node absent" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "gen_jis_index: curl absent" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for t in jis0208 jis0212; do
  curl -sSfL "https://encoding.spec.whatwg.org/index-$t.txt" -o "$TMP/$t.txt" || {
    echo "gen_jis_index: could not fetch index-$t.txt (this command needs network)" >&2
    exit 1
  }
done

check_id() {
  file=$1; want=$2; name=$3
  got=$(sed -n 's/^# Identifier: //p' "$file" | head -1)
  [ "$got" = "$want" ] && return 0
  echo "gen_jis_index: index-$name.txt changed upstream" >&2
  echo "  pinned: $want" >&2
  echo "  fetched: $got" >&2
  echo "  Review the diff, then update the pin in this script." >&2
  exit 1
}
check_id "$TMP/jis0208.txt" "$ID_0208" jis0208
check_id "$TMP/jis0212.txt" "$ID_0212" jis0212

cat > "$TMP/gen.js" <<'NODE'
const fs = require("fs");

// "<pointer>\t0x<hex>\t<char> (NAME)", pointer left-padded with spaces.
const load = (path, size) => {
  const a = new Array(size).fill(0);
  let n = 0, max = 0;
  for (const line of fs.readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*(\d+)\s+0x([0-9A-Fa-f]+)/);
    if (!m) continue;
    const p = +m[1], cp = parseInt(m[2], 16);
    if (p >= size) continue;   // jis0208's file runs past the decoder's range
    if (a[p] !== 0) throw new Error(path + ": pointer " + p + " listed twice");
    a[p] = cp; n++;
    if (cp > max) max = cp;
  }
  if (n === 0) throw new Error(path + ": no entries parsed — has the format changed?");
  if (max > 0xffff) throw new Error(path + ": a slot is above U+FFFF (0x" + max.toString(16) + ")");
  return { a, n, max };
};

const t208 = load(process.argv[2], 8836);
const t212 = load(process.argv[3], 8836);
const hex = (t) => t.map((x) => x.toString(16).toUpperCase().padStart(4, "0")).join("");

const L = [];
L.push("// contrib/encoding/jis_index.mere — GENERATED. Do not edit.");
L.push("//");
L.push("// Written by scripts/gen_jis_index.sh from the Encoding Standard's own");
L.push("// published index files, whose Identifier hashes are pinned in that");
L.push("// script. Run it to regenerate.");
L.push("//");
L.push("// Deliberately NOT derived from node, which is the oracle elsewhere in");
L.push("// contrib/encoding: node's shift_jis is ICU's CP932, and while its");
L.push("// jis0208 is identical to the Standard's in all 8,836 slots, its jis0212");
L.push("// maps 21 pointers the Standard does not. A browser implements the");
L.push("// Standard. scripts/encoding_parity.sh records the difference.");
L.push("//");
L.push("// index-jis0208.txt  " + process.env.ID_0208);
L.push("// index-jis0212.txt  " + process.env.ID_0212);
L.push("//");
L.push("// jis0208: 8836 slots, " + t208.n + " mapped, max U+" +
       t208.max.toString(16).toUpperCase());
L.push("// jis0212: 8836 slots, " + t212.n + " mapped, max U+" +
       t212.max.toString(16).toUpperCase());
L.push("//");
L.push("// Four hexadecimal characters per slot, and `0000` for a hole. Fixed width");
L.push("// so a slot is four O(1) char_at reads with no startup pass, and hex rather");
L.push("// than raw 16-bit values because a str is strlen-based on the LLVM backend");
L.push("// and a raw table is full of 0x00 bytes. U+0000 is not a mapping either");
L.push("// table produces, so the hole sentinel needs no separate presence bitmap.");
L.push("");
L.push("module JisIndex {");
L.push("");
L.push("  let _hexval = fn (b: int) -> if b >= 48 && b <= 57 then b - 48 else b - 55;");
L.push("");
L.push("  // -1 for a pointer outside the table or for a hole, which the callers");
L.push("  // treat identically: both mean \"this pair is not a character\".");
L.push("  let _lookup = fn (t: str) -> fn (n: int) -> fn (p: int) ->");
L.push("    if p < 0 || p >= n then 0 - 1");
L.push("    else");
L.push("      let i = p * 4 in");
L.push("      let v = _hexval (ord (char_at t i)) * 4096");
L.push("              + _hexval (ord (char_at t (i + 1))) * 256");
L.push("              + _hexval (ord (char_at t (i + 2))) * 16");
L.push("              + _hexval (ord (char_at t (i + 3))) in");
L.push("      if v == 0 then 0 - 1 else v;");
L.push("");
L.push("  let jis0208_len = 8836;");
L.push("  let jis0212_len = 8836;");
L.push("");
L.push("  let _jis0208 = \"" + hex(t208.a) + "\";");
L.push("");
L.push("  let _jis0212 = \"" + hex(t212.a) + "\";");
L.push("");
L.push("  let code_point_208 = fn (p: int) -> _lookup _jis0208 jis0208_len p;");
L.push("  let code_point_212 = fn (p: int) -> _lookup _jis0212 jis0212_len p;");
L.push("");
L.push("}");
L.push("");

process.stdout.write(L.join("\n"));
process.stderr.write("jis0208: " + t208.n + "/8836 mapped, max U+" +
  t208.max.toString(16).toUpperCase() + "\njis0212: " + t212.n + "/8836 mapped, max U+" +
  t212.max.toString(16).toUpperCase() + "\n");
NODE

ID_0208="$ID_0208" ID_0212="$ID_0212" \
  node "$TMP/gen.js" "$TMP/jis0208.txt" "$TMP/jis0212.txt" > "$TMP/jis_index.mere"

if [ "$1" = "--check" ]; then
  [ -f "$OUT" ] || { echo "gen_jis_index: $OUT does not exist" >&2; exit 1; }
  if diff -q "$OUT" "$TMP/jis_index.mere" >/dev/null; then
    echo "gen_jis_index: ok  (the checked-in tables are what the Standard's indexes say)"
    exit 0
  fi
  echo "gen_jis_index: FAILED — the derived tables differ from the checked-in file" >&2
  diff "$OUT" "$TMP/jis_index.mere" | head -5 | cut -c1-120 >&2
  echo "Run 'sh scripts/gen_jis_index.sh' if the change is intended." >&2
  exit 1
fi

cp "$TMP/jis_index.mere" "$OUT"
echo "gen_jis_index: wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
