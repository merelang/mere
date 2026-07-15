# Memory management model (mere)

A summary of Mere's memory-management strategies, how `mere` currently handles them, and what's planned. Deeper design notes live in separate internal notes.

---

## 1. Comparison of memory-management strategies

| Strategy | When is memory freed? | Examples | Strengths | Weaknesses |
|---|---|---|---|---|
| **Manual (malloc/free)** | The programmer calls `free` each time | C | Maximum control | Frequent use-after-free / leaks |
| **GC** | A runtime garbage collector decides | OCaml, Java, Go, Python | Safe, easy | Pause times, memory overhead, poor for real-time |
| **Ownership (move + borrow)** | Automatically at scope exit | Rust | Compile-time guarantees, zero cost | Cyclic / self-references are painful; learning curve |
| **Region (bulk per-region)** | The whole region scope is freed at once | Cone, Vale, Cyclone, ML/Talpin research | Fast alloc / bulk free; cyclic refs OK | Requires designing region lifetimes |
| **Stack-only** | At stack-frame exit | C autos, Rust `let` | Zero cost | Strict size/lifetime constraints |

Mere is designed to let you **mix and match**: the programmer chooses a strategy explicitly, and the compiler verifies safety.

---

## 2. Mere's memory strategies (5)

Based on the design note `01_memory_model.md`:

### ① `owned T` — sole ownership

A value has one owner; freed when the owner leaves scope. Equivalent to Rust's `T`.
```
let x: owned String = String.from("hello")
let y: owned String = x    // move; x is no longer usable
```

### ② `&borrowed T` — borrow

Pass a reference without transferring ownership. Equivalent to Rust's `&T` / `&mut T`, except Mere plans to **refine the borrow annotations** (`&shared write` etc.; design Q-004).

### ③ `region R { ... }` — bulk per-region

Values placed in region R are freed all together when R is destroyed. Bump-allocator backed. Only Trivial types (no Drop) can live in a region. **Unified with `arena` under Q-008.**

### ④ `view V[R] of T` — self-referential views (Q-009)

A "bundle type" built inside a region: immutable, non-moving. Lets you express self-references without `unsafe`.
```
view DocumentView[R] of Document {
  own:    &R Document,
  tokens: &R [&R str],    // points into own.text
}
```

### ⑤ `stack { ... }` — stack-only

Guarantees the value lives only on the stack. No heap allocation.

---

## 3. Why region (in detail)

### Problems it solves

Areas where Rust's ownership struggles:
- **Self-referential structs** (`Pin<T>` + `unsafe`)
- **Graphs / cycles** (escape into Rc/RefCell)
- **Bulk short-lived allocations** (overhead of individual frees)
- **async + lifetimes** (lifetimes threaded across function calls)

Region resolves these via **bulk-free per region**.

### How it works

```
region R {
  // R is a bump allocator (just a pointer + size)
  let a = R.alloc(Node {...})    // one pointer bump
  let b = R.alloc(Node {...})    // ditto
  a.next = b                      // references freely valid inside the region
  b.next = a                      // cycle is fine
  // ... computation ...
}  // The whole region's memory is freed at once — no individual destructors
```

### Typical uses

- **Parsers / compilers**: one input = one region; AST is built, then freed in bulk.
- **One frame of a game**: per-frame region; everything dropped at frame end.
- **Request handlers**: one request = one region; freed after response.
- **Transactions**: a region per transaction boundary.

### The Trivial constraint

Only "types without Drop" (Trivial) can be placed in a region. Why: bulk free without invoking individual destructors. Types that have Drop (DB connections, file handles, etc.) are managed separately via `with` (Q-011 resolved):

```
with db = Database.connect(...) in
  region R {
    let nodes = ...   // many allocations into R
    process(db, nodes)
  }
  // R is destroyed (Trivial only; no destructors)
// db.drop() runs (it has Drop, so it's released individually)
```

---

## 3.5 Region blocks reclaim values (v0.1.30–31, implemented)

The "one request = one region" use case above is no longer aspirational —
as of v0.1.31 it is the implemented semantics on the C backend:

- **Value allocations follow the current region.** Strings, cons cells,
  and variant nodes allocate in a thread-local *current region*. A
  `region R { ... }` block makes itself current for its body, so
  everything the body allocates is reclaimed when the block exits.
  Closure environments and container structs (Vec / Map / StrBuf) stay in
  their own binding region — they carry identity and must not die with a
  scratch block.
- **The block's result is copied out** into the enclosing region
  (per-type deep copy, specialized like the `show`/`==` derive family),
  so returning a value from a block is always safe. A container cannot be
  a block result — the typer's region-escape check rejects it.
