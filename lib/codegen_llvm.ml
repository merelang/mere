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
  | Ast.TyFloat -> "float"   (* Phase 43.1: allow float to be used as an fn signature tag *)
  | Ast.TyTuple ts -> "tuple_" ^ String.concat "_" (List.map ty_tag ts)
  | Ast.TyArrow (p, r) -> "closure_" ^ ty_tag p ^ "_" ^ ty_tag r
  | Ast.TyCon (name, []) -> name
  | Ast.TyCon (name, args) -> name ^ "_" ^ String.concat "_" (List.map ty_tag args)
  | Ast.TyRef (_, r, Ast.TyUnit) ->
    (* Region marker — use the region name itself as the tag (same as codegen_c). *)
    r
  | Ast.TyRef (_, _, inner) ->
    (* Phase 19.x: for borrow types `&[mode] R T`, use the tag of the inner T.
       Same policy as codegen_c. *)
    ty_tag inner
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

(* Phase 19.2: map_iter helper instances, keyed by "<K_tag>__<V_tag>". *)
let map_iter_instances : (string, Ast.ty * Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 19.3: vec_sort helper instances, keyed by element T tag. *)
let vec_sort_instances : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4
let vec_fold_instances : (string, Ast.ty * Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.6: vec_map per-(T, U) and vec_filter per-T helper instances. *)
let vec_map_instances : (string, Ast.ty * Ast.ty) Hashtbl.t = Hashtbl.create 4
let vec_filter_instances : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.7: concrete element types of `OwnedVec[T]`. Heap-allocated,
   not region-bound. *)
let owned_vec_instances : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.9: StrBuf[R] usage flag — non-polymorphic, single runtime. *)
let strbuf_used = ref false
(* Phase 25.9: stdlib catchup — emit each helper only when used. *)
let str_split_used_llvm = ref false
let str_join_used_llvm = ref false
let str_count_used_llvm = ref false
let file_io_used_llvm = ref false

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
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyFloat -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, _, inner) -> ty_is_concrete inner
  | Ast.TyVar _ | Ast.TyParam _ -> false  (* Phase 43.1: TyFloat was incorrectly listed as poly *)

(* Walk a Lang type to its LLVM type. Tuples / monomorphic records /
   variants lower to named-struct references (`%tuple_int_int`,
   `%Point`, `%Status`); these are emitted as `type` definitions at the
   top of the module. *)
let rec llvm_ty_of (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyCon ("Vec", args) ->
    (* Phase 15.3: Vec[R, T] — return `%mere_vec_<tag>*` (just `ptr` since
       LLVM pointers are opaque) using the element type T (= ty_tag-sanitized
       name). Registering the element type in vec_instances lets the runtime
       generator pick it up. *)
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
    (* Phase 15.7: OwnedVec[T] — heap-allocated; walk the element type T
       and return an opaque ptr. Register in `owned_vec_instances`. *)
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
  | Ast.TyFloat -> "double"  (* Phase 34.2: IEEE 754 double *)
  | Ast.TyStr -> "ptr"
  | Ast.TyUnit -> "i32"  (* unit becomes int 0 *)
  | Ast.TyTuple ts -> "%" ^ tuple_struct_name ts
  | Ast.TyRef _ -> "ptr"  (* `&R T` is a pointer into the region's buffer *)
  (* Q-012: ThreadHandle wraps a pthread_t (pointer-sized); Channel[T] is a
     heap pointer to the monomorphized channel struct. *)
  | Ast.TyCon ("ThreadHandle", _) -> "i64"
  | Ast.TyCon ("Channel", _) -> "ptr"
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
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyFloat -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, _, inner) -> ty_is_concrete inner
  | Ast.TyVar _ | Ast.TyParam _ -> false  (* Phase 43.1: TyFloat was incorrectly listed as poly *)

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

(* Phase 30.2b (DEFERRED §1.10 fix, LLVM): keep the names and types of
   top-level non-fn lets. emit_expr Var "name" loads @name. *)
let top_globals_llvm : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Phase 32.3 (C1 FFI, LLVM): extern fn declarations. emit_expr's App handler
   dispatches App (Var name, arg) to `call <ret> @name(<arg>)`. *)
let extern_fn_decls_llvm : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Phase 35.2 (DEFERRED §1.2 fix): registry of eta-wrapped nullary factory
   builtins. emit_program emits each entry as
   `define ... @<name>_<tag>_closure_fn` + `@<name>_<tag>_as_value = constant ...`. *)
