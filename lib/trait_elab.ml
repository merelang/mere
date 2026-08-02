(* Trait elaboration — dictionary passing.

   Mere resolves ad-hoc polymorphism (user traits) by *elaboration*: after
   type inference has resolved every trait-parameter to a concrete type (or to
   a generic function's own constrained variable), this pass rewrites the whole
   program into plain Mere with no trait constructs, so no backend
   (interpreter / C / LLVM / Wasm) needs any trait-specific support.

   The lowering is the classic type-class -> dictionary translation:

     trait Num 'a { add : 'a -> 'a -> 'a; zero : 'a; }
        ==>  type 'a Num__dict = { add : 'a -> 'a -> 'a; zero : 'a };

     impl Num int { add = fn x -> fn y -> x + y; zero = 0; }
        ==>  let Num__int__dict = Num__dict { add = ...; zero = 0 };

     let sum = fn xs -> list_fold xs zero (fn a -> fn x -> add a x);
     -- sum is inferred to be `Num 'a => 'a list -> 'a`, so it gains a
     -- leading dictionary parameter, and its trait-method uses become
     -- field accesses on that dictionary:
        ==>  let sum = fn __dict_Num -> fn xs ->
                        list_fold xs __dict_Num.zero
                          (fn a -> fn x -> __dict_Num.add a x);

     sum [1, 2, 3]            ==>  sum Num__int__dict [1, 2, 3]
     sum [1.0, 2.0, 3.0]      ==>  sum Num__float__dict [1.0, 2.0, 3.0]

   The single dispatch value `zero` (return-position polymorphic, so it can
   never be resolved by runtime dispatch) falls out for free: it is just a
   field of the passed dictionary.

   A program that declares no trait / impl is returned untouched (the fast
   path below), so every existing program and every backend is byte-identical. *)

open Ast

exception Trait_error of Loc.t * string

(* --- generic structural map over an expression ---------------------------
   `subst e` returns `Some replacement` to substitute this node wholesale (the
   replacement is NOT re-descended into), or `None` to rebuild it from mapped
   children. Physical identity of the original node is what the caller keys on. *)
let rec map_expr (subst : expr -> expr option) (e : expr) : expr =
  match subst e with
  | Some r -> r
  | None ->
    let go = map_expr subst in
    let node =
      match e.node with
      | Int_lit _ | Float_lit _ | Bool_lit _ | Str_lit _ | Unit_lit
      | Var _ -> e.node
      | Bin (op, a, b) -> Bin (op, go a, go b)
      | Cmp (op, a, b) -> Cmp (op, go a, go b)
      | Logic (op, a, b) -> Logic (op, go a, go b)
      | Neg a -> Neg (go a)
      | Let (p, v, b) -> Let (p, go v, go b)
      | Let_rec (bs, b) -> Let_rec (List.map (fun (n, v) -> (n, go v)) bs, go b)
      | With (s, v, b) -> With (s, go v, go b)
      | If (c, t, el) -> If (go c, go t, go el)
      | Fun (s, ty, b) -> Fun (s, ty, go b)
      | App (a, b) -> App (go a, go b)
      | Annot (a, ty) -> Annot (go a, ty)
      | Constr (s, arg) -> Constr (s, Option.map go arg)
      | Match (scrut, arms) ->
        Match (go scrut,
          List.map (fun (p, guard, body) ->
            (p, Option.map go guard, go body)) arms)
      | Tuple es -> Tuple (List.map go es)
      | Region_block (r, b) -> Region_block (r, go b)
      | Ref (m, r, inner) -> Ref (m, r, go inner)
      | Record_lit (name, fields) ->
        Record_lit (name, List.map (fun (f, v) -> (f, go v)) fields)
      | Field_get (a, f) -> Field_get (go a, f)
      | Record_update (base, fields) ->
        Record_update (go base, List.map (fun (f, v) -> (f, go v)) fields)
    in
    { e with node }

let mk loc node = { loc; ty = None; node }
let mk_pat pnode = { ploc = Loc.dummy; pnode }

(* Substitute the trait parameter (a `TyParam param`) with the concrete
   instance type `target` throughout a method signature. Used to annotate each
   impl method body at its concrete type, so numeric operators (`+`, `*`, ...)
   — which otherwise default to int — specialise correctly (e.g. the `float`
   impl's `fn x -> fn y -> x + y` becomes float addition). *)
let rec subst_param param target (t : ty) : ty =
  match t with
  | TyParam p -> if p = param then target else t
  | TyInt | TyFloat | TyBool | TyStr | TyUnit | TyVar _ -> t
  | TyArrow (a, b) -> TyArrow (subst_param param target a, subst_param param target b)
  | TyTuple ts -> TyTuple (List.map (subst_param param target) ts)
  | TyCon (n, args) -> TyCon (n, List.map (subst_param param target) args)
  | TyRef (m, r, inner) -> TyRef (m, r, subst_param param target inner)

(* Annotate an impl method body at its concrete type. Mere's `(e : T)` is a
   post-hoc unification, so it does NOT push the type into a lambda's
   parameters — and `fn x -> fn y -> x + y` would default `+` to int before the
   ascription is checked. So we push the concrete type into the lambda spine
   directly (annotating each parameter) and ascribe the final scalar result. *)
let rec annotate_impl (concrete : ty) (body : expr) : expr =
  match body.node, concrete with
  | Fun (x, _, inner), TyArrow (pt, rt) ->
    { body with node = Fun (x, Some pt, annotate_impl rt inner) }
  | _ -> { body with node = Annot (body, concrete) }

let dict_type_name trait = trait ^ "__dict"
let dict_value_name trait key = trait ^ "__" ^ key ^ "__dict"
let dict_param_name trait vid = "__dict_" ^ trait ^ "_" ^ string_of_int vid

(* Register trait / impl declarations into the typer, then run a throwaway
   type-inference pass over the whole program. Its sole purpose is to populate
   `Typer.trait_obligations` and the per-binding constraint sets, which the
   rewrite below consumes. The real pipeline re-types the elaborated (plain
   Mere) program afterwards. *)
let type_pass (prog : program) : (string, Typer.scheme) Hashtbl.t =
  let schemes : (string, Typer.scheme) Hashtbl.t = Hashtbl.create 16 in
  let type_env = ref Typer.initial_env in
  List.iter (fun decl ->
    match decl with
    | Top_let (pat, value) ->
      let outer = !type_env in
      let t = Typer.infer outer value in
      let bindings = Typer.check_pattern pat t in
      type_env := List.fold_left (fun acc (n, ty) ->
        let sch = Typer.generalize outer ty in
        Hashtbl.replace schemes n sch;
        (n, sch) :: acc) outer bindings
    | Top_let_rec bindings ->
      let outer = !type_env in
      let alphas = List.map (fun _ -> Typer.fresh_var ()) bindings in
      let env_rec = List.fold_left2 (fun acc (n, _) a ->
        (n, Typer.mono a) :: acc) outer bindings alphas in
      List.iter2 (fun (_, value) alpha ->
        let t = Typer.infer env_rec value in
        Typer.unify value.loc alpha t) bindings alphas;
      type_env := List.fold_left2 (fun acc (n, _) a ->
        let sch = Typer.generalize outer a in
        Hashtbl.replace schemes n sch;
        (n, sch) :: acc) outer bindings alphas
    | Top_type (name, params, variants) -> Typer.register_type name params variants
    | Top_record (name, params, fields) -> Typer.register_record name params fields
    | Top_view (name, region, fields) -> Typer.register_view name region fields
    | Top_drop name -> Typer.register_drop_type name
    | Top_sync name -> Typer.register_sync_type name
    | Top_local name -> Typer.register_local_type name
    | Top_extern (name, ty) -> type_env := (name, Typer.mono ty) :: !type_env
    | Top_extern_type name -> Typer.register_type name [] []
    | Top_ctor_alias (a, t) -> Typer.alias_ctor a t
    | Top_record_alias (a, t) -> Typer.alias_record a t
    | Top_signature _ | Top_type_alias _ -> ()
    | Top_impl (_, _, methods) ->
      (* Type-check impl bodies so obligations inside them are recorded. *)
      List.iter (fun (_, v) -> ignore (Typer.infer !type_env v)) methods
    | Top_trait _ -> ()
  ) prog.decls;
  ignore (Typer.infer !type_env prog.main);
  schemes

let elaborate (prog : program) : program =
  let has_trait_decls =
    List.exists (function Top_trait _ | Top_impl _ -> true | _ -> false)
      prog.decls
  in
  if not has_trait_decls then prog
  else begin
    (* trait name -> (param, methods) for building dict records / values *)
    let trait_info : (string, string * (string * ty) list) Hashtbl.t =
      Hashtbl.create 8 in
    Typer.reset_traits ();
    List.iter (function
      | Top_trait (name, param, methods) ->
        Hashtbl.replace trait_info name (param, methods);
        Typer.register_trait name param methods
      | Top_impl (trait, target, _) -> Typer.register_impl trait target
      | _ -> ()) prog.decls;

    let schemes = type_pass prog in

    (* Global map: a constrained binding's quantified variable id -> the name
       of the dictionary parameter that binding receives. Also the ordered
       parameter list per binding name (for wrapping its definition). *)
    let var2param : (int, string) Hashtbl.t = Hashtbl.create 16 in
    (* name -> ordered [(param, trait)] the binding receives *)
    let binding_params : (string, (string * string) list) Hashtbl.t =
      Hashtbl.create 16 in
    Hashtbl.iter (fun name sch ->
      if sch.Typer.constraints <> [] then begin
        let params =
          List.map (fun (trait, vid) ->
            let p = dict_param_name trait vid in
            Hashtbl.replace var2param vid p;
            (p, trait)) sch.Typer.constraints
        in
        Hashtbl.replace binding_params name params
      end) schemes;

    (* Resolve the dictionary expression for a trait at a dispatch type. *)
    let resolve_dict loc trait (dispatch : ty) : expr =
      match Ast.walk dispatch with
      | Ast.TyVar v ->
        (match Hashtbl.find_opt var2param v.id with
         | Some p -> mk loc (Var p)
         | None ->
           raise (Trait_error (loc,
             Printf.sprintf
               "ambiguous trait constraint `%s` — the type it applies to \
                could not be resolved at this use site" trait)))
      | concrete ->
        (match Typer.trait_type_key concrete with
         | Some key ->
           if Hashtbl.mem Typer.trait_impls (trait ^ "@" ^ key) then
             mk loc (Var (dict_value_name trait key))
           else
             raise (Trait_error (loc,
               Printf.sprintf "no `impl %s %s`" trait key))
         | None ->
           raise (Trait_error (loc,
             Printf.sprintf
               "trait `%s` instance type is not supported here (only simple \
                types: int / float / bool / str / unit / a nullary user type)"
               trait)))
    in

    (* Build the physical-identity replacement table from the obligations. *)
    let replacements : (expr * expr) list =
      List.map (fun ob ->
        match ob with
        | Typer.Ob_method (node, trait, meth, dispatch) ->
          let dict = resolve_dict node.loc trait dispatch in
          (node, mk node.loc (Field_get (dict, meth)))
        | Typer.Ob_constrained (node, cs) ->
          (* Insert one dictionary argument per constraint, in order. *)
          let applied =
            List.fold_left (fun acc (trait, dispatch) ->
              let dict = resolve_dict node.loc trait dispatch in
              mk node.loc (App (acc, dict)))
              node cs
          in
          (node, applied)
      ) !Typer.trait_obligations
    in
    let subst e =
      match List.find_opt (fun (n, _) -> n == e) replacements with
      | Some (_, r) -> Some r
      | None -> None
    in
    let rewrite = map_expr subst in

    (* Wrap a constrained binding's value with its leading dictionary params. *)
    let wrap_dict_params name value =
      match Hashtbl.find_opt binding_params name with
      | None -> value
      | Some params ->
        List.fold_right (fun (p, trait) acc ->
          (* Annotate the dict parameter with its record type so the field
             accesses inside the body type-check; the single `TyParam "a"` is
             freshened to one variable that the body then unifies with the
             element type via `zero` / `add`. *)
          let dict_ty = TyCon (dict_type_name trait, [TyParam "a"]) in
          mk value.loc (Fun (p, Some dict_ty, acc))) params value
    in

    (* Rewrite each declaration in place, preserving source order (so type /
       value dependencies stay valid). *)
    let rewrite_decl decl =
      match decl with
      | Top_trait (name, param, methods) ->
        Top_record (dict_type_name name, [param], methods)
      | Top_impl (trait, target, impls) ->
        let key = match Typer.trait_type_key target with
          | Some k -> k
          | None ->
            raise (Trait_error (Loc.dummy,
              Printf.sprintf "impl %s: unsupported instance type" trait))
        in
        let param, methods = Hashtbl.find trait_info trait in
        (* Emit fields in trait-declaration order; each impl body is rewritten
           (an impl may itself use trait methods) and annotated at the concrete
           instance type so numeric-operator defaulting resolves correctly. *)
        let fields =
          List.map (fun (mname, mty) ->
            match List.assoc_opt mname impls with
            | Some body ->
              let concrete_ty = subst_param param target mty in
              (mname, annotate_impl concrete_ty (rewrite body))
            | None ->
              raise (Trait_error (Loc.dummy,
                Printf.sprintf "impl %s %s: missing method `%s`" trait key mname)))
            methods
        in
        let dict_lit = mk Loc.dummy (Record_lit (dict_type_name trait, fields)) in
        Top_let (mk_pat (P_var (dict_value_name trait key)), dict_lit)
      | Top_let (({ pnode = P_var name; _ }) as p, value) ->
        Top_let (p, wrap_dict_params name (rewrite value))
      | Top_let (p, value) -> Top_let (p, rewrite value)
      | Top_let_rec bindings ->
        List.iter (fun (n, _) ->
          if Hashtbl.mem binding_params n then
            raise (Trait_error (Loc.dummy,
              Printf.sprintf
                "recursive constrained function `%s` is not yet supported \
                 (define it non-recursively, e.g. via list_fold)" n)))
          bindings;
        Top_let_rec (List.map (fun (n, v) -> (n, rewrite v)) bindings)
      | other -> other
    in
    let decls = List.map rewrite_decl prog.decls in
    let main = rewrite prog.main in
    (* Clear trait state, and the Send obligations accumulated by the
       throwaway type pass, so the real (post-elaboration) pass starts clean
       and sees plain Mere with no traits in play. *)
    Typer.reset_traits ();
    Typer.reset_send_constraints ();
    { decls; main }
  end
