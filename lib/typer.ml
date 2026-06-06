(* Hindley-Milner type inference (Algorithm W) with let-polymorphism.

   Unannotated functions are inferred. let-bound values are generalized
   over type variables that are not free in the surrounding environment,
   giving let-polymorphism (`let id = fn x -> x in id 5; id true` works).

   Type annotations (`(expr : ty)`) act as unification hints: they constrain
   the inferred type to match the annotation. *)

exception Type_error of Loc.t * string

let counter = ref 0
let fresh_var () =
  let id = !counter in
  incr counter;
  Ast.TyVar { id; link = None }

let rec occurs id = function
  | Ast.TyVar v when v.id = id -> true
  | Ast.TyVar { link = Some t; _ } -> occurs id t
  | Ast.TyVar _ | Ast.TyInt | Ast.TyBool -> false
  | Ast.TyArrow (a, b) -> occurs id a || occurs id b

let rec unify loc t1 t2 =
  let t1 = Ast.walk t1 in
  let t2 = Ast.walk t2 in
  match t1, t2 with
  | Ast.TyInt, Ast.TyInt -> ()
  | Ast.TyBool, Ast.TyBool -> ()
  | Ast.TyArrow (a1, b1), Ast.TyArrow (a2, b2) ->
    unify loc a1 a2;
    unify loc b1 b2
  | Ast.TyVar v1, Ast.TyVar v2 when v1.id = v2.id -> ()
  | Ast.TyVar v, t | t, Ast.TyVar v ->
    if occurs v.id t then
      raise (Type_error (loc, "occurs check failed (cyclic type)"))
    else
      v.link <- Some t
  | _ ->
    raise (Type_error (loc, Printf.sprintf
      "cannot unify %s with %s" (Ast.pp_ty t1) (Ast.pp_ty t2)))

type scheme = {
  quantified : int list;
  body : Ast.ty;
}

let mono t = { quantified = []; body = t }

let rec collect_free_vars t acc =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool -> acc
  | Ast.TyVar v -> if List.mem v.id acc then acc else v.id :: acc
  | Ast.TyArrow (a, b) -> collect_free_vars b (collect_free_vars a acc)

let env_free_vars env =
  List.fold_left (fun acc (_, sch) ->
    let body_free = collect_free_vars sch.body [] in
    List.fold_left (fun a id ->
      if List.mem id sch.quantified then a
      else if List.mem id a then a
      else id :: a
    ) acc body_free
  ) [] env

let generalize env t =
  let t_free = collect_free_vars t [] in
  let env_free = env_free_vars env in
  let qs = List.filter (fun id -> not (List.mem id env_free)) t_free in
  { quantified = qs; body = t }

let instantiate sch =
  let mapping = List.map (fun id -> (id, fresh_var ())) sch.quantified in
  let rec subst t =
    match Ast.walk t with
    | (Ast.TyInt | Ast.TyBool) as t -> t
    | Ast.TyVar v as orig ->
      (try List.assoc v.id mapping with Not_found -> orig)
    | Ast.TyArrow (a, b) -> Ast.TyArrow (subst a, subst b)
  in
  subst sch.body

type env = (string * scheme) list

let rec infer (env : env) (e : Ast.expr) : Ast.ty =
  match e.node with
  | Ast.Int_lit _ -> Ast.TyInt
  | Ast.Bool_lit _ -> Ast.TyBool
  | Ast.Var name ->
    (try instantiate (List.assoc name env)
     with Not_found ->
       raise (Type_error (e.loc, "unbound variable: " ^ name)))
  | Ast.Neg a ->
    let t = infer env a in
    unify a.loc t Ast.TyInt;
    Ast.TyInt
  | Ast.Bin (_, a, b) ->
    let ta = infer env a in
    let tb = infer env b in
    unify a.loc ta Ast.TyInt;
    unify b.loc tb Ast.TyInt;
    Ast.TyInt
  | Ast.Cmp (op, a, b) ->
    let ta = infer env a in
    let tb = infer env b in
    (match op with
     | Ast.Lt ->
       unify a.loc ta Ast.TyInt;
       unify b.loc tb Ast.TyInt
     | Ast.Eq ->
       unify e.loc ta tb);
    Ast.TyBool
  | Ast.If (cond, then_, else_) ->
    let tc = infer env cond in
    unify cond.loc tc Ast.TyBool;
    let tt = infer env then_ in
    let te = infer env else_ in
    unify else_.loc te tt;
    tt
  | Ast.Let (name, value, body) ->
    let tv = infer env value in
    let sch = generalize env tv in
    infer ((name, sch) :: env) body
  | Ast.Let_rec (name, value, body) ->
    let alpha = fresh_var () in
    let env_rec = (name, mono alpha) :: env in
    let tv = infer env_rec value in
    unify e.loc alpha tv;
    (* Generalize against the OUTER env so the recursive binding can be polymorphic. *)
    let sch = generalize env tv in
    infer ((name, sch) :: env) body
  | Ast.Fun (param, body) ->
    let alpha = fresh_var () in
    let tb = infer ((param, mono alpha) :: env) body in
    Ast.TyArrow (alpha, tb)
  | Ast.App (f, arg) ->
    let tf = infer env f in
    let ta = infer env arg in
    let result = fresh_var () in
    unify e.loc tf (Ast.TyArrow (ta, result));
    result
  | Ast.Annot (inner, t) ->
    let ti = infer env inner in
    unify e.loc ti t;
    t

let type_check e =
  counter := 0;  (* Fresh counter per top-level inference for stable test output. *)
  infer [] e
