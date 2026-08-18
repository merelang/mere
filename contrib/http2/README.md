# contrib/http2 — HTTP/2 frames

The layer below HPACK and below any notion of a request: an HTTP/2 connection is
a 24-byte preface followed by a sequence of frames, each a 9-byte header and a
payload. Nothing here knows what a HEADERS frame's payload *means* — that is
HPACK's job — which is what lets this be shared by a server, a client and a
packet dumper.

## Files

| file | exports | lines |
|---|---|---|
| `frame.mere` | `module H2 { preface; frame types; flags; put_u8/16be/24be/32be; get_u8/16be/24be/32be; put_header / put_frame / frame_bytes; read_frame; has_flag; settings_payload / read_settings; u32_payload / window_increment / error_code; goaway_payload; grpc_message / read_grpc_message }` | ~215 |

## Usage

```mere
import "contrib/http2/frame.mere";

// an empty SETTINGS frame
hex_of_bytes (H2.frame_bytes H2.settings 0 0 (H2.settings_payload []))
// "000000040000000000"

// read one back
let (ln, ty, flags, stream, payload, next) = H2.read_frame buf 0 in ...
```

Writers build into a `Vec[R, int]`, readers read from `bytes` — the same split as
`contrib/proto`, and for the same two reasons: `bytes_slice` gives a frame's
payload its own buffer with no copy loop, and the `bytes` accessors are
monomorphic so nothing here is generic.

## Two facts that cost time if you get them wrong

- **HTTP/2 is big-endian; protobuf's fixed fields are little-endian.** Two
  protocols with opposite byte order in one program is exactly where a copied
  helper produces a plausible wrong answer, so nothing here is shared with
  `contrib/proto`.
- **The stream identifier is 31 bits.** The top bit of that four-byte field is
  reserved and must be **ignored** on receipt — not rejected. A decoder that reads
  all 32 bits behaves identically against every well-behaved peer and then reports
  a stream id of 2147483649 the first time it meets one that sets the bit. Both
  directions are checked: reading `0x80000001` must give 1, and writing 1
  must give the same frame as writing `0x80000001`.

### `bit_shr` is arithmetic, and that is fine *here*

Every shift in this file is immediately masked with 255 to extract one byte, and
the bits an arithmetic shift copies in all sit above bit 7, so they are discarded.
A logical shift would give the same byte.

That is **not** true in `contrib/proto`, where the shifted value is the *loop
variable* — the varint encoder shifts until it reaches zero, so a negative int64
shifted arithmetically never terminates. There the mask is load-bearing.

The first version of this file carried the mask anyway. Poisoning the gate showed
that removing it changed nothing, which is the definition of dead code: a guard
that cannot fire is a claim the reader has to verify for themselves.

## The gate

`scripts/http2_parity.sh` compares bytes with **hyperframe**, an independent
implementation of RFC 9113 and the frame layer of the `h2` library. Six sections:
encode (50 frames, byte-identical), decode (the same frames, compared on
*fields*), the reserved bit in each direction, the gRPC message prefix, and the
preface.

The sweep crosses frame type × flags × stream id × payload size — payload lengths
0, 1, 2, 255, 256, 16383 and 16384 to cross every length-encoding boundary —
rather than listing frames somebody thought of.

**One byte has two independent confirmations**, which is the only kind of
agreement that means anything: an empty SETTINGS frame serialises as
`000000040000000000`, and that is byte-for-byte what `grpcurl` 1.8.8 was observed
sending on a real connection. hyperframe and grpcurl never met.

### What the poison tests found

Deliberately breaking the implementation to see whether the gate notices found two
things the sweep did not reach:

- **The `lshr` mask was dead** (see above) — removing it changed no answer.
- **The writer's stream-id mask was never exercised.** Every stream id in the
  sweep already has the reserved bit clear, so the mask was a no-op. A section
  now writes `0x80000001` and requires the same frame as stream 1.

Both are the same shape: a guard nothing reaches is indistinguishable from a guard
that is wrong.

## Not here yet

- **HPACK.** Measured on a real connection: grpcurl's very first HEADERS frame
  uses static-table indices, **Huffman-coded** string literals and **seven**
  dynamic-table insertions, so a static-only decoder is not enough for even one
  request. The *encoder*, though, can be trivial — a server that emits
  non-Huffman, non-indexed literals was confirmed to satisfy grpcurl end to end.
- Flow control, stream state, priority, `CONTINUATION` reassembly.
- **Which frame types may appear on which streams** is a rule of its own and is
  not enforced here. hyperframe does enforce it, and refusing to build a SETTINGS
  frame on stream 1 is how the gate found that out.
