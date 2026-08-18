#!/bin/sh
# scripts/proto_gen_parity.sh — check the generated codec against protoc's bytes.
#
# The generator turns a `.proto` into Mere source: a record per message and an
# `encode_` / `decode_` pair. What has to be true of that output is not that it looks
# right but that it AGREES WITH protoc ON THE WIRE, so the check is:
#
#     protoc --encode  ->  bytes  ->  decode_M  ->  encode_M  ->  bytes
#     assert the two byte strings are identical
#
# A ROUND TRIP THROUGH THE ORACLE'S BYTES CATCHES MORE THAN IT LOOKS LIKE. A field
# the decoder ignores is a field the encoder cannot write back, so a dropped field
# shows up as a shorter byte string. A field read at the wrong wire type fails to
# match its tag and disappears the same way. The one thing it cannot see is a
# consistent swap of two fields carrying equal values, which is why the corpus gives
# every field a distinct value.
#
# THE GENERATED SOURCE IS ALSO COMMITTED AND DIFFED, the same arrangement as the
# Unicode tables and the host matrix: a generator whose output nobody reads is a
# generator nobody can review.
#
# Skips (exit 0) without protoc.
#
# Usage:
#   sh scripts/proto_gen_parity.sh

set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MERE="$ROOT/_build/default/bin/mere.exe"

command -v protoc >/dev/null 2>&1 || { echo "proto_gen_parity: protoc absent, skipping"; exit 0; }
[ -x "$MERE" ] || { echo "proto_gen_parity: $MERE not found — run 'dune build'" >&2; exit 1; }
echo "proto_gen_parity: oracle is $(protoc --version)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; rm -f "$ROOT/examples/.pgen_tmp.mere"' EXIT
fail=0
set +e

# --- the corpus: a schema, a message name, and a value ---------------------
# Every field gets a DISTINCT value, because the one thing a round trip cannot see is
# two fields of the same type holding the same thing being swapped.
mkdir -p "$TMP/c"
i=0
newcase() {  # newcase <msg> <textproto> <schema...>
  i=$((i + 1))
  d="$TMP/c/$(printf '%02d' $i)"
  mkdir -p "$d"
  printf '%s\n' "$1" > "$d/msg"
  printf '%s\n' "$2" > "$d/val"
  cat > "$d/s.proto"
}