let eta_adapters_llvm : (string, string * Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Phase 38.C (DEFERRED §1.2 A2): syntactic eta-expansion for multi-arg curried
   builtins when used in value position (same logic as the helper of the same
   name in codegen_c.ml). Routes through an anonymous Fun adapter + each
   builtin's direct-call fast path (line 3104 / 3147 etc.). *)
let synthesize_curried_eta_llvm (name : string) (arrow_ty : Ast.ty) (loc : Loc.t)
    : Ast.expr =
  let mk node ty = Ast.{ node; ty = Some ty; loc } in
  let rec uncurry t =
    match Ast.walk t with
    | Ast.TyArrow (a, b) ->
      let args, ret = uncurry b in (a :: args, ret)
    | other -> ([], other)
  in
  let arg_tys, ret_ty = uncurry arrow_ty in
  let n = List.length arg_tys in
  if n = 0 then
    raise (Codegen_error (loc, name ^ ": cannot eta-expand non-arrow type"));
  let rec build_app i acc acc_ty =
    if i >= n then acc
    else
      let arg_ty = List.nth arg_tys i in
      let arg_node = mk (Ast.Var (Printf.sprintf "__arg%d" i)) arg_ty in
      let new_ty =
        match Ast.walk acc_ty with
        | Ast.TyArrow (_, b) -> b
        | _ -> ret_ty
      in
      build_app (i + 1) (mk (Ast.App (acc, arg_node)) new_ty) new_ty
  in
  let inner_apps = build_app 0 (mk (Ast.Var name) arrow_ty) arrow_ty in
  let rec wrap i body_acc body_ty =
    if i < 0 then body_acc
    else
      let arg_ty = List.nth arg_tys i in
      let fn_ty = Ast.TyArrow (arg_ty, body_ty) in
      let fn_node =
        mk (Ast.Fun (Printf.sprintf "__arg%d" i, Some arg_ty, body_acc)) fn_ty
      in
      wrap (i - 1) fn_node fn_ty
  in
  wrap (n - 1) inner_apps ret_ty

(* Phase 25.5: per-instantiation specialization (LLVM port of Phase 23.3).
   If a poly fn is called at 2+ distinct concrete arrow types, it's emitted
   once per instantiation with a mangled name (`base__T1__T2__...`).
   Populated by resolve_fn_types; consulted at call sites by emit_expr
   to dispatch to the correct mangled name. *)
let multi_inst_fns_llvm : (string, Ast.ty list) Hashtbl.t = Hashtbl.create 4

(* Phase 25.5: mangle a fn name with its concrete arrow type tag. *)
let mangled_inst_name_llvm (base : string) (arrow : Ast.ty) : string =
  let rec collect_tys t acc =
    match Ast.walk t with
    | Ast.TyArrow (a, b) -> collect_tys b (a :: acc)
    | _ -> List.rev (t :: acc)
  in
  let tys = collect_tys arrow [] in
  base ^ "__" ^ String.concat "__" (List.map ty_tag tys)

(* Phase 25.3: inner-fn lifting (port from codegen_c). Inner Let-bound
   fns / Let_rec are lifted out to top-level @-named fns at codegen
   time, with their captured free vars prepended as parameters. The
   in-body Var dispatch uses inner_lifts to find the lifted name + capture
   list. Per-host scope (inner_lifts_by_host) avoids name clashes when
   two host fns both have `let rec loop = ...`. *)
type lifted_inner_llvm = {
  lifted_name : string;
  captures    : (string * Ast.ty) list;
}
let inner_lifts_llvm : (string, lifted_inner_llvm) Hashtbl.t = Hashtbl.create 8
let inner_lifts_by_host_llvm : (string, (string, lifted_inner_llvm) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 8

(* Phase 39.A2 (LLVM port): generate per-fn env struct + adapter. At each use
   site, alloc the env, store capture values, and build the closure value. *)
let inner_lift_closures_emitted_llvm : (string, unit) Hashtbl.t = Hashtbl.create 4
let inner_lift_closure_pending_llvm :
  (string * (string * Ast.ty) list * Ast.ty * Ast.ty) list ref = ref []
let set_inner_lifts_for_host_llvm (host : string) : unit =
  Hashtbl.reset inner_lifts_llvm;
  (match Hashtbl.find_opt inner_lifts_by_host_llvm host with
   | Some tbl -> Hashtbl.iter (fun k v -> Hashtbl.add inner_lifts_llvm k v) tbl
   | None -> ())

type lifted_fn_llvm = {
  l_name      : string;
  l_captures  : (string * Ast.ty) list;
  l_param     : string;
  l_param_ty  : Ast.ty;
  l_body      : Ast.expr;
  l_return_ty : Ast.ty;
  l_host      : string;
}

let inner_fn_counter_llvm = ref 0
let fresh_inner_name_llvm (base : string) : string =
  let n = !inner_fn_counter_llvm in
  incr inner_fn_counter_llvm;
  Printf.sprintf "__lifted_%s_%d" base n

(* Phase 25.3: collect lifted_fn_llvm during walk; emit them at the end
   of emit_program (similar to top-level fns). *)
let lifted_fns_llvm : lifted_fn_llvm list ref = ref []

(* Phase 25.3: name of the currently-emitting top-level (or lifted) fn,
   so anonymous-Fun closures queued in pending_closures can remember
   which host scope they belong to (their inner_lifts_llvm view). *)
let current_host_fn_llvm : string ref = ref ""

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
  mutable ce_host : string;  (* Phase 25.3: host scope at queue time *)
}
(* Phase 38.G-1 (DEFERRED §1.3 Level 1): auto-Drop static check helpers.
   Same logic as codegen_c.ml; see that file for the design rationale. *)
let rec ty_contains_owned_vec_llvm (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyCon ("OwnedVec", _) -> true
  | Ast.TyCon (_, args) -> List.exists ty_contains_owned_vec_llvm args
  | Ast.TyTuple ts -> List.exists ty_contains_owned_vec_llvm ts
  | Ast.TyArrow (a, b) ->
    ty_contains_owned_vec_llvm a || ty_contains_owned_vec_llvm b
  | Ast.TyRef (_, _, t') -> ty_contains_owned_vec_llvm t'
  | _ -> false

let rec var_appears_in_llvm (v : string) (e : Ast.expr) : bool =
  let g = var_appears_in_llvm v in
  match e.Ast.node with
  | Ast.Var n -> n = v
  | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
  | Ast.Unit_lit -> false
  | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
  | Ast.App (a, b) -> g a || g b
  | Ast.Neg a | Ast.Annot (a, _) | Ast.Field_get (a, _) -> g a
  | Ast.Let (pat, value, body) ->
    g value || (not (List.mem v (pattern_vars pat)) && g body)
  | Ast.Let_rec (bs, body) ->
    let names = List.map fst bs in
    List.exists (fun (_, e') -> g e') bs
    || (not (List.mem v names) && g body)
  | Ast.With (n, value, body) -> g value || (n <> v && g body)
  | Ast.If (c, t, e_) -> g c || g t || g e_
  | Ast.Fun (param, _, body) -> param <> v && g body
  | Ast.Constr (_, Some a) -> g a
  | Ast.Constr (_, None) -> false
  | Ast.Match (s, arms) ->
    g s
    || List.exists (fun (pat, gd, b) ->
       (match gd with Some ge -> g ge | None -> false)
       || (not (List.mem v (pattern_vars pat)) && g b)) arms
  | Ast.Tuple es -> List.exists g es
  | Ast.Record_lit (_, fs) -> List.exists (fun (_, e') -> g e') fs
  | Ast.Record_update (a, fs) -> g a || List.exists (fun (_, e') -> g e') fs
  | Ast.Region_block (_, b) -> g b
  | Ast.Ref (_, _, a) -> g a

let rec no_value_leak_llvm (v : string) (e : Ast.expr) : bool =
  let g = no_value_leak_llvm v in
  match e.Ast.node with
  | Ast.Var _ | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _
  | Ast.Str_lit _ | Ast.Unit_lit -> true
  | Ast.Tuple es ->
    List.for_all (fun e' -> not (var_appears_in_llvm v e') && g e') es
  | Ast.Constr (_, Some a) -> not (var_appears_in_llvm v a) && g a
  | Ast.Constr (_, None) -> true
  | Ast.Record_lit (_, fs) ->
    List.for_all (fun (_, e') -> not (var_appears_in_llvm v e') && g e') fs
  | Ast.Record_update (a, fs) ->
    not (var_appears_in_llvm v a)
    && List.for_all (fun (_, e') -> not (var_appears_in_llvm v e') && g e') fs
  | Ast.Fun (param, _, fbody) ->
    param = v || not (var_appears_in_llvm v fbody)
  | Ast.Annot (a, _) | Ast.Neg a | Ast.Field_get (a, _) -> g a
  | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
  | Ast.App (a, b) -> g a && g b
  | Ast.Let (pat, value, body) ->
    g value && (List.mem v (pattern_vars pat) || g body)
  | Ast.Let_rec (bs, body) ->
    let names = List.map fst bs in
    List.for_all (fun (_, v') -> g v') bs
    && (List.mem v names || g body)
  | Ast.If (c, t, e_) -> g c && g t && g e_
  | Ast.Match (s, arms) ->
    g s
    && List.for_all (fun (pat, gd, b) ->
       (match gd with Some ge -> g ge | None -> true)
       && (List.mem v (pattern_vars pat) || g b)) arms
  | Ast.With (n, value, body) -> g value && (n = v || g body)
  | Ast.Region_block (_, b) -> g b
  | Ast.Ref (_, _, a) -> g a

let rec tail_does_not_return_v_llvm (v : string) (e : Ast.expr) : bool =
  match e.Ast.node with
  | Ast.Var n -> n <> v
  | Ast.Let (pat, _, body) ->
    List.mem v (pattern_vars pat) || tail_does_not_return_v_llvm v body
  | Ast.Let_rec (bs, body) ->
    List.exists (fun (n, _) -> n = v) bs
    || tail_does_not_return_v_llvm v body
  | Ast.If (_, t, e_) ->
    tail_does_not_return_v_llvm v t && tail_does_not_return_v_llvm v e_
  | Ast.Match (_, arms) ->
    List.for_all (fun (pat, _, b) ->
       List.mem v (pattern_vars pat)
       || tail_does_not_return_v_llvm v b) arms
  | Ast.With (n, _, body) -> n = v || tail_does_not_return_v_llvm v body
  | Ast.Region_block (_, body) -> tail_does_not_return_v_llvm v body
  | Ast.Annot (a, _) -> tail_does_not_return_v_llvm v a
  | _ ->
    let tail_ty = match e.Ast.ty with
      | Some t -> Ast.walk t
      | None -> Ast.TyUnit
    in
    not (ty_contains_owned_vec_llvm tail_ty)

let rec is_trivial_ty_llvm (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyFloat -> true
  | Ast.TyTuple ts -> List.for_all is_trivial_ty_llvm ts
  | _ -> false

let collect_tainted_names_llvm (v : string) (body : Ast.expr) : string list =
  let tainted = ref [v] in
  let any_tainted_in e =
    List.exists (fun n -> var_appears_in_llvm n e) !tainted
  in
  let value_propagates_taint value =
    let vty = match value.Ast.ty with
      | Some t -> Ast.walk t
      | None -> Ast.TyUnit
    in
    (not (is_trivial_ty_llvm vty)) && any_tainted_in value
  in
  let rec walk e =
    match e.Ast.node with
    | Ast.Let (pat, value, body') ->
      walk value;
      if value_propagates_taint value then
        tainted := pattern_vars pat @ !tainted;
      walk body'
    | Ast.Let_rec (bs, body') ->
      List.iter (fun (_, v') -> walk v') bs;
      if List.exists (fun (_, v') -> value_propagates_taint v') bs then
        tainted := List.map fst bs @ !tainted;
      walk body'
    | Ast.With (n, value, body') ->
      walk value;
      if value_propagates_taint value then tainted := n :: !tainted;
      walk body'
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk a; walk b
    | Ast.Neg a | Ast.Annot (a, _) | Ast.Field_get (a, _) -> walk a
    | Ast.If (c, t, e_) -> walk c; walk t; walk e_
    | Ast.Fun (_, _, b) -> walk b
    | Ast.Constr (_, Some a) -> walk a
    | Ast.Match (s, arms) ->
      walk s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk ge | None -> ());
        walk b) arms
    | Ast.Tuple es -> List.iter walk es
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e') -> walk e') fs
    | Ast.Record_update (a, fs) ->
      walk a; List.iter (fun (_, e') -> walk e') fs
    | Ast.Region_block (_, b) -> walk b
    | Ast.Ref (_, _, a) -> walk a
    | _ -> ()
  in
  walk body;
  !tainted

let rec tail_does_not_return_any_llvm (tainted : string list) (e : Ast.expr) : bool =
  match e.Ast.node with
  | Ast.Var n -> not (List.mem n tainted)
  | Ast.Let (_, _, body) -> tail_does_not_return_any_llvm tainted body
  | Ast.Let_rec (_, body) -> tail_does_not_return_any_llvm tainted body
  | Ast.If (_, t, e_) ->
    tail_does_not_return_any_llvm tainted t
    && tail_does_not_return_any_llvm tainted e_
  | Ast.Match (_, arms) ->
    List.for_all (fun (_, _, b) -> tail_does_not_return_any_llvm tainted b) arms
  | Ast.With (_, _, body) -> tail_does_not_return_any_llvm tainted body
  | Ast.Region_block (_, body) -> tail_does_not_return_any_llvm tainted body
  | Ast.Annot (a, _) -> tail_does_not_return_any_llvm tainted a
  | _ ->
    let tail_ty = match e.Ast.ty with
      | Some t -> Ast.walk t
      | None -> Ast.TyUnit
    in
    not (ty_contains_owned_vec_llvm tail_ty)

let rec no_tainted_leak_llvm (tainted : string list) (e : Ast.expr) : bool =
  let g = no_tainted_leak_llvm tainted in
  let appears e' = List.exists (fun n -> var_appears_in_llvm n e') tainted in
  match e.Ast.node with
  | Ast.Var _ | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _
  | Ast.Str_lit _ | Ast.Unit_lit -> true
  | Ast.Tuple es ->
    List.for_all (fun e' -> not (appears e') && g e') es
  | Ast.Constr (_, Some a) -> not (appears a) && g a
  | Ast.Constr (_, None) -> true
  | Ast.Record_lit (_, fs) ->
    List.for_all (fun (_, e') -> not (appears e') && g e') fs
  | Ast.Record_update (a, fs) ->
    not (appears a)
    && List.for_all (fun (_, e') -> not (appears e') && g e') fs
  | Ast.Fun (param, _, fbody) ->
    List.mem param tainted || g fbody
  | Ast.Annot (a, _) | Ast.Neg a | Ast.Field_get (a, _) -> g a
  | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
  | Ast.App (a, b) -> g a && g b
  | Ast.Let (_, value, body) -> g value && g body
  | Ast.Let_rec (bs, body) ->
    List.for_all (fun (_, v') -> g v') bs && g body
  | Ast.If (c, t, e_) -> g c && g t && g e_
  | Ast.Match (s, arms) ->
    g s
    && List.for_all (fun (_, gd, b) ->
       (match gd with Some ge -> g ge | None -> true) && g b) arms
  | Ast.With (_, value, body) -> g value && g body
  | Ast.Region_block (_, b) -> g b
  | Ast.Ref (_, _, a) -> g a

let owned_vec_safe_to_drop_at_scope_llvm (body : Ast.expr) (v : string) : bool =
  let tainted = collect_tainted_names_llvm v body in
  no_tainted_leak_llvm tainted body
  && tail_does_not_return_any_llvm tainted body

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
  (* Phase 25.9 (port of codegen_c Phase 24.4): walk through ALL top-level
     Let chains so a non-Fun Let (e.g., `let path = "/tmp/x"`) doesn't
     break the chain and block subsequent `let rec` from being lifted.
     Fun-valued Lets with P_var → extract as skel + drop from body.
     Other Lets → keep in body + walk rest.
     Phase 37.A: `let _ = while ... ;` desugars to
     `Let (P_wild, Let_rec (bs, call_loop), rest)`. Lift the inner
     Let_rec as top-level skels and replace the value with its body. *)
  let rec go (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, rest) ->
      (match pat.Ast.pnode, value.Ast.node with
       | Ast.P_var name, Ast.Fun (param, _, fn_body) ->
         let more, rest' = go rest in
         { sname = name; sparam = param; sbody = fn_body; sfun = value }
         :: more, rest'
       | _, Ast.Let_rec (bindings, lr_body) ->
         let lr_skels =
           List.map (fun (n, v) ->
             match v.Ast.node with
             | Ast.Fun (p, _, fb) ->
               { sname = n; sparam = p; sbody = fb; sfun = v }
             | _ ->
               raise (Codegen_error (v.Ast.loc,
                 "let rec inside top-level let value must bind a single-arg function")))
             bindings
         in
         let more, rest' = go { e with Ast.node = Ast.Let (pat, lr_body, rest) } in
         lr_skels @ more, rest'
       | _ ->
         let more, rest' = go rest in
         more, { e with Ast.node = Ast.Let (pat, value, rest') })
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

(* Phase 25.5: collect ALL distinct concrete arrow types `name` is called
   at across the given exprs. Multi-pass resolve uses this to detect
   multi-instantiation (LLVM port of codegen_c's find_all_concrete_arrows_in). *)
let find_all_concrete_arrows_in_llvm (name : string) (exprs : Ast.expr list) : Ast.ty list =
  let seen : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4 in
  let rec go (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.Var n when n = name ->
       (match e.Ast.ty with
        | Some t when ty_is_concrete (Ast.walk t) ->
          let walked = Ast.walk t in
          (match walked with
           | Ast.TyArrow _ ->
             let key = Ast.pp_ty walked in
             if not (Hashtbl.mem seen key) then Hashtbl.add seen key walked
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
  List.iter go exprs;
  Hashtbl.fold (fun _ v acc -> v :: acc) seen []

(* Phase 25.5: deep-clone an expression with fresh tyvars (LLVM port of
   codegen_c's clone_with_fresh_tyvars). Used for per-instantiation
   specialization — each clone gets its own fresh tyvars so we can unify
   the clone's Fun.ty with a different concrete type independently. *)
let clone_with_fresh_tyvars_llvm (e : Ast.expr) : Ast.expr =
  let map : (int, Ast.ty) Hashtbl.t = Hashtbl.create 16 in
  let rec clone_ty t =
    match Ast.walk t with
    | Ast.TyVar v ->
      (match Hashtbl.find_opt map v.id with
       | Some fresh -> fresh
       | None ->
         let fresh = Typer.fresh_var () in
         Hashtbl.add map v.id fresh;
         fresh)
    | Ast.TyParam _ as t -> t
    | (Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit) as t -> t
    | Ast.TyArrow (a, b) -> Ast.TyArrow (clone_ty a, clone_ty b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map clone_ty ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map clone_ty args)
    | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, clone_ty inner)
  in
  let clone_ty_opt = function None -> None | Some t -> Some (clone_ty t) in
  let rec clone_expr (e : Ast.expr) : Ast.expr =
    { Ast.loc = e.Ast.loc;
      ty = clone_ty_opt e.Ast.ty;
      node = clone_node e.Ast.node }
  and clone_node = function
    | (Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _
       | Ast.Str_lit _ | Ast.Unit_lit | Ast.Var _) as n -> n
    | Ast.Bin (op, a, b) -> Ast.Bin (op, clone_expr a, clone_expr b)
    | Ast.Cmp (op, a, b) -> Ast.Cmp (op, clone_expr a, clone_expr b)
    | Ast.Logic (op, a, b) -> Ast.Logic (op, clone_expr a, clone_expr b)
    | Ast.Neg a -> Ast.Neg (clone_expr a)
    | Ast.Let (p, v, b) -> Ast.Let (clone_pattern p, clone_expr v, clone_expr b)
    | Ast.Let_rec (bs, b) ->
      Ast.Let_rec (List.map (fun (n, e) -> (n, clone_expr e)) bs, clone_expr b)
    | Ast.With (n, v, b) -> Ast.With (n, clone_expr v, clone_expr b)
    | Ast.If (c, t, e_) -> Ast.If (clone_expr c, clone_expr t, clone_expr e_)
    | Ast.Fun (n, t_opt, b) ->
      Ast.Fun (n, (match t_opt with None -> None | Some t -> Some (clone_ty t)),
        clone_expr b)
    | Ast.App (a, b) -> Ast.App (clone_expr a, clone_expr b)
    | Ast.Annot (a, t) -> Ast.Annot (clone_expr a, clone_ty t)
    | Ast.Constr (n, Some a) -> Ast.Constr (n, Some (clone_expr a))
    | Ast.Constr (n, None) -> Ast.Constr (n, None)
    | Ast.Match (s, arms) ->
      Ast.Match (clone_expr s,
        List.map (fun (p, g, b) ->
          (clone_pattern p,
           (match g with None -> None | Some e -> Some (clone_expr e)),
           clone_expr b)) arms)
    | Ast.Tuple es -> Ast.Tuple (List.map clone_expr es)
    | Ast.Region_block (n, b) -> Ast.Region_block (n, clone_expr b)
    | Ast.Ref (m, r, a) -> Ast.Ref (m, r, clone_expr a)
    | Ast.Record_lit (n, fs) ->
      Ast.Record_lit (n, List.map (fun (k, v) -> (k, clone_expr v)) fs)
    | Ast.Field_get (a, f) -> Ast.Field_get (clone_expr a, f)
    | Ast.Record_update (a, fs) ->
      Ast.Record_update (clone_expr a,
        List.map (fun (k, v) -> (k, clone_expr v)) fs)
  and clone_pattern p =
    { Ast.ploc = p.Ast.ploc; pnode = clone_pattern_node p.Ast.pnode }
  and clone_pattern_node = function
    | (Ast.P_wild | Ast.P_var _ | Ast.P_int _ | Ast.P_bool _
       | Ast.P_str _ | Ast.P_unit) as n -> n
    | Ast.P_constr (c, Some sub) -> Ast.P_constr (c, Some (clone_pattern sub))
    | Ast.P_constr (c, None) -> Ast.P_constr (c, None)
    | Ast.P_tuple ps -> Ast.P_tuple (List.map clone_pattern ps)
    | Ast.P_record (n, fs) ->
      Ast.P_record (n, List.map (fun (k, v) -> (k, clone_pattern v)) fs)
    | Ast.P_as (p, n) -> Ast.P_as (clone_pattern p, n)
    | Ast.P_or (a, b) -> Ast.P_or (clone_pattern a, clone_pattern b)
  in
  clone_expr e

let resolve_fn_types (skels : fn_skel list) (root : Ast.expr) : fn_decl list =
  (* Phase 21.2 multi-pass + Phase 25.5 multi-instantiation specialization
     (LLVM port of Phase 23.3). See codegen_c.ml for design notes. *)
  let resolved : (string, Ast.ty) Hashtbl.t = Hashtbl.create 16 in
  let progress = ref true in
  Hashtbl.reset multi_inst_fns_llvm;
  let multi_specs : (string, (Ast.ty * Ast.expr) list) Hashtbl.t =
    Hashtbl.create 4
  in
  (* Phase 43: re-scan multi-inst fns each pass to catch chained poly
     instantiations (see codegen_c.ml for design). *)
  let make_spec arrow s =
    let cloned_fun = clone_with_fresh_tyvars_llvm s.sfun in
    let clone_fun_ty =
      match cloned_fun.Ast.ty with
      | Some t -> Ast.walk t
      | None -> Ast.TyUnit
    in
    (try Typer.unify Loc.dummy clone_fun_ty arrow with _ -> ());
    let cloned_body =
      match cloned_fun.Ast.node with
      | Ast.Fun (_, _, b) -> b
      | _ ->
        raise (Codegen_error (s.sfun.Ast.loc,
          "multi-inst clone: expected Fun at root"))
    in
    (arrow, cloned_body)
  in
  while !progress do
    progress := false;
    List.iter (fun s ->
      let extra_exprs () =
        Hashtbl.fold (fun _ specs acc ->
          List.fold_left (fun acc (_, body) -> body :: acc) acc specs
        ) multi_specs []
      in
      if Hashtbl.mem resolved s.sname then ()
      else if Hashtbl.mem multi_specs s.sname then begin
        (* Phase 43 fix (DEFERRED §1.7): re-scan multi-inst fns each pass. *)
        let all = find_all_concrete_arrows_in_llvm s.sname (root :: extra_exprs ()) in
        let existing = Hashtbl.find multi_specs s.sname in
        let existing_arrows = List.map fst existing in
        let new_arrows = List.filter (fun a ->
          let a_str = Ast.pp_ty (Ast.walk a) in
          not (List.exists (fun e -> Ast.pp_ty (Ast.walk e) = a_str) existing_arrows)) all
        in
        if new_arrows <> [] then begin
          let new_specs = List.map (fun a -> make_spec a s) new_arrows in
          Hashtbl.replace multi_specs s.sname (existing @ new_specs);
          Hashtbl.replace multi_inst_fns_llvm s.sname (existing_arrows @ new_arrows);
          progress := true
        end
      end
      else begin
        let fun_ty =
          match s.sfun.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
        in
        if ty_is_concrete fun_ty then begin
          Hashtbl.add resolved s.sname fun_ty;
          progress := true
        end else
          let all = find_all_concrete_arrows_in_llvm s.sname (root :: extra_exprs ()) in
          match all with
          | _ :: _ ->
            if List.length all > 1 then begin
              Hashtbl.add multi_inst_fns_llvm s.sname all;
              let specs = List.map (fun arrow -> make_spec arrow s) all in
              Hashtbl.add multi_specs s.sname specs;
              progress := true
            end else begin
              (try Typer.unify Loc.dummy fun_ty (List.hd all) with _ -> ());
              Hashtbl.add resolved s.sname (List.hd all);
              progress := true
            end
          | [] -> ()
      end
    ) skels
  done;
  List.concat_map (fun s ->
    match Hashtbl.find_opt multi_specs s.sname with
    | Some specs ->
      List.map (fun (arrow, cloned_body) ->
        match Ast.walk arrow with
        | Ast.TyArrow (p, r) ->
          { name = mangled_inst_name_llvm s.sname arrow;
            param = s.sparam;
            body = cloned_body;
            param_ty = Ast.walk p;
            return_ty = Ast.walk r }
        | other ->
          raise (Codegen_error (s.sfun.Ast.loc,
            Printf.sprintf "function `%s` has non-arrow inferred type `%s`"
              s.sname (Ast.pp_ty other)))
      ) specs
    | None ->
      (match Hashtbl.find_opt resolved s.sname with
       | None -> []
       | Some (Ast.TyArrow (p, r)) ->
         [{ name = s.sname; param = s.sparam; body = s.sbody;
            param_ty = Ast.walk p; return_ty = Ast.walk r }]
       | Some _ ->
         raise (Codegen_error (s.sfun.Ast.loc,
           Printf.sprintf "function `%s` has non-arrow inferred type" s.sname)))
  ) skels

(* Phase 25.3: lookup a free var's concrete type by scanning the inner
   fn body. Mirrors codegen_c's lookup_var_ty. *)
let lookup_var_ty_llvm (body : Ast.expr) (name : string) : Ast.ty =
  let found = ref Ast.TyUnit in
  let stop = ref false in
  let rec go (e : Ast.expr) =
    if !stop then () else
    match e.Ast.node with
    | Ast.Var n when n = name ->
      (match e.Ast.ty with
       | Some t when ty_is_concrete (Ast.walk t) ->
         found := Ast.walk t; stop := true
       | _ -> ())
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
      go s; List.iter (fun (_, g, b) ->
        (match g with Some ge -> go ge | None -> ()); go b) arms
    | Ast.Tuple es -> List.iter go es
    | Ast.Region_block (_, b) -> go b
    | Ast.Ref (_, _, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  go body; !found

(* Phase 25.3: lift inner Let-Fun / Let_rec to top-level lifted fns.
   Same algorithm as codegen_c's lift_inner_fns, adapted to populate
   inner_lifts_by_host_llvm + lifted_fns_llvm. *)
let lift_inner_fns_llvm (toplevel_names : string list) (fns : fn_decl list) : unit =
  Hashtbl.reset inner_lifts_llvm;
  Hashtbl.reset inner_lifts_by_host_llvm;
  inner_fn_counter_llvm := 0;
  lifted_fns_llvm := [];
  let builtin_names = List.map fst Typer.initial_env in
  let known = ref (toplevel_names @ builtin_names) in
  let current_host = ref "" in
  let lift_one _host_param host_locals n p fn_body value_loc value_ty =
    let effective_known =
      List.filter (fun k -> not (List.mem k host_locals)) !known
    in
    let body_fvs = free_vars fn_body (p :: effective_known) in
    let captures =
      List.map (fun fv ->
        let ty = lookup_var_ty_llvm fn_body fv in
        (fv, ty)) body_fvs
    in
    let lifted_name = fresh_inner_name_llvm n in
    let return_ty, param_ty =
      match value_ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyArrow (a, b) -> (Ast.walk b, Ast.walk a)
         | _ -> raise (Codegen_error (value_loc, "inner fn has non-arrow type")))
      | None -> raise (Codegen_error (value_loc, "inner fn missing type"))
    in
    let lf = {
      l_name = lifted_name; l_captures = captures;
      l_param = p; l_param_ty = param_ty;
      l_body = fn_body; l_return_ty = return_ty;
      l_host = !current_host;
    } in
    lifted_fns_llvm := lf :: !lifted_fns_llvm;
    let entry = { lifted_name; captures } in
    Hashtbl.replace inner_lifts_llvm n entry;
    let host_tbl =
      match Hashtbl.find_opt inner_lifts_by_host_llvm !current_host with
      | Some t -> t
      | None ->
        let t = Hashtbl.create 4 in
        Hashtbl.add inner_lifts_by_host_llvm !current_host t;
        t
    in
    Hashtbl.replace host_tbl n entry;
    known := lifted_name :: !known;
    fn_body
  in
  let rec walk (host_param : string) (host_locals : string list) (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, body) ->
      (match pat.Ast.pnode, value.Ast.node with
       | Ast.P_var n, Ast.Fun (p, _, fn_body) ->
         let fn_body = lift_one host_param host_locals n p fn_body value.Ast.loc value.Ast.ty in
         walk p [] fn_body;
         walk host_param (n :: host_locals) body
       | _ ->
         walk host_param host_locals value;
         walk host_param (pattern_vars pat @ host_locals) body)
    | Ast.Let_rec (bindings, body) ->
      let rec_names = List.map fst bindings in
      let fn_specs = List.map (fun (n, value) ->
        match value.Ast.node with
        | Ast.Fun (p, _, fn_body) ->
          (n, p, fn_body, value.Ast.loc, value.Ast.ty)
        | _ ->
          raise (Codegen_error (value.Ast.loc,
            "inner let-rec binding must be a single-arg fn"))) bindings
      in
      known := rec_names @ !known;
      List.iter (fun (n, p, fb, loc, vty) ->
        let _ = lift_one host_param host_locals n p fb loc vty in ()) fn_specs;
      List.iter (fun (_, p, fb, _, _) -> walk p [] fb) fn_specs;
      walk host_param (rec_names @ host_locals) body
    | Ast.Fun (_, _, b) -> walk host_param host_locals b
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk host_param host_locals a; walk host_param host_locals b
    | Ast.Neg a | Ast.Annot (a, _) -> walk host_param host_locals a
    | Ast.With (_, v, b) -> walk host_param host_locals v; walk host_param host_locals b
    | Ast.If (c, t, e_) -> walk host_param host_locals c; walk host_param host_locals t; walk host_param host_locals e_
    | Ast.Constr (_, Some a) -> walk host_param host_locals a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk host_param host_locals s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk host_param host_locals ge | None -> ());
        walk host_param host_locals b) arms
    | Ast.Tuple es -> List.iter (walk host_param host_locals) es
    | Ast.Region_block (_, b) -> walk host_param host_locals b
    | Ast.Ref (_, _, a) -> walk host_param host_locals a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk host_param host_locals e) fs
    | Ast.Field_get (a, _) -> walk host_param host_locals a
    | Ast.Record_update (a, fs) ->
      walk host_param host_locals a;
      List.iter (fun (_, e) -> walk host_param host_locals e) fs
  in
  List.iter (fun (f : fn_decl) ->
    current_host := f.name;
    walk f.param [f.param] f.body) fns;
  (* Phase 45 (DEFERRED §8): compute the transitive capture closure to handle
     mutual references between inner-lifted fns (same algorithm as codegen_c).
     See there for details. *)
  let all_lifted = !lifted_fns_llvm in
  let mere_to_lifted : (string, string) Hashtbl.t = Hashtbl.create 8 in
  Hashtbl.iter (fun mname entry ->
    Hashtbl.replace mere_to_lifted mname entry.lifted_name) inner_lifts_llvm;
  let captures_map : (string, (string * Ast.ty) list) Hashtbl.t =
    Hashtbl.create 8
  in
  List.iter (fun lf ->
    let filtered = List.filter (fun (n, _) ->
      not (Hashtbl.mem mere_to_lifted n)) lf.l_captures in
    Hashtbl.replace captures_map lf.l_name filtered) all_lifted;
  let rec scan_for_called called_acc (e : Ast.expr) cur_name =
    let acc = ref called_acc in
    (match e.Ast.node with
     | Ast.Var n when Hashtbl.mem mere_to_lifted n
                   && Hashtbl.find mere_to_lifted n <> cur_name ->
       let cl_name = Hashtbl.find mere_to_lifted n in
       if not (List.mem cl_name !acc) then acc := cl_name :: !acc
     | _ -> ());
    let recurse sub = acc := scan_for_called !acc sub cur_name in
    (match e.Ast.node with
     | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
     | Ast.Unit_lit | Ast.Var _ -> ()
     | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
     | Ast.App (a, b) -> recurse a; recurse b
     | Ast.Neg a | Ast.Annot (a, _) -> recurse a
     | Ast.Let (_, v, b) -> recurse v; recurse b
     | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> recurse v) bs; recurse b
     | Ast.With (_, v, b) -> recurse v; recurse b
     | Ast.If (c, t, e_) -> recurse c; recurse t; recurse e_
     | Ast.Fun (_, _, b) -> recurse b
     | Ast.Constr (_, Some a) -> recurse a
     | Ast.Constr (_, None) -> ()
     | Ast.Match (s, arms) ->
       recurse s;
       List.iter (fun (_, g, b) ->
         (match g with Some ge -> recurse ge | None -> ()); recurse b) arms
     | Ast.Tuple es -> List.iter recurse es
     | Ast.Region_block (_, b) -> recurse b
     | Ast.Ref (_, _, a) -> recurse a
     | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> recurse e) fs
     | Ast.Field_get (a, _) -> recurse a
     | Ast.Record_update (a, fs) -> recurse a;
       List.iter (fun (_, e) -> recurse e) fs);
    !acc
  in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter (fun lf ->
      let called_inner = scan_for_called [] lf.l_body lf.l_name in
      let cur_caps = Hashtbl.find captures_map lf.l_name in
      let new_caps = ref cur_caps in
      List.iter (fun called_lifted_name ->
        let other_caps = Hashtbl.find captures_map called_lifted_name in
        List.iter (fun (cap_n, cap_t) ->
          if cap_n = lf.l_param then ()
          else if Hashtbl.mem mere_to_lifted cap_n then ()
          else if List.mem_assoc cap_n !new_caps then ()
          else begin
            new_caps := !new_caps @ [(cap_n, cap_t)];
            changed := true
          end
        ) other_caps
      ) called_inner;
      Hashtbl.replace captures_map lf.l_name !new_caps
    ) all_lifted
  done;
  lifted_fns_llvm := List.map (fun lf ->
    let new_caps = Hashtbl.find captures_map lf.l_name in
    { lf with l_captures = new_caps }) all_lifted;
  Hashtbl.iter (fun _host tbl ->
    Hashtbl.iter (fun mere_n entry ->
      let new_caps = Hashtbl.find captures_map entry.lifted_name in
      Hashtbl.replace tbl mere_n { entry with captures = new_caps }
    ) tbl) inner_lifts_by_host_llvm;
  Hashtbl.iter (fun mere_n entry ->
    let new_caps = Hashtbl.find captures_map entry.lifted_name in
    Hashtbl.replace inner_lifts_llvm mere_n { entry with captures = new_caps }
  ) inner_lifts_llvm

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
       Hashtbl.find Typer.types name = 0 (* arity 0 — monomorphic *) &&
       (* Only real variants have a shape; skip builtin runtime types such as
          Q-012's ThreadHandle that live in the arity registry but are not
          user-declared variants. *)
       Hashtbl.mem Exhaustive.type_variants name
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
     | Ast.Constr (raw_cname, _) ->
       (* Phase 41: canonicalize `M.Foo` → `Foo` for Typer lookup *)
       let cname = Ast.canonical_ctor raw_cname in
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

(* Phase 25.0: variant payload is now BOXED (always ptr).
   Each constructor's payload is heap-allocated in the region and the
   variant struct stores `{ i32 tag, ptr payload }`. This removes the
   Phase 5 MVP restriction that all constructors must share a payload
   type — different-typed payloads now work because they're stored
   uniformly as pointers (with per-ctor bitcast at Constr / Match). *)
let variant_has_any_payload (name : string) : bool =
  let vs = variant_shape name in
  List.exists (fun (_, p) -> p <> None) vs

let emit_variant_typedef (name : string) : string =
  let vs = variant_shape name in
  List.iteri (fun i (cname, _) ->
    Hashtbl.replace variant_tags cname i) vs;
  let has_payload = variant_has_any_payload name in
  if is_recursive_variant_name name then
    if has_payload then Printf.sprintf "%%%s_node = type { i32, ptr }" name
    else Printf.sprintf "%%%s_node = type { i32 }" name
  else
    if has_payload then Printf.sprintf "%%%s = type { i32, ptr }" name
    else Printf.sprintf "%%%s = type { i32 }" name

(* Variant payload type for an already-substituted variant list (used by
   mono-instance codegen, where we've already applied param→arg subst). *)
let variant_has_any_payload_of (variants : (string * Ast.ty option) list)
    : bool =
  List.exists (fun (_, p) -> p <> None) variants

(* Phase 25.0: per-constructor payload type lookup (replaces the shared
   variant_payload_ty / variant_payload_ty_of). The boxed-payload
   representation lets each constructor have its own type, accessed via
   bitcast at Constr / Match. *)
let ctor_payload_ty (cname : string) : Ast.ty option =
  match Hashtbl.find_opt Typer.constructors cname with
  | Some info -> info.Typer.arg
  | None -> None

(* Specialized typedef for a polymorphic variant instance. *)
let emit_mono_variant_typedef (variant_name : string) (args : Ast.ty list) : string =
  let mono_name = mono_variant_name variant_name args in
  let (params, variants) = Hashtbl.find polymorphic_variants variant_name in
  let svariants = subst_variants params args variants in
  let has_payload = variant_has_any_payload_of svariants in
  if is_recursive_variant_name mono_name then
    if has_payload then Printf.sprintf "%%%s_node = type { i32, ptr }" mono_name
    else Printf.sprintf "%%%s_node = type { i32 }" mono_name
  else
    if has_payload then Printf.sprintf "%%%s = type { i32, ptr }" mono_name
    else Printf.sprintf "%%%s = type { i32 }" mono_name

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
      (* Phase 16.3: also walk into known record field types. For records like
         Logger / Metrics that have closure-typed fields, this lets arrow_pairs
         pick up closure types that only appear through the field. *)
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
(* Does an Eq/Ne on this type need structural comparison (vs a scalar icmp)? *)
let llvm_needs_struct_eq (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyTuple _ -> true
  | Ast.TyCon (name, _) ->
    Hashtbl.mem Typer.records name
    || Hashtbl.mem polymorphic_records name
    || Hashtbl.mem Typer.types name
    || Hashtbl.mem polymorphic_variants name
    || name = "list"
  | _ -> false

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
      (* Phase 25.6: run %x through __lang_str_escape first so output
         matches interp's show_str (backslash-escapes newline / tab /
         backslash / double-quote). *)
      let esc = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_escape(ptr %%x)" esc);
      let p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = alloca ptr" p);
      emit_instr (Printf.sprintf
                    "  call i32 (ptr, ptr, ...) @asprintf(ptr %s, ptr @.fmt_show_str, ptr %s)"
                    p esc);
      let r = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" r p);
      r
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
      (* Phase 25.0: payload is boxed (ptr). Load the ptr, then load the
         tuple struct from it. *)
      let pl_box = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" pl_box pl_p);
      let pl = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load %s, ptr %s" pl payload_struct pl_box);
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
            (* Phase 25.0: payload is boxed (ptr). Load the ptr, then
               dereference to get the payload value. *)
            let ptr_reg = fresh_reg () in
            if recursive then begin
              let pp = fresh_reg () in
              emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %%x, i32 0, i32 1"
                            pp node_ty);
              emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" ptr_reg pp)
            end else
              emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, 1" ptr_reg mono);
            let p_reg = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                          p_reg (llvm_ty_of pty) ptr_reg);
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
            (* Phase 25.0: payload is boxed (ptr). Load the ptr, then
               dereference to get the payload value. *)
            let ptr_reg = fresh_reg () in
            if recursive then begin
              let pp = fresh_reg () in
              emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %%x, i32 0, i32 1"
                            pp node_ty);
              emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" ptr_reg pp)
            end else
              emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, 1" ptr_reg n);
            let p_reg = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                          p_reg (llvm_ty_of pty) ptr_reg);
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

(* Q-012: cast a Mere LLVM value to / from the i64 slot used by the generic
   channel runtime. Every Mere value (i32 / i1 / double / ptr) fits in 8 bytes. *)
let is_aggregate_llty (s : string) : bool =
  String.length s > 0 && s.[0] = '%'

let cast_to_i64 (v : string) (llty : string) : string =
  match llty with
  | "i64" -> v
  | "double" -> let r = fresh_reg () in emit_instr (Printf.sprintf "  %s = bitcast double %s to i64" r v); r
  | "ptr" -> let r = fresh_reg () in emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" r v); r
  | "i1" -> let r = fresh_reg () in emit_instr (Printf.sprintf "  %s = zext i1 %s to i64" r v); r
  | s when is_aggregate_llty s ->
    (* By-value aggregate (tuple / record) — may exceed 8 bytes, so it can't
       ride in the slot directly. Box it on the heap and carry the pointer.
       This keeps the generic i64-slot channel correct for every Send type,
       not just scalars. *)
    let szp = fresh_reg () and sz = fresh_reg () and p = fresh_reg () and r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr null, i32 1" szp s);
    emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" sz szp);
    emit_instr (Printf.sprintf "  %s = call ptr @malloc(i64 %s)" p sz);
    emit_instr (Printf.sprintf "  store %s %s, ptr %s" s v p);
    emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" r p);
    r
  | _ (* i32 (int / unit) *) ->
    let r = fresh_reg () in emit_instr (Printf.sprintf "  %s = sext i32 %s to i64" r v); r

let cast_from_i64 (v : string) (llty : string) : string =
  match llty with
  | "i64" -> v
  | "double" -> let r = fresh_reg () in emit_instr (Printf.sprintf "  %s = bitcast i64 %s to double" r v); r
  | "ptr" -> let r = fresh_reg () in emit_instr (Printf.sprintf "  %s = inttoptr i64 %s to ptr" r v); r
  | "i1" -> let r = fresh_reg () in emit_instr (Printf.sprintf "  %s = trunc i64 %s to i1" r v); r
  | s when is_aggregate_llty s ->
    (* Unbox: the slot holds a pointer to the heap-stored aggregate. *)
    let p = fresh_reg () and r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = inttoptr i64 %s to ptr" p v);
    emit_instr (Printf.sprintf "  %s = load %s, ptr %s" r s p);
    r
  | _ (* i32 *) -> let r = fresh_reg () in emit_instr (Printf.sprintf "  %s = trunc i64 %s to i32" r v); r

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
    (* Phase 25.10 (port of codegen_c): a local binding (env / current_var_types)
       can shadow a stdlib builtin name like `len`. Treat as regular var if
       shadowed; only reject if it's the actual stdlib builtin as a value. *)
    let is_shadowed =
      List.mem_assoc name env
      || List.mem_assoc name !current_var_types
    in
    (* Phase 35.2: nullary factory builtins as first-class value (eta-wrap).
       For vec_new / owned_vec_new / strbuf_new / map_new in value position,
       if the concrete ret_ty is known, register an eta adapter and return
       `@<name>_<tag>_as_value`. If polymorphic, fall through to the next
       unsupported guard. *)
    let is_nullary_factory = name = "vec_new" || name = "owned_vec_new"
                              || name = "strbuf_new" || name = "map_new" in
    let eta_value_str_opt =
      if (not is_shadowed) && is_nullary_factory then
        match e.Ast.ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyArrow (_, ret_ty) when ty_is_concrete (Ast.walk ret_ty) ->
             let ret_ty = Ast.walk ret_ty in
             let ret_tag = ty_tag ret_ty in
             (* Register Vec / OwnedVec / Map / StrBuf so runtime gets emitted *)
             (match Ast.walk ret_ty with
              | Ast.TyCon ("Vec", [_; et]) ->
                let et = Ast.walk et in
                if not (Hashtbl.mem vec_instances (ty_tag et)) then
                  Hashtbl.add vec_instances (ty_tag et) et
              | Ast.TyCon ("OwnedVec", [et]) ->
                let et = Ast.walk et in
                if not (Hashtbl.mem owned_vec_instances (ty_tag et)) then
                  Hashtbl.add owned_vec_instances (ty_tag et) et
              | Ast.TyCon ("StrBuf", _) ->
                strbuf_used := true
              | Ast.TyCon ("Map", [_; k_ty; v_ty]) ->
                let k_ty = Ast.walk k_ty and v_ty = Ast.walk v_ty in
                let kvtag = ty_tag k_ty ^ "__" ^ ty_tag v_ty in
                if not (Hashtbl.mem map_instances kvtag) then
                  Hashtbl.add map_instances kvtag (k_ty, v_ty)
              | _ -> ());
             let adapter = name ^ "_" ^ ret_tag in
             if not (Hashtbl.mem eta_adapters_llvm adapter) then
               Hashtbl.add eta_adapters_llvm adapter (name, ret_ty);
             let cstruct = closure_struct_name Ast.TyUnit ret_ty in
             let r = fresh_reg () in
             emit_instr (Printf.sprintf "  %s = load %%%s, ptr @%s_as_value" r cstruct adapter);
             Some r
           | _ -> None)
        | None -> None
      else None
    in
    let is_curried_collection_builtin =
      name = "vec_push"
      || name = "vec_get" || name = "vec_len"
      || name = "vec_set" || name = "vec_iter" || name = "vec_fold"
      || name = "vec_reverse" || name = "vec_concat" || name = "vec_sort"
      || name = "vec_map" || name = "vec_filter"
      || name = "vec_to_owned" || name = "owned_vec_to_vec"
      || name = "owned_vec_push"
      || name = "owned_vec_get" || name = "owned_vec_len"
      || name = "strbuf_push"
      || name = "strbuf_to_str" || name = "strbuf_len"
      || name = "map_set" || name = "map_get"
      || name = "map_has" || name = "map_len" || name = "map_iter"
    in
    let is_phase38c_target =
      name = "owned_vec_push" || name = "owned_vec_get"
      || name = "vec_push" || name = "vec_get"
      || name = "strbuf_push"
      || name = "map_get" || name = "map_has"
      || name = "map_set" || name = "vec_set"
    in
    let try_eta_llvm () =
      match e.Ast.ty with
      | Some t when ty_is_concrete (Ast.walk t) ->
        (match Ast.walk t with
         | Ast.TyArrow _ as arrow ->
           Some (emit_expr env (synthesize_curried_eta_llvm name arrow e.Ast.loc))
         | _ -> None)
      | _ -> None
    in
    (* Phase 38.A1: value-ification of single-arg builtins *)
    let is_single_arg_value_builtin =
      name = "int_of_str" || name = "str_of_int"
      || name = "str_len" || name = "str_rev" || name = "str_trim"
      || name = "str_unescape"
      || name = "ord" || name = "chr"
      || name = "to_upper" || name = "to_lower"
      || name = "not" || name = "abs" || name = "even" || name = "odd"
      || name = "bool_of_str"
      || name = "float_of_int" || name = "int_of_float"
      || name = "str_of_float" || name = "float_of_str"
      || name = "f_neg" || name = "f_abs"
      || name = "sqrt" || name = "sin" || name = "cos" || name = "tan"
      || name = "print" || name = "fail"
      || name = "fst" || name = "snd"
    in
    let eta38c_opt =
      if not is_shadowed && is_curried_collection_builtin && is_phase38c_target
      then try_eta_llvm ()
      else if not is_shadowed && is_single_arg_value_builtin
      then try_eta_llvm ()
      else None
    in
    if not is_shadowed && is_curried_collection_builtin && eta38c_opt = None then
      unsupported e.Ast.loc
        (name ^ " as a value (Phase 15.3-15.10: curried multi-arg builtin only supports direct application, partial support in progress in Phase 38.C)");
    if not is_shadowed && is_single_arg_value_builtin && eta38c_opt = None then
      unsupported e.Ast.loc
        (name ^ " as a value: type is polymorphic (Phase 38.A1 MVP: work around by wrapping with `fn x -> " ^ name ^ " x`)");
    if not is_shadowed && is_nullary_factory && eta_value_str_opt = None then
      unsupported e.Ast.loc
        (name ^ " as a value: return type is polymorphic, can't monomorphize \
                 (Phase 35.2 MVP: use direct app or manual eta `fn () -> vec_new ()`)");
    if not is_shadowed && (name = "len" || name = "vec_to_list") then
      unsupported e.Ast.loc
        (name ^ " as a value (Phase 15.11/15.12: len / vec_to_list only support direct application)");
    (match eta38c_opt with
     | Some v -> v
     | None ->
    (match eta_value_str_opt with
     | Some v -> v
     | None ->
    (* Phase 34.2: float constants *)
    if not is_shadowed && name = "pi" then "0x400921FB54442D18"
    else if not is_shadowed && name = "e" then "0x4005BF0A8B145769"
    else
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
       (* Phase 25.5: if name is multi-inst, use the mangled spec name. *)
       let dispatch_name =
         if Hashtbl.mem multi_inst_fns_llvm name then mangled_inst_name_llvm name arrow
         else name
       in
       let r0 = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = insertvalue %%%s undef, ptr null, 0" r0 cname);
       let r1 = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, ptr @%s_closure_fn, 1"
                     r1 cname r0 dispatch_name);
       r1
     | None when Hashtbl.mem top_globals_llvm name ->
       (* Phase 30.2b: top-level non-fn let is already initialized in the
          file-scope global @name. Load it into a register. *)
       let ty = Hashtbl.find top_globals_llvm name in
       let r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = load %s, ptr @%s" r (llvm_ty_of ty) name);
       r
     | None when Hashtbl.mem inner_lifts_llvm name ->
       (* Phase 39.A2: materialize inner-lifted fn at value position.
          Alloc env in the default region, store captures, and build the
          closure value via a chain of insertvalues. *)
       let li = Hashtbl.find inner_lifts_llvm name in
       (match e.Ast.ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyArrow (arg_ty, ret_ty) ->
             let arg_ty = Ast.walk arg_ty in
             let ret_ty = Ast.walk ret_ty in
             let env_struct_name = li.lifted_name ^ "_env" in
             let adapter_name = li.lifted_name ^ "_inner_closure_fn" in
             if not (Hashtbl.mem inner_lift_closures_emitted_llvm li.lifted_name)
             then begin
               Hashtbl.add inner_lift_closures_emitted_llvm li.lifted_name ();
               inner_lift_closure_pending_llvm :=
                 (li.lifted_name, li.captures, arg_ty, ret_ty)
                 :: !inner_lift_closure_pending_llvm
             end;
             (* sizeof env: GEP null, i32 1 → ptr at offset = sizeof env *)
             let size_r = fresh_reg () in
             emit_instr (Printf.sprintf
                           "  %s = getelementptr %%%s, ptr null, i32 1"
                           size_r env_struct_name);
             let size_int = fresh_reg () in
             emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64"
                           size_int size_r);
             let env_p = fresh_reg () in
             emit_instr (Printf.sprintf
                           "  %s = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %s)"
                           env_p size_int);
             (* Store each capture into an env field *)
             List.iteri (fun i (cn, cty) ->
               let cv =
                 match List.assoc_opt cn env with
                 | Some r -> r
                 | None ->
                   (* Free variable: can't resolve from an outer scope, so
                      mark as unsupported. This is a limitation on the
                      synthesize side (Phase 39.A2 MVP). *)
                   unsupported e.Ast.loc
                     ("inner-lifted fn `" ^ name
                      ^ "`: cannot resolve capture `" ^ cn ^ "` (Phase 39.A2 MVP)")
               in
               let gep = fresh_reg () in
               emit_instr (Printf.sprintf
                             "  %s = getelementptr %%%s, ptr %s, i32 0, i32 %d"
                             gep env_struct_name env_p i);
               emit_instr (Printf.sprintf "  store %s %s, ptr %s"
                             (llvm_ty_of cty) cv gep)
             ) li.captures;
             (* closure value: {env=env_p, fn=&adapter} *)
             let cname = closure_struct_name arg_ty ret_ty in
             let r0 = fresh_reg () in
             emit_instr (Printf.sprintf
                           "  %s = insertvalue %%%s undef, ptr %s, 0"
                           r0 cname env_p);
             let r1 = fresh_reg () in
             emit_instr (Printf.sprintf
                           "  %s = insertvalue %%%s %s, ptr @%s, 1"
                           r1 cname r0 adapter_name);
             r1
           | _ -> unsupported e.Ast.loc
                    ("inner-lifted fn `" ^ name ^ "`: type is not an arrow"))
        | None -> unsupported e.Ast.loc
                    ("inner-lifted fn `" ^ name ^ "`: type is unknown"))
     | None -> unsupported e.Ast.loc ("unbound variable: " ^ name))))
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
    let a_ty = match a.Ast.ty with Some t -> Ast.walk t | _ -> Ast.TyInt in
    (* Phase 25.1: string comparison uses strcmp instead of icmp. *)
    (match a_ty with
     | Ast.TyStr ->
       let cmp = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = call i32 @strcmp(ptr %s, ptr %s)" cmp ra rb);
       let r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = icmp %s i32 %s, 0" r (llvm_cmp_int op) cmp);
       r
     | (Ast.TyTuple _ | Ast.TyCon _) when
         (op = Ast.Eq || op = Ast.Ne) && llvm_needs_struct_eq a_ty ->
       (* A compound value is an aggregate / pointer; `icmp eq i32` on it is
          invalid IR. Structural == is implemented on interp / C / Wasm; the
          LLVM backend (no deployment path) doesn't specialize it yet, so
          fail clearly here instead of emitting broken IR. *)
       let _ = ra and _ = rb in
       unsupported e.Ast.loc
         "structural == / != on a record / variant / tuple \
          (use the interp, C, or Wasm backend; LLVM specialization pending)"
     | _ ->
       let r = fresh_reg () in
       let opnd_ty = if a_ty = Ast.TyBool then "i1" else "i32" in
       emit_instr (Printf.sprintf "  %s = icmp %s %s %s, %s" r (llvm_cmp_int op) opnd_ty ra rb);
       r)
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
     | Ast.P_var name when
         (match value.Ast.node with Ast.Fun _ -> true | _ -> false)
         && Hashtbl.mem inner_lifts_llvm name ->
       (* Phase 25.3: inner-lifted fn binding — body holds the call sites,
          the definition lives at top level (lifted). Just emit body. *)
       emit_expr env body
     | Ast.P_var name ->
       let rv = emit_expr env value in
       let saved = !current_var_types in
       let value_ty =
         match value.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
       in
       current_var_types := (name, value_ty) :: saved;
       (* Phase 36 (DEFERRED §1.18 fix): if name is a file-scope global,
          store the value into @name so subsequent reads (via Var emit
          which does `load ... @name`) see the updated value at the
          right source-order point. *)
       if Hashtbl.mem top_globals_llvm name then
         emit_instr (Printf.sprintf "  store %s %s, ptr @%s"
                       (llvm_ty_of value_ty) rv name);
       (* Phase 38.G-1 (DEFERRED §1.3 Level 1): detect safe auto-Drop. *)
       let value_is_fresh_owned_vec =
         (match value.Ast.node with
          | Ast.App ({ Ast.node = Ast.Var "owned_vec_new"; _ }, _) -> true
          | _ -> false)
         && (match value_ty with
             | Ast.TyCon ("OwnedVec", _) -> true
             | _ -> false)
       in
       let do_auto_drop =
         value_is_fresh_owned_vec
         && (not (Hashtbl.mem top_globals_llvm name))
         && owned_vec_safe_to_drop_at_scope_llvm body name
       in
       let r = emit_expr ((name, rv) :: env) body in
       current_var_types := saved;
       (* Emit scope-end free for auto-Drop — same shape as Phase 15.13 `with`. *)
       if do_auto_drop then begin
         let dp = fresh_reg () in
         emit_instr (Printf.sprintf
                       "  %s = getelementptr {ptr, i32, i32}, ptr %s, i32 0, i32 0"
                       dp rv);
         let data = fresh_reg () in
         emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" data dp);
         emit_instr (Printf.sprintf "  call void @free(ptr %s)" data);
         emit_instr (Printf.sprintf "  store ptr null, ptr %s" dp)
       end;
       r
     | Ast.P_wild | Ast.P_unit ->
       (* Phase 22.1: evaluate RHS for side effects, then continue with body. *)
       let _ = emit_expr env value in
       emit_expr env body
     | Ast.P_tuple ps ->
       (* Phase 22.1: `let (a, b, ...) = E in B` — extractvalue per index. *)
       let rv = emit_expr env value in
       let value_ty =
         match value.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
       in
       let elem_tys = match value_ty with
         | Ast.TyTuple ts -> ts
         | _ ->
           raise (Codegen_error (pat.Ast.ploc,
             "let-tuple pattern requires a tuple-typed RHS"))
       in
       if List.length ps <> List.length elem_tys then
         raise (Codegen_error (pat.Ast.ploc,
           "let-tuple arity mismatch"));
       let tname = tuple_struct_name elem_tys in
       let saved = !current_var_types in
       let new_env_extra = List.mapi (fun i p ->
         let elem_ty = List.nth elem_tys i in
         match p.Ast.pnode with
         | Ast.P_var n ->
           let r = fresh_reg () in
           emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, %d"
                         r tname rv i);
           Some (n, r, elem_ty)
         | Ast.P_wild -> None
         | _ ->
           raise (Codegen_error (p.Ast.ploc,
             "nested let-tuple patterns not supported in LLVM codegen subset"))
       ) ps in
       let env' =
         List.filter_map (function Some (n, r, _) -> Some (n, r) | None -> None)
           new_env_extra @ env
       in
       current_var_types :=
         List.filter_map (function Some (n, _, t) -> Some (n, t) | None -> None)
           new_env_extra @ saved;
       let r = emit_expr env' body in
       current_var_types := saved;
       r
     | _ ->
       (* General irrefutable pattern (constructor / record / as / …):
          desugar `let pat = value in body` to a single-arm
          `match value with | pat -> body`, reusing the full pattern
          compiler. Previously only P_var / P_tuple / P_wild were handled
          (the interp accepted every pattern) — a backend parity gap
          surfaced by the mere-blog dogfood. *)
       emit_expr env { e with Ast.node = Ast.Match (value, [(pat, None, body)]) })
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
  | Ast.App _ as outer_app when
    (let rec head_is_extern e =
       match e.Ast.node with
       | Ast.App (f, _) -> head_is_extern f
       | Ast.Var name -> Hashtbl.mem extern_fn_decls_llvm name
       | _ -> false
     in head_is_extern { Ast.node = outer_app; ty = e.Ast.ty; loc = e.Ast.loc }) ->
    (* Phase 32.6 (C1 FFI multi-arg LLVM): collect the curried App chain and
       emit a single direct LLVM call instruction. *)
    let rec collect e acc =
      match e.Ast.node with
      | Ast.App (f, a) -> collect f (a :: acc)
      | Ast.Var name -> name, acc
      | _ -> failwith "unreachable"
    in
    let name, args =
      collect { Ast.node = outer_app; ty = e.Ast.ty; loc = e.Ast.loc } []
    in
    let rec result_ty t =
      match Ast.walk t with
      | Ast.TyArrow (_, r) -> result_ty r
      | t -> t
    in
    let ret_ty = result_ty (Hashtbl.find extern_fn_decls_llvm name) in
    let arg_ll_list =
      List.filter_map (fun a ->
        match a.Ast.node with
        | Ast.Unit_lit -> None
        | _ ->
          let v = emit_expr env a in
          let t =
            match a.Ast.ty with
            | Some t -> Ast.walk t | None -> Ast.TyInt
          in
          Some (Printf.sprintf "%s %s" (llvm_ty_of t) v))
        args
    in
    let arg_ll = String.concat ", " arg_ll_list in
    (match ret_ty with
     | Ast.TyUnit ->
       emit_instr (Printf.sprintf "  call void @%s(%s)" name arg_ll);
       "0"
     | _ ->
       let r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = call %s @%s(%s)"
                     r (llvm_ty_of ret_ty) name arg_ll);
       r)
  | Ast.App ({ node = Ast.Var "print"; _ }, arg) ->
    let av = emit_expr env arg in
    emit_instr (Printf.sprintf "  call i32 @puts(ptr %s)" av);
    "0"  (* unit / int 0 *)
  (* Q-012: spawn a unit -> unit closure on a fresh pthread. Copy the
     closure's {env, fn} onto the heap so the child owns it, then
     pthread_create the trampoline. Result is the pthread_t as i64. *)
  | Ast.App ({ node = Ast.Var "spawn"; _ }, clos) ->
    let cl = emit_expr env clos in
    let cs =
      match Option.map Ast.walk clos.Ast.ty with
      | Some (Ast.TyArrow (p, r)) -> closure_struct_name (Ast.walk p) (Ast.walk r)
      | _ -> "closure_unit_unit"
    in
    let envr = fresh_reg () and fnr = fresh_reg () and c = fresh_reg () in
    let fnslot = fresh_reg () and tidp = fresh_reg () and tid = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 0" envr cs cl);
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 1" fnr cs cl);
    emit_instr (Printf.sprintf "  %s = call ptr @malloc(i64 16)" c);
    emit_instr (Printf.sprintf "  store ptr %s, ptr %s" envr c);
    emit_instr (Printf.sprintf "  %s = getelementptr i8, ptr %s, i64 8" fnslot c);
    emit_instr (Printf.sprintf "  store ptr %s, ptr %s" fnr fnslot);
    emit_instr (Printf.sprintf "  %s = alloca i64" tidp);
    emit_instr (Printf.sprintf
      "  call i32 @pthread_create(ptr %s, ptr null, ptr @__mere_spawn_trampoline, ptr %s)"
      tidp c);
    emit_instr (Printf.sprintf "  %s = load i64, ptr %s" tid tidp);
    tid
  | Ast.App ({ node = Ast.Var "join"; _ }, h) ->
    let hv = emit_expr env h in
    emit_instr (Printf.sprintf "  call i32 @pthread_join(i64 %s, ptr null)" hv);
    "0"  (* unit *)
  (* Q-012: channels via the generic i64-slot runtime. Elements cast to/from
     i64 at the call site based on their LLVM type. *)
  | Ast.App ({ node = Ast.Var "channel_new"; _ }, _arg) ->
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @mere_channel_new()" r);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "channel_send"; _ }, ch_e); _ }, v_e) ->
    let chv = emit_expr env ch_e in
    let vv = emit_expr env v_e in
    let vty = match v_e.Ast.ty with Some t -> llvm_ty_of t | None -> "i32" in
    let slot = cast_to_i64 vv vty in
    emit_instr (Printf.sprintf "  call i32 @mere_channel_send(ptr %s, i64 %s)" chv slot);
    "0"  (* unit *)
  | Ast.App ({ node = Ast.Var "channel_recv"; _ }, ch_e) ->
    let chv = emit_expr env ch_e in
    let raw = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i64 @mere_channel_recv(ptr %s)" raw chv);
    let ety = match e.Ast.ty with Some t -> llvm_ty_of t | None -> "i32" in
    cast_from_i64 raw ety
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
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_index_of"; _ }, h_e); _ }, n_e) ->
    (* Phase 19.1.1: str_index_of h n — curried. *)
    let hv = emit_expr env h_e in
    let nv = emit_expr env n_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @__lang_str_index_of(ptr %s, ptr %s)"
                  r hv nv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_compare"; _ }, a_e); _ }, b_e) ->
    (* Phase 31.0: str_compare a b — sign-normalize the raw strcmp value to
       (-1/0/1). Matches the interp's `compare s t` (OCaml). *)
    let av = emit_expr env a_e in
    let bv = emit_expr env b_e in
    let raw = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @strcmp(ptr %s, ptr %s)"
                  raw av bv);
    let is_lt = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = icmp slt i32 %s, 0" is_lt raw);
    let is_gt = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = icmp sgt i32 %s, 0" is_gt raw);
    let r1 = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = select i1 %s, i32 1, i32 0" r1 is_gt);
    let r2 = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = select i1 %s, i32 -1, i32 %s" r2 is_lt r1);
    r2
  (* Phase 34.2: float arithmetic + comparison + unary + conversions *)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var fname; _ }, a_e); _ }, b_e)
    when fname = "f_add" || fname = "f_sub" || fname = "f_mul" || fname = "f_div" ->
    let op = match fname with
      | "f_add" -> "fadd" | "f_sub" -> "fsub"
      | "f_mul" -> "fmul" | "f_div" -> "fdiv" | _ -> "fadd"
    in
    let av = emit_expr env a_e in
    let bv = emit_expr env b_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = %s double %s, %s" r op av bv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var fname; _ }, a_e); _ }, b_e)
    when fname = "f_lt" || fname = "f_le" || fname = "f_gt" || fname = "f_ge" ->
    let cmp = match fname with
      | "f_lt" -> "olt" | "f_le" -> "ole"
      | "f_gt" -> "ogt" | "f_ge" -> "oge" | _ -> "olt"
    in
    let av = emit_expr env a_e in
    let bv = emit_expr env b_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = fcmp %s double %s, %s" r cmp av bv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var fname; _ }, a_e); _ }, b_e)
    when fname = "f_min" || fname = "f_max" ->
    let cmp = if fname = "f_min" then "olt" else "ogt" in
    let av = emit_expr env a_e in
    let bv = emit_expr env b_e in
    let cmp_r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = fcmp %s double %s, %s" cmp_r cmp av bv);
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = select i1 %s, double %s, double %s" r cmp_r av bv);
    r
  | Ast.App ({ node = Ast.Var "f_neg"; _ }, a_e) ->
    let av = emit_expr env a_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = fneg double %s" r av);
    r
  | Ast.App ({ node = Ast.Var "f_abs"; _ }, a_e) ->
    let av = emit_expr env a_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call double @llvm.fabs.f64(double %s)" r av);
    r
  | Ast.App ({ node = Ast.Var "float_of_int"; _ }, a_e) ->
    let av = emit_expr env a_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = sitofp i32 %s to double" r av);
    r
  | Ast.App ({ node = Ast.Var "int_of_float"; _ }, a_e) ->
    let av = emit_expr env a_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = fptosi double %s to i32" r av);
    r
  | Ast.App ({ node = Ast.Var "str_of_float"; _ }, a_e) ->
    let av = emit_expr env a_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_of_float(double %s)" r av);
    r
  | Ast.App ({ node = Ast.Var "float_of_str"; _ }, a_e) ->
    let av = emit_expr env a_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call double @atof(ptr %s)" r av);
    r
  (* Phase 34.4: libm functions (intrinsics where available) *)
  | Ast.App ({ node = Ast.Var fname; _ }, a_e)
    when fname = "sqrt" || fname = "sin" || fname = "cos" || fname = "tan" ->
    let llvm_fn = match fname with
      | "sqrt" -> "@llvm.sqrt.f64"
      | "sin" -> "@llvm.sin.f64"
      | "cos" -> "@llvm.cos.f64"
      | "tan" -> "@tan"  (* tan has no LLVM intrinsic, so use libm *)
      | _ -> "@sqrt"
    in
    let av = emit_expr env a_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call double %s(double %s)" r llvm_fn av);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "f_pow"; _ }, a_e); _ }, b_e) ->
    let av = emit_expr env a_e in
    let bv = emit_expr env b_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call double @llvm.pow.f64(double %s, double %s)" r av bv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "atan2"; _ }, a_e); _ }, b_e) ->
    let av = emit_expr env a_e in
    let bv = emit_expr env b_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call double @atan2(double %s, double %s)" r av bv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "substring"; _ }, s_e); _ }, start_e); _ }, end_e) ->
    (* Phase 25.1: substring s start end_ — 3-arg curried. *)
    let sv = emit_expr env s_e in
    let startv = emit_expr env start_e in
    let endv = emit_expr env end_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @__lang_substring(ptr %s, i32 %s, i32 %s)"
                  r sv startv endv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "char_at"; _ }, s_e); _ }, i_e) ->
    let sv = emit_expr env s_e in
    let iv = emit_expr env i_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_char_at(ptr %s, i32 %s)" r sv iv);
    r
  (* Phase 30.0 (DEFERRED §1.12 fix): when a user-defined fn with the same
     name exists, skip the builtin dispatch and fall through to the normal
     user fn call path *)
  | Ast.App ({ node = Ast.Var "is_digit"; _ }, arg)
    when not (Hashtbl.mem toplevel_fn_names "is_digit") ->
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i1 @__lang_is_digit(ptr %s)" r av);
    r
  | Ast.App ({ node = Ast.Var "is_alpha"; _ }, arg)
    when not (Hashtbl.mem toplevel_fn_names "is_alpha") ->
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i1 @__lang_is_alpha(ptr %s)" r av);
    r
  | Ast.App ({ node = Ast.Var "is_space"; _ }, arg)
    when not (Hashtbl.mem toplevel_fn_names "is_space") ->
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i1 @__lang_is_space(ptr %s)" r av);
    r
  | Ast.App ({ node = Ast.Var "int_of_str"; _ }, arg) ->
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i32 @atoi(ptr %s)" r av);
    r
  | Ast.App ({ node = Ast.Var "str_unescape"; _ }, arg) ->
    (* Phase 25.4: str_unescape — interpret backslash-escape sequences into
       the actual characters; leave other characters as-is. Used by
       json_parser etc. *)
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_unescape(ptr %s)" r av);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_split"; _ }, s_e); _ }, delim_e) ->
    (* Phase 25.9: str_split s delim — curried; returns list_str (list ptr). *)
    str_split_used_llvm := true;
    let sv = emit_expr env s_e in
    let dv = emit_expr env delim_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_split(ptr %s, ptr %s)" r sv dv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_join"; _ }, sep_e); _ }, xs_e) ->
    (* Phase 25.9: str_join sep xs — curried; xs: list_str. *)
    str_join_used_llvm := true;
    let sv = emit_expr env sep_e in
    let xv = emit_expr env xs_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_join(ptr %s, ptr %s)" r sv xv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_count"; _ }, s_e); _ }, n_e) ->
    (* Phase 25.9: str_count s needle — non-overlapping. *)
    str_count_used_llvm := true;
    let sv = emit_expr env s_e in
    let nv = emit_expr env n_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i32 @__lang_str_count(ptr %s, ptr %s)" r sv nv);
    r
  | Ast.App ({ node = Ast.Var "str_trim"; _ }, s_e) ->
    (* Phase 36: str_trim — leading + trailing whitespace strip *)
    let sv = emit_expr env s_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_trim(ptr %s)" r sv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_starts_with"; _ }, s_e); _ }, p_e) ->
    (* Phase 36: str_starts_with s p — bool (Mere's bool == LLVM i1) *)
    let sv = emit_expr env s_e in
    let pv = emit_expr env p_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i1 @__lang_str_starts_with(ptr %s, ptr %s)" r sv pv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "str_replace"; _ }, s_e); _ }, old_e); _ }, new_e) ->
    (* Phase 36: str_replace s old new — 3-arg curried *)
    let sv = emit_expr env s_e in
    let ov = emit_expr env old_e in
    let nv = emit_expr env new_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_replace(ptr %s, ptr %s, ptr %s)" r sv ov nv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_ends_with"; _ }, s_e); _ }, p_e) ->
    (* Phase 36: str_ends_with s p — bool *)
    let sv = emit_expr env s_e in
    let pv = emit_expr env p_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i1 @__lang_str_ends_with(ptr %s, ptr %s)" r sv pv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_contains"; _ }, h_e); _ }, n_e) ->
    (* Phase 36: str_contains h n — bool via strstr *)
    let hv = emit_expr env h_e in
    let nv = emit_expr env n_e in
    let pr = fresh_reg () in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @strstr(ptr %s, ptr %s)" pr hv nv);
    emit_instr (Printf.sprintf "  %s = icmp ne ptr %s, null" r pr);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_repeat"; _ }, s_e); _ }, n_e) ->
    let sv = emit_expr env s_e in
    let nv = emit_expr env n_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_repeat(ptr %s, i32 %s)" r sv nv);
    r
  | Ast.App ({ node = Ast.Var "str_rev"; _ }, s_e) ->
    let sv = emit_expr env s_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_rev(ptr %s)" r sv);
    r
  | Ast.App ({ node = Ast.Var "not"; _ }, b_e) ->
    let bv = emit_expr env b_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = xor i1 %s, true" r bv);
    r
  | Ast.App ({ node = Ast.Var "abs"; _ }, n_e) ->
    let nv = emit_expr env n_e in
    let neg = fresh_reg () in
    let cmp = fresh_reg () in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = sub i32 0, %s" neg nv);
    emit_instr (Printf.sprintf "  %s = icmp slt i32 %s, 0" cmp nv);
    emit_instr (Printf.sprintf "  %s = select i1 %s, i32 %s, i32 %s" r cmp neg nv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "min"; _ }, a_e); _ }, b_e) ->
    let av = emit_expr env a_e in
    let bv = emit_expr env b_e in
    let cmp = fresh_reg () in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = icmp slt i32 %s, %s" cmp av bv);
    emit_instr (Printf.sprintf "  %s = select i1 %s, i32 %s, i32 %s" r cmp av bv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "max"; _ }, a_e); _ }, b_e) ->
    let av = emit_expr env a_e in
    let bv = emit_expr env b_e in
    let cmp = fresh_reg () in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = icmp sgt i32 %s, %s" cmp av bv);
    emit_instr (Printf.sprintf "  %s = select i1 %s, i32 %s, i32 %s" r cmp av bv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "clamp"; _ }, lo_e); _ }, hi_e); _ }, x_e) ->
    let lov = emit_expr env lo_e in
    let hiv = emit_expr env hi_e in
    let xv = emit_expr env x_e in
    let lt_lo = fresh_reg () in
    let lo_or_x = fresh_reg () in
    let gt_hi = fresh_reg () in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = icmp slt i32 %s, %s" lt_lo xv lov);
    emit_instr (Printf.sprintf "  %s = select i1 %s, i32 %s, i32 %s" lo_or_x lt_lo lov xv);
    emit_instr (Printf.sprintf "  %s = icmp sgt i32 %s, %s" gt_hi lo_or_x hiv);
    emit_instr (Printf.sprintf "  %s = select i1 %s, i32 %s, i32 %s" r gt_hi hiv lo_or_x);
    r
  | Ast.App ({ node = Ast.Var "chr"; _ }, n_e) ->
    (* Phase 36: chr n — via char_table *)
    let nv = emit_expr env n_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_char_at_chr(i32 %s)" r nv);
    r
  | Ast.App ({ node = Ast.Var "ord"; _ }, s_e) ->
    (* Phase 36: ord s — load first byte, zext to i32 *)
    let sv = emit_expr env s_e in
    let bv = fresh_reg () in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = load i8, ptr %s" bv sv);
    emit_instr (Printf.sprintf "  %s = zext i8 %s to i32" r bv);
    r
  | Ast.App ({ node = Ast.Var "to_upper"; _ }, s_e) ->
    let sv = emit_expr env s_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_to_upper(ptr %s)" r sv);
    r
  | Ast.App ({ node = Ast.Var "to_lower"; _ }, s_e) ->
    let sv = emit_expr env s_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_to_lower(ptr %s)" r sv);
    r
  | Ast.App ({ node = Ast.Var "even"; _ }, n_e) ->
    let nv = emit_expr env n_e in
    let rem = fresh_reg () in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = srem i32 %s, 2" rem nv);
    emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, 0" r rem);
    r
  | Ast.App ({ node = Ast.Var "odd"; _ }, n_e) ->
    let nv = emit_expr env n_e in
    let rem = fresh_reg () in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = srem i32 %s, 2" rem nv);
    emit_instr (Printf.sprintf "  %s = icmp ne i32 %s, 0" r rem);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "gcd"; _ }, a_e); _ }, b_e) ->
    let av = emit_expr env a_e in
    let bv = emit_expr env b_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i32 @__lang_gcd(i32 %s, i32 %s)" r av bv);
    r
  | Ast.App ({ node = Ast.Var "bool_of_str"; _ }, s_e) ->
    (* Phase 36: bool_of_str — strcmp s "true". Reuse the dedicated const *)
    let true_label = fresh_str_global "true" in
    let sv = emit_expr env s_e in
    let pr = fresh_reg () in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i32 @strcmp(ptr %s, ptr %s)" pr sv true_label);
    emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, 0" r pr);
    r
  | Ast.App ({ node = Ast.Var "read_file"; _ }, path_e) ->
    (* Phase 25.9: read_file path — returns str (region-allocated buffer). *)
    file_io_used_llvm := true;
    let pv = emit_expr env path_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_read_file(ptr %s)" r pv);
    r
  | Ast.App ({ node = Ast.Var "list_dir"; _ }, _path_e) ->
    unsupported e.Ast.loc
      "list_dir is unsupported in LLVM codegen (Phase 44 MVP scope = interp + C only)"
  | Ast.App ({ node = Ast.Var "mkdir_p"; _ }, _path_e) ->
    unsupported e.Ast.loc
      "mkdir_p is unsupported in LLVM codegen (Phase 44 MVP scope = interp + C only)"
  | Ast.App ({ node = Ast.Var "file_mtime"; _ }, _) ->
    unsupported e.Ast.loc
      "file_mtime is unsupported in LLVM codegen (Phase 44.6 MVP = interp + C only)"
  | Ast.App ({ node = Ast.Var "sleep_ms"; _ }, _) ->
    unsupported e.Ast.loc
      "sleep_ms is unsupported in LLVM codegen (Phase 44.6 MVP = interp + C only)"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "write_file"; _ }, path_e); _ }, content_e) ->
    (* Phase 25.9: write_file path content — curried; returns unit (i32 0). *)
    file_io_used_llvm := true;
    let pv = emit_expr env path_e in
    let cv = emit_expr env content_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i32 @__lang_write_file(ptr %s, ptr %s)" r pv cv);
    r
  | Ast.App ({ node = Ast.Var "str_of_int"; _ }, arg) ->
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @show_int(i32 %s)" r av);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "try_or"; _ }, fn_e); _ }, default_e) ->
    (* Phase 25.2: try_or fn default — catch fail via setjmp + longjmp.
       The fn invocation (= apply to unit) is the try branch; on failure use
       default. Save/restore the jmpbuf-set flag to handle nesting. *)
    let result_ty =
      match e.Ast.ty with Some t -> llvm_ty_of (Ast.walk t) | None -> "i32"
    in
    let l_try_ok = fresh_label "try_ok_" in
    let l_try_failed = fresh_label "try_failed_" in
    let l_try_done = fresh_label "try_done_" in
    (* Save state *)
    let saved_set_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = load i32, ptr @__lang_fail_jmpbuf_set" saved_set_reg);
    let saved_buf_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = alloca [200 x i8], align 16" saved_buf_reg);
    emit_instr (Printf.sprintf "  call ptr @memcpy(ptr %s, ptr @__lang_fail_jmpbuf, i64 200)" saved_buf_reg);
    emit_instr "  store i32 1, ptr @__lang_fail_jmpbuf_set";
    (* setjmp *)
    let sj_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i32 @setjmp(ptr @__lang_fail_jmpbuf)" sj_reg);
    let from_jmp_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = icmp ne i32 %s, 0" from_jmp_reg sj_reg);
    emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                  from_jmp_reg l_try_failed l_try_ok);
    (* try_ok block: invoke fn () via closure dispatch *)
    emit_label l_try_ok;
    let fn_v = emit_expr env fn_e in
    (* fn_v is a closure_unit_<R>. Extract env and fn pointer, call. *)
    let cl_struct_name =
      match fn_e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyArrow (p, r) -> closure_struct_name p r
         | _ -> unsupported e.Ast.loc "try_or: fn arg has non-arrow type")
      | None -> unsupported e.Ast.loc "try_or: fn arg missing type"
    in
    let env_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 0" env_reg cl_struct_name fn_v);
    let fnp_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 1" fnp_reg cl_struct_name fn_v);
    let ok_result_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call %s %s(ptr %s, i32 0)"
                  ok_result_reg result_ty fnp_reg env_reg);
    let l_try_ok_end = fresh_label "try_ok_end_" in
    emit_instr (Printf.sprintf "  br label %%%s" l_try_ok_end);
    emit_label l_try_ok_end;
    emit_instr (Printf.sprintf "  br label %%%s" l_try_done);
    (* try_failed block: emit default *)
    emit_label l_try_failed;
    let default_v = emit_expr env default_e in
    let l_try_failed_end = fresh_label "try_failed_end_" in
    emit_instr (Printf.sprintf "  br label %%%s" l_try_failed_end);
    emit_label l_try_failed_end;
    emit_instr (Printf.sprintf "  br label %%%s" l_try_done);
    (* try_done block: phi *)
    emit_label l_try_done;
    let result_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = phi %s [%s, %%%s], [%s, %%%s]"
                  result_reg result_ty
                  ok_result_reg l_try_ok_end
                  default_v l_try_failed_end);
    (* Restore state *)
    emit_instr (Printf.sprintf "  store i32 %s, ptr @__lang_fail_jmpbuf_set" saved_set_reg);
    emit_instr (Printf.sprintf "  call ptr @memcpy(ptr @__lang_fail_jmpbuf, ptr %s, i64 200)" saved_buf_reg);
    result_reg
  | Ast.App ({ node = Ast.Var "fail"; _ }, arg) ->
    let result_ty =
      match e.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyInt
    in
    let av = emit_expr env arg in
    (* Phase 25.1: __lang_fail_impl is noreturn — the return value is
       unreachable. For ptr / struct / etc. contexts where __lang_fail_int
       (i32) wouldn't type-check, emit the call (which aborts) then
       provide an undef of the expected type. *)
    (match Ast.walk result_ty with
     | Ast.TyStr ->
       let r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = call ptr @__lang_fail_str(ptr %s)" r av);
       r
     | Ast.TyBool ->
       let r_i32 = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = call i32 @__lang_fail_int(ptr %s)" r_i32 av);
       let r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = trunc i32 %s to i1" r r_i32);
       r
     | Ast.TyInt | Ast.TyUnit ->
       let r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = call i32 @__lang_fail_int(ptr %s)" r av);
       r
     | other ->
       (* For ptr / struct / variant / tuple etc. — call fail then emit
          undef. fail aborts so undef is never read. *)
       emit_instr (Printf.sprintf "  call void @__lang_fail_impl(ptr %s)" av);
       Printf.sprintf "undef" |> fun _ ->
       (* Need an SSA value of the expected LLVM type. Use undef literal. *)
       let _ = other in
       "undef")
  | Ast.App ({ node = Ast.Var "vec_new"; _ }, _arg) ->
    (* Phase 15.3: vec_new () — extract the region and element type from
       the result type's TyCon args and call the `@mere_vec_<tag>_new`
       runtime. If the region binding is __heap, use @__lang_default_region;
       otherwise use %__region_<R> (the SSA register alloca'd by Region_block). *)
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
  | Ast.App ({ node = Ast.Var "vec_reverse"; _ }, vec_e) ->
    (* Phase 19.3: vec_reverse v — in-place, per-T helper. *)
    let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let av = emit_expr env vec_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_vec_%s_reverse(ptr %s)"
                  r elem_tag av);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_concat"; _ }, a_e); _ }, b_e) ->
    (* Phase 19.3: vec_concat a b — new region Vec, per-T helper. *)
    let elem_tag = vec_elem_tag_of a_e.Ast.ty a_e.Ast.loc in
    let av = emit_expr env a_e in
    let bv = emit_expr env b_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @mere_vec_%s_concat(ptr %s, ptr %s)"
                  r elem_tag av bv);
    r
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_sort"; _ }, vec_e); _ }, cmp_e) ->
    (* Phase 19.3: vec_sort v cmp — per-T helper, in-place insertion sort.
       comparator: T -> T -> int (curried). *)
    let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
    let elem_ty = Hashtbl.find vec_instances elem_tag in
    if not (Hashtbl.mem vec_sort_instances elem_tag) then
      Hashtbl.add vec_sort_instances elem_tag elem_ty;
    let av = emit_expr env vec_e in
    let cv = emit_expr env cmp_e in
    let outer_cl = closure_struct_name elem_ty
      (Ast.TyArrow (elem_ty, Ast.TyInt)) in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_vec_%s_sort(ptr %s, %%%s %s)"
                  r elem_tag av outer_cl cv);
    r
  | Ast.App ({ node = Ast.Var "strbuf_new"; _ }, _arg) ->
    (* Phase 15.9: strbuf_new () — extract the region from the result type's
       TyCon arg and pass it to @mere_strbuf_new. *)
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
    (* Phase 15.11: len ad-hoc dispatch — at compile time, route to the
       corresponding _len helper based on arg.ty. *)
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
    (* Phase 15.10: map_new () — extract the region and (K, V) from the result type. *)
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
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_delete"; _ }, m_e); _ }, k_e) ->
    (* Phase 39.A' #2: map_delete m k *)
    let (k_tag, v_tag) = map_kv_tags_of m_e.Ast.ty m_e.Ast.loc in
    let (k_ty, _) = Hashtbl.find map_instances (k_tag ^ "__" ^ v_tag) in
    let av = emit_expr env m_e in
    let kv = emit_expr env k_e in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_map_%s_%s_delete(ptr %s, %s %s)"
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
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_iter"; _ }, m_e); _ }, fn_e) ->
    (* Phase 19.2: map_iter m f — per-(K, V) helper.
       Signature: i32 @mere_map_<K>_<V>_iter(ptr m, %closure_<K>_<closure_<V>_unit> outer) *)
    let (k_tag, v_tag) = map_kv_tags_of m_e.Ast.ty m_e.Ast.loc in
    let (k_ty, v_ty) = Hashtbl.find map_instances (k_tag ^ "__" ^ v_tag) in
    let key = k_tag ^ "__" ^ v_tag in
    if not (Hashtbl.mem map_iter_instances key) then
      Hashtbl.add map_iter_instances key (k_ty, v_ty);
    let av = emit_expr env m_e in
    let cv = emit_expr env fn_e in
    let outer_cl = closure_struct_name k_ty (Ast.TyArrow (v_ty, Ast.TyUnit)) in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call i32 @mere_map_%s_%s_iter(ptr %s, %%%s %s)"
                  r k_tag v_tag av outer_cl cv);
    r
  | Ast.App ({ node = Ast.Var "owned_vec_new"; _ }, _arg) ->
    (* Phase 15.7: owned_vec_new () — heap-allocated OwnedVec[T].
       Extract the element type T from e.ty (the result Vec's TyCon arg). *)
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
    (* Phase 15.7: vec_to_owned v — deep copy a region Vec[R, T] to a heap
       OwnedVec[T]. *)
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
    (* Phase 15.7: owned_vec_to_vec o — deep copy a heap OwnedVec[T] to a
       region Vec[R, T]. Extract the region from e.ty's TyRef marker. *)
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
    when Hashtbl.mem inner_lifts_llvm name ->
    (* Phase 25.3: inner-lifted fn call. Prepend captures (by name from env)
       then the arg. *)
    let li = Hashtbl.find inner_lifts_llvm name in
    let av = emit_expr env arg in
    let arg_ty_str =
      match arg.Ast.ty with
      | Some t -> llvm_ty_of (Ast.walk t)
      | None -> "i32"
    in
    let cap_args =
      List.map (fun (cn, cty) ->
        let cv =
          match List.assoc_opt cn env with
          | Some v -> v
          | None when Hashtbl.mem top_globals_llvm cn ->
            (* Phase 36 (DEFERRED §1.14 fix): if a captured free var is a
               top-level global, load it before passing.
               Pass the loaded value of `ptr @cn`, not `ptr %cn` (register). *)
            let r = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = load %s, ptr @%s"
                          r (llvm_ty_of cty) cn);
            r
          | None -> "%" ^ cn  (* fallback *)
        in
        Printf.sprintf "%s %s" (llvm_ty_of cty) cv
      ) li.captures
    in
    let all_args = String.concat ", " (cap_args @ [Printf.sprintf "%s %s" arg_ty_str av]) in
    let ret_ty =
      match e.Ast.ty with
      | Some t -> llvm_ty_of (Ast.walk t)
      | None -> "i32"
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call %s @%s(%s)" r ret_ty li.lifted_name all_args);
    r
  | Ast.App ({ node = Ast.Var name; ty = f_ty; _ }, arg)
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
    (* Phase 25.5: per-instantiation dispatch. If name is multi-inst, use
       the call site's f.ty (the head Var's specific arrow type for this
       use) to pick the mangled name. *)
    let dispatch_name =
      if Hashtbl.mem multi_inst_fns_llvm name then
        match f_ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyArrow _ as arrow -> mangled_inst_name_llvm name arrow
           | _ -> name)
        | None -> name
      else name
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call %s @%s(%s %s)" r ret_ty dispatch_name arg_ty av);
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
    (* Phase 25.10/25.12: if arrow_ty still has free tyvars, try to recover
       concrete types from arg.ty / e.ty / current_var_types. Useful when
       a polymorphic callback (e.g., the f in `list_iter xs f`) leaves the
       App-result tyvar unconstrained. *)
    let arrow_ty =
      if ty_is_concrete arrow_ty then arrow_ty
      else begin
        (match arg.Ast.ty, e.Ast.ty with
         | Some pt, Some rt when ty_is_concrete (Ast.walk pt) && ty_is_concrete (Ast.walk rt) ->
           let target = Ast.TyArrow (Ast.walk pt, Ast.walk rt) in
           (try Typer.unify Loc.dummy arrow_ty target with _ -> ())
         | _ -> ());
        let walked = Ast.walk arrow_ty in
        if ty_is_concrete walked then walked
        else begin
          (* Fall back to arg's concrete binding from current_var_types if arg
             is a Var. This handles `list_iter t f` inside list_iter's body
             where f is a captured var with concrete (str -> unit) type. *)
          let arg_concrete =
            match arg.Ast.node with
            | Ast.Var n ->
              (match List.assoc_opt n !current_var_types with
               | Some t when ty_is_concrete (Ast.walk t) -> Some (Ast.walk t)
               | _ -> None)
            | _ -> None
          in
          (match arg_concrete, e.Ast.ty with
           | Some pt, Some rt when ty_is_concrete (Ast.walk rt) ->
             let target = Ast.TyArrow (pt, Ast.walk rt) in
             (try Typer.unify Loc.dummy arrow_ty target with _ -> ())
           | _ -> ());
          Ast.walk arrow_ty
        end
      end
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
    (* Phase 25.12: derive arg_ty from arrow_ty's p (which we just fixed
       up) instead of arg.Ast.ty directly. arg.Ast.ty might still be a
       free TyVar even though arrow_ty's p is concrete. *)
    let arg_ty =
      match arrow_ty with
      | Ast.TyArrow (p, _) when ty_is_concrete (Ast.walk p) -> llvm_ty_of (Ast.walk p)
      | _ ->
        (match arg.Ast.ty with
         | Some t -> llvm_ty_of t
         | None -> "i32")
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
    let raw_ty =
      match inner.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "field access: missing inner type"
    in
    (* Phase 19.x: field access through a borrow. In LLVM, &[mode] R T is a
       ptr value; unwrap and treat as the inner T's record type (follows the
       same GEP+load path as view). *)
    let inner_ty, via_borrow =
      match raw_ty with
      | Ast.TyRef (_, _, t) -> (Ast.walk t, true)
      | _ -> (raw_ty, false)
    in
    if is_view_type inner_ty || via_borrow then begin
      (* View value (or borrowed record) is a ptr to a region-allocated
         struct. GEP+load. *)
      let name =
        match inner_ty with
        | Ast.TyCon (n, _) -> n
        | _ -> assert false
      in
      let fields =
        match Hashtbl.find_opt Typer.views name with
        | Some info -> info.Typer.v_fields
        | None ->
          (* Borrowed plain record — use record info. *)
          record_fields name
      in
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
  | Ast.Constr (raw_cname, arg_opt) ->
    (* Phase 42: try raw qualified lookup first (preserves multi-module
       disambiguation `Traffic.Red` → Light/Red vs `Mood.Red` → Color/Red);
       fall back to canonical bare name. *)
    let cname = Ast.canonical_ctor raw_cname in
    let info =
      match Hashtbl.find_opt Typer.constructors raw_cname with
      | Some i -> i
      | None ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some i -> i
         | None -> unsupported e.Ast.loc ("unknown constructor: " ^ raw_cname))
    in
    let type_name = info.Typer.type_name in
    if not (Hashtbl.mem Typer.types type_name) then
      unsupported e.Ast.loc ("constructor's type not registered: " ^ type_name);
    let tag =
      match Hashtbl.find_opt variant_tags cname with
      | Some t -> t
      | None -> unsupported e.Ast.loc ("constructor without tag: " ^ cname)
    in
    let struct_name =
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
        mono_variant_name type_name args
      end else
        type_name
    in
    (* Phase 25.0: per-ctor payload type. For poly variants, substitute
       type params with concrete args (computed from e.Ast.ty above). *)
    let ctor_pty =
      match info.Typer.arg with
      | None -> None
      | Some t ->
        if Hashtbl.mem polymorphic_variants type_name then begin
          let args =
            match e.Ast.ty with
            | Some et ->
              (match Ast.walk et with
               | Ast.TyCon (n, ts) when n = type_name -> List.map Ast.walk ts
               | _ -> [])
            | None -> []
          in
          let (params, _) = Hashtbl.find polymorphic_variants type_name in
          let mapping = List.combine params args in
          Some (Ast.walk (subst_params mapping t))
        end
        else Some (Ast.walk t)
    in
    (* Box the payload (if any) into a region-allocated ptr. *)
    let box_payload () =
      match arg_opt, ctor_pty with
      | None, _ -> None
      | Some arg, Some pty ->
        let av = emit_expr env arg in
        let pty_llvm = llvm_ty_of pty in
        (* alloc + store + return ptr *)
        let size_p = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr null, i32 1"
                      size_p pty_llvm);
        let size = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" size size_p);
        let p = fresh_reg () in
        emit_instr (Printf.sprintf
                      "  %s = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %s)"
                      p size);
        emit_instr (Printf.sprintf "  store %s %s, ptr %s" pty_llvm av p);
        Some p
      | Some _, None ->
        unsupported e.Ast.loc
          (Printf.sprintf "constructor `%s` has payload but type info missing payload type"
             cname)
    in
    if is_recursive_variant_name struct_name then begin
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
      (match box_payload () with
       | None -> ()
       | Some boxed ->
         let pl_p = fresh_reg () in
         emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 1"
                       pl_p node_ty p);
         emit_instr (Printf.sprintf "  store ptr %s, ptr %s" boxed pl_p));
      p
    end
    else begin
      let r0 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s undef, i32 %d, 0"
                    r0 struct_name tag);
      match box_payload () with
      | None -> r0
      | Some boxed ->
        let r1 = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, ptr %s, 1"
                      r1 struct_name r0 boxed);
        r1
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
    (* Phase 25.8: compile_pat now takes a `fail_label` and emits
       short-circuit branches for P_constr — when the outer tag doesn't
       match, jump to fail_label BEFORE dereferencing the payload.
       Returns (cond, bindings, var_tys); for atomic patterns the cond
       is the final i1 check (caller does br); for nested P_constr,
       intermediate tag checks already branched to fail_label inside,
       so the returned cond is just the final pattern's check (or "1"). *)
    let rec compile_pat (pat : Ast.pattern) (v_reg : string) (v_ty : Ast.ty)
      (fail_label : string)
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
        let (c, bs, tys) = compile_pat inner v_reg v_ty fail_label in
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
            let (c, bs, tys) = compile_pat p er ety fail_label in
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
            let (c, bs, tys) = compile_pat sub_p fr ft fail_label in
            go (and_cond acc_cond c)
              (List.rev_append bs acc_bs) (List.rev_append tys acc_tys) rest
        in
        go "1" [] [] sub_fields
      | Ast.P_constr (raw_cname, sub) ->
        (* Phase 41 + 42: try raw qualified ctor lookup first (preserves
           multi-module disambiguation `Traffic.Red` vs `Mood.Red`), fall back
           to canonical bare name. *)
        let cname = Ast.canonical_ctor raw_cname in
        let info =
          match Hashtbl.find_opt Typer.constructors raw_cname with
          | Some i -> i
          | None ->
            (match Hashtbl.find_opt Typer.constructors cname with
             | Some i -> i
             | None -> unsupported pat.Ast.ploc ("unknown ctor: " ^ raw_cname))
        in
        (* Phase 42: prefer the scrutinee's type for struct_name (so the
           pattern resolves to the actual variant being matched against,
           not the alias overwrite). info.type_name is only used as fallback. *)
        let struct_name =
          match Ast.walk v_ty with
          | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
            mono_variant_name n (List.map Ast.walk args)
          | Ast.TyCon (n, _) -> n
          | _ -> info.Typer.type_name
        in
        let ctor_pty =
          match info.Typer.arg with
          | None -> None
          | Some t ->
            (match Ast.walk v_ty with
             | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
               let args = List.map Ast.walk args in
               let (params, _) = Hashtbl.find polymorphic_variants n in
               let mapping = List.combine params args in
               Some (Ast.walk (subst_params mapping t))
             | _ -> Some (Ast.walk t))
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
        (match sub, ctor_pty with
         | None, _ -> (tag_cond, [], [])
         | Some sub_pat, Some pty ->
           (* Phase 25.8: short-circuit on tag mismatch before deref —
              without this guard, a nested pattern would unconditionally
              load the payload field which is uninitialized for variants
              of a different tag (e.g. Nil), causing SIGSEGV. *)
           let ok_label = fresh_label "tag_ok_" in
           emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                         tag_cond ok_label fail_label);
           emit_label ok_label;
           let ptr_reg = fresh_reg () in
           if recursive then begin
             let p = fresh_reg () in
             emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 1"
                           p node_ty v_reg);
             emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" ptr_reg p)
           end else
             emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 1"
                           ptr_reg struct_name v_reg);
           let payload_reg = fresh_reg () in
           emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                         payload_reg (llvm_ty_of pty) ptr_reg);
           let (c, bs, tys) = compile_pat sub_pat payload_reg pty fail_label in
           (c, bs, tys)
         | Some _, None ->
           unsupported pat.Ast.ploc
             "pattern has payload but constructor has no payload type")
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
        let arm_label = fresh_label "arm_" in
        let next_label = fresh_label "next_" in
        let (cond, bindings, var_tys) = compile_pat pat scrut_v scrut_ty next_label in
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
      ce_host = !current_host_fn_llvm;
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
  | Ast.Let_rec (bindings, body) ->
    (* Phase 25.3: inner let-rec lifting. If all bindings are registered
       in inner_lifts_llvm (= lifted to top level), just emit body. *)
    if List.for_all (fun (n, _) -> Hashtbl.mem inner_lifts_llvm n) bindings then
      emit_expr env body
    else
      unsupported e.Ast.loc "let rec inside an expression (only allowed at top level)"
  | Ast.Float_lit f ->
    (* Phase 34.2: LLVM IR double literal. LLVM requires a decimal point even
       for integer-valued floats, so emit the bit pattern directly as hex
       (roundtrip-safe and no formatting required). *)
    if f <> f then "0x7FF8000000000000"  (* canonical NaN *)
    else if f = infinity then "0x7FF0000000000000"
    else if f = neg_infinity then "0xFFF0000000000000"
    else
      let bits = Int64.bits_of_float f in
      Printf.sprintf "0x%016Lx" bits

