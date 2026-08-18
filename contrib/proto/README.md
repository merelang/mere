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

`scripts/proto_desc_parity.sh` compares **bytes** across 103 derived files. Not a
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

## Options

`option name = value;` at file, message, enum, service and method level, and
`[a = 1, b = 2]` on a field or an enum value.

### The subset lives in the encoder, not the parser

An option's name means nothing to the grammar — `option x = 1;` is well-formed
whatever `x` is — and the field number that encodes it belongs to
`descriptor.proto`. So the parser accepts any `name = value` and
`descriptor.mere` refuses a name it cannot encode, **by name**. Keeping the list
of known names in both places is how the two drift.

### protoc emits options in ascending field order, not source order

Measured: `option go_package` (field 11) written before `option java_package`
(field 1) comes back as 1 then 11. Same inside a field's brackets —
`[jstype = JS_STRING, deprecated = true]` is emitted 3 then 6. Every multi-option
case in the corpus is therefore written in **descending** field order on purpose,
so a writer that keeps source order produces different bytes.

### `json_name` is not an option

`[json_name = "wire"]` sets `FieldDescriptorProto`'s own `json_name` (field 10)
and produces **no options submessage at all**. Treating it as an option would put
it in the wrong message under a number that means something else. The encoder
pulls it out of the bracket list before looking anything up.

Three more things the oracle fixed:

- **`OptimizeMode` does not start at 0** — `SPEED = 1`, `CODE_SIZE = 2`,
  `LITE_RUNTIME = 3`. `JSType`, `CType` and `IdempotencyLevel` do start at 0.
- **An unset `options` submessage is omitted**, so writing an empty one adds two
  bytes protoc does not — *except* on a method, where `{}` must emit an empty
  submessage and `;` must emit nothing. That distinction predates options and is
  why `has_body` is still carried separately from the options a body may hold.
- **A method body may now contain options**, so the "only empty braces" refusal is
  gone; anything other than `option` inside one is still a named error.

### What is still refused, and what cannot be tested

The options protoc accepts and this encoder does not carry are refused by name and
each has a case in the gate: `java_string_check_utf8`, `php_class_prefix`,
`cc_generic_services`, `weak`, `debug_redact`. **Adding one to the table makes its
case fail as stale** — measured by doing it.

A **custom option** (`option (my.ext) = 1`) is refused where the syntax says what
it is: an extension's field number comes from a registry built out of other
`.proto` files, so it cannot be encoded from this file alone.

Two guards are **defensive and unreachable from valid input**, and say so in the
code: an unknown option name and a wrong-typed value. protoc rejects both, so no
protoc-accepted file reaches either branch.

## Imports

`import "path";`, `import public "path";`, `import weak "path";` — recorded in the
descriptor and used to resolve types across files.

```mere
Pdesc.of_sources "a.proto" a_src [("dep.proto", dep_src)]
```

`deps` is `(path, source)`, so **I/O stays with the caller**: `contrib` reads no
files.

### The two index lists are indices, not paths

`public_dependency` (field 10) and `weak_dependency` (field 11) hold **positions in
`dependency`**, not their own path strings. Measured: three imports where the second
is public and the third weak give `dependency` 0,1,2 with `10: 1` and `11: 2`.

Field order matters because these are compared as bytes: `dependency` is 3 and
`message_type` is 4, so the paths come **before** the messages, while the two index
lists (10, 11) come **after** them.

### A private import is not transitive; a public one is

This is a rule, not a convenience, and the oracle is what says so. protoc rejects a
type reached through a private import two files away:

```
"cc.Deep" seems to be defined in "c.proto", which is not imported by "a.proto"
```

and accepts the same reference when the middle file says `import public`. **A
resolver that walked every import transitively would accept schemas protoc rejects**
— the wrong direction to be wrong in, because a schema that compiles here and
nowhere else is worse than one that is refused. The gate checks both directions.

An import path the caller did not supply is an error **naming the path**. Without
that, the reference would simply fail to resolve and be reported as an unknown type
in the importing file — a message about the wrong file.

### Three kinds of cross-file reference, and all three are in the gate

- **qualified into another package** — `dep.Shared` → `.dep.Shared`
- **unqualified into the same package in a different file** — `Local` → `.pk.Local`
- **an enum**, which resolves to a different type code (`TYPE_ENUM`, not
  `TYPE_MESSAGE`) and so needs the imported file's *declarations* and not just its
  package

`scripts/proto_desc_parity.sh` compares 11 multi-file cases as bytes, and offers
**every** dependency file to **every** target — so an import a target does not
declare must not become visible merely because it was supplied.

### The generator refuses a cross-file reference, and that is a layout decision

`contrib/proto/descriptor` resolves an imported type and emits it. `gen.mere` will
not, because generated Mere source would need the imported file's **generated
names** — which means knowing what the other output file is called and emitting an
`import` for it. That is the caller's layout, and it is exactly why `wire_path` is
already an argument.

So it is refused **by name**, pointing at the descriptor path, rather than met with
"no such type" — which would point at the field and say nothing about why the type
is missing. A file that imports something it never references across still
generates, and the gate checks both halves: without the second, "refuses imports"
would be indistinguishable from "refuses any file containing an import".

### The subset is refused, not skipped

`oneof`, `map`, `reserved`, `optional`, `extend`, `group` and proto2 syntax are
outside the subset. **protoc accepts all of
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
- ~~`double` / `float` fields~~ — **done** (mere v0.1.281). They needed IEEE-754 bit
  patterns, and `float_bits_hi` / `float_bits_lo` / `f32_bits` provide them. The
  bits come out in two 32-bit halves rather than one 64-bit integer, because a
  whole pattern read as a signed int64 does not fit the interpreter's native int for
  a large share of ordinary values — `1e308` among them — and one accessor would have
  answered differently there than on every compiled backend. `put_double` /
  `put_float` keep that split inside this layer.
- Groups (wire types 3 and 4) are recognised by `skip_value`'s refusal, not
  decoded. They are deprecated and no proto3 file can produce them.
