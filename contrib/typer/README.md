# contrib/typer — Mere self-hosted Hindley-Milner type inference (Phase 52)

The OCaml `Mere.Typer` (`lib/typer.ml`, 1893 lines) is the reference
implementation; this directory holds the in-progress Mere self-host of
the same type inferencer. §S2.B closes once 52a–52g land.

> See [`aidocs/projects/lang/52_self_hosted_typer_paper.md`][paper]
> for the full plan.

[paper]: https://github.com/284km/aidocs/blob/main/projects/lang/52_self_hosted_typer_paper.md

## Files

| file | scope | lines |
|---|---|---|
| `typer.mere` | Unification (Stage 52a) + monomorphic `infer` (52b) + Hindley-Milner `scheme` / `generalize` / `instantiate` + `ELet` / `ELetRec` (52c) + `parse_and_infer` glue. | ~650 |

## Status

| Stage | Content | Status |
|---|---|---|
| **52a** | `TyMeta of int` added to `ast.mere`; substitution as `(int * ty) list`; `resolve_meta` + `apply_subst` + `occurs` + `unify` + `unify_list` + `fresh_var`. 11 unification demos covering primitive equality, meta binding, arrow / tuple / TyCon, occurs check, chained metas, arity mismatch. | **complete** |
| **52b** | Monomorphic `infer` over the expression AST: literals, `EVar`, `EBin` (int / str arith), `ECmp` (int order + polymorphic eq), `ELogic`, `ENeg`, `EIf`, `EFun` (incl. type annotation), `EApp`, `EAnnot`. State-passing `(counter, subst)` via `infer_state`. `parse_and_infer src` glues parser + typer for end-to-end demos. 15 source-string demos cover `fn x -> x + 1` → `(int -> int)`, `fn x -> x` → `('_0 -> '_0)`, `fn (x: int) -> x` → `(int -> int)`, application, conditionals, polymorphic equality, annotation. | **complete** |
| **52c** | Hindley-Milner let-polymorphism: `scheme = (int list, ty)` (quantified meta ids + body), `mono` / `generalize` / `instantiate` / `subst_quants`. `type_env` lifts to `(str * scheme) list`. New AST cases: `ELet (PVar / PWild)` (generalize at let-binding) and `ELetRec` (pre-bind fresh metas, infer bodies, unify, generalize against outer env). 11 demos including `let id = fn x -> x in if (id true) then id 1 else 0` — `id` used at both `bool -> bool` and `int -> int` in the same body. | **complete** (this commit) |
| **52d** | Pattern type checking + `EConstr` + `ETuple` + `EMatch`. | future |
| **52e** | Records (`ERecordLit` / `EFieldGet` / `ERecordUpdate` / `PRecord`) + `EAnnot`. | future |
| **52f** | Top-level decl integration + cross-validation in `dune runtest` against OCaml `Pipeline.type_of`. | future |
| **52g** | Browser bridge — `selfhost-tyck.html` page, sibling of `selfhost-fmt` / `selfhost-repl`. **Live in-browser type-checker**. | future |

## Why `TyMeta` is separate from `TyVar`

`ast.mere`'s `TyVar of str` is what the parser produces when it reads
an explicit `'a` from source. The typer needs a different kind of
type variable — one allocated by `fresh_var`, indexed by a unique
integer, with no source-level name. Conflating them would force the
typer to invent strings for fresh metas and risk colliding with
parser-emitted names.

`TyMeta` rides on the existing `ty` declaration; `fmt.mere` and
`eval.mere` accept it (fmt renders as `'_n`, eval has no reason to
construct it and uses the catch-all match arm).

## Stage 52a scope

Pure unification — no inference yet. The functions here are the
building blocks 52b will call:

| Function | Behaviour |
|---|---|
| `resolve_meta s id` | Walk the substitution chain, return `Some final_ty` or `None` |
| `apply_subst s t` | Shake the substitution through a type, replacing bound metas |
| `occurs id t s` | True if `TyMeta id` appears in `t` after resolving metas — prevents infinite types |
| `unify s t1 t2` | Returns `Some new_subst` or `None`. Standard HM cases: meta-vs-anything (with occurs check), structural Arrow / Tuple / TyCon, primitive equality |
| `unify_list s xs ys` | Element-wise unify (used by Tuple and TyCon arg lists) |
| `fresh_var n` | `(TyMeta n, n + 1)` — state-passing fresh counter |

## Verification

- 11 demos byte-identical on interp / Wasm / C.
- `dune runtest` 1610 passing (no regression from the `TyMeta` extension).
- `fmt.mere`'s `fmt_ty` and `parser.mere`'s `ty_to_str` both grow a
  `TyMeta n -> "'_n"` arm to keep their matches exhaustive.
