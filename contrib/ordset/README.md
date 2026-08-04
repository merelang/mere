# ordset — a generic sorted set over an `Ord` key

A purely-functional (persistent) binary-search-tree set whose element type is
abstracted by two user traits — `Eq` (equality) and `Ord : Eq` (ordering). A
consumer supplies `impl Eq T` and `impl Ord T` for its key type `T` and gets a
sorted set for free; the same tree code runs at every instance type.

```mere
import "github.com/merelang/mere/contrib/ordset/ordset.mere";

derive (Eq, Ord) int;   // structural instances from the traits' defaults

let s = Ordset.to_list (Ordset.of_list [5, 3, 8, 3, 1]);  // [1, 3, 5, 8]
```

`Eq` / `Ord` carry structural defaults (`a == b` / `a < b`), so a key type whose
builtin comparison is the intended ordering can be `derive`d. A key type that
wants a *custom* ordering supplies its own method bodies instead:

```mere
type color = Red | Green | Blue;
let rank = fn c -> (match c with Red -> 0 | Green -> 1 | Blue -> 2);
impl Eq color  { eq = fn a -> fn b -> rank a == rank b; }
impl Ord color { lt = fn a -> fn b -> rank a < rank b; }
```

Traits and the `'a tree` type are **global** even though they are written inside
`module Ordset` (Mere keeps traits/types global; a `module` only namespaces its
functions). So a consumer writes bare `impl Ord T` but calls `Ordset.of_list`.

See `../../examples/ordset_demo.mere` for a consumer that instantiates the set
at both `int` and a user-defined `color` variant.

## API (`t = 'a tree`)

| function | type | notes |
|----------|------|-------|
| `empty`   | `unit -> t`        | a thunk — see below |
| `insert`  | `t -> 'a -> t`     | ignores duplicates |
| `member`  | `t -> 'a -> bool`  | |
| `of_list` | `'a list -> t`     | |
| `to_list` | `t -> 'a list`     | in-order = sorted, deduped |
| `size`    | `t -> int`         | |

## Dogfood pain (what this exercised in the compiler)

This library was written to dogfood the trait system as a *reusable, generic
library*. It surfaced:

1. **traits / impls could not live in a `module` body** — the parser allowed
   only `let` / `let rec` / nested `module`. Fixed upstream: `trait` and `impl`
   are now allowed in module bodies (kept global, like `type`).
2. **a `type` inside a `module` produced spurious non-exhaustive-match
   warnings** — the module-qualified constructor names (`Ordset.Leaf`) weren't
   normalized against the bare-registered variants. Fixed upstream.
3. **a top-level polymorphic *value* binding breaks the LLVM backend** — an
   `empty = Leaf : 'a tree` constant has no use site to fix `'a`, so LLVM emits
   an unrepresentable `'a`. Worked around by exposing `empty` as a thunk
   (`empty ()`), which monomorphizes per use. (A known "poly value can't
   monomorphize" limitation, not specific to this library.)
4. **no `derive`** — originally `Eq` / `Ord` instances were hand-written per key
   type. Resolved: traits carry structural defaults and `derive (Eq, Ord) T;`
   generates the empty instances that inherit them.
