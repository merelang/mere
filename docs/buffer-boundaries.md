# Buffer boundaries

ByteBuf and StrBuf belong to their creating thread. Owner reads leave them
writable. A foreign storage read permanently makes them shared and read-only,
including empty storage and a failed bounds check. Joining the reader does
not undo the mark. A rejected foreign write changes neither storage nor its
sharing state.

ListBuf has a different contract: push and conversion require its owner.
Conversion writes its frozen flag, even for an empty builder. Repeated owner
conversions are valid; a rejected foreign conversion does not freeze the
builder. An already-frozen push reports that state before ownership. Completed
immutable lists can be shared when their elements satisfy Send/Sync rules.

## Access inventory

| Path | Boundary |
| --- | --- |
| `bytebuf_new`, `bytebuf_of_bytes`, `strbuf_new`, `lb_new` | Establish caller ownership of new storage |
| `bytebuf_len` | Mark a read before inspecting length |
| `bytebuf_get` | At full application, mark before checking bounds or reading a byte |
| `bytes_of_bytebuf` | Mark before inspecting length or copying bytes, including an empty snapshot |
| `bytebuf_set`, `bytebuf_push` | Check ownership and sharing before bounds checks or mutation |
| `strbuf_len`, generic `len` on StrBuf | Mark before inspecting length |
| `strbuf_to_str` | Mark before inspecting length or copying text, including empty text |
| `strbuf_push` | At full application, check ownership and sharing before append, including an empty append |
| `lb_push` | After argument evaluation, check frozen state, ownership and current region before appending |
| `lb_to_list` | Check ownership before setting frozen state or accessing elements; another current region is allowed |
| Interpreter `show` and `to_json` | Check each visited buffer, including nested buffers; see [formatting ownership](memory-model.md) |

String and byte conversions produce independent immutable snapshots. Later
source growth or mutation does not change a snapshot. Sending only that
snapshot to another thread does not read or freeze its source. A ListBuf's
completed list remains stable because subsequent pushes are rejected; its
mutable element values are not recursively cloned by conversion.

Creating a partial application or wrapper does not access buffer storage.
The check runs when the remaining arguments have been evaluated and the
operation executes. A saved writer must observe the current shared/frozen
state. Argument failure stops later argument effects and the operation itself.

## Regions and representation

ListBuf push requires its binding region to be current. A rejected push must
leave the builder usable after returning to that region. C checks the live
region identity. Interpreter checks its region identifier; LLVM and Wasm use
region depth. As of v0.1.706, RISC-V stores the creation depth at slot 1, after
the frozen flag at slot 0; payload elements begin at slot 2. Conversion skips
metadata and preserves insertion order. Its ownership guard still runs before
setting the frozen flag. A region check is required even without threads.

These runtime checks complement the frontend's region escape checks. They
do not synchronize a traversal against concurrent mutation or cover FFI
implementations that access storage outside the runtime helpers.

## Validation and limits

`python3 scripts/buffer_boundary_check.py --poison` checks explicit expected
stdout, empty stderr and successful exit on interpreter, C, LLVM and Wasm.
The catalogue covers both ByteBuf constructors, empty/full sources, failed
lookups, rejected writes, preserved contents, snapshots across growth, saved
writers, delayed reads, argument evaluation and failure, repeated ListBuf
conversion and region refusal/recovery. Direct builtin partials are
interpreter cases; explicit `fn` wrappers cover supported compiled forms.

`--rv-only --poison` runs the same supported cases on RV32 and RV64. The C
reference must first satisfy the explicit expected output, so agreeing with
an incorrect reference is a failure. Negative controls remove individual read,
owner, freeze and region boundaries, remove RISC-V helpers or reuse logical
thread identities. Guard-removal witnesses must complete with a visible
`allowed` result; a crash or timeout is not a successful control.

The existing Wasm and RISC-V buffer matrices retain their specialized growth,
alignment, coroutine and worker coverage. Recursive formatting is covered by
`container_format_owner_check.py`; formatting support differs by backend.
Required tools and unsupported cases inside the declared catalogue are errors,
not silent skips. The two common modes are required CI gates in the existing
containers and RISC-V ownership groups.
