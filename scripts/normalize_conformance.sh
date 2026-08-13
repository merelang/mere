#!/bin/sh
# scripts/normalize_conformance.sh — run contrib/unicode/normalize.mere against the
# UCD's own normalization conformance suite.
#
# Normalization is the one algorithm in this repository with BOTH kinds of gate
# pointed at it, and they answer different questions:
#
#   * scripts/unicode_parity.sh compares against node's String.prototype.normalize
#     — an independent implementation, which is the only thing that can catch a
#     misreading of the prose shared with a test file derived from it.
#   * this one runs the UCD's 20,034 cases, which is exhaustive in ways no
#     independent implementation is sampled for: canonical order permutations, PRI
#     #29's chained composites, and the closure of every composite in the standard.
#
# Each line is `source; NFC; NFD;` and the standard's conformance requirement is
# six assertions per line rather than two — NFC and NFD must each be idempotent
# across all three columns:
#
#   NFC(c1) == NFC(c2) == NFC(c3) == c2
#   NFD(c1) == NFD(c2) == NFD(c3) == c3
#
# Checking only `NFC(c1) == c2` would pass an implementation that is wrong about
# already-normalized input, which is the common case in real text.
#
# The file is vendored (scripts/gen_ucd_testdata.sh) so this runs offline and its
# version cannot drift from the tables'.
#
# Usage:
#   sh scripts/normalize_conformance.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"
DATA="$ROOT/test/data/NormalizationTest.txt"

[ -x "$MERE" ] || { echo "normalize_conformance: $MERE not found — run 'dune build'" >&2; exit 1; }
[ -f "$DATA" ] || {
  echo "normalize_conformance: $DATA missing — run scripts/gen_ucd_testdata.sh" >&2
  exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Three columns out, one line each, so the Mere side reads a flat file and the
# expected answers are a plain diff away.
awk -F';' '/^[0-9A-Fa-f]/ { print $1 ";" $2 ";" $3 }' "$DATA" > "$TMP/corpus.txt"
awk -F';' '{ print $2 "|" $3 }' "$TMP/corpus.txt" \
  | sed 's/^ *//; s/ *|/|/; s/| */|/' > "$TMP/want.txt"

cases=$(wc -l < "$TMP/corpus.txt" | tr -d ' ')

cat > "$ROOT/examples/.nf_conf_tmp.mere" <<'MERE'
import "../contrib/unicode/normalize.mere";

let _hv = fn (b: int) ->
  if b >= 48 && b <= 57 then b - 48
  else if b >= 65 && b <= 70 then b - 55
  else b - 87;

let rec _hex = fn (s: str) -> fn (i: int) -> fn (n: int) -> fn (acc: int) ->
  if i >= n then acc else _hex s (i + 1) n (acc * 16 + _hv (ord (char_at s i)));

let _build = fn (field: str) ->
  list_fold (list_map (str_split (str_trim field) " ")
                      (fn (h: str) -> if str_len h == 0 then ""
                                      else str_of_codepoint (_hex h 0 (str_len h) 0)))
            "" (fn (a: str) -> fn (b: str) -> a ++ b);

let _hexs = fn (s: str) ->
  let rec go = fn (i: int) -> fn (acc: str) ->
    if i >= utf8_len s then acc
    else go (i + 1) (acc ++ (if acc == "" then "" else " ") ++ show (codepoint_at s i)) in
  go 0 "";

let _nth = fn (fields: str list) -> fn (n: int) ->
  let rec go = fn (fs: str list) -> fn (i: int) ->
    match fs with
    | Nil -> ""
    | Cons (h, t) -> if i == n then h else go t (i + 1) in
  go fields 0;

// Six assertions per line: NFC and NFD must each agree across all three columns.
// Printed as `nfc|nfd` when they do, and as the disagreement when they do not, so
// the diff names which of the six failed.
let _check = fn (line: str) ->
  let fs = str_split line ";" in
  let c1 = _build (_nth fs 0) in
  let c2 = _build (_nth fs 1) in
  let c3 = _build (_nth fs 2) in
  let nfc1 = Normalize.nfc c1 in
  let nfc2 = Normalize.nfc c2 in
  let nfc3 = Normalize.nfc c3 in
  let nfd1 = Normalize.nfd c1 in
  let nfd2 = Normalize.nfd c2 in
  let nfd3 = Normalize.nfd c3 in
  let nfc_ok = nfc1 == c2 && nfc2 == c2 && nfc3 == c2 in
  let nfd_ok = nfd1 == c3 && nfd2 == c3 && nfd3 == c3 in
  if nfc_ok && nfd_ok then _hexs c2 ++ "|" ++ _hexs c3
  else
    (if nfc_ok then _hexs c2 else "NFC(" ++ _hexs nfc1 ++ "," ++ _hexs nfc2
                                  ++ "," ++ _hexs nfc3 ++ ")")
    ++ "|"
    ++ (if nfd_ok then _hexs c3 else "NFD(" ++ _hexs nfd1 ++ "," ++ _hexs nfd2
                                     ++ "," ++ _hexs nfd3 ++ ")");

let rec _go = fn (lines: str list) ->
  match lines with
  | Nil -> 0
  | Cons (line, rest) ->
    let _ = if str_len line == 0 then () else print (_check line) in
    _go rest;

let _ = _go (read_lines "CORPUS_PATH");
0
MERE
sed -i.bak "s|CORPUS_PATH|$TMP/corpus.txt|" "$ROOT/examples/.nf_conf_tmp.mere"
rm -f "$ROOT/examples/.nf_conf_tmp.mere.bak"
( ulimit -t 1800; "$MERE" "$ROOT/examples/.nf_conf_tmp.mere" ) | sed '$d' > "$TMP/ours_raw.txt"
rm -f "$ROOT/examples/.nf_conf_tmp.mere"

# The expected side is the file's own columns 2 and 3 as decimal code points, which
# is what the Mere side prints, so normalise the hex to decimal here rather than
# printing hex there.
WANT="$TMP/want.txt" OUT="$TMP/want_dec.txt" node -e '
  const fs = require("fs");
  const out = [];
  for (const line of fs.readFileSync(process.env.WANT, "utf8").split("\n")) {
    if (!line) continue;
    const [c2, c3] = line.split("|");
    const dec = (f) => f.trim().split(/\s+/).filter(Boolean)
      .map((h) => parseInt(h, 16)).join(" ");
    out.push(dec(c2) + "|" + dec(c3));
  }
  fs.writeFileSync(process.env.OUT, out.join("\n") + "\n");
'

if diff -q "$TMP/want_dec.txt" "$TMP/ours_raw.txt" >/dev/null; then
  version=$(sed -n '1s/^# //p' "$DATA")
  echo "  ok    normalization  ($cases cases x 6 assertions, all agreeing — $version)"
  echo "normalize_conformance: ok"
  exit 0
fi

echo "  FAIL  normalization" >&2
paste -d'\t' "$TMP/corpus.txt" "$TMP/want_dec.txt" "$TMP/ours_raw.txt" \
  | awk -F'\t' '$2 != $3 { n++; if (n <= 10) printf "        %-40s\n          want=%s\n          ours=%s\n", substr($1, 1, 40), $2, $3 }
                END { printf "        %d of '"$cases"' cases differ\n", n }' >&2
echo "normalize_conformance: FAILED" >&2
exit 1
