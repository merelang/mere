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

# --- every field of the parse, against node --------------------------------
#
# One line per input, nine fields, so a mismatch names the field rather than
# just the URL. Inputs node rejects are expected to come back INVALID from us
# too — a parser that accepts more than the oracle is the failure mode that
# matters for anything that then makes a request.
#
# `href` is in there because it is the only field that pins the state the other
# eight cannot show: `http://h/?` has an empty query that still serialises its
# `?`, and `foo://` and `foo:` have the same empty host but only one has an
# authority. A round-trip catches a dropped field or an invented delimiter.

CORPUS="$TMP/corpus.txt"
cat > "$CORPUS" <<'URLS'
http://EXAMPLE.com:80/a
https://a:b@h:443/x
HTTP://h
http://h:8080
http://0x7f.1
http://0177.1
http://127.0.0.1
http://1.2
http://256.1.1.1
http://1.2.3.4.5
http://[::1]:81/
http://[::1
foo://Host:99/p
foo://Host
http://h:/
http://h:99999
http://h:abc
http://user@h/
http://user:pw@h/
http://a@b@h/
mailto:x@y
http://
not a url
http://h/p?q#f
http://h/a/b/..
http://h/a/b/.
http://h/a/./b
http://h/a/%2e%2e/b
http://h/a/%2E/b
http://h/%2E%2E/a
http://h/a/.%2e/b
http://h/..
http://h/../..
http://h//
http://h/a//b
http://h/a/b/../../../c
http://h/.../a
http://h/a/..%2f
http://h/a%2fb
http://h/%41
http://h/a b
http://h/a?b#c
http://h/?
http://h/#
http://h/?a
http://h/?a#
http://h/#f
http://h/?#
http://h/?a=1&b=2#f/g?h
http://h/?a?b
http://h/#a#b
http://h/#a?b
http://h/a?<>
http://h/a#<>`
http://h/a'b?c'd
http://h/a?b%20c
http://h/a#b c
foo://h/a/../b
foo://h/a b
foo://h/?a'b
foo://h
foo://h/
foo://
foo://?q
foo://#f
foo://h?#
foo:
foo:?q
foo:#f
foo:/
foo:/#f
foo:/a/../b
foo:a/../b
mailto:a/../b
mailto:a b
mailto:a"b
mailto:a<b
mailto:a`b
mailto:a{b
mailto:x?q'r#f g
foo:a b?c'd#e f
http:h
http:/h
http:///h
http://h
http://h?q
http://h#f
http://h\a
http://h\a?b
http://u\p@h/
http://h/a\b
http://h/a\b?c\d#e\f
http://h/a\..\b
foo://h/a\b
foo:\\h
URLS

cat > "$TMP/auth.js" <<'NODE'
const fs = require("fs");
for (const line of fs.readFileSync(process.argv[2], "utf8").split("\n")) {
  if (!line) continue;
  let out;
  try {
    const u = new URL(line);
    out = [u.protocol.replace(/:$/, ""), u.username, u.password,
           u.hostname, u.port, u.pathname, u.search, u.hash, u.href].join("|");
  } catch (e) { out = "INVALID"; }
  console.log(out);
}
NODE
node "$TMP/auth.js" "$CORPUS" > "$TMP/auth_want.txt"

# node's `search` and `hash` carry their delimiter when non-empty and are empty
# when the component is present but empty, so they are derived from our two
# bools rather than printed directly. `href` is what checks the bools.
{
  echo 'import "../contrib/url/host.mere";'
  echo 'let p = fn (s: str) ->'
  echo '  match Url.parse s with'
  echo '  | None -> print "INVALID"'
  echo '  | Some u ->'
  echo '    let search = if u.has_query && not (u.query == "")'
  echo '                 then "?" ++ u.query else "" in'
  echo '    let hash = if u.has_fragment && not (u.fragment == "")'
  echo '               then "#" ++ u.fragment else "" in'
  echo '    print (u.scheme ++ "|" ++ u.username ++ "|" ++ u.password ++ "|"'
  echo '           ++ u.host ++ "|" ++ u.port ++ "|" ++ u.path ++ "|" ++ search'
  echo '           ++ "|" ++ hash ++ "|" ++ Url.href u);'
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Escape for a Mere string literal: backslash first, then quote, then `{`
    # last — a `{` in a string opens interpolation, and `\{` is the literal.
    # (Adding a backslash last is safe because nothing re-doubles it.)
    esc=$(printf '%s' "$line" | sed 's/\\/\\\\/g; s/"/\\"/g; s/{/\\{/g')
    printf 'let _ = p "%s";\n' "$esc"
  done < "$CORPUS"
  echo '0'
} > "$ROOT/examples/.url_auth_tmp.mere"
( ulimit -t 60; "$MERE" "$ROOT/examples/.url_auth_tmp.mere" ) | sed '$d' > "$TMP/auth_ours.txt"
rm -f "$ROOT/examples/.url_auth_tmp.mere"

if diff -q "$TMP/auth_want.txt" "$TMP/auth_ours.txt" >/dev/null; then
  echo "  ok    fields  ($(grep -c . "$CORPUS") inputs agree on scheme|user|pass|host|port|path|search|hash|href)"
else
  echo "  FAIL  fields"
  paste -d'\t' "$CORPUS" "$TMP/auth_want.txt" "$TMP/auth_ours.txt" \
    | awk -F'\t' '$2 != $3 { printf "        %-26s\n          node=%s\n          ours=%s\n", $1, $2, $3 }'
  fail=1
fi

[ "$fail" = 0 ] && echo "url_parity: ok" || echo "url_parity: FAILED"
[ "$fail" = 0 ]
