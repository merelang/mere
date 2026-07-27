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

See the header of `gen.mere` for the API and the known limitation
(one element type per program).
