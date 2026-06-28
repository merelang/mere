# contrib/eval — Mere self-hosted evaluator (Phase 51 in progress)

The OCaml `Mere.Eval` (lib/eval.ml, 1986 lines) is the reference
implementation; this directory holds the in-progress Mere self-host so
that, paired with `contrib/parser/` and `contrib/fmt/`, the full
pipeline `source → tokenize → parse → eval` can run inside the
browser. The §S1 plan was self-host fmt + parser; §S2 is the
evaluator.

Together with `contrib/parser/` (Phase 50) and `contrib/fmt/`
(Phase 49), this directory will complete the §S2 vision
(see [the paper trial](../../../aidocs/projects/lang/51_self_hosted_eval_paper.md)).

## Files

| file | scope | lines |
|---|---|---|
| `eval.mere` | Tree-walking interpreter over `ast.mere`'s `expr`. Stage 51a: literals, variables, binop / cmpop / logicop (with short-circuit), unary negation, `if`, transparent `EAnnot`. | ~210 |

## Status

| Stage | Content | Status |
|---|---|---|
| **51a** | value type + env + minimal eval (literal / var / binop / cmpop / logicop / neg / if / annot) + 11 hand-coded demos | **complete** |
| **51b-1** | closures (`EFun` + `EApp`), `ELet`, `EMatch` + full `match_pattern` (PWild / PVar / PInt / PBool / PStr / PUnit / PConstr / PTuple / PAs / POr), `EConstr`, `ETuple` + 12 more demos | **complete** |
| **51b-2** | `ELetRec` via `VRecBinding` placeholder env entries — pure-functional mutual recursion, no `ref` needed. Factorial / mutual `even`/`odd` / Fibonacci / list-sum (over `Cons`/`Nil` chain) all evaluate. 4 more demos. | **complete** |
| **51c** | `try_as_list` walks `Cons`/`Nil` chains so `value_to_str` renders `[1, 2, 3]` instead of `Cons (1, Cons (2, Cons (3, Nil)))`. Empty list `[]`, `mklist n`, and a tail-recursive `rev` over a 3-element list all render. 4 more demos. | **complete** |
| **51d** | `VRecord of str * (str * value) list` + `PRecord` matching (subset of fields) + `ERecordLit` / `EFieldGet` / `ERecordUpdate` evaluation. Record update keeps the base record's field order. `value_to_str` emits `Name { f1 = v1, f2 = v2 }`. 5 more demos. | **complete** |
| **51e** | `VBuiltin` + `apply_builtin` (MVP set: `print`, `show`) + `initial_env` seeding. `apply_decls` + `run_program` over `program = (decls, main)`. **`parse_and_eval`**: imports `contrib/parser/parser.mere`, so a Mere source string runs end-to-end through `tokenize + parse_decls + run_program`. 8 cross-validation tests against OCaml `Pipeline.process`. | **complete** (this commit) |
| **51f** | Browser bridge — paste source, run, see result; **live in-browser Mere REPL** | future |

## Running the Stage 51a demos

```sh
dune exec mere -- contrib/eval/eval.mere
```

Expected:

```
=== Stage 51a eval demos ===
d1  (literal 42):       42
d2  (1 + 2):            3
d3  (3 * (4 + 5)):      27
d4  (if cmp lt):        "less"
...
```

Runs identically on interp / C (`mere -c` + `cc`) / Wasm
(`mere -w` + `wat2wasm` + `node scripts/run_wasm.js`).

## Eval scope (Stage 51a + 51b-1)

