(* Hindley-Milner type inference + let-polymorphism + sum types + tuples +
   parameterized user types (single parameter for now: `type 'a opt = ...`). *)

exception Type_error of Loc.t * string

(* ── Levenshtein-based name suggestions (Phase 7.3) ──
   Used to suggest "did you mean `fact`?" when the user typo'd a name
   as e.g. `facot`. *)

let levenshtein (a : string) (b : string) : int =
  let la = String.length a and lb = String.length b in
  if la = 0 then lb
  else if lb = 0 then la
  else begin
    let prev = Array.make (lb + 1) 0 in
    let curr = Array.make (lb + 1) 0 in
    for j = 0 to lb do prev.(j) <- j done;
    for i = 1 to la do
      curr.(0) <- i;
      for j = 1 to lb do
        let cost = if a.[i - 1] = b.[j - 1] then 0 else 1 in
        let del = prev.(j) + 1 in
        let ins = curr.(j - 1) + 1 in
        let sub = prev.(j - 1) + cost in
        curr.(j) <- min (min del ins) sub
      done;
      Array.blit curr 0 prev 0 (lb + 1)
    done;
    prev.(lb)
  end

(* Best candidate within `max_dist` edit-distance, else None. Ties pick
   the shortest name (more conservative suggestion). *)
let suggest_name (target : string) (candidates : string list) : string option =
  let max_dist =
    if String.length target <= 3 then 1
    else if String.length target <= 6 then 2
    else 3
  in
  let scored =
    List.filter_map (fun c ->
      let d = levenshtein target c in
      if d <= max_dist && d > 0 then Some (d, c) else None
    ) candidates
  in
  match scored with
  | [] -> None
  | _ ->
    let sorted = List.sort (fun (d1, n1) (d2, n2) ->
      let c = compare d1 d2 in
      if c <> 0 then c else compare (String.length n1) (String.length n2)
    ) scored in
    Some (snd (List.hd sorted))

(* Append a `help:` hint line to a Type_error message. Diagnostic.format
   recognizes `\nhelp: ...` and renders it below the code frame. *)
let with_hint (msg : string) (hint : string) : string =
  msg ^ "\nhelp: " ^ hint

let raise_with_suggestion loc kind target candidates =
  let msg =
    match suggest_name target candidates with
    | Some n -> with_hint (kind ^ ": " ^ target) (Printf.sprintf "did you mean `%s`?" n)
    | None -> kind ^ ": " ^ target
  in
  raise (Type_error (loc, msg))

let counter = ref 0
let fresh_var () =
  let id = !counter in
  incr counter;
  Ast.TyVar { id; link = None }

let rec occurs id = function
  | Ast.TyVar v when v.id = id -> true
  | Ast.TyVar { link = Some t; _ } -> occurs id t
  | Ast.TyVar _ -> false
  | Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> false
  | Ast.TyParam _ -> false
  | Ast.TyCon (_, args) -> List.exists (occurs id) args
  | Ast.TyArrow (a, b) -> occurs id a || occurs id b
  | Ast.TyTuple ts -> List.exists (occurs id) ts
  | Ast.TyRef (_, _, inner) -> occurs id inner

(* For common primitive-type mismatches, suggest a likely fix. Returns
   None for combinations where no obvious one-liner conversion exists.
   t1 = expected, t2 = actual. *)
let type_conversion_hint (t1 : Ast.ty) (t2 : Ast.ty) : string option =
  match Ast.walk t1, Ast.walk t2 with
  | Ast.TyStr, Ast.TyInt | Ast.TyStr, Ast.TyBool ->
    Some "use `show x` to render a value as `str`"
  | Ast.TyInt, Ast.TyStr ->
    Some "use `str_len s` to get the length, or call a parser yourself"
  | Ast.TyInt, Ast.TyBool ->
    Some "use `if b then 1 else 0` to get an `int` from a `bool`"
  | Ast.TyBool, (Ast.TyInt | Ast.TyStr) ->
    Some "wrap in a comparison (e.g. `x == 0`) to get a `bool`"
  | Ast.TyTuple ts1, Ast.TyTuple ts2 when List.length ts1 <> List.length ts2 ->
    Some (Printf.sprintf
            "tuple lengths differ — expected %d element(s), got %d"
            (List.length ts1) (List.length ts2))
  | Ast.TyArrow _, (Ast.TyInt | Ast.TyStr | Ast.TyBool | Ast.TyUnit
                   | Ast.TyTuple _ | Ast.TyCon _) ->
    Some "you may be passing one too many arguments (the function position was \
          already fully applied)"
  | (Ast.TyInt | Ast.TyStr | Ast.TyBool | Ast.TyUnit
    | Ast.TyTuple _ | Ast.TyCon _), Ast.TyArrow _ ->
    Some "you may be missing an argument — the function value isn't fully applied"
  | Ast.TyCon (n1, _), Ast.TyCon (n2, _) when n1 <> n2 ->
    Some (Printf.sprintf "these are different named types (`%s` vs `%s`)" n1 n2)
  | _ -> None

let rec unify loc t1 t2 =
  let t1 = Ast.walk t1 in
  let t2 = Ast.walk t2 in
  match t1, t2 with
  | Ast.TyInt, Ast.TyInt -> ()
  | Ast.TyFloat, Ast.TyFloat -> ()
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
  | Ast.TyRef (m1, r1, t1), Ast.TyRef (m2, r2, t2) when r1 = r2 && m1 = m2 ->
    unify loc t1 t2
  | Ast.TyVar v1, Ast.TyVar v2 when v1.id = v2.id -> ()
  | Ast.TyVar v, t | t, Ast.TyVar v ->
    if occurs v.id t then
      raise (Type_error (loc, "occurs check failed (cyclic type)"))
    else
      v.link <- Some t
  | _ ->
    let base =
      Printf.sprintf "expected `%s`, got `%s`" (Ast.pp_ty t1) (Ast.pp_ty t2)
    in
    let msg =
      match type_conversion_hint t1 t2 with
      | Some hint -> base ^ "\nhelp: " ^ hint
      | None -> base
    in
    raise (Type_error (loc, msg))

type scheme = {
  quantified : int list;
  body : Ast.ty;
}

let mono t = { quantified = []; body = t }

let rec collect_free_vars t acc =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> acc
  | Ast.TyParam _ -> acc
  | Ast.TyVar v -> if List.mem v.id acc then acc else v.id :: acc
  | Ast.TyArrow (a, b) -> collect_free_vars b (collect_free_vars a acc)
  | Ast.TyTuple ts -> List.fold_left (fun a t -> collect_free_vars t a) acc ts
  | Ast.TyCon (_, args) ->
    List.fold_left (fun a t -> collect_free_vars t a) acc args
  | Ast.TyRef (_, _, inner) -> collect_free_vars inner acc

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
    | (Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit) as t -> t
    | Ast.TyParam _ as t -> t
    | Ast.TyVar v as orig ->
      (try List.assoc v.id mapping with Not_found -> orig)
    | Ast.TyArrow (a, b) -> Ast.TyArrow (subst a, subst b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map subst ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map subst args)
    | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, subst inner)
  in
  subst sch.body

type env = (string * scheme) list

