# contrib/http2 — HTTP/2 frames, HPACK, and an h2c server

The layer below HPACK and below any notion of a request: an HTTP/2 connection is
a 24-byte preface followed by a sequence of frames, each a 9-byte header and a
payload. Nothing here knows what a HEADERS frame's payload *means* — that is
HPACK's job — which is what lets this be shared by a server, a client and a
packet dumper.

## Files

| file | exports | lines |
|---|---|---|
| `server.mere` | `type grpc_reply`; `module H2Server { serve, serve_n, respond, respond_ok, respond_err, status codes, pct_encode }` — an h2c connection | ~260 |
| `hpack.mere` | `type hstate`; `module Hpack { new_state; decode; encode; decode_int / encode_int; huff_decode; insert / resize; lookup }` | ~250 |
| `hpack_table.mere` | `module HpackTable { … }` — **generated** by `scripts/gen_hpack_tables.sh` | ~160 |
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

**Binary crosses the FFI as `bytes`** (mere v0.1.282). `tcp_read` writes into the
integer-addressed arena and `mem_to_str` cannot bring that back — it stops at the
first zero byte, which every second HPACK block contains. `mem_to_bytes` /
`mem_copy_bytes` are the arena's two directions for data that may contain one.

This file used to go arena → hex → `bytes` on the way in and call `mem_set_u8`
**once per byte** on the way out. The write was the one that mattered: a response is
one FFI call now rather than one call per byte of it.

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

## HPACK

`hpack.mere` is the header compression layer, and what had to be complete in it
was **measured, not guessed**. grpcurl 1.8.8's first HEADERS frame on a real
connection uses static-table indices, Huffman-coded string literals and **seven**
dynamic-table insertions. So:

- **The decoder is complete** — integers, both string forms, all five
  instructions, the dynamic table with eviction. There is no static-only shortcut
  that survives even one request, because the table's state changes what later
  indices mean: a decoder that skips insertions desynchronises and then reports
  plausible wrong header *names* rather than erroring.
- **The encoder is trivial** — literal, new name, no indexing, no Huffman. RFC 7541
  permits it, and a server emitting only those was confirmed end to end: grpcurl
  accepted the response and printed the message. Compression is an optimisation
  and this file does not do it.

That asymmetry is why a gRPC server is reachable without a Huffman *encoder*.

**The dynamic table is connection state and is threaded through the API**, not
hidden in a global: `decode` takes a state and returns the new one. One decoder
per connection is correct and two is not, and a parameter makes that visible at
the call site rather than at 3am.

### The tables are generated, and that is a hole the gate has to close

`hpack_table.mere` holds the two things HPACK cannot compute — the 61-entry static
table (RFC 7541 Appendix A) and the 257-symbol Huffman code (Appendix B). Both are
generated by `scripts/gen_hpack_tables.sh`, committed, and diffed on every run.

The generator's source is **the same Python library the gate uses as its oracle**,
which means a differential test cannot catch an error in a table both sides share.
That is stated rather than papered over, and it is why `hpack_parity.sh` decodes a
header block **captured from grpcurl 1.8.8 / grpc-go 1.57** — a third
implementation, in another language, that never saw either table. If the tables
were wrong, those bytes would not decode to those nine header names.

The Huffman code is **canonical** — contiguous within each length and ordered by
symbol — which the generator *asserts* rather than assumes. That is what lets the
decoder work from per-length counts and first codes with no tree.

### The gate, and what poisoning it found

`scripts/hpack_parity.sh` has seven sections: the generated tables, a
**per-connection** decode sweep (75 blocks — per *block* would pass while the
implementation could not hold a connection open), the grpc-go block, an encode
round-trip through the oracle, 108 integer (prefix, value) pairs, dynamic-table
eviction compared on entry count *and* byte size, and a reject-list.

Poisoning found three things:

1. **Valid input does not test a refusal.** Removing the Huffman padding check did
   not turn the gate red, because well-formed blocks have well-formed padding. Nine
   malformed blocks now check the refusals.
2. **"Does it refuse" and "does it say what was wrong" are two questions.**
   Removing the index-0, EOS and string-length checks *still* refused — further
   downstream, with a message about something else. Each malformed case now asserts
   a substring the refusal must contain. This couples the gate to *our own* wording,
   which is the acceptable direction: it stops a named diagnostic from decaying into
   a confusing downstream one.
3. **A check whose input never arrives passes.** The case file was written with two
   columns while the reader expected three, so every expectation was the empty
   string and `grep -q ""` matched everything. An empty expectation is now itself a
   failure, and a reject-list that checked *zero* cases is too — a gate reporting ok
   for no cases is indistinguishable from one that did not run.

One line survives poisoning on purpose: the `len2 < huff_min_len` test is a **fast
path, not a check**, and is labelled as such so nobody has to re-derive that.

## The server

`server.mere` turns the layers above into a connection. A handler is `str -> bytes -> grpc_reply` — a path and a request message, giving
either a response message or a status — and everything about HTTP/2 stays on the
other side of it.