newcase M 'a: 1  b: 2  c: 3  d: 4' <<'P'
syntax = "proto3";
message M { int32 a = 1; int64 b = 2; uint32 c = 3; uint64 d = 4; }
P
newcase M 'a: -1  b: -2' <<'P'
syntax = "proto3";
message M { sint32 a = 1; sint64 b = 2; }
P
newcase M 'a: 7  b: 8  c: -9  d: -10' <<'P'
syntax = "proto3";
message M { fixed32 a = 1; fixed64 b = 2; sfixed32 c = 3; sfixed64 d = 4; }
P
# double and float. Until float_bits_hi / f32_bits existed the generator REFUSED
# these two types rather than emit something wrong on the wire, so these cases are
# the check that the refusal is gone for the right reason.
newcase M 'a: 1.5  b: 2.5' <<'P'
syntax = "proto3";
message M { double a = 1; float b = 2; }
P
newcase M 'a: -1.5  b: 0.1  c: 1e308  d: 1e-308' <<'P'
syntax = "proto3";
message M { double a = 1; double b = 2; double c = 3; double d = 4; }
P
newcase M 'a: 0.1  b: -2.5  c: 3.4028234663852886e38' <<'P'
syntax = "proto3";
message M { float a = 1; float b = 2; float c = 3; }
P
newcase M 'a: 0  b: 0' <<'P'
syntax = "proto3";
message M { double a = 1; float b = 2; }
P
newcase M 'a: [1.5,-2.5,0.1]  b: [1.5,2.5]' <<'P'
syntax = "proto3";
message M { repeated double a = 1; repeated float b = 2; }
P
newcase M 'a: true  b: "hello"  c: "\x01\x02\xff"' <<'P'
syntax = "proto3";
message M { bool a = 1; string b = 2; bytes c = 3; }
P
# every field at its DEFAULT: proto3 writes nothing at all, so the whole message is
# the empty byte string and the round trip has to produce that too
newcase M 'a: 0  b: ""  c: false' <<'P'
syntax = "proto3";
message M { int32 a = 1; string b = 2; bool c = 3; }
P
# repeated, packed by protoc for the numeric families
newcase M 'a: [1,2,3]  b: [-1,-2]  c: [true,false,true]' <<'P'
syntax = "proto3";
message M { repeated int32 a = 1; repeated sint64 b = 2; repeated bool c = 3; }
P
# Poisoning the repeated-sint32 encoder changed nothing until this existed: the
# corpus had SINGULAR sint32 and REPEATED sint64, so the repeated sint32 path was
# generated and never executed. Same for the repeated fixed families.
newcase M 'a: [-1,-2,3]  b: [1,2]  c: [-3,-4]' <<'P'
syntax = "proto3";
message M { repeated sint32 a = 1; repeated fixed32 b = 2; repeated sfixed64 c = 3; }
P
newcase M 'a: [1,2]  b: [-1,-2]' <<'P'
syntax = "proto3";
message M { repeated uint64 a = 1; repeated sint32 b = 2; }
P
newcase M 'a: ["x","yy"]  b: ["\x00","\xff\xfe"]' <<'P'
syntax = "proto3";
message M { repeated string a = 1; repeated bytes b = 2; }
P
newcase M 'a: []' <<'P'
syntax = "proto3";
message M { repeated int32 a = 1; }
P
# a singular message field, present and absent
newcase M 'n { v: 5 }' <<'P'
syntax = "proto3";
message N { int32 v = 1; }
message M { N n = 1; }
P
newcase M 'v: 1' <<'P'
syntax = "proto3";
message N { int32 v = 1; }
message M { int32 v = 1; N n = 2; }
P
# repeated messages
newcase M 'n { v: 1 }  n { v: 2 }  n { }' <<'P'
syntax = "proto3";
message N { int32 v = 1; }
message M { repeated N n = 1; }
P
# nested messages and enums
newcase M 'i { v: 3 }  e: B' <<'P'
syntax = "proto3";
message M {
  message I { int32 v = 1; }
  enum E { A = 0; B = 1; }
  I i = 1;
  E e = 2;
}
P
# an enum value outside the schema must survive: a proto3 enum is OPEN
newcase M 'e: 7' <<'P'
syntax = "proto3";
enum E { A = 0; }
message M { E e = 1; }
P
newcase M 'e: [1,2,7]' <<'P'
syntax = "proto3";
enum E { A = 0; B = 1; C = 2; }
message M { repeated E e = 1; }
P
# FIELDS DECLARED OUT OF NUMERIC ORDER. protoc encodes in field-number order; a
# generator that emits in declaration order would produce the same fields in a
# different sequence, and the bytes would differ.
newcase M 'a: 1  b: 2  c: 3' <<'P'
syntax = "proto3";
message M { int32 c = 3; int32 a = 1; int32 b = 2; }
P
# a field number past the one-byte tag boundary
newcase M 'a: 1  b: 2' <<'P'
syntax = "proto3";
message M { int32 a = 15; int32 b = 16; }
P
# deep nesting
newcase M 'n { m { v: 9 } }' <<'P'
syntax = "proto3";
message L { int32 v = 1; }
message K { L m = 1; }
message M { K n = 1; }
P
# a package, so the generated names have a prefix to strip
newcase M 'n { v: 2 }' <<'P'
syntax = "proto3";
package deep.pkg;
message N { int32 v = 1; }
message M { N n = 1; }
P

NC=$(ls "$TMP/c" | wc -l | tr -d ' ')

