#!/bin/sh
# scripts/hpack_parity.sh — check contrib/http2/hpack.mere against hpack (Python).
#
# HPACK is where an HTTP/2 implementation is most likely to be quietly wrong,
# because almost every mistake still produces headers. A desynchronised dynamic
# table does not error — it reports a different header name, plausibly spelled,
# from an index that used to mean something else.
#
# SO THE SWEEP IS PER CONNECTION, NOT PER BLOCK. Python's `hpack.Encoder` is
# stateful; it emits indices that only mean anything against the insertions the
# previous blocks made. A harness that decoded each block with a fresh state would
# pass while the implementation was unable to hold a connection open.
#
# THE TABLES SHARE A SOURCE WITH THIS ORACLE, and that is a real hole:
# `contrib/http2/hpack_table.mere` is generated from the same Python library, so a
# transcription error in the static table or the Huffman code would be invisible to
# every section that uses it. Section 2 is what closes it — a header block captured
# from **grpcurl 1.8.8 / grpc-go 1.57**, a third implementation in another language
# that never saw either table. If our tables were wrong, those bytes would not
# decode to those names.
#
# SECTIONS:
#   0. tables    — the generated file is what the generator produces
#   1. decode    — per-connection sweeps from hpack.Encoder
#   2. grpc-go   — a real captured block, the cross-language check of the tables
#   3. encode    — our block, decoded by the oracle (no AST/table transcription)
#   4. integers  — the prefix representation across every boundary
#   5. eviction  — a sequence that forces the dynamic table to evict
#
# Skips (exit 0) when hpack is absent.
#
# Usage:
#   sh scripts/hpack_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

[ -x "$MERE" ] || { echo "hpack_parity: $MERE not found — run 'dune build'" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "hpack_parity: python3 absent, skipping"; exit 0; }
python3 -c "import hpack" 2>/dev/null || {
  echo "hpack_parity: the 'hpack' package is not importable, skipping"
  echo "              (python3 -m pip install hpack)"
  exit 0; }
HP_VER=$(python3 -c "import hpack; print(hpack.__version__)")
echo "hpack_parity: oracle is hpack $HP_VER"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f "$ROOT/examples/.hpack_parity_tmp.mere"' EXIT
fail=0
set +e

run_subject() {  # run_subject <label> <mere-file> <stdout-file>
  if ( ulimit -t 240; "$MERE" "$2" ) > "$3" 2> "$TMP/err.txt"; then return 0; fi
  echo "  FAIL  $1  the subject itself failed on this section:"
  sed 's/^/          /' "$TMP/err.txt" | head -5
  fail=1
  return 1
}

# --- 0. the generated tables are what the generator produces --------------
if sh "$ROOT/scripts/gen_hpack_tables.sh" --check > "$TMP/gen.txt" 2>&1; then
  echo "  ok    tables  $(sed -n 's/^gen_hpack_tables: //p' "$TMP/gen.txt" | head -1)"
else
  echo "  FAIL  tables  the committed table is not what the generator produces"
  sed 's/^/        /' "$TMP/gen.txt" | head -12
  fail=1
fi

# --- 1. decode, per connection -------------------------------------------
python3 - "$TMP" <<'PY'
import sys, pathlib
from hpack import Encoder
tmp = pathlib.Path(sys.argv[1])

# Each connection is a list of blocks; each block is a list of (name, value).
# The point of several blocks per connection is the dynamic table: the second
# block's indices only mean anything if the first block's insertions happened.
conns = []

# a realistic request, then the same request again (all indices), then a variation
req = [(":method", "POST"), (":scheme", "http"), (":path", "/svc/Method"),
       (":authority", "localhost:50051"), ("content-type", "application/grpc"),
       ("user-agent", "harness/1.0"), ("te", "trailers")]
conns.append([req, req, req[:4] + [("content-type", "application/grpc+proto")]])

# a response, its trailers, and a second response
conns.append([[(":status", "200"), ("content-type", "application/grpc")],
              [("grpc-status", "0"), ("grpc-message", "")],
              [(":status", "200"), ("content-type", "application/grpc")]])

# every static-table entry, one block each — this is what makes the static table
# exercised rather than assumed
from hpack.table import HeaderTable
static_blocks = [[(n.decode(), v.decode())] for n, v in HeaderTable.STATIC_TABLE]
conns.append(static_blocks)