```mere
import "contrib/http2/server.mere";
H2Server.serve 50051 (fn (path: str, req: bytes) ->
  if str_eq path "/svc/Method" then RpcOk (reply_for req)
  else RpcErr (H2Server.unimplemented, "no such method: " ++ path))
```

**A failure is a status in the trailers, not an HTTP status.** The request succeeded
as HTTP and failed as RPC, so it cannot be expressed as a 4xx — and a failed unary
call carries no DATA frame at all, only HEADERS and trailers. `bytes` alone could
not say "this failed", which is why the handler's answer is a variant: before it
was, an unknown method got a reply that looked like a success.

**`grpc-message` is percent-encoded**, and that is neither optional nor cosmetic:
the specification says so and grpc-go *decodes* it — measured, `caf%C3%A9 %25`
came back as `café %` — so a raw `%` in a message would be read as the start of an
escape. The rule is "bytes outside printable ASCII, plus `%` itself", which means a
space and an apostrophe pass through. The first expectation written into the harness
assumed otherwise and the wire corrected it.

`examples/grpc_hello.mere` is a gRPC Greeter built on it, and
`scripts/grpc_parity.sh` drives it with two real clients. That harness is the only
one here that does not compare bytes: every layer underneath already has a
byte-level gate, and none of them answers the question a server exists to answer —
whether a client that knows nothing about any of this gets a reply it recognises.

**TLS is absent by measurement, not oversight.** gRPC over cleartext HTTP/2 (h2c,
prior knowledge) is what `grpcurl -plaintext` and every gRPC client's insecure mode
speak: 24 literal bytes and no negotiation. So a server is useful before anything
here knows what ALPN is.

### What the server does not do, and how each one is checked

- **One connection at a time.** `mhttpd` already showed how to spawn a handler per
  connection with a buffer pool; doing it here too would mix two problems in one
  first version.
- **No flow control.** WINDOW_UPDATE frames are read and ignored and none are sent.
  Safe only because the responses are small.
- **One stream's state at a time.** Sequential streams on one connection work and
  are checked; interleaved ones would be mis-served.
- **No streaming.** A handler answers once, so server-streaming and
  client-streaming methods are not expressible in its signature.

The DOCUMENTED-GAP that used to sit here — "no RPC status for an unknown method" —
is gone, and closing it worked the way it was meant to: the assertion of the gap's
*presence* failed and said it was stale. Three status routes are checked now
(unimplemented, a method that refuses its input, and a message needing
percent-encoding), and the python client reads the **raw** trailers, which is the
observation grpcurl cannot give — it prints the decoded message and the rendered
code name, so whether the encoding happened is invisible there.

### Two things loopback hid

Poisoning `grpc_parity.sh` found two bugs that every other section passed:

1. **Removing the frame reassembly changed nothing.** On loopback a request arrives
   in a single read, so a server that parses whatever one read gave it works. The
   python client now sends one request **split every seven bytes**, so the 9-byte
   frame header itself lands across two reads.
2. **Removing the SETTINGS acknowledgement changed nothing.** Neither client blocks
   on it. The client now asserts the ACK arrives.

Both are the same shape as the guards found dead in `frame.mere`, from the other
direction: there, code nothing reached; here, behaviour nothing observed.

## Flow control, and streaming

Both directions of the flow-control window, `SETTINGS_MAX_FRAME_SIZE`, and gRPC
methods that send or receive more than one message.

### The limits bite in an order, and the first one is not a window

Every number below was measured against a python `h2` client before any of the
code existed:

| bound | bites at | what the client does |
|---|---|---|
| `wbuf` capacity, unchecked | 16385 | **nothing** — the write ran past the buffer and returned success |
| `SETTINGS_MAX_FRAME_SIZE` | 16385 | refuses the frame: `FrameTooLargeError` |
| the flow-control window | 65536 | accepts no more DATA until it sends `WINDOW_UPDATE` |
| **inbound**, the same window | 65536 | stalls at exactly 65535 with nothing from us |

**The first thing a large response needs is not a window, it is being cut into
frames.** A fix that added window accounting without splitting frames would still
have failed at 16385.

The `wbuf` row is the one with no symptom. `mem_copy_bytes` is a `memcpy` into a
bump-allocated arena that records no allocation sizes, so no layer below could
catch it — demonstrated with a sentinel: 32 bytes into a 16-byte allocation
changed the byte after it and reported 32. `send` takes the capacity now and fails
loudly. **A bound nothing enforces is not a bound.**

The write buffer holds **65536** bytes rather than 16384, and that is not for
speed. `SETTINGS_MAX_FRAME_SIZE` has a *minimum* of 16384, so a peer can only ever
raise it — with a 16384-byte buffer `min(peer, capacity)` was always the capacity
and reading the setting was a term that could not change the answer. The same dead
guard this directory already deleted once from `frame.mere`, except here making it
live is better than removing it: a peer that allows 32768-byte frames gets half as
many of them.