| Form | Behaviour |
|---|---|
| `EInt n` / `EBool b` / `EStr s` / `EUnit` | wrap into `VInt` / `VBool` / `VStr` / `VUnit` |
| `EVar name` | linear lookup in env (list of `(str * value)`) |
| `EBin (op, a, b)` | int arithmetic + `++` string concat |
| `ECmp (op, a, b)` | int comparisons + `==` / `!=` on `int` / `bool` / `str` |
| `ELogic (op, a, b)` | short-circuit `&&` / `\|\|` (dispatch inline in `eval`) |
| `ENeg e` | unary minus on `VInt` |
| `EIf (c, t, e)` | branch on `VBool` |
| `EAnnot (e, _ty)` | transparent (annotation ignored at eval time) |
| `EFun (arg, _ty, body)` | build `VClosure (arg, body, env)` (51b-1) |
| `EApp (f, a)` | apply `VClosure` — `eval body (Cons ((arg, av), captured))` (51b-1) |
| `ELet (pat, v, body)` | match `pat` against `eval v`, extend env, eval body (51b-1) |
| `EMatch (e, arms)` | iterate arms; first matching `(pat, guard, body)` wins (51b-1) |
| `EConstr (name, payload?)` | build `VConstr` (51b-1) |
| `ETuple es` | `VTuple (list_map …)` (51b-1) |
| `ELetRec (bindings, body)` | introduces `VRecBinding` placeholders in env; `lookup_env` resolves them on demand by rebuilding the rec env and evaluating the binding body (51b-2) |
| `ERecordLit (name, fields)` | build `VRecord (name, [(f, eval v), …])` (51d) |
| `EFieldGet (e, fname)` | lookup `fname` in `VRecord` fields (51d) |
| `ERecordUpdate (base, updates)` | new `VRecord` with base's field order, overridden values from `updates` (51d) |

Patterns covered (`match_pattern`): `PWild`, `PVar`, `PInt`, `PBool`,
`PStr`, `PUnit`, `PConstr`, `PTuple`, `PAs`, `POr`, **`PRecord`**
(matches by type name, then matches each named field — subset patterns
welcome).

Everything else (`EFloat`) falls through to a `fail`. Floats wait on a
lexer token + the value-type extension; not on the current §S2 path.

### How `ELetRec` works without `ref`

OCaml-side `lib/eval.ml` builds a recursive env via `ref` —  each rec
binding's closure captures an `env ref` that's mutated after the
bindings are built, so the body can reference its own name. Mere is
pure, so we use a different trick:

1. `ELetRec (bindings, body)` calls `make_rec_env bindings env`, which
   prepends a `VRecBinding (name, all_bindings, outer_env)` entry for
   each rec-group name to the outer env. Every placeholder carries the
   **full** bindings list and the SAME outer env.
2. The body is evaluated in this new env. When a rec-group name like
   `fact` is looked up, `lookup_env` notices the `VRecBinding` and
   resolves it: re-runs `make_rec_env` (producing the same rec env)
   and evaluates the binding's body in it. For an `EFun`-shaped body,
   this yields a `VClosure` whose captured env IS the rec env — so
   recursive calls inside the closure go through the same resolution
   path again.
3. Mutual recursion just falls out: `even`'s resolution builds a rec
   env that contains a `VRecBinding` for `odd` (and vice-versa), so
   the inter-name calls work without any cycle in the env.

The cost is that each lookup re-allocates the closure; for typical
recursive code this is fine (closures don't escape across deep
recursion). The previous bug — `make_rec_env` recursing with `rest`
instead of carrying the full `all_bindings` — only surfaced once
mutual recursion was exercised; the factorial case worked because the
group has only one member.

## Notes on the port

Mere-side specifics surfaced during Stage 51a:

- **String comparisons**: Mere's `<` / `<=` / `>` / `>=` are int-only.
  Strings only support `==` / `!=`; `cmpop` therefore covers only the
  int / bool / str combinations the typer accepts.
- **Polymorphic top-level value**: `let empty_env = Nil` generalizes
  the binding to `'a list`, which the C codegen can't monomorphize at
  a top-level value position. Annotated as `(Nil : env)` to keep it
  monomorphic.
- **Match-arm shadowing**: an arm pattern like `ENeg e` that re-uses
  the outer function parameter name `e` confuses the C codegen — the
  generated code references the wrong binding and the recursion loops.
  Inner-bound expressions use `inner` / `cond` / `then_e` / `else_e`
  instead. (Wasm + interp tolerate this; the C codegen quirk is
  follow-up material.)

## Position

Stage 2 contrib (incubation), part of the Phase 51 self-host roadmap.
See [contrib/README.md](../README.md) for the lifecycle. Eventual
graduation target is `mere-eval` (separate repo), but only after the
full evaluator runs alongside the parser + fmt and the OCaml side
stays canonical for cross-validation.