# values that stress the Huffman coder: every ASCII printable, long runs, and the
# characters whose codes are longest
conns.append([[("x-a", "".join(chr(c) for c in range(32, 127)))],
              [("x-b", "a" * 300)],
              [("x-c", "0123456789" * 20)],
              [("x-d", "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")],
              [("x-e", "")],
              [("x-f", " ")]])

# names and values that must NOT be Huffman-shrunk (hpack falls back to raw when
# Huffman would be longer), so both string forms appear in one connection
conns.append([[("x-raw", "\x01\x02\x03")], [("x-raw2", "\x7f")]])

lines, want = [], []
for ci, blocks in enumerate(conns):
    e = Encoder()
    for bi, hdrs in enumerate(blocks):
        raw = e.encode(hdrs)
        lines.append(f"{ci} {raw.hex()}")
        for n, v in hdrs:
            want.append(f"{ci}.{bi} {n}={v}")
        want.append(f"{ci}.{bi} .")
tmp.joinpath("blocks.txt").write_text("\n".join(lines) + "\n")
tmp.joinpath("dec_want.txt").write_text("\n".join(want) + "\n")
print(len(lines))
PY
NBLK=$(wc -l < "$TMP/blocks.txt" | tr -d ' ')

# One state per connection, threaded through that connection's blocks. Generated
# in python rather than awk: the awk version tracked the block index in a variable
# that was wrong on the first row of each connection, and produced a `let` that
# referred to itself.
python3 - "$TMP" "$ROOT/examples/.hpack_parity_tmp.mere" <<'PY'
import sys, pathlib
tmp, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
lines = ['import "../contrib/http2/hpack.mere";',
         'let show = fn (tag: str, st: hstate, h: str) ->',
         '  let (hs, st2) = Hpack.decode st (bytes_of_hex h) in',
         '  let _ = list_iter hs (fn (kv) ->',
         '            let (n, v) = kv in print (tag ++ " " ++ n ++ "=" ++ v)) in',
         '  let _ = print (tag ++ " .") in',
         '  st2;']
bi_of = {}
for row in tmp.joinpath("blocks.txt").read_text().split("\n"):
    if not row: continue
    ci, hexs = row.split(" ", 1)
    bi = bi_of.get(ci, 0); bi_of[ci] = bi + 1
    prev = "Hpack.new_state" if bi == 0 else f"st_{ci}_{bi - 1}"
    lines.append(f'let st_{ci}_{bi} = show "{ci}.{bi}" {prev} "{hexs}";')
lines.append("0")
out.write_text("\n".join(lines) + "\n")
PY

if run_subject "decode" "$ROOT/examples/.hpack_parity_tmp.mere" "$TMP/dec_raw.txt"; then
  sed '$d' "$TMP/dec_raw.txt" > "$TMP/dec.txt"
  if diff -q "$TMP/dec_want.txt" "$TMP/dec.txt" >/dev/null; then
    echo "  ok    decode  $NBLK blocks over 5 connections, dynamic table in step"
  else
    echo "  FAIL  decode"
    diff "$TMP/dec_want.txt" "$TMP/dec.txt" | head -16 | sed 's/^/        /'
    fail=1
  fi
fi

