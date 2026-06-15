(* Hindley-Milner type inference + let-polymorphism + sum types + tuples +
   parameterized user types (single parameter for now: `type 'a opt = ...`). *)

exception Type_error of Loc.t * string

let counter = ref 0
let fresh_var () =
  let id = !counter in
  incr counter;
  Ast.TyVar { id; link = None }

let rec occurs id = function
  | Ast.TyVar v when v.id = id -> true
  | Ast.TyVar { link = Some t; _ } -> occurs id t
  | Ast.TyVar _ -> false
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> false
  | Ast.TyParam _ -> false
  | Ast.TyCon (_, args) -> List.exists (occurs id) args
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
  | Ast.TyParam a, Ast.TyParam b when a = b -> ()
  | Ast.TyCon (a, args_a), Ast.TyCon (b, args_b)
    when a = b && List.length args_a = List.length args_b ->
    List.iter2 (unify loc) args_a args_b
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
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> acc
  | Ast.TyParam _ -> acc
  | Ast.TyVar v -> if List.mem v.id acc then acc else v.id :: acc
  | Ast.TyArrow (a, b) -> collect_free_vars b (collect_free_vars a acc)
  | Ast.TyTuple ts -> List.fold_left (fun a t -> collect_free_vars t a) acc ts
  | Ast.TyCon (_, args) ->
    List.fold_left (fun a t -> collect_free_vars t a) acc args

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
    | (Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit) as t -> t
    | Ast.TyParam _ as t -> t
    | Ast.TyVar v as orig ->
      (try List.assoc v.id mapping with Not_found -> orig)
    | Ast.TyArrow (a, b) -> Ast.TyArrow (subst a, subst b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map subst ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map subst args)
  in
  subst sch.body

type env = (string * scheme) list

(* Replace TyParam by fresh TyVars, sharing per param name within one call.
   Used to instantiate polymorphic constructors and user-supplied annotations. *)
let freshen_params t =
  let mapping = Hashtbl.create 4 in
  let lookup p =
    match Hashtbl.find_opt mapping p with
    | Some v -> v
    | None ->
      let v = fresh_var () in
      Hashtbl.add mapping p v;
      v
  in
  let rec aux t =
    match Ast.walk t with
    | Ast.TyParam p -> lookup p
    | (Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyVar _) as t -> t
    | Ast.TyArrow (a, b) -> Ast.TyArrow (aux a, aux b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map aux ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map aux args)
  in
  aux t, mapping

(* Constructor registry: name -> (params, arg, type_name). *)
type constr_info = {
  params : string list;
  arg : Ast.ty option;
  type_name : string;
}

let constructors : (string, constr_info) Hashtbl.t = Hashtbl.create 16

(* Type registry: name -> declared arity (param count). *)
let types : (string, int) Hashtbl.t = Hashtbl.create 16

(* Record registry: type_name -> (type params, ordered field list). *)
type record_info = {
  r_params : string list;
  r_fields : (string * Ast.ty) list;
}
let records : (string, record_info) Hashtbl.t = Hashtbl.create 16

let register_type type_name params variants =
  Hashtbl.replace types type_name (List.length params);
  List.iter (fun (cname, payload) ->
    Hashtbl.replace constructors cname
      { params; arg = payload; type_name }
  ) variants

let register_record type_name params fields =
  Hashtbl.replace types type_name (List.length params);
  Hashtbl.replace records type_name { r_params = params; r_fields = fields }

(* Instantiate a constructor for a single use: pick fresh TyVars for params,
   substitute them into the arg type and result type. *)
