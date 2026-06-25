# contrib/parser — Mere self-hosted parser (Phase 50 in progress)

The OCaml `Mere.Lexer` (lib/lexer.ml, 391 lines) and `Mere.Parser`
(lib/parser.ml, 1935 lines) are the reference implementations; this
directory holds the in-progress Mere self-host so that
`contrib/fmt/fmt.mere`'s pretty-printer can be fed real Mere source
instead of hand-coded AST literals.

Together with `contrib/fmt/`, this directory completes the §S1
self-host plan (see
[the paper trial](internal design notes)).

## Files

| file | scope | lines |
|---|---|---|
| `lexer.mere` | Tokenizer: source string → `(int, token) list`. Covers literals, ident / keywords, the 12-precedence operator set, and standard punctuation (Stage 50a). | ~336 |
| `parser.mere` | Expression parser: token list → `expr`. Full 12-level precedence cascade — `atom → apply → factor → term → sum → range → cmp → and → or → expr_top` — plus control-flow keywords `if-then-else` / `let [rec]` / `fn` (Stage 50b slices 1 + 2). | ~500 |

## Status

| Stage | Content | Status |
|---|---|---|
| **50a** | Lexer MVP — token type + tokenize + 9 hand-coded demos | **complete** |
| **50b-1** | Expression parser slice 1 — atom / apply / factor / term / sum (arithmetic, unary `-`, paren, tuple, list, constructor) + 15 demos | **complete** |
| **50b-2** | Expression parser slice 2 — range / cmp / `&&` / `\|\|` + `if` / `let [rec]` / `fn` (multi-arg curry) + minimal `PWild` / `PVar` patterns + 14 more demos | **complete** (this commit) |
| **50c** | Pattern parser (full set: `PInt` / `PBool` / `PStr` / `PUnit` / `PConstr` / `PTuple` / `PRecord` / `PAs` / `POr`) + `match` expression in parser | future |
| **50d** | Type parser (for `EAnnot` + `EFun`'s `ty option` argument) | future |
| **50e** | Top-level decls (`Top_let` / `Top_let_rec` / `Top_type`) + mutual recursion via `let rec ... and ...` | future |
| **50f** | Browser integration — textarea → tokenize + parse + fmt → display | future |

## Running the demos

Stage 50a (lexer):

```sh
dune exec mere -- contrib/parser/lexer.mere
```

Expected (excerpt):

```
demo1 (let in):    Let Ident(x) Eq Int(1) Plus Int(2) In Ident(x) Eof
demo2 (fn arrow):  Fn Ident(x) Arrow Ident(x) Star Ident(x) Eof
...
```

Stage 50b (parser; imports the lexer):

```sh
dune exec mere -- contrib/parser/parser.mere
```

Expected (slice 1 + slice 2 excerpt):

```
d2  (prec):     Bin(+, Int(1), Bin(*, Int(2), Int(3)))
d6  (apply):    App(App(Var(f), Var(a)), Var(b))
e1  (cmp):      Cmp(==, Bin(+, Int(1), Int(2)), Int(3))
e4  (or prec):  Logic(||, Logic(&&, Var(a), Var(b)), Var(c))
e6  (range):    App(App(Var(range), Int(1)), Int(10))
e13 (let rec):  LetRec([f = Fun(n, If(Cmp(==, Var(n), Int(0)), Int(1), ...))], App(Var(f), Int(5)))
```

Both files run identically on interp / C (`-c` + cc) / Wasm (`-w` +
`wat2wasm` + `node scripts/run_wasm.js`).

## Lexer scope (Stage 50a)

| Group | Tokens |
|---|---|
| Literals | `TInt` / `TStr` / `TIdent` |
| Keywords | `let` / `rec` / `and` / `in` / `if` / `then` / `else` / `fn` / `match` / `with` / `when` / `of` / `type` / `as` / `true` / `false` |
| Operators | `=` `==` `!=` `<` `<=` `>` `>=` `+` `-` `*` `/` `%` `++` `\|\|` `&&` `\` |
| Punctuation | `(` `)` `[` `]` `{` `}` `,` `;` `:` `::` `\|` `.` `..` `_` `->` |
| Comments | `// ... \n` skipped |
| Strings | `"..."` with `\n` `\t` `\"` `\\` `\{` escapes |

## Parser scope (Stage 50b slices 1 + 2)

| Layer | Productions |
|---|---|
| `atom` | int / str / bool / unit / var / `Foo` / `Foo (…)` constructor / `(e)` paren / `(e1, …)` tuple / `[e1, …]` list (desugared to nested `Cons`) |
| `apply` | left-associative juxtaposition `f a b` |
| `factor` | unary `-` (right-associative) |
| `term` | `* / %` (left-associative) |
| `sum` | `+ - ++` (left-associative) |
| `range` | `a..b` (desugared to `range a b` — matches `lib/parser.ml`'s `range_expr`) |
| `cmp` | `== != < <= > >=` (left-associative; non-associative-style chaining isn't enforced) |
| `and` | `&&` (left-associative) |
| `or` | `\|\|` (left-associative) |
| `expr_top` | `if cond then t else e` / `let [rec] pat = v in body` / `fn x [y …] -> body` — control-flow keywords |

The full cascade is now in place — `parse_expr` enters at
`parse_expr_top`. Productions still deferred from the OCaml-side
parser:

- `match` expression — needs the full pattern parser, hence Stage 50c.
- `fn (x: ty) -> body` type annotations on lambda arguments — Stage 50d.
- `let rec f = … and g = …` mutual recursion — Stage 50e (currently
  `let rec` accepts a single binding only).
- Phase 36 operator family beyond `..` and `\` lambda shorthand
  (`<\|` / `\|>` / `<<` / `>>` / `@@` / `?` / `?!` / `<-`) — add as
  dogfood demands.

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
- **Stage 50b drive-by fix**: `mere -c / -ll / -w <path>` did not
  forward the file's directory as the `import` base, so any source
  using `import "neighbour.mere"` only resolved on the interp path.
  `parser.mere`'s `import "lexer.mere"` made this surface; `bin/mere.ml`
  now threads `~base_dir` through the three codegen entry points.
- **Stage 50b-2 lexer fix**: `_` was being lexed as `TIdent "_"`
  because `is_alpha_c` admits `_` as an ident-start char and the bare
  `TUnderscore` branch in the main loop never fired. The OCaml side
  resolves this in its keyword table; `keyword_of` in `lexer.mere` now
  does the same so `let _ = …` correctly emits `TUnderscore` while
  identifiers like `_foo` stay as `TIdent "_foo"`.

## Position

Stage 2 contrib (incubation), part of the Phase 50 self-host roadmap.
See [contrib/README.md](../README.md) for the lifecycle. Graduation
target eventually is `mere-parser` (separate repo) but only after the
full lexer + parser is stable and OCaml-side stays canonical for
cross-validation.
