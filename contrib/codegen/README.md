# contrib/codegen — Mere self-hosted Wasm codegen (Phase 53)

The OCaml `Mere.Codegen_wasm` (`lib/codegen_wasm.ml`, 5491 lines) is
the reference implementation; this directory holds the in-progress
Mere self-host of the same emitter. §S3 closes once 53a–53g land.

> See [`internal design notes`][paper]
> for the full plan.

[paper]: https://github.com/284km/internal design notes

## Files

| file | scope | lines |
|---|---|---|
| `codegen_wasm.mere` | WAT skeleton + int literal (Stage 53a). | ~140 |

## Status

| Stage | Content | Status |
|---|---|---|
| **53a** | `EmitState` record (instrs / data / str_offset / locals / counters / table / variant_tags), `push_instr` / `list_reverse` / `join_indented` helpers, minimal module wrapper (memory only, no extern imports, no stdlib), `emit_expr` over `EInt n` only, `parse_and_emit` glue. 3 demos (`42` / `0` / `100`) produce a 4-line `(module ... (func $main (export "main") (result i32) i32.const N))`; `wat2wasm` accepts the output, `node` runs `main()` and returns the literal. | **complete** (this commit) |
| **53b** | Arith + cmp + logic + neg (binop / cmpop / logicop / unop dispatch over typed AST). | future |
| **53c** | `let` + `if` + `fn` + `app` with closure ABI (2-word `{env_ptr, fn_idx}` + bump-alloc env + `call_indirect`). | future |
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

- 3 demos byte-identical on interp / Wasm / C (the host backends that
  run codegen_wasm.mere itself).
- The emitted WAT compiles via `wat2wasm` and `main()` returns the
  expected `i32` literal via `node`.
- `dune runtest` 1622 passing (no regression from the contrib/codegen
  addition).
