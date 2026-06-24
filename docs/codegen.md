# Code generation (codegen)

Mere's code-generation strategy, the current state in `mere`, and what's planned. Because the **memory model** and **effect system** at Mere's core only show their real power once codegen is in place, Phase 4 progresses through this in slices.

---

## 1. What is codegen?

The process of transforming the source-language AST (or typed AST) into **another language or machine instructions**.

```
       parser              typer             codegen
source  ───▶  AST   ───▶  typed AST   ───▶  target
"1+2"        Bin(+,1,2)    .ty = TyInt        "1 + 2" (C)
                                              "i32.add" (Wasm)
                                              "addq" (x86 assembly)
```

The last stage of a compiler. Mere-ml started as parser → typer → **eval** (tree-walking interpreter); it now also has codegen running **in parallel with eval**.

---

## 2. Why do we need it?

### Performance

| Mode | Execution model |
|---|---|
| Tree-walking interpreter | Traverses the AST each time, looks up env, boxes/unboxes closure values, runs through OCaml's GC |
| C codegen (current) | Runs the native binary produced by the C compiler — register allocation, function calls are one `call` instruction |
| LLVM / Wasm (future) | Adds more optimization (inlining, dead-code elim, loop unrolling) |

### Distribution

Interpreter mode: distribute both the `mere` binary and `program.mere`.
Codegen mode: compile `program.mere` once and you have a self-contained binary.

### Letting the memory model shine

Mere's **region / view / Trivial[R] / `with` Drop** design ([memory-model.md](memory-model.md)) currently exists as type-level labels; under the hood, OCaml's GC actually manages memory.

```
// Current (interpreter):
region R { let n = R.alloc(Node { ... }) in ... }
// Reality: an ordinary object allocated on OCaml's heap, collected by the GC

// After codegen:
// region R push/pops a bump allocator and frees everything on scope exit
// Drop's LIFO execution becomes a mechanical reverse-order walk over a Drop list
```

As memory-model.md says:
> Region's real power (bump allocator, bulk free, cache locality) only emerges with **native codegen**.

### Becoming a self-contained language

In interpreter mode, "Mere runs on top of OCaml." Once we can emit native binaries via codegen, "Mere is a self-contained language." This is required by the design goal of "both native (LLVM) and Wasm" in the internal design notes.

---

## 3. Mere's codegen strategy

### Multi-stage approach

| Phase | Target | Status | Why |
|---|---|---|---|
| 4 (current) | **C** | In progress | The simplest intermediate language; clang/gcc are right there |
| 5 (future) | **LLVM IR** | Not started | More optimization opportunities; supports both native and JIT |
| or | **Wasm** | Not started | Browser execution + WASI for self-contained binaries |

### Why go through C?

- Easier than emitting LLVM / Wasm directly (C is "portable assembly").
- A C compiler is already on hand (clang/gcc are standard on macOS/Linux).
- Region runtime and GC helpers can be written in C and FFI-bound.
- When we later switch to LLVM IR, the C output serves as a "ground truth" for comparison.

### Per-AST type annotations (introduced in Phase 4 slice 5)

`Ast.expr` gains a `mutable ty : ty option`; `Typer.infer` records the inferred type on each node. This lets codegen directly read each node's type — tuple shape inference and fn signature inference become clean. The same foundation will be used for LLVM / Wasm migration.

---

## 4. Current state in mere (as of 2026-06-24, after Phases 4-46)

**Nearly the entire Mere syntax that's expressible in the interpreter** + **Q-010 collections (Vec / OwnedVec / StrBuf / Map)** + **FFI (`extern fn`)** + **float (3 backends)** + **Phase 36's 13 syntactic sugars** is native-compilable and runnable in 3 backends (C / LLVM IR / Wasm). **1551 tests pass**. End-to-end: factorial, fibonacci, linked-list sum, `make_adder` closures, polymorphic variant + record, pattern match (nested / guard / or). Phase 15 added all element types for Vec[R, T] / OwnedVec[T] / StrBuf[R] / Map[R, K, V] (K = int / bool / str / tuple / record / all variants) / higher-order API (vec_set / iter / fold / map / filter) / conversions (vec_to_owned / owned_vec_to_vec / vec_to_list) / `len` ad-hoc polymorphism / with-OwnedVec scope-Drop — all in 3 backends.

**Phases 24-27 (2026-06-21, 29 consecutive slices) reached 4-backend feature parity**: 16 realistic examples (~2500 LoC; toy_sql.mere alone is 1165 LoC) **match diff = 0 PERFECT across interp + C + LLVM + Wasm runtime**. Phase 27.2 added `scripts/run_wasm.js` (Node.js host harness providing puts / read_file / write_file imports), so Wasm is now runtime-verifiable. Phases 28-30 used dogfood (toy_sql) → unearthed 3 codegen bugs (DEFERRED §1.10 record field × nested-lambda capture / §1.11 env_subst shadow / §1.12 builtin shadow) → all fixed (across all 3 backends). Phase 31.0 ported str_compare to the 3 backends (sign-normalized -1/0/1).

### Codegen capabilities added in Phases 32-36 (2026-06-22)