# --- 2. the cross-language check of the tables ----------------------------
# Captured from grpcurl 1.8.8 (grpc-go 1.57) on a live cleartext connection: the
# first HEADERS frame of a real request, Huffman-coded, with seven dynamic-table
# insertions. Nothing in this repo or in the Python oracle produced these bytes.
GRPCGO=838645a9626b2b22f6165a0a4498f52fdc2bee2d9dcb66d2cb4148931ea63716cee5b36965a0a4498f564aa53f418b089d5c0b8170dc6c006c5f5f8b1d75d0620d263d4c4d65647a959acac96d943015de5de526b2b22d31d80aedbab83f40027465864d833505b11f408e9acac8b0c842d6958b510f21aa9b839bd9ab40899acac8b24d494f6a7f8665f7db782edb
{
  echo 'import "../contrib/http2/hpack.mere";'
  printf 'let (hs, st) = Hpack.decode Hpack.new_state (bytes_of_hex "%s");\n' "$GRPCGO"
  echo 'let _ = list_iter hs (fn (kv) -> let (n, v) = kv in print (n ++ ": " ++ v));'
  echo 'match st with | HState (e, sz, _) -> print ("entries=" ++ str_of_int (list_len e) ++ " size=" ++ str_of_int sz)'
} > "$ROOT/examples/.hpack_parity_tmp.mere"
python3 - "$TMP" "$GRPCGO" <<'PY'
import sys, pathlib
from hpack import Decoder
hs = Decoder().decode(bytes.fromhex(sys.argv[2]), raw=False)
lines = [f"{n}: {v}" for n, v in hs]
# the oracle's own accounting, so the entry count is checked and not just the names
d = Decoder(); d.decode(bytes.fromhex(sys.argv[2]), raw=False)
lines.append(f"entries={len(d.header_table.dynamic_entries)} "
             f"size={d.header_table._current_size}")
pathlib.Path(sys.argv[1], "go_want.txt").write_text("\n".join(lines) + "\n")
PY
if run_subject "grpc-go block" "$ROOT/examples/.hpack_parity_tmp.mere" "$TMP/go_raw.txt"; then
  sed '$d' "$TMP/go_raw.txt" > "$TMP/go.txt"
  if diff -q "$TMP/go_want.txt" "$TMP/go.txt" >/dev/null; then
    echo "  ok    grpc-go block  9 headers + table accounting from a third implementation"
  else
    echo "  FAIL  grpc-go block  our tables disagree with bytes grpc-go produced"
    diff "$TMP/go_want.txt" "$TMP/go.txt" | head -12 | sed 's/^/        /'
    fail=1
  fi
fi

# --- 3. encode: our block, read by the oracle ----------------------------
# The same trick as graphql_parity: send our output through the oracle instead of
# comparing two serialisations. Our encoder never indexes, so the peer's table
# stays empty and one decoder for the connection is the faithful arrangement.
python3 - "$TMP" <<'PY'
import sys, pathlib
sets = [
    [(":status", "200"), ("content-type", "application/grpc")],
    [("grpc-status", "0"), ("grpc-message", "")],
    [("x-empty", "")],
    [("x-long", "z" * 500)],
    [("x-punct", "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")],
    [("x-many", "1"), ("x-many", "2"), ("x-many", "3")],
]
mere, want = [], []
for i, hs in enumerate(sets):
    # Mere string escaping: a backslash, a double quote, and `{` (which opens
    # string interpolation). The first version escaped only the brace, and the
    # punctuation row — which contains a quote and a backslash — broke the lexer.
    def esc(x):
        return x.replace("\\", "\\\\").replace('"', '\\"').replace("{", "\\{")
    args = ", ".join(f'("{esc(n)}", "{esc(v)}")' for n, v in hs)
    mere.append(f'let _ = print (hex_of_bytes (Hpack.encode [{args}]));')
    want.append(" | ".join(f"{n}={v}" for n, v in hs))
pathlib.Path(sys.argv[1], "enc_mere.txt").write_text("\n".join(mere) + "\n")
pathlib.Path(sys.argv[1], "enc_want.txt").write_text("\n".join(want) + "\n")
PY
{ echo 'import "../contrib/http2/hpack.mere";'; cat "$TMP/enc_mere.txt"; echo '0'; } \
  > "$ROOT/examples/.hpack_parity_tmp.mere"
if run_subject "encode" "$ROOT/examples/.hpack_parity_tmp.mere" "$TMP/enc_raw.txt"; then
  sed '$d' "$TMP/enc_raw.txt" > "$TMP/enc_hex.txt"
  python3 - "$TMP" <<'PY'
import sys, pathlib
from hpack import Decoder
tmp = pathlib.Path(sys.argv[1])
d = Decoder()
out = []
for hexs in tmp.joinpath("enc_hex.txt").read_text().split("\n"):
    if not hexs: continue
    try:
        hs = d.decode(bytes.fromhex(hexs), raw=False)
        out.append(" | ".join(f"{n}={v}" for n, v in hs))
    except Exception as e:
        out.append("UNDECODABLE: " + str(e))
