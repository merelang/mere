# mlint — a tiny Mere linter, written in Mere

`mlint` parses Mere source into the shared self-host AST
(`contrib/parser`) and runs lint rules over it. It exists to dogfood the trait
system on a real, AST-sized program:

- lint rules are **trait objects** (`dyn Rule`) — a heterogeneous list of rules,
  each with two methods (`rname : 'a -> str`, `check : 'a -> program -> diag list`),
  dispatched dynamically;
- diagnostics **`derive (Eq, Ord)`** so results are deduplicated and sorted;
- `Ord` is a **super-trait** of `Eq`, both carrying structural defaults
  (`a == b` / `a < b`).

## Rules

| rule | finds |
|------|-------|
| `UnusedBinding` | a `let x = e in body` (or top-level `let`) whose `x` never occurs in scope (conservative: ignores shadowing, so it never reports a false unused) |
| `UnusedParam` | a `fn x -> body` whose parameter `x` is never used in the body |
| `ShadowedBinding` | a `let`/`fn` binding of a name already in scope (threads its own scope environment) |

`_` is exempt everywhere (it is the conventional "unused" name).

Run it on the built-in sample:

```
mere contrib/mlint/mlint.mere
# mlint [unused-binding unused-param shadowing ]: 3 finding(s)
#   - shadowed binding: x
#   - unused binding: unused1
#   - unused parameter: unusedp
```

Or lint a file:

```
mere contrib/mlint/mlint.mere path/to/file.mere
```

## Backends

`mlint` runs on the **interpreter** and the **native (C)** backend — a linter's
natural targets. File input uses `args` / `read_file`, which the LLVM and Wasm
MVP backends do not bind (Wasm has no filesystem), so those two cleanly refuse
at emit time (`unsupported … unbound variable: args`). The trait-object
machinery itself works on all four backends (see `examples/trait_object.mere`).

## Dogfood pain (what building this exercised / surfaced)

1. **No AST-returning parser entry** — `contrib/parser` only exposed
   `parse_str_program : str -> str` (a debug string). Added
   `parse_program_ast : str -> program` (returns the AST value) upstream.
2. **A contrib library leaked a monomorphic prelude shadow** —
   `parser.mere` defined its own `list_append` fixed to `top_decl list`,
   which shadowed the prelude's polymorphic `list_append` for every importer,
   so `list_append` on any other element type failed to type. Renamed the
   private helper to `append_top_decls` upstream.
3. **Trait-object consumers must annotate the parameter as `dyn Trait`** —
   a function that takes a rule as `fn ru -> check ru …` is inferred with a
   `Rule 'a =>` constraint (a *dictionary*-carrying value), not an object.
   Annotating `fn (ru : dyn Rule) -> …` selects object dispatch. Forgetting it
   either errors ("no `impl Rule Rule__obj`") or — through a polymorphic
   higher-order function — silently builds a phantom dictionary that only the
   interpreter tolerated. See #4.
4. **C-backend fix: closure typedefs from polymorphic-record fields** — the C
   backend monomorphizes a polymorphic trait dictionary `Trait__dict 'a` left
   generic (e.g. `Trait__pack`'s dictionary parameter) at the TyParam-erased
   default `int`, emitting `Trait__dict_int`. Its field closure types
   (`int -> R`) can appear nowhere else in the program, and the arrow-type
   collector skipped polymorphic records' fields, so the emitted struct
   referenced an undefined C type. `mlint`'s `check : 'a -> program -> diag list`
   hit this (`int -> program -> diag list` is instantiated nowhere else);
   `examples/trait_object.mere` got lucky because its `int -> int` / `int -> str`
   closures exist elsewhere. Fixed by walking polymorphic-record field types at
   their monomorphized instances in the collector.
5. **`type T = Ctor;` (a single nullary variant) parses as a type alias** —
   not a variant — so its constructor isn't registered. A leading bar
   (`type T = | Ctor;`) or a payload disambiguates. (Pre-existing parser
   ambiguity; worked around here with the leading bar.)
6. **The self-host AST is position-less** — `expr` nodes carry no source span,
   so diagnostics are messages without line numbers. See below.

## Not yet

- **Line numbers / spans.** The self-host AST (`contrib/parser/ast.mere`) has no
  position field on `expr` / `top_decl`. Adding one means threading a span
  through the whole self-host parser and every downstream consumer (typer, eval,
  codegen) plus the bootstrap fixpoint — a separate, larger change than this
  dogfood, deferred deliberately to keep the bootstrap stable.
- More rules (redundant match arms, unreachable branches), and linting a whole
  directory rather than a single file.
