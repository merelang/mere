#!/bin/sh
# scripts/encoding_parity.sh — check contrib/encoding against somebody else's
# implementation of the same specification.
#
# Why this exists: a decoder's interesting behaviour is all in its error cases,
# and the Encoding Standard specifies those exactly — including HOW MANY U+FFFD a
# malformed sequence produces, which is not one per byte. `F1 80 80 41` is one
# replacement then `A`, because the three bytes were a valid prefix and are one
# error together; `E0 80 80` is three, because 0x80 is out of range for a
# sequence starting `E0`, so each remaining byte is reconsidered and fails on its
# own. An implementation can be wrong about this and still decode every valid
# page correctly, which is exactly the kind of bug a fixture file does not find.
#
# node's TextDecoder is that other implementation, and node is already a
# dependency here (scripts/run_wasm.js).
#
# It sweeps rather than asserts:
#
#   * every single byte                          256
#   * every two-byte sequence                    65536
#   * every three-byte lead x first continuation 4096   (E0..EF c 80)
#   * every four-byte lead x first continuation  1280   (F0..F4 c 80 80)
#   * every byte through windows-1252            256
#
# The two- byte sweep is exhaustive. The three- and four-byte sweeps are
# exhaustive in the dimension that carries the logic — the first continuation,
# where the narrowed range lives (E0 wants A0..BF, ED wants 80..9F, F0 wants
# 90..BF, F4 wants 80..8F) — with the remaining bytes held at a valid value.
#
# Labels are the one part that is checked rather than derived, and the gap is
# stated where it is printed: the harness confirms every label we claim maps
# where we say it does, and it cannot discover a label we forgot to list.
#
# Skips (exit 0) when node is absent, so it stays out of the dependency set.
#
# Usage:
#   sh scripts/encoding_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

