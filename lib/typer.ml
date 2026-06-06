(* Bidirectional type checker.
   `infer` returns a type. `check` verifies an expected type.
   Functions without annotations cannot be inferred — they must appear in
   a checking context (e.g. wrapped in `(fn x -> ...) : t1 -> t2`). *)

exception Type_error of Loc.t * string

type env = (string * Ast.ty) list

let mismatch loc expected actual =
  raise (Type_error (loc, Printf.sprintf
    "type error: expected %s, got %s"
    (Ast.pp_ty expected) (Ast.pp_ty actual)))

let rec infer (env : env) (e : Ast.expr) : Ast.ty =
  match e.node with
  | Ast.Int_lit _ -> Ast.TyInt
  | Ast.Bool_lit _ -> Ast.TyBool
  | Ast.Var name ->
    (try List.assoc name env
     with Not_found ->
       raise (Type_error (e.loc, "unbound variable: " ^ name)))
  | Ast.Neg a ->
    check env a Ast.TyInt;
    Ast.TyInt
  | Ast.Bin (_, a, b) ->
    check env a Ast.TyInt;
    check env b Ast.TyInt;
    Ast.TyInt
  | Ast.Cmp (op, a, b) ->
    (match op with
     | Ast.Lt ->
       check env a Ast.TyInt;
       check env b Ast.TyInt;
       Ast.TyBool
     | Ast.Eq ->
       (* Eq works on int or bool; infer LHS, check RHS *)
       let t = infer env a in
       check env b t;
       Ast.TyBool)
  | Ast.Let (name, value, body) ->
    let vt = infer env value in
    infer ((name, vt) :: env) body
  | Ast.If (cond, then_, else_) ->
    check env cond Ast.TyBool;
    let t = infer env then_ in
    check env else_ t;
    t
  | Ast.Fun _ ->
    raise (Type_error (e.loc,
      "cannot infer type of function — wrap in annotation `(fn x -> ...) : t1 -> t2`"))
  | Ast.App (f, arg) ->
    (match infer env f with
     | Ast.TyArrow (t1, t2) ->
       check env arg t1;
       t2
     | t ->
       raise (Type_error (e.loc, Printf.sprintf
         "type error: applying non-function (got %s)" (Ast.pp_ty t))))
  | Ast.Annot (inner, t) ->
    check env inner t;
    t

and check env e expected =
  match e.Ast.node, expected with
  | Ast.Fun (param, body), Ast.TyArrow (t1, t2) ->
    check ((param, t1) :: env) body t2
  | Ast.If (cond, then_, else_), _ ->
    check env cond Ast.TyBool;
    check env then_ expected;
    check env else_ expected
  | Ast.Let (name, value, body), _ ->
    let vt = infer env value in
    check ((name, vt) :: env) body expected
  | _ ->
    let actual = infer env e in
    if actual <> expected then
      mismatch e.Ast.loc expected actual

let type_check e = infer [] e