let instantiate_constr (info : constr_info) =
  let mapping = List.map (fun p -> (p, fresh_var ())) info.params in
  let rec subst t =
    match Ast.walk t with
    | Ast.TyParam p ->
      (try List.assoc p mapping with Not_found -> t)
    | (Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyVar _) as t -> t
    | Ast.TyArrow (a, b) -> Ast.TyArrow (subst a, subst b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map subst ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map subst args)
  in
  let arg' = Option.map subst info.arg in
  let result_args = List.map (fun p -> List.assoc p mapping) info.params in
  (arg', Ast.TyCon (info.type_name, result_args))

(* Instantiate a record type at a use site: pick fresh TyVars for params,
   substitute them into each field type and into the result type. *)
let instantiate_record name (info : record_info) =
  let mapping = List.map (fun p -> (p, fresh_var ())) info.r_params in
  let rec subst t =
    match Ast.walk t with
    | Ast.TyParam p ->
      (try List.assoc p mapping with Not_found -> t)
    | (Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyVar _) as t -> t
    | Ast.TyArrow (a, b) -> Ast.TyArrow (subst a, subst b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map subst ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map subst args)
  in
  let fields' = List.map (fun (f, t) -> (f, subst t)) info.r_fields in
  let result_args = List.map (fun p -> List.assoc p mapping) info.r_params in
  (fields', Ast.TyCon (name, result_args))

(* Build a polymorphic scheme `str -> 'a` for `fail`.  We allocate a tyvar
   at module-load time; instantiate replaces it with a fresh var on each use. *)
let _fail_alpha_init = fresh_var ()
let fail_scheme =
  let id = match _fail_alpha_init with
    | Ast.TyVar v -> v.id
    | _ -> assert false
  in
  { quantified = [id];
    body = Ast.TyArrow (Ast.TyStr, _fail_alpha_init) }

(* `show : 'a -> str` — convert any value to a string. *)
let _show_alpha_init = fresh_var ()
let show_scheme =
  let id = match _show_alpha_init with
    | Ast.TyVar v -> v.id
    | _ -> assert false
  in
  { quantified = [id];
    body = Ast.TyArrow (_show_alpha_init, Ast.TyStr) }

let initial_env : env =
  [ ("print",       mono (Ast.TyArrow (Ast.TyStr,  Ast.TyUnit)));
    ("print_int",   mono (Ast.TyArrow (Ast.TyInt,  Ast.TyUnit)));
    ("print_bool",  mono (Ast.TyArrow (Ast.TyBool, Ast.TyUnit)));
    ("str_of_int",  mono (Ast.TyArrow (Ast.TyInt,  Ast.TyStr)));
    ("not",         mono (Ast.TyArrow (Ast.TyBool, Ast.TyBool)));
    ("str_len",     mono (Ast.TyArrow (Ast.TyStr,  Ast.TyInt)));
    ("int_of_str",  mono (Ast.TyArrow (Ast.TyStr,  Ast.TyInt)));
    ("str_contains",
       mono (Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyStr, Ast.TyBool))));
    ("str_starts_with",
       mono (Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyStr, Ast.TyBool))));
    ("str_ends_with",
       mono (Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyStr, Ast.TyBool))));
    ("str_repeat",
       mono (Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyInt, Ast.TyStr))));
    ("substring",
       mono (Ast.TyArrow (Ast.TyStr,
              Ast.TyArrow (Ast.TyInt,
              Ast.TyArrow (Ast.TyInt, Ast.TyStr)))));
    ("char_at",
       mono (Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyInt, Ast.TyStr))));
    ("fail",        fail_scheme);
    ("min",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyArrow (Ast.TyInt, Ast.TyInt))));
    ("max",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyArrow (Ast.TyInt, Ast.TyInt))));
    ("abs",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyInt)));
    ("even",        mono (Ast.TyArrow (Ast.TyInt, Ast.TyBool)));
    ("odd",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyBool)));
    ("pow",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyArrow (Ast.TyInt, Ast.TyInt))));
    ("assert",
       mono (Ast.TyArrow (Ast.TyBool, Ast.TyArrow (Ast.TyStr, Ast.TyUnit))));
    ("show",        show_scheme);
  ]

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
     | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod ->
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
     | Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge ->
       unify a.loc ta Ast.TyInt;
       unify b.loc tb Ast.TyInt
     | Ast.Eq | Ast.Ne ->
       unify e.loc ta tb);
    Ast.TyBool
  | Ast.Logic (_, a, b) ->
    let ta = infer env a in
    let tb = infer env b in
    unify a.loc ta Ast.TyBool;
    unify b.loc tb Ast.TyBool;
    Ast.TyBool
  | Ast.If (cond, then_, else_) ->
    let tc = infer env cond in
    unify cond.loc tc Ast.TyBool;
    let tt = infer env then_ in
    let te = infer env else_ in
    unify else_.loc te tt;
    tt
  | Ast.Let (pat, value, body) ->
    let tv = infer env value in
    let bindings = check_pattern pat tv in
    (* Generalize each binding against the OUTER env so polymorphism is preserved
       for `let (f, g) = (fn x -> x, fn x -> x + 1) in ...` style. *)
    let env' = List.fold_left (fun acc (n, t) ->
      let sch = generalize env t in
      (n, sch) :: acc
    ) env bindings in
    infer env' body
  | Ast.Let_rec (bindings, body) ->
    (* Mutual recursion: fresh vars for ALL names first, infer each value
       under env_rec (which has all names mono-bound), unify each, then
       generalize each against the OUTER env. *)
    let alphas = List.map (fun _ -> fresh_var ()) bindings in
    let env_rec = List.fold_left2 (fun acc (n, _) a ->
      (n, mono a) :: acc
    ) env bindings alphas in
    List.iter2 (fun (_, value) alpha ->
      let tv = infer env_rec value in
      unify value.Ast.loc alpha tv
    ) bindings alphas;
    let env' = List.fold_left2 (fun acc (n, _) a ->
      let sch = generalize env a in
      (n, sch) :: acc
    ) env bindings alphas in
    infer env' body
  | Ast.With (name, value, body) ->
    (* v0: identical to Let. Lifetime/resource semantics will be added with
       Drop/destructors in a future slice. *)
    let tv = infer env value in
    let sch = generalize env tv in
    infer ((name, sch) :: env) body
  | Ast.Fun (param, ty_opt, body) ->
    let alpha = fresh_var () in
    (match ty_opt with
     | Some t ->
       let t', _ = freshen_params t in
       unify e.loc alpha t'
     | None -> ());
    let tb = infer ((param, mono alpha) :: env) body in
    Ast.TyArrow (alpha, tb)
  | Ast.App (f, arg) ->
    let tf = infer env f in
    let ta = infer env arg in
    let result = fresh_var () in
    unify e.loc tf (Ast.TyArrow (ta, result));
    result
  | Ast.Annot (inner, t) ->
    let t', _ = freshen_params t in
    let ti = infer env inner in
    unify e.loc ti t';
    t'
  | Ast.Constr (name, arg_opt) ->
    let info =
      try Hashtbl.find constructors name
      with Not_found ->
        raise (Type_error (e.loc, "unknown constructor: " ^ name))
    in
    let (expected_arg, result_ty) = instantiate_constr info in
    (match expected_arg, arg_opt with
     | None, None -> result_ty
     | Some exp, Some arg ->
       let ta = infer env arg in
       unify arg.loc ta exp;
       result_ty
     | None, Some _ ->
       raise (Type_error (e.loc,
         "constructor " ^ name ^ " takes no argument"))
     | Some _, None ->
       raise (Type_error (e.loc,
         "constructor " ^ name ^ " requires an argument")))
  | Ast.Match (scrut, arms) ->
    let t_scrut = infer env scrut in
    let result_var = fresh_var () in
    List.iter (fun (pat, guard, branch) ->
      let bindings = check_pattern pat t_scrut in
      let env' = List.fold_left (fun acc (n, t) -> (n, mono t) :: acc) env bindings in
      (match guard with
       | None -> ()
       | Some g ->
         let tg = infer env' g in
         unify g.Ast.loc tg Ast.TyBool);
      let tb = infer env' branch in
      unify branch.loc tb result_var
    ) arms;
    result_var
  | Ast.Tuple es ->
    let ts = List.map (infer env) es in
    Ast.TyTuple ts
  | Ast.Record_lit (name, fields) ->
    let info =
      try Hashtbl.find records name
      with Not_found ->
        raise (Type_error (e.loc, "unknown record type: " ^ name))
    in
    let (expected_fields, result_ty) = instantiate_record name info in
    (* All declared fields must be provided exactly once. *)
    let provided_names = List.map fst fields in
    let expected_names = List.map fst expected_fields in
    if List.sort compare provided_names <> List.sort compare expected_names then
      raise (Type_error (e.loc,
        Printf.sprintf "record %s: field set mismatch (expected: %s, got: %s)"
          name
          (String.concat ", " expected_names)
          (String.concat ", " provided_names)));
    List.iter (fun (fname, fexpr) ->
      let exp_ty = List.assoc fname expected_fields in
      let t = infer env fexpr in
      unify fexpr.loc t exp_ty
    ) fields;
    result_ty
  | Ast.Field_get (inner, fname) ->
    let t_inner = infer env inner in
    (* The inner expression must have type `TyCon (rec_name, args)` for some
       declared record `rec_name`.  Walk to resolve type vars. *)
    (match Ast.walk t_inner with
     | Ast.TyCon (rec_name, _) when Hashtbl.mem records rec_name ->
       let info = Hashtbl.find records rec_name in
       let (expected_fields, result_ty) = instantiate_record rec_name info in
       unify inner.loc t_inner result_ty;
       (try List.assoc fname expected_fields
        with Not_found ->
          raise (Type_error (e.loc,
            Printf.sprintf "record %s has no field %s" rec_name fname)))
     | _ ->
       raise (Type_error (e.loc,
         "field access on non-record value (cannot infer record type)")))
  | Ast.Record_update (base, updates) ->
    let t_base = infer env base in
    (match Ast.walk t_base with
     | Ast.TyCon (rec_name, _) when Hashtbl.mem records rec_name ->
       let info = Hashtbl.find records rec_name in
       let (expected_fields, result_ty) = instantiate_record rec_name info in
       unify base.loc t_base result_ty;
       List.iter (fun (fname, fexpr) ->
         let exp_ty =
           try List.assoc fname expected_fields
           with Not_found ->
             raise (Type_error (e.loc,
               Printf.sprintf "record %s has no field %s" rec_name fname))
         in
         let t = infer env fexpr in
         unify fexpr.loc t exp_ty
       ) updates;
       result_ty
     | _ ->
       raise (Type_error (e.loc,
         "record update base must be a record value")))

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
    let (expected_arg, result_ty) = instantiate_constr info in
    unify p.ploc expected result_ty;
    (match expected_arg, sub with
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
  | Ast.P_record (name, fpats) ->
    let info =
      try Hashtbl.find records name
      with Not_found ->
        raise (Type_error (p.ploc, "unknown record type in pattern: " ^ name))
    in
    let (expected_fields, result_ty) = instantiate_record name info in
    unify p.ploc expected result_ty;
    (* Each pattern field must be a declared field; partial patterns are allowed. *)
    List.concat_map (fun (fname, fpat) ->
      let exp_ty =
        try List.assoc fname expected_fields
        with Not_found ->
          raise (Type_error (p.ploc,
            Printf.sprintf "record %s has no field %s" name fname))
      in
      check_pattern fpat exp_ty
    ) fpats

let type_check e =
  counter := 0;
  infer initial_env e
