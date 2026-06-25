# contrib/parser — Mere self-hosted parser (Phase 50 in progress)

The OCaml `Mere.Lexer` (lib/lexer.ml, 391 lines) and `Mere.Parser`
(lib/parser.ml, 1935 lines) are the reference implementations; this
directory holds the in-progress Mere self-host so that
`contrib/fmt/fmt.mere`'s pretty-printer can be fed real Mere source
instead of hand-coded AST literals.

Together with `contrib/fmt/`, this directory completes the §S1
self-host plan (see
[the paper trial](../../../aidocs/projects/lang/50_self_hosted_parser_paper.md)).

## Files

| file | scope | lines |
|---|---|---|
| `lexer.mere` | Tokenizer: source string → `(int, token) list`. Covers literals, ident / keywords, the 12-precedence operator set, and standard punctuation (Stage 50a). | ~332 |

## Status

| Stage | Content | Status |
|---|---|---|
| **50a** | Lexer MVP — token type + tokenize + 9 hand-coded demos | **complete** (this commit) |
| **50b** | Expression parser (recursive descent over the 12-level precedence cascade) | future |
| **50c** | Pattern parser | future |
| **50d** | Type parser (for `Annot`) | future |
| **50e** | Top-level decls (`Top_let` / `Top_let_rec` / `Top_type`) | future |
| **50f** | Browser integration — textarea → tokenize + parse + fmt → display | future |

## Running the Stage 50a demos

```sh
dune exec mere -- contrib/parser/lexer.mere
```

Expected (excerpt):

```
demo1 (let in):    Let Ident(x) Eq Int(1) Plus Int(2) In Ident(x) Eof
demo2 (fn arrow):  Fn Ident(x) Arrow Ident(x) Star Ident(x) Eof
...
```

Also runs in Wasm via `mere -w contrib/parser/lexer.mere | wat2wasm` +
`node scripts/run_wasm.js`.

## What's covered

| Group | Tokens |
|---|---|
| Literals | `TInt` / `TStr` / `TIdent` |
| Keywords | `let` / `rec` / `and` / `in` / `if` / `then` / `else` / `fn` / `match` / `with` / `when` / `of` / `type` / `as` / `true` / `false` |
| Operators | `=` `==` `!=` `<` `<=` `>` `>=` `+` `-` `*` `/` `%` `++` `\|\|` `&&` `\` |
| Punctuation | `(` `)` `[` `]` `{` `}` `,` `;` `:` `::` `\|` `.` `..` `_` `->` |
| Comments | `// ... \n` skipped |
| Strings | `"..."` with `\n` `\t` `\"` `\\` `\{` escapes |

## What's deferred (per the §S1 paper trial)

- Float literals — `mere fmt` rarely formats float-heavy code; add later
  if Stage 50e Top-level needs them.
- Multi-line / raw / interpolated strings — Phase 36 sugar, deferred.
- Phase 36 operator family beyond `\` and `..`: `<|` / `<<` / `>>` /
  `@@` / `?` / `?!` / `<-`. Add the ones that show up in real input.
- `extern` / `module` / `import` / `open` / `region` / `view` / `with`
  / `drop` / `signature` — out of self-host fmt's scope.
- Diagnostic-style errors with code frames — line number + simple
  message is the MVP.

## Notes on porting from OCaml

A few Mere-side limitations that surfaced during the port:

- **`\r` escape isn't accepted in string literals.** Comparing CR by
  `ord c == 13` works around it.
- **`substring` takes (start, end) not (start, length).** Spelled out
  in `read_ident_run` / `read_digit_run` comments.
- **Wasm Phase 6.1 doesn't support inner-lifted captures of
  higher-order parameters** (`pred: str -> bool`). `read_run`'s pred
  is duplicated into `read_ident_run` and `read_digit_run` to keep
  the code portable across all backends.

## Position

Stage 2 contrib (incubation), part of the Phase 50 self-host roadmap.
See [contrib/README.md](../README.md) for the lifecycle. Graduation
target eventually is `mere-parser` (separate repo) but only after the
full lexer + parser is stable and OCaml-side stays canonical for
cross-validation.
