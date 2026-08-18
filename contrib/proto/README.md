# contrib/proto — the Protocol Buffers wire format

The layer below any schema: a protobuf message is a sequence of
`(field number, wire type)` tags, each followed by a value in one of six shapes.
Nothing here knows what a field *means*, which is what lets a generated encoder,
a hand-written one and a schema-less inspector share it.

## Files

| file | exports | lines |
|---|---|---|
| `gen.mere` | `module Pgen { file_source }` — a `.proto` into Mere source | ~420 |
| `parse.mere` | `type pty/pfield/penum/pmsg/pmethod/psvc/pfile/pdecl`; `module Pparse { parse_file, collect, resolve, json_name, type codes }` | ~360 |
| `descriptor.mere` | `module Pdesc { of_source, file_set, file_desc }` | ~150 |
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

## The schema half

`parse.mere` reads a `.proto` file and `descriptor.mere` writes it out as a
`FileDescriptorSet`.

```mere
import "contrib/proto/descriptor.mere";
hex_of_bytes (Pdesc.of_source "a.proto" (read_file "a.proto"))
```

**The bootstrap closes here.** A descriptor set is itself a protobuf message, so the
code that reads a schema is serialised by the code that reads wire bytes, and one
oracle — `protoc --descriptor_set_out` — checks both layers at once. If the varint
encoder is wrong the descriptor diff says so; if a descriptor field number is wrong,
the same diff says so.

`scripts/proto_desc_parity.sh` compares **bytes** across 72 derived files. Not a
decoded rendering and not a field walk: a descriptor that decodes to the same text
but different bytes is still a different descriptor to anything that hashes or
caches it.

### Three things the oracle taught before any of it was written

- **`descriptor.proto` is proto2, which reverses a rule.** A set field is written
  even at its default, so an enum value's `number: 0` appears on the wire. The wire
  harness had to learn the opposite for proto3 — `v: 0` could not be swept there.
  Same encoder, opposite rule, decided by the schema being encoded.
- **`json_name` is always present and is not plain camelCase.** Measured:
  `my_field` → `myField`, `a_b_c` → `aBC`, `already_Camel` → `alreadyCamel`,
  `trailing_` → `trailing`, `__lead` → `Lead`, `num_2_x` → `num2X`. The rule is
  "drop underscores, upper-case what follows each one" — guessing camelCase gets the
  last three wrong.
- **`rpc U (Q) returns (R) {}` is not the same as `rpc U (Q) returns (R);`.** The
  empty body sets `MethodOptions` to an empty submessage, so protoc emits `22 00`
  for it and nothing for the semicolon form. That two-byte difference was the last
  file of 72 to match.

`type_name` is fully qualified with a **leading dot** (`.pk.N`), and a reference
resolves from the innermost scope outward — so the same simple name means different
types at different depths, and getting the order wrong produces a descriptor that is
still well-formed.

### The subset is refused, not skipped

`oneof`, `map`, `import`, `option` (file and field), `reserved`, `optional`,
`extend`, `group` and proto2 syntax are outside the subset. **protoc accepts all of
them**, so the oracle cannot be asked whether they are wrong — they are simply not
implemented. What the harness checks instead is that the parser **refuses each one by
name**: a skipped construct would produce a descriptor that is wrong where nothing
looks.

## The generator

`gen.mere` turns a `.proto` into Mere source — a record per message and an
`encode_` / `decode_` pair — and `examples/protoc_mere.mere` is its command line:

```sh
mere examples/protoc_mere.mere examples/hello.proto ../contrib/proto/wire.mere \
  > examples/hello_pb.mere
```

`examples/grpc_hello.mere` uses it, and that is the point of the slice: the codec
there used to be a hand-written field walk and a two-line encoder. Both were correct
and both were a schema transcribed by hand.

### Three representation choices

- **A singular message field is a 0-or-1 list.** proto3 gives message fields explicit
  presence, so "absent" and "present but empty" differ and a bare field could not say
  the first. It also makes `message Node { Node next = 1; }` expressible.
- **An enum is an `int`, not a variant.** A proto3 enum is *open*: an unknown number
  must survive a round trip, and a closed variant could not hold one. The generator
  emits `enum_<Type>_<VALUE>` constants beside it.
- **A generated identifier never starts with the type name.** Uppercase-leading is how
  this language recognises a constructor, so `M_get_a` parses as one and is reported as
  an unknown constructor at its *use* site — an error naming something the schema
  author never wrote. Hence `get_M_a`.

**Decode scans the buffer once per field.** A single pass would have to thread every
field through the loop as an N-tuple; one pass per field is O(fields × bytes) and
makes each field a small independent function. A deliberate trade, stated because a
reader would otherwise assume the single pass.

**The encoder writes fields in field-number order, not declaration order**, because
protoc does — a schema declaring `int32 c = 3;` first would otherwise produce the same
fields in a different sequence and different bytes.

### The gate, and the two gaps poisoning found

`scripts/proto_gen_parity.sh` runs protoc's bytes through the generated codec and back:
`protoc --encode` → `decode_M` → `encode_M` → compare. 20 schemas. A round trip through
the oracle's bytes catches more than it looks like — a field the decoder ignores cannot
be written back, so it shows up as a shorter byte string — and the one thing it cannot
see is a consistent swap of two fields holding equal values, which is why every field
in the corpus has a distinct value.

The committed `examples/hello_pb.mere` is diffed against a fresh run, the same
arrangement as the Unicode tables: a generator whose output nobody reads is a generator
nobody can review.

Poisoning found two coverage gaps:

1. **The repeated zigzag and fixed families were not in the corpus.** It had *singular*
   sint32 and *repeated* sint64, so the repeated-sint32 path was generated and never
   executed. Breaking it changed nothing.
2. **protoc always writes packed, so the decoder's unpacked branch was never reached.**
   proto3 requires a decoder to accept both forms whatever the writer chose, and
   removing that branch left the harness green. The unpacked bytes are now built by the
   harness — *computed from the values*, after a hand-typed first version put field 2's
   tag as length-delimited and protoc rejected it — and **protoc is asked** whether the
   two spellings mean the same thing rather than being told.

## Not here yet
- `double` / `float` fields. They need IEEE-754 bit patterns; a bit-exact
  conversion from existing language features has been measured to work (24 values,
  no differences) but costs a scaling loop per value.
- Groups (wire types 3 and 4) are recognised by `skip_value`'s refusal, not
  decoded. They are deprecated and no proto3 file can produce them.
