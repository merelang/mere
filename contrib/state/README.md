# contrib/state — mutable state that says what it is

Two modules, and the choice between them is the whole point.

| file | for | API |
|---|---|---|
| `cell.mere` | a slot nothing is derived from | `cell_new` / `cell_get` / `cell_set` |
| `store.mere` | state the screen is a function of | `store_new` / `store_get` / `store_watch` / `store_set` / `store_update` |

## Where this came from

Mere has no mutable cell, and every browser client here built one the
same way: a vec allocated once, pushed once, then read and written at
index 0. It works — the bump arena is page-lifetime, so the slot survives
across event firings — and by v0.1.170 there were ten of them across four
apps, each with a comment explaining the trick.

```mere
let filter_timer = vec_new () in
let _ = vec_push filter_timer 0 in
... vec_get filter_timer 0 ... vec_set filter_timer 0 t ...
```

Naming that is `cell.mere`, and it is the smaller half. The noise was
never the real problem.

## The real problem

`examples/profile` was written first with three of those cells and a
`refresh_summary ()` call after every mutation — seven of them, the last
added during debugging. Every one is a place where the screen agrees with
the state only because a human remembered to say so, and nothing detects
the one that gets forgotten.

A store holds one value and a list of watchers. `store_update` writes and
then tells them:

```mere
let model = store_new (Model { saved = blank, current = blank }) in

let _ = store_watch model (fn (m: Model) -> paint_summary m) in

// every mutation site, in full:
let edit = fn (f: Field) -> fn (text: str) ->
  store_update model (fn (m: Model) -> { m | current = f.set m.current text })
in
```

The seven calls became zero. The screen stopped being something the
mutation sites maintain and became a function of the state, which is the
only arrangement that cannot drift.

`store_watch` runs the watcher immediately with the current value, since a
watcher is a function of the state and has to run once to make the screen
true.

## When a cell is still right

`examples/tasks` keeps four cells and no store, on purpose. Its screen is
not derived from its state — it is *reconciled* against it: rows that
stopped matching are removed one at a time and rows that started matching
are appended, so that the row being typed into is never rebuilt. A watcher
that redrew on every write would destroy exactly the thing that app exists
to protect.

Two of its four cells are a pending timer handle and a retry delay, which
nothing renders at all. There is nothing to derive from those, and a
watcher would be ceremony.

## Limitations

- **Watchers must not update the store.** Nothing detects it; the result
  is unbounded recursion.
- **No unsubscribe.** The watcher list only grows, which suits a page that
  wires its handlers at startup and then runs.
- **No equality check.** Every `store_set` notifies, even with an
  unchanged value. Adding one would need `S` to be comparable.
- **Not thread-safe.** A store is a pair of vecs with no synchronisation.
  For state shared across threads, see the actor pattern in `mkv`.

## Position

Stage 2 contrib (incubation). See [contrib/README.md](../README.md) for the
lifecycle. `test/parity/store_watch.mere` locks the store's behaviour —
watcher order, immediate first run, read-modify-write, two stores at
different types — across all four backends.
