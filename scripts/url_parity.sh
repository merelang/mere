#!/bin/sh
# scripts/url_parity.sh — check contrib/url/percent.mere against somebody else's
# URL implementation.
#
# Why this exists: a percent-encode set is a list of bytes, and a list of bytes
# read off prose is a list of bytes somebody transcribed. The only way to know
# the set is right is to ask an implementation that was written from the same
# specification by someone else. Node's URL is that implementation, and node is
# already a dependency here (scripts/run_wasm.js).
#
# It works by derivation rather than by fixtures: for every byte in 0x20..0x7E,
# put that byte alone into a component of an http URL, read the serialisation
# back, and record whether it came out as %XX. That yields node's set for the
# component, which is then diffed against ours. A fixture file would only tell
# us about the bytes somebody thought to write down.
#
# Some bytes cannot be probed this way and are excluded, with the reason:
#   * a byte that delimits the component under test ends it instead of being
#     escaped in it (`#` and `?` in a path, `#` in a query)
#   * leading and trailing spaces are stripped by URL parsing before any
#     escaping happens, so a lone space says nothing
#   * `.` in a path is resolved away, and `\` is normalised to `/` for the
#     special schemes
# For those, our set is what it is and this harness has nothing to say. They are
# printed as SKIP so the gap is visible rather than implied.
#
# Skips (exit 0) when node is absent, so it stays out of the dependency set.
#
# Usage:
#   sh scripts/url_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

command -v node >/dev/null 2>&1 || { echo "url_parity: node absent, skipping"; exit 0; }
[ -x "$MERE" ] || { echo "url_parity: $MERE not found — run 'dune build'" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- node's answer ----------------------------------------------------------
node > "$TMP/node.txt" <<'NODE'
const build = {
  path:     [c => "http://h/" + c,  u => u.pathname.slice(1),
             [0x20, 0x23, 0x2e, 0x3f, 0x5c]],
  query:    [c => "http://h/?" + c, u => u.search.slice(1),
             [0x20, 0x23]],
  fragment: [c => "http://h/#" + c, u => u.hash.slice(1),
             [0x20]],
  userinfo: [c => "http://" + c + "@h/", u => u.username,
             [0x23, 0x2f, 0x3a, 0x3f, 0x5c]],
};
for (const [name, [mk, read, skip]] of Object.entries(build)) {
  const on = [];
  for (let b = 0x20; b <= 0x7e; b++) {
    if (skip.includes(b)) continue;
    const ch = String.fromCharCode(b);
    let out;
    try { out = read(new URL(mk(ch))); } catch (e) { continue; }
    const pct = "%" + b.toString(16).padStart(2, "0").toUpperCase();
    if (out.toUpperCase() === pct) on.push(b);
  }
  console.log(name + " " + on.join(" "));
  console.log(name + "-skip " + skip.join(" "));
}
NODE

# --- our answer -------------------------------------------------------------
cat > "$TMP/ours.mere" <<'MERE'
import "../contrib/url/percent.mere";

// The special_query set is the one an http URL uses, so that is what a
// serialised `?` component is compared against.
let rec dump = fn (label: str) -> fn (should: int -> bool) -> fn buf ->
                fn (b: int) ->
  if b > 0x7E then strbuf_to_str buf
  else
    let _ = if should b then
              let _ = strbuf_push buf (show b) in strbuf_push buf " "
            else () in
    dump label should buf (b + 1);

let line = fn (label: str) -> fn (should: int -> bool) ->
  print (label ++ " " ++ dump label should (strbuf_new ()) 0x20);

let _ = line "path" Percent.path;
let _ = line "query" Percent.special_query;
let _ = line "fragment" Percent.fragment;
let _ = line "userinfo" Percent.userinfo;
0
MERE
cp "$TMP/ours.mere" "$ROOT/examples/.url_parity_tmp.mere"
( ulimit -t 60; "$MERE" "$ROOT/examples/.url_parity_tmp.mere" ) > "$TMP/ours.txt"
rm -f "$ROOT/examples/.url_parity_tmp.mere"

# --- diff, per component, excluding the unprobeable bytes -------------------
fail=0
for name in path query fragment userinfo; do
  skip=$(grep "^$name-skip " "$TMP/node.txt" | cut -d' ' -f2-)
  theirs=$(grep "^$name " "$TMP/node.txt" | cut -d' ' -f2-)
  ours=$(grep "^$name " "$TMP/ours.txt" | cut -d' ' -f2- | tr -s ' ')

  # Drop the excluded bytes from our set before comparing.
  filtered=""
  for b in $ours; do
    excluded=0
    for s in $skip; do [ "$b" = "$s" ] && excluded=1; done
    [ "$excluded" = 0 ] && filtered="$filtered $b"
  done

  a=$(echo $theirs | tr ' ' '\n' | sort -n | tr '\n' ' ')
  b=$(echo $filtered | tr ' ' '\n' | sort -n | tr '\n' ' ')
  if [ "$a" = "$b" ]; then
    echo "  ok    $name  ($(echo $b | wc -w | tr -d ' ') bytes agree, $(echo $skip | wc -w | tr -d ' ') unprobeable)"
  else
    echo "  FAIL  $name"
    echo "        node: $a"
    echo "        ours: $b"
    fail=1
  fi
  [ -n "$skip" ] && echo "        SKIP  $(for s in $skip; do printf '0x%02x ' "$s"; done)"
done

# --- decode: round-trip every printable byte through node -------------------
cat > "$TMP/dec.mere" <<'MERE'
import "../contrib/url/percent.mere";
let rec go = fn buf -> fn (b: int) ->
  if b > 0x7E then strbuf_to_str buf
  else
    let _ = strbuf_push buf (Percent.decode (Percent.encode Percent.component (chr b))) in
    go buf (b + 1);
let _ = print (go (strbuf_new ()) 0x20);
let _ = print (Percent.decode "%E3%81%82 %e3%81%82 100% %A %ZZ");
0
MERE
cp "$TMP/dec.mere" "$ROOT/examples/.url_dec_tmp.mere"
( ulimit -t 60; "$MERE" "$ROOT/examples/.url_dec_tmp.mere" ) > "$TMP/dec.txt"
rm -f "$ROOT/examples/.url_dec_tmp.mere"

node > "$TMP/dec_want.txt" <<'NODE'
let s = "";
for (let b = 0x20; b <= 0x7e; b++) s += String.fromCharCode(b);
console.log(s);
console.log("あ あ 100% %A %ZZ");
// A Mere program prints the value of its final expression, so the `0` at the
// end of the probe is part of its output and part of what we expect.
console.log(0);
NODE

if diff -q "$TMP/dec_want.txt" "$TMP/dec.txt" >/dev/null; then
  echo "  ok    decode  (every printable byte round-trips; malformed escapes pass through)"
else
  echo "  FAIL  decode"
  diff "$TMP/dec_want.txt" "$TMP/dec.txt" | head -6
  fail=1
fi

[ "$fail" = 0 ] && echo "url_parity: ok" || echo "url_parity: FAILED"
[ "$fail" = 0 ]
