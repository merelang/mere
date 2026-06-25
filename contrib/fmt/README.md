# contrib/fmt — Mere self-hosted formatter (Phase 49 in progress)

The OCaml `Mere.Formatter` (lib/formatter.ml, ~600 lines) is the
reference implementation; this directory holds the in-progress Mere
self-host of the same pretty-printer.

Self-hosting is staged so each step lands as a runnable artifact —
see [the paper trial](../../../aidocs/projects/lang/49_self_hosted_fmt_paper.md)
for the multi-phase plan.

## Files

| file | scope | lines |
|---|---|---|
| `fmt.mere` | Pretty-printer. Imports [`contrib/parser/ast.mere`](../parser/ast.mere) for AST type definitions so the parser and the formatter share one `expr` / `program` definition. | ~480 |

The AST definitions live in `contrib/parser/ast.mere` since Phase 50.7
— fmt.mere used to keep its own copy with a bare `T` prefix on ty
variants, but lifting them out lets the parser and the formatter be
imported into the same browser bridge without colliding on names.
Variants renamed to match the parser's `Ty` prefix convention
(`TInt` → `TyInt`, etc.).

## Status

| Stage | Content | Status |
|---|---|---|
| **49a** | AST variant declarations + minimal `fmt_expr` (int / var / binop / let / if / fn / app) + hand-coded demos | **complete** |
| **49b** | Full pretty-printer: precedence-driven paren insertion, block-form layout, `else if` chain flattening, sugar reconstruction (range / Cons-Nil list literal / lambda shorthand), full pattern coverage | **complete** |
| **49d** | Wasm-compile 49a + 49b and wire up a browser playground demo | **complete** — [merelang.github.io/mere/playground/selfhost-fmt.html](https://merelang.github.io/mere/playground/selfhost-fmt.html) |
| **49c** | Mere parser written in Mere (the real self-host bottleneck — ~800 lines) | deferred to Phase 50 |

### Cross-validation against OCaml side

For an AST that round-trips through `mere fmt` (e.g. `let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10`), the Mere self-host produces **byte-identical** output:

```
=== OCaml fmt ===
let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in
fact 10
=== Mere self-host ===
let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in
fact 10
```

## Running the Stage 49a demo

```sh
dune exec mere -- contrib/fmt/fmt.mere

# Wasm (works in browser):
mere -w contrib/fmt/fmt.mere > /tmp/fmt.wat
wat2wasm /tmp/fmt.wat -o /tmp/fmt.wasm
node scripts/run_wasm.js /tmp/fmt.wasm
```

Expected output:

```
demo1: let x = 42 in x
demo2: 1 + 2 * 3
demo3: if <expr> then 1 else n * fact n - 1
demo4: fn x -> x + 1
0
```

The `<expr>` in demo3 is the placeholder arm in `fmt_expr` — `ECmp` is
intentionally uncovered at Stage 49a; Stage 49b widens the match.
`demo2` doesn't reflect precedence yet either; 49b adds the
precedence-driven paren insertion the OCaml side has.

## Known C-backend issue (DEFERRED)

The variant declaration has three sibling constructors each carrying a
3-element tuple payload (`EBin of binop * expr * expr`,
`ECmp of cmpop * expr * expr`, `ELogic of logicop * expr * expr`).
The C codegen's `collect_tuple_shapes` only walks expressions and
polymorphic-variant instantiations; it doesn't pick up tuple shapes
buried inside *monomorphic* variant payloads, so only the first such
tuple typedef gets emitted and the others fail to compile.

This affects `mere -c contrib/fmt/fmt.mere` (clang reports an unknown
type name); interp and Wasm both work. Tracked separately as a
codegen-side fix.

## Position

Stage 2 contrib (incubation). See [contrib/README.md](../README.md).
This lib is the visible Mere-side of the longer self-host roadmap and
is intentionally co-evolving with `lib/formatter.ml`; both stay in
sync (with the OCaml side as canonical) until 49c lets Mere fully
process its own source.