### Flow control makes the writer a reader

Before it, sending was a leaf: bytes went out and nothing came back. A send whose
window is exhausted has to **consume input** — the `WINDOW_UPDATE` that reopens it
— so `send_data` contains a reader. That reader is deliberately narrow: a HEADERS
frame arriving there is a second request interleaved with the first, which this
server does not serve, and it **fails and names that** rather than skipping the
frame. A skipped HEADERS is a request that never gets an answer.

### The advertised window is left at the default on purpose

Raising `SETTINGS_INITIAL_WINDOW_SIZE` in our own SETTINGS would let large requests
through with no `WINDOW_UPDATE` logic at all — and would therefore make that logic
untestable. The small default window is what keeps the gate able to fail.

### Streaming is the list having more than one element

The handler takes the request's messages as a `bytes list` and answers with
`RpcOk` (one), `RpcStream` (many), or `RpcErr`. There is no separate code path for
client-streaming: a DATA payload is a stream of length-prefixed messages, so
splitting it is the same work either way. `H2Server.unary` adapts a
one-in-one-out handler.

**Interleaving is not supported and is stated rather than approximated.** The
handler runs after the request half-closes, so no reply can precede the last
request message.

### Four things the gate had to be taught, three of them by being wrong first

- **The boundary in the field is not the boundary on the wire.** A 16384-byte reply
  *field* is 16393 bytes of DATA once the gRPC prefix, the protobuf tag and a
  3-byte varint are added — so it already needs two frames. The first frame-count
  expectation was wrong for this reason, and so, later, was a window grant that
  left the server nine bytes short.
- **A well-behaved client cannot see a server that ignores its window.** Poisoning
  the window check to "a billion bytes" left the whole section green: a client that
  acknowledges as it reads has already granted more credit by the time the next
  chunk is processed. The gate now includes a **rude** client that advertises 8192
  and stops reading, and measures how much arrives before it acknowledges anything.
- **`SETTINGS` adjusts a spent window by the delta; it does not reset it.** Those
  two rules agree exactly when nothing has been spent, which is where the first
  version of the test put the SETTINGS. It now arrives mid-response, with the
  window driven to **-57343** — negative is legal, and a SETTINGS reduction after
  credit was spent is the only way to get there.
- **`h2`'s `local_settings.initial_window_size = ...` is silently ignored** before
  `initiate_connection`. The client advertised the default 65535, the server
  correctly sent 65535, and the harness blamed the server. `update_settings` is the
  API — and it makes the frame arrive mid-connection, which is what the delta path
  needed anyway.

### An export list is not a coverage list

`H2.read_settings` read each SETTINGS entry's 32-bit value at offset `i+4` instead
of `i+2` — two bytes past every six-byte entry, so the **last entry of any payload
read off the end**. It had been wrong for as long as the file existed.

Nothing caught it because **nothing called it**. The writer had a parity section
from the start; the reader was exported, documented in the table above, and never
fed a single byte — and this server's own comment said its peer's settings were
"read and ignored". The first caller found it on the first connection, at byte 42
of a 42-byte payload.

So the fix was not only the offset. Enumerating every export and counting call
sites turned up a second accessor in the same state — `H2.error_code`, zero callers
and zero coverage. It happens to be right; it had not been checked. Section 2d of
`http2_parity.sh` now feeds every payload accessor, and poisoning the original
off-by-two turns it red.

### One rule, written twice

A `WINDOW_UPDATE` increment of 0 is a protocol error. The frame loop **ignored**
it and the window-wait loop **failed** on it — two spellings of one rule, and the
wrong one was on the path every ordinary frame takes. There is one
`apply_window_update` now, and the gate sends a hand-built illegal frame, because
no conforming client will.

A related find, from a poison in a *different* rule: the SETTINGS branch of the
window-wait loop **recursed** under a comment saying it returned to its caller. A
peer may reopen a stalled stream with `SETTINGS` alone and send no `WINDOW_UPDATE`
at all, and this server would have waited forever. The delta poison was
undetectable precisely because the poisoned server got stuck in the same place.

## Not here yet

- Stream state, priority, `CONTINUATION` reassembly.
- Concurrency (one connection at a time), and interleaved streams.
- Server-side TLS and ALPN — needed for `h2` over TLS, not for h2c.
- **Huffman *encoding*.** Not needed (see above), and its absence is a size
  question rather than a correctness one.
- **Interleaved bidirectional streaming.** Many messages in each direction work;
  a reply that must react to a request message *while more are arriving* does not.
- **`SETTINGS_MAX_FRAME_SIZE` cannot be checked by conformance.** Its minimum is
  the default, so a peer can only ever raise it — ignoring it forgoes fewer frames
  and can never produce an illegal one. It is honoured, and the gate checks it
  behaviourally rather than as a conformance rule.
- **Which frame types may appear on which streams** is a rule of its own and is
  not enforced here. hyperframe does enforce it, and refusing to build a SETTINGS
  frame on stream 1 is how the gate found that out.
