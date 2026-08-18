#!/bin/sh
# scripts/proto_parity.sh — check contrib/proto/wire.mere against protoc's BYTES.
#
# Why bytes and not behaviour: the wire format is a transcription. Every rule in
# it (how a varint packs, which end of a fixed64 comes first, that a negative
# int64 costs ten bytes and not nine) is a fact somebody read out of prose and
# typed in. The only check that catches a mis-transcription is byte equality
# with an implementation written from the same prose by someone else, and protoc
# is that implementation.
#
# It works by derivation, not by fixtures. The value lists below are generated
# to cross every varint length boundary and every sign boundary, and the same
# list is fed to protoc and to us. A fixture file would only say what somebody
# thought to write down — and what somebody thinks to write down is exactly the
# set of values their implementation already handles.
#
# FOUR SECTIONS, and the third is the interesting one:
#
#   1. message   — one message with every wire type in it, compared whole
#   2. int64     — a swept value list, encoded as a single int64 field
#   3. DIVERGE   — the values where the INTERPRETER is knowingly wrong
#   4. decode    — protoc's own bytes, decoded by us and re-encoded, compared
#                  back to protoc's bytes
#
# Section 3 exists because the interpreter's int is OCaml's native int, which is
# 63-bit, while every compiled backend's int is 64-bit. Above 2^62 the same
# program gives different answers, and the interpreter's is the wrong one:
#
#     bit_shl 1 62        interp -4611686018427387904   C  4611686018427387904
#     int64 max, built    interp -1                     C  9223372036854775807
#     bit_shl 1 63        interp 0                      C -9223372036854775808
#
# That is a silent wrong answer, not a failure, and it matters more than it
# looks: the interpreter is the oracle the builtin-refusal work holds the
# compiled backends to. So these values are PINNED as DIVERGE rather than
# dropped from the harness. Dropping them would make the gate quiet about a
# thing that is still true; pinning them means that on the day the interpreter
# becomes 64-bit, THIS SCRIPT BREAKS and says so. A gate that cannot detect its
# own repair leaves a claim in the tree that stopped being true.
#
# Skips (exit 0) when protoc is absent, so protoc stays out of the dependency
# set for building mere.
#
# Usage:
#   sh scripts/proto_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

command -v protoc >/dev/null 2>&1 || { echo "proto_parity: protoc absent, skipping"; exit 0; }
[ -x "$MERE" ] || { echo "proto_parity: $MERE not found — run 'dune build'" >&2; exit 1; }

echo "proto_parity: oracle is $(protoc --version)"

# The C backend is checked too, because sections 2 and 3 are ABOUT the width
# difference between the interpreter and a compiled backend. Without a compiled
# backend this script can only report the interpreter's answer, which is the
# answer that is wrong.
HAVE_CC=0
if command -v clang >/dev/null 2>&1; then HAVE_CC=1; CC=clang
elif command -v cc >/dev/null 2>&1; then HAVE_CC=1; CC=cc
else echo "proto_parity: no C compiler — sections 2/3 will report interp only"; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f "$ROOT/examples/.proto_parity_tmp.mere"' EXIT
fail=0

cat > "$TMP/t.proto" <<'PROTO'
syntax = "proto3";
package pp;
message All {
  int32  a = 1;
  int64  b = 2;
  sint32 c = 3;
  string d = 4;
  bool   g = 7;
  repeated int32 h = 8;
}
message I64 { int64  v = 1; }
message S64 { sint64 v = 1; }
message F64 { fixed64 v = 1; }
message F32 { fixed32 v = 1; }
PROTO

enc() {  # enc <MessageName> <textproto>  -> hex on stdout
  printf '%s\n' "$2" | protoc --encode="pp.$1" -I"$TMP" "$TMP/t.proto" 2>/dev/null \
    | od -An -tx1 -v | tr -d ' \n'
  echo
}

# run_mere <file> <mode>   mode = interp | c
run_mere() {
  if [ "$2" = interp ]; then
    ( ulimit -t 180; "$MERE" "$1" ) | sed '$d'
  else
    ( ulimit -t 180
      "$MERE" -c "$1" > "$TMP/out.c" &&
      $CC -O1 -w "$TMP/out.c" -o "$TMP/out.bin" &&
      "$TMP/out.bin" ) | sed '$d'
  fi
}

