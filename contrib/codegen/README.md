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
| `codegen_wasm.mere` | WAT skeleton + int literal (53a) + arith / cmp / logic / neg / EAnnot passthrough (53b) + `let` (PVar / PWild) + `if` + `EVar` local resolve (53c-1) + `EFun` / `EApp` with capture-less closure ABI (53c-2). | ~430 |

## Status

| Stage | Content | Status |
|---|---|---|
| **53a** | `EmitState` record (instrs / data / str_offset / locals / counters / table / variant_tags), `push_instr` / `list_reverse` / `join_indented` helpers, minimal module wrapper (memory only, no extern imports, no stdlib), `emit_expr` over `EInt n` only, `parse_and_emit` glue. 3 demos (`42` / `0` / `100`) produce a 4-line `(module ... (func $main (export "main") (result i32) i32.const N))`; `wat2wasm` accepts the output, `node` runs `main()` and returns the literal. | **complete** |
| **53b** | `binop_instr` / `cmpop_instr` / `logicop_instr` lookup tables — `+` → `i32.add`, `<` → `i32.lt_s`, `&&` → `i32.and`, etc. `emit_expr` now handles `EBool`, `EBin`, `ECmp`, `ELogic`, `ENeg` (lowers to `0 - x`, since wasm has no `i32.neg`), and `EAnnot` passthrough. `OpConcat` (`str ++ str`) raises a Stage 53e marker fail (data segments + extern fns land there). 8 new demos (`1 + 2 * 3` / `10 - 4` / `100 / 4` / `17 % 5` / `1 < 2` / `3 == 3` / `true && false` / `true \|\| false` / `-5` / `(42 : int)`) — each emitted module compiles via `wat2wasm` and `node`'s `main()` returns the expected i32 (`7`, `6`, `25`, `2`, `1`, `1`, `0`, `1`, `-5`, `42`). | **complete** |
| **53c-1** | `let` (PVar / PWild only — destructure deferred to 53d/53e) + `if` + `EVar` resolved against a `(name, slot)` locals table. New helpers `alloc_local` (mints next index, prepends to `locals` and `local_tys`) and `lookup_local` (linear search, fails for unbound names — params land in 53c-2). Module wrapper now emits `(local i32)` declarations from `local_tys` ahead of the body. 6 new demos verified end-to-end on wat2wasm + node: `let x = 5 in x + 1` → 6, nested let → 3, PWild → 42, `if 1 < 2 then 10 else 20` → 10, `let x = 7 in if x < 10 then x * 2 else x` → 14, nested if → 100. | **complete** |
| **53c-2** | Capture-less `EFun` + `EApp` closure ABI: lifts each `fn` to a static `(func $anon_N (param i32) (param i32) (result i32))` (env_ptr at param 0, arg at param 1), bump-allocates an 8-byte closure record `(env_ptr=0, fn_idx)` at construction sites, calls via `call_indirect (type $cl)`. New helpers `alloc_tmp_local` (unnamed scratch slot), `emit_alloc_closure`, plus enter/exit-fn save/restore of per-function state inline in the `EFun` arm. New `EmitState` field `lifted_fns: str list` collects definitions; module wrapper now conditionally emits `(type $cl)`, `(global $__lang_bump)`, `(table N funcref)`, and the `(elem ...)` line when any lambdas were lifted. 5 new demos verified on wat2wasm + node: `(fn x -> x + 1) 5` → 6, `let inc = fn x -> x + 1 in inc 41` → 42, `(fn n -> n * n) 7` → 49, `(fn _x -> 42) 0` → 42, `(fn b -> if b then 10 else 20) true` → 10. Capture (free vars from enclosing scope) lands in 53c-3. | **complete** (this commit) |
| **53c-3** | Free-var capture: scan `EFun` body for free vars, lay out a heap env record at construction time, load via `local.get 0 (env_ptr); i32.load offset=N` inside the lifted fn. | future |
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

- 25 demos (3 from 53a + 11 from 53b + 6 from 53c-1 + 5 from 53c-2)
  byte-identical on interp / Wasm / C (the host backends that run
  codegen_wasm.mere itself).
- Each emitted WAT compiles via `wat2wasm` and `main()` returns the
  expected `i32` value via `node` — covering int arithmetic with
  precedence, signed comparison, bool-as-i32 logic, negation, and
  type annotation passthrough.
- `dune runtest` 1622 passing (no regression).