# --- generate, then round-trip through protoc's bytes ---------------------
for d in "$TMP"/c/*; do
  MSG=$(cat "$d/msg"); PKG=$(sed -n 's/^package \(.*\);$/\1/p' "$d/s.proto")
  FQ=$([ -n "$PKG" ] && echo "$PKG.$MSG" || echo "$MSG")
  if ! protoc --encode="$FQ" -I"$d" "$d/s.proto" < "$d/val" > "$d/want.bin" 2>"$d/pe.txt"; then
    echo "  FAIL  corpus  protoc could not encode $(basename "$d"): $(head -1 "$d/pe.txt")"
    fail=1; continue
  fi
  od -An -tx1 -v < "$d/want.bin" | tr -d ' \n' > "$d/want.hex"; echo >> "$d/want.hex"
  if ! ( ulimit -t 120; "$MERE" "$ROOT/examples/protoc_mere.mere" "$d/s.proto" \
          "$ROOT/contrib/proto/wire.mere" ) > "$d/pb.mere" 2>"$d/ge.txt"; then
    echo "  FAIL  generate  $(basename "$d"): $(head -1 "$d/ge.txt")"
    fail=1; continue
  fi
  # `sed '$d'` drops the interpreter's trailing unit line.
  sed -i.bak '$d' "$d/pb.mere" 2>/dev/null || sed -i '$d' "$d/pb.mere"
  {
    printf 'import "%s";\n' "$d/pb.mere"
    printf 'let src = bytes_of_hex "%s";\n' "$(cat "$d/want.hex")"
    printf 'print (hex_of_bytes (encode_%s (decode_%s src)))\n' "$MSG" "$MSG"
  } > "$ROOT/examples/.pgen_tmp.mere"
  if ( ulimit -t 120; "$MERE" "$ROOT/examples/.pgen_tmp.mere" ) 2>"$d/re.txt" \
       | sed '$d' > "$d/got.hex"; then :; fi
  if ! diff -q "$d/want.hex" "$d/got.hex" >/dev/null 2>&1; then
    echo "  FAIL  round-trip  $(basename "$d")"
    echo "        schema: $(tr '\n' ' ' < "$d/s.proto" | cut -c1-100)"
    echo "        value:  $(tr '\n' ' ' < "$d/val")"
    echo "        protoc: $(cat "$d/want.hex")"
    echo "        ours:   $(cat "$d/got.hex" 2>/dev/null)"
    [ -s "$d/re.txt" ] && sed 's/^/        /' "$d/re.txt" | head -3
    fail=1
  fi
done
[ "$fail" = 0 ] && echo "  ok    round-trip  $NC schemas: protoc's bytes decoded and re-encoded identically"

# --- the UNPACKED form a decoder must also accept -------------------------
#
# proto3 writes a repeated scalar PACKED, so protoc never produces the other form and
# nothing in the sweep above reaches the branch that reads it. Removing that branch
# left this harness green — a decoder that only understands the encoding its own
# oracle emits works against exactly one kind of writer.
#
# So the unpacked bytes are built here, and PROTOC IS ASKED whether the two spellings
# mean the same thing rather than being told. Then the generated decoder has to agree
# with the same answer AND normalise to the packed form, which is what protoc does.
mkdir -p "$TMP/u"
cat > "$TMP/u/s.proto" <<'P'
syntax = "proto3";
message M { repeated int32 a = 1; repeated sint32 b = 2; }
P
# COMPUTED, NOT TYPED. The first version of these bytes was written by hand and had
# field 2's tag as length-delimited instead of varint — protoc rejected the input and
# the harness reported it as its own bug, correctly. Hand-written test bytes are a
# transcription like any other, so they are derived from the values instead.
UNPACKED=$(python3 -c "
def varint(v):
    out = bytearray()
    while True:
        b = v & 0x7f; v >>= 7
        out.append(b | (0x80 if v else 0))
        if not v: break
    return bytes(out)
def zz(n): return (n << 1) ^ (n >> 63) & ((1 << 64) - 1) if n < 0 else n << 1
out = bytearray()
for v in (1, 2, 300):          # field 1, int32, one tag each
    out += bytes([(1 << 3) | 0]) + varint(v)
for v in (-1, -2, -3):         # field 2, sint32, zigzagged, one tag each
    out += bytes([(2 << 3) | 0]) + varint((v << 1) ^ -1 if v < 0 else v << 1)
print(out.hex())
")
printf 'a: [1,2,300]  b: [-1,-2,-3]\n' > "$TMP/u/val"
protoc --encode=M -I"$TMP/u" "$TMP/u/s.proto" < "$TMP/u/val" > "$TMP/u/packed.bin" 2>/dev/null
od -An -tx1 -v < "$TMP/u/packed.bin" | tr -d ' \n' > "$TMP/u/packed.hex"; echo >> "$TMP/u/packed.hex"
printf '%s' "$UNPACKED" | xxd -r -p > "$TMP/u/unpacked.bin"
protoc --decode=M -I"$TMP/u" "$TMP/u/s.proto" < "$TMP/u/packed.bin" \
  | tr -d ' \n' > "$TMP/u/p.txt" 2>/dev/null
protoc --decode=M -I"$TMP/u" "$TMP/u/s.proto" < "$TMP/u/unpacked.bin" \
  | tr -d ' \n' > "$TMP/u/u.txt" 2>/dev/null
if ! diff -q "$TMP/u/p.txt" "$TMP/u/u.txt" >/dev/null 2>&1; then
  echo "  FAIL  unpacked  protoc does NOT read the two forms as the same value, so this"
  echo "        case is about the harness's hand-built bytes rather than about us:"
  echo "        packed:   $(cat "$TMP/u/p.txt")"
  echo "        unpacked: $(cat "$TMP/u/u.txt")"
  fail=1
else
  if ! ( ulimit -t 120; "$MERE" "$ROOT/examples/protoc_mere.mere" "$TMP/u/s.proto" \
          "$ROOT/contrib/proto/wire.mere" ) > "$TMP/u/pb.mere" 2>"$TMP/u/ge.txt"; then
    echo "  FAIL  unpacked  the generator failed: $(head -1 "$TMP/u/ge.txt")"
    fail=1
  else
    sed -i.bak '$d' "$TMP/u/pb.mere" 2>/dev/null || sed -i '$d' "$TMP/u/pb.mere"
    {
      printf 'import "%s";\n' "$TMP/u/pb.mere"
      printf 'print (hex_of_bytes (encode_M (decode_M (bytes_of_hex "%s"))))\n' "$UNPACKED"
    } > "$ROOT/examples/.pgen_tmp.mere"
    ( ulimit -t 120; "$MERE" "$ROOT/examples/.pgen_tmp.mere" ) 2>"$TMP/u/re.txt" \
      | sed '$d' > "$TMP/u/got.hex"
    if diff -q "$TMP/u/packed.hex" "$TMP/u/got.hex" >/dev/null 2>&1; then
      echo "  ok    unpacked  the non-packed form decodes to the same value and re-encodes packed"
    else
      echo "  FAIL  unpacked  the non-packed form was not read as protoc reads it"
      echo "        want (packed): $(cat "$TMP/u/packed.hex")"
      echo "        ours:          $(cat "$TMP/u/got.hex" 2>/dev/null)"
      [ -s "$TMP/u/re.txt" ] && sed 's/^/        /' "$TMP/u/re.txt" | head -3
      fail=1
    fi
  fi
fi

# --- the committed generated file is what the generator produces ----------
GEN="$ROOT/examples/hello_pb.mere"
PROTO="$ROOT/examples/hello.proto"
if [ -f "$PROTO" ]; then
  if ( ulimit -t 120; "$MERE" "$ROOT/examples/protoc_mere.mere" "examples/hello.proto" \
        "../contrib/proto/wire.mere" ) > "$TMP/fresh.mere" 2>"$TMP/fe.txt"; then
    sed -i.bak '$d' "$TMP/fresh.mere" 2>/dev/null || sed -i '$d' "$TMP/fresh.mere"
    if diff -q "$GEN" "$TMP/fresh.mere" >/dev/null 2>&1; then
      echo "  ok    committed  examples/hello_pb.mere matches a fresh run"
    else
      echo "  FAIL  committed  examples/hello_pb.mere is not what the generator produces"
      diff "$GEN" "$TMP/fresh.mere" | head -12 | sed 's/^/        /'
      fail=1
    fi
  else
    echo "  FAIL  committed  the generator failed on examples/hello.proto:"
    sed 's/^/        /' "$TMP/fe.txt" | head -4
    fail=1
  fi
else
  echo "  FAIL  committed  examples/hello.proto is missing"
  fail=1
fi

[ "$fail" = 0 ] && echo "proto_gen_parity: ok" || echo "proto_gen_parity: FAILED"
[ "$fail" = 0 ]
