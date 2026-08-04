# mlint — a tiny Mere linter, written in Mere

`mlint` parses Mere source into the shared self-host AST
(`contrib/parser`) and runs lint rules over it. It exists to dogfood the trait
system on a real, AST-sized program:

- lint rules are **trait objects** (`dyn Rule`) — a heterogeneous list of rules,
  each with `check : 'a -> program -> diag list`, dispatched dynamically;
- diagnostics **`derive (Eq, Ord)`** so results are deduplicated and sorted;
- `Ord` is a **super-trait** of `Eq`, both carrying structural defaults
  (`a == b` / `a < b`).

## Rules

| rule | finds |
|------|-------|
| `UnusedBinding` | a `let x = e in body` (or top-level `let`) whose `x` never occurs in scope (conservative: ignores shadowing, so it never reports a false unused) |

Run it:

```
mere contrib/mlint/mlint.mere
# mlint: 2 finding(s)
#   - unused binding: unused1
#   - unused binding: unused2
```

Works on all four backends (interp / C / LLVM / Wasm).

## Dogfood pain (what building this exercised / surfaced)

1. **No AST-returning parser entry** — `contrib/parser` only exposed
   `parse_str_program : str -> str` (a debug string). Added
   `parse_program_ast : str -> program` (returns the AST value) upstream.
2. **A contrib library leaked a monomorphic prelude shadow** —
   `parser.mere` defined its own `list_append` fixed to `top_decl list`,
   which shadowed the prelude's polymorphic `list_append` for every importer,
   so `list_append` on any other element type failed to type. Renamed the
   private helper to `append_top_decls` upstream.
3. **`type T = Ctor;` (a single nullary variant) parses as a type alias** —
   not a variant — so its constructor isn't registered. A leading bar
   (`type T = | Ctor;`) or a payload disambiguates. (Pre-existing parser
   ambiguity; worked around here with the leading bar.)
4. **The self-host AST is position-less** — `expr` nodes carry no source span,
   so diagnostics are messages without line numbers. A future span-carrying
   AST would let mlint point at locations.

## Not yet

More rules (shadowing, unused parameters, redundant match arms), reading a file
path / directory instead of a hard-coded sample, and line numbers (needs spans).
