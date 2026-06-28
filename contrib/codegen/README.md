# contrib/codegen — Mere self-hosted Wasm codegen (Phase 53)

The OCaml `Mere.Codegen_wasm` (`lib/codegen_wasm.ml`, 5491 lines) is
the reference implementation; this directory holds the in-progress
Mere self-host of the same emitter. §S3 closes once 53a–53g land.

> See [`aidocs/projects/lang/53_self_hosted_codegen_paper.md`][paper]
> for the full plan.

[paper]: https://github.com/284km/aidocs/blob/main/projects/lang/53_self_hosted_codegen_paper.md

## Files

| file | scope | lines |
|---|---|---|
| `codegen_wasm.mere` | WAT skeleton + int literal (53a) + arith / cmp / logic / neg / EAnnot passthrough (53b) + `let` (PVar / PWild) + `if` + `EVar` local resolve (53c-1) + `EFun` / `EApp` with capture-less closure ABI (53c-2) + free-var capture (53c-3) + `EMatch` / `EConstr` / `ETuple` + destructuring `let` (53d). | ~770 |

## Status

| Stage | Content | Status |
|---|---|---|
| **53a** | `EmitState` record (instrs / data / str_offset / locals / counters / table / variant_tags), `push_instr` / `list_reverse` / `join_indented` helpers, minimal module wrapper (memory only, no extern imports, no stdlib), `emit_expr` over `EInt n` only, `parse_and_emit` glue. 3 demos (`42` / `0` / `100`) produce a 4-line `(module ... (func $main (export "main") (result i32) i32.const N))`; `wat2wasm` accepts the output, `node` runs `main()` and returns the literal. | **complete** |
| **53b** | `binop_instr` / `cmpop_instr` / `logicop_instr` lookup tables — `+` → `i32.add`, `<` → `i32.lt_s`, `&&` → `i32.and`, etc. `emit_expr` now handles `EBool`, `EBin`, `ECmp`, `ELogic`, `ENeg` (lowers to `0 - x`, since wasm has no `i32.neg`), and `EAnnot` passthrough. `OpConcat` (`str ++ str`) raises a Stage 53e marker fail (data segments + extern fns land there). 8 new demos (`1 + 2 * 3` / `10 - 4` / `100 / 4` / `17 % 5` / `1 < 2` / `3 == 3` / `true && false` / `true \|\| false` / `-5` / `(42 : int)`) — each emitted module compiles via `wat2wasm` and `node`'s `main()` returns the expected i32 (`7`, `6`, `25`, `2`, `1`, `1`, `0`, `1`, `-5`, `42`). | **complete** |
| **53c-1** | `let` (PVar / PWild only — destructure deferred to 53d/53e) + `if` + `EVar` resolved against a `(name, slot)` locals table. New helpers `alloc_local` (mints next index, prepends to `locals` and `local_tys`) and `lookup_local` (linear search, fails for unbound names — params land in 53c-2). Module wrapper now emits `(local i32)` declarations from `local_tys` ahead of the body. 6 new demos verified end-to-end on wat2wasm + node: `let x = 5 in x + 1` → 6, nested let → 3, PWild → 42, `if 1 < 2 then 10 else 20` → 10, `let x = 7 in if x < 10 then x * 2 else x` → 14, nested if → 100. | **complete** |
| **53c-2** | Capture-less `EFun` + `EApp` closure ABI: lifts each `fn` to a static `(func $anon_N (param i32) (param i32) (result i32))` (env_ptr at param 0, arg at param 1), bump-allocates an 8-byte closure record `(env_ptr=0, fn_idx)` at construction sites, calls via `call_indirect (type $cl)`. New helpers `alloc_tmp_local` (unnamed scratch slot), `emit_alloc_closure`, plus enter/exit-fn save/restore of per-function state inline in the `EFun` arm. New `EmitState` field `lifted_fns: str list` collects definitions; module wrapper now conditionally emits `(type $cl)`, `(global $__lang_bump)`, `(table N funcref)`, and the `(elem ...)` line when any lambdas were lifted. 5 new demos verified on wat2wasm + node: `(fn x -> x + 1) 5` → 6, `let inc = fn x -> x + 1 in inc 41` → 42, `(fn n -> n * n) 7` → 49, `(fn _x -> 42) 0` → 42, `(fn b -> if b then 10 else 20) true` → 10. Capture (free vars from enclosing scope) lands in 53c-3. | **complete** |
| **53c-3** | Free-var capture for `EFun`. `free_vars body bound` walks the expression tree to compute the set of names referenced inside the lambda but not bound there; `build_offsets` lays them out at byte offsets 0, 4, 8, ... in a heap env record. `EmitState` gains `captures: (str * int) list` so `EVar` inside the lifted body resolves names by trying `locals` first, then loading from `local.get 0 (env_ptr); i32.load offset=N`. At construction sites the new helpers `emit_build_env` / `emit_store_captures` bump-alloc the env record, emit each captured value via the regular `EVar` dispatch (so transitive captures through middle lambdas just work), and store at the corresponding offset; `emit_alloc_closure` now takes the env_ptr from the stack rather than hardcoding `i32.const 0`. Also fixes two ordering bugs the new tests surfaced: (1) `fn_counter` was being clobbered to `fn_idx + 1` after the body emit, which made nested `EFun`s redefine the same `$anon_N_fn` — now adopts `inner_done.fn_counter` so nested allocations stick; (2) `table_entries` was being reversed at module-wrap time, which swapped the dispatch order for any module with two or more lifted fns — Cons-prepend during emit already puts entries in `fn_idx` order, so the reverse is dropped. 5 new demos verified on wat2wasm + node: `let x = 10 in (fn y -> x + y) 5` → 15, `((fn x -> fn y -> x + y) 3) 4` → 7 (curried two-arg), `(((fn x -> fn y -> fn z -> x + y + z) 1) 2) 3` → 6 (three-level chain, inner captures two), `let a = 7 in let b = 6 in (fn z -> a * b + z) 0` → 42 (multi-let capture), `let n = 100 in let add_n = fn x -> x + n in add_n 23` → 123 (let-bound captured closure). | **complete** |
| **53d** | `EMatch` + `EConstr` + `ETuple` + destructuring `let`. Variants are 2-word `(tag, payload_ptr)` heap records with lazy tag allocation (first encounter of `Some` → tag 0, etc.); tuples are N-word heap records with i32 slots. Pattern matching is a chain of nested `if (result i32) ... else ... end` blocks: the new `emit_check_pattern` pushes an i32 0/1 for whether the pattern matches the value in a given local slot; on success `emit_bind_pattern` allocates fresh locals for each `PVar` / `PAs` binding (with tuple destructure recursing via per-element scratch slots). Terminal `else` traps with `unreachable`. Pattern coverage: `PWild` / `PVar` / `PInt` / `PBool` / `PUnit` / `PTuple` / `PConstr` / `PAs` (defer: `PStr` / `PRecord` / `POr` / `when`-guards). `free_vars` extended to recurse into `ETuple` / `EConstr` / `EMatch` (with new `pattern_bindings` helper to compute names a pattern introduces). `wrap_module` now emits `$__lang_bump` unconditionally (tuples + variants need bump-alloc even without closures). The destructuring-let arm of `ELet` is implemented via the new bind helper (no `emit_check_pattern` since let-destructure is unconditional). 7 new demos verified on wat2wasm + node: `let (a, b) = (3, 4) in a + b` → 7, `match (1, 2) with | (a, b) -> a + b` → 3, `match 2 with | 1 -> 10 | 2 -> 20 | _ -> 99` → 20, `match true with | true -> 100 | false -> 200` → 100, `match (5, 6) with | (a, _) as p -> a` → 5 (PAs binding), `match Some (42) with | Some n -> n | None -> 0` → 42 (variant payload), `match None with | Some n -> n | None -> 99` → 99 (nullary variant wins). Caveat: self-host parser parses `Some 42` as `EApp (Some, 42)` instead of `EConstr ("Some", Some 42)` — demos use the parenthesized form `Some (42)` to get the right AST. | **complete** (this commit) |
| **53d** | `match` + variant tag dispatch + tuple destructure. | future |
| **53e** | Top-level decls (`TopLet` / `TopLetRec` / `TopType` for variant tag registry) + main + full `(module ...)` wrapper with extern fn imports. | future |
| **53f** | Cross-validation: self-host codegen vs OCaml `Codegen_wasm.emit_program` (compare via "same value out of `main()`" rather than byte-identical WAT). Ultimate dogfood: feed `contrib/eval/eval.mere` through self-host codegen and confirm parity with OCaml-side output. | future |
| **53g** | Browser bridge — `selfhost-compile.html` page, sibling of `selfhost-fmt` / `selfhost-repl` / `selfhost-tyck`. **Live in-browser Mere compiler**. | future |