# ---------------------------------------------------------------------------
# 1. one message with every wire type in it
# ---------------------------------------------------------------------------
enc All 'a: 300  b: -1  c: -2  d: "hi"  g: true  h: [1,2,300]' > "$TMP/msg_want.txt"

cat > "$ROOT/examples/.proto_parity_tmp.mere" <<'MERE'
import "../contrib/proto/wire.mere";
let b = vec_new ();
let _ = Wire.tag b 1 Wire.varint;
let _ = Wire.put_varint b 300;
let _ = Wire.tag b 2 Wire.varint;
let _ = Wire.put_varint b (0 - 1);
let _ = Wire.tag b 3 Wire.varint;
let _ = Wire.put_varint b (Wire.zz32 (0 - 2));
let _ = Wire.tag b 4 Wire.delimited;
let _ = Wire.put_str b "hi";
let _ = Wire.tag b 7 Wire.varint;
let _ = Wire.put_varint b 1;
let p = vec_new ();
let _ = Wire.put_varint p 1;
let _ = Wire.put_varint p 2;
let _ = Wire.put_varint p 300;
let _ = Wire.tag b 8 Wire.delimited;
let _ = Wire.put_delimited b p;
print (hex_of_bytes (bytes_of_vec b))
MERE

for mode in interp c; do
  [ "$mode" = c ] && [ "$HAVE_CC" = 0 ] && continue
  run_mere "$ROOT/examples/.proto_parity_tmp.mere" "$mode" > "$TMP/msg_ours.txt"
  if diff -q "$TMP/msg_want.txt" "$TMP/msg_ours.txt" >/dev/null; then
    echo "  ok    message ($mode)  every wire type, compared whole"
  else
    echo "  FAIL  message ($mode)"
    echo "        protoc: $(cat "$TMP/msg_want.txt")"
    echo "        ours:   $(cat "$TMP/msg_ours.txt")"
    fail=1
  fi
done

# ---------------------------------------------------------------------------
# 2/3. swept value lists.
#
# SAFE crosses every varint length boundary up to 2^62-1, which is also the
# largest integer LITERAL this compiler accepts. PINNED is the range above it,
# where the interpreter and a compiled backend disagree.
# ---------------------------------------------------------------------------
# TWO CONSTRAINTS ON THIS LIST, both learned by getting them wrong:
#
#   * 0 IS EXCLUDED. proto3 does not write a scalar field that holds its default,
#     so `protoc --encode` answers the empty string for `v: 0` while this layer
#     — which has no schema and therefore no notion of a default — writes `0800`.
#     That is not a disagreement about the wire format; it is a question whose
#     answer lives one layer up. A schema-less encoder cannot be gated against a
#     schema-ful oracle at the default value, and asking anyway would have been
#     recorded as a bug in the varint code.
#
#   * THE ZIGZAG BOUND IS HALF THE VARINT BOUND. zigzag doubles its input, so a
#     value safe for `int64` overflows for `sint64`. The largest literal this
#     compiler accepts is 2^62-1; the largest value whose zigzag still fits the
#     INTERPRETER's 63-bit int is 2^61-1. Sweeping both with one list put four
#     interpreter-width divergences into the section meant for real failures.
python3 - "$TMP" <<'PY'
import sys, pathlib
tmp = pathlib.Path(sys.argv[1])
# every varint length boundary, both signs; 0 excluded (see above)
plain = [1, 2, 127, 128, 129, 255, 256, 16383, 16384, 2097151, 2097152,
         268435455, 268435456, 34359738367, 34359738368,
         4398046511103, 4398046511104, 562949953421311, 562949953421312,
         72057594037927935, 72057594037927936,
         4611686018427387902, 4611686018427387903]
