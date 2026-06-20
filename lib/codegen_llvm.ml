(* LLVM IR codegen — Phase 5.1 MVP.
   Mirrors codegen_c.ml's first slice scope:
   int / bool / arithmetic / compare / logic / Neg / If / Let (P_var) / Var / Annot.
   Emits textual LLVM IR (modern opaque-pointer form) that `clang` accepts
   directly: `clang out.ll -o bin`.

   Scope intentionally narrow — future slices add functions, strings,
   tuples, records, variants, closures, region/view, in parallel with
   how Phase 4 grew. *)

exception Codegen_error of Loc.t * string

let unsupported loc what =
  raise (Codegen_error (loc, "unsupported (llvm codegen, Phase 5.1 MVP): " ^ what))

(* SSA register / basic-block label counter. Reset per emit_program. *)
let reg_counter = ref 0
let fresh_reg () =
  let n = !reg_counter in
  incr reg_counter;
  Printf.sprintf "%%t%d" n

let label_counter = ref 0
let fresh_label base =
  let n = !label_counter in
  incr label_counter;
  Printf.sprintf "%s%d" base n

(* Accumulated instruction lines (without leading indent / newline).
   Reset per emit_program, appended via emit_instr from emit_expr. *)
let instrs : string list ref = ref []
let emit_instr s = instrs := s :: !instrs
let emit_label s = instrs := (s ^ ":") :: !instrs

(* env: maps Lang variable name -> LLVM SSA value (e.g. "%t3" or "42").
   Pure functional; let-bindings extend it for the body. *)
type env = (string * string) list
let lookup (env : env) name loc =
  match List.assoc_opt name env with
  | Some v -> v
  | None -> unsupported loc ("unbound variable: " ^ name)

let llvm_binop_int = function
  | Ast.Add -> "add"
  | Ast.Sub -> "sub"
  | Ast.Mul -> "mul"
  | Ast.Div -> "sdiv"
  | Ast.Mod -> "srem"
  | Ast.Concat -> raise Exit  (* handled at caller *)

let llvm_cmp_int = function
  | Ast.Eq -> "eq"
  | Ast.Ne -> "ne"
  | Ast.Lt -> "slt"
  | Ast.Le -> "sle"
  | Ast.Gt -> "sgt"
  | Ast.Ge -> "sge"

(* Stable name fragment for a type — used to mint struct names. Mirrors
   codegen_c's ty_tag so a Lang `(int, str)` tuple maps to the same
   `tuple_int_str` shape across backends. *)
let rec ty_tag (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt -> "int"
  | Ast.TyBool -> "bool"
  | Ast.TyStr -> "str"
  | Ast.TyUnit -> "unit"
  | Ast.TyTuple ts -> "tuple_" ^ String.concat "_" (List.map ty_tag ts)
  | Ast.TyArrow (p, r) -> "closure_" ^ ty_tag p ^ "_" ^ ty_tag r
  | Ast.TyCon (name, []) -> name
  | Ast.TyCon (name, args) -> name ^ "_" ^ String.concat "_" (List.map ty_tag args)
  | Ast.TyRef (_, r, Ast.TyUnit) ->
    (* Region marker — region 名そのものを tag に使う (codegen_c と同じ). *)
    r
  | other ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unsupported LLVM codegen type element: %s" (Ast.pp_ty other)))

let tuple_struct_name (elems : Ast.ty list) : string =
  "tuple_" ^ String.concat "_" (List.map ty_tag elems)

let closure_struct_name (p : Ast.ty) (r : Ast.ty) : string =
  "closure_" ^ ty_tag p ^ "_" ^ ty_tag r

(* Variant tags: each constructor → integer tag. Populated up front
   for both monomorphic and polymorphic variants. *)
let variant_tags : (string, int) Hashtbl.t = Hashtbl.create 16

(* Polymorphic variant declarations: name → (params, variants).
   Populated before emit_expr from Exhaustive's variant registry. *)
let polymorphic_variants
    : (string, string list * (string * Ast.ty option) list) Hashtbl.t =
  Hashtbl.create 4

(* Polymorphic record declarations: name → (params, fields). *)
let polymorphic_records
    : (string, string list * (string * Ast.ty) list) Hashtbl.t =
  Hashtbl.create 4

(* Concrete instantiations seen in the program. Key is the mono name
   (e.g. `opt_int`, `Box_str`); value is the source name + arg list. *)
let mono_variant_instances : (string, string * Ast.ty list) Hashtbl.t =
  Hashtbl.create 8
let mono_record_instances : (string, string * Ast.ty list) Hashtbl.t =
  Hashtbl.create 8

(* Phase 15.3: concrete element types of `Vec[R, T]` seen in the program.
   Key is `ty_tag` of the element type (`int`, `str`, `tuple_int_int`, ...)
   and value is the walked element type. For each entry the codegen emits
   `%mere_vec_<tag>` struct type + 4 helper functions. *)
let vec_instances : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.5: vec_iter / vec_fold helper instances.
   vec_iter is keyed by T tag; vec_fold by `T_tag ^ "__" ^ U_tag` —
   each instance gets its own `@mere_vec_<T>_iter` /
   `@mere_vec_<T>_fold_<U>` function. *)
let vec_iter_instances : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4
let vec_fold_instances : (string, Ast.ty * Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.6: vec_map per-(T, U) and vec_filter per-T helper instances. *)
let vec_map_instances : (string, Ast.ty * Ast.ty) Hashtbl.t = Hashtbl.create 4
let vec_filter_instances : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.7: concrete element types of `OwnedVec[T]`. Heap-allocated,
   not region-bound. *)
let owned_vec_instances : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.9: StrBuf[R] usage flag — non-polymorphic, single runtime. *)
let strbuf_used = ref false

(* Phase 16.3: Logger / Metrics builtin usage flags. *)
let logger_used = ref false
let metrics_used = ref false

(* Phase 15.10: Map[R, K, V] per-(K, V) instances. *)
let map_instances : (string, Ast.ty * Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.12: vec_to_list per-T instances. *)
let vec_to_list_instances : (string, Ast.ty * Ast.ty) Hashtbl.t =
  Hashtbl.create 4

let rec subst_params (mapping : (string * Ast.ty) list) (t : Ast.ty) : Ast.ty =
  match Ast.walk t with
  | Ast.TyParam p ->
    (try List.assoc p mapping with Not_found -> t)
  | Ast.TyArrow (a, b) -> Ast.TyArrow (subst_params mapping a, subst_params mapping b)
  | Ast.TyTuple ts -> Ast.TyTuple (List.map (subst_params mapping) ts)
  | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map (subst_params mapping) args)
  | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, subst_params mapping inner)
  | t -> t

let subst_variants
    (params : string list) (args : Ast.ty list)
    (variants : (string * Ast.ty option) list) : (string * Ast.ty option) list =
  let mapping = List.combine params args in
  List.map (fun (cname, arg_opt) ->
    (cname, Option.map (subst_params mapping) arg_opt)) variants

let mono_variant_name (name : string) (args : Ast.ty list) : string =
  match args with
  | [] -> name
  | _ -> name ^ "_" ^ String.concat "_" (List.map ty_tag args)

let mono_record_name (name : string) (args : Ast.ty list) : string =
  match args with
  | [] -> name
  | _ -> name ^ "_" ^ String.concat "_" (List.map ty_tag args)

(* Names of variants whose value representation is a pointer to a heap
   node (because the variant's payload self-references). Mono and poly
   instantiations are tracked separately by their LLVM-side struct name. *)
let recursive_variants : (string, unit) Hashtbl.t = Hashtbl.create 4

(* Types that need a `show_<tag>` function emitted. Key is ty_tag of
   the type (used as the function name suffix); value is the type. *)
let show_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

let is_recursive_variant_name (name : string) : bool =
  Hashtbl.mem recursive_variants name

(* Direct self-reference in a variant's payload (the type's own name). *)
let variant_is_recursive
    (name : string) (variants : (string * Ast.ty option) list) : bool =
  let rec mentions t =
    match Ast.walk t with
    | Ast.TyCon (n, _) when n = name -> true
    | Ast.TyCon (_, args) -> List.exists mentions args
    | Ast.TyTuple ts -> List.exists mentions ts
    | Ast.TyArrow (a, b) -> mentions a || mentions b
    | Ast.TyRef (_, _, inner) -> mentions inner
    | _ -> false
  in
  List.exists (fun (_, arg_opt) ->
    match arg_opt with Some t -> mentions t | None -> false) variants

(* Whether a mono instance (name, args) is recursive — does any
   substituted payload mention the SAME (name, args)? *)
let mono_variant_is_recursive
    (vname : string) (args : Ast.ty list)
    (svariants : (string * Ast.ty option) list) : bool =
  let same_inst t =
    match Ast.walk t with
    | Ast.TyCon (n, ts) when n = vname && List.length ts = List.length args ->
      List.for_all2 (fun a b -> ty_tag (Ast.walk a) = ty_tag (Ast.walk b)) ts args
    | _ -> false
  in
  let rec ty_mentions t =
    same_inst t
    || (match Ast.walk t with
        | Ast.TyTuple ts -> List.exists ty_mentions ts
        | Ast.TyArrow (a, b) -> ty_mentions a || ty_mentions b
        | Ast.TyCon (_, targs) -> List.exists ty_mentions targs
        | Ast.TyRef (_, _, inner) -> ty_mentions inner
        | _ -> false)
  in
  List.exists (fun (_, arg_opt) ->
    match arg_opt with Some t -> ty_mentions t | None -> false) svariants

(* Probe: is the type fully resolved (no tyvars / params / floats)? *)
let rec ty_is_concrete (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, _, inner) -> ty_is_concrete inner
  | Ast.TyVar _ | Ast.TyParam _ | Ast.TyFloat -> false

(* Walk a Lang type to its LLVM type. Tuples / monomorphic records /
   variants lower to named-struct references (`%tuple_int_int`,
   `%Point`, `%Status`); these are emitted as `type` definitions at the
   top of the module. *)