(* Check whether a type mentions region `name` anywhere in its structure.
   Used by Region_block's escape check. *)
let rec mentions_region (name : string) (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyRef (_, r, inner) -> r = name || mentions_region name inner
  | Ast.TyArrow (a, b) -> mentions_region name a || mentions_region name b
  | Ast.TyTuple ts -> List.exists (mentions_region name) ts
  | Ast.TyCon (_, args) -> List.exists (mentions_region name) args
  | Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit
  | Ast.TyParam _ | Ast.TyVar _ -> false

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
    | (Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyVar _) as t -> t
    | Ast.TyArrow (a, b) -> Ast.TyArrow (aux a, aux b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map aux ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map aux args)
    | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, aux inner)
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

(* View registry: name -> (region_param, ordered field list).
   View construction is enforced to happen inside an active region block;
   the region_param is substituted with the active region at construction. *)
type view_info = {
  v_region_param : string;
  v_fields : (string * Ast.ty) list;
}
let views : (string, view_info) Hashtbl.t = Hashtbl.create 8

(* Stack of currently-open region names (innermost first), maintained by
   Region_block during inference. Used to enforce that view construction
   happens inside a region. *)
let active_regions : string list ref = ref []

(* Substitute a region name in a type. Used when instantiating a view's
   declared field types at construction time. *)
let rec subst_region (from_name : string) (to_name : string) (t : Ast.ty) : Ast.ty =
  match Ast.walk t with
  | Ast.TyRef (m, r, inner) ->
    let r' = if r = from_name then to_name else r in
    Ast.TyRef (m, r', subst_region from_name to_name inner)
  | Ast.TyArrow (a, b) ->
    Ast.TyArrow (subst_region from_name to_name a,
                 subst_region from_name to_name b)
  | Ast.TyTuple ts -> Ast.TyTuple (List.map (subst_region from_name to_name) ts)
  | Ast.TyCon (n, args) ->
    Ast.TyCon (n, List.map (subst_region from_name to_name) args)
  | (Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit
    | Ast.TyParam _ | Ast.TyVar _) as t -> t

let register_type type_name params variants =
  Hashtbl.replace types type_name (List.length params);
  Exhaustive.register_variants type_name variants;
  List.iter (fun (cname, payload) ->
    Hashtbl.replace constructors cname
      { params; arg = payload; type_name }
  ) variants

let register_record type_name params fields =
  Hashtbl.replace types type_name (List.length params);
  Hashtbl.replace records type_name { r_params = params; r_fields = fields }

(* Built-in capability record types. Registered at module load so that
   `mk_logger`/`mk_metrics` return values whose type the typer recognizes
   as Logger / Metrics. Users can override with their own `type Logger`
   declarations if they want a different shape. *)
let () =
  register_record "Logger" []
    [("info",  Ast.TyArrow (Ast.TyStr, Ast.TyUnit));
     ("warn",  Ast.TyArrow (Ast.TyStr, Ast.TyUnit));
     ("error", Ast.TyArrow (Ast.TyStr, Ast.TyUnit))];
  register_record "Metrics" []
    [("inc",    Ast.TyArrow (Ast.TyStr, Ast.TyUnit));
     ("record", Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyInt, Ast.TyUnit)))]

(* Register a view: populates both the view registry (for construction-time
   region enforcement) and the record registry (so field access / record
   update work as for a plain record). *)
let register_view view_name region_param fields =
  Hashtbl.replace views view_name
    { v_region_param = region_param; v_fields = fields };
  Hashtbl.replace types view_name 0;
  Hashtbl.replace records view_name { r_params = []; r_fields = fields }

(* Drop type registry: names declared with `drop type ...`. Region-tagged
   values (`&R v`) must NOT have a type that mentions any drop type
   anywhere — this is the Trivial[R] constraint. *)
let drop_types : (string, unit) Hashtbl.t = Hashtbl.create 8

let register_drop_type name =
  Hashtbl.replace drop_types name ()

(* True when the type structurally contains a TyCon whose name is in the
   drop_types registry. Walks through type vars / refs / tuples /
   constructors. Function-type arms are skipped (a function value itself
   is Trivial even if it captures Drop resources via closure). *)
let rec contains_drop_type (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyCon (name, args) ->
    Hashtbl.mem drop_types name
    || List.exists contains_drop_type args
  | Ast.TyTuple ts -> List.exists contains_drop_type ts
  | Ast.TyRef (_, _, inner) -> contains_drop_type inner
  | Ast.TyArrow _ -> false
  | Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit
  | Ast.TyParam _ | Ast.TyVar _ -> false

(* Instantiate a constructor for a single use: pick fresh TyVars for params,
   substitute them into the arg type and result type. *)
let instantiate_constr (info : constr_info) =
  let mapping = List.map (fun p -> (p, fresh_var ())) info.params in
  let rec subst t =
    match Ast.walk t with
    | Ast.TyParam p ->
      (try List.assoc p mapping with Not_found -> t)
    | (Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyVar _) as t -> t
    | Ast.TyArrow (a, b) -> Ast.TyArrow (subst a, subst b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map subst ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map subst args)
    | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, subst inner)
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
    | (Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyVar _) as t -> t
    | Ast.TyArrow (a, b) -> Ast.TyArrow (subst a, subst b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map subst ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map subst args)
    | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, subst inner)
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

(* `len : 'a -> int` (Phase 12.6) — ad-hoc polymorphic builtin that
   dispatches at runtime over Vec[R, T] / OwnedVec[T] / 'a list / str /
   tuple. Type-system level it is just `'a -> int` (same枠 as `show`);
   illegal argument types surface as runtime errors. A future slice may
   replace this with a proper trait-based dispatch. *)
let _len_alpha = fresh_var ()
let len_scheme =
  let id = match _len_alpha with
    | Ast.TyVar v -> v.id
    | _ -> assert false
  in
  { quantified = [id];
    body = Ast.TyArrow (_len_alpha, Ast.TyInt) }

(* `fst : ('a * 'b) -> 'a` and `snd : ('a * 'b) -> 'b` — 2-quantified schemes. *)
let _fst_alpha = fresh_var ()
let _fst_beta = fresh_var ()
let fst_scheme =
  let aid = match _fst_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  let bid = match _fst_beta with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; bid];
    body = Ast.TyArrow (Ast.TyTuple [_fst_alpha; _fst_beta], _fst_alpha) }

let _snd_alpha = fresh_var ()
let _snd_beta = fresh_var ()
let snd_scheme =
  let aid = match _snd_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  let bid = match _snd_beta with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; bid];
    body = Ast.TyArrow (Ast.TyTuple [_snd_alpha; _snd_beta], _snd_beta) }

(* `id : 'a -> 'a` — identity function. *)
let _id_alpha = fresh_var ()
let id_scheme =
  let aid = match _id_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid];
    body = Ast.TyArrow (_id_alpha, _id_alpha) }

(* `swap : ('a * 'b) -> ('b * 'a)` — 2-tuple swap. *)
let _swap_alpha = fresh_var ()
let _swap_beta = fresh_var ()
let swap_scheme =
  let aid = match _swap_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  let bid = match _swap_beta with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; bid];
    body = Ast.TyArrow (Ast.TyTuple [_swap_alpha; _swap_beta],
                        Ast.TyTuple [_swap_beta; _swap_alpha]) }

(* `pair : 'a -> 'b -> ('a * 'b)` — construct a 2-tuple from curried args. *)
let _pair_alpha = fresh_var ()
let _pair_beta = fresh_var ()
let pair_scheme =
  let aid = match _pair_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  let bid = match _pair_beta with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; bid];
    body = Ast.TyArrow (_pair_alpha,
                        Ast.TyArrow (_pair_beta,
                                     Ast.TyTuple [_pair_alpha; _pair_beta])) }

(* `const : 'a -> 'b -> 'a` — returns first arg, ignores second. *)
let _const_alpha = fresh_var ()
let _const_beta = fresh_var ()
let const_scheme =
  let aid = match _const_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  let bid = match _const_beta with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; bid];
    body = Ast.TyArrow (_const_alpha,
                        Ast.TyArrow (_const_beta, _const_alpha)) }

