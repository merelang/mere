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
    | Top_impl (trait, target, methods) ->
      (* Type-check impl bodies so obligations inside them are recorded, and
         unify each body with its method signature at the concrete instance
         type (`param := target`). Without this the body is inferred
         generically, so a use of another trait's method (e.g. a super-trait
         method) on the instance value keeps an unresolved dispatch variable
         and later fails to resolve to a dictionary. Fixing the instance type
         makes such uses concrete, so they resolve to that trait's concrete
         dictionary. (Same-trait sibling uses are already inlined away before
         this pass, so they never reach here to cause a self-referential
         dictionary.) *)
      let sigs = match Hashtbl.find_opt Typer.traits trait with
        | Some (param, msigs) -> Some (param, msigs) | None -> None in
      List.iter (fun (mname, v) ->
        let t = Typer.infer !type_env v in
        match sigs with
        | Some (param, msigs) ->
          (match List.assoc_opt mname msigs with
           | Some mty ->
             (try Typer.unify v.Ast.loc t (subst_param param target mty)
              with _ -> ())
           | None -> ())
        | None -> ()) methods
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
    (* trait name -> (param, methods, defaults) for building dict records /
       values and filling omitted impl methods. *)
    let trait_info :
      (string, string * (string * ty) list * (string * expr) list) Hashtbl.t =
      Hashtbl.create 8 in
    (* trait name -> its declared super-traits (direct). *)
    let trait_supers : (string, string list) Hashtbl.t = Hashtbl.create 8 in
    Typer.reset_traits ();
    List.iter (function
      | Top_trait (name, param, methods, defaults, supers) ->
        Hashtbl.replace trait_info name (param, methods, defaults);
        Hashtbl.replace trait_supers name supers;
        Typer.register_trait name param methods
      | Top_impl (trait, target, _) -> Typer.register_impl trait target
      | _ -> ()) prog.decls;

    (* Well-formedness: `impl Sub T` requires an impl of every (transitive)
       super-trait of `Sub` at `T`. A super-trait is a promise that the
       instance also satisfies the parent interface; enforce it so a program
       cannot claim `Ord T` without `Eq T`. (Method *access* needs no special
       handling: Mere's inference collects a separate constraint for every
       trait method actually used, so a generic function using both an Ord and
       an Eq method already receives both dictionaries.) *)
    let rec all_supers trait seen =
      let direct = try Hashtbl.find trait_supers trait with Not_found -> [] in
      List.fold_left (fun acc s ->
        if List.mem s seen then acc
        else s :: all_supers s (s :: seen) @ acc) [] direct
    in
    List.iter (function
      | Top_impl (trait, target, _) ->
        (match Typer.trait_type_key target with
         | None -> ()  (* non-concrete head is reported elsewhere *)
         | Some key ->
           List.iter (fun sup ->
             if not (Hashtbl.mem Typer.trait_impls (sup ^ "@" ^ key)) then
               raise (Trait_error (Loc.dummy,
                 Printf.sprintf
                   "impl %s %s requires an `impl %s %s` (super-trait of %s)"
                   trait key sup key trait)))
             (all_supers trait []))
      | _ -> ()) prog.decls;

    (* --- Trait objects (`dyn Trait`) -----------------------------------------
       A heterogeneous collection of values that all implement a trait is
       expressible in userland as a record of self-capturing closures; this
       pass just auto-generates that encoding per trait so it isn't hand-written
       for every instance type. For a trait whose every method has the shape
       `'a -> R` (a single `self` argument, with `'a` not appearing in R — so no
       `Self`-returning or multi-`self` methods like `Eq`'s `eq`), generate:

         type Trait__obj = { m1 : unit -> R1; ...; mk : unit -> Rk };
         let Trait__pack = fn x -> Trait__obj { m1 = fn () -> m1 x; ... };

       `Trait__pack` is an ordinary CONSTRAINED generic function (its body uses
       the trait methods on `x`), so the existing dictionary-passing elaboration
       gives it a dict parameter and lowers `m1 x` to `dict.m1 x` — no special
       handling is needed here or in any backend. A consumer packs a value with
       `Trait__pack v : Trait__obj` and dispatches with `o.m ()`. The object
       type is also reachable as the sugar `dyn Trait` (see the parser).

       Generated BEFORE the type pass so `Trait__pack` is typed, constrained,
       and elaborated like any other constrained binding. *)
    let ty_mentions_param param t =
      let rec go t =
        match Ast.walk t with
        | TyParam p -> p = param
        | TyInt | TyFloat | TyBool | TyStr | TyUnit -> false
        | TyVar _ -> false
        | TyArrow (a, b) -> go a || go b
        | TyTuple ts -> List.exists go ts
        | TyCon (_, args) -> List.exists go args
        | TyRef (_, _, inner) -> go inner
      in go t
    in
    let obj_type_name trait = trait ^ "__obj" in
    let pack_name trait = trait ^ "__pack" in
    let trait_object_decls name param methods =
      (* Eligible iff nonempty and every method is `param -> R` with R free of
         `param`. Returns [] (no object type) otherwise. *)
      let elig =
        methods <> [] &&
        List.for_all (fun (_, mty) ->
          match Ast.walk mty with
          | TyArrow (a, r) ->
            (match Ast.walk a with
             | TyParam p -> p = param && not (ty_mentions_param param r)
             | _ -> false)
          | _ -> false) methods
      in
      if not elig then []
      else begin
        let ret_of mty =
          match Ast.walk mty with TyArrow (_, r) -> r | _ -> TyUnit in
        let fields =
          List.map (fun (m, mty) -> (m, TyArrow (TyUnit, ret_of mty))) methods in
        let obj_rec = Top_record (obj_type_name name, [], fields) in
        let x = "__dyn_self" in
        let lit =
          mk Loc.dummy (Record_lit (obj_type_name name,
            List.map (fun (m, _) ->
              (m, mk Loc.dummy (Fun ("__dyn_u", Some TyUnit,
                mk Loc.dummy (App (mk Loc.dummy (Var m),
                                   mk Loc.dummy (Var x))))))) methods))
        in
        let packer =
          Top_let (mk_pat (P_var (pack_name name)),
                   mk Loc.dummy (Fun (x, None, lit)))
        in
        [obj_rec; packer]
      end
    in
    let prog =
      { prog with decls =
          List.concat_map (function
            | Top_trait (name, param, methods, _, _) as d ->
              d :: trait_object_decls name param methods
            | d -> [d]) prog.decls }
    in

    (* --- Complete + inline impl bodies, before any type-checking ------------
       Two problems share one solution:
         (1) an impl method body that references a SIBLING trait method (e.g.
             `neq = fn a -> fn b -> if eq a b then ... `) — the sibling use has
             an unresolved dispatch type, so the dictionary-passing rewrite
             raises "ambiguous", and resolving it to a dict field would make
             the dictionary reference itself (Mere has no self-referential
             record binding);
         (2) DEFAULT methods, whose whole point is to be written in terms of
             sibling methods.
       Both are solved by *syntactic inlining* per instance, done here before
       type_pass: for each `impl Trait T`, every trait method gets a source
       body (the impl's own, else the trait default, else "missing"), and any
       reference to a sibling method name inside a body is replaced by that
       sibling's (recursively inlined) source body. Cycles are rejected. The
       result is a complete impl — one self-contained body per method, no
       trait-method name references left — so type_pass sees ordinary Mere and
       the dictionary is a plain (non-recursive) record. *)
    let complete_impl trait target impls =
      match Hashtbl.find_opt trait_info trait with
      | None -> impls  (* unknown trait — let the later error path report it *)
      | Some (_param, methods, defaults) ->
        let method_names = List.map fst methods in
        let source m =
          match List.assoc_opt m impls with
          | Some b -> Some b
          | None -> List.assoc_opt m defaults
        in
        (* Inline sibling-method references in `body`, with `in_progress` the
           set of methods currently being resolved (cycle guard). *)
        let rec inline in_progress body =
          map_expr (fun e ->
            match e.node with
            | Var m when List.mem m method_names ->
              if List.mem m in_progress then
                raise (Trait_error (e.loc,
                  Printf.sprintf
                    "cyclic trait method definitions: `%s` in `impl %s ...`"
                    m trait))
              else (match source m with
                | Some b -> Some (inline (m :: in_progress) b)
                | None ->
                  raise (Trait_error (e.loc,
                    Printf.sprintf
                      "impl %s: method `%s` (referenced by a sibling) has \
                       neither an implementation nor a default" trait m)))
            | _ -> None)
            body
        in
        List.map (fun (m, _mty) ->
          match source m with
          | Some b -> (m, inline [m] b)
          | None ->
            let key = match Typer.trait_type_key target with
              | Some k -> k | None -> "?" in
            raise (Trait_error (Loc.dummy,
              Printf.sprintf "impl %s %s: missing method `%s`" trait key m)))
          methods
    in
    let prog =
      { prog with decls =
          List.map (function
            | Top_impl (trait, target, impls) ->
              Top_impl (trait, target, complete_impl trait target impls)
            | d -> d) prog.decls }
    in

    let schemes = type_pass prog in

    (* Global map: (a constrained binding's quantified variable id, trait
       name) -> the name of the dictionary parameter that binding receives.
       Keyed by (vid, trait), NOT vid alone: one type variable can carry
       several constraints (e.g. `Num 'a` AND `Sh 'a`), each getting its own
       dict parameter. Keying by vid alone let the second constraint's param
       clobber the first, so a `Num` method use resolved to the `Sh`
       dictionary — "record Sh__dict has no field: add". Also the ordered
       parameter list per binding name (for wrapping its definition). *)
    let var2param : (int * string, string) Hashtbl.t = Hashtbl.create 16 in
    (* name -> ordered [(param, trait)] the binding receives *)
    let binding_params : (string, (string * string) list) Hashtbl.t =
      Hashtbl.create 16 in
    Hashtbl.iter (fun name sch ->
      if sch.Typer.constraints <> [] then begin
        let params =
          List.map (fun (trait, vid) ->
            let p = dict_param_name trait vid in
            Hashtbl.replace var2param (vid, trait) p;
            (p, trait)) sch.Typer.constraints
        in
        Hashtbl.replace binding_params name params
      end) schemes;

    (* Local (non-top-level) constrained `let` bindings: value node -> its
       ordered [(dict-param, trait)]. Populate var2param here — before the
       resolve_dict pass — so the body's trait-method uses (whose dispatch
       variable is the local binding's own quantified variable) resolve to the
       dict parameter rather than raising "ambiguous". *)
    let local_params : (expr * (string * string) list) list =
      List.map (fun (value_node, constraints) ->
        let params =
          List.map (fun (trait, vid) ->
            let p = dict_param_name trait vid in
            Hashtbl.replace var2param (vid, trait) p;
            (p, trait)) constraints
        in
        (value_node, params)) !Typer.trait_local_constrained
    in

    (* Resolve the dictionary expression for a trait at a dispatch type. *)
    let resolve_dict loc trait (dispatch : ty) : expr =
      match Ast.walk dispatch with
      | Ast.TyVar v ->
        (match Hashtbl.find_opt var2param (v.id, trait) with
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
          (match Ast.walk dispatch with
           | Ast.TyCon (tn, []) when tn = obj_type_name trait ->
             (* Dispatch on a trait OBJECT (`dyn Trait`): the method use `meth o`
                becomes `(o : Trait__obj).meth ()` — read the captured thunk from
                the object record and force it. The annotation fixes the record
                type at the field access (Mere can't otherwise infer it). Emitted
                as `fn __self -> ((__self : Trait__obj).meth) ()` so it slots into
                the same use site as a normal method value. *)
             let self = "__dyn_disp" in
             let obj_ty = Ast.TyCon (obj_type_name trait, []) in
             let body =
               mk node.loc (App (
                 mk node.loc (Field_get (
                   mk node.loc (Annot (mk node.loc (Var self), obj_ty)), meth)),
                 mk node.loc Unit_lit))
             in
             (node, mk node.loc (Fun (self, Some obj_ty, body)))
           | _ ->
             let dict = resolve_dict node.loc trait dispatch in
             (node, mk node.loc (Field_get (dict, meth))))
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
    (* Prepend one dictionary parameter per constraint to a function value.
       The single `TyParam "a"` in each dict record type is freshened to one
       variable that the body then unifies with the element type via the
       trait-method uses (`zero` / `add` / ...). *)
    let wrap_params params value =
      List.fold_right (fun (p, trait) acc ->
        let dict_ty = TyCon (dict_type_name trait, [TyParam "a"]) in
        mk value.loc (Fun (p, Some dict_ty, acc))) params value
    in
    let wrap_dict_params name value =
      match Hashtbl.find_opt binding_params name with
      | None -> value
      | Some params -> wrap_params params value
    in

    (* The rewriter: apply the obligation replacements (trait-method uses ->
       dict field access, constrained-fn uses -> dict argument), and wrap each
       local constrained `let` value with its dictionary parameter(s) after
       rewriting its own body. *)
    let rec subst e =
      match List.find_opt (fun (n, _) -> n == e) replacements with
      | Some (_, r) -> Some r
      | None ->
        (match e.node with
         | Let_rec (bindings, body)
           when List.exists (fun (_, v) ->
                  List.exists (fun (vn, _) -> vn == v) local_params) bindings ->
           (* A local recursive `let rec ... and ...` group with at least one
              constrained member (self- or mutually-recursive). Intra-group
              references are typed monomorphically — no constrained-use
              obligation — so thread each constrained member's dictionary
              parameter(s) through references to it, then wrap each constrained
              binding with its own parameter(s). Mirrors the top-level
              `Top_let_rec` handling; because the group is monomorphic its
              members share the dispatch variable(s), so the dict parameters are
              in scope across the whole group. *)
           let group_params =
             List.filter_map (fun (n, v) ->
               match List.find_opt (fun (vn, _) -> vn == v) local_params with
               | Some (_, params) -> Some (n, params)
               | None -> None) bindings
           in
           let subst_rec ex =
             match subst ex with
             | Some r -> Some r
             | None ->
               (match ex.node with
                | Var m when List.mem_assoc m group_params ->
                  let params = List.assoc m group_params in
                  Some (List.fold_left (fun acc (p, _) ->
                    mk ex.loc (App (acc, mk ex.loc (Var p)))) ex params)
                | _ -> None)
           in
           let bindings' =
             List.map (fun (n, v) ->
               match List.assoc_opt n group_params, v.node with
               | Some params, Fun (x, ty, fbody) ->
                 let fbody' = map_expr subst_rec fbody in
                 (n, wrap_params params { v with node = Fun (x, ty, fbody') })
               | _ -> (n, map_expr subst_rec v)) bindings
           in
           Some { e with node = Let_rec (bindings', map_expr subst_rec body) }
         | _ ->
           (match List.find_opt (fun (v, _) -> v == e) local_params with
            | Some (_, params) ->
              (match e.node with
               | Fun (x, ty, fbody) ->
                 (* Rewrite the body (recurse into children, not `e` itself, so
                    no re-match loop), then prepend the dict parameter(s). *)
                 let fbody' = map_expr subst fbody in
                 Some (wrap_params params { e with node = Fun (x, ty, fbody') })
               | _ -> None)
            | None -> None))
    in
    let rewrite = map_expr subst in

    (* Rewrite each declaration in place, preserving source order (so type /
       value dependencies stay valid). *)
    let rewrite_decl decl =
      match decl with
      | Top_trait (name, param, methods, _defaults, _supers) ->
        Top_record (dict_type_name name, [param], methods)
      | Top_impl (trait, target, impls) ->
        let key = match Typer.trait_type_key target with
          | Some k -> k
          | None ->
            raise (Trait_error (Loc.dummy,
              Printf.sprintf "impl %s: unsupported instance type" trait))
        in
        (* impls has already been completed (defaults filled, sibling refs
           inlined) by complete_impl, so every method is present. *)
        let param, methods, _defaults = Hashtbl.find trait_info trait in
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
        let constrained =
          List.filter (fun (n, _) -> Hashtbl.mem binding_params n) bindings in
        (match constrained with
         | [] ->
           (* No constrained binding in the group — nothing trait-specific. *)
           Top_let_rec (List.map (fun (n, v) -> (n, rewrite v)) bindings)
         | _ ->
           (* One or more (mutually) recursive constrained functions.
              Intra-let-rec references are typed monomorphically (before
              generalization), so they carry NO constrained-use obligation and
              must be threaded here: a reference to a constrained group member
              `m` — the fn itself or a sibling — is applied to the dictionary
              parameter(s) `m` expects. Because the group is typed
              monomorphically, mutually-recursive members share the dispatch
              variable(s), so `m`'s dict parameters have the same names as the
              current member's own (keyed by (vid, trait)), i.e. they are in
              scope. This subsumes the single self-recursive case. Sibling
              obligation replacements (trait-method uses -> dict.method) run via
              `subst`; then each body gets its own dict parameter(s) prepended. *)
           let group_names = List.map fst bindings in
           let subst_rec e =
             match subst e with
             | Some r -> Some r
             | None ->
               (match e.node with
                | Var m
                  when List.mem m group_names
                       && Hashtbl.mem binding_params m ->
                  let params = Hashtbl.find binding_params m in
                  Some (List.fold_left (fun acc (p, _) ->
                    mk e.loc (App (acc, mk e.loc (Var p)))) e params)
                | _ -> None)
           in
           Top_let_rec (List.map (fun (n, v) ->
             let v' = map_expr subst_rec v in
             (n, wrap_dict_params n v')) bindings))
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