(* Emit the body of an anonymous-Fun adapter: gep + load each capture
   from `%env_self`, then evaluate the original Fun body with the
   captures bound. Returns the full `define ...` string. *)
let emit_anon_adapter (ce : closure_emission) : string =
  let saved_instrs = !instrs in
  let saved_reg = !reg_counter and saved_lbl = !label_counter in
  let saved_vt = !current_var_types in
  let saved_exp = !current_expected_ty in
  let saved_host = !current_host_fn_llvm in
  (* Phase 25.3: restore the host scope this closure was queued under,
     so its body can resolve recursive calls into inner-lifted siblings. *)
  set_inner_lifts_for_host_llvm ce.ce_host;
  current_host_fn_llvm := ce.ce_host;
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
  (* Phase 25.7: the body's inferred type might still hold free TyVars
     left over from let-poly generalization that weren't reachable via the
     containing fn's surface arrow (e.g., a fresh tyvar from a Nil
     pattern instantiation never tied back to the outer's elem type).
     Unify body.ty with ce_return_ty to propagate concrete types. *)
  (match ce.ce_body.Ast.ty with
   | Some t ->
     (try Typer.unify Loc.dummy t ce.ce_return_ty with _ -> ())
   | None -> ());
  let rv = emit_expr env ce.ce_body in
  emit_instr (Printf.sprintf "  ret %s %s" (llvm_ty_of ce.ce_return_ty) rv);
  let body = String.concat "\n" (List.rev !instrs) in
  instrs := saved_instrs;
  reg_counter := saved_reg;
  label_counter := saved_lbl;
  current_var_types := saved_vt;
  current_expected_ty := saved_exp;
  current_host_fn_llvm := saved_host;
  Printf.sprintf
    "define %s @%s(ptr %%env_self, %s %%%s) {\n%s\n}"
    (llvm_ty_of ce.ce_return_ty) ce.ce_adapter_name
    (llvm_ty_of ce.ce_param_ty) ce.ce_param body

