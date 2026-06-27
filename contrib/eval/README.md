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
| **51a** | value type + env + minimal eval (literal / var / binop / cmpop / logicop / neg / if / annot) + 11 hand-coded demos | **complete** (this commit) |
| **51b** | closures (`EFun` + `EApp`), `ELet`, `EMatch`, `ELetRec` (with `VRecGroup` for mutual recursion) | future |
| **51c** | constructors / tuples / list literal reconstruction in `value_to_str` | future |
| **51d** | full pattern coverage + records (`VRecord`) | future |
| **51e** | minimal builtins (extern fn) + top-level decl integration (`TopLet` / `TopLetRec` / `TopType` / `TopRecord`) | future |
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

## Stage 51a scope

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

Everything else (`EFun`, `EApp`, `ELet`, `ELetRec`, `EMatch`,
`EConstr`, `ETuple`, `ERecordLit`, `EFieldGet`, `ERecordUpdate`,
`EFloat`) falls through to a `fail` that names the upcoming stage.

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