- **Containers own their contents** (v0.1.30 copy-on-store): `map_set`
  deep-copies the key and value into the map's own region; `vec_push` /
  `vec_set` copy the element. A stored value therefore outlives whoever
  stored it, no matter where it was allocated. Strings are immutable, so
  the copies are unobservable.
- **Channel payloads copy through a per-message region**: `channel_send`
  deep-copies into a malloc-backed message region; `channel_recv` copies
  out into the *receiver's* current region and frees the message. A
  sender's scratch region can die while the message is in flight.
- Measured effect: an idiomatic line-at-a-time counter with a per-line
  region runs at constant ~1.5 MB RSS over 8M lines (previously 246 MB);
  a Redis-wire KV server with per-command regions holds flat RSS under
  sustained load.

Backend note: the interpreter is GC-backed (same value semantics, memory
behaviour trivially fine); the Wasm backend still uses page-lifetime bump
allocation — browser-scale programs are unaffected, and a long-lived Wasm
server would need the v0.1.31 treatment ported.

---

## 4. Current state in mere (as of 2026-06-24, Phase 46)

The "Phase 2" section below is a record of the first implementation slices (the region/view syntax layer). **Phase 11 → 31 implemented the 4 borrow modes (`&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T`) + borrow checker + `with` Drop integration + the 4 Q-010 collections (`Vec` / `OwnedVec` / `StrBuf` / `Map`) + 4-backend codegen (interp + C / LLVM / Wasm) parity.** Details: [language-reference.md §3 region/view/with](language-reference.md) / [codegen.md §4](codegen.md).

