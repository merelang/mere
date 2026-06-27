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
| `lexer.mere` | Tokenizer: source string → `(int, token) list`. Covers literals, ident / keywords, the 12-precedence operator set, and standard punctuation (Stage 50a). | ~336 |
| `ast.mere` | Shared AST type definitions (`binop` / `cmpop` / `logicop` / `ty` / `pattern` / `expr` / `top_decl` / `program`). Imported by both `parser.mere` and `contrib/fmt/fmt.mere` so the two ends of the self-host pipeline share one definition. Type-only — no functions, no demos. | ~90 |
| `parser.mere` | Full Mere program parser: tokens → `program = (top_decl list, expr)`. Imports `ast.mere` for the type definitions. | ~1010 |

## Status

| Stage | Content | Status |
|---|---|---|
| **50a** | Lexer MVP — token type + tokenize + 9 hand-coded demos | **complete** |
| **50b-1** | Expression parser slice 1 — atom / apply / factor / term / sum (arithmetic, unary `-`, paren, tuple, list, constructor) + 15 demos | **complete** |
| **50b-2** | Expression parser slice 2 — range / cmp / `&&` / `\|\|` + `if` / `let [rec]` / `fn` (multi-arg curry) + minimal `PWild` / `PVar` patterns + 14 more demos | **complete** |
| **50c** | Pattern parser (`PInt` / `PBool` / `PStr` / `PUnit` / `PConstr` / `PTuple` / `PAs` / `POr`, list-pattern desugar) + `match expr with \| pat [when g] -> body \| …` + 12 more demos. `PRecord` deferred. | **complete** |
| **50d** | Type parser (arrow / tuple / postfix-app / paren / 5 primitives) + `fn (x: ty) -> body` annotated lambdas + `fn () -> body` unit param + `(e : ty)` `EAnnot` ascription + 13 more demos. | **complete** |
| **50e** | Top-level decls — `TopLet pat = e ;` / `TopLetRec NAME = e (and NAME = e)* ;` / `TopType NAME = [\|] CTOR [of ty] (\| CTOR [of ty])* ;` — plus `program = (decls, main)` shape and end-to-end `parse_str_program`. 13 more demos including a full recursive list-sum program. Records / extern / view / module deferred. | **complete** |
| **50f-1** | Lift AST type definitions out of `parser.mere` and `contrib/fmt/fmt.mere` into a shared `ast.mere` so both ends of the self-host pipeline can be imported together. fmt.mere's `TInt` / `TArrow` / … ty constructors renamed to `TyInt` / `TyArrow` / … (matching the prefix the parser had to use to dodge the lexer's `TInt` token tag). Both files' demos byte-identical on interp + wasm after the refactor. | **complete** |
| **50f-2** | Browser integration — `contrib/site/playground/selfhost-fmt.mere` wires `dom + parser + fmt` into one Wasm module. The textarea on `selfhost-fmt.html` feeds `tokenize → parse_expr → format_expr`, with the result written back through `dom_set_text`. 7-case node smoke test (arithmetic precedence / let-in / curried lambda / factorial / match / list / range) all round-trip cleanly. | **complete** |
| **50g** | `format_program` in `contrib/fmt/fmt.mere` — `fmt_top_let` / `fmt_top_let_rec` / `fmt_top_type` ported from `lib/formatter.ml` so the browser bridge can accept full Mere files (decls + main). 6 new program-level demos + 5 new node smoke-test cases (`let X = …; … ; main`, variant decls, decls-only) all round-trip; a non-trivial multi-decl program (`type opt = … ; let x = … ; let rec sum = … ; sum [1, 2, 3]`) cross-validates **byte-identical to OCaml-side `mere fmt`**. Records / extern / view / signature still deferred. | **complete** |
| **50h** | Self-host fmt cross-validation in `dune runtest` — `test/test_basic.ml` adds 13 cases that feed an input through both `Pipeline.parse_program + Formatter.format_program` (OCaml) and the self-host pipeline (Mere `tokenize + parse_decls + format_program` via `Pipeline.process` over a synthesized bridge script that reads the input via `read_file`). Each case asserts byte-identical output. Covers expressions, top-level decls, mutual `let rec ... and`, variant types, annotated lambdas, list / range / match. CI now catches any self-host regression vs the OCaml reference. | **complete** (this commit) |

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

Expected (one demo per slice):