(* `flip : ('a -> 'b -> 'c) -> ('b -> 'a -> 'c)` — flip arg order of a curried
   binary function.  Lang's first 3-quantified, higher-order builtin. *)
let _flip_alpha = fresh_var ()
let _flip_beta = fresh_var ()
let _flip_gamma = fresh_var ()
let flip_scheme =
  let aid = match _flip_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  let bid = match _flip_beta with Ast.TyVar v -> v.id | _ -> assert false in
  let cid = match _flip_gamma with Ast.TyVar v -> v.id | _ -> assert false in
  let arrow_in =
    Ast.TyArrow (_flip_alpha, Ast.TyArrow (_flip_beta, _flip_gamma)) in
  let arrow_out =
    Ast.TyArrow (_flip_beta, Ast.TyArrow (_flip_alpha, _flip_gamma)) in
  { quantified = [aid; bid; cid];
    body = Ast.TyArrow (arrow_in, arrow_out) }

(* `try_or : (unit -> 'a) -> 'a -> 'a` — catch Eval_error, return default. *)
let _try_alpha = fresh_var ()
let try_or_scheme =
  let aid = match _try_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid];
    body = Ast.TyArrow (
      Ast.TyArrow (Ast.TyUnit, _try_alpha),
      Ast.TyArrow (_try_alpha, _try_alpha)) }

(* `exit : int -> 'a` — never returns, polymorphic result. *)
let _exit_alpha = fresh_var ()
let exit_scheme =
  let aid = match _exit_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid];
    body = Ast.TyArrow (Ast.TyInt, _exit_alpha) }

(* --- Vec builtins (Q-010 narrowed → 実装、Phase 12.1〜12.3) ---
   `Vec[R, T]` は region-aware な可変長 vector。型は 2-arg TyCon
   `TyCon ("Vec", [TyRef BorrowedRead R TyUnit; T])`:
     - 第 1 引数: region marker (`TyRef` を介して region 名を埋め込む、
       view 型と同じ慣例)
     - 第 2 引数: 要素型
   Trivial 扱いなので Trivial[R'] が破れない限り region に置ける。

   Schemes は region 位置に TyVar を置く: 各呼出ごとに「任意の region
   marker」と unify される。具体的な region 名は scheme 内で固定せず、
   call site の Vec 値から伝搬する。 *)
let _vec_new_elem = fresh_var ()
let _vec_new_region = fresh_var ()
let vec_new_scheme =
  let aid = match _vec_new_elem with Ast.TyVar v -> v.id | _ -> assert false in
  let rid = match _vec_new_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; rid];
    body = Ast.TyArrow (Ast.TyUnit,
      Ast.TyCon ("Vec", [_vec_new_region; _vec_new_elem])) }

let _vec_push_elem = fresh_var ()
let _vec_push_region = fresh_var ()
let vec_push_scheme =
  let aid = match _vec_push_elem with Ast.TyVar v -> v.id | _ -> assert false in
  let rid = match _vec_push_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; rid];
    body = Ast.TyArrow (
      Ast.TyCon ("Vec", [_vec_push_region; _vec_push_elem]),
      Ast.TyArrow (_vec_push_elem, Ast.TyUnit)) }

let _vec_get_elem = fresh_var ()
let _vec_get_region = fresh_var ()
let vec_get_scheme =
  let aid = match _vec_get_elem with Ast.TyVar v -> v.id | _ -> assert false in
  let rid = match _vec_get_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; rid];
    body = Ast.TyArrow (
      Ast.TyCon ("Vec", [_vec_get_region; _vec_get_elem]),
      Ast.TyArrow (Ast.TyInt, _vec_get_elem)) }

let _vec_len_elem = fresh_var ()
let _vec_len_region = fresh_var ()
let vec_len_scheme =
  let aid = match _vec_len_elem with Ast.TyVar v -> v.id | _ -> assert false in
  let rid = match _vec_len_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; rid];
    body = Ast.TyArrow (Ast.TyCon ("Vec", [_vec_len_region; _vec_len_elem]),
                        Ast.TyInt) }

(* Pre-register `Vec[R, T]` (arity 2). User code can write `Vec[R, int]`
   or `int Vec` (legacy 1-arg postfix, auto-defaults the region to a
   synthetic `__heap`). *)
let () = Hashtbl.replace types "Vec" 2

(* --- Vec の高階 API (Phase 12.9) ---
   region-polymorphic、element-type-polymorphic な schemes。
     vec_iter : forall R T. Vec[R, T] -> (T -> unit) -> unit
     vec_map  : forall R T U. Vec[R, T] -> (T -> U) -> Vec[R, U]
     vec_fold : forall R T U. Vec[R, T] -> U -> (U -> T -> U) -> U
     vec_set  : forall R T. Vec[R, T] -> int -> T -> unit *)
let _vec_iter_elem = fresh_var ()
let _vec_iter_region = fresh_var ()
let vec_iter_scheme =
  let aid = match _vec_iter_elem with Ast.TyVar v -> v.id | _ -> assert false in
  let rid = match _vec_iter_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; rid];
    body = Ast.TyArrow (
      Ast.TyCon ("Vec", [_vec_iter_region; _vec_iter_elem]),
      Ast.TyArrow (
        Ast.TyArrow (_vec_iter_elem, Ast.TyUnit),
        Ast.TyUnit)) }

let _vec_map_t = fresh_var ()
let _vec_map_u = fresh_var ()
let _vec_map_region = fresh_var ()
let vec_map_scheme =
  let tid = match _vec_map_t with Ast.TyVar v -> v.id | _ -> assert false in
  let uid = match _vec_map_u with Ast.TyVar v -> v.id | _ -> assert false in
  let rid = match _vec_map_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [tid; uid; rid];
    body = Ast.TyArrow (
      Ast.TyCon ("Vec", [_vec_map_region; _vec_map_t]),
      Ast.TyArrow (
        Ast.TyArrow (_vec_map_t, _vec_map_u),
        Ast.TyCon ("Vec", [_vec_map_region; _vec_map_u]))) }

let _vec_fold_t = fresh_var ()
let _vec_fold_u = fresh_var ()
let _vec_fold_region = fresh_var ()
let vec_fold_scheme =
  let tid = match _vec_fold_t with Ast.TyVar v -> v.id | _ -> assert false in
  let uid = match _vec_fold_u with Ast.TyVar v -> v.id | _ -> assert false in
  let rid = match _vec_fold_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [tid; uid; rid];
    body = Ast.TyArrow (
      Ast.TyCon ("Vec", [_vec_fold_region; _vec_fold_t]),
      Ast.TyArrow (
        _vec_fold_u,
        Ast.TyArrow (
          Ast.TyArrow (_vec_fold_u,
            Ast.TyArrow (_vec_fold_t, _vec_fold_u)),
          _vec_fold_u))) }

let _vec_set_elem = fresh_var ()
let _vec_set_region = fresh_var ()
let vec_set_scheme =
  let aid = match _vec_set_elem with Ast.TyVar v -> v.id | _ -> assert false in
  let rid = match _vec_set_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid; rid];
    body = Ast.TyArrow (
      Ast.TyCon ("Vec", [_vec_set_region; _vec_set_elem]),
      Ast.TyArrow (Ast.TyInt,
        Ast.TyArrow (_vec_set_elem, Ast.TyUnit))) }