**Added in Phase 36 (2026-06-22)**: a narrow value restriction in the typer. `let v = map_get m k in ...`-style **let-binds through mutable containers** are no longer generalized (so `'a` doesn't leak). Details:
- `is_value e` decides whether an expression is in value form (literal / fn / Var / Tuple of values / etc.).
- `ty_mentions_mutable_container t` decides whether a type contains `OwnedVec[T]` / `Map[R, K, V]` / `StrBuf[R]`.
- Generalization is suppressed only when both fail (non-value AND contains a mutable container).

This is a narrowed variant of ML's standard value restriction (limited to types involving mutable containers) — ordinary fn lets like `let inc = fn x -> x + 1` remain polymorphic.

**Added in Phase 38.G-1 (2026-06-22)**: **automatic scope-bound Drop** for `let v = owned_vec_new () in body` (Level 1). Implements N1 of the N1/N2/N3 decomposition from the `39_nll_linear_design.md` design notes:

- If body doesn't let v escape lexically, `free(v->data)` is auto-emitted at scope end (same shape as the Phase 15.13 `with`).
- Static analysis: `no_value_leak v body` (v doesn't appear inside Tuple / Constr / Record_lit / Fun) + `tail_does_not_return_v v body` (body's tail expression's type doesn't include OwnedVec).
- If both pass → auto-Drop; if either fails → fall back to the existing registry + main-end sweep (safe-by-default).
- Implemented in C + LLVM; Wasm uses a bump-arena scheme that doesn't need per-allocation free.
- Level 2 (NLL Light: drop at last use) and Level 3 (Full Linear: static use-after-move detection) remain deferred (see DEFERRED §1.3).

This is a compromise from Mere's "explicitness > brevity" philosophy: explicit `with` is still supported and recommended (for custom Drop types), and the typical OwnedVec pattern (build → query → return scalar) gets auto-Drop.

### What works (Phase 2: syntax + value expressions + escape check + view declarations + region-enforced construction + field-access region propagation)
- `region R { body }` — introduces R as a region name in scope.
- `&R T` — region-tagged reference type.
- `&R v` — region-tagged value expression.
- **Escape check** — if R leaks into the type of `region R { body }`'s body, it's a compile error.
- `view V[R] of T { fields }` declarations.
- **View region enforcement** (Phase 2.3) — view construction allowed only inside a region block.
- **Type-level region tag on view values + field-access region propagation** (Phase 2.4) — a view value's type carries the construction-time region as `Name[R]`; field accesses / record updates substitute it with the actual region. The view value itself is subject to escape checking (cannot leave the region).

```
> region R { 42 }
- : int = 42

> fn (x: &R int) -> x
- : (&R int -> &R int)

> region R { let x = &R 5 in 42 }
- : int = 42                              // &R used inside, but result is int → OK

> region R { &R 5 }
ERROR: region escape: `&R int` cannot leave region `R`

> region R { region S { 100 } }            // nesting OK
- : int = 100

> view Node[R] of int { value: int, next: int };
  region R { let n = Node { value = 1, next = 0 } in n.value }
- : int = 1                                // view construction is only inside a region

> view Slot[R] { item: &R int };
  region S { let s = Slot { item = &S 42 } in 100 }
- : int = 100                              // R is substituted to S

> view Node[R] of int { value: int };
  let n = Node { value = 1 } in n.value    // outside any region
ERROR: view Node must be constructed inside a region block
```

### What doesn't work yet

- **Child regions (`region S of R { ... }`)** — promotion across nested regions.
- **Integration of `with` + Drop** — lifecycle of Drop-bearing caps.

### Why "syntax only"

`mere` is a **tree-walking interpreter** written in OCaml, and in interpreter mode the actual memory management is done by OCaml's GC.

**In Phase 4 codegen (C output), region becomes a real bump allocator** (achieved 2026-06-18, Phase 4.17). `region R { body }` initializes the C runtime's `__lang_region`; `&R v` (sugar for `R.alloc(v)`) bump-allocates inside the region and returns T*; leaving the scope releases it all at once. Combined with the typer's escape check, leaving a region scope frees memory while the type signature guarantees no `&R T` value has leaked. Details in [codegen.md](codegen.md)'s Phase 4.17.

---

## 5. View types — self-referential / cyclic structures inside a region

A region is "a box that shares the same lifetime"; we also need a way to safely express **structures that point at each other inside** (graphs, linked lists, ASTs, JSON trees, etc.). That's what **view types** are for.

### Motivation: weak spots of ownership

```
// In Rust this is nearly unwritable: two mutually-referencing nodes
let a = Node { value = 1, next = ??? }  // want ??? to be b
let b = Node { value = 2, next = a }    // but a should also point to b
```

In ownership-based languages, cyclic references are fundamentally hard (`Rc<RefCell<T>>`, `unsafe`, custom arenas, etc.). Inside a region, **everyone shares the same lifetime**, so cycles are fine. View types capture this "in-region relational structure" as a type.

### Three axioms (Q-009 paper-validated)

| Axiom | Meaning |
|---|---|
| **immutable** | View values cannot be modified after construction; cannot be reassigned. |
| **region-scoped** | Always tied to some region R; cannot leave R (the type bakes in `[R]`). |
| **structural identity by region** | Same-typed views inside the same region are identified — this is the basis on which cyclic references work safely. |

### Difference from records

```
type Point = { x: int, y: int };       // ordinary record: lifetime via GC; region-independent
view Node[R] of int { value: int };    // view: bundle type tied to region R
```

- A record is just data. A view is a structure **with the region tag baked into the type** (the `[R]` in `Node[R]`).
- Field types can include `&R T`: `view Node[R] of int { next: &R Node[R] }` for self-reference.
- View values can only be accessed through `&R Node` (structural identity is per region).

### Why "view"?

The physical layout (the inner type `of T`) and what the programmer manipulates (the `Node` type) are **viewed as different things**. Enables expressions like "internally a sequential int, but viewed as a Node struct" (a planned future feature).

### Current state (Phase 2.4, 2026-06-17)

View construction is **restricted to inside a region block**; the region parameter `R` at the declaration site is substituted with the innermost active region's name at construction time; and **the view value's type itself carries the region tag as `Name[R]`**. Field accesses / record updates propagate the region, and the view value is subject to escape checking.

```
view Node[R] of int { value: int, next: int };
region R { let n = Node { value = 1, next = 0 } in n.value }    // 1

view Slot[R] { item: &R int };
region S { 
  let s = Slot { item = &S 7 } in
  s.item                                                         // : &S int (R → S propagation)
}                                                                // ERROR: &S int would escape

region S { 
  let s = Slot { item = &S 7 } in
  let take_s = fn (x: &S int) -> 99 in
  take_s s.item                                                  // 99 (s.item is &S int)
}

region S { Cell { v = 1 } }    // ERROR: Cell[S] cannot leave region S
let n = Node { ... }            // ERROR: must be inside a region block
```

### Tightening planned for later phases

- Cyclic construction within the same region (a two-phase model: mutable construction phase + immutable use phase).
- Making views reachable only through `&R V` (currently the view value appears in types directly).
- Q-009's "structural identity by region" axiom (a strict semantics that identifies same-typed views).

The detailed design lives in the internal design notes (Q-009 resolved).

---

## 6. Roadmap

### Phase 2 (medium-sized, ~600-800 LoC, multiple slices) — in progress
- [x] `&R v` value expressions (Phase 2.1, 2026-06-16).
- [x] Region escape check (`&R T` cannot leak outside R, Phase 2.1).
- [x] `view V[R] of T { ... }` declarations (Phase 2.2, 2026-06-16, Q-009 paper-validated).
- [x] Region enforcement on view (construction only inside a region + R is substituted to the active region at construction, Phase 2.3, 2026-06-16).
- [x] Type-level region tag on view values + field-access / record-update region propagation + escape check on views (Phase 2.4, 2026-06-17).
- [x] `R.alloc(v)` syntactic sugar (equivalent to `&R v`; parser inspects region_stack and desugars; Phase 2.5, 2026-06-17).
- [x] `Trivial[R]` type constraint (declare Drop types with `drop type Name = ...`; type error when a region holds a value containing such a type; Phase 2.6, 2026-06-17).

### Phase 3 (larger; some design needs to be revisited)
- [x] Refined borrow annotations: `&shared write` / `&exclusive write` (Q-004 resolved in Phase 11.1-11.3; the borrow checker covers all 4 mode × 4 mode = 10 conflict pairs by Phase 17.1/17.2).
- [ ] Child regions and promotion (`region S of R`, `R.promote(...)`).
- [ ] Region std-types like `Vec[R, T]` / `StrBuf[R]` (Q-010 narrowed).
- [ ] Mechanizing `with` + Drop ordering (per Q-011 resolved).

### Current state of borrow modes and concurrency safety (2026-06-23 update)

The syntax and borrow checker for all 4 borrow modes are complete (Phase 11-17). However, **with no concurrent backend yet**, type-level requirements that T be "internally safe" (Rust's Send/Sync) for `&shared write R T` are **not yet enforced**:

| Mode | Concurrency-safety requirement (future) |
|---|---|
| `&R T` (default = shared read) | Safe — read-only access on immutable T |
| `&shared write R T` | **Requires: T is internally safe** (atomic / Mutex etc.) — not yet enforced |
| `&exclusive R T` (= exclusive read) | Safe — single-thread access only |
| `&mut R T` (= exclusive write) | Safe — single-thread access only |

Concurrent-backend prerequisites are collected in DEFERRED §2.4. Currently Mere is **single-threaded interpreter + 3 single-threaded backends (C / LLVM / Wasm)**; `&shared write` is only a syntactic distinction and runtime-wise behaves like a plain `&R T` pointer. Introducing a concurrent backend (e.g. via OCaml domains / Wasm threads) is the trigger for adding Send/Sync-equivalent type bounds for T.

### Phase 4 (codegen)

In progress — see [codegen.md](codegen.md).

- [x] C codegen MVP (int + arithmetic + if + let, 2026-06-17).
- [x] Function lifting + recursion (factorial / fibonacci works, 2026-06-17).
- [x] Strings + print + concat (hello world, 2026-06-18).
- [x] Functions taking/returning str (2026-06-18).
- [x] Tuples + per-AST type annotations (2026-06-18).
- [x] Records / variants / pattern match (2026-06-18; includes polymorphic monomorphization).
- [x] Closure conversion + first-class functions (2026-06-18).
- [x] **Region runtime (bump allocator)** — the memory model in action, 2026-06-18.
- [x] `with` Drop execution codegen (2026-06-18; auto-invokes `close` at scope end).
- [x] View construction over region (2026-06-18; view values become bump-alloc + pointer).
- [x] Default-region closure env (2026-06-18, Phase 4.20; program-lifetime arena `__lang_default_region` is init/freed in `main`; closure env alloc moves to bump).
- [x] Default-region for strings / recursive variant nodes (2026-06-18, Phase 4.21; `__lang_str_concat` and recursive Constr's malloc go through the default region — user-visible malloc disappears entirely).
- [ ] Move to LLVM IR or Wasm.

---

## 7. Design context (in detail)

Specific design decisions live in the internal design notes:

| Doc | Content | Status |
|---|---|---|
| `00_design_principles.md` | Mere's philosophy and assumptions | — |
| `01_memory_model.md` | Overview of the 5 strategies | — |
| `02_json_parser_example.md` | Region's canonical use case | — |
| `03_lifetime_and_mutability.md` | Lifetime subtyping | — |
| `04_fundamental_tradeoffs.md` | Staged annotations, etc. | — |
| `08_effect_granularity.md` | Q-004 borrow refinement | narrowed |
| `11_region_vs_arena.md` | Q-008 unification | resolved |
| `12_drop_and_with.md` | Q-011 Drop ordering | resolved |
| `13_region_std_types.md` | Q-010 region std types | narrowed |
| `14_view_types.md` | Q-009 view-type axioms | resolved |

---

## 8. Academic roots

| Reference | Content |
|---|---|
| Tofte & Talpin (1997) | "Region-Based Memory Management" — the foundational region calculus |
| Cyclone (2002) | A research language that extends C with lifetimes and regions |
| Cone (2018-) | A modern language with region as a primitive |
| Vale (2020-) | Region + generational references |
| Mike Acton et al. | "Data-Oriented Design" — practical examples of frame-arena patterns |

---

Bottom line: Mere is designed to **map memory lifetime onto program structure** — looser than ownership but stricter than GC; permits cycles; predictable. Currently `mere` is at Phase 1 (syntax-only); the real power emerges in Phase 2+'s static checks + codegen.
