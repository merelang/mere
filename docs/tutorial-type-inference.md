# Tutorial: implement type inference in Mere

This builds a working type inferencer — the unification engine at the
heart of Hindley-Milner (HM) — for a tiny lambda calculus with `let`.
By the end you'll have a program that infers principal types like
`fn f -> fn x -> f x  :  (t6 -> t7) -> t6 -> t7`, catches type errors,
and performs the occurs check. It's the same algorithm Mere's own
self-host typer ([`contrib/typer`](https://github.com/merelang/mere/blob/main/contrib/typer/typer.mere))
runs — just distilled to its core.

The complete program is
[`examples/tutorial_type_infer.mere`](https://github.com/merelang/mere/blob/main/examples/tutorial_type_infer.mere).

## Prerequisites

- A built `mere` compiler + `wat2wasm` + Node.js. Pure compute — no
  network, no database. It even runs in the browser playground.
- Familiarity with algebraic data types and pattern matching in Mere
  (see the [main tutorial](tutorial.md)).

## The two data types

We type-check a tiny language: literals, variables, lambda,
application, and `let`.

```mere
type expr =
  | EInt  of int
  | EBool of bool
  | EVar  of str
  | ELam  of str * expr        // fn x -> body
  | EApp  of expr * expr       // f arg
  | ELet  of str * expr * expr // let x = e1 in e2
  ;
```

Types are `int`, `bool`, arrows, and **type variables** — an integer
id standing for "some type we haven't pinned down yet":

```mere
type ty =
  | TInt
  | TBool
  | TVar   of int
  | TArrow of ty * ty          // a -> b
  ;
```

Inference is the process of filling in those `TVar`s.

## Fresh type variables

Each unknown gets a distinct id from a counter. Mere has no
first-class mutable cell, so we use a single-slot vector:

```mere
let counter = vec_new () in
let _ = vec_push counter 0 in
let fresh = fn (u: unit) ->
  let n = vec_get counter 0 in
  let _ = vec_set counter 0 (n + 1) in
  TVar n
  ;
```

## The substitution

As inference learns facts ("`t0` is `int`"), it records them in a
**substitution** — an association list from tvar id to type:

```mere
let rec subst_lookup = fn (s: (int * ty) list) -> fn (n: int) ->
  match s with
  | Nil -> (None : ty option)
  | Cons (b, rest) ->
    let (k, v) = b in
    if k == n then Some v else subst_lookup rest n
  ;
```

`apply` resolves a type under the substitution — following tvar
bindings all the way down and recursing into arrows:

```mere
let rec apply = fn (s: (int * ty) list) -> fn (t: ty) ->
  match t with
  | TVar n ->
    (match subst_lookup s n with
      | Some t2 -> apply s t2
      | None -> TVar n)
  | TArrow (a, b) -> TArrow (apply s a, apply s b)
  | _ -> t
  ;
```

## The occurs check

Before binding `t = <some type>`, we must check `t` doesn't appear
inside that type — otherwise we'd build an infinite type like
`t = t -> t`. This is what makes `id id` (below) a type error:

```mere
let rec occurs = fn (n: int) -> fn (t: ty) ->
  match t with
  | TVar m -> n == m
  | TArrow (a, b) -> occurs n a || occurs n b
  | _ -> false
  ;
```

## Unification — the core

`unify a b s` makes two types equal, extending the substitution.
Returns `Some new-subst`, or `None` on a clash (e.g. `int` vs a
function) or an occurs-check failure. Note the tuple match on
`(a, b)`:

```mere
let rec unify = fn (a0: ty) -> fn (b0: ty) -> fn (s: (int * ty) list) ->
  let a = apply s a0 in
  let b = apply s b0 in
  match (a, b) with
  | (TInt, TInt)   -> Some s
  | (TBool, TBool) -> Some s
  | (TVar n, TVar m) ->
    if n == m then Some s else Some (Cons ((n, b), s))
  | (TVar n, _) -> if occurs n b then (None : (int * ty) list option)
                   else Some (Cons ((n, b), s))
  | (_, TVar m) -> if occurs m a then None else Some (Cons ((m, a), s))
  | (TArrow (a1, a2), TArrow (b1, b2)) ->
    (match unify a1 b1 s with
      | None -> None
      | Some s1 -> unify a2 b2 s1)
  | _ -> None
  ;
```

Two arrows unify by unifying domains, then codomains under the
resulting substitution. Everything else is either a match (same base
type) or a clash.

## Inference

`infer env e s` returns `Some (type, subst)` or `None`. The
environment maps variable names to types. Each form:

- **literals** → their base type
- **variable** → look it up in the environment
- **lambda** `fn x -> body` → invent a fresh type for `x`, infer the
  body with `x` bound, return `arg-type -> body-type`
- **application** `f arg` → infer both, then `unify` `f`'s type with
  `arg-type -> fresh`, and the result is that fresh (now resolved)
- **let** `let x = e1 in e2` → infer `e1`, bind `x` to its type, infer
  `e2`

```mere
let rec infer = fn (env: (str * ty) list) -> fn (e: expr) -> fn (s: (int * ty) list) ->
  match e with
  | EInt _  -> Some (TInt, s)
  | EBool _ -> Some (TBool, s)
  | EVar x ->
    (match env_lookup env x with
      | Some t -> Some (t, s)
      | None -> (None : (ty * (int * ty) list) option))
  | ELam (x, body) ->
    let tv = fresh () in
    (match infer (Cons ((x, tv), env)) body s with
      | None -> None
      | Some (tbody, s1) -> Some (TArrow (apply s1 tv, tbody), s1))
  | EApp (f, arg) ->
    (match infer env f s with
      | None -> None
      | Some (tf, s1) ->
        (match infer env arg s1 with
          | None -> None
          | Some (targ, s2) ->
            let tres = fresh () in
            (match unify tf (TArrow (targ, tres)) s2 with
              | None -> None
              | Some s3 -> Some (apply s3 tres, s3))))
  | ELet (x, e1, e2) ->
    (match infer env e1 s with
      | None -> None
      | Some (t1, s1) -> infer (Cons ((x, apply s1 t1), env)) e2 s1)
  ;
```

(`env_lookup` is the string-keyed twin of `subst_lookup`; see the
full source.)

## Run it

```sh
./_build/default/bin/mere.exe -w examples/tutorial_type_infer.mere > /tmp/ti.wat
wat2wasm --enable-tail-call /tmp/ti.wat -o /tmp/ti.wasm
node scripts/run_wasm.js /tmp/ti.wasm
```

Output:

```
fn x -> x                      :  t0 -> t0
fn x -> fn y -> x              :  t1 -> t2 -> t1
(fn x -> x) 5                  :  int
fn f -> fn x -> f x            :  (t6 -> t7) -> t6 -> t7
let id = fn x -> x in id true  :  bool
1 2  (apply an int)            :  TYPE ERROR
let id = fn x -> x in id id    :  TYPE ERROR
```

Read the wins: `fn x -> x` gets the polymorphic-looking `t0 -> t0`;
the higher-order `fn f -> fn x -> f x` correctly infers
`(t6 -> t7) -> t6 -> t7` with the arrow domain parenthesized; `1 2`
is rejected because `int` won't unify with a function type.

## The Hindley-Milner leap: let-generalization

Notice the last line: `let id = fn x -> x in id id` is a **type
error** here. That's the limitation of what we built — our `let` is
**monomorphic**. When `id` is used, its single type variable gets
unified with `id`'s own type, triggering the occurs check.

Real HM makes `let` **polymorphic**: after inferring `id : t -> t`,
it *generalizes* the free type variable into a scheme `∀t. t -> t`,
and each use of `id` *instantiates* the scheme with fresh variables.
So `id 1` uses `int -> int` and `id true` uses `bool -> bool`
independently, and `id id` type-checks. That generalization +
instantiation step is the "M" (Milner) in HM.

Adding it means: a type-scheme representation (`∀`-quantified vars),
a free-variable computation over types and the environment, and
`generalize` / `instantiate` functions around the `let` and variable
cases. It's the natural next ~80 lines.

Mere's real typer does all of this — see
[`contrib/typer/typer.mere`](https://github.com/merelang/mere/blob/main/contrib/typer/typer.mere),
which extends this same unification core with let-generalization,
records, algebraic data types, pattern-match checking, and
"did you mean" diagnostics. It's written in Mere and
[runs in the browser playground](https://merelang.org/playground/selfhost-tyck.html)
— you can watch it infer types on live input.

## Where to go next

- **[`contrib/typer/typer.mere`](https://github.com/merelang/mere/blob/main/contrib/typer/typer.mere)**
  — the full self-host HM typer.
- **[`contrib/parser/parser.mere`](https://github.com/merelang/mere/blob/main/contrib/parser/parser.mere)**
  — parse real Mere source into an AST to feed the typer (instead of
  hand-building `expr` values).
- The browser playground's
  [self-host type-checker](https://merelang.org/playground/selfhost-tyck.html)
  and [compiler](https://merelang.org/playground/selfhost-compile.html)
  — the same pipeline, running as Wasm in the page.