(* --- OwnedVec[T] (Phase 12.5, Q-010 narrowed → 設計 (b) 別型分離) ---
   `OwnedVec[T]` は heap-allocated, Drop あり vector。`Vec[R, T]`
   (region 内、Trivial) と対照的に、Drop 型として登録されるので
   region に置けない (`Trivial[R]` を破る)。Runtime 実装は `V_vec` を
   共有 — 型システム上だけ区別される。

   設計コンテキスト: 13_region_std_types.md §9「(b) 別型 + trait で
   API 統一」。本 slice は (b) の「別型」部分のみ、trait による API
   統一は後続 slice。 *)
let _ovec_new_alpha = fresh_var ()
let owned_vec_new_scheme =
  let aid = match _ovec_new_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid];
    body = Ast.TyArrow (Ast.TyUnit, Ast.TyCon ("OwnedVec", [_ovec_new_alpha])) }

let _ovec_push_alpha = fresh_var ()
let owned_vec_push_scheme =
  let aid = match _ovec_push_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid];
    body = Ast.TyArrow (
      Ast.TyCon ("OwnedVec", [_ovec_push_alpha]),
      Ast.TyArrow (_ovec_push_alpha, Ast.TyUnit)) }

let _ovec_get_alpha = fresh_var ()
let owned_vec_get_scheme =
  let aid = match _ovec_get_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid];
    body = Ast.TyArrow (
      Ast.TyCon ("OwnedVec", [_ovec_get_alpha]),
      Ast.TyArrow (Ast.TyInt, _ovec_get_alpha)) }

let _ovec_len_alpha = fresh_var ()
let owned_vec_len_scheme =
  let aid = match _ovec_len_alpha with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [aid];
    body = Ast.TyArrow (Ast.TyCon ("OwnedVec", [_ovec_len_alpha]), Ast.TyInt) }

(* OwnedVec[T] (arity 1) を pre-register + drop type 登録。
   drop_types の効果: `&R (vec : T OwnedVec)` のように region に置こうとする
   と `Trivial[R] violated: cannot place value of type `T OwnedVec` into
   region — type contains a Drop type` で reject。 *)
let () =
  Hashtbl.replace types "OwnedVec" 1;
  Hashtbl.replace drop_types "OwnedVec" ()

(* --- StrBuf[R] (Phase 12.7, Q-010 narrowed) ---
   region 内可変文字列バッファ。型は 1-arg `TyCon ("StrBuf",
   [TyRef BorrowedRead R TyUnit])` (region marker のみ、view 型と同じ
   慣例)。Trivial 扱いで region に置ける。`vec_new` と同じく `App
   (Var "strbuf_new", _)` を typer の special handler で active_regions
   から region を bind する。 *)
let _strbuf_new_region = fresh_var ()
let strbuf_new_scheme =
  let rid = match _strbuf_new_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [rid];
    body = Ast.TyArrow (Ast.TyUnit,
      Ast.TyCon ("StrBuf", [_strbuf_new_region])) }

let _strbuf_push_region = fresh_var ()
let strbuf_push_scheme =
  let rid = match _strbuf_push_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [rid];
    body = Ast.TyArrow (
      Ast.TyCon ("StrBuf", [_strbuf_push_region]),
      Ast.TyArrow (Ast.TyStr, Ast.TyUnit)) }

let _strbuf_to_str_region = fresh_var ()
let strbuf_to_str_scheme =
  let rid = match _strbuf_to_str_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [rid];
    body = Ast.TyArrow (
      Ast.TyCon ("StrBuf", [_strbuf_to_str_region]), Ast.TyStr) }

let _strbuf_len_region = fresh_var ()
let strbuf_len_scheme =
  let rid = match _strbuf_len_region with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [rid];
    body = Ast.TyArrow (
      Ast.TyCon ("StrBuf", [_strbuf_len_region]), Ast.TyInt) }

let () = Hashtbl.replace types "StrBuf" 1

(* --- Map[R, K, V] (Phase 12.10, Q-010 narrowed) ---
   region-aware mutable map。型は 3-arg `TyCon ("Map", [TyRef BR R TyUnit;
   K; V])`、region marker + key 型 + value 型。schemes は region / K / V
   それぞれ多相 (TyVar)。`map_new` は active_regions から region binding。 *)
let _map_new_region = fresh_var ()
let _map_new_k = fresh_var ()
let _map_new_v = fresh_var ()
let map_new_scheme =
  let rid = match _map_new_region with Ast.TyVar v -> v.id | _ -> assert false in
  let kid = match _map_new_k with Ast.TyVar v -> v.id | _ -> assert false in
  let vid = match _map_new_v with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [rid; kid; vid];
    body = Ast.TyArrow (Ast.TyUnit,
      Ast.TyCon ("Map", [_map_new_region; _map_new_k; _map_new_v])) }

let _map_set_region = fresh_var ()
let _map_set_k = fresh_var ()
let _map_set_v = fresh_var ()
let map_set_scheme =
  let rid = match _map_set_region with Ast.TyVar v -> v.id | _ -> assert false in
  let kid = match _map_set_k with Ast.TyVar v -> v.id | _ -> assert false in
  let vid = match _map_set_v with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [rid; kid; vid];
    body = Ast.TyArrow (
      Ast.TyCon ("Map", [_map_set_region; _map_set_k; _map_set_v]),
      Ast.TyArrow (_map_set_k,
        Ast.TyArrow (_map_set_v, Ast.TyUnit))) }

let _map_get_region = fresh_var ()
let _map_get_k = fresh_var ()
let _map_get_v = fresh_var ()
let map_get_scheme =
  let rid = match _map_get_region with Ast.TyVar v -> v.id | _ -> assert false in
  let kid = match _map_get_k with Ast.TyVar v -> v.id | _ -> assert false in
  let vid = match _map_get_v with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [rid; kid; vid];
    body = Ast.TyArrow (
      Ast.TyCon ("Map", [_map_get_region; _map_get_k; _map_get_v]),
      Ast.TyArrow (_map_get_k, _map_get_v)) }

let _map_has_region = fresh_var ()
let _map_has_k = fresh_var ()
let _map_has_v = fresh_var ()
let map_has_scheme =
  let rid = match _map_has_region with Ast.TyVar v -> v.id | _ -> assert false in
  let kid = match _map_has_k with Ast.TyVar v -> v.id | _ -> assert false in
  let vid = match _map_has_v with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [rid; kid; vid];
    body = Ast.TyArrow (
      Ast.TyCon ("Map", [_map_has_region; _map_has_k; _map_has_v]),
      Ast.TyArrow (_map_has_k, Ast.TyBool)) }

let _map_len_region = fresh_var ()
let _map_len_k = fresh_var ()
let _map_len_v = fresh_var ()
let map_len_scheme =
  let rid = match _map_len_region with Ast.TyVar v -> v.id | _ -> assert false in
  let kid = match _map_len_k with Ast.TyVar v -> v.id | _ -> assert false in
  let vid = match _map_len_v with Ast.TyVar v -> v.id | _ -> assert false in
  { quantified = [rid; kid; vid];
    body = Ast.TyArrow (
      Ast.TyCon ("Map", [_map_len_region; _map_len_k; _map_len_v]),
      Ast.TyInt) }

let () = Hashtbl.replace types "Map" 3