(* Phase 25.3: emit a lifted inner fn as top-level @-named LLVM IR.
   Captures + param prepended as parameters. The body's free vars resolve
   to either capture parameters or to recursive inner-lifted calls (via
   inner_lifts_llvm, set up by set_inner_lifts_for_host_llvm). *)
let emit_lifted_fn_llvm (lf : lifted_fn_llvm) : string =
  set_inner_lifts_for_host_llvm lf.l_host;
  reg_counter := 0;
  label_counter := 0;
  let saved_instrs = !instrs in
  let saved_vt = !current_var_types in
  let saved_exp = !current_expected_ty in
  let saved_host = !current_host_fn_llvm in
  instrs := [];
  current_expected_ty := Some lf.l_return_ty;
  current_host_fn_llvm := lf.l_host;
  emit_instr "entry:";
  let env =
    List.map (fun (n, _) -> (n, "%" ^ n)) lf.l_captures
    @ [(lf.l_param, "%" ^ lf.l_param)]
  in
  current_var_types :=
    List.map (fun (n, t) -> (n, t)) lf.l_captures
    @ [(lf.l_param, lf.l_param_ty)];
  let rv = emit_expr env lf.l_body in
  emit_instr (Printf.sprintf "  ret %s %s" (llvm_ty_of lf.l_return_ty) rv);
  let body = String.concat "\n" (List.rev !instrs) in
  instrs := saved_instrs;
  current_var_types := saved_vt;
  current_expected_ty := saved_exp;
  current_host_fn_llvm := saved_host;
  let params =
    String.concat ", "
      (List.map (fun (n, t) -> Printf.sprintf "%s %%%s" (llvm_ty_of t) n)
         (lf.l_captures @ [(lf.l_param, lf.l_param_ty)]))
  in
  Printf.sprintf "define %s @%s(%s) {\n%s\n}"
    (llvm_ty_of lf.l_return_ty) lf.l_name params body

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
  let saved_host = !current_host_fn_llvm in
  instrs := [];
  current_var_types := [(f.param, f.param_ty)];
  current_expected_ty := Some f.return_ty;
  current_host_fn_llvm := f.name;
  emit_instr "entry:";
  let env = [(f.param, "%" ^ f.param)] in
  let rv = emit_expr env f.body in
  emit_instr (Printf.sprintf "  ret %s %s" (llvm_ty_of f.return_ty) rv);
  let body = String.concat "\n" (List.rev !instrs) in
  instrs := saved;
  current_var_types := saved_types;
  current_expected_ty := saved_exp;
  current_host_fn_llvm := saved_host;
  Printf.sprintf "define %s @%s(%s %%%s) {\n%s\n}"
    (llvm_ty_of f.return_ty) f.name (llvm_ty_of f.param_ty) f.param body

