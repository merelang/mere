(* Hindley-Milner type inference with let-polymorphism, user-defined
   nominal sum types, and tuples. *)

exception Type_error of Loc.t * string

let counter = ref 0
let fresh_var () =
  let id = !counter in
  incr counter;
  Ast.TyVar { id; link = None }

let rec occurs id = function
  | Ast.TyVar v when v.id = id -> true
  | Ast.TyVar { link = Some t; _ } -> occurs id t
  | Ast.TyVar _ | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> false
  | Ast.TyCon _ -> false
  | Ast.TyArrow (a, b) -> occurs id a || occurs id b
  | Ast.TyTuple ts -> List.exists (occurs id) ts

let rec unify loc t1 t2 =
  let t1 = Ast.walk t1 in
  let t2 = Ast.walk t2 in
  match t1, t2 with
  | Ast.TyInt, Ast.TyInt -> ()
  | Ast.TyBool, Ast.TyBool -> ()
  | Ast.TyStr, Ast.TyStr -> ()
  | Ast.TyUnit, Ast.TyUnit -> ()
  | Ast.TyCon a, Ast.TyCon b when a = b -> ()
  | Ast.TyArrow (a1, b1), Ast.TyArrow (a2, b2) ->
    unify loc a1 a2;
    unify loc b1 b2
  | Ast.TyTuple ts1, Ast.TyTuple ts2 when List.length ts1 = List.length ts2 ->
    List.iter2 (unify loc) ts1 ts2
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
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyCon _ -> acc
  | Ast.TyVar v -> if List.mem v.id acc then acc else v.id :: acc
  | Ast.TyArrow (a, b) -> collect_free_vars b (collect_free_vars a acc)
  | Ast.TyTuple ts -> List.fold_left (fun a t -> collect_free_vars t a) acc ts

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
    | (Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyCon _) as t -> t
    | Ast.TyVar v as orig ->
      (try List.assoc v.id mapping with Not_found -> orig)
    | Ast.TyArrow (a, b) -> Ast.TyArrow (subst a, subst b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map subst ts)
  in
  subst sch.body

type env = (string * scheme) list

type constr_info = {
  arg : Ast.ty option;
  result : string;
}

let constructors : (string, constr_info) Hashtbl.t = Hashtbl.create 16

let register_type type_name variants =
  List.iter (fun (cname, payload) ->
    Hashtbl.replace constructors cname
      { arg = payload; result = type_name }
  ) variants

let initial_env : env =
  [ ("print", mono (Ast.TyArrow (Ast.TyStr, Ast.TyUnit))) ]

let rec infer (env : env) (e : Ast.expr) : Ast.ty =
  match e.node with
  | Ast.Int_lit _ -> Ast.TyInt
  | Ast.Bool_lit _ -> Ast.TyBool
  | Ast.Str_lit _ -> Ast.TyStr
  | Ast.Unit_lit -> Ast.TyUnit
  | Ast.Var name ->
    (try instantiate (List.assoc name env)
     with Not_found ->
       raise (Type_error (e.loc, "unbound variable: " ^ name)))
  | Ast.Neg a ->
    let t = infer env a in
    unify a.loc t Ast.TyInt;
    Ast.TyInt
  | Ast.Bin (op, a, b) ->
    let ta = infer env a in
    let tb = infer env b in
    (match op with
     | Ast.Add | Ast.Sub | Ast.Mul ->
       unify a.loc ta Ast.TyInt;
       unify b.loc tb Ast.TyInt;
       Ast.TyInt
     | Ast.Concat ->
       unify a.loc ta Ast.TyStr;
       unify b.loc tb Ast.TyStr;
       Ast.TyStr)
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
  | Ast.Constr (name, arg_opt) ->
    let info =
      try Hashtbl.find constructors name
      with Not_found ->
        raise (Type_error (e.loc, "unknown constructor: " ^ name))
    in
    (match info.arg, arg_opt with
     | None, None -> Ast.TyCon info.result
     | Some expected_arg_ty, Some arg ->
       let ta = infer env arg in
       unify arg.loc ta expected_arg_ty;
       Ast.TyCon info.result
     | None, Some _ ->
       raise (Type_error (e.loc,
         "constructor " ^ name ^ " takes no argument"))
     | Some _, None ->
       raise (Type_error (e.loc,
         "constructor " ^ name ^ " requires an argument")))
  | Ast.Match (scrut, arms) ->
    let t_scrut = infer env scrut in
    let result_var = fresh_var () in
    List.iter (fun (pat, branch) ->
      let bindings = check_pattern pat t_scrut in
      let env' = List.fold_left (fun acc (n, t) -> (n, mono t) :: acc) env bindings in
      let tb = infer env' branch in
      unify branch.loc tb result_var
    ) arms;
    result_var
  | Ast.Tuple es ->
    let ts = List.map (infer env) es in
    Ast.TyTuple ts

and check_pattern (p : Ast.pattern) (expected : Ast.ty) : (string * Ast.ty) list =
  match p.pnode with
  | Ast.P_wild -> []
  | Ast.P_var name -> [(name, expected)]
  | Ast.P_int _ -> unify p.ploc expected Ast.TyInt; []
  | Ast.P_bool _ -> unify p.ploc expected Ast.TyBool; []
  | Ast.P_str _ -> unify p.ploc expected Ast.TyStr; []
  | Ast.P_unit -> unify p.ploc expected Ast.TyUnit; []
  | Ast.P_constr (name, sub) ->
    let info =
      try Hashtbl.find constructors name
      with Not_found ->
        raise (Type_error (p.ploc, "unknown constructor in pattern: " ^ name))
    in
    unify p.ploc expected (Ast.TyCon info.result);
    (match info.arg, sub with
     | None, None -> []
     | Some arg_ty, Some sub_pat -> check_pattern sub_pat arg_ty
     | None, Some _ ->
       raise (Type_error (p.ploc,
         "constructor pattern " ^ name ^ " takes no sub-pattern"))
     | Some _, None ->
       raise (Type_error (p.ploc,
         "constructor pattern " ^ name ^ " requires a sub-pattern")))
  | Ast.P_tuple ps ->
    let element_tys = List.map (fun _ -> fresh_var ()) ps in
    unify p.ploc expected (Ast.TyTuple element_tys);
    List.concat (List.map2 check_pattern ps element_tys)

let type_check e =
  counter := 0;
  infer initial_env e