```
d2  (prec):          Bin(+, Int(1), Bin(*, Int(2), Int(3)))
e4  (or prec):       Logic(||, Logic(&&, Var(a), Var(b)), Var(c))
e6  (range):         App(App(Var(range), Int(1)), Int(10))
f5  (match guard):   Match(Var(n), [Var(x) when Cmp(>, Var(x), Int(0)) -> Var(x) | _ -> Int(0)])
g5  (fn arrow ty):   Fun(f : Arrow(Int, Str), App(Var(f), Int(1)))
g10 (annot expr):    Annot(Int(42), Int)
h5  (let rec mutual): Program(TopLetRec([even = Fun(n, If(...)); odd = Fun(n, If(...))]); main = App(Var(even), Int(10)))
h7  (type payload):   Program(TopType(opt, [Just of Int | Nothing]); main = Constr(Just, Int(42)))
h13 (full program):   Program(TopType(mylist, [MyNil | MyCons of Tuple[Int, Con(mylist)]]); TopLetRec([sum = Fun(xs : ..., Match(...))]); main = App(Var(sum), ...))
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

## Parser scope (Stage 50b + 50c + 50d + 50e)

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
| `expr_top` | `if cond then t else e` / `let [rec] pat = v in body` / `fn x [y …] -> body` / `match e with [\|] pat [when g] -> body [\| …]` — control-flow keywords |

Patterns (slice 50c) accept the same shape as the OCaml side except
records:

| Form | Result |
|---|---|
| `_` | `PWild` |
| `x` (lowercase) | `PVar x` |
| `42` / `"hi"` / `true` / `()` | `PInt` / `PStr` / `PBool` / `PUnit` |
| `(p1, p2, …)` | `PTuple` |
| `[p1, …, pN]` | nested `PConstr ("Cons", Some (PTuple [pi, …]))`, terminated by `PConstr ("Nil", None)` |
| `Foo` / `Foo (sub)` | `PConstr` (paren-wrapped payload only — atom-style `Some 1` needs the OCaml side's constr-arity table, which the self-host parser doesn't carry, so use `Some (1)`) |
| `p as name` | `PAs (p, name)` |
| `p1 \| p2 \| p3` (inside match arm only) | left-associative `POr` |

Type grammar (slice 50d) — `parse_type`:

| Layer | Productions |
|---|---|
| `ty` | `tuple_ty ('->' ty)?` — `->` is right-associative |
| `tuple_ty` | `app_ty ('*' app_ty)+ \| app_ty` |
| `app_ty` | postfix `int list` ⇒ `TyCon ("list", [TyInt])`, chains left |
| `atom_ty` | `int` / `bool` / `str` / `unit` / `float` primitives; `(ty)`; bare lowercase ident ⇒ `TyCon (name, [])` |

`fn (x: ty) -> body` and `(e : ty)` ascription are the surface entry
points; `fn () -> body` synthesises an `_u: unit` parameter to match
OCaml-side behaviour.

Top-level grammar (slice 50e) — `parse_decls` / `parse_str_program`:

| Form | Result |
|---|---|
| `let pat = e ;` | `TopLet (pat, e)` |
| `let rec NAME = e (and NAME = e)* ;` | `TopLetRec [(name, e); …]` |
| `type NAME = [\|] CTOR [of ty] (\| CTOR [of ty])* ;` | `TopType (name, [], [(ctor, ty?)…])` |
| `let pat = e in body` (at top level) | becomes the program's `main = ELet (pat, e, body)` |
| trailing expression | becomes `main` |
| no trailing expression | synthesised `main = EUnit` (matches OCaml side) |

Each decl is `;`-terminated; the disambiguation between top-level
`let X = e ;` and expression-level `let X = e in body` is by the
post-binding token — same as OCaml's `lib/parser.ml`.

Productions still deferred:

- `'a` style type variables (`TyVar`) — needs a new `T_tyvar` lex token.
- `&R T` borrow refs / `Vec[R, T]` bracket forms — capability syntax
  belongs in a much later phase.
- `fn (x: ty1, y: ty2) -> body` (comma-separated annotated params in
  one paren) — users can chain `fn (x: ty1) -> fn (y: ty2) -> body`.
- Records: `type T = { f: ty, … };` declarations, `Name { f = e, … }`
  literals, `e.f` field access, `Name { … with f = e }` updates, and
  `Name { f = pat, … }` patterns — the whole record story rides on one
  follow-up slice once self-host fmt itself needs them.
- `[a, b, ...rest]` cons-tail sugar in list patterns — Phase 36 sugar.
- `type T 'a = ...` parameterised type decls — waits on the tyvar
  lexer token.
- `extern fn` / `extern type` / `module M { ... }` / `import` /
  `open` / `view` / `drop` / `signature` — all out of self-host fmt's
  scope (the parser deals with the source forms that fmt itself
  formats).
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
- ~~**Stage 50e C-codegen note**: a local variable named `main` is~~
  ✅ **fixed in `lib/codegen_c.ml`** (2026-06-26). The `Let` and
  tuple-`Let` emit sites now route the binder name through
  `c_safe_name`, matching the variable-reference path. `main` (and any
  other entry in `c_reserved_keywords`) works as a local Mere binding
  name.
- ~~**Stage 50f-1 C-codegen regression**: after pulling in ast.mere's~~
  ✅ **fixed in `lib/codegen_c.ml`** (2026-06-26). Two pieces:
  `collect_tuple_shapes_in_ty` walks each monomorphic variant
  declaration's payload to register tuple typedefs (`ELogic of
  logicop * expr * expr` registers `tuple_logicop_expr_expr`), and
  `collect_mono_variant_instances` now takes `variant_decls` so
  polymorphic specializations declared inside monomorphic payloads
  (e.g. `(str * expr) list` inside `ELetRec`'s tuple) get registered
  in `mono_variant_instances`. parser.mere + fmt.mere now compile on
  the C backend with byte-identical output to interp + Wasm.

## Position

Stage 2 contrib (incubation), part of the Phase 50 self-host roadmap.
See [contrib/README.md](../README.md) for the lifecycle. Graduation
target eventually is `mere-parser` (separate repo) but only after the
full lexer + parser is stable and OCaml-side stays canonical for
cross-validation.
