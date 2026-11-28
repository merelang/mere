# contrib/fmt — Mere self-hosted formatter (Phase 49 in progress)

Current pattern formatting preserves parentheses around nested alternatives,
whole-constructor aliases and or-pattern lets. Prefix patterns remain source
patterns, and NUL and carriage-return bytes are escaped for round trips.
The source formatter also preserves nested modules, declaration order, opaque
extern types and extern function signatures. It consumes the unresolved output
of `parse_decls`; evaluation and compilation use a separate flattened tree.
Comments and import statements are not preserved, and the self-host parser
still covers a subset of the native syntax.
The stage tables below record the implementation history.

The OCaml `Mere.Formatter` (lib/formatter.ml) is the
reference implementation; this directory holds the in-progress Mere
self-host of the same pretty-printer.

Self-hosting is staged so each step lands as a runnable artifact,
following a multi-phase plan.

## Files

| file | scope | lines |
|---|---|---|
| `fmt.mere` | Pretty-printer. Entry points: `format_expr : expr -> str` and `format_program : program -> str`. Imports [`contrib/parser/ast.mere`](../parser/ast.mere) for AST type definitions so the parser and the formatter share one `expr` / `program` definition. | 683 |

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
| **49c** | Mere parser written in Mere (the real self-host bottleneck) | moved to Phase 50 — done in [`contrib/parser/`](../parser/) |

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

## Running the demos

```sh
dune exec mere -- contrib/fmt/fmt.mere

# Wasm (works in browser):
mere -w contrib/fmt/fmt.mere > /tmp/fmt.wat
wat2wasm --enable-tail-call /tmp/fmt.wat -o /tmp/fmt.wasm
node scripts/run_wasm.js /tmp/fmt.wasm
```

The compiler emits `return_call`, so `wat2wasm` needs `--enable-tail-call`.
Expected output starts:

```
=== Stage 49b pretty-printer demos ===
simple:        let x = 42 in
x
prec (no par): 1 + 2 * 3
paren needed:  (1 + 2) * 3
list literal:  [1, 2, 3]
range sugar:   1..10
lambda chain:  \x y -> x + y
```

followed by the factorial round trip above and the Stage 50g
`format_program` demos (top-level `let`, `let rec`, `type` declarations).

## Declaration and runtime checks

`scripts/selfhost_format_check.py` checks 12 handwritten declaration layouts
through the interpreter and compiled Wasm, including idempotence and complete
raw-AST round trips. It formats all eleven required runtime fixtures, whose
140 handwritten output lines are then checked on five paths by
`scripts/selfhost_check.sh`. Opaque extern handles also execute before and
after formatting through both reference-compiled and self-hosted Wasm.

The existing Wasm-size gate runs the actual optimized browser formatter and
compiler with their shipped HTML and DOM glue against the same layouts,
runtime oracles and extern signatures. The formatter also remains in the
contrib interpreter/C differential inventory.

## Position

Stage 2 contrib (incubation). See [contrib/README.md](../README.md).
This lib is the visible Mere-side of the longer self-host roadmap and
is intentionally co-evolving with `lib/formatter.ml`; both stay in
sync (with the OCaml side as canonical) until 49c lets Mere fully
process its own source.