let initial_env : env =
  [ ("print",       mono (Ast.TyArrow (Ast.TyStr,  Ast.TyUnit)));
    ("read_line",   mono (Ast.TyArrow (Ast.TyUnit, Ast.TyStr)));
    ("time",        mono (Ast.TyArrow (Ast.TyUnit, Ast.TyFloat)));
    ("exit",        exit_scheme);
    ("int_max",     mono Ast.TyInt);
    ("int_min",     mono Ast.TyInt);
    ("print_no_nl", mono (Ast.TyArrow (Ast.TyStr,  Ast.TyUnit)));
    ("print_err",   mono (Ast.TyArrow (Ast.TyStr,  Ast.TyUnit)));
    ("read_file",   mono (Ast.TyArrow (Ast.TyStr,  Ast.TyStr)));
    ("write_file",
       mono (Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyStr, Ast.TyUnit))));
    ("print_int",   mono (Ast.TyArrow (Ast.TyInt,  Ast.TyUnit)));
    ("print_bool",  mono (Ast.TyArrow (Ast.TyBool, Ast.TyUnit)));
    ("str_of_int",  mono (Ast.TyArrow (Ast.TyInt,  Ast.TyStr)));
    ("float_of_int", mono (Ast.TyArrow (Ast.TyInt,  Ast.TyFloat)));
    ("int_of_float", mono (Ast.TyArrow (Ast.TyFloat, Ast.TyInt)));
    ("str_of_float", mono (Ast.TyArrow (Ast.TyFloat, Ast.TyStr)));
    ("float_of_str", mono (Ast.TyArrow (Ast.TyStr,  Ast.TyFloat)));
    ("f_add",       mono (Ast.TyArrow (Ast.TyFloat, Ast.TyArrow (Ast.TyFloat, Ast.TyFloat))));
    ("f_sub",       mono (Ast.TyArrow (Ast.TyFloat, Ast.TyArrow (Ast.TyFloat, Ast.TyFloat))));
    ("f_mul",       mono (Ast.TyArrow (Ast.TyFloat, Ast.TyArrow (Ast.TyFloat, Ast.TyFloat))));
    ("f_div",       mono (Ast.TyArrow (Ast.TyFloat, Ast.TyArrow (Ast.TyFloat, Ast.TyFloat))));
    ("f_lt",        mono (Ast.TyArrow (Ast.TyFloat, Ast.TyArrow (Ast.TyFloat, Ast.TyBool))));
    ("f_le",        mono (Ast.TyArrow (Ast.TyFloat, Ast.TyArrow (Ast.TyFloat, Ast.TyBool))));
    ("f_gt",        mono (Ast.TyArrow (Ast.TyFloat, Ast.TyArrow (Ast.TyFloat, Ast.TyBool))));
    ("f_ge",        mono (Ast.TyArrow (Ast.TyFloat, Ast.TyArrow (Ast.TyFloat, Ast.TyBool))));
    ("f_abs",       mono (Ast.TyArrow (Ast.TyFloat, Ast.TyFloat)));
    ("f_neg",       mono (Ast.TyArrow (Ast.TyFloat, Ast.TyFloat)));
    ("sqrt",        mono (Ast.TyArrow (Ast.TyFloat, Ast.TyFloat)));
    ("floor",       mono (Ast.TyArrow (Ast.TyFloat, Ast.TyFloat)));
    ("ceil",        mono (Ast.TyArrow (Ast.TyFloat, Ast.TyFloat)));
    ("round",       mono (Ast.TyArrow (Ast.TyFloat, Ast.TyFloat)));
    ("pi",          mono Ast.TyFloat);
    ("e",           mono Ast.TyFloat);
    ("not",         mono (Ast.TyArrow (Ast.TyBool, Ast.TyBool)));
    ("str_len",     mono (Ast.TyArrow (Ast.TyStr,  Ast.TyInt)));
    ("int_of_str",  mono (Ast.TyArrow (Ast.TyStr,  Ast.TyInt)));
    ("bool_of_str", mono (Ast.TyArrow (Ast.TyStr,  Ast.TyBool)));
    ("str_contains",
       mono (Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyStr, Ast.TyBool))));
    ("str_count",
       mono (Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyStr, Ast.TyInt))));
    ("str_compare",
       mono (Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyStr, Ast.TyInt))));
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
    ("str_replace",
       mono (Ast.TyArrow (Ast.TyStr,
              Ast.TyArrow (Ast.TyStr,
              Ast.TyArrow (Ast.TyStr, Ast.TyStr)))));
    ("char_at",
       mono (Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyInt, Ast.TyStr))));
    ("chr",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyStr)));
    ("ord",         mono (Ast.TyArrow (Ast.TyStr, Ast.TyInt)));
    ("to_upper",    mono (Ast.TyArrow (Ast.TyStr, Ast.TyStr)));
    ("to_lower",    mono (Ast.TyArrow (Ast.TyStr, Ast.TyStr)));
    ("str_trim",    mono (Ast.TyArrow (Ast.TyStr, Ast.TyStr)));
    ("str_rev",     mono (Ast.TyArrow (Ast.TyStr, Ast.TyStr)));
    ("str_unescape", mono (Ast.TyArrow (Ast.TyStr, Ast.TyStr)));
    ("is_digit",    mono (Ast.TyArrow (Ast.TyStr, Ast.TyBool)));
    ("is_alpha",    mono (Ast.TyArrow (Ast.TyStr, Ast.TyBool)));
    ("is_space",    mono (Ast.TyArrow (Ast.TyStr, Ast.TyBool)));
    ("fail",        fail_scheme);
    ("min",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyArrow (Ast.TyInt, Ast.TyInt))));
    ("max",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyArrow (Ast.TyInt, Ast.TyInt))));
    ("abs",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyInt)));
    ("even",        mono (Ast.TyArrow (Ast.TyInt, Ast.TyBool)));
    ("odd",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyBool)));
    ("sign",        mono (Ast.TyArrow (Ast.TyInt, Ast.TyInt)));
    ("incr",        mono (Ast.TyArrow (Ast.TyInt, Ast.TyInt)));
    ("decr",        mono (Ast.TyArrow (Ast.TyInt, Ast.TyInt)));
    ("sum_range",
       mono (Ast.TyArrow (Ast.TyInt, Ast.TyArrow (Ast.TyInt, Ast.TyInt))));
    ("square",      mono (Ast.TyArrow (Ast.TyInt, Ast.TyInt)));
    ("cube",        mono (Ast.TyArrow (Ast.TyInt, Ast.TyInt)));
    ("divmod",
       mono (Ast.TyArrow (Ast.TyInt,
              Ast.TyArrow (Ast.TyInt,
              Ast.TyTuple [Ast.TyInt; Ast.TyInt]))));
    ("clamp",
       mono (Ast.TyArrow (Ast.TyInt,
              Ast.TyArrow (Ast.TyInt,
              Ast.TyArrow (Ast.TyInt, Ast.TyInt)))));
    ("pow",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyArrow (Ast.TyInt, Ast.TyInt))));
    ("gcd",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyArrow (Ast.TyInt, Ast.TyInt))));
    ("lcm",         mono (Ast.TyArrow (Ast.TyInt, Ast.TyArrow (Ast.TyInt, Ast.TyInt))));
    ("assert",
       mono (Ast.TyArrow (Ast.TyBool, Ast.TyArrow (Ast.TyStr, Ast.TyUnit))));
    ("show",        show_scheme);
    ("len",         len_scheme);
    ("fst",         fst_scheme);
    ("snd",         snd_scheme);
    ("id",          id_scheme);
    ("swap",        swap_scheme);
    ("pair",        pair_scheme);
    ("const",       const_scheme);
    ("flip",        flip_scheme);
    ("try_or",      try_or_scheme);
    ("iter_n",
       mono (Ast.TyArrow (Ast.TyInt,
              Ast.TyArrow (Ast.TyArrow (Ast.TyUnit, Ast.TyUnit), Ast.TyUnit))));
    (* Capability constructors (cf. builtin Logger / Metrics record types
       registered above). *)
    ("mk_logger",  mono (Ast.TyArrow (Ast.TyStr,  Ast.TyCon ("Logger",  []))));
    ("mk_metrics", mono (Ast.TyArrow (Ast.TyUnit, Ast.TyCon ("Metrics", []))));
    (* Vec builtins (Phase 12.1) *)
    ("vec_new",    vec_new_scheme);
    ("vec_iter",   vec_iter_scheme);
    ("vec_map",    vec_map_scheme);
    ("vec_fold",   vec_fold_scheme);
    ("vec_set",    vec_set_scheme);
    ("owned_vec_new",  owned_vec_new_scheme);
    ("owned_vec_push", owned_vec_push_scheme);
    ("owned_vec_get",  owned_vec_get_scheme);
    ("owned_vec_len",  owned_vec_len_scheme);
    ("strbuf_new",     strbuf_new_scheme);
    ("strbuf_push",    strbuf_push_scheme);
    ("strbuf_to_str",  strbuf_to_str_scheme);
    ("strbuf_len",     strbuf_len_scheme);
    ("map_new",        map_new_scheme);
    ("map_set",        map_set_scheme);
    ("map_get",        map_get_scheme);
    ("map_has",        map_has_scheme);
    ("map_len",        map_len_scheme);
    ("vec_push",   vec_push_scheme);
    ("vec_get",    vec_get_scheme);
    ("vec_len",    vec_len_scheme);
  ]

