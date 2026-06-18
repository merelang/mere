(* C codegen — Phase 4 prep.

   Subset:
     int / bool / str literals
     binary arithmetic   + - * / %
     string concat       ++  (allocates via __lang_str_concat helper)
     unary negation      -
     comparisons         == != < <= > >=  (results in int 0/1)
     logical             && ||             (short-circuit via C's own)
     if-then-else        (both branches must have the same type)
     let bindings        (P_var pattern; type inferred from usage on C side)
     Var references
     Annot
     Top-level fn bindings (single-arg, no closures) — lifted to C
       functions. Self-recursion and mutual recursion supported via
       forward declarations.
     Direct function calls `Var name`-headed App.
     `print : str -> unit` builtin → `puts(...)`.

   Not yet supported (will raise Codegen_error):
     closures / nested fn defs / curried multi-arg fns / first-class fns
     records / variants / tuples / patterns / match / floats
     region / view / Ref / with
     other builtins (mk_logger, read_file, etc.)

   Top-level decls are flattened into nested `let` via Ast.desugar_program;
   we then walk that chain to extract fn bindings into a list of C
   functions, leaving the residual body to emit as the C `main`. The main
   expression's inferred type drives the printf format (int/bool → %d,
   str → %s, unit → skip the printf). *)

exception Codegen_error of Loc.t * string

let unsupported loc what =
  raise (Codegen_error (loc,
    Printf.sprintf "unsupported in C codegen subset: %s" what))

(* Constructor name → tag index (declaration order). Populated by
   emit_program from Top_type decls; read by emit_expr for Constr /
   Match. *)
let variant_tags : (string, int) Hashtbl.t = Hashtbl.create 16

(* Names of top-level lifted fns. Set by emit_program before emit_expr
   runs so Var-in-value-position can pick the right closure wrapper
   const, and App-in-head-position can choose direct vs indirect call. *)
let toplevel_fn_names : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Variant types whose constructors carry payload referencing the same
   type (directly recursive). These are emitted as pointer-typed values:
     typedef intlist_node intlist_node;
     struct intlist_node { ... };
     typedef intlist_node* intlist;
   So `intlist` in C is `intlist_node*`, Cons mallocs a node, and
   pattern match dereferences via `->`. *)
let recursive_variants : (string, unit) Hashtbl.t = Hashtbl.create 4

let is_recursive_variant (name : string) : bool =
  Hashtbl.mem recursive_variants name

(* Polymorphic variant declarations: stored here at emit_variant_typedef
   time when params != [], then specialized at collect/emit time per
   concrete instantiation. *)
let polymorphic_variants
    : (string, string list * (string * Ast.ty option) list) Hashtbl.t =
  Hashtbl.create 4

(* Concrete instantiations seen in the program. Key is the mono name
   (`list_int`, ...); value is the variant's source name + arg types. *)
let mono_variant_instances : (string, string * Ast.ty list) Hashtbl.t =
  Hashtbl.create 8

(* Types that need a `show_T` function emitted. Key is the ty_tag of
   the type (used as the function name suffix); value is the type. *)
let show_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Polymorphic record declarations: deferred to instantiation time. *)
let polymorphic_records
    : (string, string list * (string * Ast.ty) list) Hashtbl.t =
  Hashtbl.create 4

(* Concrete instantiations of polymorphic records seen in the program.
   Key is the mono name; value is (record_name, arg_types). *)
let mono_record_instances : (string, string * Ast.ty list) Hashtbl.t =
  Hashtbl.create 8

(* Substitute TyParam names → concrete types throughout `t`. *)
let rec subst_params (mapping : (string * Ast.ty) list) (t : Ast.ty) : Ast.ty =
  match Ast.walk t with
  | Ast.TyParam p ->
    (try List.assoc p mapping with Not_found -> t)
  | Ast.TyArrow (a, b) ->
    Ast.TyArrow (subst_params mapping a, subst_params mapping b)
  | Ast.TyTuple ts ->
    Ast.TyTuple (List.map (subst_params mapping) ts)
  | Ast.TyCon (n, args) ->
    Ast.TyCon (n, List.map (subst_params mapping) args)
  | Ast.TyRef (r, inner) ->
    Ast.TyRef (r, subst_params mapping inner)
  | t -> t