plain += [-v for v in (1, 2, 127, 128, 255, 16384, 2097152, 4611686018427387903)]
# zigzag: same boundaries, halved bound so the doubling stays inside 63 bits
zz = [v for v in plain if abs(v) < (1 << 61)]
tmp.joinpath("safe.txt").write_text("\n".join(str(v) for v in plain) + "\n")
tmp.joinpath("zz.txt").write_text("\n".join(str(v) for v in zz) + "\n")
PY

# sweep <listfile> <MessageName> <mere-encoder-expr> <label>
sweep() {
  list=$1; msg=$2; expr=$3; label=$4
  : > "$TMP/want.txt"
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    enc "$msg" "v: $v" >> "$TMP/want.txt"
  done < "$list"

  {
    echo 'import "../contrib/proto/wire.mere";'
    echo 'let one = fn (f) -> let b = vec_new () in let _ = f b in hex_of_bytes (bytes_of_vec b);'
    printf 'let row = fn (v: int) -> print (one (fn (b) -> let _ = Wire.tag b 1 %s in %s));\n' \
      "$(echo "$expr" | cut -d'@' -f1)" "$(echo "$expr" | cut -d'@' -f2)"
    while IFS= read -r v; do
      [ -z "$v" ] && continue
      case "$v" in
        -*) printf 'let _ = row (0 - %s);\n' "${v#-}" ;;
        *)  printf 'let _ = row %s;\n' "$v" ;;
      esac
    done < "$list"
    echo '0'
  } > "$ROOT/examples/.proto_parity_tmp.mere"

  for mode in interp c; do
    [ "$mode" = c ] && [ "$HAVE_CC" = 0 ] && continue
    run_mere "$ROOT/examples/.proto_parity_tmp.mere" "$mode" > "$TMP/ours.txt"
    if diff -q "$TMP/want.txt" "$TMP/ours.txt" >/dev/null; then
      echo "  ok    $label ($mode)  $(grep -c . "$list") values, every varint length boundary"
    else
      echo "  FAIL  $label ($mode)"
      paste -d'|' "$list" "$TMP/want.txt" "$TMP/ours.txt" \
        | awk -F'|' '$2 != $3 { printf "        %-22s protoc=%-24s ours=%s\n", $1, $2, $3 }' | head -12
      fail=1
    fi
  done
}

sweep "$TMP/safe.txt" I64 'Wire.varint@Wire.put_varint b v'            "int64"
sweep "$TMP/zz.txt"   S64 'Wire.varint@Wire.put_varint b (Wire.zz64 v)' "sint64 (zigzag)"

# --- 3. DIVERGE: the width the interpreter does not have --------------------
#
# These are pinned EXACTLY, not tolerated. int64 max and int64 min cannot be
# written as literals (the largest the lexer accepts is 2^62-1, and 2^62 dies
# with an uncaught OCaml Failure("int_of_string")), so they are computed from
# 2^62-1 — which is itself part of what is being reported here.
cat > "$ROOT/examples/.proto_parity_tmp.mere" <<'MERE'
import "../contrib/proto/wire.mere";
let m62 = 4611686018427387903;
let i64max = m62 + m62 + 1;
let i64min = 0 - i64max - 1;
let one = fn (f) -> let b = vec_new () in let _ = f b in hex_of_bytes (bytes_of_vec b);
let _ = print (one (fn (b) -> Wire.put_varint b i64max));
let _ = print (one (fn (b) -> Wire.put_varint b i64min));
let _ = print (one (fn (b) -> Wire.put_varint b (Wire.zz64 i64min)));
let _ = print (one (fn (b) -> Wire.put_varint b (Wire.zz64 i64max)));
0
MERE

cat > "$TMP/div_c.txt" <<'EOF'
ffffffffffffffff7f
80808080808080808001
ffffffffffffffffff01
feffffffffffffffff01
EOF
# What the 63-bit interpreter answers instead. Pinned so that a fix breaks this.
cat > "$TMP/div_interp.txt" <<'EOF'
ffffffffffffffffff01
00
00
01
EOF