command -v node >/dev/null 2>&1 || { echo "encoding_parity: node absent, skipping"; exit 0; }
[ -x "$MERE" ] || { echo "encoding_parity: $MERE not found — run 'dune build'" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

# --- the sweeps, both sides looping over the byte ---------------------------
# Neither side builds these inputs as string literals: there is no corpus file
# and so no escaping layer to get wrong. Code points are printed in decimal
# because that needs no formatting helper on either side.

cat > "$TMP/sweep.js" <<'NODE'
const u8 = new TextDecoder("utf-8");
const cp = new TextDecoder("windows-1252");
const out = [];
const emit = (dec, bytes) => {
  const s = dec.decode(new Uint8Array(bytes));
  out.push([...s].map((c) => c.codePointAt(0)).join(" "));
};
for (let a = 0; a < 256; a++) emit(u8, [a]);
for (let a = 0; a < 256; a++) for (let b = 0; b < 256; b++) emit(u8, [a, b]);
for (let a = 0xe0; a <= 0xef; a++) for (let c = 0; c < 256; c++) emit(u8, [a, c, 0x80]);
for (let a = 0xf0; a <= 0xf4; a++) for (let c = 0; c < 256; c++) emit(u8, [a, c, 0x80, 0x80]);
for (let a = 0; a < 256; a++) emit(cp, [a]);
process.stdout.write(out.join("\n") + "\n");
NODE
node "$TMP/sweep.js" > "$TMP/want.txt"

cat > "$ROOT/examples/.enc_sweep_tmp.mere" <<'MERE'
import "../contrib/encoding/decode.mere";

// Two hex digits per byte, so nothing goes through a `str` that could hold a
// NUL — a str is strlen-based on the LLVM backend and byte 0x00 is in the sweep.
let _hexd = fn (x: int) -> if x < 10 then chr (48 + x) else chr (87 + x);
let hx = fn (v: int) -> _hexd (v / 16) ++ _hexd (v % 16);

// codepoint_at takes a codepoint index, not a byte offset.
let cps = fn (s: str) ->
  let rec go = fn (i: int) -> fn (acc: str) ->
    if i >= utf8_len s then acc
    else go (i + 1) (acc ++ (if acc == "" then "" else " ")
                     ++ show (codepoint_at s i)) in
  go 0 "";

let u8 = fn (hex: str) -> print (cps (Encoding.decode_utf8 (bytes_of_hex hex)));
let cp = fn (hex: str) ->
  print (cps (Encoding.decode_windows_1252 (bytes_of_hex hex)));

let rec one = fn (a: int) ->
  if a > 255 then 0 else let _ = u8 (hx a) in one (a + 1);

let rec two_inner = fn (a: int) -> fn (b: int) ->
  if b > 255 then 0 else let _ = u8 (hx a ++ hx b) in two_inner a (b + 1);
let rec two = fn (a: int) ->
  if a > 255 then 0 else let _ = two_inner a 0 in two (a + 1);

let rec three_inner = fn (a: int) -> fn (c: int) ->
  if c > 255 then 0
  else let _ = u8 (hx a ++ hx c ++ "80") in three_inner a (c + 1);
let rec three = fn (a: int) ->
  if a > 0xEF then 0 else let _ = three_inner a 0 in three (a + 1);

let rec four_inner = fn (a: int) -> fn (c: int) ->
  if c > 255 then 0
  else let _ = u8 (hx a ++ hx c ++ "8080") in four_inner a (c + 1);
let rec four = fn (a: int) ->
  if a > 0xF4 then 0 else let _ = four_inner a 0 in four (a + 1);

let rec sb = fn (a: int) ->
  if a > 255 then 0 else let _ = cp (hx a) in sb (a + 1);

let _ = one 0;
let _ = two 0;
let _ = three 0xE0;
let _ = four 0xF0;
let _ = sb 0;
0
MERE
( ulimit -t 300; "$MERE" "$ROOT/examples/.enc_sweep_tmp.mere" ) | sed '$d' > "$TMP/ours.txt"
rm -f "$ROOT/examples/.enc_sweep_tmp.mere"

# One diff, but reported per section so a failure names which sweep broke.
report() {
  name=$1; from=$2; count=$3
  to=$((from + count - 1))
  sed -n "${from},${to}p" "$TMP/want.txt" > "$TMP/sec_want"
  sed -n "${from},${to}p" "$TMP/ours.txt" > "$TMP/sec_ours"
  if diff -q "$TMP/sec_want" "$TMP/sec_ours" >/dev/null; then
    echo "  ok    $name  ($count sequences agree)"
  else
    echo "  FAIL  $name"
    # The line number within the section is the input, so it names the bytes.
    diff "$TMP/sec_want" "$TMP/sec_ours" | head -8 | sed 's/^/        /'
    fail=1
  fi
}

if [ "$(wc -l < "$TMP/want.txt")" != "$(wc -l < "$TMP/ours.txt")" ]; then
  echo "  FAIL  sweep produced $(wc -l < "$TMP/ours.txt") lines, expected $(wc -l < "$TMP/want.txt")"
  fail=1
else
  report "utf8 1-byte"     1     256
  report "utf8 2-byte"     257   65536
  report "utf8 3-byte lead" 65793 4096
  report "utf8 4-byte lead" 69889 1280
  report "windows-1252"    71169 256
fi

# --- labels ----------------------------------------------------------------
# Checked, not derived. Every label claimed below is confirmed against node;
# a label we failed to list cannot be found this way, and that is the gap.

cat > "$TMP/labels.txt" <<'LABELS'
utf-8 utf-8
utf8 utf-8
UTF-8 utf-8
  utf-8   utf-8
unicode-1-1-utf-8 utf-8
unicode11utf8 utf-8
unicode20utf8 utf-8
x-unicode20utf8 utf-8
windows-1252 windows-1252
cp1252 windows-1252
x-cp1252 windows-1252
ascii windows-1252
us-ascii windows-1252
latin1 windows-1252
l1 windows-1252
cp819 windows-1252
ibm819 windows-1252
csisolatin1 windows-1252
iso-8859-1 windows-1252
iso8859-1 windows-1252
iso88591 windows-1252
iso_8859-1 windows-1252
iso_8859-1:1987 windows-1252
iso-ir-100 windows-1252
ansi_x3.4-1968 windows-1252
shift_jis shift_jis
shift-jis shift_jis
SJIS shift_jis
sjis shift_jis
x-sjis shift_jis
ms932 shift_jis
ms_kanji shift_jis
windows-31j shift_jis
csshiftjis shift_jis
euc-jp euc-jp
x-euc-jp euc-jp
cseucpkdfmtjapanese euc-jp
eucjp UNKNOWN
utf-9 UNKNOWN
nonsense-xyz UNKNOWN
LABELS

# node's view: does the label name the encoding we claim, and does it reject the
# ones we claim are not labels?
cat > "$TMP/labels.js" <<'NODE'
const fs = require("fs");
for (const line of fs.readFileSync(process.argv[2], "utf8").split("\n")) {
  if (line === "") continue;
  // The claim is the last space-separated field; the label is everything before
  // it, so a label with leading or trailing spaces survives the round trip.
  const cut = line.lastIndexOf(" ");
  const label = line.slice(0, cut);
  let enc; try { enc = new TextDecoder(label).encoding; } catch (e) { enc = "UNKNOWN"; }
  console.log(enc);
}
NODE
node "$TMP/labels.js" "$TMP/labels.txt" > "$TMP/labels_node.txt"
awk '{ print $NF }' "$TMP/labels.txt" > "$TMP/labels_claim.txt"

if diff -q "$TMP/labels_claim.txt" "$TMP/labels_node.txt" >/dev/null; then
  echo "  ok    labels vs node  ($(grep -c . "$TMP/labels.txt") labels; node agrees with every claim)"
else
  echo "  FAIL  labels vs node"
  paste -d'\t' "$TMP/labels.txt" "$TMP/labels_node.txt" \
    | awk -F'\t' '{ n = split($1, f, " "); if (f[n] != $2) printf "        %-24s claim=%-14s node=%s\n", $1, f[n], $2 }'
  fail=1
fi

# ...and our view of the same table.
{
  echo 'import "../contrib/encoding/decode.mere";'
  echo 'let l = fn (s: str) ->'
  echo '  match Encoding.label_of s with'
  echo '  | None -> print "UNKNOWN"'
  echo '  | Some n -> print n;'
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    label=${line% *}
    esc=$(printf '%s' "$label" | sed 's/\\/\\\\/g; s/"/\\"/g; s/{/\\{/g')
    printf 'let _ = l "%s";\n' "$esc"
  done < "$TMP/labels.txt"
  echo '0'
} > "$ROOT/examples/.enc_labels_tmp.mere"
( ulimit -t 60; "$MERE" "$ROOT/examples/.enc_labels_tmp.mere" ) | sed '$d' > "$TMP/labels_ours.txt"
rm -f "$ROOT/examples/.enc_labels_tmp.mere"

if diff -q "$TMP/labels_claim.txt" "$TMP/labels_ours.txt" >/dev/null; then
  echo "  ok    labels vs ours  (same table, including the ones that must not resolve)"
  echo "        SKIP  a label we forgot to list cannot be discovered this way"
else
  echo "  FAIL  labels vs ours"
  paste -d'\t' "$TMP/labels.txt" "$TMP/labels_ours.txt" \
    | awk -F'\t' '{ n = split($1, f, " "); if (f[n] != $2) printf "        %-24s claim=%-14s ours=%s\n", $1, f[n], $2 }'
  fail=1
fi

[ "$fail" = 0 ] && echo "encoding_parity: ok" || echo "encoding_parity: FAILED"
[ "$fail" = 0 ]