tmp.joinpath("enc_got.txt").write_text("\n".join(out) + "\n")
PY
  if diff -q "$TMP/enc_want.txt" "$TMP/enc_got.txt" >/dev/null; then
    echo "  ok    encode  6 blocks the oracle decodes back to what we meant"
  else
    echo "  FAIL  encode"
    diff "$TMP/enc_want.txt" "$TMP/enc_got.txt" | head -12 | sed 's/^/        /'
    fail=1
  fi
fi

# --- 4. the integer representation ---------------------------------------
# A value equal to the prefix maximum still needs a continuation octet, which is
# the boundary a "does the prefix fit" test gets wrong. Swept for every prefix
# width HPACK uses.
python3 - "$TMP" <<'PY'
import sys, pathlib
from hpack.hpack import encode_integer
vals = [0, 1, 2, 5, 14, 15, 16, 30, 31, 32, 62, 63, 64, 126, 127, 128, 129,
        254, 255, 256, 1337, 4096, 16383, 16384, 65535, 1048576, 2147483647]
rows, want = [], []
for prefix in (4, 5, 6, 7):
    for v in vals:
        rows.append(f"{prefix} {v}")
        want.append(bytes(encode_integer(v, prefix)).hex())
tmp = pathlib.Path(sys.argv[1])
tmp.joinpath("int_rows.txt").write_text("\n".join(rows) + "\n")
tmp.joinpath("int_want.txt").write_text("\n".join(want) + "\n")
PY
{
  echo 'import "../contrib/http2/hpack.mere";'
  echo 'let enc = fn (prefix: int, v: int) ->'
  echo '  let o = vec_new () in'
  echo '  let _ = Hpack.encode_int o 0 prefix v in'
  echo '  print (hex_of_bytes (bytes_of_vec o));'
  echo 'let rt = fn (prefix: int, v: int) ->'
  echo '  let o = vec_new () in'
  echo '  let _ = Hpack.encode_int o 0 prefix v in'
  echo '  let (got, _) = Hpack.decode_int (bytes_of_vec o) 0 prefix in'
  echo '  if got == v then () else fail ("hpack: int round-trip lost " ++ str_of_int v);'
  while IFS=' ' read -r prefix v; do
    [ -z "$prefix" ] && continue
    printf 'let _ = rt %s %s;\nlet _ = enc %s %s;\n' "$prefix" "$v" "$prefix" "$v"
  done < "$TMP/int_rows.txt"
  echo '0'
} > "$ROOT/examples/.hpack_parity_tmp.mere"
if run_subject "integers" "$ROOT/examples/.hpack_parity_tmp.mere" "$TMP/int_raw.txt"; then
  sed '$d' "$TMP/int_raw.txt" > "$TMP/int_got.txt"
  if diff -q "$TMP/int_want.txt" "$TMP/int_got.txt" >/dev/null; then
    echo "  ok    integers  $(wc -l < "$TMP/int_rows.txt" | tr -d ' ') (prefix, value) pairs, encoded and round-tripped"
  else
    echo "  FAIL  integers"
    paste -d'|' "$TMP/int_rows.txt" "$TMP/int_want.txt" "$TMP/int_got.txt" \
      | awk -F'|' '$2 != $3 { printf "        prefix/value %-14s oracle=%-16s ours=%s\n", $1, $2, $3 }' | head -12
    fail=1
  fi
fi

# --- 5. eviction ---------------------------------------------------------
# The dynamic table's size is bytes, not entries, and each entry costs its name
# plus its value plus 32. A table that omits the 32 evicts too late and then
# disagrees with the peer about what index 62 means. Driven past the limit with a
# size update small enough to force it.
python3 - "$TMP" <<'PY'
import sys, pathlib
from hpack import Encoder
e = Encoder()
e.header_table_size = 200          # emits a dynamic table size update
blocks, want = [], []
seq = [[("x-1", "a" * 40)], [("x-2", "b" * 40)], [("x-3", "c" * 40)],
       [("x-1", "a" * 40)], [("x-4", "d" * 150)], [("x-5", "e")]]
for bi, hdrs in enumerate(seq):
    blocks.append(e.encode(hdrs).hex())
    for n, v in hdrs:
        want.append(f"{bi} {n}={v}")
    want.append(f"{bi} . entries={len(e.header_table.dynamic_entries)}"
                f" size={e.header_table._current_size}")