let rec llvm_ty_of (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyCon ("Vec", args) ->
    (* Phase 15.3: Vec[R, T] — element type T (= ty_tag-sanitized name)
       で `%mere_vec_<tag>*` (LLVM opaque pointer なのでただの ptr) を返す。
       要素型を vec_instances に登録すれば runtime ジェネレータが拾う。 *)
    (match List.map Ast.walk args with
     | [_; elem_ty] when ty_is_concrete elem_ty ->
       let tag = ty_tag elem_ty in
       if not (Hashtbl.mem vec_instances tag) then
         Hashtbl.add vec_instances tag elem_ty;
       (* All LLVM pointers are opaque `ptr`; the element type only affects
          the runtime helpers' GEP / load / store, not the value's static
          LLVM type. *)
       let _ = llvm_ty_of elem_ty in
       "ptr"
     | _ ->
       raise (Codegen_error (Loc.dummy,
         "unsupported in LLVM codegen subset: Vec[R, <unresolved>] (element type must be concrete)")))
  | Ast.TyCon ("OwnedVec", args) ->
    (* Phase 15.7: OwnedVec[T] — heap-allocated、要素型 T を walk して
       opaque ptr を返す。`owned_vec_instances` に登録。 *)
    (match List.map Ast.walk args with
     | [elem_ty] when ty_is_concrete elem_ty ->
       let tag = ty_tag elem_ty in
       if not (Hashtbl.mem owned_vec_instances tag) then
         Hashtbl.add owned_vec_instances tag elem_ty;
       let _ = llvm_ty_of elem_ty in
       "ptr"
     | _ ->
       raise (Codegen_error (Loc.dummy,
         "unsupported in LLVM codegen subset: OwnedVec[<unresolved>] (element type must be concrete)")))
  | Ast.TyCon ("StrBuf", _) ->
    strbuf_used := true;
    "ptr"
  | Ast.TyCon ("Map", args) ->
    (* Phase 15.10: Map[R, K, V] — per-(K, V) monomorphize、K = int / str。 *)
    (match List.map Ast.walk args with
     | [_; k_ty; v_ty]
       when ty_is_concrete k_ty && ty_is_concrete v_ty ->
       let rec is_key_supported = function
         | Ast.TyInt | Ast.TyBool | Ast.TyStr -> true
         | Ast.TyTuple ts -> List.for_all is_key_supported ts
         | Ast.TyCon (rname, _) when Hashtbl.mem Typer.records rname ->
           let info = Hashtbl.find Typer.records rname in
           List.for_all (fun (_, ft) -> is_key_supported (Ast.walk ft))
             info.Typer.r_fields
         | Ast.TyCon (vname, _) when Hashtbl.mem Exhaustive.type_variants vname ->
           (* Phase 15.15: nullary variants.
              Phase 15.16: also payload variants, but LLVM MVP requires
              all payloads share the same type. *)
           let ctors = Hashtbl.find Exhaustive.type_variants vname in
           List.for_all (fun (_, payload) ->
             match payload with
             | None -> true
             | Some pt -> is_key_supported (Ast.walk pt)) ctors
         | _ -> false
       in
       if not (is_key_supported k_ty) then
         raise (Codegen_error (Loc.dummy,
           "Map key type must be int / bool / str / tuple / record / variant in LLVM codegen (Phase 15.10〜15.16)"));
       let k_tag = ty_tag k_ty in
       let v_tag = ty_tag v_ty in
       let key = k_tag ^ "__" ^ v_tag in
       if not (Hashtbl.mem map_instances key) then
         Hashtbl.add map_instances key (k_ty, v_ty);
       let _ = llvm_ty_of k_ty in
       let _ = llvm_ty_of v_ty in
       "ptr"
     | _ ->
       raise (Codegen_error (Loc.dummy,
         "unsupported in LLVM codegen subset: Map[<unresolved>]")))
  | Ast.TyInt -> "i32"
  | Ast.TyBool -> "i1"
  | Ast.TyStr -> "ptr"
  | Ast.TyUnit -> "i32"  (* unit becomes int 0 *)
  | Ast.TyTuple ts -> "%" ^ tuple_struct_name ts
  | Ast.TyRef _ -> "ptr"  (* `&R T` is a pointer into the region's buffer *)
  | Ast.TyCon (name, _) when Hashtbl.mem Typer.views name -> "ptr"
  | Ast.TyCon (name, args) when Hashtbl.mem polymorphic_records name ->
    "%" ^ mono_record_name name (List.map Ast.walk args)
  | Ast.TyCon (name, []) when Hashtbl.mem Typer.records name -> "%" ^ name
  | Ast.TyCon (name, args) when Hashtbl.mem polymorphic_variants name ->
    let mono = mono_variant_name name (List.map Ast.walk args) in
    if is_recursive_variant_name mono then "ptr" else "%" ^ mono
  | Ast.TyCon (name, []) when Hashtbl.mem Typer.types name ->
    if is_recursive_variant_name name then "ptr" else "%" ^ name
  | Ast.TyArrow (p, r) -> "%" ^ closure_struct_name p r
  | _ -> "i32"  (* best-effort fallback; typer should reject before this *)

(* View test: is this Lang type a view? Views are constructed via
   Record_lit with a name in Typer.views; values are ptr to the
   region-allocated struct. *)
let is_view_type (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyCon (n, _) -> Hashtbl.mem Typer.views n
  | _ -> false

(* Look up a record's ordered field list. Raises if name isn't in the
   typer registry — the typer should have caught that before codegen. *)
let record_fields (name : string) : (string * Ast.ty) list =
  match Hashtbl.find_opt Typer.records name with
  | Some info -> info.Typer.r_fields
  | None ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unknown record type `%s` at LLVM codegen" name))

let field_index (record_name : string) (field_name : string) : int =
  let fields = record_fields record_name in
  let rec idx i = function
    | [] ->
      raise (Codegen_error (Loc.dummy,
        Printf.sprintf "record `%s` has no field `%s`" record_name field_name))
    | (n, _) :: _ when n = field_name -> i
    | _ :: rest -> idx (i + 1) rest
  in
  idx 0 fields

(* Encode an OCaml string to LLVM's c"..." literal body (without the
   trailing \00). Printable ASCII goes through; everything else is \HH. *)
let llvm_string_escape (s : string) : string =
  let buf = Buffer.create (String.length s + 4) in
  String.iter (fun c ->
    let code = Char.code c in
    if code >= 32 && code <= 126 && c <> '"' && c <> '\\' then
      Buffer.add_char buf c
    else
      Buffer.add_string buf (Printf.sprintf "\\%02X" code)
  ) s;
  Buffer.contents buf

(* Accumulator for string-literal globals.
   Each entry: full LLVM declaration line. *)
let str_globals : string list ref = ref []
let str_counter = ref 0
let fresh_str_global (s : string) : string =
  let n = !str_counter in
  incr str_counter;
  let label = Printf.sprintf "@.str_%d" n in
  let escaped = llvm_string_escape s in
  let bytes_len = String.length s + 1 in
  let decl =
    Printf.sprintf "%s = private constant [%d x i8] c\"%s\\00\""
      label bytes_len escaped
  in
  str_globals := decl :: !str_globals;
  label

let rec ty_is_concrete (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, _, inner) -> ty_is_concrete inner
  | Ast.TyVar _ | Ast.TyParam _ | Ast.TyFloat -> false

(* Top-level fn binding extracted from main: `let name = fn param -> body in ...`.
   We keep the original Fun expr so we can read its typer-set `.ty`. *)
type fn_skel = {
  sname : string;
  sparam : string;
  sbody : Ast.expr;
  sfun : Ast.expr;
}

(* Fully type-resolved fn declaration. *)
type fn_decl = {
  name      : string;
  param     : string;
  body      : Ast.expr;
  param_ty  : Ast.ty;
  return_ty : Ast.ty;
}

(* Set of known top-level fn names (used by emit_expr to direct-call Var). *)
let toplevel_fn_names : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Concrete LLVM-side types of in-scope name bindings. Used to recover
   concrete arrow types when an inner App's head Var still has a
   polymorphic `.ty` from let-poly generalization. Saved/restored
   around each fn body emit. *)
let current_var_types : (string * Ast.ty) list ref = ref []

(* Type the parent context expects this expression to have. Set by
   emit_fn_def / emit_anon_adapter as the body's return type, so
   anonymous Funs in tail position can recover their concrete arrow
   type even when their .ty was generalized to polymorphic. *)
let current_expected_ty : Ast.ty option ref = ref None

(* Active user `region R { ... }` scopes — region name → SSA register
   holding the region's ptr. Pushed by Region_block entry, popped at
   exit so `&R v` / view literals can find the right region. *)
let current_regions : (string * string) list ref = ref []

(* For a pattern matched against a scrutinee of type `scrut_ty` and
   payload of type `payload_ty` (if any), produce the (name, concrete-ty)
   bindings introduced by the pattern. Used to update current_var_types
   so arm bodies can recover concrete types for pattern-bound names
   (otherwise the typer's AST .ty may carry polymorphic ty-vars). *)
let pattern_var_types
    (pat : Ast.pattern) (scrut_ty : Ast.ty) (payload_ty : Ast.ty option)
    : (string * Ast.ty) list =
  match pat.Ast.pnode with
  | Ast.P_var n -> [(n, scrut_ty)]
  | Ast.P_wild -> []
  | Ast.P_constr (_, None) -> []
  | Ast.P_constr (_, Some sub) ->
    (match sub.Ast.pnode, payload_ty with
     | Ast.P_var n, Some t -> [(n, t)]
     | Ast.P_wild, _ -> []
     | Ast.P_tuple pats, Some t ->
       let elem_tys =
         match Ast.walk t with
         | Ast.TyTuple ts -> ts
         | _ -> []
       in
       List.map2 (fun p ety ->
         match p.Ast.pnode with
         | Ast.P_var n -> [(n, ety)]
         | _ -> [])
         pats elem_tys
       |> List.concat
     | _ -> [])
  | _ -> []

(* Names of a pattern's bound variables (used by free_vars). *)
let pattern_vars (p : Ast.pattern) : string list =
  let rec go p =
    match p.Ast.pnode with
    | Ast.P_var n -> [n]
    | Ast.P_constr (_, Some sub) -> go sub
    | Ast.P_tuple ps -> List.concat_map go ps
    | Ast.P_record (_, fs) -> List.concat_map (fun (_, p) -> go p) fs
    | Ast.P_as (inner, n) -> n :: go inner
    | Ast.P_or (a, _) -> go a
    | _ -> []
  in
  go p

(* Free variables of `e` excluding `initially_bound` and names introduced
   by inner binders. Preserves left-to-right first-appearance order. *)
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
    | Ast.With (n, v, body) -> go v bound; go body (n :: bound)
    | Ast.If (c, t, e_) -> go c bound; go t bound; go e_ bound
    | Ast.Fun (param, _, body) -> go body (param :: bound)
    | Ast.Constr (_, Some a) -> go a bound
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      go s bound;
      List.iter (fun (pat, g, b) ->
        let bound' = pattern_vars pat @ bound in
        (match g with Some ge -> go ge bound' | None -> ()); go b bound') arms
    | Ast.Tuple es -> List.iter (fun e -> go e bound) es
    | Ast.Region_block (n, b) -> go b (n :: bound)
    | Ast.Ref (_, _, a) -> go a bound
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e bound) fs
    | Ast.Field_get (a, _) -> go a bound
    | Ast.Record_update (a, fs) ->
      go a bound; List.iter (fun (_, e) -> go e bound) fs
  in
  go e initially_bound;
  List.rev !order

(* Anonymous-closure emission state. Each `Fun` in expression position
   becomes one of these; the adapter body is emitted later by
   draining the queue in emit_program. *)
type closure_emission = {
  ce_adapter_name : string;
  ce_env_name     : string;
  ce_env_fields   : (string * Ast.ty) list;
  ce_param        : string;
  ce_param_ty     : Ast.ty;
  ce_return_ty    : Ast.ty;
  ce_body         : Ast.expr;
}
let pending_closures : closure_emission list ref = ref []
let anon_env_typedefs : string list ref = ref []
let anon_closure_counter = ref 0
let fresh_anon_names () =
  let n = !anon_closure_counter in
  incr anon_closure_counter;
  (Printf.sprintf "anon_%d_fn" n, Printf.sprintf "anon_%d_env" n)

(* Walk the desugared main expression, peeling top-level fn-binding lets
   (P_var of Fun) and let-recs whose bindings are all single-arg fns.
   Returns the skels and the residual main body. *)
let lift_fn_skels (e : Ast.expr) : fn_skel list * Ast.expr =
  let rec go (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, rest)
      when (match pat.Ast.pnode with Ast.P_var _ -> true | _ -> false) ->
      (match value.Ast.node with
       | Ast.Fun (param, _, fn_body) ->
         let name = match pat.Ast.pnode with Ast.P_var n -> n | _ -> assert false in
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
              "let rec binding must be a single-arg function in LLVM subset")))
          bindings
      in
      let more, rest' = go rest in
      skels @ more, rest'
    | _ -> [], e
  in
  go e

(* Scan `root` for a Var of `name` whose ty walked to a concrete arrow.
   Used when the binding-site Fun.ty was generalized (let-poly) and we
   need a monomorphic instantiation. *)
let find_concrete_arrow (name : string) (root : Ast.expr) : Ast.ty option =
  let found = ref None in
  let rec go (e : Ast.expr) =
    (if !found = None then
       match e.Ast.node with
       | Ast.Var n when n = name ->
         (match e.Ast.ty with
          | Some t ->
            let t = Ast.walk t in
            (match t with
             | Ast.TyArrow _ when ty_is_concrete t -> found := Some t
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
    | Ast.Ref (_, _, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  go root;
  !found

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
              "fn `%s` has polymorphic type with no concrete use site \
               — LLVM codegen needs a monomorphic instantiation" s.sname))
    in
    match arrow with
    | Ast.TyArrow (p, r) ->
      { name = s.sname; param = s.sparam; body = s.sbody;
        param_ty = Ast.walk p; return_ty = Ast.walk r }
    | _ ->
      raise (Codegen_error (s.sfun.Ast.loc,
        Printf.sprintf "function `%s` has non-arrow inferred type" s.sname))
  ) skels

(* Walk a typed AST + fn signatures to collect every concrete tuple shape
   so we can emit `%tuple_int_str = type { i32, ptr }` for each. *)
let collect_tuple_shapes (root : Ast.expr) (fns : fn_decl list) : Ast.ty list list =
  let seen = Hashtbl.create 8 in
  let add elems =
    let key = tuple_struct_name elems in
    if not (Hashtbl.mem seen key) then Hashtbl.add seen key elems
  in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyTuple ts ->
      if List.for_all ty_is_concrete ts then add ts;
      List.iter walk_ty ts
    | Ast.TyArrow (a, b) -> walk_ty a; walk_ty b
    | Ast.TyCon (_, args) -> List.iter walk_ty args
    | Ast.TyRef (_, _, inner) -> walk_ty inner
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
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns;
  (* Also walk substituted payloads of mono instances — variant
     payloads (e.g. `(int, list int)` inside Cons) are referenced by
     the variant struct definition but may never appear as a direct
     AST node when the program only matches/shows the type. *)
  Hashtbl.iter (fun _ (vn, args) ->
    let (params, variants) = Hashtbl.find polymorphic_variants vn in
    let sv = subst_variants params args variants in
    List.iter (fun (_, arg_opt) ->
      match arg_opt with Some t -> walk_ty t | None -> ()) sv
  ) mono_variant_instances;
  Hashtbl.iter (fun _ (rn, args) ->
    let (params, fields) = Hashtbl.find polymorphic_records rn in
    let mapping = List.combine params args in
    List.iter (fun (_, ft) -> walk_ty (subst_params mapping ft)) fields
  ) mono_record_instances;
  Hashtbl.fold (fun _ v acc -> v :: acc) seen []

let emit_tuple_typedef (elems : Ast.ty list) : string =
  let name = tuple_struct_name elems in
  let fields = String.concat ", " (List.map llvm_ty_of elems) in
  Printf.sprintf "%%%s = type { %s }" name fields

(* Walk a typed AST + fn signatures to collect every monomorphic variant
   type name encountered. *)
let collect_variant_names (root : Ast.expr) (fns : fn_decl list) : string list =
  let seen = Hashtbl.create 8 in
  let add name =
    if Hashtbl.mem Typer.types name &&
       not (Hashtbl.mem Typer.records name) &&
       not (Hashtbl.mem seen name) &&
       Hashtbl.find Typer.types name = 0 (* arity 0 — monomorphic *)
    then Hashtbl.add seen name ()
  in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyCon (n, args) -> add n; List.iter walk_ty args
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyArrow (a, b) -> walk_ty a; walk_ty b
    | Ast.TyRef (_, _, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    (match e.Ast.node with
     | Ast.Constr (cname, _) ->
       (match Hashtbl.find_opt Typer.constructors cname with
        | Some info -> add info.Typer.type_name
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
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns;
  Hashtbl.fold (fun k () acc -> k :: acc) seen []

(* Walk a typed AST + fn signatures to collect every monomorphic record
   type name encountered. *)
let collect_record_names (root : Ast.expr) (fns : fn_decl list) : string list =
  let seen = Hashtbl.create 8 in
  let add name =
    if Hashtbl.mem Typer.records name &&
       not (Hashtbl.mem seen name) then
      let info = Hashtbl.find Typer.records name in
      if info.Typer.r_params = [] then
        Hashtbl.add seen name ()
  in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyCon (n, args) -> add n; List.iter walk_ty args
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyArrow (a, b) -> walk_ty a; walk_ty b
    | Ast.TyRef (_, _, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    (match e.Ast.node with
     | Ast.Record_lit (n, _) -> add n
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
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns;
  Hashtbl.fold (fun k () acc -> k :: acc) seen []

let emit_record_typedef (name : string) : string =
  let fields = record_fields name in
  let field_tys = String.concat ", " (List.map (fun (_, t) -> llvm_ty_of t) fields) in
  Printf.sprintf "%%%s = type { %s }" name field_tys

(* Variants and their concrete shape — populated from Exhaustive's
   registry. None means nullary-only; Some t means all payload-bearing
   constructors share payload type t (MVP restriction). *)
let variant_shape (name : string) : (string * Ast.ty option) list =
  match Hashtbl.find_opt Exhaustive.type_variants name with
  | Some vs -> vs
  | None ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unknown variant type `%s` at LLVM codegen" name))

(* Decide the single payload type for a variant (Phase 5.6 MVP only
   handles all-nullary or single-payload-type). Returns None if all
   constructors are nullary. *)
let variant_payload_ty (name : string) : Ast.ty option =
  let vs = variant_shape name in
  let payloads =
    List.filter_map (fun (_, p) -> p) vs
  in
  match payloads with
  | [] -> None
  | first :: rest ->
    let first_tag = ty_tag (Ast.walk first) in
    if List.for_all (fun p -> ty_tag (Ast.walk p) = first_tag) rest then
      Some first
    else
      raise (Codegen_error (Loc.dummy,
        Printf.sprintf
          "variant `%s` has constructors with different payload types — \
           Phase 5 MVP needs all payloads to be the same type" name))

let emit_variant_typedef (name : string) : string =
  let vs = variant_shape name in
  List.iteri (fun i (cname, _) ->
    Hashtbl.replace variant_tags cname i) vs;
  if is_recursive_variant_name name then begin
    (* Recursive: emit `%name_node = type { i32, T }` — the on-heap
       node. The "value" of the variant at this point is `ptr` (handled
       by llvm_ty_of). *)
    let payload =
      match variant_payload_ty name with
      | None -> ""
      | Some t -> Printf.sprintf ", %s" (llvm_ty_of t)
    in
    Printf.sprintf "%%%s_node = type { i32%s }" name payload
  end
  else
    match variant_payload_ty name with
    | None -> Printf.sprintf "%%%s = type { i32 }" name
    | Some t -> Printf.sprintf "%%%s = type { i32, %s }" name (llvm_ty_of t)

(* Variant payload type for an already-substituted variant list (used by
   mono-instance codegen, where we've already applied param→arg subst). *)
let variant_payload_ty_of (variants : (string * Ast.ty option) list)
    : Ast.ty option =
  let payloads = List.filter_map (fun (_, p) -> p) variants in
  match payloads with
  | [] -> None
  | first :: rest ->
    let first_tag = ty_tag (Ast.walk first) in
    if List.for_all (fun p -> ty_tag (Ast.walk p) = first_tag) rest then
      Some first
    else
      raise (Codegen_error (Loc.dummy,
        "variant has constructors with different payload types — \
         Phase 5 MVP needs all payloads to be the same type"))

(* Specialized typedef for a polymorphic variant instance. *)
let emit_mono_variant_typedef (variant_name : string) (args : Ast.ty list) : string =
  let mono_name = mono_variant_name variant_name args in
  let (params, variants) = Hashtbl.find polymorphic_variants variant_name in
  let svariants = subst_variants params args variants in
  if is_recursive_variant_name mono_name then begin
    let payload =
      match variant_payload_ty_of svariants with
      | None -> ""
      | Some t -> Printf.sprintf ", %s" (llvm_ty_of t)
    in
    Printf.sprintf "%%%s_node = type { i32%s }" mono_name payload
  end
  else
    match variant_payload_ty_of svariants with
    | None -> Printf.sprintf "%%%s = type { i32 }" mono_name
    | Some t -> Printf.sprintf "%%%s = type { i32, %s }" mono_name (llvm_ty_of t)

(* Specialized typedef for a polymorphic record instance. *)
let emit_mono_record_typedef (record_name : string) (args : Ast.ty list) : string =
  let mono_name = mono_record_name record_name args in
  let (params, fields) = Hashtbl.find polymorphic_records record_name in
  let mapping = List.combine params args in
  let field_tys =
    String.concat ", " (List.map (fun (_, ft) ->
      llvm_ty_of (subst_params mapping ft)) fields)
  in
  Printf.sprintf "%%%s = type { %s }" mono_name field_tys

(* Collect every distinct concrete arrow type (T1 -> T2) used in the
   program — these become `%closure_T1_T2 = type { ptr, ptr }` typedefs. *)
let collect_arrow_types (root : Ast.expr) (fns : fn_decl list) : (Ast.ty * Ast.ty) list =
  let seen = Hashtbl.create 8 in
  let add p r =
    let key = closure_struct_name p r in
    if not (Hashtbl.mem seen key) then Hashtbl.add seen key (p, r)
  in
  let seen_records : (string, unit) Hashtbl.t = Hashtbl.create 4 in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyArrow (p, r) ->
      let p' = Ast.walk p and r' = Ast.walk r in
      if ty_is_concrete p' && ty_is_concrete r' then add p' r';
      walk_ty p'; walk_ty r'
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyCon (name, args) ->
      List.iter walk_ty args;
      (* Phase 16.3: 既知 record の field 型もたどる。Logger / Metrics
         のように field が closure 型を持つ record で、field 経由でしか
         登場しない closure 型を arrow_pairs に拾わせる。 *)
      if Hashtbl.mem Typer.records name
         && not (Hashtbl.mem seen_records name)
      then begin
        Hashtbl.add seen_records name ();
        let info = Hashtbl.find Typer.records name in
        if info.Typer.r_params = [] then
          List.iter (fun (_, ft) -> walk_ty ft) info.Typer.r_fields
      end
    | Ast.TyRef (_, _, inner) -> walk_ty inner
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
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f ->
    add (Ast.walk f.param_ty) (Ast.walk f.return_ty);
    walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns;
  Hashtbl.fold (fun _ v acc -> v :: acc) seen []

(* Walk AST + fns to find every concrete instantiation of a polymorphic
   variant / record. Populates mono_variant_instances and
   mono_record_instances; later iteration emits one typedef per key. *)
let collect_mono_instances (root : Ast.expr) (fns : fn_decl list) : unit =
  let add name args =
    if List.for_all ty_is_concrete args then begin
      if Hashtbl.mem polymorphic_variants name
         && not (Hashtbl.mem mono_variant_instances
                   (mono_variant_name name args))
      then
        Hashtbl.add mono_variant_instances
          (mono_variant_name name args) (name, args);
      if Hashtbl.mem polymorphic_records name
         && not (Hashtbl.mem mono_record_instances
                   (mono_record_name name args))
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
    | Ast.TyRef (_, _, inner) -> walk_ty inner
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
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns

(* Walk AST to collect types passed to `show`. Pulls in dependent types
   (tuple elems, record fields, variant payloads) recursively. The
   Hashtbl guard prevents infinite recursion on self-referential
   variants (e.g. `'a list`). *)
let rec add_show_type (t : Ast.ty) : unit =
  let t = Ast.walk t in
  if not (ty_is_concrete t) then ()
  else
    let tag = ty_tag t in
    if Hashtbl.mem show_types tag then ()
    else begin
      Hashtbl.add show_types tag t;
      (* For polymorphic types, register the mono instance so typedef
         emission picks them up — needed when the program only uses
         this type via show (no constructor call to seed
         collect_mono_instances). *)
      (match t with
       | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
         let mono = mono_variant_name n args in
         if not (Hashtbl.mem mono_variant_instances mono) then
           Hashtbl.add mono_variant_instances mono (n, args)
       | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
         let mono = mono_record_name n args in
         if not (Hashtbl.mem mono_record_instances mono) then
           Hashtbl.add mono_record_instances mono (n, args)
       | _ -> ());
      (* Recurse into dependent types. *)
      match t with
      | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> ()
      | Ast.TyTuple ts -> List.iter add_show_type ts
      | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
        let (params, fields) = Hashtbl.find polymorphic_records n in
        let mapping = List.combine params args in
        List.iter (fun (_, ft) -> add_show_type (subst_params mapping ft)) fields
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
        let fields = record_fields n in
        List.iter (fun (_, ft) -> add_show_type ft) fields
      | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
        let (params, variants) = Hashtbl.find polymorphic_variants n in
        let sv = subst_variants params args variants in
        List.iter (fun (_, arg_opt) ->
          match arg_opt with Some t -> add_show_type t | None -> ()) sv
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.types n ->
        let vs = variant_shape n in
        List.iter (fun (_, arg_opt) ->
          match arg_opt with Some t -> add_show_type t | None -> ()) vs
      | _ -> ()
    end

let collect_show_types (root : Ast.expr) (fns : fn_decl list) : unit =
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
       (match arg.Ast.ty with
        | Some t -> add_show_type t
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
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_expr f.body) fns

(* Pre-defined string globals used by show fns. Emitted once per program. *)
let show_string_globals = ref []
let show_format_globals = ref []
(* String global for an arbitrary literal — adds a unique label.
   Different from fresh_str_global (which is per-call); these are
   shared / pre-registered at the start of show emission. *)
let mint_show_global name content =
  let bytes_len = String.length content + 1 in
  let escaped = llvm_string_escape content in
  show_string_globals :=
    Printf.sprintf "@.%s = private constant [%d x i8] c\"%s\\00\""
      name bytes_len escaped
    :: !show_string_globals

let mint_show_format name fmt =
  (* `fmt` is the OCaml string content (e.g. "%d") — emit it as the LLVM
     constant body and let LLVM count the bytes correctly. *)
  let bytes_len = String.length fmt + 1 in
  let escaped = llvm_string_escape fmt in
  show_format_globals :=
    Printf.sprintf "@.fmt_%s = private constant [%d x i8] c\"%s\\00\""
      name bytes_len escaped
    :: !show_format_globals

(* Emit a single show_<tag> function for the given type. *)
let emit_show_fn (tag : string) (t : Ast.ty) : string =
  let saved_instrs = !instrs in
  let saved_reg = !reg_counter and saved_lbl = !label_counter in
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
  let param_ty = llvm_ty_of t in
  let emit_asprintf fmt_name args =
    (* Allocate a local ptr to receive the asprintf result. *)
    let p = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = alloca ptr" p);
    let arg_str =
      if args = "" then "" else ", " ^ args
    in
    emit_instr (Printf.sprintf
                  "  call i32 (ptr, ptr, ...) @asprintf(ptr %s, ptr @.fmt_%s%s)"
                  p fmt_name arg_str);
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" r p);
    r
  in
  emit_instr "entry:";
  let result_reg =
    match Ast.walk t with
    | Ast.TyInt ->
      emit_asprintf "show_int" "i32 %x"
    | Ast.TyBool ->
      (* Select between "true" / "false" globals. *)
      let r = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = select i1 %%x, ptr @.s_true, ptr @.s_false" r);
      r
    | Ast.TyStr ->
      emit_asprintf "show_str" "ptr %x"
    | Ast.TyUnit ->
      "@.s_unit"
    | Ast.TyTuple ts ->
      (* Show each element, then asprintf "(%s, %s, ...)" with them. *)
      let tname = tuple_struct_name ts in
      let elem_strs =
        List.mapi (fun i ety ->
          let e = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, %d" e tname i);
          let s = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                        s (ty_tag ety) (llvm_ty_of ety) e);
          Printf.sprintf "ptr %s" s
        ) ts
      in
      emit_asprintf ("show_" ^ tag) (String.concat ", " elem_strs)
    | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
      let (params, fields) = Hashtbl.find polymorphic_records n in
      let mapping = List.combine params args in
      let sf = List.map (fun (fn, ft) -> (fn, subst_params mapping ft)) fields in
      let mono = mono_record_name n args in
      let field_strs =
        List.mapi (fun i (_, ft) ->
          let e = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, %d" e mono i);
          let s = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                        s (ty_tag ft) (llvm_ty_of ft) e);
          Printf.sprintf "ptr %s" s
        ) sf
      in
      emit_asprintf ("show_" ^ tag) (String.concat ", " field_strs)
    | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
      let fields = record_fields n in
      let field_strs =
        List.mapi (fun i (_, ft) ->
          let e = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, %d" e n i);
          let s = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                        s (ty_tag ft) (llvm_ty_of ft) e);
          Printf.sprintf "ptr %s" s
        ) fields
      in
      emit_asprintf ("show_" ^ tag) (String.concat ", " field_strs)
    | Ast.TyCon ("list", [elem_ty])
      when is_recursive_variant_name (mono_variant_name "list" [elem_ty]) ->
      (* `'a list` special-case: render as `[a, b, c]` instead of the
         generic `Cons (a, Cons (b, Cons (c, Nil)))` form. Walks the
         list with mutable iter / acc / first flag (via alloca/load/store
         for simplicity over phi chains). *)
      let mono = mono_variant_name "list" [elem_ty] in
      let node_ty = "%" ^ mono ^ "_node" in
      let payload_struct =
        "%" ^ tuple_struct_name [elem_ty; Ast.TyCon ("list", [elem_ty])]
      in
      let iter_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = alloca ptr" iter_p);
      let acc_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = alloca ptr" acc_p);
      let first_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = alloca i1" first_p);
      emit_instr (Printf.sprintf "  store ptr %%x, ptr %s" iter_p);
      emit_instr (Printf.sprintf "  store ptr @.s_lbracket, ptr %s" acc_p);
      emit_instr (Printf.sprintf "  store i1 1, ptr %s" first_p);
      let test_lbl = fresh_label "list_show_test_" in
      let body_lbl = fresh_label "list_show_body_" in
      let end_lbl = fresh_label "list_show_end_" in
      let first_lbl = fresh_label "list_show_first_" in
      let nfirst_lbl = fresh_label "list_show_nfirst_" in
      let iter_lbl = fresh_label "list_show_iter_" in
      emit_instr (Printf.sprintf "  br label %%%s" test_lbl);
      emit_label test_lbl;
      let cur = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" cur iter_p);
      let tag_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 0"
                    tag_p node_ty cur);
      let tag = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load i32, ptr %s" tag tag_p);
      let is_nil = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, 0" is_nil tag);
      emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                    is_nil end_lbl body_lbl);
      emit_label body_lbl;
      let pl_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 1"
                    pl_p node_ty cur);
      let pl = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load %s, ptr %s" pl payload_struct pl_p);
      let h = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = extractvalue %s %s, 0" h payload_struct pl);
      let t = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = extractvalue %s %s, 1" t payload_struct pl);
      let h_str = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                    h_str (ty_tag elem_ty) (llvm_ty_of elem_ty) h);
      let is_first = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load i1, ptr %s" is_first first_p);
      let acc_cur = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" acc_cur acc_p);
      emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                    is_first first_lbl nfirst_lbl);
      emit_label first_lbl;
      let new_acc_1 = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_str_concat(ptr %s, ptr %s)"
                    new_acc_1 acc_cur h_str);
      emit_instr (Printf.sprintf "  store ptr %s, ptr %s" new_acc_1 acc_p);
      emit_instr (Printf.sprintf "  store i1 0, ptr %s" first_p);
      emit_instr (Printf.sprintf "  br label %%%s" iter_lbl);
      emit_label nfirst_lbl;
      let tmp = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_str_concat(ptr %s, ptr @.s_comma_space)"
                    tmp acc_cur);
      let new_acc_2 = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_str_concat(ptr %s, ptr %s)"
                    new_acc_2 tmp h_str);
      emit_instr (Printf.sprintf "  store ptr %s, ptr %s" new_acc_2 acc_p);
      emit_instr (Printf.sprintf "  br label %%%s" iter_lbl);
      emit_label iter_lbl;
      emit_instr (Printf.sprintf "  store ptr %s, ptr %s" t iter_p);
      emit_instr (Printf.sprintf "  br label %%%s" test_lbl);
      emit_label end_lbl;
      let acc_final = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" acc_final acc_p);
      let r = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_str_concat(ptr %s, ptr @.s_rbracket)"
                    r acc_final);
      r
    | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
      let (params, variants) = Hashtbl.find polymorphic_variants n in
      let sv = subst_variants params args variants in
      let mono = mono_variant_name n args in
      let recursive = is_recursive_variant_name mono in
      let node_ty = "%" ^ mono ^ "_node" in
      (* Extract tag *)
      let tag_reg = fresh_reg () in
      if recursive then begin
        let p = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %%x, i32 0, i32 0"
                      p node_ty);
        emit_instr (Printf.sprintf "  %s = load i32, ptr %s" tag_reg p)
      end else
        emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, 0" tag_reg mono);
      (* Switch over tag: for each constructor, emit a branch that
         produces the string. *)
      let merge_label = fresh_label "show_join_" in
      let phi_entries = ref [] in
      List.iteri (fun ctor_tag (cname, arg_opt) ->
        let arm_label = fresh_label "show_arm_" in
        let next_label = fresh_label "show_next_" in
        let cmp = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, %d" cmp tag_reg ctor_tag);
        emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                      cmp arm_label next_label);
        emit_label arm_label;
        let s =
          match arg_opt with
          | None ->
            "@.s_ctor_" ^ cname
          | Some pty ->
            let p_reg = fresh_reg () in
            if recursive then begin
              let pp = fresh_reg () in
              emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %%x, i32 0, i32 1"
                            pp node_ty);
              emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                            p_reg (llvm_ty_of pty) pp)
            end else
              emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, 1" p_reg mono);
            let ps = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                          ps (ty_tag pty) (llvm_ty_of pty) p_reg);
            (* Build "Ctor payload_str" *)
            let p = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = alloca ptr" p);
            emit_instr (Printf.sprintf
                          "  call i32 (ptr, ptr, ...) @asprintf(ptr %s, ptr @.fmt_show_ctor_payload, ptr @.s_ctor_%s, ptr %s)"
                          p cname ps);
            let r = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" r p);
            r
        in
        let end_label = fresh_label "show_armend_" in
        emit_instr (Printf.sprintf "  br label %%%s" end_label);
        emit_label end_label;
        phi_entries := (s, end_label) :: !phi_entries;
        emit_instr (Printf.sprintf "  br label %%%s" merge_label);
        emit_label next_label
      ) sv;
      (* Final unreachable (typer should catch non-exhaustive) *)
      emit_instr "  call void @abort()";
      emit_instr "  unreachable";
      emit_label merge_label;
      let r = fresh_reg () in
      let phi_parts =
        String.concat ", " (List.rev_map (fun (v, lbl) ->
          Printf.sprintf "[%s, %%%s]" v lbl) !phi_entries)
      in
      emit_instr (Printf.sprintf "  %s = phi ptr %s" r phi_parts);
      r
    | Ast.TyCon (n, _) when Hashtbl.mem Typer.types n ->
      (* Mono variant. *)
      let vs = variant_shape n in
      let recursive = is_recursive_variant_name n in
      let node_ty = "%" ^ n ^ "_node" in
      let tag_reg = fresh_reg () in
      if recursive then begin
        let p = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %%x, i32 0, i32 0"
                      p node_ty);
        emit_instr (Printf.sprintf "  %s = load i32, ptr %s" tag_reg p)
      end else
        emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, 0" tag_reg n);
      let merge_label = fresh_label "show_join_" in
      let phi_entries = ref [] in
      List.iteri (fun ctor_tag (cname, arg_opt) ->
        let arm_label = fresh_label "show_arm_" in
        let next_label = fresh_label "show_next_" in
        let cmp = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, %d" cmp tag_reg ctor_tag);
        emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                      cmp arm_label next_label);
        emit_label arm_label;
        let s =
          match arg_opt with
          | None -> "@.s_ctor_" ^ cname
          | Some pty ->
            let p_reg = fresh_reg () in
            if recursive then begin
              let pp = fresh_reg () in
              emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %%x, i32 0, i32 1"
                            pp node_ty);
              emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                            p_reg (llvm_ty_of pty) pp)
            end else
              emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, 1" p_reg n);
            let ps = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                          ps (ty_tag pty) (llvm_ty_of pty) p_reg);
            let p = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = alloca ptr" p);
            emit_instr (Printf.sprintf
                          "  call i32 (ptr, ptr, ...) @asprintf(ptr %s, ptr @.fmt_show_ctor_payload, ptr @.s_ctor_%s, ptr %s)"
                          p cname ps);
            let r = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" r p);
            r
        in
        let end_label = fresh_label "show_armend_" in
        emit_instr (Printf.sprintf "  br label %%%s" end_label);
        emit_label end_label;
        phi_entries := (s, end_label) :: !phi_entries;
        emit_instr (Printf.sprintf "  br label %%%s" merge_label);
        emit_label next_label
      ) vs;
      emit_instr "  call void @abort()";
      emit_instr "  unreachable";
      emit_label merge_label;
      let r = fresh_reg () in
      let phi_parts =
        String.concat ", " (List.rev_map (fun (v, lbl) ->
          Printf.sprintf "[%s, %%%s]" v lbl) !phi_entries)
      in
      emit_instr (Printf.sprintf "  %s = phi ptr %s" r phi_parts);
      r
    | _ ->
      "@.s_unit"  (* unknown — fallback to "()" *)
  in
  emit_instr (Printf.sprintf "  ret ptr %s" result_reg);
  let body = String.concat "\n" (List.rev !instrs) in
  instrs := saved_instrs;
  reg_counter := saved_reg;
  label_counter := saved_lbl;
  Printf.sprintf "define ptr @show_%s(%s %%x) {\n%s\n}" tag param_ty body

