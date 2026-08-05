# contrib/gen — thread-backed generators

Lazy pull iteration (`make` / `next` / `take` / `fold`) built on the existing
concurrency primitives — one producer thread per generator, one
request/reply channel pair per pull. No coroutines or continuations in the
language: the producer simply blocks between pulls.

The payoff is recursive producers. A tree walk can `yield` from inside its
recursion:

```
import "contrib/gen/gen.mere";

let g = Gen.make (fn y -> walk y tree) in   // walk calls `y v` per node
Gen.take g 10                                // first 10 nodes, in order
```

A hand-written state machine would need an explicit stack for this; a plain
fold could not stop after 10 nodes without threading a countdown through the
recursion.

One pull costs two channel operations plus a thread wake-up (~5-7 us
measured). Use it for coarse-grained streams — lines, records, chunks, tree
nodes — not per-integer hot loops.

## Draining and early stop

Early stop is the point of a generator: `take 10` off a huge or endless
producer pulls ten elements and no more. That works on the interpreter, C, and
LLVM backends — a producer left parked between pulls is harmless there, because
the process exits and takes its threads with it.

**On the Wasm backend it is not harmless.** Each generator's producer runs in a
Web Worker, and a live Worker keeps the host process (Node) from exiting. A
generator that is only partially consumed leaves its Worker blocked on the next
pull forever, so the program hangs at the end instead of exiting. The library
has no cancellation — the producer is arbitrary user code parked mid-recursion,
which Mere cannot unwind. So on Wasm: **fully drain every generator** (`fold`,
or `take n` with `n` past the end) before the program finishes. `examples/gen_demo.mere`
does this and runs on all four backends. Early stop stays a native-only move
until the language grows a cancellation story.

See the header of `gen.mere` for the API and the other known limitation (one
element type per program — the module's functions are not re-generalized).