tmp = pathlib.Path(sys.argv[1])
tmp.joinpath("ev_blocks.txt").write_text("\n".join(blocks) + "\n")
tmp.joinpath("ev_want.txt").write_text("\n".join(want) + "\n")
PY
{
  echo 'import "../contrib/http2/hpack.mere";'
  echo 'let show = fn (tag: str, st: hstate, h: str) ->'
  echo '  let (hs, st2) = Hpack.decode st (bytes_of_hex h) in'
  echo '  let _ = list_iter hs (fn (kv) ->'
  echo '            let (n, v) = kv in print (tag ++ " " ++ n ++ "=" ++ v)) in'
  echo '  let _ = match st2 with'
  echo '          | HState (e, sz, _) -> print (tag ++ " . entries=" ++ str_of_int (list_len e)'
  echo '                                        ++ " size=" ++ str_of_int sz) in'
  echo '  st2;'
  i=0
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    if [ "$i" = 0 ]; then prev=Hpack.new_state; else prev="st$((i-1))"; fi
    printf 'let st%s = show "%s" %s "%s";\n' "$i" "$i" "$prev" "$h"
    i=$((i+1))
  done < "$TMP/ev_blocks.txt"
  echo '0'
} > "$ROOT/examples/.hpack_parity_tmp.mere"
if run_subject "eviction" "$ROOT/examples/.hpack_parity_tmp.mere" "$TMP/ev_raw.txt"; then
  sed '$d' "$TMP/ev_raw.txt" > "$TMP/ev_got.txt"
  if diff -q "$TMP/ev_want.txt" "$TMP/ev_got.txt" >/dev/null; then
    echo "  ok    eviction  entry count and byte size track the oracle through 6 blocks"
  else
    echo "  FAIL  eviction"
    diff "$TMP/ev_want.txt" "$TMP/ev_got.txt" | head -14 | sed 's/^/        /'
    fail=1
  fi
fi

# --- 6. what must be REJECTED --------------------------------------------
#
# Every section above feeds well-formed blocks, and that is not enough: poisoning
# the decoder to stop checking Huffman padding did NOT turn this gate red, because
# valid input has valid padding. A check that only fires on malformed input needs
# malformed input, or it is a comment.
#
# Each case runs in its own process because a refusal aborts. And a case the
# ORACLE accepts is a bug in this list, not a finding — the same rule as
# everywhere else here.
python3 - "$TMP" <<'PY2'
import sys, pathlib
from hpack import Decoder
from hpack.huffman import HuffmanEncoder
from hpack.huffman_constants import REQUEST_CODES, REQUEST_CODES_LENGTH

he = HuffmanEncoder(REQUEST_CODES, REQUEST_CODES_LENGTH)
cases = []

# The third column is a substring the refusal must CONTAIN. Poisoning showed why
# it is needed: removing the index-0 check, the EOS check or the string-length
# check did not turn this gate red, because each malformed block still failed —
# further downstream, with a message about something else. "Does it refuse" and
# "does it say what was wrong" are two questions, and only the first was asked.
#
# This couples the gate to OUR OWN wording, which is the acceptable direction: it
# stops a named diagnostic from silently decaying into a confusing downstream one.
# It is not coupled to the oracle's wording, which would be brittle for no gain.
def add(label, raw, says):
    cases.append((label, raw.hex(), says))

# an indexed header field naming index 0, which is not an index
add("indexed field, index 0", bytes([0x80]), "index 0 is not a table entry")
# an index past the end of a table that has nothing dynamic in it
add("index 62 with an empty dynamic table", bytes([0x80 | 62]), "does not exist")
add("index 200", bytes([0xff, 0x49]), "does not exist")
# a literal whose value length runs past the block
add("string length past the end", bytes([0x00, 0x01, 0x61, 0x05, 0x61]),
    "runs past the end of the block")
add("name length past the end", bytes([0x00, 0x05, 0x61]), "runs past the end of the block")
# Huffman padding of a whole octet: legal padding is fewer than 8 bits
h = he.encode(b"a")
add("Huffman padding of eight bits",
    bytes([0x00, 0x01, 0x61, 0x80 | (len(h) + 1)]) + h + b"\xff",
    "padding is eight bits or more")