(* Closure value layout: `{ ptr env, ptr fn }`. The fn pointer's
   concrete signature (T2 (ptr, T1)) is encoded via bitcast at call
   sites; LLVM's opaque pointers tolerate that without a typed cast. *)
let emit_closure_typedef ((p : Ast.ty), (r : Ast.ty)) : string =
  ignore p; ignore r;
  let name = closure_struct_name p r in
  Printf.sprintf "%%%s = type { ptr, ptr }" name

(* Phase 15.10: extract (K_tag, V_tag) from a Map[R, K, V] typed expr,
   register in `map_instances`. *)
let map_kv_tags_of (ty_opt : Ast.ty option) (loc : Loc.t) : string * string =
  match ty_opt with
  | Some t ->
    (match Ast.walk t with
     | Ast.TyCon ("Map", [_; k_ty; v_ty]) ->
       let k_ty = Ast.walk k_ty in
       let v_ty = Ast.walk v_ty in
       if ty_is_concrete k_ty && ty_is_concrete v_ty then begin
         let rec is_key_supported = function
           | Ast.TyInt | Ast.TyBool | Ast.TyStr -> true
           | Ast.TyTuple ts -> List.for_all is_key_supported ts
           | Ast.TyCon (rname, _) when Hashtbl.mem Typer.records rname ->
             let info = Hashtbl.find Typer.records rname in
             List.for_all (fun (_, ft) -> is_key_supported (Ast.walk ft))
               info.Typer.r_fields
           | Ast.TyCon (vname, _) when Hashtbl.mem Exhaustive.type_variants vname ->
             let ctors = Hashtbl.find Exhaustive.type_variants vname in
             List.for_all (fun (_, payload) ->
               match payload with
               | None -> true
               | Some pt -> is_key_supported (Ast.walk pt)) ctors
           | _ -> false
         in
         if not (is_key_supported k_ty) then
           raise (Codegen_error (loc,
             "Map key type must be int / bool / str / tuple / record / variant in LLVM codegen (Phase 15.10〜15.16)"));
         let k_tag = ty_tag k_ty in
         let v_tag = ty_tag v_ty in
         let key = k_tag ^ "__" ^ v_tag in
         if not (Hashtbl.mem map_instances key) then
           Hashtbl.add map_instances key (k_ty, v_ty);
         (k_tag, v_tag)
       end else raise (Codegen_error (loc,
         "map_* on Map with unresolved K or V"))
     | _ -> raise (Codegen_error (loc, "map_* expected a Map value")))
  | None -> raise (Codegen_error (loc, "map_*: missing type info"))

(* Phase 15.7: pull the element type out of an `OwnedVec[T]` typed
   expression and register in `owned_vec_instances`. *)
let owned_vec_elem_tag_of (ty_opt : Ast.ty option) (loc : Loc.t) : string =
  match ty_opt with
  | Some t ->
    (match Ast.walk t with
     | Ast.TyCon ("OwnedVec", [et]) ->
       let et = Ast.walk et in
       if ty_is_concrete et then begin
         let tag = ty_tag et in
         if not (Hashtbl.mem owned_vec_instances tag) then
           Hashtbl.add owned_vec_instances tag et;
         tag
       end else raise (Codegen_error (loc,
         "owned_vec_* on OwnedVec with unresolved element type"))
     | _ -> raise (Codegen_error (loc,
         "owned_vec_* expected an OwnedVec value")))
  | None -> raise (Codegen_error (loc, "owned_vec_*: missing type info"))

(* Pull the element type out of a `Vec[R, T]` typed expression and
   return its `ty_tag`. Also registers the element type in
   `vec_instances` so the runtime emitter generates the matching
   struct + helpers. *)
let vec_elem_tag_of (ty_opt : Ast.ty option) (loc : Loc.t) : string =
  match ty_opt with
  | Some t ->
    (match Ast.walk t with
     | Ast.TyCon ("Vec", [_; et]) ->
       let et = Ast.walk et in
       if ty_is_concrete et then begin
         let tag = ty_tag et in
         if not (Hashtbl.mem vec_instances tag) then
           Hashtbl.add vec_instances tag et;
         tag
       end else raise (Codegen_error (loc,
         "vec_* on Vec with unresolved element type"))
     | _ -> raise (Codegen_error (loc, "vec_* expected a Vec value")))
  | None -> raise (Codegen_error (loc, "vec_*: missing type info"))

(* Emit `expr` as a sequence of SSA instructions; return the register (or
   literal) holding the result. Caller is expected to know the expected
   LLVM type from the AST's `.ty` annotation. *)
let rec emit_expr (env : env) (e : Ast.expr) : string =
  match e.Ast.node with
  | Ast.Int_lit n -> string_of_int n
  | Ast.Bool_lit b -> if b then "1" else "0"
  | Ast.Unit_lit -> "0"  (* unit represented as i32 0 *)
  | Ast.Str_lit s ->
    (* String literals lower to a private constant + return its symbol;
       since pointers are opaque, the global is directly usable as a ptr. *)
    fresh_str_global s
  | Ast.Var name ->
    (* Phase 15.3: vec_new / vec_push / vec_get / vec_len は App handler
       で special-case 処理。first-class value 用法のみここで reject。 *)
    if name = "vec_new" || name = "vec_push"
       || name = "vec_get" || name = "vec_len"
       || name = "vec_set" || name = "vec_iter" || name = "vec_fold"
       || name = "vec_map" || name = "vec_filter"
       || name = "vec_to_owned" || name = "owned_vec_to_vec"
       || name = "owned_vec_new" || name = "owned_vec_push"
       || name = "owned_vec_get" || name = "owned_vec_len"
       || name = "strbuf_new" || name = "strbuf_push"
       || name = "strbuf_to_str" || name = "strbuf_len"
       || name = "map_new" || name = "map_set" || name = "map_get"
       || name = "map_has" || name = "map_len" then
      unsupported e.Ast.loc
        (name ^ " as a value (Phase 15.3〜15.10: vec_* / owned_vec_* / strbuf_* / map_* は直接 application のみ対応、first-class value 用法は未対応)");
    if name = "len" || name = "vec_to_list" then
      unsupported e.Ast.loc
        (name ^ " as a value (Phase 15.11/15.12: len / vec_to_list は直接 application のみ対応)");
    (* If a local binding shadows a top-level fn, prefer it. Otherwise,
       if the name resolves to a known top-level fn, materialize the
       closure value `{ ptr null, ptr @<name>_closure_fn }` inline. *)
    (match List.assoc_opt name env with
     | Some v -> v
     | None when Hashtbl.mem toplevel_fn_names name ->
       let arrow =
         match e.Ast.ty with
         | Some t -> Ast.walk t
         | None -> unsupported e.Ast.loc ("fn-as-value missing type: " ^ name)
       in
       let cname =
         match arrow with
         | Ast.TyArrow (p, r) -> closure_struct_name (Ast.walk p) (Ast.walk r)
         | _ -> unsupported e.Ast.loc "fn-as-value on non-arrow type"
       in
       let r0 = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = insertvalue %%%s undef, ptr null, 0" r0 cname);
       let r1 = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, ptr @%s_closure_fn, 1"
                     r1 cname r0 name);
       r1
     | None -> unsupported e.Ast.loc ("unbound variable: " ^ name))
  | Ast.Annot (inner, _) -> emit_expr env inner
  | Ast.Neg inner ->
    let v = emit_expr env inner in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = sub i32 0, %s" r v);
    r
  | Ast.Bin (Ast.Concat, a, b) ->
    let ra = emit_expr env a in
    let rb = emit_expr env b in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_concat(ptr %s, ptr %s)" r ra rb);
    r
  | Ast.Bin (op, a, b) ->
    let ra = emit_expr env a in
    let rb = emit_expr env b in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = %s i32 %s, %s" r (llvm_binop_int op) ra rb);
    r
  | Ast.Cmp (op, a, b) ->
    let ra = emit_expr env a in
    let rb = emit_expr env b in
    let r = fresh_reg () in
    (* Operand type: bool comparisons use i1, otherwise i32. *)
    let opnd_ty =
      match a.Ast.ty with
      | Some t when Ast.walk t = Ast.TyBool -> "i1"
      | _ -> "i32"
    in
    emit_instr (Printf.sprintf "  %s = icmp %s %s %s, %s" r (llvm_cmp_int op) opnd_ty ra rb);
    r
  | Ast.Logic (op, a, b) ->
    (* Short-circuit semantics matter for effects, but the MVP subset has
       no effects, so eager `and`/`or` on i1 is observationally equivalent. *)
    let ra = emit_expr env a in
    let rb = emit_expr env b in
    let r = fresh_reg () in
    let opc = match op with Ast.And -> "and" | Ast.Or -> "or" in
    emit_instr (Printf.sprintf "  %s = %s i1 %s, %s" r opc ra rb);
    r
  | Ast.If (cond, t, f) ->
    let result_ty =
      match e.Ast.ty with
      | Some ty -> llvm_ty_of ty
      | None -> "i32"
    in
    let cv = emit_expr env cond in
    let l_then = fresh_label "then_" in
    let l_else = fresh_label "else_" in
    let l_join = fresh_label "join_" in
    emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s" cv l_then l_else);
    emit_label l_then;
    let tv = emit_expr env t in
    (* The branch's last block might not be l_then if the branch nested
       another If — capture the actual current block via a marker reg. *)
    let l_then_end = fresh_label "then_end_" in
    emit_instr (Printf.sprintf "  br label %%%s" l_then_end);
    emit_label l_then_end;
    emit_instr (Printf.sprintf "  br label %%%s" l_join);
    emit_label l_else;
    let fv = emit_expr env f in
    let l_else_end = fresh_label "else_end_" in
    emit_instr (Printf.sprintf "  br label %%%s" l_else_end);
    emit_label l_else_end;
    emit_instr (Printf.sprintf "  br label %%%s" l_join);
    emit_label l_join;
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = phi %s [%s, %%%s], [%s, %%%s]"
                  r result_ty tv l_then_end fv l_else_end);
    r
  | Ast.Let (pat, value, body) ->
    (match pat.Ast.pnode with
     | Ast.P_var name ->
       let rv = emit_expr env value in
       let saved = !current_var_types in
       let value_ty =
         match value.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
       in
       current_var_types := (name, value_ty) :: saved;
       let r = emit_expr ((name, rv) :: env) body in
       current_var_types := saved;
       r
     | _ ->
       unsupported pat.Ast.ploc "non-P_var let pattern — Phase 5 later slice")
  | Ast.App ({ node = Ast.Var "fst"; _ }, arg) ->
    let av = emit_expr env arg in
    let tname =
      match arg.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyTuple ts -> tuple_struct_name ts
         | _ -> unsupported e.Ast.loc "fst on non-tuple")
      | None -> unsupported e.Ast.loc "fst: missing arg type"
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 0" r tname av);
    r
  | Ast.App ({ node = Ast.Var "snd"; _ }, arg) ->
    let av = emit_expr env arg in
    let tname =
      match arg.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyTuple ts -> tuple_struct_name ts
         | _ -> unsupported e.Ast.loc "snd on non-tuple")
      | None -> unsupported e.Ast.loc "snd: missing arg type"
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 1" r tname av);
    r
  | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "show: missing arg type"
    in
    let tag = ty_tag arg_ty in
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                  r tag (llvm_ty_of arg_ty) av);
    r
  | Ast.App ({ node = Ast.Var "print"; _ }, arg) ->
    let av = emit_expr env arg in
    emit_instr (Printf.sprintf "  call i32 @puts(ptr %s)" av);
    "0"  (* unit / int 0 *)
  | Ast.App ({ node = Ast.Var "mk_logger"; _ }, arg) ->
    (* Phase 16.3 / DEFERRED §1.5: call @__mere_mk_logger to build a
       Logger value (= 3 closure_str_unit fields). *)
    logger_used := true;
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call %%Logger @__mere_mk_logger(ptr %s)" r av);
    r
  | Ast.App ({ node = Ast.Var "mk_metrics"; _ }, arg) ->
    (* Phase 16.3: mk_metrics () — unit arg ignored. *)
    metrics_used := true;
    let _ = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call %%Metrics @__mere_mk_metrics()" r);
    r
  | Ast.App ({ node = Ast.Var "str_len"; _ }, arg) ->
    let av = emit_expr env arg in
    let raw = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i64 @strlen(ptr %s)" raw av);
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = trunc i64 %s to i32" r raw);
    r
  | Ast.App ({ node = Ast.Var "vec_new"; _ }, _arg) ->
    (* Phase 15.3: vec_new () — region と要素型を result type の TyCon
       args から取り出し、`@mere_vec_<tag>_new` runtime を call。
       region binding が __heap なら @__lang_default_region、それ以外は
       %__region_<R> (Region_block で alloca された SSA register)。 *)
    let (region_reg, elem_tag) =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon ("Vec", [Ast.TyRef (_, r, Ast.TyUnit); et]) ->
           let et = Ast.walk et in
           if ty_is_concrete et then begin
             let tag = ty_tag et in
             if not (Hashtbl.mem vec_instances tag) then
               Hashtbl.add vec_instances tag et;
             let region_ptr =
               if r = "__heap" then "@__lang_default_region"
               else match List.assoc_opt r !current_regions with
                 | Some reg -> reg
                 | None ->
                   unsupported e.Ast.loc
                     ("vec_new: region not in scope: " ^ r)
             in
             (region_ptr, tag)
           end else unsupported e.Ast.loc "vec_new: unresolved element type"
         | _ -> unsupported e.Ast.loc "vec_new: missing Vec result type")
      | None -> unsupported e.Ast.loc "vec_new: missing type info"
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @mere_vec_%s_new(ptr %s)"
                  r elem_tag region_reg);
    r
  | Ast.App ({ node = Ast.Var "vec_len"; _ }, arg) ->
    let elem_tag = vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_vec_%s_len(ptr %s)"
                  r elem_tag av);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_push"; _ }, vec_e); _ }, val_e) ->
    let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let elem_ty = Hashtbl.find vec_instances elem_tag in
    let av = emit_expr env vec_e in
    let xv = emit_expr env val_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_vec_%s_push(ptr %s, %s %s)"
                  r elem_tag av (llvm_ty_of elem_ty) xv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_get"; _ }, vec_e); _ }, idx_e) ->
    let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let elem_ty = Hashtbl.find vec_instances elem_tag in
    let av = emit_expr env vec_e in
    let iv = emit_expr env idx_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call %s @mere_vec_%s_get(ptr %s, i32 %s)"
                  r (llvm_ty_of elem_ty) elem_tag av iv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_set"; _ }, vec_e); _ }, idx_e); _ }, val_e) ->
    (* Phase 15.5: vec_set v i x — per-T runtime helper. *)
    let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let elem_ty = Hashtbl.find vec_instances elem_tag in
    let av = emit_expr env vec_e in
    let iv = emit_expr env idx_e in
    let xv = emit_expr env val_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_vec_%s_set(ptr %s, i32 %s, %s %s)"
                  r elem_tag av iv (llvm_ty_of elem_ty) xv);
    r
  | Ast.App ({ node = Ast.Var "strbuf_new"; _ }, _arg) ->
    (* Phase 15.9: strbuf_new () — result type の TyCon arg から region を
       取り出して @mere_strbuf_new に渡す。 *)
    strbuf_used := true;
    let region_name =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon ("StrBuf", [Ast.TyRef (_, r, Ast.TyUnit)]) -> r
         | _ -> "__heap")
      | None -> "__heap"
    in
    let region_reg =
      if region_name = "__heap" then "@__lang_default_region"
      else match List.assoc_opt region_name !current_regions with
        | Some reg -> reg
        | None ->
          unsupported e.Ast.loc
            ("strbuf_new: region not in scope: " ^ region_name)
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @mere_strbuf_new(ptr %s)"
                  r region_reg);
    r
  | Ast.App ({ node = Ast.Var "strbuf_len"; _ }, arg) ->
    strbuf_used := true;
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_strbuf_len(ptr %s)" r av);
    r
  | Ast.App ({ node = Ast.Var "strbuf_to_str"; _ }, arg) ->
    strbuf_used := true;
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @mere_strbuf_to_str(ptr %s)" r av);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "strbuf_push"; _ }, sb_e); _ }, str_e) ->
    strbuf_used := true;
    let sv = emit_expr env sb_e in
    let xv = emit_expr env str_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_strbuf_push(ptr %s, ptr %s)"
                  r sv xv);
    r
  | Ast.App ({ node = Ast.Var "len"; _ }, arg) ->
    (* Phase 15.11: len ad-hoc dispatch — arg.ty に基づいてコンパイル時に
       対応する _len ヘルパに routing。 *)
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported arg.Ast.loc "len: missing arg type info"
    in
    (match arg_ty with
     | Ast.TyCon ("Vec", _) ->
       let t_tag = vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
       let av = emit_expr env arg in
       let r = fresh_reg () in
       emit_instr (Printf.sprintf
                     "  %s = call i32 @mere_vec_%s_len(ptr %s)" r t_tag av);
       r
     | Ast.TyCon ("OwnedVec", _) ->
       let t_tag = owned_vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
       let av = emit_expr env arg in
       let r = fresh_reg () in
       emit_instr (Printf.sprintf
                     "  %s = call i32 @mere_owned_vec_%s_len(ptr %s)" r t_tag av);
       r
     | Ast.TyCon ("StrBuf", _) ->
       strbuf_used := true;
       let av = emit_expr env arg in
       let r = fresh_reg () in
       emit_instr (Printf.sprintf
                     "  %s = call i32 @mere_strbuf_len(ptr %s)" r av);
       r
     | Ast.TyCon ("Map", _) ->
       let (k_tag, v_tag) = map_kv_tags_of arg.Ast.ty arg.Ast.loc in
       let av = emit_expr env arg in
       let r = fresh_reg () in
       emit_instr (Printf.sprintf
                     "  %s = call i32 @mere_map_%s_%s_len(ptr %s)"
                     r k_tag v_tag av);
       r
     | Ast.TyStr ->
       let av = emit_expr env arg in
       let raw = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = call i64 @strlen(ptr %s)" raw av);
       let r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = trunc i64 %s to i32" r raw);
       r
     | Ast.TyTuple ts ->
       (* Static arity. Emit arg for side effects (but tuples have none). *)
       let _ = emit_expr env arg in
       string_of_int (List.length ts)
     | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n
                             && Hashtbl.mem variant_tags "Cons"
                             && Hashtbl.mem variant_tags "Nil" ->
       (* Phase 15.12: `len` on `T list` — call per-T helper
          `@mere_list_<T>_len`. Track in `vec_to_list_instances` so
          emit_program emits the helper. *)
       let args = List.map Ast.walk args in
       (match args with
        | [t_ty] ->
          let t_tag = ty_tag t_ty in
          let list_mono = mono_variant_name n args in
          let key = list_mono ^ "__" ^ t_tag in
          if not (Hashtbl.mem vec_to_list_instances key) then
            Hashtbl.add vec_to_list_instances key (t_ty,
              Ast.TyCon (n, [t_ty]));
          let lv = emit_expr env arg in
          let r = fresh_reg () in
          emit_instr (Printf.sprintf
                        "  %s = call i32 @mere_list_%s_len(ptr %s)"
                        r t_tag lv);
          r
        | _ ->
          unsupported e.Ast.loc
            "len: list variants with non-1-arg parameter unsupported")
     | _ ->
       unsupported e.Ast.loc
         "len: arg type has no codegen-defined length")
  | Ast.App ({ node = Ast.Var "map_new"; _ }, _arg) ->
    (* Phase 15.10: map_new () — region と (K, V) を result type から取り出す。 *)
    let (k_tag, v_tag) = map_kv_tags_of e.Ast.ty e.Ast.loc in
    let region_name =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon ("Map", [Ast.TyRef (_, r, Ast.TyUnit); _; _]) -> r
         | _ -> "__heap")
      | None -> "__heap"
    in
    let region_reg =
      if region_name = "__heap" then "@__lang_default_region"
      else match List.assoc_opt region_name !current_regions with
        | Some reg -> reg
        | None ->
          unsupported e.Ast.loc
            ("map_new: region not in scope: " ^ region_name)
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @mere_map_%s_%s_new(ptr %s)"
                  r k_tag v_tag region_reg);
    r
  | Ast.App ({ node = Ast.Var "map_len"; _ }, arg) ->
    let (k_tag, v_tag) = map_kv_tags_of arg.Ast.ty arg.Ast.loc in
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_map_%s_%s_len(ptr %s)"
                  r k_tag v_tag av);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_get"; _ }, m_e); _ }, k_e) ->
    let (k_tag, v_tag) = map_kv_tags_of m_e.Ast.ty m_e.Ast.loc in
    let (k_ty, v_ty) = Hashtbl.find map_instances (k_tag ^ "__" ^ v_tag) in
    let av = emit_expr env m_e in
    let kv = emit_expr env k_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call %s @mere_map_%s_%s_get(ptr %s, %s %s)"
                  r (llvm_ty_of v_ty) k_tag v_tag av (llvm_ty_of k_ty) kv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_has"; _ }, m_e); _ }, k_e) ->
    let (k_tag, v_tag) = map_kv_tags_of m_e.Ast.ty m_e.Ast.loc in
    let (k_ty, _) = Hashtbl.find map_instances (k_tag ^ "__" ^ v_tag) in
    let av = emit_expr env m_e in
    let kv = emit_expr env k_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i1 @mere_map_%s_%s_has(ptr %s, %s %s)"
                  r k_tag v_tag av (llvm_ty_of k_ty) kv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "map_set"; _ }, m_e); _ }, k_e); _ }, v_e) ->
    (* map_set m k v *)
    let (k_tag, v_tag) = map_kv_tags_of m_e.Ast.ty m_e.Ast.loc in
    let (k_ty, v_ty) = Hashtbl.find map_instances (k_tag ^ "__" ^ v_tag) in
    let av = emit_expr env m_e in
    let kv = emit_expr env k_e in
    let vv = emit_expr env v_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_map_%s_%s_set(ptr %s, %s %s, %s %s)"
                  r k_tag v_tag av (llvm_ty_of k_ty) kv (llvm_ty_of v_ty) vv);
    r
  | Ast.App ({ node = Ast.Var "owned_vec_new"; _ }, _arg) ->
    (* Phase 15.7: owned_vec_new () — heap-allocated OwnedVec[T]。
       要素型 T を e.ty (result Vec の TyCon arg) から取り出す。 *)
    let elem_tag = owned_vec_elem_tag_of e.Ast.ty e.Ast.loc in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @mere_owned_vec_%s_new()" r elem_tag);
    r
  | Ast.App ({ node = Ast.Var "owned_vec_len"; _ }, arg) ->
    let elem_tag = owned_vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_owned_vec_%s_len(ptr %s)"
                  r elem_tag av);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "owned_vec_push"; _ }, vec_e); _ }, val_e) ->
    let elem_tag = owned_vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let elem_ty = Hashtbl.find owned_vec_instances elem_tag in
    let av = emit_expr env vec_e in
    let xv = emit_expr env val_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_owned_vec_%s_push(ptr %s, %s %s)"
                  r elem_tag av (llvm_ty_of elem_ty) xv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "owned_vec_get"; _ }, vec_e); _ }, idx_e) ->
    let elem_tag = owned_vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let elem_ty = Hashtbl.find owned_vec_instances elem_tag in
    let av = emit_expr env vec_e in
    let iv = emit_expr env idx_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call %s @mere_owned_vec_%s_get(ptr %s, i32 %s)"
                  r (llvm_ty_of elem_ty) elem_tag av iv);
    r
  | Ast.App ({ node = Ast.Var "vec_to_list"; _ }, vec_e) ->
    (* Phase 15.12: vec_to_list — per-T helper @mere_vec_to_list_<T>. *)
    let t_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let t_ty = Hashtbl.find vec_instances t_tag in
    let result_ty =
      match e.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "vec_to_list: missing result type"
    in
    let list_ty =
      match result_ty with
      | Ast.TyCon (_, _) -> result_ty
      | _ -> unsupported e.Ast.loc "vec_to_list: result is not a list type"
    in
    let key = t_tag ^ "__listresult" in
    if not (Hashtbl.mem vec_to_list_instances key) then
      Hashtbl.add vec_to_list_instances key (t_ty, list_ty);
    let av = emit_expr env vec_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @mere_vec_to_list_%s(ptr %s)"
                  r t_tag av);
    r
  | Ast.App ({ node = Ast.Var "vec_to_owned"; _ }, vec_e) ->
    (* Phase 15.7: vec_to_owned v — region Vec[R, T] を heap OwnedVec[T] に
       deep copy。 *)
    let t_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let elem_ty = Hashtbl.find vec_instances t_tag in
    if not (Hashtbl.mem owned_vec_instances t_tag) then
      Hashtbl.add owned_vec_instances t_tag elem_ty;
    let av = emit_expr env vec_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @mere_vec_to_owned_%s(ptr %s)"
                  r t_tag av);
    r
  | Ast.App ({ node = Ast.Var "owned_vec_to_vec"; _ }, owned_e) ->
    (* Phase 15.7: owned_vec_to_vec o — heap OwnedVec[T] を region Vec[R, T]
       に deep copy。region は e.ty の TyRef marker から取り出す。 *)
    let t_tag = owned_vec_elem_tag_of owned_e.Ast.ty owned_e.Ast.loc in
    let elem_ty = Hashtbl.find owned_vec_instances t_tag in
    if not (Hashtbl.mem vec_instances t_tag) then
      Hashtbl.add vec_instances t_tag elem_ty;
    let region_name =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon ("Vec", [Ast.TyRef (_, r, Ast.TyUnit); _]) -> r
         | _ -> "__heap")
      | None -> "__heap"
    in
    let region_reg =
      if region_name = "__heap" then "@__lang_default_region"
      else match List.assoc_opt region_name !current_regions with
        | Some reg -> reg
        | None ->
          unsupported e.Ast.loc
            ("owned_vec_to_vec: region not in scope: " ^ region_name)
    in
    let ov = emit_expr env owned_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @mere_owned_vec_to_vec_%s(ptr %s, ptr %s)"
                  r t_tag ov region_reg);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_iter"; _ }, vec_e); _ }, fn_e) ->
    (* Phase 15.5: vec_iter v f — per-T helper.
       Helper signature: i32 @mere_vec_<T>_iter(ptr v, %closure_<T>_unit cl). *)
    let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let elem_ty = Hashtbl.find vec_instances elem_tag in
    if not (Hashtbl.mem vec_iter_instances elem_tag) then
      Hashtbl.add vec_iter_instances elem_tag elem_ty;
    let av = emit_expr env vec_e in
    let cv = emit_expr env fn_e in
    let cname = closure_struct_name elem_ty Ast.TyUnit in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_vec_%s_iter(ptr %s, %%%s %s)"
                  r elem_tag av cname cv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_map"; _ }, vec_e); _ }, fn_e) ->
    (* Phase 15.6: vec_map v f — per-(T, U) helper.
       Returns ptr to fresh mere_vec_<U>, region-preserving. *)
    let t_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let u_tag = vec_elem_tag_of e.Ast.ty e.Ast.loc in
    let t_ty = Hashtbl.find vec_instances t_tag in
    let u_ty = Hashtbl.find vec_instances u_tag in
    let key = t_tag ^ "__" ^ u_tag in
    if not (Hashtbl.mem vec_map_instances key) then
      Hashtbl.add vec_map_instances key (t_ty, u_ty);
    let av = emit_expr env vec_e in
    let cv = emit_expr env fn_e in
    let cname = closure_struct_name t_ty u_ty in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @mere_vec_%s_map_%s(ptr %s, %%%s %s)"
                  r t_tag u_tag av cname cv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_filter"; _ }, vec_e); _ }, fn_e) ->
    (* Phase 15.6: vec_filter v f — per-T helper. *)
    let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let elem_ty = Hashtbl.find vec_instances elem_tag in
    if not (Hashtbl.mem vec_filter_instances elem_tag) then
      Hashtbl.add vec_filter_instances elem_tag elem_ty;
    let av = emit_expr env vec_e in
    let cv = emit_expr env fn_e in
    let cname = closure_struct_name elem_ty Ast.TyBool in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @mere_vec_%s_filter(ptr %s, %%%s %s)"
                  r elem_tag av cname cv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_fold"; _ }, vec_e); _ }, acc_e); _ }, fn_e) ->
    (* Phase 15.5: vec_fold v acc f — per-(T, U) helper.
       Helper signature:
         <U> @mere_vec_<T>_fold_<U>(ptr v, <U> acc, %closure_<U>_closure_<T>_<U> outer) *)
    let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let elem_ty = Hashtbl.find vec_instances elem_tag in
    let acc_ty =
      match acc_e.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported acc_e.Ast.loc "vec_fold: missing acc type"
    in
    let acc_tag = ty_tag acc_ty in
    let key = elem_tag ^ "__" ^ acc_tag in
    if not (Hashtbl.mem vec_fold_instances key) then
      Hashtbl.add vec_fold_instances key (elem_ty, acc_ty);
    let av = emit_expr env vec_e in
    let initv = emit_expr env acc_e in
    let cv = emit_expr env fn_e in
    let inner_cl_name = closure_struct_name elem_ty acc_ty in
    let outer_cl_name = closure_struct_name acc_ty
      (Ast.TyArrow (elem_ty, acc_ty)) in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call %s @mere_vec_%s_fold_%s(ptr %s, %s %s, %%%s %s)"
                  r (llvm_ty_of acc_ty) elem_tag acc_tag
                  av (llvm_ty_of acc_ty) initv outer_cl_name cv);
    ignore inner_cl_name;
    r
  | Ast.App ({ node = Ast.Var name; _ }, arg)
    when Hashtbl.mem toplevel_fn_names name ->
    let av = emit_expr env arg in
    let ret_ty =
      match e.Ast.ty with
      | Some t -> llvm_ty_of t
      | None -> "i32"
    in
    let arg_ty =
      (* Prefer current_var_types for Var args (in case the AST .ty is
         still polymorphic from let-rec generalization). *)
      let from_var_types =
        match arg.Ast.node with
        | Ast.Var n ->
          (match List.assoc_opt n !current_var_types with
           | Some t when ty_is_concrete t -> Some (llvm_ty_of (Ast.walk t))
           | _ -> None)
        | _ -> None
      in
      match from_var_types with
      | Some s -> s
      | None ->
        (match arg.Ast.ty with
         | Some t -> llvm_ty_of t
         | None -> "i32")
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call %s @%s(%s %s)" r ret_ty name arg_ty av);
    r
  | Ast.App (f, arg) ->
    (* Closure dispatch via the closure value's fn pointer. *)
    let arrow_ty =
      (* Prefer current_var_types if the head is a Var with a known
         concrete binding — fn body may carry polymorphic .ty. *)
      let from_var_types =
        match f.Ast.node with
        | Ast.Var n ->
          (match List.assoc_opt n !current_var_types with
           | Some t when ty_is_concrete t -> Some (Ast.walk t)
           | _ -> None)
        | _ -> None
      in
      match from_var_types with
      | Some t -> t
      | None ->
        (match f.Ast.ty with
         | Some t -> Ast.walk t
         | None -> unsupported f.Ast.loc "closure call: missing fn type")
    in
    let cname =
      match arrow_ty with
      | Ast.TyArrow (p, r) -> closure_struct_name (Ast.walk p) (Ast.walk r)
      | _ -> unsupported f.Ast.loc "closure call on non-arrow"
    in
    let ret_ty =
      match e.Ast.ty with
      | Some t -> llvm_ty_of t
      | None -> "i32"
    in
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> llvm_ty_of t
      | None -> "i32"
    in
    let cv = emit_expr env f in
    let av = emit_expr env arg in
    let env_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 0" env_reg cname cv);
    let fn_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 1" fn_reg cname cv);
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call %s %s(ptr %s, %s %s)"
                  r ret_ty fn_reg env_reg arg_ty av);
    r
  | Ast.Tuple elems ->
    let tname =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyTuple ts -> tuple_struct_name ts
         | _ -> unsupported e.Ast.loc "tuple literal has non-tuple type")
      | None -> unsupported e.Ast.loc "tuple literal: missing inferred type"
    in
    let elem_tys =
      match e.Ast.ty with
      | Some t -> (match Ast.walk t with Ast.TyTuple ts -> ts | _ -> [])
      | None -> []
    in
    (* Build the struct value via a chain of insertvalue, starting from
       `undef`. Each insertvalue produces a new SSA value of the same
       struct type. *)
    let rec build prev idx = function
      | [] -> prev
      | (elem, ty) :: rest ->
        let ev = emit_expr env elem in
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, %d"
                      r tname prev (llvm_ty_of ty) ev idx);
        build r (idx + 1) rest
    in
    build "undef" 0 (List.combine elems elem_tys)
  | Ast.Record_lit (name, fields) when Hashtbl.mem Typer.views name ->
    (* View literal: allocate the struct in the view's region (encoded as
       a [R] tyref in the inferred type), insertvalue chain to build the
       record value, store into the allocated buffer, return ptr. *)
    let region =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon (_, [Ast.TyRef (_, r, _)]) -> r
         | _ -> unsupported e.Ast.loc
                  "view literal missing region marker in inferred type")
      | None -> unsupported e.Ast.loc "view literal: missing type info"
    in
    let region_p =
      match List.assoc_opt region !current_regions with
      | Some r -> r
      | None -> unsupported e.Ast.loc
                  ("view literal: region not in scope: " ^ region)
    in
    let info = Hashtbl.find Typer.views name in
    let rec build prev idx = function
      | [] -> prev
      | (fname, fty) :: rest ->
        let ex =
          match List.assoc_opt fname fields with
          | Some e -> e
          | None ->
            unsupported e.Ast.loc
              (Printf.sprintf "view literal missing field `%s`" fname)
        in
        let ev = emit_expr env ex in
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, %d"
                      r name prev (llvm_ty_of fty) ev idx);
        build r (idx + 1) rest
    in
    let v = build "undef" 0 info.Typer.v_fields in
    let size_p = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = getelementptr %%%s, ptr null, i32 1"
                  size_p name);
    let size = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" size size_p);
    let p = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @__lang_region_alloc(ptr %s, i64 %s)"
                  p region_p size);
    emit_instr (Printf.sprintf "  store %%%s %s, ptr %s" name v p);
    p
  | Ast.Record_lit (name, fields) ->
    let () = ignore name in
    begin
      let info =
        match Hashtbl.find_opt Typer.records name with
        | Some i -> i
        | None ->
          unsupported e.Ast.loc ("unknown record type: " ^ name)
      in
      (* Mono vs poly: for polymorphic records, pick the mono instance
         from the Record_lit's inferred type and substitute fields. *)
      let struct_name, decl_fields =
        if info.Typer.r_params <> [] then
          let args =
            match e.Ast.ty with
            | Some t ->
              (match Ast.walk t with
               | Ast.TyCon (n, ts) when n = name -> List.map Ast.walk ts
               | _ -> unsupported e.Ast.loc
                        "Record_lit: type info missing concrete args")
            | None -> unsupported e.Ast.loc "Record_lit: missing inferred type"
          in
          let mapping = List.combine info.Typer.r_params args in
          let sf =
            List.map (fun (fn, ft) -> (fn, subst_params mapping ft))
              info.Typer.r_fields
          in
          (mono_record_name name args, sf)
        else
          (name, info.Typer.r_fields)
      in
      let rec build prev idx = function
        | [] -> prev
        | (fname, fty) :: rest ->
          let ex =
            match List.assoc_opt fname fields with
            | Some e -> e
            | None ->
              unsupported e.Ast.loc
                (Printf.sprintf "missing field `%s` in record literal" fname)
          in
          let ev = emit_expr env ex in
          let r = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, %d"
                        r struct_name prev (llvm_ty_of fty) ev idx);
          build r (idx + 1) rest
      in
      build "undef" 0 decl_fields
    end
  | Ast.Field_get (inner, fname) ->
    let iv = emit_expr env inner in
    let inner_ty =
      match inner.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "field access: missing inner type"
    in
    if is_view_type inner_ty then begin
      (* View value is a ptr to a region-allocated struct. GEP+load. *)
      let name =
        match inner_ty with
        | Ast.TyCon (n, _) -> n
        | _ -> assert false
      in
      let info = Hashtbl.find Typer.views name in
      let fields = info.Typer.v_fields in
      let rec find_idx i = function
        | [] ->
          unsupported e.Ast.loc
            (Printf.sprintf "view `%s` has no field `%s`" name fname)
        | (n, t) :: _ when n = fname -> (i, t)
        | _ :: rest -> find_idx (i + 1) rest
      in
      let (idx, ft) = find_idx 0 fields in
      let p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %%%s, ptr %s, i32 0, i32 %d"
                    p name iv idx);
      let r = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                    r (llvm_ty_of ft) p);
      r
    end
    else begin
      let struct_name, fields =
        match inner_ty with
        | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
          let args = List.map Ast.walk args in
          let (params, fs) = Hashtbl.find polymorphic_records n in
          let mapping = List.combine params args in
          let sf = List.map (fun (fn, ft) -> (fn, subst_params mapping ft)) fs in
          (mono_record_name n args, sf)
        | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
          (n, record_fields n)
        | _ -> unsupported e.Ast.loc "field access on non-record"
      in
      let idx =
        let rec find i = function
          | [] ->
            unsupported e.Ast.loc
              (Printf.sprintf "record `%s` has no field `%s`" struct_name fname)
          | (n, _) :: _ when n = fname -> i
          | _ :: rest -> find (i + 1) rest
        in find 0 fields
      in
      let r = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, %d"
                    r struct_name iv idx);
      r
    end
  | Ast.Record_update (base, updates) ->
    let bv = emit_expr env base in
    let struct_name, fields =
      match base.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
           let args = List.map Ast.walk args in
           let (params, fs) = Hashtbl.find polymorphic_records n in
           let mapping = List.combine params args in
           let sf = List.map (fun (fn, ft) -> (fn, subst_params mapping ft)) fs in
           (mono_record_name n args, sf)
         | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
           (n, record_fields n)
         | _ -> unsupported e.Ast.loc "record update on non-record")
      | None -> unsupported e.Ast.loc "record update: missing base type"
    in
    let field_index_local fname =
      let rec find i = function
        | [] ->
          unsupported e.Ast.loc
            (Printf.sprintf "record `%s` has no field `%s`" struct_name fname)
        | (n, _) :: _ when n = fname -> i
        | _ :: rest -> find (i + 1) rest
      in find 0 fields
    in
    let rec apply prev = function
      | [] -> prev
      | (fname, ex) :: rest ->
        let fty =
          try List.assoc fname fields
          with Not_found ->
            unsupported e.Ast.loc
              (Printf.sprintf "record `%s` has no field `%s`" struct_name fname)
        in
        let ev = emit_expr env ex in
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, %d"
                      r struct_name prev (llvm_ty_of fty) ev
                      (field_index_local fname));
        apply r rest
    in
    apply bv updates
  | Ast.Constr (cname, arg_opt) ->
    let info =
      match Hashtbl.find_opt Typer.constructors cname with
      | Some i -> i
      | None -> unsupported e.Ast.loc ("unknown constructor: " ^ cname)
    in
    let type_name = info.Typer.type_name in
    if not (Hashtbl.mem Typer.types type_name) then
      unsupported e.Ast.loc ("constructor's type not registered: " ^ type_name);
    let tag =
      match Hashtbl.find_opt variant_tags cname with
      | Some t -> t
      | None -> unsupported e.Ast.loc ("constructor without tag: " ^ cname)
    in
    let struct_name, payload_ty =
      if Hashtbl.mem polymorphic_variants type_name then begin
        let args =
          match e.Ast.ty with
          | Some t ->
            (match Ast.walk t with
             | Ast.TyCon (n, ts) when n = type_name -> List.map Ast.walk ts
             | _ -> unsupported e.Ast.loc
                      "Constr: type info missing concrete args")
          | None -> unsupported e.Ast.loc "Constr: missing inferred type"
        in
        let mono = mono_variant_name type_name args in
        let (params, variants) = Hashtbl.find polymorphic_variants type_name in
        let sv = subst_variants params args variants in
        (mono, variant_payload_ty_of sv)
      end else
        (type_name, variant_payload_ty type_name)
    in
    if is_recursive_variant_name struct_name then begin
      (* Recursive variant: allocate a node in the default region, write
         tag (+ optional payload) via getelementptr + store, return ptr. *)
      let node_ty = "%" ^ struct_name ^ "_node" in
      let size_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr null, i32 1"
                    size_p node_ty);
      let size = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" size size_p);
      let p = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %s)"
                    p size);
      let tag_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 0"
                    tag_p node_ty p);
      emit_instr (Printf.sprintf "  store i32 %d, ptr %s" tag tag_p);
      (match arg_opt, payload_ty with
       | None, _ -> ()
       | Some arg, Some pty ->
         let av = emit_expr env arg in
         let pl_p = fresh_reg () in
         emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 1"
                       pl_p node_ty p);
         emit_instr (Printf.sprintf "  store %s %s, ptr %s"
                       (llvm_ty_of pty) av pl_p)
       | Some _, None ->
         unsupported e.Ast.loc
           (Printf.sprintf
              "constructor `%s` has payload but variant lowered as nullary-only"
              cname));
      p
    end
    else begin
      let r0 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s undef, i32 %d, 0"
                    r0 struct_name tag);
      match arg_opt, payload_ty with
      | None, _ -> r0
      | Some arg, Some pty ->
        let av = emit_expr env arg in
        let r1 = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, 1"
                      r1 struct_name r0 (llvm_ty_of pty) av);
        r1
      | Some _, None ->
        unsupported e.Ast.loc
          (Printf.sprintf
             "constructor `%s` has payload but variant lowered as nullary-only"
             cname)
    end
  | Ast.Match (scrut, arms) ->
    let scrut_ty =
      let from_var_types =
        match scrut.Ast.node with
        | Ast.Var n ->
          (match List.assoc_opt n !current_var_types with
           | Some t when ty_is_concrete t -> Some (Ast.walk t)
           | _ -> None)
        | _ -> None
      in
      match from_var_types with
      | Some t -> t
      | None ->
        (match scrut.Ast.ty with
         | Some t -> Ast.walk t
         | None -> unsupported e.Ast.loc "match: missing scrutinee type")
    in
    let scrut_v = emit_expr env scrut in
    let result_ty =
      match e.Ast.ty with
      | Some t -> llvm_ty_of t
      | None -> "i32"
    in
    let merge_label = fresh_label "match_join_" in
    let phi_entries = ref [] in
    (* Combine two i1 booleans with `and i1`. *)
    let and_cond a b =
      if a = "1" then b
      else if b = "1" then a
      else begin
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = and i1 %s, %s" r a b);
        r
      end
    in
    (* Fully recursive pattern compiler. Tests run via icmp / strcmp /
       extractvalue / load and AND together. Bindings accumulate as
       (name, register). For nested constructors / tuples / records,
       sub-patterns recurse on extracted sub-values. *)
    let rec compile_pat (pat : Ast.pattern) (v_reg : string) (v_ty : Ast.ty)
      : string * (string * string) list * (string * Ast.ty) list =
      match pat.Ast.pnode with
      | Ast.P_wild -> ("1", [], [])
      | Ast.P_var n -> ("1", [(n, v_reg)], [(n, v_ty)])
      | Ast.P_unit -> ("1", [], [])
      | Ast.P_int n ->
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, %d" r v_reg n);
        (r, [], [])
      | Ast.P_bool b ->
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i1 %s, %d" r v_reg (if b then 1 else 0));
        (r, [], [])
      | Ast.P_str s ->
        let label = fresh_str_global s in
        let cmp = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = call i32 @strcmp(ptr %s, ptr %s)" cmp v_reg label);
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, 0" r cmp);
        (r, [], [])
      | Ast.P_as (inner, n) ->
        let (c, bs, tys) = compile_pat inner v_reg v_ty in
        (c, (n, v_reg) :: bs, (n, v_ty) :: tys)
      | Ast.P_tuple pats ->
        let elem_tys =
          match Ast.walk v_ty with Ast.TyTuple ts -> ts | _ ->
            unsupported pat.Ast.ploc "P_tuple on non-tuple"
        in
        let tname = tuple_struct_name elem_tys in
        let rec go i acc_cond acc_bs acc_tys = function
          | [] -> (acc_cond, List.rev acc_bs, List.rev acc_tys)
          | p :: rest ->
            let ety = List.nth elem_tys i in
            let er = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, %d"
                          er tname v_reg i);
            let (c, bs, tys) = compile_pat p er ety in
            go (i + 1) (and_cond acc_cond c)
              (List.rev_append bs acc_bs) (List.rev_append tys acc_tys) rest
        in
        go 0 "1" [] [] pats
      | Ast.P_record (_, sub_fields) ->
        let struct_name, decl_fields =
          match Ast.walk v_ty with
          | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
            let args = List.map Ast.walk args in
            let (params, fs) = Hashtbl.find polymorphic_records n in
            let mapping = List.combine params args in
            let sf = List.map (fun (fn, ft) -> (fn, subst_params mapping ft)) fs in
            (mono_record_name n args, sf)
          | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
            (n, record_fields n)
          | _ -> unsupported pat.Ast.ploc "P_record on non-record"
        in
        let idx_of fname =
          let rec find i = function
            | [] -> -1
            | (n, _) :: _ when n = fname -> i
            | _ :: rest -> find (i + 1) rest
          in find 0 decl_fields
        in
        let ty_of fname = List.assoc fname decl_fields in
        let rec go acc_cond acc_bs acc_tys = function
          | [] -> (acc_cond, List.rev acc_bs, List.rev acc_tys)
          | (fname, sub_p) :: rest ->
            let i = idx_of fname in
            let ft = ty_of fname in
            let fr = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, %d"
                          fr struct_name v_reg i);
            let (c, bs, tys) = compile_pat sub_p fr ft in
            go (and_cond acc_cond c)
              (List.rev_append bs acc_bs) (List.rev_append tys acc_tys) rest
        in
        go "1" [] [] sub_fields
      | Ast.P_constr (cname, sub) ->
        let info =
          match Hashtbl.find_opt Typer.constructors cname with
          | Some i -> i
          | None -> unsupported pat.Ast.ploc ("unknown ctor: " ^ cname)
        in
        let type_name = info.Typer.type_name in
        let struct_name, payload_ty =
          match Ast.walk v_ty with
          | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
            let args = List.map Ast.walk args in
            let mono = mono_variant_name n args in
            let (params, variants) = Hashtbl.find polymorphic_variants n in
            let sv = subst_variants params args variants in
            (mono, variant_payload_ty_of sv)
          | _ -> (type_name, variant_payload_ty type_name)
        in
        let recursive = is_recursive_variant_name struct_name in
        let node_ty = "%" ^ struct_name ^ "_node" in
        let tag =
          match Hashtbl.find_opt variant_tags cname with
          | Some t -> t
          | None -> unsupported pat.Ast.ploc ("ctor without tag: " ^ cname)
        in
        let tag_reg = fresh_reg () in
        if recursive then begin
          let p = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 0"
                        p node_ty v_reg);
          emit_instr (Printf.sprintf "  %s = load i32, ptr %s" tag_reg p)
        end else
          emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 0"
                        tag_reg struct_name v_reg);
        let tag_cond = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, %d" tag_cond tag_reg tag);
        (match sub, payload_ty with
         | None, _ -> (tag_cond, [], [])
         | Some sub_pat, Some pty ->
           let payload_reg = fresh_reg () in
           if recursive then begin
             let p = fresh_reg () in
             emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 1"
                           p node_ty v_reg);
             emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                           payload_reg (llvm_ty_of pty) p)
           end else
             emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 1"
                           payload_reg struct_name v_reg);
           let (c, bs, tys) = compile_pat sub_pat payload_reg pty in
           (and_cond tag_cond c, bs, tys)
         | Some _, None ->
           unsupported pat.Ast.ploc
             "pattern has payload but variant has no payload type")
      | Ast.P_or _ ->
        unsupported pat.Ast.ploc "P_or should have been flattened"
    in
    (* Pre-flatten or-patterns into multiple arms. The typer guarantees
       both branches bind the same names with compatible types. *)
    let rec expand_or (pat, guard, body) =
      match pat.Ast.pnode with
      | Ast.P_or (a, b) ->
        expand_or (a, guard, body) @ expand_or (b, guard, body)
      | _ -> [(pat, guard, body)]
    in
    let arms = List.concat_map expand_or arms in
    let rec emit_arms = function
      | [] ->
        emit_instr "  call void @abort()";
        emit_instr "  unreachable"
      | (pat, guard, body) :: rest ->
        let (cond, bindings, var_tys) = compile_pat pat scrut_v scrut_ty in
        let arm_label = fresh_label "arm_" in
        let next_label = fresh_label "next_" in
        emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                      cond arm_label next_label);
        emit_label arm_label;
        let env' = bindings @ env in
        let saved_vt = !current_var_types in
        current_var_types := var_tys @ saved_vt;
        (* Guard: evaluate within the arm's bindings scope. If false,
           branch to next_label (= same as failing the test). *)
        (match guard with
         | None -> ()
         | Some g ->
           let gv = emit_expr env' g in
           let pass_label = fresh_label "guard_pass_" in
           emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                         gv pass_label next_label);
           emit_label pass_label);
        let v = emit_expr env' body in
        current_var_types := saved_vt;
        let end_label = fresh_label "arm_end_" in
        emit_instr (Printf.sprintf "  br label %%%s" end_label);
        emit_label end_label;
        phi_entries := (v, end_label) :: !phi_entries;
        emit_instr (Printf.sprintf "  br label %%%s" merge_label);
        emit_label next_label;
        emit_arms rest
    in
    emit_arms arms;
    emit_label merge_label;
    let r = fresh_reg () in
    let phi_parts =
      String.concat ", " (List.rev_map (fun (v, lbl) ->
        Printf.sprintf "[%s, %%%s]" v lbl) !phi_entries)
    in
    emit_instr (Printf.sprintf "  %s = phi %s %s" r result_ty phi_parts);
    r
  | Ast.Fun (param, _, fn_body) ->
    (* Anonymous Fun in expression position → emit a closure value:
       env-struct alloc (default region) + adapter (deferred) + closure
       value built via insertvalue. *)
    let arrow_ty =
      let from_node =
        match e.Ast.ty with Some t -> Some (Ast.walk t) | None -> None
      in
      let from_ctx = !current_expected_ty in
      match from_node, from_ctx with
      | Some t, _ when ty_is_concrete t -> t
      | _, Some t when ty_is_concrete t -> t
      | Some t, _ -> t  (* best-effort; will likely raise in ty_tag *)
      | None, _ ->
        unsupported e.Ast.loc "anonymous fn missing inferred type (no context)"
    in
    let param_ty, return_ty =
      match arrow_ty with
      | Ast.TyArrow (p, r) -> (Ast.walk p, Ast.walk r)
      | _ -> unsupported e.Ast.loc "anonymous fn has non-arrow type"
    in
    let raw_fvs = free_vars fn_body [param] in
    let fvs =
      List.filter (fun n -> List.mem_assoc n !current_var_types) raw_fvs
    in
    let captures =
      List.map (fun fv ->
        let cty =
          match List.assoc_opt fv !current_var_types with
          | Some t when ty_is_concrete t -> Ast.walk t
          | _ ->
            unsupported e.Ast.loc
              (Printf.sprintf "capture `%s` has non-concrete type" fv)
        in
        (fv, cty)) fvs
    in
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
    (* Env struct typedef (even when empty — only emit if captures > 0). *)
    if captures <> [] then begin
      let fields =
        String.concat ", " (List.map (fun (_, t) -> llvm_ty_of t) captures)
      in
      anon_env_typedefs :=
        Printf.sprintf "%%%s = type { %s }" env_name fields
        :: !anon_env_typedefs
    end;
    let cstruct = closure_struct_name param_ty return_ty in
    if captures = [] then begin
      let r0 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s undef, ptr null, 0" r0 cstruct);
      let r1 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, ptr @%s, 1"
                    r1 cstruct r0 adapter_name);
      r1
    end else begin
      let size_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %%%s, ptr null, i32 1"
                    size_p env_name);
      let size = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" size size_p);
      let env_p = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %s)"
                    env_p size);
      List.iteri (fun i (cname, cty) ->
        let cv =
          match List.assoc_opt cname env with
          | Some v -> v
          | None -> unsupported e.Ast.loc ("capture not in scope: " ^ cname)
        in
        let p = fresh_reg () in
        emit_instr (Printf.sprintf
                      "  %s = getelementptr %%%s, ptr %s, i32 0, i32 %d"
                      p env_name env_p i);
        emit_instr (Printf.sprintf "  store %s %s, ptr %s"
                      (llvm_ty_of cty) cv p)
      ) captures;
      let r0 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s undef, ptr %s, 0"
                    r0 cstruct env_p);
      let r1 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, ptr @%s, 1"
                    r1 cstruct r0 adapter_name);
      r1
    end
  | Ast.Region_block (name, body) ->
    (* Allocate a fresh region locally, run body within it, free at exit.
       The region's SSA ptr is pushed onto current_regions so Ref / view
       constructions inside body find it by name. *)
    let region_p = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = alloca %%__lang_region" region_p);
    emit_instr (Printf.sprintf
                  "  call void @__lang_region_init(ptr %s, i64 1048576)" region_p);
    let saved = !current_regions in
    current_regions := (name, region_p) :: saved;
    let v = emit_expr env body in
    current_regions := saved;
    emit_instr (Printf.sprintf "  call void @__lang_region_free(ptr %s)" region_p);
    v
  | Ast.Ref (_mode, region, inner) ->
    (* `&R v` — region-allocate a copy of `v` and return ptr. *)
    let v = emit_expr env inner in
    let v_ty =
      match inner.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "&R: missing inner type"
    in
    let region_p =
      match List.assoc_opt region !current_regions with
      | Some r -> r
      | None -> unsupported e.Ast.loc ("&R: region not in scope: " ^ region)
    in
    let size_p = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr null, i32 1"
                  size_p (llvm_ty_of v_ty));
    let size = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" size size_p);
    let p = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @__lang_region_alloc(ptr %s, i64 %s)"
                  p region_p size);
    emit_instr (Printf.sprintf "  store %s %s, ptr %s" (llvm_ty_of v_ty) v p);
    p
  | Ast.With (name, value, body) ->
    (* `with c = v in body` — bind v, run body, then auto-invoke
       c.close(unit) if v's record type has a `close: unit -> unit` field.
       Body's resulting value is returned. *)
    let vv = emit_expr env value in
    let value_ty =
      match value.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "with: missing value type"
    in
    (* Discover record type name + struct + close field index (if any). *)
    let close_info =
      match value_ty with
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
        let fields = record_fields n in
        let rec find_close i = function
          | [] -> None
          | (fname, fty) :: _ when fname = "close" -> Some (i, fty, n)
          | _ :: rest -> find_close (i + 1) rest
        in
        find_close 0 fields
      | _ -> None
    in
    let saved_vt = !current_var_types in
    current_var_types := (name, value_ty) :: saved_vt;
    let body_v = emit_expr ((name, vv) :: env) body in
    current_var_types := saved_vt;
    (* Auto-invoke close (after body is evaluated). *)
    (match close_info with
     | None -> ()
     | Some (idx, fty, struct_name) ->
       let close_cl = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, %d"
                     close_cl struct_name vv idx);
       let cname = llvm_ty_of fty in
       let env_r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = extractvalue %s %s, 0"
                     env_r cname close_cl);
       let fn_r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = extractvalue %s %s, 1"
                     fn_r cname close_cl);
       let _ = fresh_reg () in
       emit_instr (Printf.sprintf "  call i32 %s(ptr %s, i32 0)" fn_r env_r));
    (* Phase 15.13: scope-bound Drop for OwnedVec. Free the data buffer
       and zero out the struct's data pointer so the registry's
       free_all sweep at main-end won't double-free (free(NULL) is a
       C-standard no-op). The struct itself is freed by free_all. *)
    (match value_ty with
     | Ast.TyCon ("OwnedVec", _) ->
       (* GEP to struct field 0 (data pointer), load it, free it,
          then store NULL into the field. *)
       let dp = fresh_reg () in
       (* mere_owned_vec_<T> has { ptr, i32, i32 }; field 0 is data. *)
       (* We don't have the struct name handy here; use the generic
          field-0 layout via a generic ptr GEP. All mere_owned_vec_<T>
          share the same prefix layout. *)
       emit_instr (Printf.sprintf
                     "  %s = getelementptr {ptr, i32, i32}, ptr %s, i32 0, i32 0"
                     dp vv);
       let data = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" data dp);
       emit_instr (Printf.sprintf "  call void @free(ptr %s)" data);
       emit_instr (Printf.sprintf "  store ptr null, ptr %s" dp)
     | _ -> ());
    body_v
  | Ast.Float_lit _
  | Ast.Let_rec _ ->
    unsupported e.Ast.loc "node kind not yet in Phase 5 MVP"