(* Substitute params → args in a variant declaration's payload types. *)
let subst_variants
    (params : string list) (args : Ast.ty list)
    (variants : (string * Ast.ty option) list) : (string * Ast.ty option) list =
  let mapping = List.combine params args in
  List.map (fun (cname, arg_opt) ->
    (cname, Option.map (subst_params mapping) arg_opt)) variants

(* Inner-fn lifting (defunctionalization) — populated by a pre-pass and
   read by emit_expr. For each `let name = fn x -> body` found nested
   inside a top-level fn, we record:
     - lifted_name : fresh C function name
     - captures    : (var, ty) pairs prepended to the lifted fn's params
   emit_expr drops the Let binding and rewrites `App (Var name, arg)` to
   `lifted_name(capture1, ..., arg)`. *)
type lifted_inner = {
  lifted_name : string;
  captures    : (string * Ast.ty) list;
}
let inner_lifts : (string, lifted_inner) Hashtbl.t = Hashtbl.create 8

(* Anonymous closure (Phase B): a Fun in expression position becomes a
   closure value. We queue its env struct + adapter for emission and
   produce a closure construction expression at the Fun's site. *)
type closure_emission = {
  ce_adapter_name : string;
  ce_env_name     : string;
  ce_env_fields   : (string * Ast.ty) list;  (* captures *)
  ce_param        : string;
  ce_param_ty     : Ast.ty;
  ce_return_ty    : Ast.ty;
  ce_body         : Ast.expr;
}
let pending_closures : closure_emission list ref = ref []

(* Substitution map used inside an adapter body to rewrite captured Var
   references to env-pointer accesses (`x` → `__env_self->x`). Saved/
   restored around adapter emission so nested closures stack cleanly. *)
let current_env_subst : (string * string) list ref = ref []

(* When the typer's recorded .ty on a Fun is still polymorphic (because
   the enclosing fn was let-poly generalized), fall back to the type
   the parent context expects. Set by emit_fn / emit_lifted_fn /
   emit_closure_adapter; consulted by emit_expr's Fun case. *)
let current_expected_ty : Ast.ty option ref = ref None

(* In-scope variable types. Used to recover concrete capture types when
   the typer's recorded .ty on a Var has been left polymorphic by
   let-poly generalization. Updated by emit_fn / emit_lifted_fn /
   emit_closure_adapter (binding the fn's param + any captures) and by
   emit_expr Let (binding the let's name). *)
let current_var_types : (string * Ast.ty) list ref = ref []

(* Fresh names for anonymous closures + their env structs. *)
let anon_closure_counter = ref 0
let fresh_anon_names () =
  let n = !anon_closure_counter in
  incr anon_closure_counter;
  (Printf.sprintf "__anon_%d_fn" n,
   Printf.sprintf "__anon_%d_env" n)

let binop_to_c = function
  | Ast.Add -> "+"
  | Ast.Sub -> "-"
  | Ast.Mul -> "*"
  | Ast.Div -> "/"
  | Ast.Mod -> "%"
  | Ast.Concat -> "++"  (* unreachable in this subset; type-error before *)

let cmpop_to_c = function
  | Ast.Eq -> "=="
  | Ast.Ne -> "!="
  | Ast.Lt -> "<"
  | Ast.Le -> "<="
  | Ast.Gt -> ">"
  | Ast.Ge -> ">="

let logicop_to_c = function
  | Ast.And -> "&&"
  | Ast.Or  -> "||"

(* Lang type → tag string, used to name tuple structs uniquely. *)
(* Probe: is every element of this type resolved enough to name in C?
   Used by tuple shape collector to skip polymorphic-shaped tuples that
   appear in the typer's recorded annotations of generalized fn bodies
   (those shapes are not part of the program's actual run-time types). *)
let rec ty_is_concrete (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, inner) -> ty_is_concrete inner
  | Ast.TyVar _ | Ast.TyParam _ | Ast.TyFloat -> false

let rec ty_tag (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt -> "int"
  | Ast.TyBool -> "bool"
  | Ast.TyStr -> "str"
  | Ast.TyUnit -> "unit"
  | Ast.TyTuple ts -> "tuple_" ^ String.concat "_" (List.map ty_tag ts)
  | Ast.TyArrow (p, r) ->
    (* Recursive arrow → use the same naming used by closure_struct_name. *)
    "closure_" ^ ty_tag p ^ "_" ^ ty_tag r
  | Ast.TyCon (name, []) -> name
  | Ast.TyCon (name, args) ->
    (* Polymorphic instantiation (e.g., `int list` → `list_int`). *)
    name ^ "_" ^ String.concat "_" (List.map ty_tag args)
  | other ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unsupported C codegen type element: %s" (Ast.pp_ty other)))

let tuple_struct_name (elems : Ast.ty list) : string =
  "tuple_" ^ String.concat "_" (List.map ty_tag elems)

(* Specialized struct name for a polymorphic variant at given args. *)
let mono_variant_name (name : string) (args : Ast.ty list) : string =
  match args with
  | [] -> name
  | _ -> name ^ "_" ^ String.concat "_" (List.map ty_tag args)

(* Specialized struct name for a polymorphic record at given args. *)
let mono_record_name (name : string) (args : Ast.ty list) : string =
  match args with
  | [] -> name
  | _ -> name ^ "_" ^ String.concat "_" (List.map ty_tag args)

(* Views (declared via `view V[R] of T { ... }`) are represented as
   pointers into a region — the `[R]` marker on the value's type
   carries the region name (encoded as `TyRef (R, TyUnit)` since
   Phase 2.4). The codegen treats view types as `V*` so values live in
   the bump-allocator buffer and follow its lifetime. *)
let is_view_type (v_ty : Ast.ty) : bool =
  match Ast.walk v_ty with
  | Ast.TyCon (n, _) -> Hashtbl.mem Typer.views n
  | _ -> false

(* Whether the value at type `v_ty` is represented as a pointer (for
   recursive variants, mono or polymorphic, or views). Used by pattern
   compiler and field access to choose `->` vs `.` accessors. *)
let is_ptr_ty (v_ty : Ast.ty) : bool =
  if is_view_type v_ty then true
  else
    match Ast.walk v_ty with
    | Ast.TyCon (n, args) ->
      let mono_n =
        if Hashtbl.mem polymorphic_variants n then
          mono_variant_name n (List.map Ast.walk args)
        else n
      in
      is_recursive_variant mono_n
    | _ -> false

(* For a value of `v_ty` (assumed to be a variant), return the payload
   type of constructor `cname` (with type-params substituted). *)
let payload_ty_for_ctor (v_ty : Ast.ty) (cname : string) : Ast.ty option =
  match Ast.walk v_ty with
  | Ast.TyCon (tname, args) when Hashtbl.mem polymorphic_variants tname ->
    let (params, variants) = Hashtbl.find polymorphic_variants tname in
    let mapping = List.combine params args in
    (try
       Option.map (subst_params mapping)
         (List.assoc cname variants)
     with Not_found -> None)
  | Ast.TyCon _ | _ ->
    (try
       let info = Hashtbl.find Typer.constructors cname in
       info.Typer.arg
     with Not_found -> None)

(* For a record value of `v_ty`, return the type of field `fname`. *)
let field_ty (v_ty : Ast.ty) (fname : string) : Ast.ty =
  match Ast.walk v_ty with
  | Ast.TyCon (rname, args) when Hashtbl.mem polymorphic_records rname ->
    let (params, fields) = Hashtbl.find polymorphic_records rname in
    let mapping = List.combine params args in
    (try subst_params mapping (List.assoc fname fields)
     with Not_found -> Ast.TyInt)
  | Ast.TyCon (rname, _) when Hashtbl.mem Typer.records rname ->
    let info = Hashtbl.find Typer.records rname in
    (try List.assoc fname info.Typer.r_fields with Not_found -> Ast.TyInt)
  | _ -> Ast.TyInt

(* Find the first Var node with the given name in `e` whose typer-
   recorded `.ty` is set, and return that type. Used to recover capture
   types for closure conversion. *)
let lookup_var_ty (e : Ast.expr) (name : string) : Ast.ty =
  let found = ref None in
  let rec go (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.Var n when n = name ->
       (match e.Ast.ty with
        | Some t -> if !found = None then found := Some (Ast.walk t)
        | None -> ())
     | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a; go b
    | Ast.Neg a | Ast.Annot (a, _) -> go a
    | Ast.Let (_, v, b) -> go v; go b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
    | Ast.With (_, v, b) -> go v; go b
    | Ast.If (c, t, e_) -> go c; go t; go e_
    | Ast.Fun (_, _, b) -> go b
    | Ast.Constr (_, Some a) -> go a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      go s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> go ge | None -> ()); go b) arms
    | Ast.Tuple es -> List.iter go es
    | Ast.Region_block (_, b) -> go b
    | Ast.Ref (_, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  go e;
  match !found with
  | Some t -> t
  | None ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "captured variable `%s` has no recorded type" name))

(* Closure-value struct name for an arrow type. A function value of type
   T1 -> T2 is represented at C level as a struct with an `env` void
   pointer and an `fn` pointer (T2 returning, taking void* + T1). The
   struct is named `closure_T1_T2`. *)
let closure_struct_name (param : Ast.ty) (ret : Ast.ty) : string =
  "closure_" ^ ty_tag param ^ "_" ^ ty_tag ret

let pattern_vars (p : Ast.pattern) : string list =
  let rec go p =
    match p.Ast.pnode with
    | Ast.P_var n -> [n]
    | Ast.P_constr (_, Some sub) -> go sub
    | Ast.P_tuple ps -> List.concat_map go ps
    | Ast.P_record (_, fs) -> List.concat_map (fun (_, p) -> go p) fs
    | Ast.P_as (inner, n) -> n :: go inner
    | Ast.P_or (a, _) -> go a  (* both branches must bind same names *)
    | Ast.P_wild | Ast.P_int _ | Ast.P_bool _ | Ast.P_str _ | Ast.P_unit
    | Ast.P_constr (_, None) -> []
  in
  go p

(* Free variables of an expression with respect to a given set of bound
   names. Used to compute captures for inner fn lifting. *)
let free_vars (e : Ast.expr) (initially_bound : string list) : string list =
  let seen = Hashtbl.create 8 in
  let order = ref [] in
  let add n =
    if not (Hashtbl.mem seen n) then begin
      Hashtbl.add seen n ();
      order := n :: !order
    end
  in
  let rec go (e : Ast.expr) (bound : string list) =
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit -> ()
    | Ast.Var n -> if not (List.mem n bound) then add n
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a bound; go b bound
    | Ast.Neg a | Ast.Annot (a, _) -> go a bound
    | Ast.Let (pat, v, body) ->
      go v bound;
      go body (pattern_vars pat @ bound)
    | Ast.Let_rec (bindings, body) ->
      let names = List.map fst bindings in
      let bound' = names @ bound in
      List.iter (fun (_, v) -> go v bound') bindings;
      go body bound'
    | Ast.With (n, v, body) ->
      go v bound; go body (n :: bound)
    | Ast.If (c, t, e_) -> go c bound; go t bound; go e_ bound
    | Ast.Fun (param, _, body) -> go body (param :: bound)
    | Ast.Constr (_, Some a) -> go a bound
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      go s bound;
      List.iter (fun (pat, guard, body) ->
        let bound' = pattern_vars pat @ bound in
        (match guard with Some g -> go g bound' | None -> ());
        go body bound') arms
    | Ast.Tuple es -> List.iter (fun e -> go e bound) es
    | Ast.Region_block (n, b) -> go b (n :: bound)
    | Ast.Ref (_, a) -> go a bound
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e bound) fs
    | Ast.Field_get (a, _) -> go a bound
    | Ast.Record_update (a, fs) ->
      go a bound; List.iter (fun (_, e) -> go e bound) fs
  in
  go e initially_bound;
  List.rev !order

(* Translate one Lang expression to a C expression string. *)
let rec emit_expr (e : Ast.expr) : string =
  match e.node with
  | Ast.Int_lit n -> string_of_int n
  | Ast.Bool_lit b -> if b then "1" else "0"
  | Ast.Str_lit s -> Ast.escape_string s
  | Ast.Var name ->
    (* If we're inside a closure adapter and this name is one of the
       captured vars, rewrite to env access. *)
    (match List.assoc_opt name !current_env_subst with
     | Some s -> s
     | None ->
       if Hashtbl.mem toplevel_fn_names name then name ^ "_as_value"
       else if Hashtbl.mem inner_lifts name then
         unsupported e.loc
           ("inner-lifted fn `" ^ name ^
            "` used as a value — only direct calls are supported (Phase 4.9-a)")
       else name)
  | Ast.Annot (inner, _) -> emit_expr inner
  | Ast.Neg a -> "(-" ^ emit_expr a ^ ")"
  | Ast.Bin (Ast.Concat, a, b) ->
    "__lang_str_concat(" ^ emit_expr a ^ ", " ^ emit_expr b ^ ")"
  | Ast.Bin (op, a, b) ->
    "(" ^ emit_expr a ^ " " ^ binop_to_c op ^ " " ^ emit_expr b ^ ")"
  | Ast.Cmp (op, a, b) ->
    "(" ^ emit_expr a ^ " " ^ cmpop_to_c op ^ " " ^ emit_expr b ^ ")"
  | Ast.Logic (op, a, b) ->
    "(" ^ emit_expr a ^ " " ^ logicop_to_c op ^ " " ^ emit_expr b ^ ")"
  | Ast.If (cond, then_, else_) ->
    "(" ^ emit_expr cond ^ " ? " ^ emit_expr then_ ^ " : " ^ emit_expr else_ ^ ")"
  | Ast.Let (pat, value, body) ->
    (match pat.pnode with
     | Ast.P_var name when
         (match value.Ast.node with Ast.Fun _ -> true | _ -> false)
         && Hashtbl.mem inner_lifts name ->
       (* This inner-fn binding has been lifted out during the pre-pass.
          The lifted definition lives at top level; just emit the body. *)
       emit_expr body
     | Ast.P_var name ->
       (* GCC/Clang statement expression so the whole let stays a C
          expression. `__auto_type` (GCC/Clang extension) lets us bind
          values of varying static types (int, const char*, ...) without
          threading typer info into codegen. Also extend
          current_var_types so a Fun in `body` can recognize this
          binding as a capture candidate. *)
       let value_c = emit_expr value in
       let bind_ty =
         match value.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyInt
       in
       let prev = !current_var_types in
       current_var_types := (name, bind_ty) :: prev;
       let body_c =
         try let r = emit_expr body in current_var_types := prev; r
         with ex -> current_var_types := prev; raise ex
       in
       "({ __auto_type " ^ name ^ " = " ^ value_c ^ "; " ^ body_c ^ "; })"
     | _ -> unsupported pat.ploc "non-variable let pattern")
  (* Unsupported nodes *)
  | Ast.Float_lit _   -> unsupported e.loc "float literals"
  | Ast.Unit_lit      -> "0"  (* unit becomes int 0 in C *)
  | Ast.Let_rec _     -> unsupported e.loc "let rec inside an expression (only allowed at top level)"
  | Ast.With (name, value, body) ->
    (* `with c = v in body` — bind c, evaluate body, then invoke c's
       `close` field if the type defines one (Phase 3.1 convention).
       The close field is a `unit -> unit` closure; dispatch via the
       closure struct's `.fn(.env, 0)`. *)
    let value_c = emit_expr value in
    let body_c = emit_expr body in
    let close_call =
      match value.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon (rname, _) when Hashtbl.mem Typer.records rname ->
           let info = Hashtbl.find Typer.records rname in
           (match List.assoc_opt "close" info.Typer.r_fields with
            | Some _ ->
              let dot = if is_ptr_ty t then "->" else "." in
              Printf.sprintf
                "%s%sclose.fn(%s%sclose.env, 0); "
                name dot name dot
            | None -> "")
         | _ -> "")
      | None -> ""
    in
    Printf.sprintf
      "({ __auto_type %s = %s; __auto_type __with_result = (%s); %s__with_result; })"
      name value_c body_c close_call
  | Ast.Fun (param, _, fn_body) ->
    (* Anonymous Fun in expression position → emit a closure value.
       Prefer the typer's recorded type; if it's still polymorphic (due
       to let-poly generalization above us), fall back to the type the
       parent context expects. *)
    let arrow_ty =
      let from_node =
        match e.Ast.ty with Some t -> Some (Ast.walk t) | None -> None
      in
      let from_context = !current_expected_ty in
      match from_node, from_context with
      | Some t, _ when ty_is_concrete t -> t
      | _, Some t when ty_is_concrete t -> t
      | Some t, _ -> t  (* best-effort; will likely raise downstream *)
      | None, None ->
        unsupported e.loc
          "anonymous fn missing inferred type (no context)"
      | None, Some _ -> assert false
    in
    let param_ty, return_ty =
      match arrow_ty with
      | Ast.TyArrow (a, b) -> (Ast.walk a, Ast.walk b)
      | _ -> unsupported e.loc "anonymous fn has non-arrow type"
    in
    (* Captures = free vars of body that are bound by the enclosing
       fn / let chain (i.e., present in current_var_types). Globals
       (builtins, top-level fns, inner-lifted fns) are NOT captured —
       they're referenced directly in the generated C. Filtering by
       current_var_types respects shadowing (e.g., a user's `id`
       parameter is captured even though `id` is also a builtin). *)
    let raw_fvs = free_vars fn_body [param] in
    let fvs =
      List.filter (fun n -> List.mem_assoc n !current_var_types) raw_fvs
    in
    (* Capture type lookup: prefer the in-scope binding's resolved type;
       fall back to scanning Var nodes in the body (which may be
       polymorphic if the host fn was generalized). *)
    let cap_ty_of fv =
      match List.assoc_opt fv !current_var_types with
      | Some t when ty_is_concrete t -> Ast.walk t
      | _ -> lookup_var_ty fn_body fv
    in
    let captures = List.map (fun fv -> (fv, cap_ty_of fv)) fvs in
    let adapter_name, env_name = fresh_anon_names () in
    pending_closures := {
      ce_adapter_name = adapter_name;
      ce_env_name = env_name;
      ce_env_fields = captures;
      ce_param = param;
      ce_param_ty = param_ty;
      ce_return_ty = return_ty;
      ce_body = fn_body;
    } :: !pending_closures;
    let cstruct = closure_struct_name param_ty return_ty in
    if captures = [] then
      (* No env needed — pass NULL. *)
      Printf.sprintf "((%s){.env = NULL, .fn = %s})" cstruct adapter_name
    else
      let inits =
        String.concat " "
          (List.map (fun (n, _) ->
            Printf.sprintf "__env->%s = %s;" n (emit_expr
              { Ast.loc = e.loc; ty = Some (List.assoc n captures);
                node = Ast.Var n })) captures)
      in
      Printf.sprintf
        "({ %s* __env = (%s*)__lang_region_alloc(&__lang_default_region, sizeof(%s)); %s (%s){.env = __env, .fn = %s}; })"
        env_name env_name env_name inits cstruct adapter_name
  | Ast.App (f, arg) ->
    (match f.node with
     | Ast.Var "print" ->
       "({ puts(" ^ emit_expr arg ^ "); 0; })"
     | Ast.Var "str_len" ->
       "((int) strlen(" ^ emit_expr arg ^ "))"
     | Ast.Var "fst" ->
       "(" ^ emit_expr arg ^ ").f0"
     | Ast.Var "snd" ->
       "(" ^ emit_expr arg ^ ").f1"
     | Ast.Var "show" ->
       (* Polymorphic builtin — dispatch to the type-specialized
          show_<tag> function based on arg's inferred type. *)
       let arg_ty =
         match arg.Ast.ty with
         | Some t -> Ast.walk t
         | None ->
           unsupported e.loc "show: missing arg type info"
       in
       let tag = ty_tag arg_ty in
       Printf.sprintf "show_%s(%s)" tag (emit_expr arg)
     | Ast.Var name when Hashtbl.mem inner_lifts name ->
       (* Defunctionalized direct call (Phase 4.8). *)
       let li = Hashtbl.find inner_lifts name in
       let cap_args = List.map (fun (n, _) -> n) li.captures in
       li.lifted_name ^ "(" ^
       String.concat ", " (cap_args @ [emit_expr arg]) ^ ")"
     | Ast.Var name when Hashtbl.mem toplevel_fn_names name ->
       (* Direct call to a known top-level fn — fast path, no closure. *)
       name ^ "(" ^ emit_expr arg ^ ")"
     | _ ->
       (* Closure dispatch via the closure value's fn pointer + env. *)
       Printf.sprintf
         "({ __auto_type __c = %s; __c.fn(__c.env, %s); })"
         (emit_expr f) (emit_expr arg))
  | Ast.Constr (name, arg_opt) ->
    let info =
      try Hashtbl.find Typer.constructors name
      with Not_found ->
        unsupported e.loc ("unknown constructor: " ^ name)
    in
    let tag = Hashtbl.find variant_tags name in
    let type_name = info.Typer.type_name in
    (* If this constructor belongs to a polymorphic variant, pick the
       mono name from the Constr's inferred result type. *)
    let actual_type_name =
      if Hashtbl.mem polymorphic_variants type_name then
        match e.Ast.ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyCon (n, args) when n = type_name ->
             mono_variant_name n (List.map Ast.walk args)
           | _ -> type_name)
        | None -> type_name
      else type_name
    in
    let payload_str =
      match arg_opt with
      | None -> ""
      | Some arg ->
        Printf.sprintf ", .payload.%s = %s" name (emit_expr arg)
    in
    if is_recursive_variant actual_type_name then
      (* Recursive variant: allocate a node in the default region and
         return its pointer (the value type for recursive variants in
         C). Reclaimed in bulk when main exits. *)
      let node = actual_type_name ^ "_node" in
      Printf.sprintf
        "({ %s* __p = (%s*)__lang_region_alloc(&__lang_default_region, sizeof(%s)); \
         __p->tag = %d%s; __p; })"
        node node node tag
        (match arg_opt with
         | None -> ""
         | Some arg -> "; __p->payload." ^ name ^ " = " ^ emit_expr arg)
    else
      let _ = payload_str in
      Printf.sprintf "((%s){.tag = %d%s})" actual_type_name tag payload_str
  | Ast.Match (scrut, arms) ->
    let scrut_c = emit_expr scrut in
    let scrut_ty =
      match scrut.Ast.ty with
      | Some t -> Ast.walk t
      | None -> Ast.TyInt
    in
    (* Flatten P_or into multiple arms (the typer guarantees both
       branches bind the same names so duplicating the body is safe). *)
    let rec expand_or (pat, guard, body) =
      match pat.Ast.pnode with
      | Ast.P_or (a, b) -> expand_or (a, guard, body) @ expand_or (b, guard, body)
      | _ -> [(pat, guard, body)]
    in
    let arms = List.concat_map expand_or arms in
    (* Emit nested ternaries — each arm's body is wrapped in a
       statement expression so the pattern bindings are in scope for
       the guard (if any) and the body. *)
    let rec emit_arms = function
      | [] -> "({ abort(); 0; })"
      | (pat, guard, body) :: rest ->
        let (test, bindings) = compile_pattern pat "__scrut" scrut_ty in
        let next = emit_arms rest in
        let body_c = emit_expr body in
        let bound =
          match guard with
          | None ->
            Printf.sprintf "({ %s%s; })" bindings body_c
          | Some g ->
            let guard_c = emit_expr g in
            Printf.sprintf "({ %s(%s) ? (%s) : (%s); })"
              bindings guard_c body_c next
        in
        Printf.sprintf "(%s) ? %s : (%s)" test bound next
    in
    Printf.sprintf
      "({ __auto_type __scrut = %s; %s; })"
      scrut_c (emit_arms arms)
  | Ast.Tuple es ->
    (* Construction via C99 compound literal. Use the typer's recorded
       type to pick the right struct name. *)
    let struct_name =
      match e.Ast.ty with
      | Some t -> (match Ast.walk t with
                   | Ast.TyTuple ts -> tuple_struct_name ts
                   | _ -> unsupported e.loc "tuple node missing TyTuple type")
      | None -> unsupported e.loc "tuple node missing type info (typer not run?)"
    in
    let init_fields =
      List.mapi (fun i ex ->
        Printf.sprintf ".f%d = %s" i (emit_expr ex)) es
    in
    "((" ^ struct_name ^ "){" ^ String.concat ", " init_fields ^ "})"
  | Ast.Region_block (name, body) ->
    (* Allocate a region buffer, evaluate body, free. The region's C
       local name is `__region_<name>` — accessed by Ref/`&R v` when
       emitting `R.alloc(...)` calls inside body. Default cap 1 MB. *)
    let region_var = "__region_" ^ name in
    Printf.sprintf
      "({ __lang_region %s; __lang_region_init(&%s, 1 << 20); \
       __auto_type __r_result = (%s); \
       __lang_region_free(&%s); \
       __r_result; })"
      region_var region_var (emit_expr body) region_var
  | Ast.Ref (region, inner) ->
    (* `&R v` — allocate v in region R's bump buffer and return a
       pointer of type `T*`. Uses typeof / __auto_type so we don't need
       to thread the inner type's C representation through. *)
    let region_var = "__region_" ^ region in
    Printf.sprintf
      "({ __auto_type __ref_v = (%s); \
       typeof(__ref_v)* __ref_p = (typeof(__ref_v)*) \
         __lang_region_alloc(&%s, sizeof(__ref_v)); \
       *__ref_p = __ref_v; __ref_p; })"
      (emit_expr inner) region_var
  | Ast.Record_lit (name, fields) ->
    let parts =
      List.map (fun (f, ex) ->
        Printf.sprintf ".%s = %s" f (emit_expr ex)) fields
    in
    if Hashtbl.mem Typer.views name then begin
      (* View construction: bump-allocate in the construction-time
         region (encoded as the `[R]` arg of the value's TyCon), copy
         the initializer in, return the pointer. *)
      let region =
        match e.Ast.ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyCon (_, [Ast.TyRef (r, _)]) -> r
           | _ -> unsupported e.loc
                    "view literal missing region marker in inferred type")
        | None -> unsupported e.loc "view literal missing type info"
      in
      Printf.sprintf
        "({ %s* __view_p = (%s*) __lang_region_alloc(&__region_%s, sizeof(%s)); \
         *__view_p = (%s){%s}; __view_p; })"
        name name region name name (String.concat ", " parts)
    end
    else begin
      (* Regular record literal. Use mono name if polymorphic. *)
      let cstruct =
        if Hashtbl.mem polymorphic_records name then
          match e.Ast.ty with
          | Some t ->
            (match Ast.walk t with
             | Ast.TyCon (n, args) when n = name ->
               mono_record_name n (List.map Ast.walk args)
             | _ -> name)
          | None -> name
        else name
      in
      "((" ^ cstruct ^ "){" ^ String.concat ", " parts ^ "})"
    end
  | Ast.Field_get (inner, fname) ->
    (* `->` for view (pointer) values, `.` for plain records. *)
    let dot =
      match inner.Ast.ty with
      | Some t when is_view_type t -> "->"
      | _ -> "."
    in
    "(" ^ emit_expr inner ^ ")" ^ dot ^ fname
  | Ast.Record_update (base, updates) ->
    (* Use a statement expression with a tmp variable so we can patch
       individual fields and yield the result. *)
    let tmp = "__rupd" in
    let updates_c =
      List.map (fun (f, ex) ->
        Printf.sprintf "%s.%s = %s;" tmp f (emit_expr ex)) updates
    in
    "({ __auto_type " ^ tmp ^ " = " ^ emit_expr base ^ "; "
    ^ String.concat " " updates_c ^ " " ^ tmp ^ "; })"

(* Compile a pattern against a C expression of type `v_ty`, returning
   a (test, bindings) pair: a boolean C expression that's true iff the
   pattern matches, and a sequence of __auto_type binding statements
   for the names introduced by the pattern. *)
and compile_pattern (pat : Ast.pattern) (v_c : string) (v_ty : Ast.ty)
    : string * string =
  match pat.Ast.pnode with
  | Ast.P_wild -> ("1", "")
  | Ast.P_var n ->
    ("1", Printf.sprintf "__auto_type %s = %s; " n v_c)
  | Ast.P_int n ->
    (Printf.sprintf "((%s) == %d)" v_c n, "")
  | Ast.P_bool b ->
    (Printf.sprintf "((%s) == %d)" v_c (if b then 1 else 0), "")
  | Ast.P_str s ->
    (Printf.sprintf "(strcmp((%s), %s) == 0)" v_c (Ast.escape_string s), "")
  | Ast.P_unit -> ("1", "")
  | Ast.P_constr (cname, sub_opt) ->
    let tag =
      try Hashtbl.find variant_tags cname
      with Not_found ->
        unsupported pat.Ast.ploc ("unknown constructor in pattern: " ^ cname)
    in
    let dot = if is_ptr_ty v_ty then "->" else "." in
    let tag_test = Printf.sprintf "(%s)%stag == %d" v_c dot tag in
    (match sub_opt with
     | None -> (tag_test, "")
     | Some sub ->
       let payload_ty =
         match payload_ty_for_ctor v_ty cname with
         | Some t -> t
         | None ->
           unsupported pat.Ast.ploc
             ("missing payload type for " ^ cname)
       in
       let sub_v = Printf.sprintf "(%s)%spayload.%s" v_c dot cname in
       let (sub_test, sub_bind) = compile_pattern sub sub_v payload_ty in
       let combined_test =
         if sub_test = "1" then tag_test
         else Printf.sprintf "((%s) && (%s))" tag_test sub_test
       in
       (combined_test, sub_bind))
  | Ast.P_tuple ps ->
    let elem_tys =
      match Ast.walk v_ty with
      | Ast.TyTuple ts -> ts
      | _ -> List.map (fun _ -> Ast.TyInt) ps
    in
    let parts =
      List.mapi (fun i p ->
        let sub_v = Printf.sprintf "(%s).f%d" v_c i in
        let sub_ty = try List.nth elem_tys i with _ -> Ast.TyInt in
        compile_pattern p sub_v sub_ty) ps
    in
    let tests = List.map fst parts in
    let binds = List.map snd parts in
    let real_tests = List.filter (fun t -> t <> "1") tests in
    let combined_test =
      if real_tests = [] then "1"
      else String.concat " && " (List.map (fun t -> "(" ^ t ^ ")") real_tests)
    in
    (combined_test, String.concat "" binds)
  | Ast.P_record (_, fps) ->
    let parts =
      List.map (fun (fname, p) ->
        let sub_v = Printf.sprintf "(%s).%s" v_c fname in
        let sub_ty = field_ty v_ty fname in
        compile_pattern p sub_v sub_ty) fps
    in
    let tests = List.map fst parts in
    let binds = List.map snd parts in
    let real_tests = List.filter (fun t -> t <> "1") tests in
    let combined_test =
      if real_tests = [] then "1"
      else String.concat " && " (List.map (fun t -> "(" ^ t ^ ")") real_tests)
    in
    (combined_test, String.concat "" binds)
  | Ast.P_as (inner, n) ->
    let (test, bind) = compile_pattern inner v_c v_ty in
    let as_bind = Printf.sprintf "__auto_type %s = %s; " n v_c in
    (test, bind ^ as_bind)
  | Ast.P_or _ ->
    (* Or-patterns are flattened to multiple arms BEFORE compile_pattern
       is called by the Match emitter, so encountering one here means
       it's nested inside another pattern — not yet supported. *)
    unsupported pat.Ast.ploc
      "or-pattern nested inside a constructor / tuple / record"

type fn_decl = {
  name      : string;
  param     : string;
  body      : Ast.expr;
  param_ty  : Ast.ty;
  return_ty : Ast.ty;
}

(* Lang type → C type, restricted to the codegen subset. *)
let rec c_type_of (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool -> "int"
  | Ast.TyStr -> "const char*"
  | Ast.TyUnit -> "int"  (* unit becomes int 0; keeps return-type uniform *)
  | Ast.TyTuple ts -> tuple_struct_name ts
  | Ast.TyArrow (p, r) -> closure_struct_name p r
  | Ast.TyRef (_, inner) ->
    (* `&R T` at runtime is a pointer into the region's buffer; the
       region name is dropped (escape check at the typer guarantees the
       pointer isn't used past the region's lifetime). *)
    c_type_of inner ^ "*"
  | Ast.TyCon (name, _) when Hashtbl.mem Typer.views name ->
    (* View values are region-allocated pointers: `V*`. *)
    name ^ "*"
  | Ast.TyCon (name, args) when Hashtbl.mem polymorphic_records name ->
    (* Polymorphic record instantiation. *)
    mono_record_name name (List.map Ast.walk args)
  | Ast.TyCon (name, _) when Hashtbl.mem Typer.records name ->
    (* Monomorphic user-declared record type. *)
    name
  | Ast.TyCon (name, args) when Hashtbl.mem polymorphic_variants name ->
    (* Polymorphic variant instantiation — pick the specialized name
       (`list_int`, `opt_str`, ...). For recursive instantiations this
       name is the ptr typedef; for non-recursive it's the struct. *)
    mono_variant_name name (List.map Ast.walk args)
  | Ast.TyCon (name, _) when Hashtbl.mem Typer.types name ->
    (* Monomorphic user-declared variant type. *)
    name
  | other ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf
        "unsupported C codegen type: %s (only int/bool/str/unit/tuple/record/closure)"
        (Ast.pp_ty other)))

(* Skeleton info collected while walking the AST. We keep the Fun
   expression around so we can read its inferred `.ty` (set by the
   typer in the compile_to_c phase) instead of re-inferring — re-
   inference would overwrite the .ty fields with fresh tyvars that
   never see the call sites. *)
type fn_skel = {
  sname : string;
  sparam : string;
  sbody : Ast.expr;
  sfun : Ast.expr;  (* the original Fun expression, with its typer .ty *)
}

(* Walk the desugared main expression, extracting top-level fn bindings.
   Returns (fn skeletons in declaration order, residual main body). *)
let lift_fn_skels (e : Ast.expr) : fn_skel list * Ast.expr =
  let rec go (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, rest)
      when (match pat.Ast.pnode with Ast.P_var _ -> true | _ -> false) ->
      (match value.Ast.node with
       | Ast.Fun (param, _, fn_body) ->
         let name =
           match pat.Ast.pnode with Ast.P_var n -> n | _ -> assert false
         in
         let more, rest' = go rest in
         { sname = name; sparam = param; sbody = fn_body; sfun = value }
         :: more, rest'
       | _ -> [], e)
    | Ast.Let_rec (bindings, rest) ->
      let skels =
        List.map (fun (n, v) ->
          match v.Ast.node with
          | Ast.Fun (p, _, fb) ->
            { sname = n; sparam = p; sbody = fb; sfun = v }
          | _ ->
            raise (Codegen_error (v.Ast.loc,
              "let rec binding must be a single-arg function in C subset")))
          bindings
      in
      let more, rest' = go rest in
      skels @ more, rest'
    | _ -> [], e
  in
  go e

(* Find the first Var node with the given name in `e` whose recorded
   `.ty` walks to a concrete arrow type. Used to recover a monomorphic
   instantiation when the binding-site Fun.ty is left polymorphic by
   let-poly generalization. *)
let find_concrete_arrow (name : string) (e : Ast.expr) : Ast.ty option =
  let found = ref None in
  let rec go (e : Ast.expr) =
    (if !found = None then
       match e.Ast.node with
       | Ast.Var n when n = name ->
         (match e.Ast.ty with
          | Some t when ty_is_concrete (Ast.walk t) ->
            (match Ast.walk t with
             | Ast.TyArrow _ as ar -> found := Some ar
             | _ -> ())
          | _ -> ())
       | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a; go b
    | Ast.Neg a | Ast.Annot (a, _) -> go a
    | Ast.Let (_, v, b) -> go v; go b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
    | Ast.With (_, v, b) -> go v; go b
    | Ast.If (c, t, e_) -> go c; go t; go e_
    | Ast.Fun (_, _, b) -> go b
    | Ast.Constr (_, Some a) -> go a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      go s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> go ge | None -> ()); go b) arms
    | Ast.Tuple es -> List.iter go es
    | Ast.Region_block (_, b) -> go b
    | Ast.Ref (_, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  go e;
  !found

(* Build fn_decls from the typer-annotated AST. For each skeleton, prefer
   the Fun's own .ty if it's already concrete; otherwise (let-poly
   generalized it) recover a concrete arrow type by scanning the main
   expression for a use-site Var with the same name. *)
let resolve_fn_types (skels : fn_skel list) (root : Ast.expr) : fn_decl list =
  List.map (fun s ->
    let arrow =
      let fun_ty =
        match s.sfun.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
      in
      if ty_is_concrete fun_ty then fun_ty
      else
        match find_concrete_arrow s.sname root with
        | Some t -> t
        | None ->
          raise (Codegen_error (s.sfun.Ast.loc,
            Printf.sprintf
              "fn `%s` has polymorphic type `%s` with no concrete use site \
               — C codegen needs a monomorphic instantiation"
              s.sname (Ast.pp_ty fun_ty)))
    in
    match arrow with
    | Ast.TyArrow (p, r) ->
      { name = s.sname; param = s.sparam; body = s.sbody;
        param_ty = Ast.walk p; return_ty = Ast.walk r }
    | other ->
      raise (Codegen_error (s.sfun.Ast.loc,
        Printf.sprintf "function `%s` has non-arrow inferred type `%s`"
          s.sname (Ast.pp_ty other)))
  ) skels

(* Lifted-inner-fn signature: captures (with types) prepended to the
   original param. Stored separately because fn_decl assumes a single
   param. *)
type lifted_fn = {
  l_name      : string;
  l_captures  : (string * Ast.ty) list;
  l_param     : string;
  l_param_ty  : Ast.ty;
  l_body      : Ast.expr;
  l_return_ty : Ast.ty;
}

let format_param (n, ty) =
  Printf.sprintf "%s %s" (c_type_of ty) n

let with_expected_ty (t : Ast.ty) (f : unit -> 'a) : 'a =
  let prev = !current_expected_ty in
  current_expected_ty := Some t;
  let r = try f () with ex -> current_expected_ty := prev; raise ex in
  current_expected_ty := prev;
  r

let with_var_types (bindings : (string * Ast.ty) list) (f : unit -> 'a) : 'a =
  let prev = !current_var_types in
  current_var_types := bindings @ prev;
  let r = try f () with ex -> current_var_types := prev; raise ex in
  current_var_types := prev;
  r

let emit_fn (f : fn_decl) : string =
  let body_c =
    with_var_types [(f.param, f.param_ty)] (fun () ->
      with_expected_ty f.return_ty (fun () -> emit_expr f.body))
  in
  Printf.sprintf "%s %s(%s %s) {\n  return %s;\n}"
    (c_type_of f.return_ty)
    f.name
    (c_type_of f.param_ty)
    f.param
    body_c

let emit_lifted_fn (f : lifted_fn) : string =
  let params =
    String.concat ", "
      (List.map format_param (f.l_captures @ [(f.l_param, f.l_param_ty)]))
  in
  let all_bindings = f.l_captures @ [(f.l_param, f.l_param_ty)] in
  let body_c =
    with_var_types all_bindings (fun () ->
      with_expected_ty f.l_return_ty (fun () -> emit_expr f.l_body))
  in
  Printf.sprintf "%s %s(%s) {\n  return %s;\n}"
    (c_type_of f.l_return_ty) f.l_name params body_c

let emit_fn_forward_decl (f : fn_decl) : string =
  Printf.sprintf "%s %s(%s);"
    (c_type_of f.return_ty) f.name (c_type_of f.param_ty)

(* Closure-value wrapper for a top-level fn: an env-ignoring adapter
   plus a const closure literal that can be passed as a value. *)
let emit_closure_wrapper (f : fn_decl) : string =
  let cstruct = closure_struct_name f.param_ty f.return_ty in
  let cret = c_type_of f.return_ty in
  let carg = c_type_of f.param_ty in
  Printf.sprintf
    "static %s %s_closure_fn(void* __env, %s %s) {\n  \
       (void)__env;\n  \
       return %s(%s);\n\
     }\n\
     static const %s %s_as_value = {.env = NULL, .fn = %s_closure_fn};"
    cret f.name carg f.param
    f.name f.param
    cstruct f.name f.name

(* Closure struct typedef for a `(p) -> r` arrow. *)
let emit_closure_typedef (p : Ast.ty) (r : Ast.ty) : string =
  let cstruct = closure_struct_name p r in
  let cret = c_type_of r in
  let carg = c_type_of p in
  Printf.sprintf
    "typedef struct {\n  void* env;\n  %s (*fn)(void*, %s);\n} %s;"
    cret carg cstruct

let emit_lifted_fn_forward_decl (f : lifted_fn) : string =
  let params =
    String.concat ", "
      (List.map (fun (_, t) -> c_type_of t)
         (f.l_captures @ [(f.l_param, f.l_param_ty)]))
  in
  Printf.sprintf "%s %s(%s);" (c_type_of f.l_return_ty) f.l_name params

(* Render an anonymous-closure env struct typedef. *)
let emit_closure_env_typedef (ce : closure_emission) : string =
  if ce.ce_env_fields = [] then ""
  else
    let fields =
      String.concat "\n"
        (List.map (fun (n, t) ->
          Printf.sprintf "  %s %s;" (c_type_of t) n) ce.ce_env_fields)
    in
    Printf.sprintf "typedef struct {\n%s\n} %s;" fields ce.ce_env_name

(* Emit a `show_T` function for type `t`, returning a C string. For
   tuple / record / variant types the function composes calls to inner
   `show_<elem>` functions. *)
let emit_show_fn (tag : string) (t : Ast.ty) : string =
  let cty = c_type_of t in
  let header =
    Printf.sprintf "static const char* show_%s(%s v)" tag cty
  in
  match Ast.walk t with
  | Ast.TyInt ->
    header ^ " {\n  char* buf; asprintf(&buf, \"%d\", v); return buf;\n}"
  | Ast.TyBool ->
    header ^ " { return v ? \"true\" : \"false\"; }"
  | Ast.TyStr ->
    header ^ " { char* buf; asprintf(&buf, \"\\\"%s\\\"\", v); return buf; }"
  | Ast.TyUnit ->
    header ^ " { (void)v; return \"()\"; }"
  | Ast.TyTuple ts ->
    let parts =
      List.mapi (fun i et ->
        Printf.sprintf "show_%s(v.f%d)" (ty_tag et) i) ts
    in
    let fmt = "(" ^ String.concat ", " (List.map (fun _ -> "%s") ts) ^ ")" in
    Printf.sprintf "%s {\n  char* buf; asprintf(&buf, \"%s\", %s); return buf;\n}"
      header fmt (String.concat ", " parts)
  | Ast.TyArrow _ ->
    header ^ " { (void)v; return \"<closure>\"; }"
  | Ast.TyCon ("list", [elem_ty]) when Hashtbl.mem polymorphic_variants "list" ->
    (* Special case: render `'a list` as `[a, b, c]` to match the
       interpreter's pretty printing. Requires the user-declared
       `type 'a list = Nil | Cons of 'a * 'a list` (Lang's standard
       list shape). *)
    let elem_show = "show_" ^ ty_tag (Ast.walk elem_ty) in
    Printf.sprintf
      "%s {\n  \
         if (v->tag == 0) return \"[]\";\n  \
         const char* __acc = \"[\";\n  \
         %s __cur = v;\n  \
         int __first = 1;\n  \
         while (__cur->tag == 1) {\n  \
           char* __buf;\n  \
           if (__first) {\n  \
             asprintf(&__buf, \"%%s%%s\", __acc, %s(__cur->payload.Cons.f0));\n  \
           } else {\n  \
             asprintf(&__buf, \"%%s, %%s\", __acc, %s(__cur->payload.Cons.f0));\n  \
           }\n  \
           __acc = __buf;\n  \
           __cur = __cur->payload.Cons.f1;\n  \
           __first = 0;\n  \
         }\n  \
         char* __buf; asprintf(&__buf, \"%%s]\", __acc); return __buf;\n\
       }"
      header cty elem_show elem_show
  | Ast.TyCon (name, _) when Hashtbl.mem Typer.records name ->
    let info = Hashtbl.find Typer.records name in
    let fields_parts =
      List.map (fun (fname, ft) ->
        Printf.sprintf "show_%s(v.%s)" (ty_tag ft) fname)
        info.Typer.r_fields
    in
    let fmt =
      name ^ " { " ^
      String.concat ", "
        (List.map (fun (fname, _) -> fname ^ " = %s") info.Typer.r_fields) ^
      " }"
    in
    Printf.sprintf "%s {\n  char* buf; asprintf(&buf, \"%s\", %s); return buf;\n}"
      header fmt (String.concat ", " fields_parts)
  | Ast.TyCon (name, args) ->
    (* Variant — either monomorphic or polymorphic instance. Find its
       variants via polymorphic_variants or by scanning constructors. *)
    let variants =
      if Hashtbl.mem polymorphic_variants name then
        let (params, vs) = Hashtbl.find polymorphic_variants name in
        subst_variants params args vs
      else
        Hashtbl.fold (fun cname (info : Typer.constr_info) acc ->
          if info.type_name = name then (cname, info.arg) :: acc else acc)
          Typer.constructors []
    in
    let is_ptr = is_recursive_variant cty in
    let dot = if is_ptr then "->" else "." in
    let cases =
      List.map (fun (cname, arg_opt) ->
        let tag_n =
          try Hashtbl.find variant_tags cname with Not_found -> 0
        in
        match arg_opt with
        | None ->
          Printf.sprintf "  if (v%stag == %d) return \"%s\";"
            dot tag_n cname
        | Some ty ->
          Printf.sprintf
            "  if (v%stag == %d) { char* buf; asprintf(&buf, \"%s %%s\", show_%s(v%spayload.%s)); return buf; }"
            dot tag_n cname (ty_tag ty) dot cname)
        variants
    in
    Printf.sprintf "%s {\n%s\n  return \"<unknown>\";\n}"
      header (String.concat "\n" cases)
  | _ ->
    Printf.sprintf "%s { (void)v; return \"<unsupported>\"; }" header

let emit_show_fn_forward_decl (tag : string) (t : Ast.ty) : string =
  Printf.sprintf "static const char* show_%s(%s);" tag (c_type_of t)

let emit_closure_adapter_forward_decl (ce : closure_emission) : string =
  Printf.sprintf "static %s %s(void*, %s);"
    (c_type_of ce.ce_return_ty) ce.ce_adapter_name
    (c_type_of ce.ce_param_ty)

(* Render an anonymous-closure adapter, emitting its body with the
   capture-name → env-pointer substitution map. *)
let emit_closure_adapter (ce : closure_emission) : string =
  let env_subst =
    List.map (fun (n, _) -> (n, "(__env_self->" ^ n ^ ")"))
      ce.ce_env_fields
  in
  let prev = !current_env_subst in
  current_env_subst := env_subst;
  let var_bindings =
    ce.ce_env_fields @ [(ce.ce_param, ce.ce_param_ty)]
  in
  let body_c =
    with_var_types var_bindings (fun () ->
      with_expected_ty ce.ce_return_ty (fun () -> emit_expr ce.ce_body))
  in
  current_env_subst := prev;
  let env_unpack =
    if ce.ce_env_fields = [] then "(void)__env_self_void;"
    else
      Printf.sprintf "%s* __env_self = (%s*)__env_self_void;"
        ce.ce_env_name ce.ce_env_name
  in
  Printf.sprintf
    "static %s %s(void* __env_self_void, %s %s) {\n  \
       %s\n  \
       return %s;\n}"
    (c_type_of ce.ce_return_ty) ce.ce_adapter_name
    (c_type_of ce.ce_param_ty) ce.ce_param
    env_unpack body_c

(* String-concat runtime helper: allocates |a| + |b| + 1 bytes from the
   default region and concatenates. Reclaimed in bulk when main exits. *)
let str_concat_helper =
  String.concat "\n"
    [ "static const char* __lang_str_concat(const char* a, const char* b) {";
      "  size_t la = strlen(a), lb = strlen(b);";
      "  char* r = (char*) __lang_region_alloc(&__lang_default_region, la + lb + 1);";
      "  memcpy(r, a, la);";
      "  memcpy(r + la, b, lb);";
      "  r[la + lb] = '\\0';";
      "  return r;";
      "}" ]

(* Region runtime: a bump allocator. `region R { body }` initializes a
   region buffer, runs body, and frees the buffer. `&R v` allocates a
   copy of v in the region and returns a pointer. Escape check at the
   typer ensures no `&R T` value leaves the region's scope. *)
let region_runtime_helpers =
  String.concat "\n"
    [ "typedef struct {";
      "  char* base;";
      "  char* top;";
      "  size_t cap;";
      "} __lang_region;";
      "";
      "static void __lang_region_init(__lang_region* r, size_t cap) {";
      "  r->base = (char*) malloc(cap);";
      "  r->top = r->base;";
      "  r->cap = cap;";
      "}";
      "";
      "static void* __lang_region_alloc(__lang_region* r, size_t n) {";
      "  size_t aligned = (n + 7) & ~((size_t)7);";
      "  if (r->top + aligned > r->base + r->cap) {";
      "    fprintf(stderr, \"region OOM\\n\"); abort();";
      "  }";
      "  void* p = r->top;";
      "  r->top += aligned;";
      "  return p;";
      "}";
      "";
      "static void __lang_region_free(__lang_region* r) {";
      "  free(r->base);";
      "}";
      "";
      "/* Program-lifetime arena for closure envs and other long-lived";
      "   allocations that outlive any user `region R { ... }` block. */";
      "static __lang_region __lang_default_region;" ]

let main_format_of (t : Ast.ty) : string option =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool -> Some "%d"
  | Ast.TyStr -> Some "%s"
  | Ast.TyUnit -> None
  | _ -> Some "%d"  (* best-effort; type-checker should have caught issues *)

(* Compile a whole program: flatten top-decls into nested lets, lift
   top-level fn bindings into C functions (with forward declarations to
   support self / mutual recursion), and emit the residual body inside
   `int main()`. `main_ty` drives the printf format (int/bool → %d, str
   → %s, unit → no printf). *)
(* Counter for fresh lifted-inner-fn names. *)
let inner_fn_counter = ref 0
let fresh_inner_name base =
  let n = !inner_fn_counter in
  incr inner_fn_counter;
  Printf.sprintf "__lifted_%s_%d" base n

(* Walk all top-level fn bodies for nested `let name = fn x -> body in
   rest` patterns. For each, compute captures (free vars minus known
   top-level fn names) and produce a lifted_fn. Records the mapping in
   `inner_lifts` so emit_expr can rewrite call sites and drop bindings. *)
let lift_inner_fns
    (toplevel_names : string list)
    (fns : fn_decl list) : lifted_fn list =
  Hashtbl.reset inner_lifts;
  inner_fn_counter := 0;
  let lifted = ref [] in
  (* Globals = top-level lifted fns + builtins (anything in Typer's
     initial env). Closure captures must exclude these. *)
  let builtin_names = List.map fst Typer.initial_env in
  let known = ref (toplevel_names @ builtin_names) in
  let rec walk_in_fn (host_param : string) (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, body) ->
      (match pat.Ast.pnode, value.Ast.node with
       | Ast.P_var n, Ast.Fun (p, _, fn_body) ->
         (* Lift this inner fn. *)
         let body_fvs = free_vars fn_body (p :: !known) in
         let captures =
           List.map (fun fv ->
             (* Look up the var's type by searching the host fn's body
                for a Var node with this name; use the typer's recorded
                ty on it. Falls back to int if not found (defensive). *)
             let ty = lookup_var_ty fn_body fv in
             (fv, ty)) body_fvs
         in
         List.iter (fun (_, ty) ->
           match Ast.walk ty with
           | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> ()
           | _ ->
             raise (Codegen_error (value.Ast.loc,
               Printf.sprintf
                 "closure capture of non-primitive type `%s` not yet supported"
                 (Ast.pp_ty ty))))
           captures;
         let lifted_name = fresh_inner_name n in
         (* The inner fn's overall type is recorded on `value`. *)
         let return_ty, param_ty =
           match value.Ast.ty with
           | Some t ->
             (match Ast.walk t with
              | Ast.TyArrow (a, b) -> (Ast.walk b, Ast.walk a)
              | _ ->
                raise (Codegen_error (value.Ast.loc,
                  "inner fn has non-arrow inferred type")))
           | None ->
             raise (Codegen_error (value.Ast.loc,
               "inner fn missing inferred type (typer not run?)"))
         in
         let lifted_fn = {
           l_name = lifted_name; l_captures = captures;
           l_param = p; l_param_ty = param_ty;
           l_body = fn_body; l_return_ty = return_ty;
         } in
         lifted := lifted_fn :: !lifted;
         Hashtbl.replace inner_lifts n
           { lifted_name; captures };
         known := lifted_name :: !known;
         (* Recurse into the lifted body and into `body` of the let. *)
         walk_in_fn p fn_body;
         walk_in_fn host_param body
       | _ ->
         walk_in_fn host_param value;
         walk_in_fn host_param body)
    | Ast.Fun (_, _, body) ->
      (* Anonymous Fun in expression position — handled by emit_expr
         as a closure value (Phase B). Just recurse so deeper Funs are
         walked too. *)
      walk_in_fn host_param body
    | _ -> walk_children walk_in_fn host_param e
  and walk_children walker host_param e =
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walker host_param a; walker host_param b
    | Ast.Neg a | Ast.Annot (a, _) -> walker host_param a
    | Ast.Let (_, v, b) -> walker host_param v; walker host_param b
    | Ast.Let_rec (bs, b) ->
      List.iter (fun (_, v) -> walker host_param v) bs;
      walker host_param b
    | Ast.With (_, v, b) -> walker host_param v; walker host_param b
    | Ast.If (c, t, e_) -> walker host_param c; walker host_param t; walker host_param e_
    | Ast.Fun (_, _, b) -> walker host_param b
    | Ast.Constr (_, Some a) -> walker host_param a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walker host_param s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walker host_param ge | None -> ());
        walker host_param b) arms
    | Ast.Tuple es -> List.iter (walker host_param) es
    | Ast.Region_block (_, b) -> walker host_param b
    | Ast.Ref (_, a) -> walker host_param a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walker host_param e) fs
    | Ast.Field_get (a, _) -> walker host_param a
    | Ast.Record_update (a, fs) ->
      walker host_param a; List.iter (fun (_, e) -> walker host_param e) fs
  in
  List.iter (fun (f : fn_decl) ->
    walk_in_fn f.param f.body) fns;
  List.rev !lifted


(* Walk the AST for `App (Var "show", arg)` calls and add each arg's
   type to `show_types` so emit_program can synthesize the right
   specialized show functions. Recurses into types so e.g. `show (1, 2)`
   also triggers show_int (for the elements). *)
let collect_show_types (root : Ast.expr) (fns : fn_decl list) : unit =
  let rec add_with_deps t =
    let t = Ast.walk t in
    if not (ty_is_concrete t) then ()
    else
      let tag = ty_tag t in
      (* Guard before recursion so recursive variants (e.g. list) don't
         infinite-loop through their self-referential payloads. *)
      if Hashtbl.mem show_types tag then ()
      else begin
        Hashtbl.add show_types tag t;
        match t with
        | Ast.TyTuple ts -> List.iter add_with_deps ts
        | Ast.TyArrow _ -> ()
        | Ast.TyCon (name, args) ->
          List.iter add_with_deps args;
          if Hashtbl.mem Typer.records name then
            let info = Hashtbl.find Typer.records name in
            List.iter (fun (_, ft) -> add_with_deps ft) info.Typer.r_fields
          else if Hashtbl.mem polymorphic_variants name then begin
            let (params, variants) = Hashtbl.find polymorphic_variants name in
            let svariants = subst_variants params args variants in
            List.iter (fun (_, arg_opt) ->
              match arg_opt with Some t -> add_with_deps t | None -> ()) svariants
          end
          else if Hashtbl.mem Typer.types name then begin
            let variants =
              Hashtbl.fold (fun cname (info : Typer.constr_info) acc ->
                if info.type_name = name then (cname, info.arg) :: acc else acc)
                Typer.constructors []
            in
            List.iter (fun (_, arg_opt) ->
              match arg_opt with Some t -> add_with_deps t | None -> ()) variants
          end
        | _ -> ()
      end
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
       (match arg.Ast.ty with
        | Some t -> add_with_deps t
        | None -> ())
     | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk_expr v) bs; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_expr f.body) fns

(* Walk a typed AST + fn signatures to find every concrete instantiation
   of a polymorphic variant. Populates `mono_variant_instances`. *)
let collect_mono_variant_instances (root : Ast.expr) (fns : fn_decl list) : unit =
  let add name args =
    if List.for_all ty_is_concrete args then begin
      if Hashtbl.mem polymorphic_variants name
         && not (Hashtbl.mem mono_variant_instances (mono_variant_name name args))
      then
        Hashtbl.add mono_variant_instances
          (mono_variant_name name args) (name, args);
      if Hashtbl.mem polymorphic_records name
         && not (Hashtbl.mem mono_record_instances (mono_record_name name args))
      then
        Hashtbl.add mono_record_instances
          (mono_record_name name args) (name, args)
    end
  in
  let rec walk_ty t =
    match Ast.walk t with
    | Ast.TyCon (n, args) ->
      let args' = List.map Ast.walk args in
      List.iter walk_ty args';
      add n args'
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyArrow (a, b) -> walk_ty a; walk_ty b
    | Ast.TyRef (_, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk_expr v) bs; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty) fns;
  (* Also walk substituted payload types of each collected instance so
     tuples that appear only inside variant payloads (e.g.
     `tuple_int_list_int` inside Cons) get found by later collectors. *)
  Hashtbl.iter (fun _ (name, args) ->
    let (params, variants) = Hashtbl.find polymorphic_variants name in
    let svariants = subst_variants params args variants in
    List.iter (fun (_, arg_opt) ->
      match arg_opt with Some t -> walk_ty t | None -> ()) svariants
  ) mono_variant_instances;
  Hashtbl.iter (fun _ (name, args) ->
    let (params, fields) = Hashtbl.find polymorphic_records name in
    let mapping = List.combine params args in
    List.iter (fun (_, ft) -> walk_ty (subst_params mapping ft)) fields
  ) mono_record_instances

(* Walk a typed AST + fn signatures and collect every distinct
   `(p, r)` arrow type so we can emit a `closure_p_r` typedef. *)
let collect_arrow_types (root : Ast.expr) (fns : fn_decl list) :
    (Ast.ty * Ast.ty) list =
  let seen = Hashtbl.create 8 in
  let order = ref [] in
  let add p r =
    if not (ty_is_concrete p && ty_is_concrete r) then ()
    else
      let key = closure_struct_name p r in
      if not (Hashtbl.mem seen key) then begin
        Hashtbl.add seen key ();
        order := (p, r) :: !order
      end
  in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyArrow (p, r) ->
      (* Walk children FIRST so simpler arrows are added before the
         outer arrow that references them — keeps C typedef ordering
         legal (typedef body needs prior types to be fully defined). *)
      walk_ty p; walk_ty r;
      add (Ast.walk p) (Ast.walk r)
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyCon (_, args) -> List.iter walk_ty args
    | Ast.TyRef (_, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk_expr v) bs; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f ->
    walk_ty f.param_ty; walk_ty f.return_ty) fns;
  List.rev !order

(* Walk a typed AST and collect every distinct tuple shape encountered
   in any node's recorded type. Used to know which structs to define. *)
let collect_tuple_shapes (root : Ast.expr) : Ast.ty list list =
  let seen = Hashtbl.create 8 in
  let add elems =
    let key = tuple_struct_name elems in
    if not (Hashtbl.mem seen key) then Hashtbl.add seen key elems
  in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyTuple ts ->
      (* Skip polymorphic-shaped tuples — they appear in generalized fn
         bodies' annotations but aren't part of any concrete run-time
         shape we need to emit a struct for. *)
      if List.for_all ty_is_concrete ts then add ts;
      List.iter walk_ty ts
    | Ast.TyArrow (a, b) -> walk_ty a; walk_ty b
    | Ast.TyCon (_, args) -> List.iter walk_ty args
    | Ast.TyRef (_, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bindings, b) ->
      List.iter (fun (_, v) -> walk_expr v) bindings;
      walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ());
        walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) ->
      walk_expr a;
      List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  Hashtbl.fold (fun _ v acc -> v :: acc) seen []

let emit_tuple_typedef (elems : Ast.ty list) : string =
  let name = tuple_struct_name elems in
  Printf.sprintf "typedef struct %s %s;" name name

let emit_tuple_struct_body (elems : Ast.ty list) : string =
  let name = tuple_struct_name elems in
  let fields =
    List.mapi (fun i t ->
      Printf.sprintf "  %s f%d;" (c_type_of t) i) elems
  in
  Printf.sprintf "struct %s {\n%s\n};" name (String.concat "\n" fields)

(* Walk a typed AST and collect every distinct record TyCon name
   encountered. Used to drive struct typedef emission. The record's
   field list is then looked up from Typer.records. *)
let collect_record_names (root : Ast.expr) (fns : fn_decl list) : string list =
  let seen = Hashtbl.create 8 in
  let order = ref [] in
  let add name =
    if Hashtbl.mem Typer.records name && not (Hashtbl.mem seen name) then begin
      Hashtbl.add seen name ();
      order := name :: !order
    end
  in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyCon (name, args) -> add name; List.iter walk_ty args
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyArrow (a, b) -> walk_ty a; walk_ty b
    | Ast.TyRef (_, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bindings, b) ->
      List.iter (fun (_, v) -> walk_expr v) bindings; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, a) -> walk_expr a
    | Ast.Record_lit (name, fs) ->
      add name; List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) ->
      walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty) fns;
  List.rev !order

let emit_record_typedef (name : string) : string =
  let info = Hashtbl.find Typer.records name in
  if info.Typer.r_params <> [] then begin
    (* Polymorphic record: defer struct emission to instantiation time. *)
    Hashtbl.replace polymorphic_records name
      (info.Typer.r_params, info.Typer.r_fields);
    ""
  end
  else
    (* Forward decl form so closure typedefs that reference this struct
       can be emitted before the struct body (function-pointer return
       types accept forward-declared structs). *)
    Printf.sprintf "typedef struct %s %s;" name name

let emit_record_struct_body (name : string) : string =
  let info = Hashtbl.find Typer.records name in
  if info.Typer.r_params <> [] then ""
  else
    let fields =
      List.map (fun (fname, ft) ->
        Printf.sprintf "  %s %s;" (c_type_of ft) fname) info.Typer.r_fields
    in
    Printf.sprintf "struct %s {\n%s\n};" name (String.concat "\n" fields)

(* Emit specialized typedef for a polymorphic record instance. *)
let emit_mono_record_typedef (record_name : string) (args : Ast.ty list) : string =
  let mono_name = mono_record_name record_name args in
  Printf.sprintf "typedef struct %s %s;" mono_name mono_name

let emit_mono_record_struct_body (record_name : string) (args : Ast.ty list) : string =
  let mono_name = mono_record_name record_name args in
  let (params, fields) = Hashtbl.find polymorphic_records record_name in
  let mapping = List.combine params args in
  let subst_fields =
    List.map (fun (fname, ft) -> (fname, subst_params mapping ft)) fields
  in
  let field_lines =
    List.map (fun (fname, ft) ->
      Printf.sprintf "  %s %s;" (c_type_of ft) fname) subst_fields
  in
  Printf.sprintf "struct %s {\n%s\n};"
    mono_name (String.concat "\n" field_lines)

(* Detect direct self-reference in a variant's payload types. *)
let variant_is_recursive (name : string)
    (variants : (string * Ast.ty option) list) : bool =
  let rec mentions t =
    match Ast.walk t with
    | Ast.TyCon (n, _) when n = name -> true
    | Ast.TyCon (_, args) -> List.exists mentions args
    | Ast.TyTuple ts -> List.exists mentions ts
    | Ast.TyArrow (a, b) -> mentions a || mentions b
    | Ast.TyRef (_, inner) -> mentions inner
    | _ -> false
  in
  List.exists (fun (_, arg_opt) ->
    match arg_opt with Some t -> mentions t | None -> false) variants

(* Emit a tagged-union struct typedef for a Lang variant declaration.
   Records the tag index for each constructor name in `variant_tags`.
   For recursive variants, emits a `T_node` struct + a `T = T_node*`
   pointer typedef so values can be passed by reference. *)
let emit_variant_typedef (name : string) (params : string list)
    (variants : (string * Ast.ty option) list) : string =
  (* Tags are by constructor name and shared across all instantiations
     of a polymorphic variant. Set them regardless. *)
  List.iteri (fun i (cname, _) ->
    Hashtbl.replace variant_tags cname i) variants;
  if params <> [] then begin
    (* Defer struct emission — wait until we know the concrete
       instantiations from the program's AST + fn signatures. *)
    Hashtbl.replace polymorphic_variants name (params, variants);
    ""
  end
  else
  let recursive = variant_is_recursive name variants in
  if recursive then Hashtbl.replace recursive_variants name ();
  let node_name = if recursive then name ^ "_node" else name in
  let payload_arms =
    List.filter_map (fun (cname, arg_opt) ->
      match arg_opt with
      | None -> None
      | Some ty -> Some (Printf.sprintf "    %s %s;" (c_type_of ty) cname))
      variants
  in
  let body =
    if payload_arms = [] then "  int tag;"
    else
      "  int tag;\n  union {\n" ^ String.concat "\n" payload_arms ^
      "\n  } payload;"
  in
  if recursive then
    Printf.sprintf
      "typedef struct %s %s;\ntypedef %s* %s;"
      node_name node_name node_name name
  else begin
    let _ = body in
    (* Non-recursive variants also split into forward + body so closures
       referencing this variant can be emitted before the struct
       definition (function-pointer return types accept forward-declared
       struct types). *)
    Printf.sprintf "typedef struct %s %s;" node_name node_name
  end

(* Check whether a specific (variant_name, args) instance is recursive:
   does any substituted payload reference the SAME (name, args)? *)
let mono_variant_is_recursive
    (variant_name : string) (args : Ast.ty list)
    (subst_variants : (string * Ast.ty option) list) : bool =
  let same_inst t =
    match Ast.walk t with
    | Ast.TyCon (n, ts) when n = variant_name
                          && List.length ts = List.length args ->
      List.for_all2 (fun a b ->
        ty_tag (Ast.walk a) = ty_tag (Ast.walk b)) ts args
    | _ -> false
  in
  let rec ty_mentions t =
    same_inst t
    || (match Ast.walk t with
        | Ast.TyTuple ts -> List.exists ty_mentions ts
        | Ast.TyArrow (a, b) -> ty_mentions a || ty_mentions b
        | Ast.TyCon (_, ts) -> List.exists ty_mentions ts
        | Ast.TyRef (_, inner) -> ty_mentions inner
        | _ -> false)
  in
  List.exists (fun (_, arg_opt) ->
    match arg_opt with Some t -> ty_mentions t | None -> false)
    subst_variants

(* Emit typedef for a mono variant instance — same shape as the
   monomorphic case (forward + ptr if recursive, else inline struct). *)
let emit_mono_variant_typedef (variant_name : string) (args : Ast.ty list) : string =
  let mono_name = mono_variant_name variant_name args in
  let (params, variants) = Hashtbl.find polymorphic_variants variant_name in
  let svariants = subst_variants params args variants in
  let recursive = mono_variant_is_recursive variant_name args svariants in
  if recursive then Hashtbl.replace recursive_variants mono_name ();
  let node_name = if recursive then mono_name ^ "_node" else mono_name in
  let payload_arms =
    List.filter_map (fun (cname, arg_opt) ->
      match arg_opt with
      | None -> None
      | Some ty -> Some (Printf.sprintf "    %s %s;" (c_type_of ty) cname))
      svariants
  in
  let body =
    if payload_arms = [] then "  int tag;"
    else
      "  int tag;\n  union {\n" ^ String.concat "\n" payload_arms ^
      "\n  } payload;"
  in
  let _ = body in
  if recursive then
    Printf.sprintf "typedef struct %s %s;\ntypedef %s* %s;"
      node_name node_name node_name mono_name
  else
    Printf.sprintf "typedef struct %s %s;" node_name node_name

(* For mono variants, the struct body comes AFTER tuple / closure / etc.
   typedefs so all referenced types are visible. *)
let emit_mono_variant_struct_body (variant_name : string) (args : Ast.ty list)
    : string option =
  let mono_name = mono_variant_name variant_name args in
  let (params, variants) = Hashtbl.find polymorphic_variants variant_name in
  let svariants = subst_variants params args variants in
  let node_name =
    if Hashtbl.mem recursive_variants mono_name then mono_name ^ "_node"
    else mono_name
  in
  let payload_arms =
    List.filter_map (fun (cname, arg_opt) ->
      match arg_opt with
      | None -> None
      | Some ty -> Some (Printf.sprintf "    %s %s;" (c_type_of ty) cname))
      svariants
  in
  let body =
    if payload_arms = [] then "  int tag;"
    else
      "  int tag;\n  union {\n" ^ String.concat "\n" payload_arms ^
      "\n  } payload;"
  in
  Some (Printf.sprintf "struct %s {\n%s\n};" node_name body)

(* Emit the full struct body for a variant — both recursive and
   non-recursive. Called by emit_program AFTER closure / tuple / record
   forward decls are in place so referenced types are visible. *)
let emit_variant_struct_body (name : string)
    (variants : (string * Ast.ty option) list) : string option =
  if Hashtbl.mem polymorphic_variants name then None
  else
    let node_name =
      if is_recursive_variant name then name ^ "_node" else name
    in
    let payload_arms =
      List.filter_map (fun (cname, arg_opt) ->
        match arg_opt with
        | None -> None
        | Some ty ->
          Some (Printf.sprintf "    %s %s;" (c_type_of ty) cname))
        variants
    in
    let body =
      if payload_arms = [] then "  int tag;"
      else
        "  int tag;\n  union {\n" ^ String.concat "\n" payload_arms ^
        "\n  } payload;"
    in
    Some (Printf.sprintf "struct %s {\n%s\n};" node_name body)

let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  (* Variant typedefs come from Top_type decls. Walk prog.decls (NOT the
     desugared main, which drops type decls) and emit a tagged-union
     struct for each declared variant type. This also populates
     variant_tags as a side effect. *)
  Hashtbl.reset variant_tags;
  Hashtbl.reset recursive_variants;
  Hashtbl.reset polymorphic_variants;
  Hashtbl.reset mono_variant_instances;
  Hashtbl.reset polymorphic_records;
  Hashtbl.reset mono_record_instances;
  let variant_decls =
    List.filter_map (fun decl ->
      match decl with
      | Ast.Top_type (name, params, variants) -> Some (name, params, variants)
      | _ -> None) prog.decls
  in
  let variant_typedefs =
    List.map (fun (name, params, variants) ->
      emit_variant_typedef name params variants) variant_decls
  in
  let variant_typedefs =
    List.filter (fun s -> s <> "") variant_typedefs
  in
  let variant_struct_bodies =
    List.filter_map (fun (name, _, variants) ->
      emit_variant_struct_body name variants) variant_decls
  in
  let main_expr = Ast.desugar_program prog in
  let skels, body_expr = lift_fn_skels main_expr in
  let fns = resolve_fn_types skels main_expr in
  (* Populate toplevel_fn_names so emit_expr can pick direct vs closure
     call and value-position references can use the closure wrapper. *)
  Hashtbl.reset toplevel_fn_names;
  List.iter (fun f -> Hashtbl.replace toplevel_fn_names f.name ()) fns;
  (* Polymorphic variant monomorphization: collect concrete
     instantiations from the AST + fn signatures, then emit specialized
     typedefs (forward+ptr for recursive instances, full struct for
     non-recursive). Bodies come after tuple/record typedefs. *)
  Hashtbl.reset show_types;
  (* Pre-populate polymorphic_records so the collector sees them. The
     typedef emission itself (which depends on c_type_of being correct
     for nested types) happens later via mono_record_typedefs. *)
  Hashtbl.iter (fun rname (info : Typer.record_info) ->
    if info.r_params <> [] then
      Hashtbl.replace polymorphic_records rname
        (info.r_params, info.r_fields))
    Typer.records;
  collect_mono_variant_instances main_expr fns;
  collect_show_types main_expr fns;
  let mono_variant_typedefs =
    Hashtbl.fold (fun _ (vn, args) acc ->
      emit_mono_variant_typedef vn args :: acc) mono_variant_instances []
  in
  let mono_variant_struct_bodies =
    Hashtbl.fold (fun _ (vn, args) acc ->
      match emit_mono_variant_struct_body vn args with
      | Some s -> s :: acc
      | None -> acc) mono_variant_instances []
  in
  let mono_record_typedefs =
    Hashtbl.fold (fun _ (rn, args) acc ->
      emit_mono_record_typedef rn args :: acc) mono_record_instances []
  in
  let mono_record_struct_bodies =
    Hashtbl.fold (fun _ (rn, args) acc ->
      emit_mono_record_struct_body rn args :: acc) mono_record_instances []
  in
  (* Tuple shape collection: walk the (now typer-annotated) AST plus the
     resolved fn signatures. *)
  let tuple_shapes =
    let from_expr = collect_tuple_shapes main_expr in
    let from_fns = List.concat_map (fun f ->
      collect_tuple_shapes
        Ast.{ loc = Loc.dummy; ty = Some f.return_ty; node = Var "" }
      @ (match Ast.walk f.param_ty with
         | Ast.TyTuple ts -> [ts] | _ -> [])
      @ (match Ast.walk f.return_ty with
         | Ast.TyTuple ts -> [ts] | _ -> [])
    ) fns in
    (* Also collect tuples inside specialized variant payloads (e.g.,
       `tuple_int_list_int` inside `list_int`'s Cons). *)
    let from_variants =
      Hashtbl.fold (fun _ (name, args) acc ->
        let (params, variants) = Hashtbl.find polymorphic_variants name in
        let mapping = List.combine params args in
        List.fold_left (fun acc (_, arg_opt) ->
          match arg_opt with
          | Some t ->
            (match Ast.walk (subst_params mapping t) with
             | Ast.TyTuple ts -> ts :: acc
             | _ -> acc)
          | None -> acc) acc variants
      ) mono_variant_instances []
    in
    let all = from_expr @ from_fns @ from_variants in
    (* Dedup by struct name. *)
    let seen = Hashtbl.create 8 in
    List.filter (fun ts ->
      let k = tuple_struct_name ts in
      if Hashtbl.mem seen k then false
      else (Hashtbl.add seen k (); true)
    ) all
  in
  let tuple_typedefs = List.map emit_tuple_typedef tuple_shapes in
  let record_names = collect_record_names main_expr fns in
  let record_typedefs = List.map emit_record_typedef record_names in
  let record_struct_bodies = List.map emit_record_struct_body record_names in
  let record_struct_bodies =
    List.filter (fun s -> s <> "") record_struct_bodies
  in
  let tuple_struct_bodies = List.map emit_tuple_struct_body tuple_shapes in
  (* Closure / inner-fn lifting (defunctionalization). Done AFTER
     top-level fn types are resolved so we know toplevel names. *)
  let toplevel_names = List.map (fun f -> f.name) fns in
  let inner_fns = lift_inner_fns toplevel_names fns in
  (* Closure (first-class fn) machinery: emit a `closure_T1_T2` typedef
     per arrow type used + a wrapper / value const for each top-level fn. *)
  let arrow_pairs = collect_arrow_types main_expr fns in
  let closure_typedefs =
    List.map (fun (p, r) -> emit_closure_typedef p r) arrow_pairs
  in
  let closure_wrappers = List.map emit_closure_wrapper fns in
  (* Reset anonymous-closure state before generating fn defs (which
     drives emit_expr to populate `pending_closures`). *)
  pending_closures := [];
  anon_closure_counter := 0;
  let fn_defs_main =
    List.map emit_lifted_fn inner_fns
    @ List.map emit_fn fns
  in
  (* Now emit the closure adapters that were registered during the
     above emissions. They might themselves emit more pending closures
     (nested), so keep draining until the queue is empty. *)
  let closure_env_typedefs = ref [] in
  let closure_adapter_forward_decls = ref [] in
  let closure_adapters = ref [] in
  let rec drain () =
    let queue = !pending_closures in
    pending_closures := [];
    if queue <> [] then begin
      List.iter (fun ce ->
        closure_env_typedefs := emit_closure_env_typedef ce :: !closure_env_typedefs;
        closure_adapter_forward_decls :=
          emit_closure_adapter_forward_decl ce :: !closure_adapter_forward_decls;
        closure_adapters := emit_closure_adapter ce :: !closure_adapters)
        (List.rev queue);
      drain ()
    end
  in
  drain ();
  let closure_env_typedefs =
    List.filter (fun s -> s <> "") (List.rev !closure_env_typedefs)
  in
  let closure_adapter_forward_decls = List.rev !closure_adapter_forward_decls in
  let closure_adapters = List.rev !closure_adapters in
  let show_fn_forward_decls =
    Hashtbl.fold (fun tag t acc ->
      emit_show_fn_forward_decl tag t :: acc) show_types []
  in
  let show_fn_defs =
    Hashtbl.fold (fun tag t acc ->
      emit_show_fn tag t :: acc) show_types []
  in
  let forward_decls =
    List.map emit_fn_forward_decl fns
    @ List.map emit_lifted_fn_forward_decl inner_fns
    @ closure_adapter_forward_decls
    @ show_fn_forward_decls
  in
  let fn_defs =
    fn_defs_main
    @ closure_adapters
    @ closure_wrappers
    @ show_fn_defs
  in
  let main_body = emit_expr body_expr in
  let main_stmt =
    match main_format_of main_ty with
    | None -> "  (void)(" ^ main_body ^ ");  /* unit result */"
    | Some fmt -> "  printf(\"" ^ fmt ^ "\\n\", " ^ main_body ^ ");"
  in
  let parts =
    [ "#include <stdio.h>";
      "#include <stdlib.h>";
      "#include <string.h>";
      "";
      region_runtime_helpers;
      "";
      str_concat_helper;
      "" ]
    (* Forward decls of all named struct types — these let closure
       typedefs (function pointers returning struct values by name)
       compile even when the struct body isn't visible yet. *)
    @ (if variant_typedefs = [] then [] else variant_typedefs @ [""])
    @ (if mono_variant_typedefs = [] then [] else mono_variant_typedefs @ [""])
    @ (if record_typedefs = [] then [] else record_typedefs @ [""])
    @ (if mono_record_typedefs = [] then [] else mono_record_typedefs @ [""])
    @ (if tuple_typedefs = [] then [] else tuple_typedefs @ [""])
    (* Closure typedefs reference user struct names (e.g.,
       `closure_int_Conn`) but only via function pointer types, which C
       accepts with forward-declared structs. *)
    @ (if closure_typedefs = [] then [] else closure_typedefs @ [""])
    (* Now the struct bodies themselves — fields may reference closure
       types (e.g., `closure_unit_unit close;` inside a Drop record), so
       these need to come AFTER closure typedefs. *)
    @ (if tuple_struct_bodies = [] then [] else tuple_struct_bodies @ [""])
    @ (if record_struct_bodies = [] then [] else record_struct_bodies @ [""])
    @ (if mono_record_struct_bodies = [] then [] else mono_record_struct_bodies @ [""])
    @ (if variant_struct_bodies = [] then [] else variant_struct_bodies @ [""])
    @ (if mono_variant_struct_bodies = [] then [] else mono_variant_struct_bodies @ [""])
    @ (if closure_env_typedefs = [] then [] else closure_env_typedefs @ [""])
    @ (if forward_decls = [] then [] else forward_decls @ [""])
    @ (if fn_defs = [] then [] else fn_defs @ [""])
    @ [ "int main(void) {";
        "  __lang_region_init(&__lang_default_region, 1 << 22);";
        main_stmt;
        "  __lang_region_free(&__lang_default_region);";
        "  return 0;";
        "}";
        "" ]
  in
  String.concat "\n" parts