(* Convert the program's main result type to (LLVM type, printf format).
   Phase 25.11: `unit` now prints "()" to match interp's behavior
   (interp's Eval.to_string V_unit = "()" gets print_endline'd). *)
let main_format_of (t : Ast.ty) : (string * string) option =
  match Ast.walk t with
  | Ast.TyInt -> Some ("i32", "%d")
  | Ast.TyBool -> Some ("i32", "%d")  (* zext from i1 *)
  | Ast.TyFloat -> Some ("double", "float")  (* Phase 34.2: use __lang_str_of_float + puts for interp parity *)
  | Ast.TyStr -> Some ("ptr", "%s")
  | Ast.TyUnit -> Some ("unit", "()")  (* Phase 25.11: print "()" for unit main *)
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
      "declare i32 @strncmp(ptr, ptr, i64)";
      "declare ptr @strstr(ptr, ptr)";
      "declare ptr @memcpy(ptr, ptr, i64)";
      "declare i32 @memcmp(ptr, ptr, i64)";
      "declare i32 @puts(ptr)";
      "declare i32 @printf(ptr, ...)";
      (* Q-012: POSIX threads. pthread_t is pointer-sized on LP64, carried as
         i64. The spawn trampoline unpacks a heap {env, fn} pair and invokes
         the closure the same way the rest of codegen does: fn(env, unit=0). *)
      "declare i32 @pthread_create(ptr, ptr, ptr, ptr)";
      "declare i32 @pthread_join(i64, ptr)";
      "declare i32 @pthread_mutex_init(ptr, ptr)";
      "declare i32 @pthread_mutex_lock(ptr)";
      "declare i32 @pthread_mutex_unlock(ptr)";
      "declare i32 @pthread_cond_init(ptr, ptr)";
      "declare i32 @pthread_cond_signal(ptr)";
      "declare i32 @pthread_cond_wait(ptr, ptr)";
      "declare i32 @fprintf(ptr, ptr, ...)";
      "declare i32 @asprintf(ptr, ptr, ...)";
      "declare void @abort()";
      "declare i32 @atoi(ptr)";
      "declare double @atof(ptr)";  (* Phase 34.2: float_of_str *)
      "declare double @llvm.fabs.f64(double)";  (* Phase 34.2: f_abs *)
      (* Phase 34.4: libm intrinsics + functions (linked via -lm by clang) *)
      "declare double @llvm.sqrt.f64(double)";
      "declare double @llvm.sin.f64(double)";
      "declare double @llvm.cos.f64(double)";
      "declare double @tan(double)";
      "declare double @llvm.pow.f64(double, double)";
      "declare double @atan2(double, double)";
      "declare i32 @setjmp(ptr) returns_twice";
      "declare void @longjmp(ptr, i32) noreturn";
      "@.fail_prefix = internal constant [7 x i8] c\"fail: \\00\"";
      "@__lang_fail_jmpbuf = global [200 x i8] zeroinitializer, align 16";
      "@__lang_fail_jmpbuf_set = global i32 0" ]
(* Phase 30.2b: declare top-level non-fn lets as @name LLVM globals.
   Emit each entry as `@name = internal global <type> zeroinitializer`.
   They are initialized by store at the start of main. *)
let emit_top_globals_llvm (lst : (string * Ast.expr * Ast.ty) list) : string list =
  List.map (fun (name, _value, ty) ->
    Printf.sprintf "@%s = internal global %s zeroinitializer"
      name (llvm_ty_of ty)) lst

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