## Stage 53a scope

Smallest viable thing: emit a 4-line WAT module that exports `main`
and returns an `i32.const N` for a top-level int literal. No stdlib
helpers, no extern fn imports, no string handling, no table — those
land as later stages need them.

| Function | Behaviour |
|---|---|
| `push_instr i s` | Prepend instruction `i` to the per-function accumulator |
| `list_reverse xs` | Flip the accumulator at output time |
| `join_indented xs` | Prefix every line with 4 spaces, join with `\n` |
| `emit_expr e s` | Dispatch on `expr` — only `EInt n` is implemented |
| `wrap_module body` | Wrap the body in `(module (memory ...) (func $main ...))` |
| `emit_program prog` | Ignore decls, emit `main` expression only |
| `parse_and_emit src` | `tokenize -> parse_decls -> emit_program` |

## Verification

- 37 demos (3 from 53a + 11 from 53b + 6 from 53c-1 + 5 from 53c-2 +
  5 from 53c-3 + 7 from 53d) byte-identical on interp / Wasm / C (the
  host backends that run codegen_wasm.mere itself).
- Each emitted WAT compiles via `wat2wasm` and `main()` returns the
  expected `i32` value via `node` — covering int arithmetic with
  precedence, signed comparison, bool-as-i32 logic, negation, and
  type annotation passthrough.
- `dune runtest` 1622 passing (no regression).