let rec infer (env : env) (e : Ast.expr) : Ast.ty =
  let t = infer_node env e in
  e.Ast.ty <- Some t;
  t

and infer_node (env : env) (e : Ast.expr) : Ast.ty =
  match e.node with
  | Ast.Int_lit _ -> Ast.TyInt
  | Ast.Float_lit _ -> Ast.TyFloat
  | Ast.Bool_lit _ -> Ast.TyBool
  | Ast.Str_lit _ -> Ast.TyStr
  | Ast.Unit_lit -> Ast.TyUnit
  | Ast.Var name ->
    (try instantiate (List.assoc name env)
     with Not_found ->
       raise_with_suggestion e.loc "unbound variable" name
         (List.map fst env))
  | Ast.Neg a ->
    let t = infer env a in
    unify a.loc Ast.TyInt t;
    Ast.TyInt
  | Ast.Bin (op, a, b) ->
    let ta = infer env a in
    let tb = infer env b in
    (match op with
     | Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod ->
       unify a.loc Ast.TyInt ta;
       unify b.loc Ast.TyInt tb;
       Ast.TyInt
     | Ast.Concat ->
       unify a.loc Ast.TyStr ta;
       unify b.loc Ast.TyStr tb;
       Ast.TyStr)
  | Ast.Cmp (op, a, b) ->
    let ta = infer env a in
    let tb = infer env b in
    (match op with
     | Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge ->
       unify a.loc Ast.TyInt ta;
       unify b.loc Ast.TyInt tb
     | Ast.Eq | Ast.Ne ->
       (* Symmetric: lhs is the "first observed" type. *)
       unify e.loc ta tb);
    Ast.TyBool
  | Ast.Logic (_, a, b) ->
    let ta = infer env a in
    let tb = infer env b in
    unify a.loc Ast.TyBool ta;
    unify b.loc Ast.TyBool tb;
    Ast.TyBool
  | Ast.If (cond, then_, else_) ->
    let tc = infer env cond in
    unify cond.loc Ast.TyBool tc;
    let tt = infer env then_ in
    let te = infer env else_ in
    (* `then` branch sets the expected type; `else` must match. *)
    unify else_.loc tt te;
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
    (* Phase 3.1: `with c = v in body` requires v's type to be a Drop type
       (declared via `drop type ...`). At runtime, the value's `close`
       field (if present) is invoked when the with-scope ends. *)
    let tv = infer env value in
    if not (contains_drop_type tv) then
      raise (Type_error (e.loc,
        Printf.sprintf
          "`with` binding `%s` requires a Drop type (use `let` for Trivial values); \
           got `%s`"
          name (Ast.pp_ty tv)));
    let sch = generalize env tv in
    infer ((name, sch) :: env) body
  | Ast.Region_block (name, body) ->
    (* Phase 2: introduce region name R in scope, then check that R does not
       escape the block (i.e., body's resulting type should not mention R).
       Also push name on active_regions so view constructions inside the
       block can substitute R with the active region (Phase 2.3). *)
    active_regions := name :: !active_regions;
    let t =
      try infer env body
      with ex ->
        active_regions := List.tl !active_regions;
        raise ex
    in
    active_regions := List.tl !active_regions;
    if mentions_region name (Ast.walk t) then
      raise (Type_error (e.loc,
        Printf.sprintf
          "region escape: value of type `%s` cannot leave region `%s`"
          (Ast.pp_ty t) name));
    t
  | Ast.Ref (mode, region, inner) ->
    (* `&R e` — tag the value's type with region R. Enforces the Trivial[R]
       constraint: the inner value's type must not mention any Drop type. *)
    let t = infer env inner in
    if contains_drop_type t then
      raise (Type_error (e.loc,
        Printf.sprintf
          "Trivial[%s] violated: cannot place value of type `%s` into region — \
           type contains a Drop type (use `with` to manage Drop cap lifetimes)"
          region (Ast.pp_ty t)));
    Ast.TyRef (mode, region, t)
  | Ast.Fun (param, ty_opt, body) ->
    let alpha = fresh_var () in
    (match ty_opt with
     | Some t ->
       let t', _ = freshen_params t in
       (* User-supplied annotation is the expected type. *)
       unify e.loc t' alpha
     | None -> ());
    let tb = infer ((param, mono alpha) :: env) body in
    Ast.TyArrow (alpha, tb)
  | Ast.App (f, arg) ->
    let tf = infer env f in
    let ta = infer env arg in
    (* Phase 12.3 special case: `vec_new ()` binds its return type's
       region marker to the innermost active region (or `__heap` if
       there is none). This gives `Vec[R, T]` real semantic teeth — the
       construction-time region is recorded in the value's type, same
       view-style binding pattern. The Var path is preserved so
       `vec_new` as a first-class value still has its polymorphic
       scheme; only direct application triggers the binding. *)
    (match f.Ast.node with
     | Ast.Var "vec_new" ->
       let active_region =
         match !active_regions with
         | r :: _ -> r
         | [] -> "__heap"
       in
       let marker =
         Ast.TyRef (Ast.BorrowedRead, active_region, Ast.TyUnit)
       in
       let result_ty = Ast.TyCon ("Vec", [marker; fresh_var ()]) in
       (* Force the scheme's region tyvar to bind to our marker by
          unifying through the call. *)
       unify e.loc tf (Ast.TyArrow (ta, result_ty));
       result_ty
     | Ast.Var "strbuf_new" ->
       let active_region =
         match !active_regions with
         | r :: _ -> r
         | [] -> "__heap"
       in
       let marker =
         Ast.TyRef (Ast.BorrowedRead, active_region, Ast.TyUnit)
       in
       let result_ty = Ast.TyCon ("StrBuf", [marker]) in
       unify e.loc tf (Ast.TyArrow (ta, result_ty));
       result_ty
     | Ast.Var "map_new" ->
       let active_region =
         match !active_regions with
         | r :: _ -> r
         | [] -> "__heap"
       in
       let marker =
         Ast.TyRef (Ast.BorrowedRead, active_region, Ast.TyUnit)
       in
       let result_ty =
         Ast.TyCon ("Map", [marker; fresh_var (); fresh_var ()]) in
       unify e.loc tf (Ast.TyArrow (ta, result_ty));
       result_ty
     | _ ->
    (match Ast.walk tf with
     | Ast.TyArrow (param_ty, ret_ty) ->
       (* tf is a concrete arrow: unify param ↔ arg directly so the
          error reads "expected <param>, got <arg>" at the arg's loc. *)
       unify arg.loc param_ty ta;
       ret_ty
     | Ast.TyVar _ ->
       (* fn type is still a free tyvar — fall back to whole-arrow unify
          (which then specializes the tyvar to (arg → result)). *)
       let result = fresh_var () in
       unify e.loc tf (Ast.TyArrow (ta, result));
       result
     | _ ->
       (* Calling a concrete non-arrow value — most often "extra
          argument to a fully-applied function" or applying a literal. *)
       let msg =
         Printf.sprintf
           "expected a function (`'a -> 'b`), got `%s`" (Ast.pp_ty tf)
       in
       let msg =
         msg ^
         "\nhelp: you may be passing one too many arguments (the call's \
          left side is already a value, not a function)"
       in
       raise (Type_error (f.loc, msg))))
  | Ast.Annot (inner, t) ->
    let t', _ = freshen_params t in
    let ti = infer env inner in
    (* Annotation declares the expected type. *)
    unify e.loc t' ti;
    t'
  | Ast.Constr (name, arg_opt) ->
    let info =
      try Hashtbl.find constructors name
      with Not_found ->
        let candidates =
          Hashtbl.fold (fun k _ acc -> k :: acc) constructors []
        in
        raise_with_suggestion e.loc "unknown constructor" name candidates
    in
    let (expected_arg, result_ty) = instantiate_constr info in
    (match expected_arg, arg_opt with
     | None, None -> result_ty
     | Some exp, Some arg ->
       let ta = infer env arg in
       unify arg.loc exp ta;
       result_ty
     | None, Some _ ->
       raise (Type_error (e.loc,
         "constructor " ^ name ^ " takes no argument"))
     | Some _, None ->
       raise (Type_error (e.loc,
         "constructor " ^ name ^ " requires an argument")))
  | Ast.Match (scrut, arms) ->
    let t_scrut = infer env scrut in
    Exhaustive.record_match e.loc t_scrut arms;
    let result_var = fresh_var () in
    List.iter (fun (pat, guard, branch) ->
      let bindings = check_pattern pat t_scrut in
      let env' = List.fold_left (fun acc (n, t) -> (n, mono t) :: acc) env bindings in
      (match guard with
       | None -> ()
       | Some g ->
         let tg = infer env' g in
         unify g.Ast.loc Ast.TyBool tg);
      let tb = infer env' branch in
      (* Result var collects each arm's type; first arm sets the
         "expected" for subsequent arms. *)
      unify branch.loc result_var tb
    ) arms;
    result_var
  | Ast.Tuple es ->
    let ts = List.map (infer env) es in
    Ast.TyTuple ts
  | Ast.Record_lit (name, fields) ->
    (* If name is a registered view, enforce construction-inside-region and
       substitute the view's region param with the innermost active region. *)
    (match Hashtbl.find_opt views name with
     | Some vinfo ->
       let target_region =
         match !active_regions with
         | [] ->
           raise (Type_error (e.loc,
             Printf.sprintf
               "view %s must be constructed inside a region block" name))
         | r :: _ -> r
       in
       let expected_fields =
         List.map (fun (f, t) ->
           (f, subst_region vinfo.v_region_param target_region t)
         ) vinfo.v_fields
       in
       let provided_names = List.map fst fields in
       let expected_names = List.map fst expected_fields in
       if List.sort compare provided_names <> List.sort compare expected_names then
         raise (Type_error (e.loc,
           Printf.sprintf "view %s: field set mismatch (expected: %s, got: %s)"
             name
             (String.concat ", " expected_names)
             (String.concat ", " provided_names)));
       List.iter (fun (fname, fexpr) ->
         let exp_ty = List.assoc fname expected_fields in
         let t = infer env fexpr in
         unify fexpr.loc exp_ty t
       ) fields;
       (* Trivial[R] for view: no field may have a Drop type since the view
          is constructed in the region. *)
       List.iter (fun (fname, ft) ->
         if contains_drop_type ft then
           raise (Type_error (e.loc,
             Printf.sprintf
               "Trivial[%s] violated: view %s field `%s` has Drop type `%s`"
               target_region name fname (Ast.pp_ty ft)))
       ) expected_fields;
       (* Encode the construction-time region in the value's type so that
          field access can later substitute the view's region param with
          the actual region. The TyRef-of-unit marker is recognized by
          Field_get / Record_update / pp_ty. *)
       Ast.TyCon (name, [Ast.TyRef (Ast.BorrowedRead, target_region, Ast.TyUnit)])
     | None ->
       let info =
         try Hashtbl.find records name
         with Not_found ->
           let candidates =
             Hashtbl.fold (fun k _ acc -> k :: acc) records []
           in
           raise_with_suggestion e.loc "unknown record type" name candidates
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
         unify fexpr.loc exp_ty t
       ) fields;
       result_ty)
  | Ast.Field_get (inner, fname) ->
    let t_inner = infer env inner in
    (* The inner expression must have type `TyCon (rec_name, args)` for some
       declared record `rec_name`.  Walk to resolve type vars. We also
       transparently strip `&[mode] R T` wrappers (Phase 11.3 auto-deref):
       `lg_ref.info` resolves through the borrow to the underlying record.
       Borrow mode is purely a static contract — eval sees the record value
       directly, so no run-time deref. *)
    let rec strip_refs t =
      match Ast.walk t with
      | Ast.TyRef (_, _, inner_t) -> strip_refs inner_t
      | t' -> t'
    in
    (match strip_refs t_inner with
     | Ast.TyCon (view_name, [Ast.TyRef (_, region, Ast.TyUnit)])
       when Hashtbl.mem views view_name ->
       (* View field access: substitute the view's region param with the
          construction-time region recorded in the value's type. *)
       let vinfo = Hashtbl.find views view_name in
       (try
          let raw_ty = List.assoc fname vinfo.v_fields in
          subst_region vinfo.v_region_param region raw_ty
        with Not_found ->
          raise (Type_error (e.loc,
            Printf.sprintf "view %s has no field %s" view_name fname)))
     | Ast.TyCon (rec_name, _) as t_stripped
       when Hashtbl.mem records rec_name ->
       let info = Hashtbl.find records rec_name in
       let (expected_fields, result_ty) = instantiate_record rec_name info in
       unify inner.loc result_ty t_stripped;
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
     | Ast.TyCon (view_name, [Ast.TyRef (_, region, Ast.TyUnit)]) as t_view
       when Hashtbl.mem views view_name ->
       (* View record update: substitute region in each updated field's
          declared type, type-check, and return the same view-typed value. *)
       let vinfo = Hashtbl.find views view_name in
       List.iter (fun (fname, fexpr) ->
         let raw_ty =
           try List.assoc fname vinfo.v_fields
           with Not_found ->
             raise (Type_error (e.loc,
               Printf.sprintf "view %s has no field %s" view_name fname))
         in
         let exp_ty = subst_region vinfo.v_region_param region raw_ty in
         let t = infer env fexpr in
         unify fexpr.loc exp_ty t
       ) updates;
       t_view
     | Ast.TyCon (rec_name, _) when Hashtbl.mem records rec_name ->
       let info = Hashtbl.find records rec_name in
       let (expected_fields, result_ty) = instantiate_record rec_name info in
       unify base.loc result_ty t_base;
       List.iter (fun (fname, fexpr) ->
         let exp_ty =
           try List.assoc fname expected_fields
           with Not_found ->
             raise (Type_error (e.loc,
               Printf.sprintf "record %s has no field %s" rec_name fname))
         in
         let t = infer env fexpr in
         unify fexpr.loc exp_ty t
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
        let candidates =
          Hashtbl.fold (fun k _ acc -> k :: acc) constructors []
        in
        raise_with_suggestion p.ploc "unknown constructor in pattern" name
          candidates
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
        let candidates =
          Hashtbl.fold (fun k _ acc -> k :: acc) records []
        in
        raise_with_suggestion p.ploc "unknown record type in pattern" name
          candidates
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
  | Ast.P_as (inner, name) ->
    (* Match inner pattern + bind the whole matched value to `name`. *)
    let inner_bindings = check_pattern inner expected in
    (name, expected) :: inner_bindings
  | Ast.P_or (p1, p2) ->
    (* Both branches must bind the same set of names with unified types. *)
    let bs1 = check_pattern p1 expected in
    let bs2 = check_pattern p2 expected in
    let names1 = List.sort compare (List.map fst bs1) in
    let names2 = List.sort compare (List.map fst bs2) in
    if names1 <> names2 then
      raise (Type_error (p.ploc,
        Printf.sprintf
          "or-pattern branches bind different names: [%s] vs [%s]"
          (String.concat ", " names1)
          (String.concat ", " names2)));
    List.iter (fun (n, t1) ->
      let t2 = List.assoc n bs2 in
      unify p.ploc t1 t2
    ) bs1;
    bs1

let type_check e =
  counter := 0;
  infer initial_env e

(* === Borrow checker (Phase 11.4) ===

   Static check for "same value, same region, conflicting borrow modes
   active simultaneously". Tracks `&[mode] R x` borrows where `x` is a
   simple `Var name`; complex borrowees (`&R record.field`, literals
   etc.) are out of scope for this slice — they don't have a stable
   identity to conflict on.

   Conflict matrix — two borrows `B1`, `B2` on the same (region, var)
   coexist iff:
     - both are BorrowedRead (multiple shared read)
     - both are SharedWrite (multiple shared write, cap-internal lock)
   Anything else conflicts (exclusive borrows + anything else, or
   mixing shared-read with shared-write).

   The checker walks the expression, threading a list of currently
   active borrows. When entering a `Let p = (&[m] R x) in body`, the
   new borrow is added to `body`'s active set. Borrows do not survive
   past the `body`. Borrows introduced by free-standing `&[m] R x`
   (not via Let) must not conflict with currently-active borrows; the
   borrow itself ends with the expression. *)
let borrows_compatible m1 m2 =
  match m1, m2 with
  | Ast.BorrowedRead, Ast.BorrowedRead -> true
  | Ast.SharedWrite,  Ast.SharedWrite  -> true
  | _ -> false

let mode_label = function
  | Ast.BorrowedRead -> "&R"
  | Ast.SharedWrite -> "&shared write R"
  | Ast.ExclusiveRead -> "&exclusive R"
  | Ast.ExclusiveWrite -> "&mut R"

(* Phase 11.5: 借用 target の identity を抽出するヘルパ。Var だけでなく
   `p.field` / `p.q.r` のような Field_get chain も追跡対象にする。
   Returns Some "<dotted>" or None when the borrowee is something more
   complex (a function call result, a literal, etc.) — None だと borrow
   tracking の対象外 (= 衝突検出なし) になる。 *)
let rec place_id (e : Ast.expr) : string option =
  match e.Ast.node with
  | Ast.Var n -> Some n
  | Ast.Field_get (inner, fname) ->
    (match place_id inner with
     | Some s -> Some (s ^ "." ^ fname)
     | None -> None)
  | _ -> None

(* `active` is a list of (region, place_id, mode, loc) describing
   borrows in scope. `place_id` is a stable string identity for the
   borrowee (see `place_id` helper). *)
let check_borrow_conflict active region place mode loc =
  List.iter (fun (r', p', m', loc') ->
    if r' = region && p' = place
       && not (borrows_compatible mode m') then begin
      let msg =
        Printf.sprintf
          "borrow conflict: `%s` is already borrowed as `%s %s` here, \
           cannot reborrow as `%s %s`\n\
           note: previous borrow at line %d, col %d"
          place (mode_label m') place (mode_label mode) place
          loc'.Loc.line loc'.Loc.col
      in
      raise (Type_error (loc, msg))
    end
  ) active

(* Phase 11.6: 制御フロー解析の最小版。式が「let の右辺として bind
   された時に、上に伝播し得る borrow」のリストを抽出する。
   - Ref (mode, region, inner): その borrow を 1 つ返す (place が
     追跡可能なら)
   - If (cond, t, e): 両分岐から抽出した borrow を union (どちらに
     なるかは runtime 依存なので保守的に両方とも active と見なす)
   - Let (_, _, body): body から抽出 (let-in を value 位置に書いた場合)
   - Annot (inner, _): inner から抽出
   - それ以外: 空リスト *)
let rec extract_borrows (e : Ast.expr) : (string * string * Ast.borrow_mode * Loc.t) list =
  match e.Ast.node with
  | Ast.Ref (mode, region, inner) ->
    (match place_id inner with
     | Some p -> [(region, p, mode, e.Ast.loc)]
     | None -> [])
  | Ast.If (_, t, el) ->
    extract_borrows t @ extract_borrows el
  | Ast.Let (_, _, body) -> extract_borrows body
  | Ast.Annot (inner, _) -> extract_borrows inner
  | _ -> []

let rec check_borrows active (e : Ast.expr) : unit =
  let go e = check_borrows active e in
  match e.node with
  | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _
  | Ast.Str_lit _ | Ast.Unit_lit | Ast.Var _ -> ()
  | Ast.Neg a -> go a
  | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b) ->
    go a; go b
  | Ast.If (c, t, el) -> go c; go t; go el
  | Ast.App (f, a) -> go f; go a
  | Ast.Annot (inner, _) -> go inner
  | Ast.Constr (_, None) -> ()
  | Ast.Constr (_, Some a) -> go a
  | Ast.Tuple es -> List.iter go es
  | Ast.Region_block (_, body) -> go body
  | Ast.Fun (_, _, body) -> go body
  | Ast.Record_lit (_, fields) -> List.iter (fun (_, e') -> go e') fields
  | Ast.Field_get (inner, _) -> go inner
  | Ast.Record_update (base, updates) ->
    go base; List.iter (fun (_, e') -> go e') updates
  | Ast.Match (scrut, arms) ->
    go scrut;
    List.iter (fun (_, guard, body) ->
      Option.iter go guard; go body
    ) arms
  | Ast.With (_, value, body) -> go value; go body
  | Ast.Ref (mode, region, inner) ->
    (* The borrow itself must not conflict with any currently-active
       borrow on the same (region, place). Place identity is computed
       via `place_id` — Var + Field_get chains are tracked; anything
       else falls outside borrow tracking (Phase 11.5 widened from
       Phase 11.4's Var-only). *)
    (match place_id inner with
     | Some p -> check_borrow_conflict active region p mode e.loc
     | None -> ());
    go inner
  | Ast.Let (pat, value, body) ->
    check_borrows active value;
    (* Extend the active set with any borrows produced by `value`.
       Phase 11.6: traverse If branches and nested Let bodies to find
       borrows that flow up to the let-binding. Each extracted borrow
       is conflict-checked against the existing active set. *)
    let active' =
      match pat.Ast.pnode with
      | Ast.P_var _ ->
        let new_borrows = extract_borrows value in
        List.iter (fun (r, p, m, lc) ->
          check_borrow_conflict active r p m lc
        ) new_borrows;
        new_borrows @ active
      | _ -> active
    in
    check_borrows active' body
  | Ast.Let_rec (bindings, body) ->
    List.iter (fun (_, v) -> check_borrows active v) bindings;
    check_borrows active body
