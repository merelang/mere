#!/bin/sh
# scripts/wasm_sourcemap.sh — build a Wasm program with a source map, and check
# the map against the binary it claims to describe.
#
# The whole chain:
#
#   mere -w  app.mere > app.wat        # the code
#   mere -wg app.mere > app.map.txt    # which function came from which line
#   wat2wasm --debug-names ...         # the binary, with names to match on
#   node scripts/wasm_sourcemap.js     # the two, joined into a source map
#
# and then the part that makes it evidence rather than hope: the map is decoded
# back into (byte offset -> source line) pairs and compared against what
# `wasm-objdump` independently says those offsets are. A source map is easy to
# produce and hard to trust — the VLQ segments are deltas, so being wrong by one
# shifts everything after it — and nothing but disassembling the result and
# looking will catch that.
#
# Skips (exit 0) when wabt or node are missing, like the other optional checks.
#
# Usage:
#   sh scripts/wasm_sourcemap.sh

set -e

MERE=${MERE:-./_build/default/bin/mere.exe}

for tool in wat2wasm wasm-objdump node; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "wasm_sourcemap: $tool not found — skipping (this check is optional)"
    exit 0
  fi
done

if [ ! -x "$MERE" ]; then
  echo "wasm_sourcemap: $MERE not found — run dune build first" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/app.mere" <<'EOF'
let twice = fn (n: int) ->
  n * 2;

let thrice = fn (n: int) ->
  n * 3;

let both = fn (n: int) ->
  twice n + thrice n;

let _ = print_int (both 7);
EOF

"$MERE" -w  "$TMP/app.mere" > "$TMP/app.wat"
"$MERE" -wg "$TMP/app.mere" > "$TMP/app.map.txt"
wat2wasm --enable-tail-call --debug-names "$TMP/app.wat" -o "$TMP/app.wasm"
node scripts/wasm_sourcemap.js "$TMP/app.wasm" "$TMP/app.map.txt" "$TMP/app.mere"

# The binary still has to be a binary: appending a custom section is only
# harmless if it is done right.
if command -v wasm-validate >/dev/null 2>&1; then
  wasm-validate --enable-tail-call "$TMP/app.wasm"
  echo "  ok    the binary still validates"
fi

if ! wasm-objdump -h "$TMP/app.wasm" | grep -q "sourceMappingURL"; then
  echo "  FAIL  no sourceMappingURL section — a browser would never look for the map" >&2
  exit 1
fi
echo "  ok    a browser is told where the map is"

# Decode the map, and ask the disassembler what is really at each offset.
TMP_PAIRS="$TMP/pairs" node -e '
const fs = require("fs");
const map = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function dec(s) {
  const out = []; let i = 0;
  while (i < s.length) {
    let v = 0, sh = 0, d;
    do { d = B64.indexOf(s[i++]); v |= (d & 31) << sh; sh += 5; } while (d & 32);
    const neg = v & 1; v >>= 1; out.push(neg ? -v : v);
  }
  return out;
}
// Every field but the first is a delta from the segment before it, which is the
// part worth checking: an off-by-one here shifts every mapping after it.
let off = 0, line = 0;
const out = [];
for (const seg of map.mappings.split(",")) {
  const f = dec(seg); off += f[0]; line += f[2];
  out.push(off.toString(16).padStart(6, "0") + " " + (line + 1));
}
fs.writeFileSync(process.env.TMP_PAIRS, out.join("\n") + "\n");
' "$TMP/app.wasm.map"

# What the disassembler says lives at each of those offsets.
wasm-objdump -d "$TMP/app.wasm" \
  | sed -n 's/^\([0-9a-f]*\) func\[[0-9]*\] <\(.*\)>:$/\1 \2/p' > "$TMP/funcs"

fail=0
while read -r off line; do
  name=$(awk -v o="$off" '$1 == o { print $2 }' "$TMP/funcs")
  expected=$(awk -v n="$name" '$1 == "F" && $2 == n { print $3 }' "$TMP/app.map.txt")
  if [ -z "$name" ]; then
    printf '  FAIL  0x%s is not the start of any function\n' "$off" >&2
    fail=1
  elif [ "$expected" != "$line" ]; then
    printf '  FAIL  0x%s is <%s> (line %s) but the map says line %s\n' \
      "$off" "$name" "$expected" "$line" >&2
    fail=1
  else
    printf '  ok    0x%s is <%s>, and the map says line %s\n' "$off" "$name" "$line"
  fi
done < "$TMP/pairs"

if [ "$fail" = 0 ]; then
  echo "wasm_sourcemap: ok"
else
  echo "wasm_sourcemap: FAILED"
fi
exit "$fail"