if [ "$HAVE_CC" = 1 ]; then
  run_mere "$ROOT/examples/.proto_parity_tmp.mere" c > "$TMP/div_ours_c.txt"
  if diff -q "$TMP/div_c.txt" "$TMP/div_ours_c.txt" >/dev/null; then
    echo "  ok    int64 edges (c)  max/min and their zigzags agree with protoc"
  else
    echo "  FAIL  int64 edges (c)"
    paste -d'|' "$TMP/div_c.txt" "$TMP/div_ours_c.txt" \
      | awk -F'|' '$1 != $2 { printf "        protoc=%-24s ours=%s\n", $1, $2 }'
    fail=1
  fi
fi

run_mere "$ROOT/examples/.proto_parity_tmp.mere" interp > "$TMP/div_ours_i.txt"
if diff -q "$TMP/div_interp.txt" "$TMP/div_ours_i.txt" >/dev/null; then
  echo "  DIVERGE int64 edges (interp)  4 pinned: interp int is 63-bit (OCaml native)"
  echo "          this is not a tolerance — when the interpreter becomes 64-bit,"
  echo "          this section FAILS and the pin must be retired."
elif diff -q "$TMP/div_c.txt" "$TMP/div_ours_i.txt" >/dev/null; then
  echo "  FAIL  int64 edges (interp)  THE PIN IS STALE — interp now agrees with protoc."
  echo "        Retire the DIVERGE block in this script and the int-width note in"
  echo "        OPEN_QUESTIONS Q-037."
  fail=1
else
  echo "  FAIL  int64 edges (interp)  neither the pinned nor the correct answer"
  paste -d'|' "$TMP/div_interp.txt" "$TMP/div_ours_i.txt" \
    | awk -F'|' '$1 != $2 { printf "        pinned=%-24s got=%s\n", $1, $2 }'
  fail=1
fi

# ---------------------------------------------------------------------------
# 4. decode: protoc's bytes in, our re-encoding out, compared to protoc's bytes.
#
# This checks the reader without needing to match protoc's TEXT format. If we
# read a field's extent wrong, the re-encoding cannot come back byte-identical.
# ---------------------------------------------------------------------------
MSG=$(cat "$TMP/msg_want.txt")
cat > "$ROOT/examples/.proto_parity_tmp.mere" <<MERE
import "../contrib/proto/wire.mere";
let src = bytes_of_hex "$MSG";
// Read every field and write it back out. Nothing here knows the schema, so a
// wrong extent shows up immediately as a different byte string.
let rec copy = fn (out, i: int) ->
  if i >= bytes_len src then ()
  else
    let (f, wt, j) = Wire.get_tag src i in
    let _ = Wire.tag out f wt in
    if wt == Wire.varint then
      let (v, k) = Wire.get_varint src j in
      let _ = Wire.put_varint out v in
      copy out k
    else if wt == Wire.delimited then
      let (payload, k) = Wire.get_delimited src j in
      let _ = Wire.put_bytes out payload in
      copy out k
    else if wt == Wire.fixed64 then
      let (v, k) = Wire.get_fixed64 src j in
      let _ = Wire.put_fixed64 out v in
      copy out k
    else if wt == Wire.fixed32 then
      let (v, k) = Wire.get_fixed32 src j in
      let _ = Wire.put_fixed32 out v in
      copy out k
    else fail "proto_parity: unexpected wire type in the round-trip corpus";
let out = vec_new ();
let _ = copy out 0;
print (hex_of_bytes (bytes_of_vec out))
MERE

for mode in interp c; do
  [ "$mode" = c ] && [ "$HAVE_CC" = 0 ] && continue
  run_mere "$ROOT/examples/.proto_parity_tmp.mere" "$mode" > "$TMP/rt_ours.txt"
  if diff -q "$TMP/msg_want.txt" "$TMP/rt_ours.txt" >/dev/null; then
    echo "  ok    decode round-trip ($mode)  protoc's bytes read and rewritten identically"
  else
    echo "  FAIL  decode round-trip ($mode)"
    echo "        protoc: $(cat "$TMP/msg_want.txt")"
    echo "        ours:   $(cat "$TMP/rt_ours.txt")"
    fail=1
  fi
done

[ "$fail" = 0 ] && echo "proto_parity: ok" || echo "proto_parity: FAILED"
[ "$fail" = 0 ]