| Feature | Phase | Backend status |
|---|---|---|
| `extern fn <name>: <ty>;` (FFI; curried multi-arg) | 32.0-32.6 | All 4 backends |
| Float MVP (Float_lit / `f_add` etc. / `f_neg` / `__lang_str_of_float`) | 34.1 (C) / 34.2 (LLVM) / 34.3 (Wasm) | All 4 backends |
| libm dispatch (sqrt / sin / cos / tan / f_pow / atan2) | 34.4-34.5 | All 4 backends |
| Nullary factory builtins as first-class values (eta-wrap) | 35.1 (C) / 35.2 (LLVM) / 35.3 (Wasm) | All 4 backends (DEFERRED §1.2 A1) |
| Phase 36 sugars (range / op section / `::` / `<|` / `@@` / `\` / interp / `?` / `?!` / list comp / `if let` / `for in do` / `while do`) | 36 | All 4 backends (parser/lexer-level desugar) |
| Narrow value restriction (don't generalize when let-binding types that contain mutable containers) | 36 (typer) | All backends |
| Fix for O(2^N) C codegen on deep list literals (cache `emit_expr arg` once in Constr emit) | 36 (DEFERRED §1.15) | C |
| `strbuf_to_str` dangling-pointer fix on region escape (switch to `__lang_default_region` alloc) | 36 (DEFERRED §1.16) | C / LLVM |
| Fix for user-shadowed `type result` crashing in `List.combine` | 36 (DEFERRED §1.17) | C |
| Phase 30.2 top-level global init-order fix (source-order inline init) | 36 (DEFERRED §1.18) | 3 backends |
| Nested lambda referencing top-level fn becoming unbound (closure_wrapper_forward_decls + fn_closure_table_idx pre-populate) | 36 (DEFERRED §1.19) | C / LLVM / Wasm |
| User records inside polymorphic variants forward-decl fix (unified topo sort) | 36 (DEFERRED §1.20) | C |
| Wasm memory bumped 16 → 64 pages (4 MB) | 36 | Wasm |
| 16 new prelude entries (range / list_filter / list_take / list_drop / list_find / list_append / list_concat / list_flat_map / list_zip / list_for_all / list_any / list_member / list_sum / list_product / list_max / list_min) | 36 (prelude) | All 4 backends |

### Codegen capabilities added in Phases 22-31

| Feature | Phase | Backend status |
|---|---|---|
| `try_or` (fail catch) | 22.2 (C) / 25.2 (LLVM) / 26.2 (Wasm) | All 4 backends |
| str_split / str_join / str_count | 22 (C) / 25.9 (LLVM) / 26.5 (Wasm) | All 4 backends |
| str_compare (sign-normalized -1/0/1) | 31.0 | All 4 backends |
| Per-instantiation specialization of polymorphic user let-recs | 23.3 (C) / 25.5 (LLVM) / 26.4 (Wasm) | All 4 backends |
| show_str escapes (`\n`, `\"`, etc.) | 23.5 (C) / 25.6 (LLVM) / 26.6 (Wasm) | All 4 backends |
| Variant boxed payload (`{i32 tag, ptr payload}`) | 24 (C unification) / 25.0 (LLVM) / 26.0 (Wasm) | All 4 backends |
| Inner let-rec lifting (sibling resolution even via anon closures) | 22.2 (C) / 25.3 (LLVM) / 26.3 (Wasm) | All 4 backends |
| Skel dedup (user-defined shadows prelude) | 24.2 (C) / 25.7 (LLVM) / 26.3 (Wasm) | All 4 backends |
| Map iter in insertion order | 27.1 (interp unification, propagated to 3 backends) | All 4 backends |
| Wasm runtime auto-print of main result | 27.2 | Wasm |
| Unit main_ty prints `"()"` | 25.11 (LLVM) / 27.0 (C reverse-port) / 26.x (Wasm) | All 4 backends |
| Wasm StrBuf containment (StrBuf in variant payload) | 27.3 | Wasm |
| Prepending pattern bindings to current_var_types in arm bodies | 28.1 (C; LLVM Phase 25.3 reverse-port) | All 4 backends |
| User-defined fn shadowing builtin (is_alpha/is_digit/is_space) | 30.0 | 3 backends (C/LLVM/Wasm) |
| `let` shadowing of captured names in closures (env_subst dance) | 30.1 (C) | C |
| Top-level non-fn let → file-scope global | 30.2a (C) / 30.2b (LLVM) / 30.2c (Wasm) | 3 backends |
| Wasm memory bumped 1 → 16 pages (1 MB) | 29.1 | Wasm |
| `extern fn <name>: <ty>;` (FFI for libc; curried multi-arg) | 32.0-32.6 | All 4 backends |

### What works

| Category | Support |
|---|---|
| Primitives | int / bool / str / unit |
| Arithmetic | `+ - * / %` (int), `-` (Neg) |
| Comparison | `== != < <= > >=` (int → int 0/1) |
| Logic | `&& \|\|` (lower directly to C short-circuit) |
| Strings | literals / `++` concatenation / `print` / `str_len` |
| Control | `if-then-else` (C ternary); `let` (GCC/Clang `__auto_type` absorbs the type) |
| Functions | Top-level fn lifting (`let f = ...` / `let rec f = ... and g = ...`), forward decls for self/mutual recursion, functions taking/returning str |
| Region | `region R { body }` implemented as a bump allocator (`__lang_region`); `&R v` (and the `R.alloc(v)` sugar) allocates in the region; bulk-released on scope exit. Combined with the typer's escape check + a real runtime, region's full power shows |
| with Drop | `with c = v in body` codegens with auto-invocation of `c.close ()`-equivalent at scope end (when the Drop type has a `close: unit -> unit` field). Multiple `with`s are nested in AST and naturally close LIFO |
| View | `view V[R] of T { ... }` becomes a bump-alloc + pointer (`V*`) representation over the region. Record_lit becomes `__lang_region_alloc(&__region_R, sizeof(V))` + copy + ptr return; field access uses `->`. The view value's lifetime matches the region scope |
| Tuple | C structs (auto-generated per shape, e.g. `tuple_int_str`) + C99 compound literals; `fst` / `snd` builtins |
| Record | Monomorphic `type Point = { x: int, y: int }` → `typedef struct {...} Point;`; supports construction (`Point { x = 1, y = 2 }`) / field access / record update |
| Variant | Monomorphic `type Status = Ok \| Err of str` → tagged union (`typedef struct { int tag; union { ... } payload; } Status;`); Constr → compound literal; match expanded into ternary chain + statement expression (`P_constr` / `P_var` / `P_wild` / `P_tuple` sub; no guards) |
| Recursive variants | Self-referential payloads (e.g. `type ilist = INil \| ICons of int * ilist`) get heap allocation + ptr representation (`typedef ilist_node* ilist;`); Constr mallocs the node and returns it; match dereferences via `__scrut->tag`; tuple payloads bind via `P_tuple (h, t)` against `.f0` / `.f1` |
| Polymorphic variant monomorphization | `type 'a list = Nil \| Cons of 'a * 'a list` and friends — concrete instantiations are collected from AST + fn signatures and a specialized struct is emitted per instance (`list_int`, `opt_str`, ...). Recursivity is judged on the substituted payload. So `[1, 2, 3]` literals and `'a list`-typed `sum` etc. run natively |
| Polymorphic record monomorphization | `type 'a Box = { v: 'a }` etc. specialize like variants (`Box_int`, `Box_str`, ...); Record_lit emit reads the mono name from `.ty` and emits e.g. `((Box_int){.v = 42})` |
| Polymorphic `show` builtin | For each `show` call, the argument type is collected and a specialized `show_T` C fn is auto-generated. Covers int/bool/str/unit/tuple/record/variant (monomorphic + polymorphic instantiations). **`'a list` is special-cased (`[1, 2, 3]` style)**; other recursive variants use `Cons (1, Cons (2, Nil))` style. asprintf-based; heap-allocates |
| Closure (defunctionalized) | Inner `let n = fn x -> body` is defunctionalized to top level. Free vars are prepended to the C fn's params; call sites are rewritten. Captures are restricted to int/bool/str/unit (tuple/record/function-value captures not yet supported). Multi-level nesting is fine |
| First-class fns (Phase A + B) | `T1 -> T2` types become closure structs (`{ void* env; T2 (*fn)(void*, T1); }`). Each top-level fn gets a `_closure_fn` adapter + `_as_value` const; anonymous Fun in expression position is lifted into env struct (heap-alloc) + adapter (`__anon_N_fn`) + closure construction, with captures rewritten to `__env_self->name`. Closure dispatch: `({ __auto_type __c = e; __c.fn(__c.env, x); })`. Direct call (Var head on a known top-level) still takes the fast direct-call path |

### What doesn't work (currently Codegen_error)

- **Phase 35 made nullary factory builtins (vec_new / map_new / strbuf_new etc.) usable as first-class values in all 4 backends** (eta-wrap). But **partial application of multi-arg curried builtins** (`let push_to_v = vec_push v in ...`) is still future work.
- **Auto scope-bound Drop for OwnedVec** — explicit `with v = ...` already frees at scope end; without it, bulk-freed at main exit (Phase 15.8 / 15.13; DEFERRED §1.3).
- Inner-lifted fns (`let h = fn ...`) used as VALUES (currently only direct calls; rewriting as an anonymous Fun works).
- Closure captures of non-primitive types (tuple/record captures; closure-value captures are fine).
- Nested or-patterns (or inside constructor / tuple / record).
- **Placing `while cond do body` directly under top-level main** — top-level Let_rec constraint; inside an fn body is fine.
- **String interpolation with nested string literals** (`"x = {show \"abc\"}"`) — workaround via a let binding.
- Some stdlib builtins (`read_lines` / `args` / `env_var` / `file_exists` etc.) are **interpreter-only**. Phase 34 brought float / libm (sqrt / sin / cos / tan / f_pow / atan2) to the 3 backends.
- GC for strings / closure envs / variant nodes (currently a region arena bulk-freed at main exit — suitable for short-lived runs).
- LLVM / Wasm with payload-mixed variants as Map K (uniform payload only) — C accepts mixed.

### CLI

```sh
# inline expression to C source
dune exec ./bin/mere.exe -- -ce '1 + 2 * 3'

# file to C source
dune exec ./bin/mere.exe -- -c examples/sample.mere > sample.c

# clang to native binary
clang sample.c -o sample
./sample
```

---

## 5. Phase 4 slices

| Slice | Content | What works |
|---|---|---|
| 4.1 | C codegen MVP | int + arithmetic + if + let |
| 4.2 | Function lifting + recursion | factorial / fibonacci / mutual recursion |
| 4.3 | Strings + print + ++ | hello world |
| 4.4 | Functions taking/returning str + `str_len` | `let exclaim = fn s -> s ++ "!"` |
| 4.5 | Tuples + per-AST type annotations | tuple-returning fns |
| 4.6 | Records (monomorphic) | `type Point = { x: int, y: int }` construction / field / update |
| 4.7 | Variants + match (monomorphic; simple patterns) | `type Status = Ok \| Err of str`; match expands into a ternary chain |
| 4.8 | Closure conversion (defunctionalization) | Inner `let h = fn ... in ...` lifted to top level; free vars prepended to params; call sites rewritten |
| 4.9-a | First-class fns (Phase A; top-level fn as value) | `T1 -> T2` becomes a `closure_T1_T2` struct; top-level fns get an adapter + `_as_value` const; HOFs take a closure arg and dispatch via `.fn(.env, x)` |
| 4.9-b | First-class fns (Phase B; anonymous Fun + captures) | Anonymous Fun in expr position is lifted to heap-allocated env struct + adapter + closure construction; captures rewritten to `__env_self->name`; curried HOF (`apply f x = f x`) / `make_adder` closures work |
| 4.10 | Recursive variants + P_tuple patterns | Self-referential variants (`type ilist = INil \| ICons of int * ilist`) get heap-allocated nodes + ptr typedef; Constr mallocs; match uses `->`; tuple sub-pattern binds `.f0 / .f1`. Linked-list `sum` runs natively via clang |
| 4.11 | Polymorphic variant monomorphization | `type 'a opt = None \| Some of 'a` / `type 'a list = Nil \| Cons of 'a * 'a list` etc. — concrete instantiations are collected from AST + fn signatures and per-instance specialized structs (`opt_int`, `list_int` etc.) are emitted. `[1, 2, 3]` literals + `'a list` sum work |
| 4.12 | Polymorphic `show` builtin | `show : 'a -> str` is specialized per call site into `show_T`. Covers int/bool/str/unit/tuple/record/variant (monomorphic + polymorphic instantiation + recursive). asprintf-based with cycle guard |
| 4.13 | Polymorphic record monomorphization | `type 'a Box = { v: 'a }` etc. specialize per type (`Box_int`, `Box_str`); Record_lit emit reads the mono name from `.ty` |
| 4.14 | Complex patterns (P_int / P_str / P_bool / P_record / nested / P_as) | Match pattern compilation rewritten with fully-recursive `compile_pattern`; each pattern reduced to (test, bindings); constructor can nest constructor/tuple/record; record patterns destructurable |
| 4.15 | Or-patterns + match guards | `\| pat1 \| pat2 -> body` pre-flattened into multiple arms (typer ensures both branches bind the same name set); guards evaluated in the arm's binding scope; falls through on false |
| 4.16 | `'a list` show as `[1, 2, 3]` + variant payload tuple-shape collection | `type 'a list` is special-cased so `show` prints `[1, 2, 3]`. Tuple shapes inside variant payloads (`tuple_int_list_int` etc.) are included in tuple shape collection, so structs are emitted even if no Cons appears in the AST (empty-list case) |
| 4.17 | **Region runtime** (bump allocator) | `region R { body }` implemented in C: `__lang_region` struct (`{ char* base; char* top; size_t cap; }`) + `__lang_region_init/alloc/free` helpers; `region R { ... }` emits init + body eval + free; `&R v` bump-allocates in the region and returns T*. `c_type_of (TyRef _ inner)` becomes `inner*`. Combined with the typer's escape check, leaving a region scope frees memory — **the memory model graduates from "type-level label" to "real bump allocator"** |
| 4.18 | `with` Drop execution + typedef reordering | `with c = v in body` codegens: at scope end, `c.close.fn(c.close.env, 0)` is auto-invoked (only when the Drop type has a close field). Typedef layout reorganized into "all forward decls → closure typedefs → all struct bodies" so a record / variant with a `closure_T1_T2` field (e.g. a Drop type's `close: unit -> unit`) can still let closures reference the record definition as a function-pointer return |
| 4.19 | View construction over region (bump alloc + ptr) | View values codegen as `V*` (a region-internal pointer). New `is_view_type` helper; `c_type_of` maps view name to `V*`; Record_lit for a view becomes `__lang_region_alloc(&__region_R, sizeof(V))` + body copy + ptr return; Field_get on a view uses `->`. View value lifetime is bound to region scope (combined with Phase 2.1 escape check + region runtime) |
| 4.20 | **Closure env in default region** | A program-lifetime arena (`__lang_default_region`) is added at file scope; `main`'s prologue initializes 4 MB; the epilogue frees. Anonymous closure env struct alloc switches from `malloc` to `__lang_region_alloc(&__lang_default_region, ...)`. Closures live beyond a user's `region R { ... }`, so a separate arena is needed. Bump-alloc-ization lowers per-closure alloc cost; bulk-freed at `main` exit (valgrind clean) |
| 4.21 | **Strings / recursive variant nodes also use the default region** | The remaining 2 malloc sites consolidate into the default region: `__lang_str_concat`'s `malloc(la + lb + 1)` → `__lang_region_alloc(&__lang_default_region, la + lb + 1)`; recursive Constr emit (`Cons (h, t)` etc.) `malloc(sizeof(T_node))` → `__lang_region_alloc(&__lang_default_region, sizeof(T_node))`. Emit order rearranged to `region_runtime_helpers → str_concat_helper` so str_concat can reference the default region. The only remaining C malloc is the **region's base-buffer alloc** inside `__lang_region_init` — all user-visible allocations now live on a bump arena. `main` exit invokes `__lang_region_free(&__lang_default_region)` for bulk free; valgrind clean |

Each slice is **verified by clang-compiling to a native binary and running it** (e.g. factorial 10 → 3628800; `print (greet 5)` → "positive"; `fst ("hello", 42)` → "hello").

Detailed change history is in [changelog.md](changelog.md).

---

## 6. Roadmap

### Remaining work (see DEFERRED §1.2 / §1.3)

| Feature | What's needed |
|---|---|
| First-class value use of builtins | Emit per-T closure wrappers for `let f = vec_new in ...` (DEFERRED §1.2). Multi-slice effort |
| Auto scope-bound Drop for OwnedVec | NLL + move semantics (DEFERRED §1.3); design first |
| Nested or-patterns | Expand or inside constructors |
| Inner-lifted fn as value | Generate a closure form alongside `let h = fn ...` when `h` is used as a value (currently rewrite as anonymous Fun) |
| Complex closure captures | Tuple / record captures (currently int / bool / str / unit / function value only) |
| float | `Float_lit` / `f_add` etc. → C `double` + `%g` family |
| Long-running program support | Currently the arena is bulk-freed only at `main` exit. A sub-arena that can drop transient strings (e.g. `show` output) or a proper GC is needed for long-running processes |
| Remaining stdlib builtins | About 70 builtins (sqrt, str_replace, ...) ported to 3 backends |
| Payload-mixed variants as Map K on LLVM / Wasm | Loosen the uniform-payload MVP constraint (a larger change) |

### Phase 5 (LLVM/Wasm migration)

| Slice | Content | What works |
|---|---|---|
| 5.1 | **LLVM IR MVP** (own textual-IR emission) | int / bool / arithmetic / comparison / logic / Neg / If / Let (P_var) / Var / Annot converted to LLVM IR; `-ll` / `-lle` CLI flags; output via `@printf`; `clang out.ll` produces a native binary. If via phi nodes, compares via icmp, bool widened to i32 via zext |
| 5.2 | **Function lifting + recursion** | top-level `let f = fn x -> ...` and `let rec f = fn x -> ... and g = fn y -> ...` lift to `define iXX @f(iYY %x) { ... }`. `App (Var name, arg)` compiles to `call iZZ @name(iYY %arg)` (direct call only for known top-level fns; first-class fns are a later slice). Each fn's register/label counter is reset to avoid SSA name collisions. LLVM IR permits in-module forward references, so no C-style forward decls. factorial 10 = 3628800; fibonacci 15 = 610; is_even 7 = 0 (mutual recursion) all run natively via clang |
| 5.3 | **Strings + ++ + print + str_len + str-arg/return fns** | `TyStr` → LLVM `ptr` (opaque pointer). `Str_lit s` lifted to a private constant global (`@.str_N = private constant [N x i8] c"...\00"`); the global symbol is used directly as the value. `Bin (Concat, a, b)` becomes `call ptr @__lang_str_concat(ptr %a, ptr %b)`. `__lang_str_concat` defined inline in LLVM IR (malloc + strlen + memcpy + GEP + store 0). `print s` becomes `call i32 @puts(ptr %s)` with value 0. `str_len s` becomes `call i64 @strlen(ptr %s)` + `trunc i64 ... to i32`. `main_format_of` handles `TyStr → ("ptr", "%s")` and generates `@.fmt_s`. str-arg/return fns lower naturally. Verified clang-natively: `print "Hello, LLVM!"` → "Hello, LLVM!"; concat / str_len / greet examples all work |
| 5.4 | **Tuples + AST type-annotation foundation (LLVM)** | Tuples lower to LLVM named structs `%tuple_int_str = type { i32, ptr }`. `collect_tuple_shapes` walks AST + fn signatures to collect used tuple types and emit typedefs. `Tuple [e1; e2; ...]` becomes an `insertvalue` chain (starting from `undef`, inserting each element by index). `fst` / `snd` lower to `extractvalue %tuple_X %p, 0/1`. Nested tuples (`((1,2), 3)` → `%tuple_tuple_int_int_int`) auto-generate. Tuple-arg / tuple-return fns lower naturally. Verified clang-natively |
| 5.5 | **Records (monomorphic)** | Monomorphic records (`type Pt = { x: int, y: int }`) lower to LLVM named structs (`%Pt = type { i32, i32 }`). `collect_record_names` walks AST + fn signatures to collect used records (only `r_params = []`; polymorphic is later). `record_fields` / `field_index` read the field order from `Typer.records`. `Record_lit` emits an `insertvalue` chain in declared order (source order can differ). `Field_get` is `extractvalue %R %p, idx`; `Record_update` does an `insertvalue` chain over the base. Record-arg / return fns lower naturally. compile_to_c-shared infer_program populates Typer.records. Verified clang-natively. Polymorphic records still Codegen_error |
| 5.6 | **Variants + match (monomorphic; one payload type)** | Monomorphic variants lower to LLVM named structs: when all ctors are nullary, `%V = type { i32 }`; when there's a payload, `%V = type { i32, T }` where T is a single shared payload type (different types → Codegen_error). `variant_tags` Hashtbl holds constructor → int tag. `Constr cname (arg)` builds via `insertvalue %V undef, i32 tag, 0` → optional `insertvalue %V %t0, T arg, 1`. `Match` does `extractvalue %V %s, 0` for the tag, then each arm via `icmp eq i32 %tag, N` + `br i1` (P_constr / P_var / P_wild only); fallthrough → `@abort()` + `unreachable`; all arm results merged via `phi`. Payload binds use `extractvalue %V %s, 1`. Verified clang-natively. Guards / polymorphic variants / recursive variants / nested patterns / or-patterns still Codegen_error |
| 5.7-a | **First-class top-level fns** | `T1 -> T2` types lower to `%closure_T1_T2 = type { ptr, ptr }` (env, fn ptr). `collect_arrow_types` walks AST + fn signatures to collect used arrow types; `emit_closure_typedef` emits the typedef. Each top-level fn gets an env-ignoring adapter `define T2 @<name>_closure_fn(ptr %env_unused, T1 %x) { ret T2 @<name>(T1 %x); }`. `Var name` in value position, with no env shadow and on the toplevel_fn_names list, inline-builds a closure via `insertvalue %closure_T1_T2 undef, ptr null, 0` + `insertvalue ..., ptr @<name>_closure_fn, 1`. Indirect App (non-known top-level head) does `extractvalue %closure %c, 0/1` for env/fn and `call T2 %fn_ptr(ptr %env, T1 %arg)`. Direct call still uses Phase 5.2's fast path. `current_var_types` recovers polymorphic Var types in fn body from resolve_fn_types' concrete types. Verified clang-natively. Anonymous Fun + closure-with-captures is the next slice |
| 5.7-b | **Anonymous Fun + closure-with-captures** | Inner `fn x -> ...` in expression position: compute free vars (`free_vars` helper, excluding bound names); filter against current_var_types (excluding globals / builtins / top-level). For each capture, fetch type from current_var_types; generate env struct typedef `%anon_N_env = type { T1, T2, ... }`; queue an `anon_N_fn` adapter into `pending_closures`. At the construction site, `malloc(sizeof(%anon_N_env))` (sizeof via the LLVM null-trick GEP + `ptrtoint`) for env; each capture is `getelementptr` + `store` into env fields; the closure value is built via `insertvalue %closure undef, ptr %env, 0` + `insertvalue ..., ptr @anon_N_fn, 1`. `emit_anon_adapter` (called by `emit_program` draining `pending_closures`): in entry, captures are GEP-loaded from env_self into fresh registers, used to emit the Fun's original body. `current_expected_ty` added so that when AST's Fun.ty is polymorphic, the parent context's type serves as fallback. Let case adds value's type to current_var_types. Verified clang-natively. Env still mallocs and leaks — default-region migration is later |
| 5.8 | **Default-region runtime + closure/string allocations via region** | C codegen's Phases 4.17 + 4.20 + 4.21 done at once for LLVM: `%__lang_region = type { ptr, ptr, i64 }` + `@__lang_default_region` as a file-scope global + `__lang_region_init/alloc/free` helpers inline in LLVM IR. `__lang_region_alloc` is 8-byte aligned bump pointer (`(n + 7) & -8`). `@main` prologue does `__lang_region_init(@__lang_default_region, 4194304)` (4 MB); epilogue does `__lang_region_free`. `__lang_str_concat`'s `malloc` → `__lang_region_alloc(@__lang_default_region, ...)`. Closure env (anonymous Fun) malloc likewise. Only remaining malloc is inside region init's base-buffer alloc; on `main` exit, `__lang_region_free` calls `@free` in bulk. Verified clang-natively. 8 tests; total 855. LLVM backend's memory-model story catches up to C |
| 5.9 | **Polymorphic variant / record monomorphization** | `type 'a opt = None \| Some of 'a` etc. (polymorphic variants) and `type 'a Box = { v: 'a }` etc. (polymorphic records): collect concrete instantiations from AST + fn signatures and emit per-instance specialized structs (`%opt_int`, `%Box_str`, ...). `polymorphic_variants` / `polymorphic_records` Hashtbls defer declarations; `collect_mono_instances` walks AST to find `(name, args)` pairs, accumulating into `mono_variant_instances` / `mono_record_instances`. `subst_params` / `subst_variants` do param → arg substitution; `mono_variant_name n args` / `mono_record_name n args` produce specialized names. `emit_mono_variant_typedef` / `emit_mono_record_typedef` resolve substituted fields/payloads via `llvm_ty_of` to emit typedefs. `llvm_ty_of (TyCon (n, args))` maps polymorphic-variant / record names to their mono name. Constr / Record_lit / Field_get / Record_update / Match emit pull mono names from `.ty`. `Exhaustive.type_variants` + `Typer.constructors[*].params` recover poly-variant params; `Typer.records.r_params` provides poly-record params. Verified clang-natively. Recursive polymorphic variants (`'a list`) need recursive-variant support — Phase 5.10 |
| 5.10 | **Recursive variants + P_tuple sub-patterns** | Self-referential payload variants (`type ilist = INil \| ICons of int * ilist`, `'a list = Nil \| Cons of 'a * 'a list`) switch to heap-allocated node + ptr representation. `recursive_variants` set tracks names; `variant_is_recursive` (source-level) and `mono_variant_is_recursive` (substituted instance) judge; populated in 2 passes at declaration-registration time + mono-instance-collection time. `emit_variant_typedef` / `emit_mono_variant_typedef`: when recursive, emit `%V_node = type { i32, T }` (heap node); value type is `ptr` (`llvm_ty_of` returns `ptr` for recursive_variants). Recursive Constr: `__lang_region_alloc` for node + `getelementptr` + `store` for tag/payload + return ptr. Recursive Match: `getelementptr` + `load` for tag/payload via the scrutinee ptr. Pattern-compile adds P_tuple sub-pattern → `extractvalue` chain on payload tuple struct. `pattern_var_types` adds bound names' concrete types to current_var_types (so polymorphic recursive calls don't stay `'a list`); Match scrutinee type falls back from current_var_types if it's a Var; App direct-call arg type likewise. Typedef order: 1) collect mono instances + 2) mark recursive + 3) tuple/record/variant typedef emit (so recursive_variants affects tuple emit). Verified clang-natively. 5 tests; total 867 |
| 5.11 | **Complex patterns (P_int / P_str / P_bool / P_unit / P_record / P_as / or / guard) + nested ctor** | LLVM port of Phase 4.14 + 4.15. `compile_pat` rewritten as a fully recursive `(test_cond, bindings, var_types)` function; each pattern is reduced to LLVM IR via icmp / strcmp / extractvalue / load + bind. P_int → `icmp eq i32`; P_bool → `icmp eq i1`; P_str → `@strcmp` + `icmp eq i32 result, 0`; P_unit → true; P_record extracts each declared field via `extractvalue` and recurses into sub-pattern; P_as compiles `inner` then binds whole value; P_tuple extracts each element via `extractvalue` and recurses; nested constructor (e.g. `Cons (SS 5, _)`) extracts the payload then routes through `Some (P_constr (...))`. Multiple sub-tests combined via `and_cond` helper using `and i1`. Or-patterns pre-flattened by `expand_or` (typer guarantees matching bind name sets). Guards run in the arm's binding scope; on true → body; on false → next_label (try next arm). `@strcmp` added to runtime_decls. Verified clang-natively. 8 tests; total 875 |
| 5.12 | **Polymorphic `show` builtin** | Per-call argument-type-driven `show_<ty_tag>` specialization; per-type dedicated fns generated via `@asprintf`. `collect_show_types` walks AST + fn signatures to find `App (Var "show", arg)`; `add_show_type` recursively registers the arg type + dependent types (tuple elems / record fields / variant payloads), guarded against cycles (already-registered → skip → no infinite loop on recursive variants like `'a list`). `emit_show_fn` emits per-entry: int → `@asprintf("%d", x)`; bool → `select i1` between `@.s_true` / `@.s_false`; str → `@asprintf("\"%s\"", x)`; unit → const `@.s_unit`; tuple → call each `show_T` and compose with `@asprintf("(%s, ..., %s)", ...)`; record → call each field's `show_T` and compose `@asprintf("Type { f = %s, ... }", ...)`; variant → tag dispatch (icmp eq + br i1 + phi); per ctor: nullary → `@.s_ctor_<name>`; payload → recursively show payload and compose `@asprintf("Ctor %s", ...)`; recursive variant → `getelementptr` + `load` for tag/payload, same shape. Format strings and ctor name strings are pre-registered as needed at `emit_program` head. `App (Var "show", arg)` dispatches to `call ptr @show_<ty_tag arg.ty>(arg)`. Verified clang-natively. 9 tests; total 884. `'a list` `[1, 2, 3]` special-case in a later slice |
| 5.13 | **Region_block + Ref + with Drop + view construction + Unit_lit** | All of Mere's memory-model features implemented in LLVM backend at once (Phase 4.17 region runtime user side + 4.18 + 4.19). `Region_block (R, body)` compiles to `alloca %__lang_region` + `__lang_region_init(ptr, 1MB)` + body + `__lang_region_free`; `current_regions : (name, ptr_reg)` tracks region name → SSA register. `Ref (R, v)` (`&R v`) is inner eval + sizeof (`getelementptr null` + `ptrtoint`) + `__lang_region_alloc` + `store` to region buffer + return `ptr`. `With (c, v, body)` (`with c = v in body`) becomes `let c = v` + body eval + if v's record has `close: unit -> unit`, post-body `c.close.fn(c.close.env, 0)` auto-invocation (3-stage `extractvalue`); body's value is returned. `Record_lit` for `Typer.views`-registered name → view construction: from `e.Ast.ty`'s `TyCon (V, [TyRef (R, ...)])` get region R, build record via `insertvalue` in declared order, `__lang_region_alloc` + `store` to region buffer, return `ptr`. `Field_get` on view (`is_view_type`) → `getelementptr %V, ptr %x, i32 0, i32 idx` + `load`. `llvm_ty_of` adds `TyRef _ → ptr` and `TyCon (n, _) when Typer.views n → ptr`. `Unit_lit` → `i32 0`. Verified clang-natively. 7 tests; total 891 — **the LLVM backend covers the full memory model, fully parallel to the C backend (Phase 4.21)** |
| 5.14 | **`'a list` show special-case `[a, b, c]`** | LLVM port of C codegen Phase 4.16. Before `emit_show_fn`'s variant branch, special-case `Ast.TyCon ("list", [elem_ty])` for recursive list. Nil alone → `"[]"`. Cons → alloca/load/store + loop blocks (`loop_test` / `loop_body` / `loop_iter` / `loop_end`) walking from head, calling `show_<elem_tag>` on each element with `", "` between, concatenating via `__lang_str_concat`, then trailing `"]"`. `@.s_lbracket` / `@.s_rbracket` / `@.s_comma_space` pre-registered. Side effects: when `add_show_type` encounters a polymorphic TyCon, also register into mono_variant_instances / mono_record_instances (handles the case where `show` uses a "weird" type that wouldn't otherwise surface as a mono instance); `collect_tuple_shapes` extended to walk substituted mono-variant payloads (so `int list`'s payload `(int, int list)` tuple shape is emitted even with no Cons in the AST). Verified clang-natively. 4 tests; total 895 |

### Phase 6 (Wasm backend)

With C / LLVM backends complete (Phase 4 / 5 parallel coverage), it's time for the third design target — Wasm. Like Phase 5, emit textual format (WAT), convert to `.wasm` binary via `wat2wasm` (wabt), and verify via Node.js's `WebAssembly.instantiate`.

| Slice | Content | What works |
|---|---|---|
| 6.1 | **Wasm (WAT) MVP** (stack-based emission) | int / bool / arithmetic / comparison / logic / Neg / If / Let (P_var) / Var / Annot converted to WAT; `-w` / `-we` CLI flags; stack-based emission (unlike LLVM's SSA — push operands in sequence; one opcode consumes from the stack and pushes a result). `If` → WAT's `if (result i32) ... else ... end` block; `Let (P_var)` → `(local i32)` decl + `local.set N` / `local.get N`. Comparisons via `i32.lt_s` / `i32.eq` etc.; bools widened to i32. Verified via wat2wasm + Node.js WebAssembly. 14 tests; total 909 |
| 6.2 | **Function lifting + recursion** | top-level `let f = fn x -> ...` and `let rec` lift to `(func $f (param i32) (result i32) ...)`. Phase 5.2's `fn_skel` / `lift_fn_skels` / `find_concrete_arrow` / `resolve_fn_types` ported in parallel to codegen_wasm. `emit_fn_def` gives each fn an independent locals / instrs scope (param at slot 0; let bindings at slot 1, 2, ...). `App (Var name, arg)` → `<arg push>; call $name` sequence (direct-call only for toplevel_fn_names entries). Wasm permits in-module forward refs, so no C-style forward decls — mutual recursion just works. Verified via wat2wasm + Node.js. 5 tests; total 914. Closures / first-class fns / strings / records / variants / etc. are subsequent slices |
| 6.3 | **Strings + str_len + ++ + print + str-arg/return fns** | Architecture: strings live in Wasm's linear memory. `(memory (export "memory") 1)` declares + exports 1 page (64 KB); `(global $__lang_bump (mut i32) (i32.const N))` is a mutable bump pointer. `Str_lit` lifted to `(data (i32.const offset) "...\00")` data segments; `wasm_string_escape` handles `\HH` escapes; the value pushed is the i32 offset via `i32.const N`. `$__lang_strlen` (block/loop for null-byte search) and `$__lang_str_concat` (2× strlen + 2× copy loop + null terminator + bump update) defined inline in WAT. `print s` delegated to host import `(import "env" "puts" (func $puts (param i32)))`; value is i32 0. `str_len s` → `call $__lang_strlen`; `++` → `call $__lang_str_concat`. str-arg / return fns work naturally (Wasm treats strs as i32, so no signature change). Verified via wat2wasm + Node.js (with `puts: (off) => decode memory at off`). 9 tests; total 923 |
| 6.4 | **Tuples** | Tuples lay out in linear memory: 4 bytes per element (all of Mere's int / bool / str are i32 / offset). Base offset saved to a fresh local; **bump pointer is advanced immediately** (reserving the region) → each element stored via `i32.store offset=N*4` relative to base → finally push base. Pre-bump is important: nested tuples or `++` inner emit further advance bump; reserving later causes overlap (a 22 / offsets-collision bug was fixed during Phase 6.4 development). `fst` / `snd` → `i32.load offset=0` / `offset=4`; tuple-arg / tuple-return fns work naturally (tuple is i32 offset → no signature change). Verified via wat2wasm + Node.js. 5 tests; total 928 |
| 6.5 | **Records (monomorphic)** | Same linear-memory layout as tuples. `Record_lit (name, fields)` stores in `Typer.records.r_fields` **declared order** (source order may differ; reordered) — advance bump by 4*N immediately, write each field via `i32.store offset=i*4`, then push base. `Field_get` looks up field index by name and uses `i32.load offset=idx*4`. `Record_update` allocates a new buffer; for each field, if in updates use the new value, else `i32.load offset=...` from source to copy; return the new base. Record-arg/return fns work naturally (records are i32 offsets too). Verified via wat2wasm + Node.js. Polymorphic records / views still Codegen_error. 4 tests; total 932 |
| 6.6 | **Variants + match (monomorphic; one payload type)** | Variants also lay out in linear memory: nullary-only → `{ i32 tag }` (4 bytes); with payload → `{ i32 tag, i32 payload }` (8 bytes; payload is i32 / offset). `variant_tags : (cname, int)` Hashtbl populated from `Exhaustive.type_variants` at `emit_program` head; `variant_payload_ty` detects the single shared type across payload-bearing ctors. `Constr` → `i32.store offset=0` (tag) + optionally `i32.store offset=4` (payload) + push base. `Match` saves scrut to a local, loads tag/payload via `i32.load offset=0/4`, then each arm: `local.get tag; i32.const N; i32.eq; if (result i32) ... else ... end` nested chain; fallthrough → `unreachable` (assumes typer exhaustiveness). Patterns: P_constr / P_var / P_wild; payload binds use a payload local slot. Verified via wat2wasm + Node.js. 6 tests; total 938. Guard / polymorphic / recursive / nested patterns / or-patterns still Codegen_error |
| 6.7 | **First-class fn + closure (top-level + anonymous Fun + captures)** | Wasm specifics: function pointers aren't memory pointers but **function-table indices**; indirect calls go through `call_indirect (type $sig)`. `(type $cl (func (param i32) (param i32) (result i32)))` declared at module head; `(table N funcref)` + `(elem (i32.const 0) $f1_closure ...)` registers adapters starting at index 0. `closure value` is 8 bytes in memory: `{ env_offset, fn_table_idx }`. Each top-level fn `f` gets an env-ignoring adapter `(func $f_closure (param i32) (param i32) ... local.get 1; call $f)` auto-generated and added to the table; `fn_closure_table_idx : (name, int) Hashtbl` records the index. `Var name` in value position, when registered in fn_closure_table_idx, allocates closure value (`env=0, fn_idx=N`) in memory and pushes. Indirect App: save closure to local → load env / arg / load fn_idx → `call_indirect (type $cl)`. Anonymous Fun: `free_vars` for captures → keep only those registered in `locals` (= parent fn's local slots) → fresh adapter `anon_N_fn` registered in table → queued in `pending_closures` → at construction site, env allocated in memory (`{ c1, c2, ... }`), closure value allocated → push. Adapter body's entry loads each capture from env via `i32.load offset=N*4` into a local slot before emitting the body. `emit_program` drains pending in a loop (handles new pending from nested adapters). `pattern_vars` + `free_vars` helpers added. Verified via wat2wasm + Node.js. 7 tests; total 945 |
| 6.8 | **Region_block + Ref + with Drop + view construction + Unit_lit** | Wasm port of LLVM Phase 5.13. Wasm's linear memory + `__lang_bump` global already act like a single region, so a user's `region R { body }` is implemented LIFO: on entry save current `__lang_bump` to a local → eval body → stash result in another local → restore bump to the saved value → push result back. This way, allocations inside the region's scope are "freed" in bulk at scope end (= bump pointer rolling back makes subsequent allocs overwritable). `Ref (R, v)` (`&R v`) → inner eval + bump 4-byte alloc + `i32.store offset=0` + push base. `With (c, v, body)` saves v to a local + evaluates body + if v's record has `close: unit -> unit`, post-body fetches its closure value (`{env_offset, fn_idx}`) via `i32.load`, then `i32.const 0` (unit arg) + `call_indirect (type $cl)` for auto-invoke, drops the result, and pushes body's value. `view V[R] of T { ... }`'s Record_lit handled separately by view name: stores each i32 field in order then pushes base (the view value is the same memory ptr as a record). `Field_get` for view-name inner uses `Typer.views.v_fields` field index for `i32.load offset=idx*4`. `Unit_lit` → `i32.const 0`. Verified via wat2wasm + Node.js: `region R { let x = &R 5 in 42 }` → 42; `with c = mk 7 in c.id * 10` produces "closing" then → 70 (close auto-invoked at scope end); view example → 7. 6 tests; total 951 — **the Wasm backend covers the full memory model, parallel to C / LLVM.** |
| 6.9 | **Polymorphic variant/record + recursive variant + P_tuple sub-pattern** | Wasm's memory layout is uniform (every value is i32 = 4 bytes), so monomorphization like LLVM (Phase 5.9 / 5.10) is unnecessary. `'a opt`, `'a Box`, `'a list = Nil \| Cons of 'a * 'a list` etc. all work with the same code path as mono variants/records. The `params <> []` check in `Constr` and `r_params <> []` check in `Record_lit` are dropped. To unfold `'a list` Cons (tuple payload) in Match, P_tuple sub-pattern in Match is added: extract each element from payload offset via `i32.load offset=i*4` and bind to fresh locals (so `Cons (h, t)` loads h, t into separate locals). Verified via wat2wasm + Node.js. 4 tests; total 955. Memory-layout uniformity is why Wasm doesn't need monomorphization — a Wasm-specific advantage |
| 6.10 | **Complex patterns (P_int / P_str / P_bool / P_unit / P_record / P_as / nested ctor / or / guard)** | Wasm port of LLVM Phase 5.11. `compile_pat` rewritten as a fully recursive `(cond_local_slot, bindings)` function. P_int → `i32.eq`; P_bool → `i32.eq`; P_str → `call $__lang_streq` (new runtime helper; byte-by-byte compare returning i32 boolean); P_unit → true; P_record → declared-field-order `i32.load offset` + sub-pattern recurse (records / views supported); P_as → inner + whole bind; P_tuple → each element `i32.load offset=i*4` + recurse; P_constr → tag test (`i32.load offset=0 + i32.eq`) + sub-pattern recurse (nesting OK). Multiple sub-tests combined via `combine_and` helper (`local.get a; local.get b; i32.and; local.set slot`) — `i32.and` chain. Or-patterns pre-flattened by `expand_or` (same approach as LLVM Phase 5.11). Guards run in the arm's binding scope; final cond is `cond AND guard` (false cond → guard not evaluated, short-circuited); `if (result i32) ... else ... end` block for guard short-circuit. Verified via wat2wasm + Node.js. 8 tests; total 963 |
| 6.12 | **`'a list` show special-case `[a, b, c]`** | Wasm port of LLVM Phase 5.14. Before `emit_show_fn`'s variant branch, special-case `TyCon ("list", [elem_ty])`: locals (cur / acc / first / tag / pl / h) drive a loop walking the chain. `block $end` + `loop $lp` walks from head: tag = `i32.load offset=0`; Nil → break (`br_if $end`); Cons → load payload (= tuple offset) → head = `i32.load offset=0 payload` → optionally concat `, ` (first flag) → concat `show_<elem_tag>(h)` → cur = tail = `i32.load offset=4 payload` → loop. After exit, concat `]`. `@.s_lbracket` / `@.s_rbracket` / `@.s_comma_space` equivalents prepared via `intern_show_str`. Verified via wat2wasm + Node.js. 3 tests; total 974 — **all 3 backends (C / LLVM / Wasm) reach complete parity** |
| 6.11 | **Polymorphic `show` builtin** | Wasm port of LLVM Phase 5.12. Wasm has no `asprintf` equivalent, so **everything is hand-rolled**: `show_int` is Wasm int → decimal string (16-byte buffer from bump pointer → write digits right-to-left → prepend `-` if needed → return pointer to first digit); `show_bool` registers `true` / `false` in a data segment and uses `select`; `show_str` wraps in `"` via 2-stage concat; `show_unit` is the `()` const offset; `show_tuple_X_Y` concats `(`, each element's show, `, `, `)` via `__lang_str_concat`; `show_<R>` concats `R { f1 = `, each field's show, `, f2 = `, ` }`; `show_<V>` does tag dispatch (nested `i32.load + i32.eq` if/else) — per ctor: nullary → direct data ptr; payload → `ctor_name + " "` + recursive show of payload, concatenated. `show_types` Hashtbl + `collect_show_types` + `add_show_type` discover types and recursively register deps (cycle-guarded). `subst_params` applies polymorphic record/variant args (Wasm also emits per-mono-instance functions; layouts share). `intern_show_str` de-dupes literals to save data segment. `App (Var "show", arg)` dispatches to `call $show_<ty_tag arg.ty>`. Verified via wat2wasm + Node.js. 8 tests; total 971. `'a list` `[a, b, c]` special-case in the next slice |

### Phase 15 (Q-010 collection codegen for all 3 backends — 2026-06-20, 16 slices)

Brings Phase 12's interpreter-level Q-010 collections (Vec / OwnedVec / StrBuf / Map + higher-order API + conversions) to all 3 backends. Details in the internal design notes.

| Slice | Content | Works in 3 backends | Tests |
|---|---|---|---|
| 15.1 | C codegen `Vec[R, int]` minimal harness | C: int only | 1177 |
| 15.2 | C codegen generalize Vec[R, T] element types (`vec_instances` table + per-T monomorphize) | C: int / bool / str / tuple / record / variant | 1178 |
| 15.3 | LLVM IR port of Phase 15.2 | + LLVM | 1182 |
| 15.4 | Wasm port of Phase 15.2 (all-i32 uniform → per-T monomorphize unneeded) | + Wasm (3 backends parity) | 1185 |
| 15.5 | 3-backend `vec_set` / `vec_iter` / `vec_fold` | 3 higher-order APIs | 1197 |
| 15.6 | 3-backend `vec_map` / `vec_filter` (region-preserving) | 5 main Vec higher-order APIs | 1206 |
| 15.7 | 3-backend `OwnedVec[T]` + `vec_to_owned` / `owned_vec_to_vec` | Heap-allocated owned vec + Vec ⇄ OwnedVec conversion | 1218 |
| 15.8 | OwnedVec bulk-free at main exit (process-wide registry + `__mere_owned_vec_free_all`; leak-sanitizer-clean) | C / LLVM memory leak fixed | 1222 |
| 15.9 | 3-backend `StrBuf[R]` (in-region mutable string buffer) | + StrBuf | 1225 |
| 15.10 | 3-backend `Map[R, K, V]` (K = int / str + arbitrary V; linear scan) | + Map (K = int / str) | 1232 |
| 15.11 | 3-backend `len` ad-hoc polymorphic builtin (arg.ty static dispatch) | len for Vec / OwnedVec / StrBuf / Map / str / tuple | 1237 |
| 15.12 | 3-backend `vec_to_list` + `len`-on-list (recursive variant Nil/Cons chain) | list conversion and len | 1244 |
| 15.13 | `with v = owned_vec_new () in body` for explicit OwnedVec scope-bound Drop | Frees at scope end | 1247 |
| 15.14 | Map K extended to bool / tuple (recursive per-K eq expansion) | Map K = int / bool / str / tuple | 1255 |
| 15.15 | Map K extended to record / nullary variant | + record / nullary variant | 1263 |
| 15.16 | Map K extended to payload variants (all Mere concrete types as Map keys) | Map K = all concrete types | 1268 |

#### Phase 15 design patterns

- **Per-T monomorphize** (C / LLVM): tables like `vec_instances` collect encountered Ts; `emit_vec_runtime_for elem_ty` emits a per-element-type struct + helpers.
- **Wasm i32 uniformity**: all values are 4-byte i32, so per-T monomorphize is mostly unnecessary — Vec, OwnedVec, StrBuf all fit a single runtime helper set (exception: Map's key equality is type-dependent, so per-K).
- **`resolve_vec_let_types` pre-pass**: Mere's let-poly generalizes `let v = vec_new () in body` to `forall T. Vec[R, T]`, leaving the binding's `.ty` with unresolved TyVars → before codegen, walk and unify binding ty with body use sites via `Typer.unify`.
- **Registry + free_all** (Phase 15.8): all `mere_owned_vec_<T>` share the head layout `{ void* data; int len; int cap; }`, so generic `free(v->data); free(v);` works.
- **Per-K key equality** (Phase 15.14-15.16): tuple / record / variant keys are recursively expanded for structural compare. C is inline expression; LLVM / Wasm get per-K helpers (`@mere_map_key_eq_<K>` / `$mere_map_key_eq_<K>`).

C codegen, LLVM codegen, and Wasm codegen are parallel implementations. AST + type annotations are the shared foundation; only the emission strategy differs per backend.

---

## 7. References

| Doc | Content |
|---|---|
| [changelog.md](changelog.md) | Per-slice change history |
| [memory-model.md](memory-model.md) | Region/view/Trivial concepts. The design that Phase 4 implements |
| `lib/codegen_c.ml` | The C codegen implementation |
| `internal design notes` | The goal of supporting both native and Wasm |

---

Bottom line: codegen is the implementation stage that makes Mere "the language it's designed to be." It's the phase where the "once native codegen is in place..." prose in the design docs becomes actual code.