(* Phase 19.3: vec_reverse helper — in-place swap loop. *)
let emit_vec_reverse_helper_llvm (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_elem = llvm_ty_of elem_ty in
  let struct_name = "mere_vec_" ^ tag in
  String.concat "\n"
    [ Printf.sprintf "define i32 @mere_vec_%s_reverse(ptr %%v) {" tag;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %data = load ptr, ptr %dp";
      "  %hi_init = sub i32 %len, 1";
      "  br label %check";
      "check:";
      "  %lo = phi i32 [ 0, %entry ], [ %lo_next, %swap ]";
      "  %hi = phi i32 [ %hi_init, %entry ], [ %hi_next, %swap ]";
      "  %done = icmp sge i32 %lo, %hi";
      "  br i1 %done, label %end, label %swap";
      "swap:";
      Printf.sprintf "  %%lo_slot = getelementptr %s, ptr %%data, i32 %%lo" c_elem;
      Printf.sprintf "  %%hi_slot = getelementptr %s, ptr %%data, i32 %%hi" c_elem;
      Printf.sprintf "  %%lo_val = load %s, ptr %%lo_slot" c_elem;
      Printf.sprintf "  %%hi_val = load %s, ptr %%hi_slot" c_elem;
      Printf.sprintf "  store %s %%hi_val, ptr %%lo_slot" c_elem;
      Printf.sprintf "  store %s %%lo_val, ptr %%hi_slot" c_elem;
      "  %lo_next = add i32 %lo, 1";
      "  %hi_next = sub i32 %hi, 1";
      "  br label %check";
      "end:";
      "  ret i32 0";
      "}" ]

(* Phase 19.3: vec_concat helper — new Vec in a's region with a's then b's. *)
let emit_vec_concat_helper_llvm (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_elem = llvm_ty_of elem_ty in
  let struct_name = "mere_vec_" ^ tag in
  String.concat "\n"
    [ Printf.sprintf "define ptr @mere_vec_%s_concat(ptr %%a, ptr %%b) {" tag;
      "entry:";
      (* Allocate new Vec in a's region. *)
      Printf.sprintf "  %%rp = getelementptr %%%s, ptr %%a, i32 0, i32 3" struct_name;
      "  %reg = load ptr, ptr %rp";
      Printf.sprintf "  %%new = call ptr @mere_vec_%s_new(ptr %%reg)" tag;
      (* Copy from a. *)
      Printf.sprintf "  %%alp = getelementptr %%%s, ptr %%a, i32 0, i32 1" struct_name;
      "  %alen = load i32, ptr %alp";
      Printf.sprintf "  %%adp = getelementptr %%%s, ptr %%a, i32 0, i32 0" struct_name;
      "  %adata = load ptr, ptr %adp";
      "  br label %check_a";
      "check_a:";
      "  %ai = phi i32 [ 0, %entry ], [ %ai_next, %body_a ]";
      "  %adone = icmp sge i32 %ai, %alen";
      "  br i1 %adone, label %prep_b, label %body_a";
      "body_a:";
      Printf.sprintf "  %%aslot = getelementptr %s, ptr %%adata, i32 %%ai" c_elem;
      Printf.sprintf "  %%aelem = load %s, ptr %%aslot" c_elem;
      Printf.sprintf "  call i32 @mere_vec_%s_push(ptr %%new, %s %%aelem)" tag c_elem;
      "  %ai_next = add i32 %ai, 1";
      "  br label %check_a";
      "prep_b:";
      Printf.sprintf "  %%blp = getelementptr %%%s, ptr %%b, i32 0, i32 1" struct_name;
      "  %blen = load i32, ptr %blp";
      Printf.sprintf "  %%bdp = getelementptr %%%s, ptr %%b, i32 0, i32 0" struct_name;
      "  %bdata = load ptr, ptr %bdp";
      "  br label %check_b";
      "check_b:";
      "  %bi = phi i32 [ 0, %prep_b ], [ %bi_next, %body_b ]";
      "  %bdone = icmp sge i32 %bi, %blen";
      "  br i1 %bdone, label %end, label %body_b";
      "body_b:";
      Printf.sprintf "  %%bslot = getelementptr %s, ptr %%bdata, i32 %%bi" c_elem;
      Printf.sprintf "  %%belem = load %s, ptr %%bslot" c_elem;
      Printf.sprintf "  call i32 @mere_vec_%s_push(ptr %%new, %s %%belem)" tag c_elem;
      "  %bi_next = add i32 %bi, 1";
      "  br label %check_b";
      "end:";
      "  ret ptr %new";
      "}" ]

(* Phase 19.3: vec_sort helper per element T — in-place insertion sort.
   Signature: i32 @mere_vec_<T>_sort(ptr v, %closure_<T>_<closure_<T>_int> cmp) *)
let emit_vec_sort_helper_llvm (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_elem = llvm_ty_of elem_ty in
  let struct_name = "mere_vec_" ^ tag in
  let inner_cl = closure_struct_name elem_ty Ast.TyInt in
  let outer_cl = closure_struct_name elem_ty
    (Ast.TyArrow (elem_ty, Ast.TyInt)) in
  String.concat "\n"
    [ Printf.sprintf "define i32 @mere_vec_%s_sort(ptr %%v, %%%s %%cmp) {"
        tag outer_cl;
      "entry:";
      Printf.sprintf "  %%outer_env = extractvalue %%%s %%cmp, 0" outer_cl;
      Printf.sprintf "  %%outer_fn = extractvalue %%%s %%cmp, 1" outer_cl;
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%v, i32 0, i32 1" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%dp = getelementptr %%%s, ptr %%v, i32 0, i32 0" struct_name;
      "  %data = load ptr, ptr %dp";
      "  br label %outer_check";
      "outer_check:";
      "  %i = phi i32 [ 1, %entry ], [ %i_next, %outer_done ]";
      "  %i_lt_len = icmp slt i32 %i, %len";
      "  br i1 %i_lt_len, label %outer_body, label %end";
      "outer_body:";
      Printf.sprintf "  %%key_slot = getelementptr %s, ptr %%data, i32 %%i" c_elem;
      Printf.sprintf "  %%key = load %s, ptr %%key_slot" c_elem;
      "  %j_init = sub i32 %i, 1";
      "  br label %inner_check";
      "inner_check:";
      "  %j = phi i32 [ %j_init, %outer_body ], [ %j_next, %shift ]";
      "  %j_ge_0 = icmp sge i32 %j, 0";
      "  br i1 %j_ge_0, label %do_cmp, label %finalize";
      "do_cmp:";
      Printf.sprintf "  %%j_slot = getelementptr %s, ptr %%data, i32 %%j" c_elem;
      Printf.sprintf "  %%j_val = load %s, ptr %%j_slot" c_elem;
      Printf.sprintf "  %%inner = call %%%s %%outer_fn(ptr %%outer_env, %s %%j_val)"
        inner_cl c_elem;
      Printf.sprintf "  %%inner_env = extractvalue %%%s %%inner, 0" inner_cl;
      Printf.sprintf "  %%inner_fn = extractvalue %%%s %%inner, 1" inner_cl;
      Printf.sprintf "  %%cmp_res = call i32 %%inner_fn(ptr %%inner_env, %s %%key)"
        c_elem;
      "  %need_shift = icmp sgt i32 %cmp_res, 0";
      "  br i1 %need_shift, label %shift, label %finalize";
      "shift:";
      "  %j_plus_1 = add i32 %j, 1";
      Printf.sprintf "  %%j1_slot = getelementptr %s, ptr %%data, i32 %%j_plus_1"
        c_elem;
      Printf.sprintf "  store %s %%j_val, ptr %%j1_slot" c_elem;
      "  %j_next = sub i32 %j, 1";
      "  br label %inner_check";
      "finalize:";
      "  %dst_idx = add i32 %j, 1";
      Printf.sprintf "  %%dst_slot = getelementptr %s, ptr %%data, i32 %%dst_idx"
        c_elem;
      Printf.sprintf "  store %s %%key, ptr %%dst_slot" c_elem;
      "  br label %outer_done";
      "outer_done:";
      "  %i_next = add i32 %i, 1";
      "  br label %outer_check";
      "end:";
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

(* Phase 19.2: map_iter helper per (K, V) pair.
   Signature: i32 @mere_map_<K>_<V>_iter(ptr m, %closure_<K>_<closure_<V>_unit> outer)
   outer: K -> (V -> unit). Apply outer(k) to get inner_cl, then inner_cl(v). *)
let emit_map_iter_helper_llvm (k_ty : Ast.ty) (v_ty : Ast.ty) : string =
  let k_tag = ty_tag k_ty in
  let v_tag = ty_tag v_ty in
  let c_k = llvm_ty_of k_ty in
  let c_v = llvm_ty_of v_ty in
  let struct_name = "mere_map_" ^ k_tag ^ "_" ^ v_tag in
  let inner_cl = closure_struct_name v_ty Ast.TyUnit in
  let outer_cl = closure_struct_name k_ty (Ast.TyArrow (v_ty, Ast.TyUnit)) in
  String.concat "\n"
    [ Printf.sprintf "define i32 @mere_map_%s_%s_iter(ptr %%m, %%%s %%outer) {"
        k_tag v_tag outer_cl;
      "entry:";
      Printf.sprintf "  %%outer_env = extractvalue %%%s %%outer, 0" outer_cl;
      Printf.sprintf "  %%outer_fn = extractvalue %%%s %%outer, 1" outer_cl;
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%m, i32 0, i32 2" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%kp = getelementptr %%%s, ptr %%m, i32 0, i32 0" struct_name;
      "  %keys = load ptr, ptr %kp";
      Printf.sprintf "  %%vp = getelementptr %%%s, ptr %%m, i32 0, i32 1" struct_name;
      "  %values = load ptr, ptr %vp";
      "  br label %check";
      "check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %body ]";
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %end, label %body";
      "body:";
      Printf.sprintf "  %%kslot = getelementptr %s, ptr %%keys, i32 %%i" c_k;
      Printf.sprintf "  %%k = load %s, ptr %%kslot" c_k;
      Printf.sprintf "  %%vslot = getelementptr %s, ptr %%values, i32 %%i" c_v;
      Printf.sprintf "  %%v = load %s, ptr %%vslot" c_v;
      Printf.sprintf "  %%inner = call %%%s %%outer_fn(ptr %%outer_env, %s %%k)"
        inner_cl c_k;
      Printf.sprintf "  %%inner_env = extractvalue %%%s %%inner, 0" inner_cl;
      Printf.sprintf "  %%inner_fn = extractvalue %%%s %%inner, 1" inner_cl;
      Printf.sprintf "  %%_ = call i32 %%inner_fn(ptr %%inner_env, %s %%v)" c_v;
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
   Region-preserving: the result Vec's region comes from v->region. *)
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
   Region-preserving. Branch on the closure's i1 return value via icmp / br. *)
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

(* Phase 15.8: OwnedVec registry — tracking for bulk-freeing at the end of
   main. Place a dynamic array of ptr + count / cap in file-scope globals.
   Each `@mere_owned_vec_<T>_new` calls register, and at the end of `@main`
   `@__mere_owned_vec_free_all` is called. *)
let owned_vec_registry_runtime_llvm =
  String.concat "\n"
    [ "; Phase 15.8: OwnedVec registry (bulk-free at process end)";
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
      "  ; The first field of mere_owned_vec_<T> is the data ptr. Same layout for all T.";
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
   Deep copy from input Vec[R, T] to output OwnedVec[T]. *)
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
   Deep copy from input OwnedVec[T] + region to output Vec[R, T]. *)
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
      "}";
      "";
      (* Phase 39.A' #2: delete — shift keys/values down to remove the key *)
      Printf.sprintf "define i32 @%s_delete(ptr %%m, %s %%k) {" fn_prefix c_k;
      "entry:";
      Printf.sprintf "  %%lp = getelementptr %%%s, ptr %%m, i32 0, i32 2" struct_name;
      "  %len = load i32, ptr %lp";
      Printf.sprintf "  %%kp = getelementptr %%%s, ptr %%m, i32 0, i32 0" struct_name;
      "  %keys = load ptr, ptr %kp";
      Printf.sprintf "  %%vp = getelementptr %%%s, ptr %%m, i32 0, i32 1" struct_name;
      "  %values = load ptr, ptr %vp";
      "  br label %find_check";
      "find_check:";
      "  %i = phi i32 [ 0, %entry ], [ %i_next, %find_cont ]";
      "  %done = icmp sge i32 %i, %len";
      "  br i1 %done, label %not_found, label %find_body";
      "find_body:";
      Printf.sprintf "  %%kslot = getelementptr %s, ptr %%keys, i32 %%i" c_k;
      Printf.sprintf "  %%cur_k = load %s, ptr %%kslot" c_k;
      emit_key_eq "%cur_k" "%k" "%eq";
      "  br i1 %eq, label %shift_init, label %find_cont";
      "find_cont:";
      "  %i_next = add i32 %i, 1";
      "  br label %find_check";
      "shift_init:";
      "  %found_at = phi i32 [ %i, %find_body ]";
      "  br label %shift_check";
      "shift_check:";
      "  %j = phi i32 [ %found_at, %shift_init ], [ %j_next, %shift_body ]";
      "  %j1 = add i32 %j, 1";
      "  %shift_done = icmp sge i32 %j1, %len";
      "  br i1 %shift_done, label %decrement, label %shift_body";
      "shift_body:";
      Printf.sprintf "  %%dst_k = getelementptr %s, ptr %%keys, i32 %%j" c_k;
      Printf.sprintf "  %%src_k = getelementptr %s, ptr %%keys, i32 %%j1" c_k;
      Printf.sprintf "  %%v_k = load %s, ptr %%src_k" c_k;
      Printf.sprintf "  store %s %%v_k, ptr %%dst_k" c_k;
      Printf.sprintf "  %%dst_v = getelementptr %s, ptr %%values, i32 %%j" c_v;
      Printf.sprintf "  %%src_v = getelementptr %s, ptr %%values, i32 %%j1" c_v;
      Printf.sprintf "  %%v_v = load %s, ptr %%src_v" c_v;
      Printf.sprintf "  store %s %%v_v, ptr %%dst_v" c_v;
      "  %j_next = add i32 %j, 1";
      "  br label %shift_check";
      "decrement:";
      "  %newlen = sub i32 %len, 1";
      "  store i32 %newlen, ptr %lp";
      "  ret i32 0";
      "not_found:";
      "  ret i32 0";
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
      (* to_str — Phase 36 (DEFERRED §1.16 fix): allocate result in the
         process-wide default region so the returned str outlives the
         StrBuf's scoped region. Avoids dangling pointers when
         `region R { ...; strbuf_to_str b }` escapes a value out of R. *)
      "define ptr @mere_strbuf_to_str(ptr %sb) {";
      "entry:";
      "  %lp = getelementptr %mere_strbuf, ptr %sb, i32 0, i32 1";
      "  %len = load i32, ptr %lp";
      "  %len1 = add i32 %len, 1";
      "  %len1_64 = zext i32 %len1 to i64";
      "  %out = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %len1_64)";
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

(* Phase 16.3 / DEFERRED §1.5: LLVM IR runtime for Logger / Metrics.
   Express the same printf-based implementation as the C side in IR. Assumes
   the Logger struct %Logger = type { %closure_str_unit, %closure_str_unit,
   %closure_str_unit } has already been emitted via record typedef. *)
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

(* Phase 34.2: float → string with interp parity (%.12g + trailing "." for
   whole numbers). asprintf to format → strchr-like loop to detect special
   chars → if none, asprintf with "." appended. *)
let float_helpers_llvm =
  String.concat "\n"
    [ "@.fmt_12g = private constant [6 x i8] c\"%.12g\\00\"";
      "@.fmt_dot = private constant [4 x i8] c\"%s.\\00\"";
      "";
      "define ptr @__lang_str_of_float(double %f) {";
      "entry:";
      "  %buf_ptr = alloca ptr";
      "  call i32 (ptr, ptr, ...) @asprintf(ptr %buf_ptr, ptr @.fmt_12g, double %f)";
      "  %buf = load ptr, ptr %buf_ptr";
      "  br label %loop";
      "loop:";
      "  %p = phi ptr [ %buf, %entry ], [ %p_next, %loop_cont ]";
      "  %c = load i8, ptr %p";
      "  %is_null = icmp eq i8 %c, 0";
      "  br i1 %is_null, label %no_dot, label %check_char";
      "check_char:";
      "  %c_dot = icmp eq i8 %c, 46";  (* '.' *)
      "  %c_e   = icmp eq i8 %c, 101"; (* 'e' *)
      "  %c_eu  = icmp eq i8 %c, 69";  (* 'E' *)
      "  %c_n   = icmp eq i8 %c, 110"; (* 'n' (nan) *)
      "  %c_i   = icmp eq i8 %c, 105"; (* 'i' (inf) *)
      "  %t1 = or i1 %c_dot, %c_e";
      "  %t2 = or i1 %t1, %c_eu";
      "  %t3 = or i1 %t2, %c_n";
      "  %is_special = or i1 %t3, %c_i";
      "  br i1 %is_special, label %has_dot, label %loop_cont";
      "loop_cont:";
      "  %p_next = getelementptr i8, ptr %p, i32 1";
      "  br label %loop";
      "has_dot:";
      "  ret ptr %buf";
      "no_dot:";
      "  %buf2_ptr = alloca ptr";
      "  call i32 (ptr, ptr, ...) @asprintf(ptr %buf2_ptr, ptr @.fmt_dot, ptr %buf)";
      "  %buf2 = load ptr, ptr %buf2_ptr";
      "  ret ptr %buf2";
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
      "}";
      "";
      (* Phase 19.1.1: str_index_of — needle position in haystack, -1 if
         not found. Empty needle returns 0. Uses libc strstr. *)
      "define i32 @__lang_str_index_of(ptr %h, ptr %n) {";
      "entry:";
      "  %nfirst = load i8, ptr %n";
      "  %is_empty = icmp eq i8 %nfirst, 0";
      "  br i1 %is_empty, label %ret0, label %dosearch";
      "ret0:";
      "  ret i32 0";
      "dosearch:";
      "  %p = call ptr @strstr(ptr %h, ptr %n)";
      "  %notfound = icmp eq ptr %p, null";
      "  br i1 %notfound, label %retneg, label %retdiff";
      "retneg:";
      "  ret i32 -1";
      "retdiff:";
      "  %diff = ptrtoint ptr %p to i64";
      "  %base = ptrtoint ptr %h to i64";
      "  %off = sub i64 %diff, %base";
      "  %r = trunc i64 %off to i32";
      "  ret i32 %r";
      "}";
      "";
      (* Phase 36: str_starts_with — bool *)
      "define i1 @__lang_str_starts_with(ptr %s, ptr %p) {";
      "entry:";
      "  %pl = call i64 @strlen(ptr %p)";
      "  %r = call i32 @strncmp(ptr %s, ptr %p, i64 %pl)";
      "  %ok = icmp eq i32 %r, 0";
      "  ret i1 %ok";
      "}";
      "";
      (* Phase 36: __lang_is_ws — ASCII whitespace test (space/tab/lf/cr/ff) *)
      "define i1 @__lang_is_ws(i8 %c) {";
      "entry:";
      "  %e1 = icmp eq i8 %c, 32";
      "  %e2 = icmp eq i8 %c, 9";
      "  %e3 = icmp eq i8 %c, 10";
      "  %e4 = icmp eq i8 %c, 13";
      "  %e5 = icmp eq i8 %c, 12";
      "  %o1 = or i1 %e1, %e2";
      "  %o2 = or i1 %o1, %e3";
      "  %o3 = or i1 %o2, %e4";
      "  %o4 = or i1 %o3, %e5";
      "  ret i1 %o4";
      "}";
      "";
      (* Phase 36: str_trim — leading + trailing whitespace strip *)
      "define ptr @__lang_str_trim(ptr %s) {";
      "entry:";
      "  br label %lead";
      "lead:";
      "  %p = phi ptr [ %s, %entry ], [ %p1, %lead_body ]";
      "  %c = load i8, ptr %p";
      "  %iz = icmp eq i8 %c, 0";
      "  br i1 %iz, label %trail_start, label %check";
      "check:";
      "  %iws = call i1 @__lang_is_ws(i8 %c)";
      "  br i1 %iws, label %lead_body, label %trail_start";
      "lead_body:";
      "  %p1 = getelementptr i8, ptr %p, i64 1";
      "  br label %lead";
      "trail_start:";
      "  %lenL = call i64 @strlen(ptr %p)";
      "  br label %trail";
      "trail:";
      "  %l = phi i64 [ %lenL, %trail_start ], [ %l1, %trail_body ]";
      "  %zz = icmp eq i64 %l, 0";
      "  br i1 %zz, label %alloc, label %trail_check";
      "trail_check:";
      "  %lm1 = sub i64 %l, 1";
      "  %tp = getelementptr i8, ptr %p, i64 %lm1";
      "  %tc = load i8, ptr %tp";
      "  %tw = call i1 @__lang_is_ws(i8 %tc)";
      "  br i1 %tw, label %trail_body, label %alloc";
      "trail_body:";
      "  %l1 = sub i64 %l, 1";
      "  br label %trail";
      "alloc:";
      "  %final_l = phi i64 [ %l, %trail ], [ %l, %trail_check ]";
      "  %cap = add i64 %final_l, 1";
      "  %buf = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %cap)";
      "  call ptr @memcpy(ptr %buf, ptr %p, i64 %final_l)";
      "  %term = getelementptr i8, ptr %buf, i64 %final_l";
      "  store i8 0, ptr %term";
      "  ret ptr %buf";
      "}";
      "";
      (* Phase 36: str_ends_with — bool *)
      "define i1 @__lang_str_ends_with(ptr %s, ptr %p) {";
      "entry:";
      "  %sl = call i64 @strlen(ptr %s)";
      "  %pl = call i64 @strlen(ptr %p)";
      "  %ok = icmp uge i64 %sl, %pl";
      "  br i1 %ok, label %do_cmp, label %ret_false";
      "ret_false:";
      "  ret i1 0";
      "do_cmp:";
      "  %off = sub i64 %sl, %pl";
      "  %tail = getelementptr i8, ptr %s, i64 %off";
      "  %r = call i32 @memcmp(ptr %tail, ptr %p, i64 %pl)";
      "  %eq = icmp eq i32 %r, 0";
      "  ret i1 %eq";
      "}";
      "";
      (* Phase 36: str_repeat *)
      "define ptr @__lang_str_repeat(ptr %s, i32 %n) {";
      "entry:";
      "  %neg = icmp sle i32 %n, 0";
      "  br i1 %neg, label %ret_empty, label %dowork";
      "ret_empty:";
      "  %empty = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 1)";
      "  store i8 0, ptr %empty";
      "  ret ptr %empty";
      "dowork:";
      "  %sl  = call i64 @strlen(ptr %s)";
      "  %n64 = sext i32 %n to i64";
      "  %tot = mul i64 %sl, %n64";
      "  %cap = add i64 %tot, 1";
      "  %buf = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %cap)";
      "  br label %loop";
      "loop:";
      "  %i = phi i32 [ 0, %dowork ], [ %inext, %body ]";
      "  %done = icmp sge i32 %i, %n";
      "  br i1 %done, label %finish, label %body";
      "body:";
      "  %i64 = sext i32 %i to i64";
      "  %off = mul i64 %i64, %sl";
      "  %bp  = getelementptr i8, ptr %buf, i64 %off";
      "  call ptr @memcpy(ptr %bp, ptr %s, i64 %sl)";
      "  %inext = add i32 %i, 1";
      "  br label %loop";
      "finish:";
      "  %tp = getelementptr i8, ptr %buf, i64 %tot";
      "  store i8 0, ptr %tp";
      "  ret ptr %buf";
      "}";
      "";
      (* Phase 36: str_rev *)
      "define ptr @__lang_str_rev(ptr %s) {";
      "entry:";
      "  %sl  = call i64 @strlen(ptr %s)";
      "  %cap = add i64 %sl, 1";
      "  %buf = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %cap)";
      "  br label %loop";
      "loop:";
      "  %i = phi i64 [ 0, %entry ], [ %inext, %body ]";
      "  %done = icmp uge i64 %i, %sl";
      "  br i1 %done, label %finish, label %body";
      "body:";
      "  %src_off = sub i64 %sl, %i";
      "  %src_off1 = sub i64 %src_off, 1";
      "  %sp = getelementptr i8, ptr %s, i64 %src_off1";
      "  %ch = load i8, ptr %sp";
      "  %dp = getelementptr i8, ptr %buf, i64 %i";
      "  store i8 %ch, ptr %dp";
      "  %inext = add i64 %i, 1";
      "  br label %loop";
      "finish:";
      "  %tp = getelementptr i8, ptr %buf, i64 %sl";
      "  store i8 0, ptr %tp";
      "  ret ptr %buf";
      "}";
      "";
      (* Phase 36: chr — return ptr to char_table entry for byte n.
         Mask to a single byte (n & 0xFF) so out-of-range input can't
         index past the 256-entry table into adjacent memory. Matches the
         C backend ((unsigned char)n) and the wasm backend. *)
      "define ptr @__lang_char_at_chr(i32 %n) {";
      "entry:";
      "  call void @__lang_char_table_setup()";
      "  %m = and i32 %n, 255";
      "  %n64 = zext i32 %m to i64";
      "  %p = getelementptr [256 x [2 x i8]], ptr @__lang_char_table, i64 0, i64 %n64";
      "  ret ptr %p";
      "}";
      "";
      (* Phase 36: to_upper / to_lower — ASCII case conversion. *)
      "define ptr @__lang_to_upper(ptr %s) {";
      "entry:";
      "  %sl  = call i64 @strlen(ptr %s)";
      "  %cap = add i64 %sl, 1";
      "  %buf = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %cap)";
      "  br label %loop";
      "loop:";
      "  %i = phi i64 [ 0, %entry ], [ %inext, %body ]";
      "  %done = icmp uge i64 %i, %sl";
      "  br i1 %done, label %finish, label %body";
      "body:";
      "  %sp = getelementptr i8, ptr %s, i64 %i";
      "  %c  = load i8, ptr %sp";
      "  %ge = icmp uge i8 %c, 97";
      "  %le = icmp ule i8 %c, 122";
      "  %lo = and i1 %ge, %le";
      "  %cm = sub i8 %c, 32";
      "  %nc = select i1 %lo, i8 %cm, i8 %c";
      "  %dp = getelementptr i8, ptr %buf, i64 %i";
      "  store i8 %nc, ptr %dp";
      "  %inext = add i64 %i, 1";
      "  br label %loop";
      "finish:";
      "  %tp = getelementptr i8, ptr %buf, i64 %sl";
      "  store i8 0, ptr %tp";
      "  ret ptr %buf";
      "}";
      "define ptr @__lang_to_lower(ptr %s) {";
      "entry:";
      "  %sl  = call i64 @strlen(ptr %s)";
      "  %cap = add i64 %sl, 1";
      "  %buf = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %cap)";
      "  br label %loop";
      "loop:";
      "  %i = phi i64 [ 0, %entry ], [ %inext, %body ]";
      "  %done = icmp uge i64 %i, %sl";
      "  br i1 %done, label %finish, label %body";
      "body:";
      "  %sp = getelementptr i8, ptr %s, i64 %i";
      "  %c  = load i8, ptr %sp";
      "  %ge = icmp uge i8 %c, 65";
      "  %le = icmp ule i8 %c, 90";
      "  %up = and i1 %ge, %le";
      "  %cm = add i8 %c, 32";
      "  %nc = select i1 %up, i8 %cm, i8 %c";
      "  %dp = getelementptr i8, ptr %buf, i64 %i";
      "  store i8 %nc, ptr %dp";
      "  %inext = add i64 %i, 1";
      "  br label %loop";
      "finish:";
      "  %tp = getelementptr i8, ptr %buf, i64 %sl";
      "  store i8 0, ptr %tp";
      "  ret ptr %buf";
      "}";
      "";
      (* Phase 36: gcd via iterative Euclid on |a|, |b|. *)
      "define i32 @__lang_gcd(i32 %a0, i32 %b0) {";
      "entry:";
      "  %aneg = icmp slt i32 %a0, 0";
      "  %na   = sub i32 0, %a0";
      "  %a1   = select i1 %aneg, i32 %na, i32 %a0";
      "  %bneg = icmp slt i32 %b0, 0";
      "  %nb   = sub i32 0, %b0";
      "  %b1   = select i1 %bneg, i32 %nb, i32 %b0";
      "  br label %loop";
      "loop:";
      "  %a = phi i32 [ %a1, %entry ], [ %b, %step ]";
      "  %b = phi i32 [ %b1, %entry ], [ %r, %step ]";
      "  %zz = icmp eq i32 %b, 0";
      "  br i1 %zz, label %done, label %step";
      "step:";
      "  %r = srem i32 %a, %b";
      "  br label %loop";
      "done:";
      "  ret i32 %a";
      "}";
      "";
      (* Phase 36: str_replace — replace all non-overlapping occurrences of
         `old` in `s` with `new_str`. Empty old returns s unchanged. *)
      "define ptr @__lang_str_replace(ptr %s, ptr %old, ptr %new_str) {";
      "entry:";
      "  %ofirst = load i8, ptr %old";
      "  %oempty = icmp eq i8 %ofirst, 0";
      "  br i1 %oempty, label %ret_s, label %dowork";
      "ret_s:";
      "  ret ptr %s";
      "dowork:";
      "  %slen = call i64 @strlen(ptr %s)";
      "  %olen = call i64 @strlen(ptr %old)";
      "  %nlen = call i64 @strlen(ptr %new_str)";
      (* Worst-case cap: slen + (slen/olen)*max(0, nlen-olen) + nlen + 1 *)
      "  %quot = udiv i64 %slen, %olen";
      "  %nbig = icmp ugt i64 %nlen, %olen";
      "  %diff = sub i64 %nlen, %olen";
      "  %sel  = select i1 %nbig, i64 %diff, i64 0";
      "  %grow = mul i64 %quot, %sel";
      "  %cap0 = add i64 %slen, %grow";
      "  %cap1 = add i64 %cap0, %nlen";
      "  %cap  = add i64 %cap1, 1";
      "  %buf  = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %cap)";
      "  br label %loop";
      "loop:";
      "  %i  = phi i64 [ 0, %dowork ], [ %i_next, %adv_match ], [ %i_next2, %adv_one ]";
      "  %bi = phi i64 [ 0, %dowork ], [ %bi_next, %adv_match ], [ %bi_next2, %adv_one ]";
      "  %done = icmp uge i64 %i, %slen";
      "  br i1 %done, label %finish, label %try_match";
      "try_match:";
      "  %rem = sub i64 %slen, %i";
      "  %fits = icmp uge i64 %rem, %olen";
      "  br i1 %fits, label %check_match, label %adv_one";
      "check_match:";
      "  %sp = getelementptr i8, ptr %s, i64 %i";
      "  %cmpr = call i32 @strncmp(ptr %sp, ptr %old, i64 %olen)";
      "  %eq = icmp eq i32 %cmpr, 0";
      "  br i1 %eq, label %adv_match, label %adv_one";
      "adv_match:";
      "  %bp = getelementptr i8, ptr %buf, i64 %bi";
      "  call ptr @memcpy(ptr %bp, ptr %new_str, i64 %nlen)";
      "  %i_next  = add i64 %i, %olen";
      "  %bi_next = add i64 %bi, %nlen";
      "  br label %loop";
      "adv_one:";
      "  %sp2 = getelementptr i8, ptr %s, i64 %i";
      "  %ch  = load i8, ptr %sp2";
      "  %bp2 = getelementptr i8, ptr %buf, i64 %bi";
      "  store i8 %ch, ptr %bp2";
      "  %i_next2  = add i64 %i, 1";
      "  %bi_next2 = add i64 %bi, 1";
      "  br label %loop";
      "finish:";
      "  %tp = getelementptr i8, ptr %buf, i64 %bi";
      "  store i8 0, ptr %tp";
      "  ret ptr %buf";
      "}";
      "";
      (* Phase 25.1 + 25.2: fail builtin. If try_or's jmpbuf is set,
         longjmp to it (rescue). Otherwise: print msg + abort. *)
      "define void @__lang_fail_impl(ptr %msg) noreturn {";
      "entry:";
      "  %set = load i32, ptr @__lang_fail_jmpbuf_set";
      "  %active = icmp ne i32 %set, 0";
      "  br i1 %active, label %do_jmp, label %do_abort";
      "do_jmp:";
      "  call void @longjmp(ptr @__lang_fail_jmpbuf, i32 1)";
      "  unreachable";
      "do_abort:";
      "  %p1 = call ptr @__lang_str_concat(ptr @.fail_prefix, ptr %msg)";
      "  call i32 @puts(ptr %p1)";
      "  call void @abort()";
      "  unreachable";
      "}";
      "define i32 @__lang_fail_int(ptr %msg) {";
      "entry:";
      "  call void @__lang_fail_impl(ptr %msg)";
      "  unreachable";
      "}";
      "define ptr @__lang_fail_str(ptr %msg) {";
      "entry:";
      "  call void @__lang_fail_impl(ptr %msg)";
      "  unreachable";
      "}";
      "";
      (* Phase 25.1: char builtins. char_at: per-byte from 256-entry
         static table (allocated at first call); is_X: inline tests. *)
      "@__lang_char_table = internal global [256 x [2 x i8]] zeroinitializer";
      "@__lang_char_table_init = internal global i32 0";
      "define void @__lang_char_table_setup() {";
      "entry:";
      "  %init = load i32, ptr @__lang_char_table_init";
      "  %already = icmp ne i32 %init, 0";
      "  br i1 %already, label %done, label %do_init";
      "do_init:";
      "  br label %loop";
      "loop:";
      "  %i = phi i32 [ 0, %do_init ], [ %next, %body ]";
      "  %cond = icmp slt i32 %i, 256";
      "  br i1 %cond, label %body, label %finish";
      "body:";
      "  %i64 = sext i32 %i to i64";
      "  %ent = getelementptr [256 x [2 x i8]], ptr @__lang_char_table, i64 0, i64 %i64";
      "  %i8 = trunc i32 %i to i8";
      "  store i8 %i8, ptr %ent";
      "  %ent2 = getelementptr [2 x i8], ptr %ent, i64 0, i64 1";
      "  store i8 0, ptr %ent2";
      "  %next = add i32 %i, 1";
      "  br label %loop";
      "finish:";
      "  store i32 1, ptr @__lang_char_table_init";
      "  br label %done";
      "done:";
      "  ret void";
      "}";
      "define ptr @__lang_char_at(ptr %s, i32 %i) {";
      "entry:";
      "  call void @__lang_char_table_setup()";
      "  %i64 = sext i32 %i to i64";
      "  %cp = getelementptr i8, ptr %s, i64 %i64";
      "  %c = load i8, ptr %cp";
      "  %cz = zext i8 %c to i64";
      "  %ent = getelementptr [256 x [2 x i8]], ptr @__lang_char_table, i64 0, i64 %cz";
      "  ret ptr %ent";
      "}";
      "define i1 @__lang_is_digit(ptr %s) {";
      "entry:";
      "  %c = load i8, ptr %s";
      "  %ge = icmp uge i8 %c, 48";
      "  %le = icmp ule i8 %c, 57";
      "  %r = and i1 %ge, %le";
      "  ret i1 %r";
      "}";
      "define i1 @__lang_is_alpha(ptr %s) {";
      "entry:";
      "  %c = load i8, ptr %s";
      "  %lge = icmp uge i8 %c, 97";
      "  %lle = icmp ule i8 %c, 122";
      "  %lo = and i1 %lge, %lle";
      "  %uge = icmp uge i8 %c, 65";
      "  %ule = icmp ule i8 %c, 90";
      "  %up = and i1 %uge, %ule";
      "  %r = or i1 %lo, %up";
      "  ret i1 %r";
      "}";
      "define i1 @__lang_is_space(ptr %s) {";
      "entry:";
      "  %c = load i8, ptr %s";
      "  %sp = icmp eq i8 %c, 32";
      "  %tb = icmp eq i8 %c, 9";
      "  %nl = icmp eq i8 %c, 10";
      "  %cr = icmp eq i8 %c, 13";
      "  %r1 = or i1 %sp, %tb";
      "  %r2 = or i1 %r1, %nl";
      "  %r3 = or i1 %r2, %cr";
      "  ret i1 %r3";
      "}";
      "";
      (* Phase 25.1: substring — region alloc + memcpy. *)
      "define ptr @__lang_substring(ptr %s, i32 %start, i32 %end_) {";
      "entry:";
      "  %lendiff = sub i32 %end_, %start";
      "  %neg = icmp slt i32 %lendiff, 0";
      "  %len = select i1 %neg, i32 0, i32 %lendiff";
      "  %len64 = sext i32 %len to i64";
      "  %sz = add i64 %len64, 1";
      "  %r = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %sz)";
      "  %start64 = sext i32 %start to i64";
      "  %srcp = getelementptr i8, ptr %s, i64 %start64";
      "  call ptr @memcpy(ptr %r, ptr %srcp, i64 %len64)";
      "  %endp = getelementptr i8, ptr %r, i64 %len64";
      "  store i8 0, ptr %endp";
      "  ret ptr %r";
      "}";
      "";
      (* Phase 25.4: str_unescape — interpret backslash-escape sequences
         (n / t / r / quote / backslash / slash) into the actual characters;
         leave others as-is. Used by json_parser etc. for string literal
         escape processing. Allocated in a region. *)
      "define ptr @__lang_str_unescape(ptr %s) {";
      "entry:";
      "  %n64 = call i64 @strlen(ptr %s)";
      "  %cap = add i64 %n64, 1";
      "  %r = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %cap)";
      "  br label %loop";
      "loop:";
      "  %i = phi i64 [0, %entry], [%i_next, %cont]";
      "  %j = phi i64 [0, %entry], [%j_next, %cont]";
      "  %done = icmp uge i64 %i, %n64";
      "  br i1 %done, label %finish, label %step";
      "step:";
      "  %sp = getelementptr i8, ptr %s, i64 %i";
      "  %c = load i8, ptr %sp";
      "  %is_bs = icmp eq i8 %c, 92";
      "  %i_plus_1 = add i64 %i, 1";
      "  %has_next = icmp ult i64 %i_plus_1, %n64";
      "  %can_esc = and i1 %is_bs, %has_next";
      "  br i1 %can_esc, label %esc, label %plain";
      "plain:";
      "  %dp1 = getelementptr i8, ptr %r, i64 %j";
      "  store i8 %c, ptr %dp1";
      "  %i_plain = add i64 %i, 1";
      "  %j_plain = add i64 %j, 1";
      "  br label %cont_plain";
      "cont_plain:";
      "  br label %cont";
      "esc:";
      "  %ep = getelementptr i8, ptr %s, i64 %i_plus_1";
      "  %ec = load i8, ptr %ep";
      "  %is_n = icmp eq i8 %ec, 110";
      "  %is_t = icmp eq i8 %ec, 116";
      "  %is_r = icmp eq i8 %ec, 114";
      "  %sel1 = select i1 %is_n, i8 10, i8 %ec";
      "  %sel2 = select i1 %is_t, i8 9, i8 %sel1";
      "  %sel3 = select i1 %is_r, i8 13, i8 %sel2";
      "  %dp2 = getelementptr i8, ptr %r, i64 %j";
      "  store i8 %sel3, ptr %dp2";
      "  %i_esc = add i64 %i, 2";
      "  %j_esc = add i64 %j, 1";
      "  br label %cont_esc";
      "cont_esc:";
      "  br label %cont";
      "cont:";
      "  %i_next = phi i64 [%i_plain, %cont_plain], [%i_esc, %cont_esc]";
      "  %j_next = phi i64 [%j_plain, %cont_plain], [%j_esc, %cont_esc]";
      "  br label %loop";
      "finish:";
      "  %endp = getelementptr i8, ptr %r, i64 %j";
      "  store i8 0, ptr %endp";
      "  ret ptr %r";
      "}";
      "";
      (* Phase 25.6: str_escape — show_str outputs through this; convert
         newline / tab / backslash / double-quote to backslash-escape form.
         Keeps parity with interp's show_str. Worst case 2x size; allocated
         in a region. *)
      "define ptr @__lang_str_escape(ptr %s) {";
      "entry:";
      "  %n64 = call i64 @strlen(ptr %s)";
      "  %n2 = mul i64 %n64, 2";
      "  %cap = add i64 %n2, 1";
      "  %r = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %cap)";
      "  br label %loop";
      "loop:";
      "  %i = phi i64 [0, %entry], [%i_next, %cont]";
      "  %j = phi i64 [0, %entry], [%j_next, %cont]";
      "  %done = icmp uge i64 %i, %n64";
      "  br i1 %done, label %finish, label %step";
      "step:";
      "  %sp = getelementptr i8, ptr %s, i64 %i";
      "  %c = load i8, ptr %sp";
      "  %is_n = icmp eq i8 %c, 10";
      "  %is_t = icmp eq i8 %c, 9";
      "  %is_r = icmp eq i8 %c, 13";
      "  %is_bs = icmp eq i8 %c, 92";
      "  %is_q = icmp eq i8 %c, 34";
      "  %is_nt = or i1 %is_n, %is_t";
      "  %is_ntr = or i1 %is_nt, %is_r";
      "  %is_ntrb = or i1 %is_ntr, %is_bs";
      "  %is_special = or i1 %is_ntrb, %is_q";
      "  br i1 %is_special, label %esc, label %plain";
      "plain:";
      "  %dp1 = getelementptr i8, ptr %r, i64 %j";
      "  store i8 %c, ptr %dp1";
      "  %j_plain = add i64 %j, 1";
      "  br label %cont_plain";
      "cont_plain:";
      "  br label %cont";
      "esc:";
      "  %dp2a = getelementptr i8, ptr %r, i64 %j";
      "  store i8 92, ptr %dp2a";
      "  %j_plus_1 = add i64 %j, 1";
      "  %dp2b = getelementptr i8, ptr %r, i64 %j_plus_1";
      "  %sel1 = select i1 %is_n, i8 110, i8 %c";
      "  %sel2 = select i1 %is_t, i8 116, i8 %sel1";
      "  %sel3 = select i1 %is_r, i8 114, i8 %sel2";
      "  store i8 %sel3, ptr %dp2b";
      "  %j_esc = add i64 %j, 2";
      "  br label %cont_esc";
      "cont_esc:";
      "  br label %cont";
      "cont:";
      "  %j_next = phi i64 [%j_plain, %cont_plain], [%j_esc, %cont_esc]";
      "  %i_next = add i64 %i, 1";
      "  br label %loop";
      "finish:";
      "  %endp = getelementptr i8, ptr %r, i64 %j";
      "  store i8 0, ptr %endp";
      "  ret ptr %r";
      "}" ]

(* Phase 25.9: str_count s needle — count non-overlapping occurrences. *)
let str_count_runtime_llvm =
  String.concat "\n"
    [ "define i32 @__lang_str_count(ptr %s, ptr %n) {";
      "entry:";
      "  %nl = call i64 @strlen(ptr %n)";
      "  %sl = call i64 @strlen(ptr %s)";
      "  %nz = icmp eq i64 %nl, 0";
      "  br i1 %nz, label %retz, label %loop";
      "retz:";
      "  ret i32 0";
      "loop:";
      "  %i = phi i64 [0, %entry], [%i_next, %cont]";
      "  %acc = phi i32 [0, %entry], [%acc_next, %cont]";
      "  %i_plus_nl = add i64 %i, %nl";
      "  %done = icmp ugt i64 %i_plus_nl, %sl";
      "  br i1 %done, label %finish, label %check";
      "check:";
      "  %sp = getelementptr i8, ptr %s, i64 %i";
      "  %r = call i32 @strncmp(ptr %sp, ptr %n, i64 %nl)";
      "  %is_match = icmp eq i32 %r, 0";
      "  br i1 %is_match, label %hit, label %skip";
      "hit:";
      "  %acc_hit = add i32 %acc, 1";
      "  %i_hit = add i64 %i, %nl";
      "  br label %cont_hit";
      "cont_hit:";
      "  br label %cont";
      "skip:";
      "  %i_skip = add i64 %i, 1";
      "  br label %cont_skip";
      "cont_skip:";
      "  br label %cont";
      "cont:";
      "  %i_next = phi i64 [%i_hit, %cont_hit], [%i_skip, %cont_skip]";
      "  %acc_next = phi i32 [%acc_hit, %cont_hit], [%acc, %cont_skip]";
      "  br label %loop";
      "finish:";
      "  ret i32 %acc";
      "}" ]

(* Phase 25.9: str_split / str_join — construct list_str (recursive variant)
   alloc'd in a region. The Cons cell's payload is boxed (Phase 25.0) =
   a ptr to `%tuple_str_list_str_node = { ptr_str, ptr_node }`. *)
let str_split_runtime_llvm =
  String.concat "\n"
    [ (* Helper: alloc + init a Nil cell. Returns ptr. *)
      "define ptr @__lang_list_str_nil() {";
      "entry:";
      "  %sz_p = getelementptr %list_str_node, ptr null, i32 1";
      "  %sz = ptrtoint ptr %sz_p to i64";
      "  %p = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %sz)";
      "  %tp = getelementptr %list_str_node, ptr %p, i32 0, i32 0";
      "  store i32 0, ptr %tp";
      "  ret ptr %p";
      "}";
      "";
      (* Helper: alloc + init a Cons cell with given head ptr and tail ptr. *)
      "define ptr @__lang_list_str_cons(ptr %head, ptr %tail) {";
      "entry:";
      "  %sz_p = getelementptr %list_str_node, ptr null, i32 1";
      "  %sz = ptrtoint ptr %sz_p to i64";
      "  %p = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %sz)";
      "  %tp = getelementptr %list_str_node, ptr %p, i32 0, i32 0";
      "  store i32 1, ptr %tp";
      (* Box the payload (tuple). *)
      "  %psz_p = getelementptr %tuple_str_list_str, ptr null, i32 1";
      "  %psz = ptrtoint ptr %psz_p to i64";
      "  %pl = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %psz)";
      "  %f0p = getelementptr %tuple_str_list_str, ptr %pl, i32 0, i32 0";
      "  store ptr %head, ptr %f0p";
      "  %f1p = getelementptr %tuple_str_list_str, ptr %pl, i32 0, i32 1";
      "  store ptr %tail, ptr %f1p";
      "  %plp = getelementptr %list_str_node, ptr %p, i32 0, i32 1";
      "  store ptr %pl, ptr %plp";
      "  ret ptr %p";
      "}";
      "";
      (* str_split: returns a list_str ptr. Build the list back-to-front
         by storing token slices in a stack-allocated array first, then
         linking Cons cells from last to first. *)
      "define ptr @__lang_str_split(ptr %s, ptr %delim) {";
      "entry:";
      "  %sl = call i64 @strlen(ptr %s)";
      "  %dl = call i64 @strlen(ptr %delim)";
      "  %dz = icmp eq i64 %dl, 0";
      "  br i1 %dz, label %empty_delim, label %count_init";
      "empty_delim:";
      "  %nil_e = call ptr @__lang_list_str_nil()";
      "  %cons_e = call ptr @__lang_list_str_cons(ptr %s, ptr %nil_e)";
      "  ret ptr %cons_e";
      (* Pass 1: count delim occurrences → token count = count + 1. *)
      "count_init:";
      "  br label %count_loop";
      "count_loop:";
      "  %ci = phi i64 [0, %count_init], [%ci_next, %count_cont]";
      "  %count = phi i64 [0, %count_init], [%count_next, %count_cont]";
      "  %ci_plus_dl = add i64 %ci, %dl";
      "  %ci_done = icmp ugt i64 %ci_plus_dl, %sl";
      "  br i1 %ci_done, label %alloc_arrays, label %count_check";
      "count_check:";
      "  %csp = getelementptr i8, ptr %s, i64 %ci";
      "  %ccmp = call i32 @strncmp(ptr %csp, ptr %delim, i64 %dl)";
      "  %cis_hit = icmp eq i32 %ccmp, 0";
      "  br i1 %cis_hit, label %count_hit, label %count_skip";
      "count_hit:";
      "  %ci_hit = add i64 %ci, %dl";
      "  %count_hit_v = add i64 %count, 1";
      "  br label %count_cont";
      "count_skip:";
      "  %ci_skip = add i64 %ci, 1";
      "  br label %count_cont";
      "count_cont:";
      "  %ci_next = phi i64 [%ci_hit, %count_hit], [%ci_skip, %count_skip]";
      "  %count_next = phi i64 [%count_hit_v, %count_hit], [%count, %count_skip]";
      "  br label %count_loop";
      (* Allocate parallel arrays of (start, len) — i64 each. *)
      "alloc_arrays:";
      "  %n_tokens = add i64 %count, 1";
      "  %n_bytes = mul i64 %n_tokens, 8";
      "  %starts = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %n_bytes)";
      "  %lens = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %n_bytes)";
      "  br label %fill_loop";
      (* Pass 2: extract tokens, store (start, len) into arrays. *)
      "fill_loop:";
      "  %fi = phi i64 [0, %alloc_arrays], [%fi_next, %fill_cont]";
      "  %tstart = phi i64 [0, %alloc_arrays], [%tstart_next, %fill_cont]";
      "  %tidx = phi i64 [0, %alloc_arrays], [%tidx_next, %fill_cont]";
      "  %fi_plus_dl = add i64 %fi, %dl";
      "  %fi_done = icmp ugt i64 %fi_plus_dl, %sl";
      "  br i1 %fi_done, label %fill_last, label %fill_check";
      "fill_check:";
      "  %fsp = getelementptr i8, ptr %s, i64 %fi";
      "  %fcmp = call i32 @strncmp(ptr %fsp, ptr %delim, i64 %dl)";
      "  %fis_hit = icmp eq i32 %fcmp, 0";
      "  br i1 %fis_hit, label %fill_hit, label %fill_skip";
      "fill_hit:";
      (* Record token: start=tstart, len=fi-tstart. *)
      "  %tlen = sub i64 %fi, %tstart";
      "  %sp_dst = getelementptr i64, ptr %starts, i64 %tidx";
      "  store i64 %tstart, ptr %sp_dst";
      "  %lp_dst = getelementptr i64, ptr %lens, i64 %tidx";
      "  store i64 %tlen, ptr %lp_dst";
      "  %fi_hit = add i64 %fi, %dl";
      "  %tstart_hit = add i64 %fi, %dl";
      "  %tidx_hit = add i64 %tidx, 1";
      "  br label %fill_cont";
      "fill_skip:";
      "  %fi_skip = add i64 %fi, 1";
      "  br label %fill_cont";
      "fill_cont:";
      "  %fi_next = phi i64 [%fi_hit, %fill_hit], [%fi_skip, %fill_skip]";
      "  %tstart_next = phi i64 [%tstart_hit, %fill_hit], [%tstart, %fill_skip]";
      "  %tidx_next = phi i64 [%tidx_hit, %fill_hit], [%tidx, %fill_skip]";
      "  br label %fill_loop";
      "fill_last:";
      (* The last token: start=tstart, len=sl-tstart. *)
      "  %ltlen = sub i64 %sl, %tstart";
      "  %lsp_dst = getelementptr i64, ptr %starts, i64 %tidx";
      "  store i64 %tstart, ptr %lsp_dst";
      "  %llp_dst = getelementptr i64, ptr %lens, i64 %tidx";
      "  store i64 %ltlen, ptr %llp_dst";
      (* Now build Cons cells back-to-front. n_tokens = count + 1. *)
      "  %nil_c = call ptr @__lang_list_str_nil()";
      "  br label %build_loop";
      "build_loop:";
      "  %bi = phi i64 [%n_tokens, %fill_last], [%bi_dec, %build_step]";
      "  %tail_b = phi ptr [%nil_c, %fill_last], [%cell_new, %build_step]";
      "  %bi_zero = icmp eq i64 %bi, 0";
      "  br i1 %bi_zero, label %build_done, label %build_step";
      "build_step:";
      "  %bi_dec = sub i64 %bi, 1";
      "  %bsp_src = getelementptr i64, ptr %starts, i64 %bi_dec";
      "  %bstart = load i64, ptr %bsp_src";
      "  %blp_src = getelementptr i64, ptr %lens, i64 %bi_dec";
      "  %blen = load i64, ptr %blp_src";
      "  %btk_cap = add i64 %blen, 1";
      "  %btk = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %btk_cap)";
      "  %btk_src = getelementptr i8, ptr %s, i64 %bstart";
      "  call ptr @memcpy(ptr %btk, ptr %btk_src, i64 %blen)";
      "  %btk_end = getelementptr i8, ptr %btk, i64 %blen";
      "  store i8 0, ptr %btk_end";
      "  %cell_new = call ptr @__lang_list_str_cons(ptr %btk, ptr %tail_b)";
      "  br label %build_loop";
      "build_done:";
      "  ret ptr %tail_b";
      "}" ]

let str_join_runtime_llvm =
  String.concat "\n"
    [ (* str_join: walks list_str, concats with sep. *)
      "define ptr @__lang_str_join(ptr %sep, ptr %xs) {";
      "entry:";
      "  %sl = call i64 @strlen(ptr %sep)";
      (* First pass: compute total length. *)
      "  br label %len_loop";
      "len_loop:";
      "  %cur1 = phi ptr [%xs, %entry], [%next1, %len_cons]";
      "  %total = phi i64 [0, %entry], [%total_n, %len_cons]";
      "  %first = phi i1 [1, %entry], [0, %len_cons]";
      "  %tagp1 = getelementptr %list_str_node, ptr %cur1, i32 0, i32 0";
      "  %tag1 = load i32, ptr %tagp1";
      "  %is_nil = icmp eq i32 %tag1, 0";
      "  br i1 %is_nil, label %alloc, label %len_cons";
      "len_cons:";
      "  %plp1 = getelementptr %list_str_node, ptr %cur1, i32 0, i32 1";
      "  %pl_box1 = load ptr, ptr %plp1";
      "  %pl1 = load %tuple_str_list_str, ptr %pl_box1";
      "  %head1 = extractvalue %tuple_str_list_str %pl1, 0";
      "  %next1 = extractvalue %tuple_str_list_str %pl1, 1";
      "  %hl = call i64 @strlen(ptr %head1)";
      "  %add_sep = select i1 %first, i64 0, i64 %sl";
      "  %t1 = add i64 %total, %add_sep";
      "  %total_n = add i64 %t1, %hl";
      "  br label %len_loop";
      "alloc:";
      "  %cap = add i64 %total, 1";
      "  %r = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %cap)";
      "  br label %write_loop";
      "write_loop:";
      "  %cur2 = phi ptr [%xs, %alloc], [%next2, %w_join]";
      "  %pos = phi i64 [0, %alloc], [%pos_n, %w_join]";
      "  %first2 = phi i1 [1, %alloc], [0, %w_join]";
      "  %tagp2 = getelementptr %list_str_node, ptr %cur2, i32 0, i32 0";
      "  %tag2 = load i32, ptr %tagp2";
      "  %is_nil2 = icmp eq i32 %tag2, 0";
      "  br i1 %is_nil2, label %finish, label %write_cons";
      "write_cons:";
      "  %plp2 = getelementptr %list_str_node, ptr %cur2, i32 0, i32 1";
      "  %pl_box2 = load ptr, ptr %plp2";
      "  %pl2 = load %tuple_str_list_str, ptr %pl_box2";
      "  %head2 = extractvalue %tuple_str_list_str %pl2, 0";
      "  %next2 = extractvalue %tuple_str_list_str %pl2, 1";
      "  br i1 %first2, label %w_no_sep, label %w_with_sep";
      "w_no_sep:";
      "  br label %w_join";
      "w_with_sep:";
      "  %sep_dst = getelementptr i8, ptr %r, i64 %pos";
      "  call ptr @memcpy(ptr %sep_dst, ptr %sep, i64 %sl)";
      "  %pos_added = add i64 %pos, %sl";
      "  br label %w_join";
      "w_join:";
      "  %pos_after_sep = phi i64 [%pos, %w_no_sep], [%pos_added, %w_with_sep]";
      "  %hl2 = call i64 @strlen(ptr %head2)";
      "  %h_dst = getelementptr i8, ptr %r, i64 %pos_after_sep";
      "  call ptr @memcpy(ptr %h_dst, ptr %head2, i64 %hl2)";
      "  %pos_n = add i64 %pos_after_sep, %hl2";
      "  br label %write_loop";
      "finish:";
      "  %endp = getelementptr i8, ptr %r, i64 %total";
      "  store i8 0, ptr %endp";
      "  ret ptr %r";
      "}" ]

let file_io_runtime_llvm =
  String.concat "\n"
    [ "declare ptr @fopen(ptr, ptr)";
      "declare i32 @fclose(ptr)";
      "declare i32 @fseek(ptr, i64, i32)";
      "declare i64 @ftell(ptr)";
      "declare i64 @fread(ptr, i64, i64, ptr)";
      "declare i64 @fwrite(ptr, i64, i64, ptr)";
      "@.fopen_rb = internal constant [3 x i8] c\"rb\\00\"";
      "@.fopen_wb = internal constant [3 x i8] c\"wb\\00\"";
      "@.file_err = internal constant [22 x i8] c\"file open failed\\00\\00\\00\\00\\00\\00\"";
      "";
      "define ptr @__lang_read_file(ptr %path) {";
      "entry:";
      "  %f = call ptr @fopen(ptr %path, ptr @.fopen_rb)";
      "  %is_null = icmp eq ptr %f, null";
      "  br i1 %is_null, label %fail, label %ok";
      "fail:";
      "  call void @__lang_fail_impl(ptr %path)";
      "  unreachable";
      "ok:";
      "  %_se = call i32 @fseek(ptr %f, i64 0, i32 2)";  (* SEEK_END *)
      "  %len64 = call i64 @ftell(ptr %f)";
      "  %_ss = call i32 @fseek(ptr %f, i64 0, i32 0)";  (* SEEK_SET *)
      "  %cap = add i64 %len64, 1";
      "  %buf = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %cap)";
      "  %is_zero = icmp eq i64 %len64, 0";
      "  br i1 %is_zero, label %skip_read, label %do_read";
      "do_read:";
      "  %_r = call i64 @fread(ptr %buf, i64 1, i64 %len64, ptr %f)";
      "  br label %skip_read";
      "skip_read:";
      "  %endp = getelementptr i8, ptr %buf, i64 %len64";
      "  store i8 0, ptr %endp";
      "  %_c = call i32 @fclose(ptr %f)";
      "  ret ptr %buf";
      "}";
      "";
      "define i32 @__lang_write_file(ptr %path, ptr %content) {";
      "entry:";
      "  %f = call ptr @fopen(ptr %path, ptr @.fopen_wb)";
      "  %is_null = icmp eq ptr %f, null";
      "  br i1 %is_null, label %fail, label %ok";
      "fail:";
      "  call void @__lang_fail_impl(ptr %path)";
      "  unreachable";
      "ok:";
      "  %len64 = call i64 @strlen(ptr %content)";
      "  %is_zero = icmp eq i64 %len64, 0";
      "  br i1 %is_zero, label %skip_write, label %do_write";
      "do_write:";
      "  %_w = call i64 @fwrite(ptr %content, i64 1, i64 %len64, ptr %f)";
      "  br label %skip_write";
      "skip_write:";
      "  %_c = call i32 @fclose(ptr %f)";
      "  ret i32 0";
      "}" ]

(* Q-012: the spawn trampoline. pthread_create runs it with a heap-allocated
   {env, fn} pair; it invokes the closure as fn(env, unit=0) and frees the
   pair. Closure fns lower to `i32 (ptr, i32)` for a unit -> unit closure. *)
let thread_runtime_llvm =
  String.concat "\n"
    [ "define ptr @__mere_spawn_trampoline(ptr %p) {";
      "entry:";
      "  %env = load ptr, ptr %p";
      "  %fnslot = getelementptr i8, ptr %p, i64 8";
      "  %fn = load ptr, ptr %fnslot";
      "  %r = call i32 %fn(ptr %env, i32 0)";
      "  call void @free(ptr %p)";
      "  ret ptr null";
      "}" ]

(* Q-012: a single generic channel runtime. Every Mere LLVM value (i32 / i1 /
   double / ptr) fits in 8 bytes, so channel elements are carried as i64
   slots — the send/recv sites cast to/from i64. A heap-allocated fixed-cap
   ring buffer guarded by a mutex + condition variable; recv blocks on the
   condition until non-empty. mutex/cond are heap blocks (64 bytes covers the
   platform's pthread structs) so the struct layout stays platform-agnostic. *)
let channel_runtime_llvm =
  String.concat "\n"
    [ "%mere_channel = type { ptr, i32, i32, i32, ptr, ptr }";
      "";
      "define ptr @mere_channel_new() {";
      "entry:";
      "  %szp = getelementptr %mere_channel, ptr null, i32 1";
      "  %sz = ptrtoint ptr %szp to i64";
      "  %ch = call ptr @malloc(i64 %sz)";
      "  %buf = call ptr @malloc(i64 524288)";  (* 65536 slots * 8 bytes *)
      "  store ptr %buf, ptr %ch";
      "  %lenp = getelementptr %mere_channel, ptr %ch, i32 0, i32 1";
      "  store i32 0, ptr %lenp";
      "  %capp = getelementptr %mere_channel, ptr %ch, i32 0, i32 2";
      "  store i32 65536, ptr %capp";
      "  %headp = getelementptr %mere_channel, ptr %ch, i32 0, i32 3";
      "  store i32 0, ptr %headp";
      "  %m = call ptr @malloc(i64 64)";
      "  %r0 = call i32 @pthread_mutex_init(ptr %m, ptr null)";
      "  %mp = getelementptr %mere_channel, ptr %ch, i32 0, i32 4";
      "  store ptr %m, ptr %mp";
      "  %c = call ptr @malloc(i64 64)";
      "  %r1 = call i32 @pthread_cond_init(ptr %c, ptr null)";
      "  %cp = getelementptr %mere_channel, ptr %ch, i32 0, i32 5";
      "  store ptr %c, ptr %cp";
      "  ret ptr %ch";
      "}";
      "";
      "define i32 @mere_channel_send(ptr %ch, i64 %v) {";
      "entry:";
      "  %mp = getelementptr %mere_channel, ptr %ch, i32 0, i32 4";
      "  %m = load ptr, ptr %mp";
      "  %r0 = call i32 @pthread_mutex_lock(ptr %m)";
      "  %lenp = getelementptr %mere_channel, ptr %ch, i32 0, i32 1";
      "  %len = load i32, ptr %lenp";
      "  %capp = getelementptr %mere_channel, ptr %ch, i32 0, i32 2";
      "  %cap = load i32, ptr %capp";
      "  %full = icmp sge i32 %len, %cap";
      "  br i1 %full, label %oom, label %ok";
      "oom:";
      "  call void @abort()";
      "  unreachable";
      "ok:";
      "  %headp = getelementptr %mere_channel, ptr %ch, i32 0, i32 3";
      "  %head = load i32, ptr %headp";
      "  %pos0 = add i32 %head, %len";
      "  %pos = srem i32 %pos0, %cap";
      "  %pos64 = sext i32 %pos to i64";
      "  %bufp = getelementptr %mere_channel, ptr %ch, i32 0, i32 0";
      "  %buf = load ptr, ptr %bufp";
      "  %slot = getelementptr i64, ptr %buf, i64 %pos64";
      "  store i64 %v, ptr %slot";
      "  %len1 = add i32 %len, 1";
      "  store i32 %len1, ptr %lenp";
      "  %cp = getelementptr %mere_channel, ptr %ch, i32 0, i32 5";
      "  %c = load ptr, ptr %cp";
      "  %r1 = call i32 @pthread_cond_signal(ptr %c)";
      "  %r2 = call i32 @pthread_mutex_unlock(ptr %m)";
      "  ret i32 0";
      "}";
      "";
      "define i64 @mere_channel_recv(ptr %ch) {";
      "entry:";
      "  %mp = getelementptr %mere_channel, ptr %ch, i32 0, i32 4";
      "  %m = load ptr, ptr %mp";
      "  %r0 = call i32 @pthread_mutex_lock(ptr %m)";
      "  %lenp = getelementptr %mere_channel, ptr %ch, i32 0, i32 1";
      "  br label %wait";
      "wait:";
      "  %len = load i32, ptr %lenp";
      "  %empty = icmp eq i32 %len, 0";
      "  br i1 %empty, label %block, label %ready";
      "block:";
      "  %cp = getelementptr %mere_channel, ptr %ch, i32 0, i32 5";
      "  %c = load ptr, ptr %cp";
      "  %rw = call i32 @pthread_cond_wait(ptr %c, ptr %m)";
      "  br label %wait";
      "ready:";
      "  %headp = getelementptr %mere_channel, ptr %ch, i32 0, i32 3";
      "  %head = load i32, ptr %headp";
      "  %capp = getelementptr %mere_channel, ptr %ch, i32 0, i32 2";
      "  %cap = load i32, ptr %capp";
      "  %bufp = getelementptr %mere_channel, ptr %ch, i32 0, i32 0";
      "  %buf = load ptr, ptr %bufp";
      "  %head64 = sext i32 %head to i64";
      "  %slot = getelementptr i64, ptr %buf, i64 %head64";
      "  %v = load i64, ptr %slot";
      "  %head1 = add i32 %head, 1";
      "  %headm = srem i32 %head1, %cap";
      "  store i32 %headm, ptr %headp";
      "  %len2 = load i32, ptr %lenp";
      "  %len2d = sub i32 %len2, 1";
      "  store i32 %len2d, ptr %lenp";
      "  %r2 = call i32 @pthread_mutex_unlock(ptr %m)";
      "  ret i64 %v";
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
  Hashtbl.reset inner_lift_closures_emitted_llvm;
  inner_lift_closure_pending_llvm := [];
  Hashtbl.reset toplevel_fn_names;
  Hashtbl.reset multi_inst_fns_llvm;
  Hashtbl.reset polymorphic_variants;
  Hashtbl.reset polymorphic_records;
  Hashtbl.reset mono_variant_instances;
  Hashtbl.reset mono_record_instances;
  Hashtbl.reset recursive_variants;
  Hashtbl.reset show_types;
  Hashtbl.reset vec_instances;
  Hashtbl.reset vec_iter_instances;
  Hashtbl.reset map_iter_instances;
  Hashtbl.reset vec_sort_instances;
  Hashtbl.reset vec_fold_instances;
  Hashtbl.reset vec_map_instances;
  Hashtbl.reset vec_filter_instances;
  Hashtbl.reset owned_vec_instances;
  Hashtbl.reset map_instances;
  Hashtbl.reset vec_to_list_instances;
  strbuf_used := false;
  str_split_used_llvm := false;
  str_join_used_llvm := false;
  str_count_used_llvm := false;
  file_io_used_llvm := false;
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
  (* Phase 32.3 (C1 FFI): walk prog.decls to register extern fn names. *)
  Hashtbl.reset extern_fn_decls_llvm;
  List.iter (fun decl ->
    match decl with
    | Ast.Top_extern (name, ty) ->
      Hashtbl.replace extern_fn_decls_llvm name (Ast.walk ty)
    | _ -> ()
  ) prog.decls;
  (* Lift top-level fn bindings; the remainder is the actual main body. *)
  let skels, body_expr = lift_fn_skels main_expr in
  List.iter (fun s -> Hashtbl.replace toplevel_fn_names s.sname ()) skels;
  (* Phase 30.2b (DEFERRED §1.10): make those top-level non-fn lets that are
     referenced from skels' fn bodies into @name LLVM globals. Unreferenced
     ones stay as let-in in the body (= alloca / register). *)
  let fvs_used_in_skels_llvm =
    List.fold_left (fun acc s ->
      let fvs = free_vars s.sbody [s.sparam] in
      List.sort_uniq compare (fvs @ acc))
      [] skels
  in
  let needs_global_llvm name = List.mem name fvs_used_in_skels_llvm in
  (* Phase 36 (DEFERRED §1.18 fix): keep Let bindings in body_expr so
     globals get initialized at their source-order position (via
     `store` emit_expr Let). We only collect (name, ty) for declaring
     `@name = internal global`. *)
  let top_globals_list =
    let rec go e =
      match e.Ast.node with
      | Ast.Let (pat, value, rest) ->
        (match pat.Ast.pnode with
         | Ast.P_var name when needs_global_llvm name ->
           (match value.Ast.node with
            | Ast.Fun _ -> go rest
            | _ ->
              let ty = match value.Ast.ty with
                | Some t -> Ast.walk t | None -> Ast.TyInt
              in
              (name, value, ty) :: go rest)
         | _ -> go rest)
      | _ -> []
    in
    go body_expr
  in
  Hashtbl.reset top_globals_llvm;
  List.iter (fun (n, _, ty) -> Hashtbl.add top_globals_llvm n ty) top_globals_list;
  Hashtbl.reset eta_adapters_llvm;
  let fns = resolve_fn_types skels main_expr in
  (* Phase 25.7: dedupe by name, keeping the LAST occurrence — when user
     defines a name (e.g. `let rec list_rev_into = ...`) that's also in the
     stdlib prelude, the user's definition (later in the let chain) should
     shadow the stdlib one. Without this, both would emit and cause a
     redefinition error at link time. *)
  let fns =
    let seen : (string, unit) Hashtbl.t = Hashtbl.create 16 in
    List.rev (
      List.fold_left (fun acc f ->
        if Hashtbl.mem seen f.name then acc
        else begin Hashtbl.add seen f.name (); f :: acc end
      ) [] (List.rev fns)
    )
  in
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
  (* Phase 25.3: lift inner fns to top-level. Must run BEFORE
     emit_fn_def so emit_expr can see inner_lifts_llvm during body emit.
     Phase 25.5: include multi-inst base names (un-mangled) so inner
     fn free_var analysis treats `rev` etc. as a known toplevel — the
     call site rewrites to the mangled spec at emit time. *)
  let mangled_names = List.map (fun f -> f.name) fns in
  let multi_base_names =
    Hashtbl.fold (fun k _ acc -> k :: acc) multi_inst_fns_llvm []
  in
  let toplevel_names = mangled_names @ multi_base_names in
  lift_inner_fns_llvm toplevel_names fns;
  let fn_defs =
    List.map (fun f ->
      set_inner_lifts_for_host_llvm f.name;
      emit_fn_def f) fns
  in
  let lifted_defs = List.map emit_lifted_fn_llvm !lifted_fns_llvm in
  let closure_adapters = List.map emit_closure_adapter fns in
  (* Reset counters for the main body. *)
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
  emit_instr "entry:";
  emit_instr
    "  call void @__lang_region_init(ptr @__lang_default_region, i64 4194304)";
  (* Phase 36 (DEFERRED §1.18 fix): globals are initialized inline in
     body_expr (the Let bindings stayed in body and emit_expr Let emits
     `store ... @name`). No upfront init needed. *)
  ignore top_globals_list;
  let r = emit_expr [] body_expr in
  (* Optional printf of main result. *)
  let print_lines =
    match main_format_of main_ty with
    | None -> []
    | Some ("unit", _) ->
      (* Phase 25.11: print literal "()" for unit-typed main, matching
         interp's Eval.to_string V_unit. *)
      [ "  call i32 (ptr, ...) @printf(ptr @.fmt_unit)" ]
    | Some ("double", _) ->
      (* Phase 34.2: float main — to match the format of interp's
         string_of_float (OCaml's %.12g + trailing "." for whole numbers),
         go through the __lang_str_of_float helper then puts. *)
      let str_r = fresh_reg () in
      [ Printf.sprintf "  %s = call ptr @__lang_str_of_float(double %s)" str_r r;
        Printf.sprintf "  call i32 @puts(ptr %s)" str_r ]
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
    | Some ("unit", _) ->
      (* Phase 25.11: "()\n\0" — 4 bytes. *)
      [ "@.fmt_unit = private constant [4 x i8] c\"()\\0A\\00\"" ]
    | _ -> []
  in
  (* Phase 15.3: Vec[R, T] runtime — emit one struct typedef + 4 helper
     functions per element type seen during fn / main emission. *)
  let vec_runtimes =
    Hashtbl.fold (fun _tag elem_ty acc ->
      emit_vec_runtime_for_llvm elem_ty :: acc) vec_instances []
  in
  (* Phase 19.3: vec_reverse / vec_concat — emit per element type seen.
     Emitted for ALL vec_instances regardless of use, simple and harmless
     (LLVM optimizes away if unreferenced). *)
  let vec_reverse_concat_helpers =
    Hashtbl.fold (fun _tag elem_ty acc ->
      emit_vec_reverse_helper_llvm elem_ty
      :: emit_vec_concat_helper_llvm elem_ty
      :: acc) vec_instances []
  in
  let vec_sort_helpers =
    Hashtbl.fold (fun _tag elem_ty acc ->
      emit_vec_sort_helper_llvm elem_ty :: acc) vec_sort_instances []
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
  let map_iter_helpers =
    Hashtbl.fold (fun _key (k_ty, v_ty) acc ->
      emit_map_iter_helper_llvm k_ty v_ty :: acc) map_iter_instances []
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
    @ (if !inner_lift_closure_pending_llvm = [] then []
       else
         List.rev_map (fun (lifted_name, captures, _, _) ->
           let env_fields =
             if captures = [] then "i8"  (* placeholder for zero-size *)
             else
               String.concat ", "
                 (List.map (fun (_, ty) -> llvm_ty_of ty) captures)
           in
           Printf.sprintf "%%%s_env = type { %s }" lifted_name env_fields)
         !inner_lift_closure_pending_llvm
         @ [""])
    @ (if !str_globals = [] then [] else List.rev !str_globals @ [""])
    @ (if !show_string_globals = [] then []
       else List.rev !show_string_globals @ [""])
    @ (if !show_format_globals = [] then []
       else List.rev !show_format_globals @ [""])
    @ format_globals
    @ [ "";
        runtime_decls;
        "";
        thread_runtime_llvm;
        "";
        channel_runtime_llvm;
        "";
        region_runtime_helpers;
        "";
        str_concat_helper;
        "";
        float_helpers_llvm;
        "" ]
    @ (if vec_runtimes = [] then [] else vec_runtimes @ [""])
    @ (if vec_reverse_concat_helpers = [] then []
       else vec_reverse_concat_helpers @ [""])
    @ (if vec_sort_helpers = [] then [] else vec_sort_helpers @ [""])
    @ (if owned_vec_runtimes = [] then []
       else owned_vec_registry_runtime_llvm :: "" :: owned_vec_runtimes @ [""])
    @ (if !strbuf_used then [strbuf_runtime_llvm; ""] else [])
    @ (if !str_count_used_llvm then [str_count_runtime_llvm; ""] else [])
    @ (if !str_split_used_llvm then [str_split_runtime_llvm; ""] else [])
    @ (if !str_join_used_llvm then [str_join_runtime_llvm; ""] else [])
    @ (if !file_io_used_llvm then [file_io_runtime_llvm; ""] else [])
    @ (if !logger_used then [logger_runtime_llvm; ""] else [])
    @ (if !metrics_used then [metrics_runtime_llvm; ""] else [])
    @ (if map_key_eq_helpers = [] then [] else map_key_eq_helpers @ [""])
    @ (if map_runtimes = [] then [] else map_runtimes @ [""])
    @ (if map_iter_helpers = [] then [] else map_iter_helpers @ [""])
    @ (if vec_to_list_helpers = [] then [] else vec_to_list_helpers @ [""])
    @ (if list_len_helpers = [] then [] else list_len_helpers @ [""])
    @ (if vec_iter_helpers = [] then [] else vec_iter_helpers @ [""])
    @ (if vec_fold_helpers = [] then [] else vec_fold_helpers @ [""])
    @ (if vec_map_helpers = [] then [] else vec_map_helpers @ [""])
    @ (if vec_filter_helpers = [] then [] else vec_filter_helpers @ [""])
    @ (if vec_to_owned_helpers = [] then [] else vec_to_owned_helpers @ [""])
    @ (if owned_vec_to_vec_helpers = [] then [] else owned_vec_to_vec_helpers @ [""])
    @ (let extern_declares =
         Hashtbl.fold (fun name ty acc ->
           let rec flatten t =
             match Ast.walk t with
             | Ast.TyArrow (p, r) ->
               let args, ret = flatten r in
               Ast.walk p :: args, ret
             | _ -> [], Ast.walk t
           in
           let args, ret = flatten ty in
           let ll_ret = match ret with
             | Ast.TyUnit -> "void"
             | t -> llvm_ty_of t
           in
           let real_args = List.filter (fun t -> t <> Ast.TyUnit) args in
           let ll_args = String.concat ", " (List.map llvm_ty_of real_args) in
           Printf.sprintf "declare %s @%s(%s)" ll_ret name ll_args :: acc)
           extern_fn_decls_llvm []
       in
       if extern_declares = [] then []
       else "; Phase 32.3 (C1 FFI): extern fn declarations"
            :: extern_declares @ [""])
    @ (if top_globals_list = [] then []
       else "; Phase 30.2b: top-level non-fn let values as LLVM globals"
            :: emit_top_globals_llvm top_globals_list @ [""])
    @ (if fn_defs = [] then [] else fn_defs @ [""])
    @ (if lifted_defs = [] then [] else lifted_defs @ [""])
    @ (if closure_adapters = [] then [] else closure_adapters @ [""])
    @ (if show_fn_defs = [] then [] else show_fn_defs @ [""])
    @ (if anon_adapters = [] then [] else anon_adapters @ [""])
    @ (if !inner_lift_closure_pending_llvm = [] then []
       else
         (* Phase 39.A2: emit adapter body for each inner-lifted fn used as
            value. Unpacks env into captures, calls lifted fn with
            captures-followed-by-arg. *)
         List.rev_map (fun (lifted_name, captures, arg_ty, ret_ty) ->
           let arg_lty = llvm_ty_of arg_ty in
           let ret_lty = llvm_ty_of ret_ty in
           let env_ty = "%" ^ lifted_name ^ "_env" in
           let unpack_instrs =
             List.mapi (fun i (_, cty) ->
               let cty_l = llvm_ty_of cty in
               Printf.sprintf
                 "  %%cap%d_p = getelementptr %s, ptr %%env_p, i32 0, i32 %d\n  %%cap%d = load %s, ptr %%cap%d_p"
                 i env_ty i i cty_l i)
               captures
             |> String.concat "\n"
           in
           let call_args =
             let cap_args =
               List.mapi (fun i (_, cty) ->
                 Printf.sprintf "%s %%cap%d" (llvm_ty_of cty) i) captures
             in
             String.concat ", " (cap_args @ [arg_lty ^ " %x"])
           in
           Printf.sprintf
             "define %s @%s_inner_closure_fn(ptr %%env_p, %s %%x) {\nentry:\n%s\n  %%result = call %s @%s(%s)\n  ret %s %%result\n}"
             ret_lty lifted_name arg_lty
             unpack_instrs
             ret_lty lifted_name call_args
             ret_lty)
         !inner_lift_closure_pending_llvm
         @ [""])
    @ (let eta_lines =
         Hashtbl.fold (fun adapter (builtin, ret_ty) acc ->
           let ret_ll = llvm_ty_of ret_ty in
           let cstruct = closure_struct_name Ast.TyUnit ret_ty in
           let body_code =
             match builtin with
             | "vec_new" ->
               let elem_tag = match Ast.walk ret_ty with
                 | Ast.TyCon ("Vec", [_; et]) -> ty_tag (Ast.walk et)
                 | _ -> "?"
               in
               Printf.sprintf
                 "  %%r = call ptr @mere_vec_%s_new(ptr @__lang_default_region)"
                 elem_tag
             | "owned_vec_new" ->
               let elem_tag = match Ast.walk ret_ty with
                 | Ast.TyCon ("OwnedVec", [et]) -> ty_tag (Ast.walk et)
                 | _ -> "?"
               in
               Printf.sprintf "  %%r = call ptr @mere_owned_vec_%s_new()" elem_tag
             | "strbuf_new" ->
               "  %r = call ptr @mere_strbuf_new(ptr @__lang_default_region)"
             | "map_new" ->
               let kvtag = match Ast.walk ret_ty with
                 | Ast.TyCon ("Map", [_; k_ty; v_ty]) ->
                   ty_tag (Ast.walk k_ty) ^ "_" ^ ty_tag (Ast.walk v_ty)
                 | _ -> "?"
               in
               Printf.sprintf
                 "  %%r = call ptr @mere_map_%s_new(ptr @__lang_default_region)"
                 kvtag
             | _ -> "  %r = i32 0"
           in
           let fn_def = Printf.sprintf
             "define %s @%s_closure_fn(ptr %%env_unused, i32 %%u_unused) {\nentry:\n%s\n  ret %s %%r\n}"
             ret_ll adapter body_code ret_ll
           in
           let const_def = Printf.sprintf
             "@%s_as_value = internal constant %%%s { ptr null, ptr @%s_closure_fn }"
             adapter cstruct adapter
           in
           fn_def :: const_def :: acc)
           eta_adapters_llvm []
       in
       if eta_lines = [] then []
       else "; Phase 35.2: nullary factory builtins as first-class values"
            :: eta_lines @ [""])
    @ [ "define i32 @main() {";
        body;
        "}";
        "" ]
  in
  String.concat "\n" parts