(* Emit the body of an anonymous-Fun adapter: gep + load each capture
   from `%env_self`, then evaluate the original Fun body with the
   captures bound. Returns the full `define ...` string. *)
let emit_anon_adapter (ce : closure_emission) : string =
  let saved_instrs = !instrs in
  let saved_reg = !reg_counter and saved_lbl = !label_counter in
  let saved_vt = !current_var_types in
  let saved_exp = !current_expected_ty in
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
  current_expected_ty := Some ce.ce_return_ty;
  emit_instr "entry:";
  (* Build env: load each capture from %env_self into a fresh register
     so the body can reference it by name. *)
  let cap_env =
    List.mapi (fun i (cname, cty) ->
      if ce.ce_env_fields = [] then assert false;
      let p = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = getelementptr %%%s, ptr %%env_self, i32 0, i32 %d"
                    p ce.ce_env_name i);
      let v = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                    v (llvm_ty_of cty) p);
      (cname, v)) ce.ce_env_fields
  in
  let env = (ce.ce_param, "%" ^ ce.ce_param) :: cap_env in
  current_var_types :=
    (ce.ce_param, ce.ce_param_ty) ::
    List.map (fun (n, t) -> (n, t)) ce.ce_env_fields;
  let rv = emit_expr env ce.ce_body in
  emit_instr (Printf.sprintf "  ret %s %s" (llvm_ty_of ce.ce_return_ty) rv);
  let body = String.concat "\n" (List.rev !instrs) in
  instrs := saved_instrs;
  reg_counter := saved_reg;
  label_counter := saved_lbl;
  current_var_types := saved_vt;
  current_expected_ty := saved_exp;
  Printf.sprintf
    "define %s @%s(ptr %%env_self, %s %%%s) {\n%s\n}"
    (llvm_ty_of ce.ce_return_ty) ce.ce_adapter_name
    (llvm_ty_of ce.ce_param_ty) ce.ce_param body