# Huffman padding that is not all ones
add("Huffman padding not all ones",
    bytes([0x00, 0x01, 0x61, 0x80 | len(he.encode(b"aaa"))])
    + (int.from_bytes(he.encode(b"aaa"), "big") & ~1).to_bytes(len(he.encode(b"aaa")), "big"),
    "padding is not all ones")
# The EOS symbol, which must never appear in a string. Its code is THIRTY bits of
# ones and codes are packed from the most significant bit, so it has to be shifted
# up and the remaining two bits filled with padding — also ones. Written as
# `0x3fffffff` in four bytes it starts with two ZERO bits, which decode as a
# different, shorter symbol and trip the padding check instead. That mistake made
# this case pass for the wrong reason until the message was asserted.
eos = ((0x3fffffff << 2) | 0x3).to_bytes(4, "big")   # == ff ff ff ff
add("EOS in a Huffman string", bytes([0x00, 0x01, 0x61, 0x80 | 4]) + eos,
    "EOS symbol appeared")
# an integer with more continuation octets than any legal value
add("integer continuation without end", bytes([0x1f]) + b"\xff" * 12,
    "longer than any legal value")

keep, oracle = [], []
for label, hexs, says in cases:
    try:
        Decoder().decode(bytes.fromhex(hexs), raw=False)
        oracle.append("ACCEPT")
    except Exception:
        oracle.append("REJECT")
    keep.append(f"{label}\t{hexs}\t{says}")
tmp = pathlib.Path(sys.argv[1])
tmp.joinpath("bad.txt").write_text("\n".join(keep) + "\n")
tmp.joinpath("bad_oracle.txt").write_text("\n".join(oracle) + "\n")
PY2

if grep -qx ACCEPT "$TMP/bad_oracle.txt"; then
  echo "  FAIL  reject-list  the oracle ACCEPTS blocks this list calls malformed:"
  paste -d'|' "$TMP/bad.txt" "$TMP/bad_oracle.txt" \
    | awk -F'|' '$2 == "ACCEPT" { split($1, a, "\t"); printf "        %s\n", a[1] }' | head -6
  fail=1
else
  nbad=0; nwrong=0
  while IFS="$(printf '\t')" read -r label hexs says; do
    [ -z "$hexs" ] && continue
    nbad=$((nbad + 1))
    {
      echo 'import "../contrib/http2/hpack.mere";'
      printf 'let (hs, _) = Hpack.decode Hpack.new_state (bytes_of_hex "%s");\n' "$hexs"
      echo 'print (str_of_int (list_len hs))'
    } > "$ROOT/examples/.hpack_parity_tmp.mere"
    if ( ulimit -t 60; "$MERE" "$ROOT/examples/.hpack_parity_tmp.mere" ) \
         >/dev/null 2>"$TMP/bad_err.txt"; then
      echo "        ACCEPTED (should have been refused): $label"
      nwrong=$((nwrong + 1))
    elif [ -z "$says" ]; then
      echo "        NO EXPECTATION for: $label"
      echo "          the case file is missing its third column, which would make"
      echo "          the message check match anything at all"
      nwrong=$((nwrong + 1))
    elif ! grep -q "$says" "$TMP/bad_err.txt"; then
      echo "        REFUSED BUT UNNAMED: $label"
      echo "          expected the message to contain: $says"
      echo "          got: $(head -1 "$TMP/bad_err.txt" | cut -c1-110)"
      nwrong=$((nwrong + 1))
    fi
  done < "$TMP/bad.txt"
  if [ "$nbad" = 0 ]; then
    echo "  FAIL  reject-list  checked ZERO cases — the case generator produced nothing."
    echo "        A gate reporting ok for no cases is indistinguishable from one that"
    echo "        did not run; this is the same rule the builtin matrix learned."
    fail=1
  elif [ "$nwrong" = 0 ]; then
    echo "  ok    reject-list  $nbad malformed blocks refused, each naming what was wrong"
  else
    echo "  FAIL  reject-list  $nwrong of $nbad were accepted"
    fail=1
  fi
fi

[ "$fail" = 0 ] && echo "hpack_parity: ok" || echo "hpack_parity: FAILED"
[ "$fail" = 0 ]
