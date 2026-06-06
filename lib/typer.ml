(* Bidirectional type checker. *)

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
       let t = infer env a in
       check env b t;
       Ast.TyBool)
  | Ast.Let (name, value, body) ->
    let vt = infer env value in
    infer ((name, vt) :: env) body
  | Ast.Let_rec (name, value, body) ->
    (* Require value to carry a type annotation, since we can't infer
       a recursive function's type without one. *)
    (match value.Ast.node with
     | Ast.Annot (_, t) ->
       (* Check value at its annotation t, with env extended by self. *)
       check ((name, t) :: env) value t;
       infer ((name, t) :: env) body
     | _ ->
       raise (Type_error (e.loc,
         "let rec value requires a type annotation: `let rec f = (... : t) in ...`")))
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
  | Ast.Let_rec (name, value, body), _ ->
    (match value.Ast.node with
     | Ast.Annot (_, t) ->
       check ((name, t) :: env) value t;
       check ((name, t) :: env) body expected
     | _ ->
       raise (Type_error (e.Ast.loc,
         "let rec value requires a type annotation")))
  | _ ->
    let actual = infer env e in
    if actual <> expected then
      mismatch e.Ast.loc expected actual

let type_check e = infer [] e