(* Env-ignoring adapter so the top-level fn `f` can be used as a closure
   value: `T2 @f_closure_fn(ptr unused, T1 %x) { ret T2 @f(T1 %x); }`. *)
let emit_closure_adapter (f : fn_decl) : string =
  let pt = llvm_ty_of f.param_ty in
  let rt = llvm_ty_of f.return_ty in
  let inner_call =
    Printf.sprintf "  %%r = call %s @%s(%s %%x)" rt f.name pt
  in
  Printf.sprintf
    "define %s @%s_closure_fn(ptr %%env_unused, %s %%x) {\nentry:\n%s\n  ret %s %%r\n}"
    rt f.name pt inner_call rt

(* Emit a top-level fn definition. Each fn gets fresh register/label
   counters so the SSA names don't collide across functions. *)
let emit_fn_def (f : fn_decl) : string =
  reg_counter := 0;
  label_counter := 0;
  let saved = !instrs in
  let saved_types = !current_var_types in
  let saved_exp = !current_expected_ty in
  instrs := [];
  current_var_types := [(f.param, f.param_ty)];
  current_expected_ty := Some f.return_ty;
  emit_instr "entry:";
  let env = [(f.param, "%" ^ f.param)] in
  let rv = emit_expr env f.body in
  emit_instr (Printf.sprintf "  ret %s %s" (llvm_ty_of f.return_ty) rv);
  let body = String.concat "\n" (List.rev !instrs) in
  instrs := saved;
  current_var_types := saved_types;
  current_expected_ty := saved_exp;
  Printf.sprintf "define %s @%s(%s %%%s) {\n%s\n}"
    (llvm_ty_of f.return_ty) f.name (llvm_ty_of f.param_ty) f.param body

(* Convert the program's main result type to (LLVM type, printf format).
   `unit` skips printing entirely. `str` uses %s. *)
let main_format_of (t : Ast.ty) : (string * string) option =
  match Ast.walk t with
  | Ast.TyInt -> Some ("i32", "%d")
  | Ast.TyBool -> Some ("i32", "%d")  (* zext from i1 *)
  | Ast.TyStr -> Some ("ptr", "%s")
  | Ast.TyUnit -> None
  | _ -> Some ("i32", "%d")

(* Runtime helpers emitted as LLVM IR. Mirrors codegen_c's runtime
   helpers but inlined into the .ll module so the file is self-contained. *)
let runtime_decls =
  String.concat "\n"
    [ "declare ptr @malloc(i64)";
      "declare ptr @realloc(ptr, i64)";
      "declare void @free(ptr)";
      "declare i64 @strlen(ptr)";
      "declare i32 @strcmp(ptr, ptr)";
      "declare ptr @memcpy(ptr, ptr, i64)";
      "declare i32 @puts(ptr)";
      "declare i32 @printf(ptr, ...)";
      "declare i32 @asprintf(ptr, ptr, ...)";
      "declare void @abort()" ]

(* Region runtime — mirrors codegen_c's region_runtime_helpers but
   expressed in LLVM IR. Uses an 8-byte aligned bump-pointer allocator.
   The default region is a file-scope global initialized in @main. *)
let region_runtime_helpers =
  String.concat "\n"
    [ "%__lang_region = type { ptr, ptr, i64 }";
      "@__lang_default_region = internal global %__lang_region zeroinitializer";
      "";
      "define void @__lang_region_init(ptr %r, i64 %cap) {";
      "entry:";
      "  %base = call ptr @malloc(i64 %cap)";
      "  %base_p = getelementptr %__lang_region, ptr %r, i32 0, i32 0";
      "  store ptr %base, ptr %base_p";
      "  %top_p = getelementptr %__lang_region, ptr %r, i32 0, i32 1";
      "  store ptr %base, ptr %top_p";
      "  %cap_p = getelementptr %__lang_region, ptr %r, i32 0, i32 2";
      "  store i64 %cap, ptr %cap_p";
      "  ret void";
      "}";
      "";
      "define ptr @__lang_region_alloc(ptr %r, i64 %n) {";
      "entry:";
      "  %n7 = add i64 %n, 7";
      "  %aligned = and i64 %n7, -8";
      "  %top_p = getelementptr %__lang_region, ptr %r, i32 0, i32 1";
      "  %top = load ptr, ptr %top_p";
      "  %new_top = getelementptr i8, ptr %top, i64 %aligned";
      "  store ptr %new_top, ptr %top_p";
      "  ret ptr %top";
      "}";
      "";
      "define void @__lang_region_free(ptr %r) {";
      "entry:";
      "  %base_p = getelementptr %__lang_region, ptr %r, i32 0, i32 0";
      "  %base = load ptr, ptr %base_p";
      "  call void @free(ptr %base)";
      "  ret void";
      "}" ]

(* Phase 15.3: emit one LLVM IR runtime block per concrete Vec element
   type. Uses LLVM's `getelementptr ... null, i32 1` idiom for sizeof.
   All pointers are opaque `ptr`; the element type only governs the
   GEP / load / store typing inside the helpers.
   Storage strategy mirrors codegen_c: struct + initial buffer come from
   the region, push reallocs by allocating a fresh larger buffer in the
   same region (arena semantics — old buffers leak until region free). *)
let emit_vec_runtime_for_llvm (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_elem = llvm_ty_of elem_ty in
  let struct_name = "mere_vec_" ^ tag in
  String.concat "\n"
    [ (* struct { ptr data; i32 len; i32 cap; ptr region } — 24 bytes. *)
      Printf.sprintf "%%%s = type { ptr, i32, i32, ptr }" struct_name;
      "";
      (* new *)
      Printf.sprintf "define ptr @mere_vec_%s_new(ptr %%r) {" tag;
      "entry:";
      Printf.sprintf "  %%v = call ptr @__lang_region_alloc(ptr %%r, i64 24)";
      Printf.sprintf "  %%esize_p = getelementptr %s, ptr null, i32 1" c_elem;
      Printf.sprintf "  %%esize = ptrtoint ptr %%esize_p to i64";
      Printf.sprintf "  %%init_bytes = mul i64 %%esize, 4";
      Printf.sprintf "  %%buf = call ptr @__lang_region_alloc(ptr %%r, i64 %%init_bytes)";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      Printf.sprintf "  store ptr %%buf, ptr %%dp";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      Printf.sprintf "  store i32 0, ptr %%lp";
      Printf.sprintf "  %%cp = getelementptr %%%s, ptr %%v, i32 0, i32 2" struct_name;
      Printf.sprintf "  store i32 4, ptr %%cp";
      Printf.sprintf "  %%rp = getelementptr %%%s, ptr %%v, i32 0, i32 3" struct_name;
      Printf.sprintf "  store ptr %%r, ptr %%rp";
      "  ret ptr %v";
      "}";
      "";
      (* push *)
      Printf.sprintf "define i32 @mere_vec_%s_push(ptr %%v, %s %%x) {" tag c_elem;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%cp = getelementptr %%%s, ptr %%v, i32 0, i32 2" struct_name;
      "  %cap = load i32, ptr %cp";
      "  %full = icmp eq i32 %len, %cap";
      "  br i1 %full, label %grow, label %store";
      "grow:";
      "  %new_cap = mul i32 %cap, 2";
      Printf.sprintf "  %%rp = getelementptr %%%s, ptr %%v, i32 0, i32 3" struct_name;
      "  %reg = load ptr, ptr %rp";
      "  %nc64 = zext i32 %new_cap to i64";
      Printf.sprintf "  %%esize_p = getelementptr %s, ptr null, i32 1" c_elem;
      "  %esize = ptrtoint ptr %esize_p to i64";
      "  %new_bytes = mul i64 %nc64, %esize";
      "  %new_buf = call ptr @__lang_region_alloc(ptr %reg, i64 %new_bytes)";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %old_buf = load ptr, ptr %dp";
      "  %old64 = zext i32 %len to i64";
      "  %old_bytes = mul i64 %old64, %esize";
      "  call ptr @memcpy(ptr %new_buf, ptr %old_buf, i64 %old_bytes)";
      "  store ptr %new_buf, ptr %dp";
      "  store i32 %new_cap, ptr %cp";
      "  br label %store";
      "store:";
      Printf.sprintf "  %%dp2 = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %cur = load ptr, ptr %dp2";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%cur, i32 %%len" c_elem;
      Printf.sprintf "  store %s %%x, ptr %%slot" c_elem;
      "  %new_len = add i32 %len, 1";
      "  store i32 %new_len, ptr %lp";
      "  ret i32 0";
      "}";
      "";
      (* get *)
      Printf.sprintf "define %s @mere_vec_%s_get(ptr %%v, i32 %%i) {" c_elem tag;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      "  %lt0 = icmp slt i32 %i, 0";
      "  %ge = icmp sge i32 %i, %len";
      "  %oob = or i1 %lt0, %ge";
      "  br i1 %oob, label %fail, label %ok";
      "fail:";
      "  call void @abort()";
      "  unreachable";
      "ok:";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %data = load ptr, ptr %dp";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%i" c_elem;
      Printf.sprintf "  %%val = load %s, ptr %%slot" c_elem;
      Printf.sprintf "  ret %s %%val" c_elem;
      "}";
      "";
      (* len *)
      Printf.sprintf "define i32 @mere_vec_%s_len(ptr %%v) {" tag;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      "  ret i32 %len";
      "}";
      "";
      (* Phase 15.5: vec_set v i x — in-place mutation. *)
      Printf.sprintf "define i32 @mere_vec_%s_set(ptr %%v, i32 %%i, %s %%x) {" tag c_elem;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      "  %lt0 = icmp slt i32 %i, 0";
      "  %ge = icmp sge i32 %i, %len";
      "  %oob = or i1 %lt0, %ge";
      "  br i1 %oob, label %fail, label %ok";
      "fail:";
      "  call void @abort()";
      "  unreachable";
      "ok:";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %data = load ptr, ptr %dp";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%i" c_elem;
      Printf.sprintf "  store %s %%x, ptr %%slot" c_elem;
      "  ret i32 0";
      "}" ]

(* Phase 15.5: vec_iter helper per element type T.
   Signature: i32 @mere_vec_<T>_iter(ptr v, %closure_<T>_unit cl)
   Emits a basic-block-style loop calling the closure for each element. *)
let emit_vec_iter_helper_llvm (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_elem = llvm_ty_of elem_ty in
  let struct_name = "mere_vec_" ^ tag in
  let cname = closure_struct_name elem_ty Ast.TyUnit in
  String.concat "\n"
    [ Printf.sprintf "define i32 @mere_vec_%s_iter(ptr %%v, %%%s %%cl) {" tag cname;
      "entry:";
      "  %env = extractvalue %" ^ cname ^ " %cl, 0";
      "  %fn = extractvalue %" ^ cname ^ " %cl, 1";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %data = load ptr, ptr %dp";
      "  br label %check";
      "check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %body ]";
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %end, label %body";
      "body:";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%i" c_elem;
      Printf.sprintf "  %%elem = load %s, ptr %%slot" c_elem;
      Printf.sprintf "  %%_ = call i32 %%fn(ptr %%env, %s %%elem)" c_elem;
      "  %i_next = add i32 %i, 1";
      "  br label %check";
      "end:";
      "  ret i32 0";
      "}" ]

(* Phase 15.5: vec_fold helper per (T, U) pair.
   Signature: <U> @mere_vec_<T>_fold_<U>(ptr v, <U> acc, %closure_<U>_closure_<T>_<U> outer)
   outer: U -> (T -> U). Apply outer(acc) to get inner closure_T_U, then
   inner(elem) to get the next acc. *)
let emit_vec_fold_helper_llvm (elem_ty : Ast.ty) (acc_ty : Ast.ty) : string =
  let t_tag = ty_tag elem_ty in
  let u_tag = ty_tag acc_ty in
  let c_elem = llvm_ty_of elem_ty in
  let c_acc = llvm_ty_of acc_ty in
  let struct_name = "mere_vec_" ^ t_tag in
  let inner_cl = closure_struct_name elem_ty acc_ty in
  let outer_cl = closure_struct_name acc_ty
    (Ast.TyArrow (elem_ty, acc_ty)) in
  String.concat "\n"
    [ Printf.sprintf
        "define %s @mere_vec_%s_fold_%s(ptr %%v, %s %%init, %%%s %%outer) {"
        c_acc t_tag u_tag c_acc outer_cl;
      "entry:";
      "  %outer_env = extractvalue %" ^ outer_cl ^ " %outer, 0";
      "  %outer_fn = extractvalue %" ^ outer_cl ^ " %outer, 1";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %data = load ptr, ptr %dp";
      "  br label %check";
      "check:";
      Printf.sprintf "  %%i = phi i32 [ 0, %%entry ], [ %%i_next, %%body ]";
      Printf.sprintf "  %%acc = phi %s [ %%init, %%entry ], [ %%new_acc, %%body ]" c_acc;
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %end, label %body";
      "body:";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%i" c_elem;
      Printf.sprintf "  %%elem = load %s, ptr %%slot" c_elem;
      Printf.sprintf "  %%inner = call %%%s %%outer_fn(ptr %%outer_env, %s %%acc)"
        inner_cl c_acc;
      Printf.sprintf "  %%inner_env = extractvalue %%%s %%inner, 0" inner_cl;
      Printf.sprintf "  %%inner_fn = extractvalue %%%s %%inner, 1" inner_cl;
      Printf.sprintf "  %%new_acc = call %s %%inner_fn(ptr %%inner_env, %s %%elem)" c_acc c_elem;
      "  %i_next = add i32 %i, 1";
      "  br label %check";
      "end:";
      Printf.sprintf "  ret %s %%acc" c_acc;
      "}" ]

(* Phase 15.6: vec_map per-(T, U) helper.
   Signature: ptr @mere_vec_<T>_map_<U>(ptr v, %closure_<T>_<U> cl)
   Region-preserving: 結果 Vec の region は v->region から取得。 *)
let emit_vec_map_helper_llvm (elem_ty : Ast.ty) (out_ty : Ast.ty) : string =
  let t_tag = ty_tag elem_ty in
  let u_tag = ty_tag out_ty in
  let c_t = llvm_ty_of elem_ty in
  let c_u = llvm_ty_of out_ty in
  let t_struct = "mere_vec_" ^ t_tag in
  let cname = closure_struct_name elem_ty out_ty in
  String.concat "\n"
    [ Printf.sprintf
        "define ptr @mere_vec_%s_map_%s(ptr %%v, %%%s %%cl) {"
        t_tag u_tag cname;
      "entry:";
      Printf.sprintf "  %%rp = getelementptr %%%s, ptr %%v, i32 0, i32 3" t_struct;
      "  %region = load ptr, ptr %rp";
      Printf.sprintf "  %%new = call ptr @mere_vec_%s_new(ptr %%region)" u_tag;
      "  %env = extractvalue %" ^ cname ^ " %cl, 0";
      "  %fn = extractvalue %" ^ cname ^ " %cl, 1";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" t_struct;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" t_struct;
      "  %data = load ptr, ptr %dp";
      "  br label %check";
      "check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %body ]";
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %end, label %body";
      "body:";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%i" c_t;
      Printf.sprintf "  %%elem = load %s, ptr %%slot" c_t;
      Printf.sprintf "  %%mapped = call %s %%fn(ptr %%env, %s %%elem)" c_u c_t;
      Printf.sprintf
        "  %%_ = call i32 @mere_vec_%s_push(ptr %%new, %s %%mapped)" u_tag c_u;
      "  %i_next = add i32 %i, 1";
      "  br label %check";
      "end:";
      "  ret ptr %new";
      "}" ]

(* Phase 15.6: vec_filter per-T helper.
   Signature: ptr @mere_vec_<T>_filter(ptr v, %closure_<T>_bool cl)
   Region-preserving。closure 返り値 i1 を icmp / br で分岐。 *)
let emit_vec_filter_helper_llvm (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_t = llvm_ty_of elem_ty in
  let t_struct = "mere_vec_" ^ tag in
  let cname = closure_struct_name elem_ty Ast.TyBool in
  String.concat "\n"
    [ Printf.sprintf
        "define ptr @mere_vec_%s_filter(ptr %%v, %%%s %%cl) {"
        tag cname;
      "entry:";
      Printf.sprintf "  %%rp = getelementptr %%%s, ptr %%v, i32 0, i32 3" t_struct;
      "  %region = load ptr, ptr %rp";
      Printf.sprintf "  %%new = call ptr @mere_vec_%s_new(ptr %%region)" tag;
      "  %env = extractvalue %" ^ cname ^ " %cl, 0";
      "  %fn = extractvalue %" ^ cname ^ " %cl, 1";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" t_struct;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" t_struct;
      "  %data = load ptr, ptr %dp";
      "  br label %check";
      "check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %cont ]";
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %end, label %body";
      "body:";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%i" c_t;
      Printf.sprintf "  %%elem = load %s, ptr %%slot" c_t;
      Printf.sprintf "  %%keep = call i1 %%fn(ptr %%env, %s %%elem)" c_t;
      "  br i1 %keep, label %push, label %cont";
      "push:";
      Printf.sprintf
        "  %%_ = call i32 @mere_vec_%s_push(ptr %%new, %s %%elem)" tag c_t;
      "  br label %cont";
      "cont:";
      "  %i_next = add i32 %i, 1";
      "  br label %check";
      "end:";
      "  ret ptr %new";
      "}" ]

(* Phase 15.8: OwnedVec registry — main 末で一括 free するための tracking。
   ptr の動的配列 + count / cap を file-scope globals に置く。各
   `@mere_owned_vec_<T>_new` が register を call、`@main` 末で
   `@__mere_owned_vec_free_all` を call。 *)
let owned_vec_registry_runtime_llvm =
  String.concat "\n"
    [ "; Phase 15.8: OwnedVec registry (process末で一括 free)";
      "@__mere_owned_vec_registry = internal global ptr null";
      "@__mere_owned_vec_count = internal global i32 0";
      "@__mere_owned_vec_cap = internal global i32 0";
      "";
      "define void @__mere_owned_vec_register(ptr %v) {";
      "entry:";
      "  %count = load i32, ptr @__mere_owned_vec_count";
      "  %cap = load i32, ptr @__mere_owned_vec_cap";
      "  %full = icmp eq i32 %count, %cap";
      "  br i1 %full, label %grow, label %store";
      "grow:";
      "  %is_zero = icmp eq i32 %cap, 0";
      "  %doubled = mul i32 %cap, 2";
      "  %new_cap = select i1 %is_zero, i32 8, i32 %doubled";
      "  store i32 %new_cap, ptr @__mere_owned_vec_cap";
      "  %nc64 = zext i32 %new_cap to i64";
      "  %psize = getelementptr ptr, ptr null, i32 1";
      "  %psize_i = ptrtoint ptr %psize to i64";
      "  %total = mul i64 %nc64, %psize_i";
      "  %old_reg = load ptr, ptr @__mere_owned_vec_registry";
      "  %new_reg = call ptr @realloc(ptr %old_reg, i64 %total)";
      "  store ptr %new_reg, ptr @__mere_owned_vec_registry";
      "  br label %store";
      "store:";
      "  %reg = load ptr, ptr @__mere_owned_vec_registry";
      "  %slot = getelementptr ptr, ptr %reg, i32 %count";
      "  store ptr %v, ptr %slot";
      "  %new_count = add i32 %count, 1";
      "  store i32 %new_count, ptr @__mere_owned_vec_count";
      "  ret void";
      "}";
      "";
      "define void @__mere_owned_vec_free_all() {";
      "entry:";
      "  %count = load i32, ptr @__mere_owned_vec_count";
      "  %reg = load ptr, ptr @__mere_owned_vec_registry";
      "  br label %check";
      "check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %body ]";
      "  %done = icmp sge i32 %i, %count";
      "  br i1 %done, label %end, label %body";
      "body:";
      "  %slot = getelementptr ptr, ptr %reg, i32 %i";
      "  %v = load ptr, ptr %slot";
      "  ; mere_owned_vec_<T> の最初の field は data ptr。全 T で同じ layout。";
      "  %dp = load ptr, ptr %v";
      "  call void @free(ptr %dp)";
      "  call void @free(ptr %v)";
      "  %i_next = add i32 %i, 1";
      "  br label %check";
      "end:";
      "  call void @free(ptr %reg)";
      "  store ptr null, ptr @__mere_owned_vec_registry";
      "  store i32 0, ptr @__mere_owned_vec_count";
      "  store i32 0, ptr @__mere_owned_vec_cap";
      "  ret void";
      "}" ]

(* Phase 15.7/15.8: OwnedVec[T] runtime — heap-allocated (malloc / realloc).
   `_new` registers itself in `__mere_owned_vec_registry` so main can
   free everything at program exit. *)
let emit_owned_vec_runtime_llvm (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_elem = llvm_ty_of elem_ty in
  let struct_name = "mere_owned_vec_" ^ tag in
  String.concat "\n"
    [ Printf.sprintf "%%%s = type { ptr, i32, i32 }" struct_name;
      "";
      (* new *)
      Printf.sprintf "define ptr @mere_owned_vec_%s_new() {" tag;
      "entry:";
      Printf.sprintf "  %%size_p = getelementptr %%%s, ptr null, i32 1" struct_name;
      "  %size = ptrtoint ptr %size_p to i64";
      "  %v = call ptr @malloc(i64 %size)";
      Printf.sprintf "  %%esize_p = getelementptr %s, ptr null, i32 1" c_elem;
      "  %esize = ptrtoint ptr %esize_p to i64";
      "  %init_bytes = mul i64 %esize, 4";
      "  %buf = call ptr @malloc(i64 %init_bytes)";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  store ptr %buf, ptr %dp";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  store i32 0, ptr %lp";
      Printf.sprintf "  %%cp = getelementptr %%%s, ptr %%v, i32 0, i32 2" struct_name;
      "  store i32 4, ptr %cp";
      "  call void @__mere_owned_vec_register(ptr %v)";
      "  ret ptr %v";
      "}";
      "";
      (* push *)
      Printf.sprintf "define i32 @mere_owned_vec_%s_push(ptr %%v, %s %%x) {" tag c_elem;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%cp = getelementptr %%%s, ptr %%v, i32 0, i32 2" struct_name;
      "  %cap = load i32, ptr %cp";
      "  %full = icmp eq i32 %len, %cap";
      "  br i1 %full, label %grow, label %store";
      "grow:";
      "  %new_cap = mul i32 %cap, 2";
      Printf.sprintf "  %%esize_p = getelementptr %s, ptr null, i32 1" c_elem;
      "  %esize = ptrtoint ptr %esize_p to i64";
      "  %nc64 = zext i32 %new_cap to i64";
      "  %new_bytes = mul i64 %nc64, %esize";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %old_buf = load ptr, ptr %dp";
      "  %new_buf = call ptr @realloc(ptr %old_buf, i64 %new_bytes)";
      "  store ptr %new_buf, ptr %dp";
      "  store i32 %new_cap, ptr %cp";
      "  br label %store";
      "store:";
      Printf.sprintf "  %%dp2 = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %data = load ptr, ptr %dp2";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%len" c_elem;
      Printf.sprintf "  store %s %%x, ptr %%slot" c_elem;
      "  %new_len = add i32 %len, 1";
      "  store i32 %new_len, ptr %lp";
      "  ret i32 0";
      "}";
      "";
      (* get *)
      Printf.sprintf "define %s @mere_owned_vec_%s_get(ptr %%v, i32 %%i) {" c_elem tag;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      "  %lt0 = icmp slt i32 %i, 0";
      "  %ge = icmp sge i32 %i, %len";
      "  %oob = or i1 %lt0, %ge";
      "  br i1 %oob, label %fail, label %ok";
      "fail:";
      "  call void @abort()";
      "  unreachable";
      "ok:";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %data = load ptr, ptr %dp";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%i" c_elem;
      Printf.sprintf "  %%val = load %s, ptr %%slot" c_elem;
      Printf.sprintf "  ret %s %%val" c_elem;
      "}";
      "";
      (* len *)
      Printf.sprintf "define i32 @mere_owned_vec_%s_len(ptr %%v) {" tag;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      "  ret i32 %len";
      "}" ]

(* Phase 15.7: vec_to_owned helper per-T.
   入力 Vec[R, T] → 出力 OwnedVec[T] への deep copy。 *)
let emit_vec_to_owned_helper_llvm (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_elem = llvm_ty_of elem_ty in
  let v_struct = "mere_vec_" ^ tag in
  String.concat "\n"
    [ Printf.sprintf "define ptr @mere_vec_to_owned_%s(ptr %%v) {" tag;
      "entry:";
      Printf.sprintf "  %%new = call ptr @mere_owned_vec_%s_new()" tag;
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" v_struct;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" v_struct;
      "  %data = load ptr, ptr %dp";
      "  br label %check";
      "check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %body ]";
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %end, label %body";
      "body:";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%i" c_elem;
      Printf.sprintf "  %%elem = load %s, ptr %%slot" c_elem;
      Printf.sprintf "  %%_ = call i32 @mere_owned_vec_%s_push(ptr %%new, %s %%elem)" tag c_elem;
      "  %i_next = add i32 %i, 1";
      "  br label %check";
      "end:";
      "  ret ptr %new";
      "}" ]

(* Phase 15.7: owned_vec_to_vec helper per-T.
   入力 OwnedVec[T] + region → 出力 Vec[R, T] への deep copy。 *)
let emit_owned_vec_to_vec_helper_llvm (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_elem = llvm_ty_of elem_ty in
  let ov_struct = "mere_owned_vec_" ^ tag in
  String.concat "\n"
    [ Printf.sprintf "define ptr @mere_owned_vec_to_vec_%s(ptr %%o, ptr %%region) {" tag;
      "entry:";
      Printf.sprintf "  %%new = call ptr @mere_vec_%s_new(ptr %%region)" tag;
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%o, i32 0, i32 1" ov_struct;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%o, i32 0, i32 0" ov_struct;
      "  %data = load ptr, ptr %dp";
      "  br label %check";
      "check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %body ]";
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %end, label %body";
      "body:";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%i" c_elem;
      Printf.sprintf "  %%elem = load %s, ptr %%slot" c_elem;
      Printf.sprintf "  %%_ = call i32 @mere_vec_%s_push(ptr %%new, %s %%elem)" tag c_elem;
      "  %i_next = add i32 %i, 1";
      "  br label %check";
      "end:";
      "  ret ptr %new";
      "}" ]

(* Phase 15.12: vec_to_list per-T helper.
   Builds the Cons chain bottom-up (start from Nil, prepend each elem in
   reverse). Allocates list nodes + tuple payloads in the default region.
   Layout: list_<T>_node = { i32 tag, %tuple_<T>_list_<T> payload }. *)
let emit_vec_to_list_helper_llvm (elem_ty : Ast.ty) (list_ty : Ast.ty)
    : string =
  let t_tag = ty_tag elem_ty in
  let c_elem = llvm_ty_of elem_ty in
  let v_struct = "mere_vec_" ^ t_tag in
  let list_mono =
    match list_ty with
    | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
      mono_variant_name n (List.map Ast.walk args)
    | Ast.TyCon (n, _) -> n
    | _ -> "list_" ^ t_tag
  in
  let node_struct =
    if is_recursive_variant_name list_mono then list_mono ^ "_node"
    else list_mono
  in
  let tup_struct = tuple_struct_name [elem_ty; Ast.TyCon (list_mono, [])] in
  let cons_tag =
    try Hashtbl.find variant_tags "Cons" with Not_found -> 1
  in
  let nil_tag =
    try Hashtbl.find variant_tags "Nil" with Not_found -> 0
  in
  String.concat "\n"
    [ Printf.sprintf "define ptr @mere_vec_to_list_%s(ptr %%v) {" t_tag;
      "entry:";
      (* Allocate Nil node *)
      Printf.sprintf "  %%node_size_p = getelementptr %%%s, ptr null, i32 1" node_struct;
      "  %node_size = ptrtoint ptr %node_size_p to i64";
      "  %nil = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %node_size)";
      Printf.sprintf "  %%nil_tp = getelementptr %%%s, ptr %%nil, i32 0, i32 0" node_struct;
      Printf.sprintf "  store i32 %d, ptr %%nil_tp" nil_tag;
      (* Loop *)
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" v_struct;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" v_struct;
      "  %data = load ptr, ptr %dp";
      "  %start_i = sub i32 %len, 1";
      "  br label %check";
      "check:";
      "  %i = phi i32 [ %start_i, %entry ], [ %i_next, %body ]";
      "  %acc = phi ptr [ %nil, %entry ], [ %new_node, %body ]";
      "  %done = icmp slt i32 %i, 0";
      "  br i1 %done, label %end, label %body";
      "body:";
      Printf.sprintf "  %%slot = getelementptr %s, ptr %%data, i32 %%i" c_elem;
      Printf.sprintf "  %%elem = load %s, ptr %%slot" c_elem;
      "  %new_node = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %node_size)";
      Printf.sprintf "  %%ntp = getelementptr %%%s, ptr %%new_node, i32 0, i32 0" node_struct;
      Printf.sprintf "  store i32 %d, ptr %%ntp" cons_tag;
      Printf.sprintf "  %%npp = getelementptr %%%s, ptr %%new_node, i32 0, i32 1" node_struct;
      Printf.sprintf "  %%tup = insertvalue %%%s undef, %s %%elem, 0" tup_struct c_elem;
      Printf.sprintf "  %%tup2 = insertvalue %%%s %%tup, ptr %%acc, 1" tup_struct;
      Printf.sprintf "  store %%%s %%tup2, ptr %%npp" tup_struct;
      "  %i_next = sub i32 %i, 1";
      "  br label %check";
      "end:";
      "  ret ptr %acc";
      "}" ]

(* Phase 15.12: len on T list per-T helper. *)
let emit_list_len_helper_llvm (elem_ty : Ast.ty) (list_ty : Ast.ty) : string =
  let t_tag = ty_tag elem_ty in
  let list_mono =
    match list_ty with
    | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
      mono_variant_name n (List.map Ast.walk args)
    | Ast.TyCon (n, _) -> n
    | _ -> "list_" ^ t_tag
  in
  let node_struct =
    if is_recursive_variant_name list_mono then list_mono ^ "_node"
    else list_mono
  in
  let tup_struct = tuple_struct_name [elem_ty; Ast.TyCon (list_mono, [])] in
  let cons_tag =
    try Hashtbl.find variant_tags "Cons" with Not_found -> 1
  in
  String.concat "\n"
    [ Printf.sprintf "define i32 @mere_list_%s_len(ptr %%l) {" t_tag;
      "entry:";
      "  br label %check";
      "check:";
      "  %n = phi i32 [ 0, %entry ], [ %n_next, %body ]";
      "  %cur = phi ptr [ %l, %entry ], [ %next, %body ]";
      Printf.sprintf "  %%tagp = getelementptr %%%s, ptr %%cur, i32 0, i32 0" node_struct;
      "  %tagv = load i32, ptr %tagp";
      Printf.sprintf "  %%is_cons = icmp eq i32 %%tagv, %d" cons_tag;
      "  br i1 %is_cons, label %body, label %end";
      "body:";
      Printf.sprintf "  %%pp = getelementptr %%%s, ptr %%cur, i32 0, i32 1" node_struct;
      Printf.sprintf "  %%tup = load %%%s, ptr %%pp" tup_struct;
      "  %next = extractvalue " ^ "%" ^ tup_struct ^ " %tup, 1";
      "  %n_next = add i32 %n, 1";
      "  br label %check";
      "end:";
      "  ret i32 %n";
      "}" ]

(* Phase 15.14: per-K equality helper for Map. Supports int / bool / str /
   tuple (recursive). Emitted once per K type, shared across (K, V) pairs. *)
let emit_map_key_eq_helper_llvm (k_ty : Ast.ty) : string =
  let k_tag = ty_tag k_ty in
  let c_k = llvm_ty_of k_ty in
  let reg_counter = ref 0 in
  let fresh () = incr reg_counter; Printf.sprintf "%%r%d" !reg_counter in
  let lines = ref [] in
  let emit s = lines := s :: !lines in
  let build a b =
    match Ast.walk k_ty with
    | _ ->
      let rec go ty a b =
        match Ast.walk ty with
        | Ast.TyInt | Ast.TyBool ->
          let r = fresh () in
          let t = llvm_ty_of ty in
          emit (Printf.sprintf "  %s = icmp eq %s %s, %s" r t a b);
          r
        | Ast.TyStr ->
          let cmp_r = fresh () in
          emit (Printf.sprintf "  %s = call i32 @strcmp(ptr %s, ptr %s)" cmp_r a b);
          let r = fresh () in
          emit (Printf.sprintf "  %s = icmp eq i32 %s, 0" r cmp_r);
          r
        | Ast.TyTuple ts ->
          let tup_struct = tuple_struct_name ts in
          let acc = ref None in
          List.iteri (fun i t ->
            let a_f = fresh () in
            emit (Printf.sprintf "  %s = extractvalue %%%s %s, %d" a_f tup_struct a i);
            let b_f = fresh () in
            emit (Printf.sprintf "  %s = extractvalue %%%s %s, %d" b_f tup_struct b i);
            let eq_i = go t a_f b_f in
            (match !acc with
             | None -> acc := Some eq_i
             | Some prev ->
               let combined = fresh () in
               emit (Printf.sprintf "  %s = and i1 %s, %s" combined prev eq_i);
               acc := Some combined)
          ) ts;
          (match !acc with
           | Some r -> r
           | None ->
             let r = fresh () in
             emit (Printf.sprintf "  %s = and i1 true, true" r);
             r)
        | Ast.TyCon (rname, _) when Hashtbl.mem Typer.records rname ->
          (* Phase 15.15: record key — compare each field via extractvalue. *)
          let info = Hashtbl.find Typer.records rname in
          let acc = ref None in
          List.iteri (fun i (_, ft) ->
            let a_f = fresh () in
            emit (Printf.sprintf "  %s = extractvalue %%%s %s, %d" a_f rname a i);
            let b_f = fresh () in
            emit (Printf.sprintf "  %s = extractvalue %%%s %s, %d" b_f rname b i);
            let eq_i = go ft a_f b_f in
            (match !acc with
             | None -> acc := Some eq_i
             | Some prev ->
               let combined = fresh () in
               emit (Printf.sprintf "  %s = and i1 %s, %s" combined prev eq_i);
               acc := Some combined)
          ) info.Typer.r_fields;
          (match !acc with Some r -> r | None ->
             let r = fresh () in
             emit (Printf.sprintf "  %s = and i1 true, true" r);
             r)
        | Ast.TyCon (vname, _) when Hashtbl.mem Exhaustive.type_variants vname ->
          (* Phase 15.15/15.16: variant key.
             1) Extract & compare tags.
             2) If a payload-carrying ctor (tag in nullary_tags excluded),
                compare payload (LLVM MVP: all payloads share same type).
             3) Otherwise (nullary), return tag-eq result. *)
          let ctors = Hashtbl.find Exhaustive.type_variants vname in
          let a_tag = fresh () in
          emit (Printf.sprintf "  %s = extractvalue %%%s %s, 0" a_tag vname a);
          let b_tag = fresh () in
          emit (Printf.sprintf "  %s = extractvalue %%%s %s, 0" b_tag vname b);
          let tag_eq = fresh () in
          emit (Printf.sprintf "  %s = icmp eq i32 %s, %s" tag_eq a_tag b_tag);
          (* Find the single shared payload type (if any). *)
          let payload_ty_opt =
            List.fold_left (fun acc (_, p) ->
              match acc, p with
              | None, Some pt -> Some (Ast.walk pt)
              | x, _ -> x) None ctors
          in
          (match payload_ty_opt with
           | None ->
             (* All nullary — tag eq is the answer. *)
             tag_eq
           | Some pt ->
             let a_pl = fresh () in
             emit (Printf.sprintf "  %s = extractvalue %%%s %s, 1" a_pl vname a);
             let b_pl = fresh () in
             emit (Printf.sprintf "  %s = extractvalue %%%s %s, 1" b_pl vname b);
             (* Determine if any nullary ctors exist; if so, those tags
                should short-circuit to true once tags match. We OR them
                with the payload-eq result. *)
             let nullary_tags =
               List.filter_map (fun (cname, p) ->
                 if p = None then Some (Hashtbl.find variant_tags cname)
                 else None) ctors
             in
             (* Compute "tag is nullary" as a series of icmp + or. *)
             let is_nullary_reg =
               match nullary_tags with
               | [] -> None
               | _ ->
                 let acc = ref None in
                 List.iter (fun tv ->
                   let r = fresh () in
                   emit (Printf.sprintf "  %s = icmp eq i32 %s, %d" r a_tag tv);
                   (match !acc with
                    | None -> acc := Some r
                    | Some prev ->
                      let combined = fresh () in
                      emit (Printf.sprintf "  %s = or i1 %s, %s" combined prev r);
                      acc := Some combined)) nullary_tags;
                 !acc
             in
             (* payload eq: recursive call on payload type pt. *)
             let pl_eq = go pt a_pl b_pl in
             (* result = tag_eq && (is_nullary || payload_eq) *)
             let inner =
               match is_nullary_reg with
               | None -> pl_eq
               | Some n ->
                 let r = fresh () in
                 emit (Printf.sprintf "  %s = or i1 %s, %s" r n pl_eq);
                 r
             in
             let r = fresh () in
             emit (Printf.sprintf "  %s = and i1 %s, %s" r tag_eq inner);
             r)
        | _ ->
          let r = fresh () in
          emit (Printf.sprintf "  %s = icmp eq %s %s, %s" r c_k a b);
          r
      in
      go k_ty a b
  in
  let final = build "%a" "%b" in
  let body_lines = List.rev !lines in
  String.concat "\n"
    ([ Printf.sprintf "define i1 @mere_map_key_eq_%s(%s %%a, %s %%b) {" k_tag c_k c_k;
       "entry:" ]
     @ body_lines
     @ [ Printf.sprintf "  ret i1 %s" final;
         "}" ])

(* Phase 15.10: Map[R, K, V] per-(K, V) runtime in LLVM IR.
   Linear-scan, region-allocated parallel arrays (keys[], values[]).
   K = int / str only; key equality is `icmp eq` for int, `@strcmp` for str. *)
let emit_map_runtime_llvm (k_ty : Ast.ty) (v_ty : Ast.ty) : string =
  let k_tag = ty_tag k_ty in
  let v_tag = ty_tag v_ty in
  let c_k = llvm_ty_of k_ty in
  let c_v = llvm_ty_of v_ty in
  let struct_name = Printf.sprintf "mere_map_%s_%s" k_tag v_tag in
  let fn_prefix = Printf.sprintf "mere_map_%s_%s" k_tag v_tag in
  (* Phase 15.14: emit a call to the per-K equality helper.
     The helper itself is emitted separately by `emit_map_key_eq_helper_llvm`. *)
  let emit_key_eq lhs k_reg eq_reg =
    Printf.sprintf "  %s = call i1 @mere_map_key_eq_%s(%s %s, %s %s)"
      eq_reg k_tag c_k lhs c_k k_reg
  in
  String.concat "\n"
    [ Printf.sprintf "%%%s = type { ptr, ptr, i32, i32, ptr }" struct_name;
      "";
      (* new *)
      Printf.sprintf "define ptr @%s_new(ptr %%r) {" fn_prefix;
      "entry:";
      Printf.sprintf "  %%size_p = getelementptr %%%s, ptr null, i32 1" struct_name;
      "  %size = ptrtoint ptr %size_p to i64";
      "  %m = call ptr @__lang_region_alloc(ptr %r, i64 %size)";
      Printf.sprintf "  %%ksize_p = getelementptr %s, ptr null, i32 1" c_k;
      "  %ksize = ptrtoint ptr %ksize_p to i64";
      Printf.sprintf "  %%vsize_p = getelementptr %s, ptr null, i32 1" c_v;
      "  %vsize = ptrtoint ptr %vsize_p to i64";
      "  %k_bytes = mul i64 %ksize, 4";
      "  %v_bytes = mul i64 %vsize, 4";
      "  %keys = call ptr @__lang_region_alloc(ptr %r, i64 %k_bytes)";
      "  %values = call ptr @__lang_region_alloc(ptr %r, i64 %v_bytes)";
      Printf.sprintf "  %%kp = getelementptr %%%s, ptr %%m, i32 0, i32 0" struct_name;
      "  store ptr %keys, ptr %kp";
      Printf.sprintf "  %%vp = getelementptr %%%s, ptr %%m, i32 0, i32 1" struct_name;
      "  store ptr %values, ptr %vp";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%m, i32 0, i32 2" struct_name;
      "  store i32 0, ptr %lp";
      Printf.sprintf "  %%cp = getelementptr %%%s, ptr %%m, i32 0, i32 3" struct_name;
      "  store i32 4, ptr %cp";
      Printf.sprintf "  %%rp = getelementptr %%%s, ptr %%m, i32 0, i32 4" struct_name;
      "  store ptr %r, ptr %rp";
      "  ret ptr %m";
      "}";
      "";
      (* set *)
      Printf.sprintf "define i32 @%s_set(ptr %%m, %s %%k, %s %%v) {"
        fn_prefix c_k c_v;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%m, i32 0, i32 2" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%kp = getelementptr %%%s, ptr %%m, i32 0, i32 0" struct_name;
      "  %keys = load ptr, ptr %kp";
      Printf.sprintf "  %%vp = getelementptr %%%s, ptr %%m, i32 0, i32 1" struct_name;
      "  %values = load ptr, ptr %vp";
      "  br label %scan_check";
      "scan_check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %scan_cont ]";
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %not_found, label %scan_body";
      "scan_body:";
      Printf.sprintf "  %%kslot = getelementptr %s, ptr %%keys, i32 %%i" c_k;
      Printf.sprintf "  %%cur_k = load %s, ptr %%kslot" c_k;
      emit_key_eq "%cur_k" "%k" "%eq";
      "  br i1 %eq, label %replace, label %scan_cont";
      "replace:";
      Printf.sprintf "  %%vslot = getelementptr %s, ptr %%values, i32 %%i" c_v;
      Printf.sprintf "  store %s %%v, ptr %%vslot" c_v;
      "  ret i32 0";
      "scan_cont:";
      "  %i_next = add i32 %i, 1";
      "  br label %scan_check";
      "not_found:";
      Printf.sprintf "  %%cp = getelementptr %%%s, ptr %%m, i32 0, i32 3" struct_name;
      "  %cap = load i32, ptr %cp";
      "  %full = icmp eq i32 %len, %cap";
      "  br i1 %full, label %grow, label %do_store";
      "grow:";
      Printf.sprintf "  %%rp = getelementptr %%%s, ptr %%m, i32 0, i32 4" struct_name;
      "  %reg = load ptr, ptr %rp";
      "  %new_cap = mul i32 %cap, 2";
      "  %nc64 = zext i32 %new_cap to i64";
      Printf.sprintf "  %%ksize_p = getelementptr %s, ptr null, i32 1" c_k;
      "  %ksize = ptrtoint ptr %ksize_p to i64";
      Printf.sprintf "  %%vsize_p = getelementptr %s, ptr null, i32 1" c_v;
      "  %vsize = ptrtoint ptr %vsize_p to i64";
      "  %k_bytes = mul i64 %nc64, %ksize";
      "  %v_bytes = mul i64 %nc64, %vsize";
      "  %new_keys = call ptr @__lang_region_alloc(ptr %reg, i64 %k_bytes)";
      "  %new_values = call ptr @__lang_region_alloc(ptr %reg, i64 %v_bytes)";
      "  %len64 = zext i32 %len to i64";
      "  %k_copy_bytes = mul i64 %len64, %ksize";
      "  %v_copy_bytes = mul i64 %len64, %vsize";
      "  call ptr @memcpy(ptr %new_keys, ptr %keys, i64 %k_copy_bytes)";
      "  call ptr @memcpy(ptr %new_values, ptr %values, i64 %v_copy_bytes)";
      "  store ptr %new_keys, ptr %kp";
      "  store ptr %new_values, ptr %vp";
      "  store i32 %new_cap, ptr %cp";
      "  br label %do_store";
      "do_store:";
      "  %cur_keys = load ptr, ptr %kp";
      "  %cur_values = load ptr, ptr %vp";
      Printf.sprintf "  %%kslot2 = getelementptr %s, ptr %%cur_keys, i32 %%len" c_k;
      Printf.sprintf "  store %s %%k, ptr %%kslot2" c_k;
      Printf.sprintf "  %%vslot2 = getelementptr %s, ptr %%cur_values, i32 %%len" c_v;
      Printf.sprintf "  store %s %%v, ptr %%vslot2" c_v;
      "  %new_len = add i32 %len, 1";
      "  store i32 %new_len, ptr %lp";
      "  ret i32 0";
      "}";
      "";
      (* get *)
      Printf.sprintf "define %s @%s_get(ptr %%m, %s %%k) {" c_v fn_prefix c_k;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%m, i32 0, i32 2" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%kp = getelementptr %%%s, ptr %%m, i32 0, i32 0" struct_name;
      "  %keys = load ptr, ptr %kp";
      Printf.sprintf "  %%vp = getelementptr %%%s, ptr %%m, i32 0, i32 1" struct_name;
      "  %values = load ptr, ptr %vp";
      "  br label %scan_check";
      "scan_check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %scan_cont ]";
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %fail, label %scan_body";
      "scan_body:";
      Printf.sprintf "  %%kslot = getelementptr %s, ptr %%keys, i32 %%i" c_k;
      Printf.sprintf "  %%cur_k = load %s, ptr %%kslot" c_k;
      emit_key_eq "%cur_k" "%k" "%eq";
      "  br i1 %eq, label %found, label %scan_cont";
      "found:";
      Printf.sprintf "  %%vslot = getelementptr %s, ptr %%values, i32 %%i" c_v;
      Printf.sprintf "  %%v = load %s, ptr %%vslot" c_v;
      Printf.sprintf "  ret %s %%v" c_v;
      "scan_cont:";
      "  %i_next = add i32 %i, 1";
      "  br label %scan_check";
      "fail:";
      "  call void @abort()";
      "  unreachable";
      "}";
      "";
      (* has *)
      Printf.sprintf "define i1 @%s_has(ptr %%m, %s %%k) {" fn_prefix c_k;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%m, i32 0, i32 2" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%kp = getelementptr %%%s, ptr %%m, i32 0, i32 0" struct_name;
      "  %keys = load ptr, ptr %kp";
      "  br label %scan_check";
      "scan_check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %scan_cont ]";
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %not_found, label %scan_body";
      "scan_body:";
      Printf.sprintf "  %%kslot = getelementptr %s, ptr %%keys, i32 %%i" c_k;
      Printf.sprintf "  %%cur_k = load %s, ptr %%kslot" c_k;
      emit_key_eq "%cur_k" "%k" "%eq";
      "  br i1 %eq, label %found, label %scan_cont";
      "found:";
      "  ret i1 1";
      "scan_cont:";
      "  %i_next = add i32 %i, 1";
      "  br label %scan_check";
      "not_found:";
      "  ret i1 0";
      "}";
      "";
      (* len *)
      Printf.sprintf "define i32 @%s_len(ptr %%m) {" fn_prefix;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%m, i32 0, i32 2" struct_name;
      "  %len = load i32, ptr %lp";
      "  ret i32 %len";
      "}" ]

(* Phase 15.9: StrBuf[R] runtime — single non-polymorphic type. Region-
   allocated mutable byte buffer; to_str returns a null-terminated copy
   in the same region. *)
let strbuf_runtime_llvm =
  String.concat "\n"
    [ "%mere_strbuf = type { ptr, i32, i32, ptr }";
      "";
      (* new *)
      "define ptr @mere_strbuf_new(ptr %r) {";
      "entry:";
      "  %sb = call ptr @__lang_region_alloc(ptr %r, i64 24)";
      "  %buf = call ptr @__lang_region_alloc(ptr %r, i64 16)";
      "  %dp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 0";
      "  store ptr %buf, ptr %dp";
      "  %lp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 1";
      "  store i32 0, ptr %lp";
      "  %cp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 2";
      "  store i32 16, ptr %cp";
      "  %rp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 3";
      "  store ptr %r, ptr %rp";
      "  ret ptr %sb";
      "}";
      "";
      (* push *)
      "define i32 @mere_strbuf_push(ptr %sb, ptr %s) {";
      "entry:";
      "  %slen64 = call i64 @strlen(ptr %s)";
      "  %slen = trunc i64 %slen64 to i32";
      "  br label %check";
      "check:";
      "  %lp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 1";
      "  %len = load i32, ptr %lp";
      "  %cp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 2";
      "  %cap = load i32, ptr %cp";
      "  %need = add i32 %len, %slen";
      "  %too_small = icmp sgt i32 %need, %cap";
      "  br i1 %too_small, label %grow, label %do_copy";
      "grow:";
      "  %new_cap = mul i32 %cap, 2";
      "  %rp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 3";
      "  %reg = load ptr, ptr %rp";
      "  %nc64 = zext i32 %new_cap to i64";
      "  %new_buf = call ptr @__lang_region_alloc(ptr %reg, i64 %nc64)";
      "  %dp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 0";
      "  %old_buf = load ptr, ptr %dp";
      "  %len_zext = zext i32 %len to i64";
      "  call ptr @memcpy(ptr %new_buf, ptr %old_buf, i64 %len_zext)";
      "  store ptr %new_buf, ptr %dp";
      "  store i32 %new_cap, ptr %cp";
      "  br label %check";
      "do_copy:";
      "  %dp2 = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 0";
      "  %buf2 = load ptr, ptr %dp2";
      "  %dst = getelementptr i8, ptr %buf2, i32 %len";
      "  %slen_zext = zext i32 %slen to i64";
      "  call ptr @memcpy(ptr %dst, ptr %s, i64 %slen_zext)";
      "  %new_len = add i32 %len, %slen";
      "  store i32 %new_len, ptr %lp";
      "  ret i32 0";
      "}";
      "";
      (* to_str *)
      "define ptr @mere_strbuf_to_str(ptr %sb) {";
      "entry:";
      "  %lp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 1";
      "  %len = load i32, ptr %lp";
      "  %rp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 3";
      "  %reg = load ptr, ptr %rp";
      "  %len1 = add i32 %len, 1";
      "  %len1_64 = zext i32 %len1 to i64";
      "  %out = call ptr @__lang_region_alloc(ptr %reg, i64 %len1_64)";
      "  %dp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 0";
      "  %buf = load ptr, ptr %dp";
      "  %len_64 = zext i32 %len to i64";
      "  call ptr @memcpy(ptr %out, ptr %buf, i64 %len_64)";
      "  %end = getelementptr i8, ptr %out, i32 %len";
      "  store i8 0, ptr %end";
      "  ret ptr %out";
      "}";
      "";
      (* len *)
      "define i32 @mere_strbuf_len(ptr %sb) {";
      "entry:";
      "  %lp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 1";
      "  %len = load i32, ptr %lp";
      "  ret i32 %len";
      "}" ]

(* Phase 16.3 / DEFERRED §1.5: Logger / Metrics の LLVM IR runtime。
   C 側と同じ printf-based 実装を IR で表現する。Logger 構造体は
   既に %Logger = type { %closure_str_unit, %closure_str_unit,
   %closure_str_unit } が record typedef 経由で emit されている前提。 *)
let logger_runtime_llvm =
  String.concat "\n"
    [ "@.__logger_fmt_info = private constant [14 x i8] c\"%s [INFO] %s\\0A\\00\"";
      "@.__logger_fmt_warn = private constant [14 x i8] c\"%s [WARN] %s\\0A\\00\"";
      "@.__logger_fmt_err  = private constant [15 x i8] c\"%s [ERROR] %s\\0A\\00\"";
      "";
      "define internal i32 @__mere_logger_info_fn(ptr %env, ptr %msg) {";
      "  call i32 (ptr, ...) @printf(ptr @.__logger_fmt_info, ptr %env, ptr %msg)";
      "  ret i32 0";
      "}";
      "define internal i32 @__mere_logger_warn_fn(ptr %env, ptr %msg) {";
      "  call i32 (ptr, ...) @printf(ptr @.__logger_fmt_warn, ptr %env, ptr %msg)";
      "  ret i32 0";
      "}";
      "define internal i32 @__mere_logger_error_fn(ptr %env, ptr %msg) {";
      "  call i32 (ptr, ...) @printf(ptr @.__logger_fmt_err, ptr %env, ptr %msg)";
      "  ret i32 0";
      "}";
      "";
      "define %Logger @__mere_mk_logger(ptr %prefix) {";
      "entry:";
      (* Build the Logger value via insertvalue cascades.
         Logger = { closure_str_unit info, warn, error }
         closure_str_unit = { ptr env, ptr fn } *)
      "  %r0 = insertvalue %Logger zeroinitializer, ptr %prefix, 0, 0";
      "  %r1 = insertvalue %Logger %r0, ptr @__mere_logger_info_fn, 0, 1";
      "  %r2 = insertvalue %Logger %r1, ptr %prefix, 1, 0";
      "  %r3 = insertvalue %Logger %r2, ptr @__mere_logger_warn_fn, 1, 1";
      "  %r4 = insertvalue %Logger %r3, ptr %prefix, 2, 0";
      "  %r5 = insertvalue %Logger %r4, ptr @__mere_logger_error_fn, 2, 1";
      "  ret %Logger %r5";
      "}" ]

let metrics_runtime_llvm =
  String.concat "\n"
    [ "@.__metrics_fmt_inc = private constant [17 x i8] c\"[METRIC] inc %s\\0A\\00\"";
      "@.__metrics_fmt_rec = private constant [16 x i8] c\"[METRIC] %s=%d\\0A\\00\"";
      "";
      "define internal i32 @__mere_metrics_inc_fn(ptr %env, ptr %name) {";
      "  call i32 (ptr, ...) @printf(ptr @.__metrics_fmt_inc, ptr %name)";
      "  ret i32 0";
      "}";
      "define internal i32 @__mere_metrics_record_inner_fn(ptr %env, i32 %n) {";
      "  call i32 (ptr, ...) @printf(ptr @.__metrics_fmt_rec, ptr %env, i32 %n)";
      "  ret i32 0";
      "}";
      "define internal %closure_int_unit @__mere_metrics_record_outer_fn(ptr %env, ptr %name) {";
      "  %r0 = insertvalue %closure_int_unit zeroinitializer, ptr %name, 0";
      "  %r1 = insertvalue %closure_int_unit %r0, ptr @__mere_metrics_record_inner_fn, 1";
      "  ret %closure_int_unit %r1";
      "}";
      "";
      "define %Metrics @__mere_mk_metrics() {";
      "entry:";
      "  %r0 = insertvalue %Metrics zeroinitializer, ptr null, 0, 0";
      "  %r1 = insertvalue %Metrics %r0, ptr @__mere_metrics_inc_fn, 0, 1";
      "  %r2 = insertvalue %Metrics %r1, ptr null, 1, 0";
      "  %r3 = insertvalue %Metrics %r2, ptr @__mere_metrics_record_outer_fn, 1, 1";
      "  ret %Metrics %r3";
      "}" ]

let str_concat_helper =
  String.concat "\n"
    [ "define ptr @__lang_str_concat(ptr %a, ptr %b) {";
      "entry:";
      "  %la = call i64 @strlen(ptr %a)";
      "  %lb = call i64 @strlen(ptr %b)";
      "  %total = add i64 %la, %lb";
      "  %totalp1 = add i64 %total, 1";
      "  %r = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %totalp1)";
      "  call ptr @memcpy(ptr %r, ptr %a, i64 %la)";
      "  %p1 = getelementptr i8, ptr %r, i64 %la";
      "  call ptr @memcpy(ptr %p1, ptr %b, i64 %lb)";
      "  %p2 = getelementptr i8, ptr %r, i64 %total";
      "  store i8 0, ptr %p2";
      "  ret ptr %r";
      "}" ]

let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
  str_globals := [];
  str_counter := 0;
  pending_closures := [];
  anon_env_typedefs := [];
  anon_closure_counter := 0;
  current_var_types := [];
  Hashtbl.reset toplevel_fn_names;
  Hashtbl.reset polymorphic_variants;
  Hashtbl.reset polymorphic_records;
  Hashtbl.reset mono_variant_instances;
  Hashtbl.reset mono_record_instances;
  Hashtbl.reset recursive_variants;
  Hashtbl.reset show_types;
  Hashtbl.reset vec_instances;
  Hashtbl.reset vec_iter_instances;
  Hashtbl.reset vec_fold_instances;
  Hashtbl.reset vec_map_instances;
  Hashtbl.reset vec_filter_instances;
  Hashtbl.reset owned_vec_instances;
  Hashtbl.reset map_instances;
  Hashtbl.reset vec_to_list_instances;
  strbuf_used := false;
  logger_used := false;
  metrics_used := false;
  show_string_globals := [];
  show_format_globals := [];
  (* Register variant tags + classify into mono / poly. Polymorphic
     variants and records are deferred to mono-instance emission. *)
  Hashtbl.iter (fun name vs ->
    List.iteri (fun i (cname, _) ->
      Hashtbl.replace variant_tags cname i) vs;
    let params =
      match vs with
      | (cname, _) :: _ ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some info -> info.Typer.params
         | None -> [])
      | [] -> []
    in
    if params <> [] then Hashtbl.replace polymorphic_variants name (params, vs);
    (* Mark source-level recursive variants. Mono instances of poly
       recursive variants will be marked below at instance-collection time. *)
    if variant_is_recursive name vs then
      Hashtbl.replace recursive_variants name ()
  ) Exhaustive.type_variants;
  Hashtbl.iter (fun name info ->
    if info.Typer.r_params <> [] then
      Hashtbl.replace polymorphic_records name (info.Typer.r_params, info.Typer.r_fields)
  ) Typer.records;
  let main_expr = Ast.desugar_program prog in
  (* Phase 15.3: resolve let-bound Vec element types. Same trick as
     codegen_c — Mere's let-poly generalizes `let v = vec_new () in body`
     to `forall T. Vec[..., T]`, so each use of v in body gets a fresh
     element tyvar. Walk the typed AST and unify the binding-site
     element with each `Var name` use; once any use resolves (e.g.
     `vec_push v 10`), the chain propagates to all sites. *)
  let resolve_vec_let_types (root : Ast.expr) : unit =
    let unify_with_value (vt : Ast.ty) (ut : Ast.ty) : unit =
      try Typer.unify Loc.dummy vt ut with _ -> ()
    in
    let rec scan_uses name vt body =
      (match body.Ast.node with
       | Ast.Var n when n = name ->
         (match body.Ast.ty with
          | Some t -> unify_with_value vt t
          | None -> ())
       | _ -> ());
      let recur b = scan_uses name vt b in
      match body.Ast.node with
      | Ast.App (a, b) -> recur a; recur b
      | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b) ->
        recur a; recur b
      | Ast.Neg a | Ast.Annot (a, _) | Ast.Field_get (a, _)
      | Ast.Ref (_, _, a) | Ast.Region_block (_, a) -> recur a
      | Ast.Let (pat, v, b) ->
        recur v;
        (match pat.Ast.pnode with
         | Ast.P_var n when n = name -> ()
         | _ -> recur b)
      | Ast.Let_rec (bs, b) ->
        let shadowed = List.exists (fun (n, _) -> n = name) bs in
        List.iter (fun (_, v) -> recur v) bs;
        if not shadowed then recur b
      | Ast.If (c, t, e_) -> recur c; recur t; recur e_
      | Ast.Tuple es -> List.iter recur es
      | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> recur e) fs
      | Ast.Record_update (a, fs) ->
        recur a; List.iter (fun (_, e) -> recur e) fs
      | Ast.With (n, v, b) -> recur v; if n <> name then recur b
      | Ast.Fun (n, _, b) -> if n <> name then recur b
      | Ast.Match (s, arms) ->
        recur s;
        List.iter (fun (_, g, b) ->
          (match g with Some ge -> recur ge | None -> ()); recur b) arms
      | Ast.Constr (_, Some a) -> recur a
      | _ -> ()
    in
    let rec walk e =
      (match e.Ast.node with
       | Ast.Let (pat, value, body) ->
         (match pat.Ast.pnode, value.Ast.ty with
          | Ast.P_var name, Some vt ->
            (match Ast.walk vt with
             | Ast.TyCon ("Vec", _) | Ast.TyCon ("OwnedVec", _)
             | Ast.TyCon ("Map", _) | Ast.TyCon ("StrBuf", _) ->
               scan_uses name vt body
             | _ -> ())
          | _ -> ())
       | Ast.With (name, value, body) ->
         (match value.Ast.ty with
          | Some vt ->
            (match Ast.walk vt with
             | Ast.TyCon ("Vec", _) | Ast.TyCon ("OwnedVec", _)
             | Ast.TyCon ("Map", _) | Ast.TyCon ("StrBuf", _) ->
               scan_uses name vt body
             | _ -> ())
          | None -> ())
       | _ -> ());
      walk_subs e
    and walk_subs e =
      match e.Ast.node with
      | Ast.Let (_, v, b) -> walk v; walk b
      | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk v) bs; walk b
      | Ast.App (a, b) | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b)
      | Ast.Logic (_, a, b) -> walk a; walk b
      | Ast.Neg a | Ast.Annot (a, _) | Ast.Field_get (a, _)
      | Ast.Ref (_, _, a) | Ast.Region_block (_, a) | Ast.Fun (_, _, a) ->
        walk a
      | Ast.If (c, t, e_) -> walk c; walk t; walk e_
      | Ast.Tuple es -> List.iter walk es
      | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk e) fs
      | Ast.Record_update (a, fs) ->
        walk a; List.iter (fun (_, e) -> walk e) fs
      | Ast.With (_, v, b) -> walk v; walk b
      | Ast.Match (s, arms) ->
        walk s;
        List.iter (fun (_, g, b) ->
          (match g with Some ge -> walk ge | None -> ()); walk b) arms
      | Ast.Constr (_, Some a) -> walk a
      | _ -> ()
    in
    walk root
  in
  resolve_vec_let_types main_expr;
  (* Lift top-level fn bindings; the remainder is the actual main body. *)
  let skels, body_expr = lift_fn_skels main_expr in
  List.iter (fun s -> Hashtbl.replace toplevel_fn_names s.sname ()) skels;
  let fns = resolve_fn_types skels main_expr in
  (* Discover mono variant / record instances + mark recursive ones
     BEFORE any typedef emission. Also collect show types now (their
     instances need to flow into mono_variant_instances so emit picks
     up types only-used-via-show). *)
  collect_mono_instances main_expr fns;
  collect_show_types main_expr fns;
  Hashtbl.iter (fun _ (vn, args) ->
    let (params, variants) = Hashtbl.find polymorphic_variants vn in
    let sv = subst_variants params args variants in
    if mono_variant_is_recursive vn args sv then
      Hashtbl.replace recursive_variants (mono_variant_name vn args) ()
  ) mono_variant_instances;
  let tuple_shapes = collect_tuple_shapes main_expr fns in
  let tuple_typedefs = List.map emit_tuple_typedef tuple_shapes in
  let record_names = collect_record_names main_expr fns in
  let record_typedefs = List.map emit_record_typedef record_names in
  let variant_names = collect_variant_names main_expr fns in
  let variant_typedefs = List.map emit_variant_typedef variant_names in
  let mono_variant_typedefs =
    Hashtbl.fold (fun _ (vn, args) acc ->
      emit_mono_variant_typedef vn args :: acc) mono_variant_instances []
  in
  let mono_record_typedefs =
    Hashtbl.fold (fun _ (rn, args) acc ->
      emit_mono_record_typedef rn args :: acc) mono_record_instances []
  in
  let arrow_types = collect_arrow_types main_expr fns in
  let closure_typedefs = List.map emit_closure_typedef arrow_types in
  (* Pre-register show globals (constants + format strings). Show types
     are already collected (above), but the format strings depend on
     specific types that we register here. *)
  if Hashtbl.length show_types > 0 then begin
    mint_show_global "s_true" "true";
    mint_show_global "s_false" "false";
    mint_show_global "s_unit" "()";
    mint_show_global "s_lbracket" "[";
    mint_show_global "s_rbracket" "]";
    mint_show_global "s_comma_space" ", ";
    mint_show_format "show_int" "%d";
    mint_show_format "show_str" "\"%s\"";
    mint_show_format "show_ctor_payload" "%s %s";
    (* Per-type tuple / record / variant format strings + per-ctor
       name strings. *)
    let registered_ctors = Hashtbl.create 4 in
    Hashtbl.iter (fun tag t ->
      match Ast.walk t with
      | Ast.TyTuple ts ->
        let body =
          "(" ^ String.concat ", "
            (List.init (List.length ts) (fun _ -> "%s")) ^ ")"
        in
        mint_show_format ("show_" ^ tag) body
      | Ast.TyCon (n, _) when Hashtbl.mem polymorphic_records n
                           || Hashtbl.mem Typer.records n ->
        let fields_count =
          if Hashtbl.mem polymorphic_records n then
            let (_, fs) = Hashtbl.find polymorphic_records n in List.length fs
          else
            List.length (record_fields n)
        in
        let body =
          n ^ " { " ^
          String.concat ", "
            (List.mapi (fun i _ ->
              let fname =
                if Hashtbl.mem polymorphic_records n then
                  fst (List.nth (snd (Hashtbl.find polymorphic_records n)) i)
                else
                  fst (List.nth (record_fields n) i)
              in
              fname ^ " = %s") (List.init fields_count (fun _ -> 0)))
          ^ " }"
        in
        mint_show_format ("show_" ^ tag) body
      | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
        let (params, variants) = Hashtbl.find polymorphic_variants n in
        let sv = subst_variants params args variants in
        List.iter (fun (cname, _) ->
          if not (Hashtbl.mem registered_ctors cname) then begin
            Hashtbl.add registered_ctors cname ();
            mint_show_global ("s_ctor_" ^ cname) cname
          end
        ) sv
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.types n ->
        let vs = variant_shape n in
        List.iter (fun (cname, _) ->
          if not (Hashtbl.mem registered_ctors cname) then begin
            Hashtbl.add registered_ctors cname ();
            mint_show_global ("s_ctor_" ^ cname) cname
          end
        ) vs
      | _ -> ()
    ) show_types
  end;
  let show_fn_defs =
    Hashtbl.fold (fun tag t acc -> emit_show_fn tag t :: acc) show_types []
  in
  let fn_defs = List.map emit_fn_def fns in
  let closure_adapters = List.map emit_closure_adapter fns in
  (* Reset counters for the main body. *)
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
  emit_instr "entry:";
  emit_instr
    "  call void @__lang_region_init(ptr @__lang_default_region, i64 4194304)";
  let r = emit_expr [] body_expr in
  (* Optional printf of main result. *)
  let print_lines =
    match main_format_of main_ty with
    | None -> []
    | Some (ty, fmt) ->
      let widen =
        if ty = "i32" && (match Ast.walk main_ty with Ast.TyBool -> true | _ -> false) then
          let r2 = fresh_reg () in
          ([ Printf.sprintf "  %s = zext i1 %s to i32" r2 r ], r2)
        else
          ([], r)
      in
      let (extra, r_final) = widen in
      extra @
      [ Printf.sprintf
          "  call i32 (ptr, ...) @printf(ptr @.fmt_%s, %s %s)"
          (String.sub fmt 1 (String.length fmt - 1)) ty r_final ]
  in
  List.iter emit_instr print_lines;
  (* Phase 15.8: free all OwnedVec allocations registered during run. *)
  if Hashtbl.length owned_vec_instances > 0 then
    emit_instr "  call void @__mere_owned_vec_free_all()";
  emit_instr "  call void @__lang_region_free(ptr @__lang_default_region)";
  emit_instr "  ret i32 0";
  let body = String.concat "\n" (List.rev !instrs) in
  (* Drain pending closures (anonymous Funs accumulated during all of
     the above emits). Draining can push more pendings — keep going
     until the queue is empty. *)
  let anon_adapters = ref [] in
  let rec drain () =
    match !pending_closures with
    | [] -> ()
    | ce :: rest ->
      pending_closures := rest;
      anon_adapters := emit_anon_adapter ce :: !anon_adapters;
      drain ()
  in
  drain ();
  let anon_adapters = List.rev !anon_adapters in
  let format_globals =
    (* Hardcoded format strings. Byte lengths count LLVM escapes (`\0A`)
       as 1 byte each and include the null terminator. *)
    match main_format_of main_ty with
    | None -> []
    | Some (_, "%d") ->
      [ "@.fmt_d = private constant [4 x i8] c\"%d\\0A\\00\"" ]
    | Some (_, "%s") ->
      [ "@.fmt_s = private constant [4 x i8] c\"%s\\0A\\00\"" ]
    | _ -> []
  in
  (* Phase 15.3: Vec[R, T] runtime — emit one struct typedef + 4 helper
     functions per element type seen during fn / main emission. *)
  let vec_runtimes =
    Hashtbl.fold (fun _tag elem_ty acc ->
      emit_vec_runtime_for_llvm elem_ty :: acc) vec_instances []
  in
  let vec_iter_helpers =
    Hashtbl.fold (fun _tag elem_ty acc ->
      emit_vec_iter_helper_llvm elem_ty :: acc) vec_iter_instances []
  in
  let vec_fold_helpers =
    Hashtbl.fold (fun _key (elem_ty, acc_ty) acc ->
      emit_vec_fold_helper_llvm elem_ty acc_ty :: acc) vec_fold_instances []
  in
  let vec_map_helpers =
    Hashtbl.fold (fun _key (t_ty, u_ty) acc ->
      emit_vec_map_helper_llvm t_ty u_ty :: acc) vec_map_instances []
  in
  let vec_filter_helpers =
    Hashtbl.fold (fun _tag elem_ty acc ->
      emit_vec_filter_helper_llvm elem_ty :: acc) vec_filter_instances []
  in
  let owned_vec_runtimes =
    Hashtbl.fold (fun _tag elem_ty acc ->
      emit_owned_vec_runtime_llvm elem_ty :: acc) owned_vec_instances []
  in
  (* Phase 15.14: emit per-K key-equality helpers once, before the
     per-(K, V) map runtimes (which call them). *)
  let map_key_eq_helpers =
    let seen = Hashtbl.create 4 in
    Hashtbl.fold (fun _key (k_ty, _) acc ->
      let k_tag = ty_tag k_ty in
      if Hashtbl.mem seen k_tag then acc
      else begin
        Hashtbl.add seen k_tag ();
        emit_map_key_eq_helper_llvm k_ty :: acc
      end) map_instances []
  in
  let map_runtimes =
    Hashtbl.fold (fun _key (k_ty, v_ty) acc ->
      emit_map_runtime_llvm k_ty v_ty :: acc) map_instances []
  in
  let vec_to_list_helpers =
    let seen = Hashtbl.create 4 in
    Hashtbl.fold (fun _key (t_ty, list_ty) acc ->
      let t_tag = ty_tag t_ty in
      if Hashtbl.mem seen t_tag then acc
      else begin
        Hashtbl.add seen t_tag ();
        emit_vec_to_list_helper_llvm t_ty list_ty :: acc
      end) vec_to_list_instances []
  in
  let list_len_helpers =
    let seen = Hashtbl.create 4 in
    Hashtbl.fold (fun _key (t_ty, list_ty) acc ->
      let t_tag = ty_tag t_ty in
      if Hashtbl.mem seen t_tag then acc
      else begin
        Hashtbl.add seen t_tag ();
        emit_list_len_helper_llvm t_ty list_ty :: acc
      end) vec_to_list_instances []
  in
  let vec_to_owned_helpers =
    Hashtbl.fold (fun tag _elem_ty acc ->
      (* emit a helper iff both vec and owned_vec exist for this tag *)
      if Hashtbl.mem vec_instances tag then
        (let elem_ty = Hashtbl.find vec_instances tag in
         emit_vec_to_owned_helper_llvm elem_ty :: acc)
      else acc) owned_vec_instances []
  in
  let owned_vec_to_vec_helpers =
    Hashtbl.fold (fun tag elem_ty acc ->
      if Hashtbl.mem vec_instances tag then
        emit_owned_vec_to_vec_helper_llvm elem_ty :: acc
      else acc) owned_vec_instances []
  in
  let parts =
    [ "; LLVM IR generated by Mere (Phase 5 / 15.3)";
      "target triple = \"" ^ "x86_64-apple-macosx" ^ "\"";  (* clang will retarget if needed *)
      "" ]
    @ (if variant_typedefs = [] then [] else variant_typedefs @ [""])
    @ (if mono_variant_typedefs = [] then [] else mono_variant_typedefs @ [""])
    @ (if record_typedefs = [] then [] else record_typedefs @ [""])
    @ (if mono_record_typedefs = [] then [] else mono_record_typedefs @ [""])
    @ (if tuple_typedefs = [] then [] else tuple_typedefs @ [""])
    @ (if closure_typedefs = [] then [] else closure_typedefs @ [""])
    @ (if !anon_env_typedefs = [] then []
       else List.rev !anon_env_typedefs @ [""])
    @ (if !str_globals = [] then [] else List.rev !str_globals @ [""])
    @ (if !show_string_globals = [] then []
       else List.rev !show_string_globals @ [""])
    @ (if !show_format_globals = [] then []
       else List.rev !show_format_globals @ [""])
    @ format_globals
    @ [ "";
        runtime_decls;
        "";
        region_runtime_helpers;
        "";
        str_concat_helper;
        "" ]
    @ (if vec_runtimes = [] then [] else vec_runtimes @ [""])
    @ (if owned_vec_runtimes = [] then []
       else owned_vec_registry_runtime_llvm :: "" :: owned_vec_runtimes @ [""])
    @ (if !strbuf_used then [strbuf_runtime_llvm; ""] else [])
    @ (if !logger_used then [logger_runtime_llvm; ""] else [])
    @ (if !metrics_used then [metrics_runtime_llvm; ""] else [])
    @ (if map_key_eq_helpers = [] then [] else map_key_eq_helpers @ [""])
    @ (if map_runtimes = [] then [] else map_runtimes @ [""])
    @ (if vec_to_list_helpers = [] then [] else vec_to_list_helpers @ [""])
    @ (if list_len_helpers = [] then [] else list_len_helpers @ [""])
    @ (if vec_iter_helpers = [] then [] else vec_iter_helpers @ [""])
    @ (if vec_fold_helpers = [] then [] else vec_fold_helpers @ [""])
    @ (if vec_map_helpers = [] then [] else vec_map_helpers @ [""])
    @ (if vec_filter_helpers = [] then [] else vec_filter_helpers @ [""])
    @ (if vec_to_owned_helpers = [] then [] else vec_to_owned_helpers @ [""])
    @ (if owned_vec_to_vec_helpers = [] then [] else owned_vec_to_vec_helpers @ [""])
    @ (if fn_defs = [] then [] else fn_defs @ [""])
    @ (if closure_adapters = [] then [] else closure_adapters @ [""])
    @ (if show_fn_defs = [] then [] else show_fn_defs @ [""])
    @ (if anon_adapters = [] then [] else anon_adapters @ [""])
    @ [ "define i32 @main() {";
        body;
        "}";
        "" ]
  in
  String.concat "\n" parts
