# contrib/proto — the Protocol Buffers wire format

The layer below any schema: a protobuf message is a sequence of
`(field number, wire type)` tags, each followed by a value in one of six shapes.
Nothing here knows what a field *means*, which is what lets a generated encoder,
a hand-written one and a schema-less inspector share it.

## Files

| file | exports | lines |
|---|---|---|
| `wire.mere` | `module Wire { varint / fixed64 / delimited / fixed32 constants; lshr; put_varint / tag / zz32 / zz64 / put_fixed32 / put_fixed64 / put_delimited / put_bytes / put_str; get_varint / get_tag / unzz32 / unzz64 / get_fixed32 / get_fixed64 / get_delimited / skip_value }` | ~185 |

## Usage

```mere
import "contrib/proto/wire.mere";

// encode
let b = vec_new () in
let _ = Wire.tag b 1 Wire.varint in
let _ = Wire.put_varint b 300 in
hex_of_bytes (bytes_of_vec b)              // "08ac02"

// decode
let src = bytes_of_hex "08ac02" in
let (field, wt, i) = Wire.get_tag src 0 in
let (v, _) = Wire.get_varint src i in
v                                          // 300
```

The writer builds into a `Vec[R, int]` and the reader reads from `bytes`. That
asymmetry is deliberate: `bytes_slice` hands a nested message its own sub-buffer
with no copy loop, and the `bytes` accessors are monomorphic so nothing in the
reader is generic. (The first version read from a `Vec` and could not be
compiled — the C backend raised `vec_* on Vec with unresolved element type` at a
line in this file for a program that never mentioned a Vec.)

## The gate

`scripts/proto_parity.sh` holds every function here to **`protoc`'s bytes**, not
to a description of them. Four sections:

1. **message** — one message containing every wire type, compared whole
2. **int64 / sint64** — swept value lists crossing every varint length boundary
3. **int64 edges** — max, min and their zigzags
4. **decode round-trip** — protoc's own bytes, read by us and rewritten, compared
   back to protoc's bytes

Two things the gate had to be taught, both by getting them wrong first:

- **0 cannot be swept.** proto3 does not write a scalar holding its default, so
  `protoc --encode` answers the empty string for `v: 0` while this layer — which
  has no schema and therefore no notion of a default — writes `0800`. That is a
  question one layer up, not a disagreement about the wire format.
- **The zigzag bound is half the varint bound.** zigzag doubles its input, so a
  value safe for `int64` overflows for `sint64`.

### The interpreter is 63-bit, and that is pinned rather than hidden

Above 2^62 the interpreter and the compiled backends disagree, because the
interpreter's int is OCaml's native int:

| | interp | C |
|---|---|---|
| `bit_shl 1 62` | −4611686018427387904 | 4611686018427387904 |
| int64 max, built by addition | −1 | 9223372036854775807 |
| `bit_shl 1 63` | 0 | −9223372036854775808 |

Section 3 records the interpreter's wrong answers as a **DIVERGE pin**, not as a
tolerance. On the day the interpreter becomes 64-bit, that section fails and says
the pin must be retired — a gate that cannot detect its own repair leaves a claim
in the tree that stopped being true.

Related: integer literals above 2^62−1 cannot be written at all (the lexer dies
with an uncaught `Failure("int_of_string")`), so the edge values in the harness
are *computed* from 2^62−1.

## Not here yet

- Schema-driven encode/decode. A `.proto` parser and a generator that emits
  records plus `encode_*` / `decode_*` are the next two slices.
- `double` / `float` fields. They need IEEE-754 bit patterns; a bit-exact
  conversion from existing language features has been measured to work (24 values,
  no differences) but costs a scaling loop per value.
- Groups (wire types 3 and 4) are recognised by `skip_value`'s refusal, not
  decoded. They are deprecated and no proto3 file can produce them.
