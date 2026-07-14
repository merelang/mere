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

(* Phase 30.2 (DEFERRED §1.10 fix): declare top-level non-fn let value names as
   file-scope C globals, initialized at the start of main. emit_expr Var "name"
   falls through to the usual c_safe_name path and references the file-scope
   global. *)
let top_globals : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Phase 32.2 (C1 FFI): extern fn declarations. The App handler in emit_expr
   dispatches App (Var name, arg) directly to a C function call. *)
let extern_fn_decls : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Phase 35.1 (DEFERRED §1.2 fix): registry of eta adapters generated when a
   builtin is used in first-class value position (`let f = vec_new in f ()`).
   key = adapter name (e.g. "vec_new_int"), value = (builtin_name, ret_ty).
   emit_program emits a static adapter function + const value for each entry. *)
let eta_adapters : (string, string * Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Phase 38.C (DEFERRED §1.2 A2): when a multi-arg curried builtin is used in
   value position, synthesize and return a syntactically fully eta-expanded Fun
   chain. For example, `owned_vec_push : OwnedVec[int] -> int -> unit` used in
   value position generates `fn __arg0 -> fn __arg1 -> owned_vec_push __arg0 __arg1`.
   The generated AST becomes a closure value via the anonymous Fun adapter
   machinery (Phase 5.7-b), and the inner nested App hits the direct-call fast
   path -- a single synthesizer supports all multi-arg curried builtins without
   any per-builtin closure boilerplate. *)
let synthesize_curried_eta (name : string) (arrow_ty : Ast.ty) (loc : Loc.t)
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
  (* Build inner App: ((... ((Var name) arg0) arg1) ...) argN-1 *)
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
  (* Wrap from inner-most outward with Fun nodes *)
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

(* Phase 23.3: poly fns that need per-instantiation specialization.
   Key = fn name (e.g., "rev_aux"). Value = list of distinct concrete
   arrow types observed at use sites. Each entry causes resolve_fn_types
   to emit N specialized fn_decls (one per arrow) with mangled names,
   and emit_expr's call-site dispatch to pick the right mangled name. *)
let multi_inst_fns : (string, Ast.ty list) Hashtbl.t = Hashtbl.create 4

(* Phase 22.6: C reserved keywords that can collide with user-defined
   identifier names (`let case = ...` in json_parser). Mangle by
   appending `_` so the emitted C is valid while leaving Mere names
   intact in error messages and AST. *)
let c_reserved_keywords =
  ["auto"; "break"; "case"; "char"; "const"; "continue"; "default";
   "do"; "double"; "else"; "enum"; "extern"; "float"; "for"; "goto";
   "if"; "inline"; "int"; "long"; "register"; "restrict"; "return";
   "short"; "signed"; "sizeof"; "static"; "struct"; "switch"; "typedef";
   "union"; "unsigned"; "void"; "volatile"; "while";
   (* C99/C11/C23 + stdlib pitfalls *)
   "_Bool"; "_Complex"; "_Imaginary"; "_Atomic"; "_Static_assert";
   "_Thread_local"; "_Alignas"; "_Alignof"; "_Generic"; "_Noreturn";
   "main";
   (* libm <math.h> / POSIX names a user fn can collide with (the C backend
      includes math.h). E.g. a `let rec fmin` clashes with libm's fmin.
      Mere's own math builtins (sqrt/sin/cos/tan/pow) are emitted as libm
      calls and are handled separately, so they're not listed here. *)
   "fmin"; "fmax"; "fabs"; "floor"; "ceil"; "round"; "trunc"; "fmod";
   "hypot"; "exp"; "log"; "log2"; "log10"; "cbrt"; "remainder"; "drem";
   "gamma"; "y0"; "y1"; "j0"; "j1"; "index"; "remove"]
let c_safe_name (n : string) : string =
  (* Phase 41: convert module-qualified name (`M.foo`) to a C identifier.
     Since `.` is not allowed in C identifiers, replace it with `__`
     (`M.foo` -> `M__foo`). Nested modules (`A.B.foo`) flatten similarly
     to `A__B__foo`. *)
  let n =
    if String.contains n '.' then begin
      let b = Buffer.create (String.length n) in
      String.iter (fun c ->
        if c = '.' then Buffer.add_string b "__"
        else Buffer.add_char b c) n;
      Buffer.contents b
    end else n
  in
  if List.mem n c_reserved_keywords then n ^ "_" else n

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

(* Same, for `to_json` (the derive-y JSON sibling of show). Keyed by ty_tag. *)
let to_json_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Same, for `of_json` — the deserialization mirror. Keyed by the target
   (result) type's ty_tag. When non-empty, the JSON-parser runtime is emitted. *)
let of_json_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* For `of_json_opt : str -> 'a option` — keyed by the INNER type's ty_tag,
   stores the inner type. Emits a setjmp wrapper that returns None on error. *)
let of_json_opt_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Compound types (tuple / record / variant) compared with == / != — they
   need a structural `eq_<tag>` since C can't `==` a struct. Keyed by ty_tag. *)
let eq_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Does an Eq/Ne on this type need a structural eq_<tag> (vs a C scalar ==)? *)
let needs_struct_eq (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyTuple _ -> true
  | Ast.TyCon (name, _) ->
    Hashtbl.mem Typer.records name
    || Hashtbl.mem Typer.types name
    || Hashtbl.mem polymorphic_variants name
    || name = "list"
  | _ -> false

(* v0.1.11 derive-ord: compound types ordered with < <= > >= need a
   structural `cmp_<tag>` (returns <0/0/>0), the ordering sibling of
   eq_<tag>. Same compound set as needs_struct_eq. Keyed by ty_tag. *)
let cmp_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8
let needs_struct_cmp = needs_struct_eq

(* Polymorphic record declarations: deferred to instantiation time. *)
let polymorphic_records
    : (string, string list * (string * Ast.ty) list) Hashtbl.t =
  Hashtbl.create 4

(* Concrete instantiations of polymorphic records seen in the program.
   Key is the mono name; value is (record_name, arg_types). *)
let mono_record_instances : (string, string * Ast.ty list) Hashtbl.t =
  Hashtbl.create 8

(* Phase 15.2: concrete element types of `Vec[R, T]` seen in the program.
   Key is `ty_tag` of the element type (`int`, `str`, `tuple_int_int`,
   ...) and value is the walked element type. For each entry the
   codegen emits `mere_vec_<tag>` struct + 4 helpers. *)
let vec_instances : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.7: concrete element types of `OwnedVec[T]` seen in the program.
   Same key strategy as `vec_instances`. OwnedVec is heap-allocated
   (malloc / realloc), not region-bound, and drop-typed so it can't be
   placed inside a region. *)
let owned_vec_instances : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Q-012: concrete element types of `Channel[T]` seen in the program. Key is
   the element ty_tag; value is the walked element type. Each entry emits a
   `mere_channel_<tag>` struct + new/send/recv (a heap-allocated blocking
   FIFO guarded by a pthread mutex + condition variable). Heap-allocated (not
   region-bound) since a channel is shared across threads and outlives any
   region block. *)
let channel_instances : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.9: StrBuf[R] usage flag — StrBuf is a single (non-polymorphic)
   region-bound mutable string buffer, so no per-T monomorphization.
   The runtime is emitted iff this flag is set. *)
let strbuf_used = ref false

(* Phase 16.3: Logger / Metrics builtin usage flags. Triggered by
   `Ast.Var "mk_logger" / "mk_metrics"` in App-head position. The
   runtime helpers (printf-based logger + simple metrics) are emitted
   after closure_typedefs and Logger / Metrics struct bodies. *)
let logger_used = ref false
let metrics_used = ref false

(* Phase 24.3: str_split / str_join C codegen usage flags. Emit the
   runtime helpers (which reference list_str_node) AFTER the mono variant
   bodies. *)
let str_split_used = ref false
let str_join_used = ref false
let list_dir_used = ref false   (* Phase 44 *)
let args_used = ref false       (* native CLI: argv → str list *)

(* Phase 15.10: Map[R, K, V] per-(K, V) monomorphize. Key supports only
   int / str; value can be any concrete type in codegen. Linear scan.
   Builds `mere_map_<K_tag>_<V_tag>` using ty_tag for both key and value. *)
let map_instances : (string, Ast.ty * Ast.ty) Hashtbl.t = Hashtbl.create 4

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
  | Ast.TyRef (m, r, inner) ->
    Ast.TyRef (m, r, subst_params mapping inner)
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
(* Phase 22.5: inner_lifts is the ACTIVE scope (per-host fn) — set
   before emitting each host fn's body. inner_lifts_by_host stores the
   per-host scope tables; lift_inner_fns populates these during
   walk_in_fn, and emit_program / emit_fn swaps `inner_lifts` to the
   right host before emitting that host's body.
   This fixes the collision when two top-level fns both have a
   `let rec inner = ...` with the same local name (e.g., `loop` in
   parse_add and parse_term). *)
let inner_lifts : (string, lifted_inner) Hashtbl.t = Hashtbl.create 8
let inner_lifts_by_host : (string, (string, lifted_inner) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 8
let current_host_fn : string ref = ref ""

(* Phase 39.A2 (DEFERRED patterns.md §8): to allow an inner-lifted fn to be
   used in value position, emit a per-fn env struct + adapter function once.
   Since emit_expr is defined before c_type_of, each use site pushes
   (lifted_name, captures, arg_ty, ret_ty) onto a pending list, and emit_program
   generates the typedef + adapter body. *)
let inner_lift_closures_emitted : (string, unit) Hashtbl.t = Hashtbl.create 4
let inner_lift_closure_pending :
  (string * (string * Ast.ty) list * Ast.ty * Ast.ty) list ref = ref []
let set_inner_lifts_for_host (host : string) : unit =
  Hashtbl.reset inner_lifts;
  (match Hashtbl.find_opt inner_lifts_by_host host with
   | Some tbl -> Hashtbl.iter (fun k v -> Hashtbl.add inner_lifts k v) tbl
   | None -> ());
  current_host_fn := host

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
  ce_host         : string;
    (* Phase 22.5: which top-level fn was being emitted when this
       closure was queued — used by emit_closure_adapter to restore
       inner_lifts scope at drain time. *)
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
  | Ast.TyRef (_, _, inner) -> ty_is_concrete inner
  | Ast.TyFloat -> true   (* Phase 43.1 fix: TyFloat is fully concrete; the previous
                              `false` was a typo that prevented a fn taking a `float` arg
                              from being emitted via the fn_decl path, so only the call
                              site was emitted and compilation failed *)
  | Ast.TyVar _ | Ast.TyParam _ -> false

let rec ty_tag (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt -> "int"
  | Ast.TyBool -> "bool"
  | Ast.TyStr -> "str"
  | Ast.TyUnit -> "unit"
  | Ast.TyFloat -> "float"   (* Phase 43.1: allow float to be used in fn signature tags *)
  | Ast.TyTuple ts -> "tuple_" ^ String.concat "_" (List.map ty_tag ts)
  | Ast.TyArrow (p, r) ->
    (* Recursive arrow → use the same naming used by closure_struct_name. *)
    "closure_" ^ ty_tag p ^ "_" ^ ty_tag r
  | Ast.TyCon (name, []) -> name
  | Ast.TyCon (name, args) ->
    (* Polymorphic instantiation (e.g., `int list` → `list_int`).
       Phase 15.1: for Vec[R, T]'s region marker (TyRef _ R TyUnit),
       use only the region name as the tag. *)
    name ^ "_" ^ String.concat "_" (List.map ty_tag args)
  | Ast.TyRef (_, r, Ast.TyUnit) ->
    (* Region marker — use the region name itself as the tag. *)
    r
  | Ast.TyRef (_, _, inner) ->
    (* Phase 19.x: for borrow type `&[mode] R T`, the tag uses the inner T's
       tag as-is. mode / region are purely static info. The typer's auto-deref
       makes field access transparent, so not distinguishing from T at the tag
       level is convenient — downstream lookups (closure_struct_name, etc.)
       then match cleanly. *)
    ty_tag inner
  | other ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unsupported C codegen type element: %s" (Ast.pp_ty other)))

let tuple_struct_name (elems : Ast.ty list) : string =
  "tuple_" ^ String.concat "_" (List.map ty_tag elems)

(* Phase 23.3: mangle a fn name with its concrete arrow type tag, e.g.
   `rev_aux` with `list_json -> list_json -> list_json` becomes
   `rev_aux__list_json__list_json__list_json`. Used for per-instantiation
   specialization. Must be defined before emit_expr (which dispatches via
   this) and before resolve_fn_types (which creates fn_decls with these
   names). *)
let mangled_inst_name (base : string) (arrow : Ast.ty) : string =
  let rec collect_tys t acc =
    match Ast.walk t with
    | Ast.TyArrow (a, b) -> collect_tys b (a :: acc)
    | _ -> List.rev (t :: acc)
  in
  let tys = collect_tys arrow [] in
  (* Phase 41: if base is module-qualified (`Json.rev_aux`), convert it to a
     C identifier first, then append the mono suffix
     (`Json__rev_aux__list_json__...`). *)
  c_safe_name base ^ "__" ^ String.concat "__" (List.map ty_tag tys)

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
let payload_ty_for_ctor (v_ty : Ast.ty) (raw_cname : string) : Ast.ty option =
  (* Phase 41: canonicalize qualified `M.Foo` → `Foo`. *)
  let cname = Ast.canonical_ctor raw_cname in
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
    | Ast.Ref (_, _, a) -> go a
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

(* Phase 28.1 (DEFERRED §1.9 fix): pattern bindings with inferred types.
   Used by Match emission to update current_var_types for the arm body
   so nested closure capture sees pattern-bound names (e.g., the `rest`
   in `Cons (head, rest) -> ... (fn pair -> ... parse_pairs rest ...)`). *)
let pattern_vars_with_types (p : Ast.pattern) (scrut_ty : Ast.ty)
  : (string * Ast.ty) list =
  let rec go p t =
    match p.Ast.pnode with
    | Ast.P_var n -> [(n, Ast.walk t)]
    | Ast.P_wild | Ast.P_int _ | Ast.P_bool _ | Ast.P_str _ | Ast.P_unit -> []
    | Ast.P_as (inner, n) -> (n, Ast.walk t) :: go inner t
    | Ast.P_or (a, _) -> go a t
    | Ast.P_tuple ps ->
      let elem_tys =
        match Ast.walk t with
        | Ast.TyTuple ts -> ts
        | _ -> List.map (fun _ -> Ast.TyInt) ps
      in
      List.concat (List.mapi (fun i sub ->
        let et = try List.nth elem_tys i with _ -> Ast.TyInt in
        go sub et) ps)
    | Ast.P_constr (cname, None) ->
      ignore cname; []
    | Ast.P_constr (cname, Some sub) ->
      (match payload_ty_for_ctor t cname with
       | Some pt -> go sub pt
       | None -> [])
    | Ast.P_record (_, fs) ->
      (* Record field type lookup does not go through payload_ty_for_ctor, so
         skip it. The minimum closure-capture fix doesn't need a precise
         per-field type (the field value itself suffices), so conservatively
         reuse scrut_ty. *)
      List.concat_map (fun (_, sub) -> go sub t) fs
  in
  go p scrut_ty

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
    | Ast.Ref (_, _, a) -> go a bound
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e bound) fs
    | Ast.Field_get (a, _) -> go a bound
    | Ast.Record_update (a, fs) ->
      go a bound; List.iter (fun (_, e) -> go e bound) fs
  in
  go e initially_bound;
  List.rev !order

(* Phase 38.G-1 (DEFERRED §1.3 Level 1): static auto-Drop check for OwnedVec.

   Given `let v = owned_vec_new () in body`, returns true iff v is statically
   provably *safe to free at the end of body* — i.e., v's value does not
   escape the lexical scope of the let binding. Conservative: false-positives
   (saying "unsafe" when actually safe) are OK and just fall back to the
   process-wide registry sweep; false-negatives (saying "safe" when actually
   escapes) would cause use-after-free, so the check must be sound.

   Escape sources we detect:
   1. Var v appears in a value-leaking construction (Tuple, Constr payload,
      Record_lit, Record_update) — the value could be stashed.
   2. Var v appears inside a Fun body that isn't immediately consumed
      (closure capture, value-position).
   3. Body's tail expression returns v or a value containing v (typed via
      `ty_contains_owned_vec`).

   Safe uses (allowed):
   - `App (..., Var v)` where the App's result type doesn't contain OwnedVec
     (e.g., `owned_vec_push v x` returns unit, `owned_vec_get v 0` returns T)
   - Annot / Neg / Field_get / arithmetic / comparison / `let _ = ... in ...`
   - if/match arms where each arm body doesn't return v *)
let rec ty_contains_owned_vec (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyCon ("OwnedVec", _) -> true
  | Ast.TyCon (_, args) -> List.exists ty_contains_owned_vec args
  | Ast.TyTuple ts -> List.exists ty_contains_owned_vec ts
  | Ast.TyArrow (a, b) -> ty_contains_owned_vec a || ty_contains_owned_vec b
  | Ast.TyRef (_, _, t') -> ty_contains_owned_vec t'
  | _ -> false

let rec var_appears_in (v : string) (e : Ast.expr) : bool =
  let g = var_appears_in v in
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

(* Check 1: no value-leaking construction has v inside it. *)
let rec no_value_leak (v : string) (e : Ast.expr) : bool =
  let g = no_value_leak v in
  match e.Ast.node with
  | Ast.Var _ | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _
  | Ast.Str_lit _ | Ast.Unit_lit -> true
  | Ast.Tuple es ->
    List.for_all (fun e' -> not (var_appears_in v e') && g e') es
  | Ast.Constr (_, Some a) -> not (var_appears_in v a) && g a
  | Ast.Constr (_, None) -> true
  | Ast.Record_lit (_, fs) ->
    List.for_all (fun (_, e') -> not (var_appears_in v e') && g e') fs
  | Ast.Record_update (a, fs) ->
    not (var_appears_in v a)
    && List.for_all (fun (_, e') -> not (var_appears_in v e') && g e') fs
  | Ast.Fun (param, _, fbody) ->
    param = v || not (var_appears_in v fbody)
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

(* Check 2: tail expression of body doesn't return v (or a value containing v). *)
let rec tail_does_not_return_v (v : string) (e : Ast.expr) : bool =
  match e.Ast.node with
  | Ast.Var n -> n <> v
  | Ast.Let (pat, _, body) ->
    List.mem v (pattern_vars pat) || tail_does_not_return_v v body
  | Ast.Let_rec (bs, body) ->
    List.exists (fun (n, _) -> n = v) bs || tail_does_not_return_v v body
  | Ast.If (_, t, e_) ->
    tail_does_not_return_v v t && tail_does_not_return_v v e_
  | Ast.Match (_, arms) ->
    List.for_all (fun (pat, _, b) ->
       List.mem v (pattern_vars pat) || tail_does_not_return_v v b) arms
  | Ast.With (n, _, body) -> n = v || tail_does_not_return_v v body
  | Ast.Region_block (_, body) -> tail_does_not_return_v v body
  | Ast.Annot (a, _) -> tail_does_not_return_v v a
  | _ ->
    (* Other tail expressions: type determines safety. If tail type contains
       OwnedVec, conservatively say unsafe (might be returning v). *)
    let tail_ty = match e.Ast.ty with
      | Some t -> Ast.walk t
      | None -> Ast.TyUnit
    in
    not (ty_contains_owned_vec tail_ty)

(* Taint propagation: a `let x = expr in body` where expr involves any
   already-tainted name (initially just v) AND x's type is **non-trivial**
   (i.e., can hold a ref to v's memory: closure, container, variant, record)
   propagates taint to x. Scalars derived from v (`let n = owned_vec_len v in
   ...`) are NOT tainted — owned_vec_len returns a plain int that doesn't
   hold any reference to v's data.

   This catches the soundness hole where `let get = owned_vec_get v in get`
   would otherwise pass tail_does_not_return_v (tail type `int -> int`
   doesn't contain OwnedVec) but actually returns a closure capturing v. *)
let rec is_trivial_ty (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyFloat -> true
  | Ast.TyTuple ts -> List.for_all is_trivial_ty ts
  | _ -> false

let collect_tainted_names (v : string) (body : Ast.expr) : string list =
  let tainted = ref [v] in
  let any_tainted_in e =
    List.exists (fun n -> var_appears_in n e) !tainted
  in
  let value_propagates_taint value =
    let vty = match value.Ast.ty with
      | Some t -> Ast.walk t
      | None -> Ast.TyUnit
    in
    (* Non-trivial type means the value can hold a ref (closure / container
       / variant / record / etc). If the value also contains a tainted name,
       the new binding is tainted too. *)
    (not (is_trivial_ty vty)) && any_tainted_in value
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

(* Tail check that considers a SET of tainted names (not just v). The let
   bindings inside body that introduce tainted names are NOT treated as
   shadowing for the purposes of this check — they ARE the tainted vars. *)
let rec tail_does_not_return_any (tainted : string list) (e : Ast.expr) : bool =
  match e.Ast.node with
  | Ast.Var n -> not (List.mem n tainted)
  | Ast.Let (_, _, body) -> tail_does_not_return_any tainted body
  | Ast.Let_rec (_, body) -> tail_does_not_return_any tainted body
  | Ast.If (_, t, e_) ->
    tail_does_not_return_any tainted t
    && tail_does_not_return_any tainted e_
  | Ast.Match (_, arms) ->
    List.for_all (fun (_, _, b) -> tail_does_not_return_any tainted b) arms
  | Ast.With (_, _, body) -> tail_does_not_return_any tainted body
  | Ast.Region_block (_, body) -> tail_does_not_return_any tainted body
  | Ast.Annot (a, _) -> tail_does_not_return_any tainted a
  | _ ->
    (* Tuple / Constr / Record etc. — type-based check *)
    let tail_ty = match e.Ast.ty with
      | Some t -> Ast.walk t
      | None -> Ast.TyUnit
    in
    not (ty_contains_owned_vec tail_ty)

(* Value-leak check considering a SET of tainted names. *)
let rec no_tainted_leak (tainted : string list) (e : Ast.expr) : bool =
  let g = no_tainted_leak tainted in
  let appears e' = List.exists (fun n -> var_appears_in n e') tainted in
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
    (* Fun in expression position is OK — the resulting closure is bound by
       the surrounding let (which propagates taint via collect_tainted_names)
       or consumed in-place (e.g. passed to list_iter). Inline Fun nested
       inside Tuple/Constr/Record is caught by the `appears` check at the
       outer container (var_appears_in walks Fun bodies). *)
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

(* Combined check, hardened with taint propagation. *)
let owned_vec_safe_to_drop_at_scope (body : Ast.expr) (v : string) : bool =
  let tainted = collect_tainted_names v body in
  no_tainted_leak tainted body && tail_does_not_return_any tainted body

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
         (* Phase 15.10/15.14: K must be a type with codegen-defined equality.
            int / bool / str / tuple (of supported types) are supported. *)
         let rec is_key_supported = function
           | Ast.TyInt | Ast.TyBool | Ast.TyStr -> true
           | Ast.TyTuple ts -> List.for_all is_key_supported ts
           | Ast.TyCon (rname, _) when Hashtbl.mem Typer.records rname ->
             let info = Hashtbl.find Typer.records rname in
             List.for_all (fun (_, ft) -> is_key_supported (Ast.walk ft))
               info.Typer.r_fields
           | Ast.TyCon (vname, _) when Hashtbl.mem Exhaustive.type_variants vname ->
             (* Phase 15.15: nullary variants ✓.
                Phase 15.16: also payload variants (per-ctor recursive
                check on each ctor's payload type). *)
             let ctors = Hashtbl.find Exhaustive.type_variants vname in
             List.for_all (fun (_, payload) ->
               match payload with
               | None -> true
               | Some pt -> is_key_supported (Ast.walk pt)) ctors
           | _ -> false
         in
         if not (is_key_supported k_ty) then
           raise (Codegen_error (loc,
             "Map key type must be int / bool / str / tuple / record / variant in C codegen (Phase 15.10-15.16)"));
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

(* Pull the element type out of an `OwnedVec[T]` typed expression and
   return its `ty_tag`. Registers in `owned_vec_instances`. *)
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
     | _ -> raise (Codegen_error (loc,
         "vec_* expected a Vec value"))
   )
  | None -> raise (Codegen_error (loc, "vec_*: missing type info"))

(* Q-012: given the type of a channel expression (`Channel[T]`), return the
   element ty_tag and register the instance so its runtime is emitted. *)
let channel_elem_tag (t : Ast.ty option) : string =
  match Option.map Ast.walk t with
  | Some (Ast.TyCon ("Channel", [el])) ->
    let el = Ast.walk el in
    let tag = ty_tag el in
    if not (Hashtbl.mem channel_instances tag) then
      Hashtbl.add channel_instances tag el;
    tag
  | _ ->
    raise (Codegen_error (Loc.dummy,
      "channel operation: element type is not a resolved Channel[T]"))

(* Translate one Lang expression to a C expression string. *)
let rec emit_expr (e : Ast.expr) : string =
  match e.node with
  | Ast.Int_lit n -> string_of_int n
  | Ast.Float_lit f ->
    (* Phase 34.1: emit as C double literal. `%.17g` is safe for round-trip.
       NaN / Infinity use the standard C NAN / INFINITY macros. *)
    if f <> f then "(0.0/0.0)"  (* NaN *)
    else if f = infinity then "(1.0/0.0)"
    else if f = neg_infinity then "(-1.0/0.0)"
    else
      (* %.17g drops the decimal point for whole values (`7.0` -> "7"), which
         C would then treat as an int in arithmetic (`7 / 2` = 3, not 3.5).
         Ensure the literal always reads as a double. *)
      let s = Printf.sprintf "%.17g" f in
      if String.contains s '.' || String.contains s 'e' || String.contains s 'E'
      then s else s ^ ".0"
  | Ast.Bool_lit b -> if b then "1" else "0"
  | Ast.Str_lit s -> Ast.escape_string s
  | Ast.Var name ->
    (* Phase 24.1: shadowing check — if the name is bound as a local
       (in current_var_types) or by a captured env field
       (current_env_subst), treat it as a regular var, NOT the builtin.
       Otherwise template_engine's `let len = str_len template in` would
       trip the "len as a value" guard below. *)
    let is_shadowed =
      List.mem_assoc name !current_var_types
      || List.mem_assoc name !current_env_subst
    in
    (* Vec builtins are interpreter-only (Phase 12.1). Reject early in
       codegen with a clear message rather than emitting code that
       fails at C compile time with undeclared-identifier errors. *)
    (* Phase 15.1: vec_new / vec_push / vec_get / vec_len are emitted
       directly via App handler special cases. First-class value usage
       (let f = vec_new in ...) is not yet supported and is rejected here. *)
    (* Phase 35.1: nullary factory builtins as first-class value.
       eta-expand to a closure adapter (registered in eta_adapters Hashtbl,
       emitted at file scope in emit_program). *)
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
             (* Register Vec / OwnedVec / Map / StrBuf instance so its runtime
                gets emitted. c_type_of is defined later in this file, so do
                the registration inline. *)
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
             if not (Hashtbl.mem eta_adapters adapter) then
               Hashtbl.add eta_adapters adapter (name, ret_ty);
             Some (adapter ^ "_as_value")
           | _ -> None)
        | None -> None
      else None
    in
    (match eta_value_str_opt with
     | Some v -> v
     | None ->
    if not is_shadowed && is_nullary_factory then
      unsupported e.loc
        (name ^ " as a value: return type is polymorphic, can't monomorphize \
                 (Phase 35.1 MVP: nullary factory as value only works when use \
                 site infers a concrete element type. Use direct application \
                 like `vec_new ()` or write `fn () -> vec_new ()` manually)");
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
    (* Phase 38.C (DEFERRED §1.2 A2): try eta-expansion before rejecting.
       If e.ty is a concrete arrow chain, synthesize the curried Fun chain
       and recurse — the resulting AST goes through the existing anonymous
       Fun adapter + direct-call fast paths. After confirming the
       owned_vec_push spike in 38.C-1, 38.C-2 extends this to the
       group of 2-arg curried collection accessors. *)
    let is_phase38c_target =
      (* 2-arg curried (38.C-1 / 38.C-2) *)
      name = "owned_vec_push" || name = "owned_vec_get"
      || name = "vec_push" || name = "vec_get"
      || name = "strbuf_push"
      || name = "map_get" || name = "map_has"
      (* 3-arg curried (38.C-3) *)
      || name = "map_set" || name = "vec_set"
    in
    let try_eta () =
      match e.Ast.ty with
      | Some t when ty_is_concrete (Ast.walk t) ->
        (match Ast.walk t with
         | Ast.TyArrow _ as arrow ->
           Some (emit_expr (synthesize_curried_eta name arrow e.loc))
         | _ -> None)
      | _ -> None
    in
    (* Phase 38.A1: also make single-arg builtins (int_of_str / str_len / not /
       ord etc.) eta-synthesis targets so they can be used in value position.
       The same synthesize_curried_eta works for arity 1, so the inner App
       rides each builtin's direct-call fast path (e.g. line 1614). *)
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
      || name = "print" || name = "print_err" || name = "print_no_nl" || name = "fail"
      || name = "fst" || name = "snd"
    in
    if not is_shadowed && is_curried_collection_builtin && is_phase38c_target then
      (match try_eta () with
       | Some s -> s
       | None ->
         unsupported e.loc
           (name ^ " as a value: type is polymorphic, can't monomorphize (Phase 38.C-1 MVP: use a fn wrapper or constrain types at use site)"))
    else if not is_shadowed && is_curried_collection_builtin then
      unsupported e.loc
        (name ^ " as a value (Phase 15.1-15.10: curried multi-arg builtins vec_* / owned_vec_* / strbuf_* / map_* support direct application only; first-class value use is in progress under Phase 38.C, currently only owned_vec_push is spike-implemented)")
    else if not is_shadowed && is_single_arg_value_builtin then
      (match try_eta () with
       | Some s -> s
       | None ->
         unsupported e.loc
           (name ^ " as a value: type is polymorphic, can't monomorphize (Phase 38.A1 MVP: use a fn wrapper `fn x -> " ^ name ^ " x` or constrain types at use site)"))
    else if not is_shadowed && (name = "len" || name = "vec_to_list") then
      unsupported e.loc
        (name ^ " as a value (Phase 15.11/15.12: len / vec_to_list support direct application only)")
    (* Phase 34.1: float constants — exactly matches the interp-side builtins *)
    else if not is_shadowed && name = "pi" then
      "(3.14159265358979323846)"
    else if not is_shadowed && name = "e" then
      "(2.7182818284590452354)"
    else
    (* If we're inside a closure adapter and this name is one of the
       captured vars, rewrite to env access. *)
    (match List.assoc_opt name !current_env_subst with
     | Some s -> s
     | None ->
       (* A local binding / parameter shadows a same-named top-level fn:
          emit the local (the C parameter / local), NOT the global's
          `<name>_as_value`. Without this, e.g. the prelude `list_fold`'s
          parameter `f` resolved to a user top-level `let f`. *)
       if List.mem_assoc name !current_var_types then c_safe_name name
       else if Hashtbl.mem toplevel_fn_names name then c_safe_name name ^ "_as_value"
       else if Hashtbl.mem inner_lifts name then
         (* Phase 39.A2 (DEFERRED patterns.md §8): materialize the inner-lifted
            fn so it can be used in value position. Pack the captures into an
            env struct and return the closure value `{env_ptr, &adapter_fn}`.
            The adapter unpacks env and calls lifted_name(cap1, ..., arg). *)
         let li = Hashtbl.find inner_lifts name in
         (match e.Ast.ty with
          | Some t ->
            (match Ast.walk t with
             | Ast.TyArrow (arg_ty, ret_ty) ->
               let arg_ty = Ast.walk arg_ty in
               let ret_ty = Ast.walk ret_ty in
               let env_struct_name = li.lifted_name ^ "_env" in
               let adapter_name = li.lifted_name ^ "_inner_closure_fn" in
               (* Push once per fn onto the pending list (emit_program then
                  generates the env typedef + adapter body via c_type_of) *)
               if not (Hashtbl.mem inner_lift_closures_emitted li.lifted_name) then begin
                 Hashtbl.add inner_lift_closures_emitted li.lifted_name ();
                 inner_lift_closure_pending :=
                   (li.lifted_name, li.captures, arg_ty, ret_ty)
                   :: !inner_lift_closure_pending
               end;
               (* Use site: env alloc + store the current value of each capture + closure value *)
               let closure_struct = closure_struct_name arg_ty ret_ty in
               let store_caps =
                 String.concat " "
                   (List.map (fun (n, _) ->
                      let v =
                        match List.assoc_opt n !current_env_subst with
                        | Some s -> s
                        | None -> c_safe_name n
                      in
                      Printf.sprintf "__env_local->%s = %s;" (c_safe_name n) v)
                      li.captures)
               in
               (* GCC statement expression: the last expression is the value,
                  semicolons are fine. Even with 0 captures, if store_caps is
                  the empty string we just get an extra ` ` gap — still syntactically OK. *)
               Printf.sprintf
                 "({ %s* __env_local = (%s*)__lang_region_alloc(&__lang_default_region, sizeof(%s)); %s(%s){.env = __env_local, .fn = %s}; })"
                 env_struct_name env_struct_name env_struct_name store_caps closure_struct adapter_name
             | _ ->
               unsupported e.loc
                 ("inner-lifted fn `" ^ name ^
                  "` used as a value — type is not an arrow (Phase 39.A2)"))
          | None ->
            unsupported e.loc
              ("inner-lifted fn `" ^ name ^
               "` used as a value — missing inferred type (Phase 39.A2)"))
       else c_safe_name name))
  | Ast.Annot (inner, _) -> emit_expr inner
  | Ast.Neg a -> "(-" ^ emit_expr a ^ ")"
  | Ast.Bin (Ast.Concat, a, b) ->
    "__lang_str_concat(" ^ emit_expr a ^ ", " ^ emit_expr b ^ ")"
  | Ast.Bin (op, a, b) ->
    "(" ^ emit_expr a ^ " " ^ binop_to_c op ^ " " ^ emit_expr b ^ ")"
  | Ast.Cmp (op, a, b) ->
    (* Phase 22.5: string comparison must use strcmp, not pointer compare. *)
    let a_ty = match a.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyInt in
    (match Ast.walk a_ty, op with
     | Ast.TyStr, Ast.Eq ->
       Printf.sprintf "(strcmp(%s, %s) == 0)" (emit_expr a) (emit_expr b)
     | Ast.TyStr, Ast.Ne ->
       Printf.sprintf "(strcmp(%s, %s) != 0)" (emit_expr a) (emit_expr b)
     | Ast.TyStr, Ast.Lt ->
       Printf.sprintf "(strcmp(%s, %s) < 0)" (emit_expr a) (emit_expr b)
     | Ast.TyStr, Ast.Le ->
       Printf.sprintf "(strcmp(%s, %s) <= 0)" (emit_expr a) (emit_expr b)
     | Ast.TyStr, Ast.Gt ->
       Printf.sprintf "(strcmp(%s, %s) > 0)" (emit_expr a) (emit_expr b)
     | Ast.TyStr, Ast.Ge ->
       Printf.sprintf "(strcmp(%s, %s) >= 0)" (emit_expr a) (emit_expr b)
     | ty, Ast.Eq when needs_struct_eq ty ->
       (* Compound value (tuple / record / variant): C can't `==` a struct,
          so compare structurally via eq_<tag>. *)
       Printf.sprintf "eq_%s(%s, %s)" (ty_tag ty) (emit_expr a) (emit_expr b)
     | ty, Ast.Ne when needs_struct_eq ty ->
       Printf.sprintf "(!eq_%s(%s, %s))" (ty_tag ty) (emit_expr a) (emit_expr b)
     | ty, (Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge) when needs_struct_cmp ty ->
       (* v0.1.11 derive-ord: compound ordering via cmp_<tag> (<0/0/>0). *)
       Printf.sprintf "(cmp_%s(%s, %s) %s 0)"
         (ty_tag ty) (emit_expr a) (emit_expr b) (cmpop_to_c op)
     | _ ->
       "(" ^ emit_expr a ^ " " ^ cmpop_to_c op ^ " " ^ emit_expr b ^ ")")
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
          binding as a capture candidate.

          Phase 16 §1.4 fix: same-name rebinding (`let tasks = f tasks`)
          must not produce `__auto_type tasks = ...tasks...`, which C
          rejects ("variable declared with deduced type cannot appear in
          its own initializer"). Always use a 2-step form via a fresh
          temporary so the initializer references the OUTER `tasks` and
          the new binding shadows it only after the value has been
          computed.

          Phase 30.1 (DEFERRED §1.11 fix): the let binding shadows any
          captured-var rewrite. value_c is emitted BEFORE we mask the
          name (so `let xs = f xs` still resolves the RHS xs to env),
          but body_c is emitted AFTER masking so `Var "xs"` in body
          emits the local rebinding, not `__env_self->xs`. *)
       let value_c = emit_expr value in
       let bind_ty =
         match value.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyInt
       in
       let prev_types = !current_var_types in
       let prev_subst = !current_env_subst in
       current_var_types := (name, bind_ty) :: prev_types;
       current_env_subst := List.filter (fun (n, _) -> n <> name) prev_subst;
       let body_c =
         try let r = emit_expr body in
             current_var_types := prev_types;
             current_env_subst := prev_subst; r
         with ex ->
           current_var_types := prev_types;
           current_env_subst := prev_subst;
           raise ex
       in
       (* Phase 36 (DEFERRED §1.18 fix): if name is a file-scope global,
          assign to it directly. The static declaration is emitted in
          emit_program; here we just emit the assignment so source-order
          side effects in main_body are preserved. *)
       (* Phase 38.G-1 (DEFERRED §1.3 Level 1): auto-Drop check.
          If value is `owned_vec_new ()` (or a chain that returns a fresh
          OwnedVec) AND the body provably doesn't let v escape, emit a
          scope-end free — same shape as `with v = ...` (Phase 15.13).
          Otherwise the existing main-end registry sweep handles cleanup. *)
       let bind_ty_walked = Ast.walk bind_ty in
       let value_is_fresh_owned_vec =
         (match value.Ast.node with
          | Ast.App ({ Ast.node = Ast.Var "owned_vec_new"; _ }, _) -> true
          | _ -> false)
         &&
         (match bind_ty_walked with
          | Ast.TyCon ("OwnedVec", _) -> true
          | _ -> false)
       in
       let do_auto_drop =
         value_is_fresh_owned_vec
         && (not (Hashtbl.mem top_globals name))
         && owned_vec_safe_to_drop_at_scope body name
       in
       (* DEFERRED §8.3 fix (2026-06-26): bindings AND references must
          agree on the mangled C identifier. `Ast.Var name` emission
          (line 1198) already goes through `c_safe_name`, so when the
          user names a local `main` (or any other C reserved word in
          `c_reserved_keywords`) the references read `main_` but the
          old code below was emitting the binders as raw `main` — cc
          would then complain about "undeclared identifier main_". Use
          the safe form on both sides. The internal temp names
          (`__let_tmp_<n>`, `__let_result_<n>`) keep the raw Mere name
          for readability; they're scoped to this expression and don't
          collide with anything. *)
       let safe = c_safe_name name in
       if Hashtbl.mem top_globals name then
         Printf.sprintf
           "({ %s = %s; %s; })" safe value_c body_c
       else if do_auto_drop then
         (* Mirror the Phase 15.13 `with` shape: bind, evaluate body, free
            v's data buffer at scope end, return the body's result.
            free(NULL) is a no-op so main-end free_all stays safe. *)
         Printf.sprintf
           "({ __auto_type __let_tmp_%s = %s; __auto_type %s = __let_tmp_%s; \
            __auto_type __let_result_%s = (%s); \
            free(((__mere_owned_vec_base*)%s)->data); \
            ((__mere_owned_vec_base*)%s)->data = NULL; \
            __let_result_%s; })"
           name value_c safe name name body_c safe safe name
       else
         Printf.sprintf
           "({ __auto_type __let_tmp_%s = %s; __auto_type %s = __let_tmp_%s; %s; })"
           name value_c safe name body_c
     | Ast.P_wild | Ast.P_unit ->
       (* Phase 21.1 (DEFERRED §1.7) fix: `let _ = E in B` / `let () = E in B`
          — evaluate E for side effects then continue with B. Block sequence
          `{ a; b }` parses to `let _ = a in b`, so this also unblocks
          stmt-sequence form in arms / fn bodies. *)
       let value_c = emit_expr value in
       let body_c = emit_expr body in
       Printf.sprintf "({ (void)(%s); %s; })" value_c body_c
     | Ast.P_tuple ps ->
       (* Phase 22.1: `let (a, b, ...) = E in B` — emit a fresh `__let_tup`
          temporary holding the tuple value, then per-field __auto_type
          bindings via `(__let_tup).f0` etc. Each sub-pattern must be
          P_var or P_wild (nested destructuring should use `match` for now). *)
       let value_c = emit_expr value in
       let value_ty =
         match value.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
       in
       let elem_tys = match value_ty with
         | Ast.TyTuple ts -> ts
         | _ ->
           raise (Codegen_error (pat.ploc,
             Printf.sprintf
               "let-tuple pattern requires a tuple-typed RHS, got `%s`"
               (Ast.pp_ty value_ty)))
       in
       if List.length ps <> List.length elem_tys then
         raise (Codegen_error (pat.ploc,
           Printf.sprintf "let-tuple arity mismatch: pattern has %d, value has %d"
             (List.length ps) (List.length elem_tys)));
       let bindings_info = List.mapi (fun i p ->
         let sub_ty = List.nth elem_tys i in
         match p.Ast.pnode with
         | Ast.P_var n -> (Some n, sub_ty, i)
         | Ast.P_wild -> (None, sub_ty, i)
         | _ ->
           raise (Codegen_error (p.Ast.ploc,
             "nested pattern in let-tuple not supported in C codegen subset \
              — use `match` for non-flat destructuring"))
       ) ps in
       (* Phase 30.1 (DEFERRED §1.11 fix): similarly, remove shadowed names
          from env_subst for tuple destructure. In `let (v, toks) = ... toks`
          the new toks shadows the old toks in the closure env. *)
       let shadow_names =
         List.filter_map (fun (n_opt, _, _) -> n_opt) bindings_info
       in
       let prev_types = !current_var_types in
       let prev_subst = !current_env_subst in
       current_var_types :=
         List.filter_map (fun (n_opt, ty, _) ->
           match n_opt with Some n -> Some (n, ty) | None -> None)
           bindings_info @ prev_types;
       current_env_subst :=
         List.filter (fun (n, _) -> not (List.mem n shadow_names)) prev_subst;
       let body_c =
         try let r = emit_expr body in
             current_var_types := prev_types;
             current_env_subst := prev_subst; r
         with ex ->
           current_var_types := prev_types;
           current_env_subst := prev_subst;
           raise ex
       in
       (* Same DEFERRED §8.3 fix as above: tuple destructure also needs
          to bind under c_safe_name so references resolve consistently. *)
       let bind_stmts =
         String.concat " " (List.filter_map (fun (n_opt, _, i) ->
           match n_opt with
           | Some n ->
             Some (Printf.sprintf "__auto_type %s = (__let_tup).f%d;"
                     (c_safe_name n) i)
           | None -> None
         ) bindings_info)
       in
       Printf.sprintf "({ __auto_type __let_tup = %s; %s %s; })"
         value_c bind_stmts body_c
     | _ ->
       (* General irrefutable pattern (constructor / record / as / …):
          desugar `let pat = value in body` to a single-arm
          `match value with | pat -> body`, reusing the full pattern
          compiler. Previously only P_var / P_tuple / P_wild were handled
          (the interp accepted every pattern) — a backend parity gap
          surfaced by the mere-blog dogfood. *)
       emit_expr { e with node = Ast.Match (value, [(pat, None, body)]) })
  (* Unsupported nodes *)
  (* Phase 34.1: Float_lit handled at top of emit_expr now *)
  | Ast.Unit_lit      -> "0"  (* unit becomes int 0 in C *)
  | Ast.Let_rec (bindings, body) ->
    (* Phase 22.2: inner let-rec lifting. If lift_inner_fns has registered
       all of the bindings here in inner_lifts, the lifted definitions
       live at top level (with captures prepended) — just emit body. *)
    if List.for_all (fun (n, _) -> Hashtbl.mem inner_lifts n) bindings then
      emit_expr body
    else
      unsupported e.loc "let rec inside an expression (only allowed at top level)"
  | Ast.With (name, value, body) ->
    (* `with c = v in body` — bind c, evaluate body, then invoke c's
       `close` field if the type defines one (Phase 3.1 convention).
       Phase 15.13: also free OwnedVec at scope end (instead of waiting
       for the process-wide registry's main-end sweep).
       The close field is a `unit -> unit` closure; dispatch via the
       closure struct's `.fn(.env, 0)`. *)
    let value_c = emit_expr value in
    let body_c = emit_expr body in
    let close_call =
      match value.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         (* Phase 15.13: scope-bound Drop for OwnedVec.
            `with v = owned_vec_new () in body` frees v's data buffer at
            scope end (the biggest heap allocation). Struct itself remains
            in the registry and is freed at main-end by free_all — but the
            buffer is gone, so total live memory after `with` ends is much
            smaller. We rely on `free(NULL)` being a no-op (C standard)
            so free_all's `free(v->data)` after this is safe. *)
         | Ast.TyCon ("OwnedVec", _) ->
           Printf.sprintf
             "free(((__mere_owned_vec_base*)%s)->data); \
              ((__mere_owned_vec_base*)%s)->data = NULL; "
             name name
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
    (* v0.1.16 (mk dogfood P5): when the body calls an inner-LIFTED fn, the
       call site injects that fn's captured vars as leading args (see the
       App-on-inner_lifts case). Those vars must ride in THIS closure's env
       too, or the injected args are undeclared inside the adapter — e.g.
       the par_map lowering's spawn lambda calling __pm_f, where __pm_f was
       an inline lambda capturing a host-fn param. inner_lifts captures are
       already transitively closed (Phase 45 fixpoint), so one level is
       enough. *)
    let lifted_callee_caps =
      List.concat_map (fun n ->
        match Hashtbl.find_opt inner_lifts n with
        | Some li -> List.map fst li.captures
        | None -> []) raw_fvs
    in
    let seen = Hashtbl.create 8 in
    let fvs =
      List.filter (fun n ->
        List.mem_assoc n !current_var_types
        && not (Hashtbl.mem seen n)
        && (Hashtbl.add seen n (); true))
        (raw_fvs @ lifted_callee_caps)
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
      ce_host = !current_host_fn;
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
    (* Phase 32.6 (C1 FFI multi-arg): if the head of a curried App chain is an
       extern fn, collect all arguments and convert to a direct C call. 1-arg
       collects [a], N-arg collects [a1; ...; aN] — both go through the same path. *)
    let rec collect_extern e acc =
      match e.Ast.node with
      | Ast.App (f', a) -> collect_extern f' (a :: acc)
      | Ast.Var name when Hashtbl.mem extern_fn_decls name -> Some (name, acc)
      | _ -> None
    in
    (match collect_extern (Ast.{ node = Ast.App (f, arg); ty = e.ty; loc = e.loc }) [] with
     | Some (name, args) ->
       let arg_strs =
         List.filter_map (fun a ->
           match a.Ast.node with
           | Ast.Unit_lit -> None
           | _ -> Some (emit_expr a))
           args
       in
       let call_str = Printf.sprintf "%s(%s)" name (String.concat ", " arg_strs) in
       let rec result_ty t =
         match Ast.walk t with
         | Ast.TyArrow (_, r) -> result_ty r
         | t -> t
       in
       let ret_ty = result_ty (Hashtbl.find extern_fn_decls name) in
       (match ret_ty with
        | Ast.TyUnit -> Printf.sprintf "(%s, 0)" call_str
        | _ -> call_str)
     | None ->
    (match f.node with
     | Ast.Var "print" ->
       "({ puts(" ^ emit_expr arg ^ "); 0; })"
     | Ast.Var "print_err" ->
       (* v0.1.13 (mk dogfood P2): write to stderr with a newline, mirroring
          print → puts. A native CLI needs diagnostics separate from stdout. *)
       "({ fprintf(stderr, \"%s\\n\", " ^ emit_expr arg ^ "); 0; })"
     | Ast.Var "print_no_nl" ->
       (* v0.1.19 (mrog dogfood P2): newline-free flushed write — a TUI's
          cursor-control sequences must not be line-buffered. *)
       "({ fputs(" ^ emit_expr arg ^ ", stdout); fflush(stdout); 0; })"
     (* Q-012: spawn a `unit -> unit` closure on a fresh OS thread. Copy the
        closure value onto the heap so the child owns it, then pthread_create
        the trampoline. Returns a ThreadHandle. *)
     | Ast.Var "spawn" ->
       "({ __auto_type __cl = " ^ emit_expr arg ^ "; \
           __mere_unit_closure* __c = (__mere_unit_closure*)malloc(sizeof(__mere_unit_closure)); \
           __c->env = __cl.env; __c->fn = __cl.fn; \
           ThreadHandle __t; \
           pthread_create(&__t.tid, NULL, __mere_spawn_trampoline, __c); \
           __t; })"
     (* Only the Q-012 thread `join` builtin when not shadowed. `join` is a
        very common user name (e.g. a string-join helper); if it's bound
        locally / lifted / at top level, fall through to the ordinary-call
        cases below instead of emitting pthread_join. *)
     | Ast.Var "join" when
         not (List.mem_assoc "join" !current_var_types
              || List.mem_assoc "join" !current_env_subst
              || Hashtbl.mem inner_lifts "join"
              || Hashtbl.mem toplevel_fn_names "join") ->
       "({ __auto_type __h = " ^ emit_expr arg ^ "; pthread_join(__h.tid, NULL); 0; })"
     (* Q-012: channel primitives, dispatched to the monomorphized runtime.
        The element tag comes from the channel's resolved type. *)
     | Ast.Var "channel_new" ->
       Printf.sprintf "mere_channel_%s_new()" (channel_elem_tag e.ty)
     | Ast.Var "channel_recv" ->
       Printf.sprintf "mere_channel_%s_recv(%s)"
         (channel_elem_tag arg.Ast.ty) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "channel_send"; _ }, ch_e) ->
       Printf.sprintf "mere_channel_%s_send(%s, %s)"
         (channel_elem_tag ch_e.Ast.ty) (emit_expr ch_e) (emit_expr arg)
     | Ast.Var "str_len" ->
       "((int) strlen(" ^ emit_expr arg ^ "))"
     | Ast.App ({ node = Ast.Var "str_index_of"; _ }, h_e) ->
       (* Phase 19.1.1: str_index_of h n — curried, outer App carries
          the needle. Emits a call to the runtime helper. *)
       Printf.sprintf "__lang_str_index_of(%s, %s)"
         (emit_expr h_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "str_compare"; _ }, a_e) ->
       (* Phase 31.0: str_compare a b — interp's `compare s t` (OCaml) returns
          -1/0/1. Sign-normalize strcmp's raw value to align behavior across
          the 3 backends. *)
       Printf.sprintf
         "({ int __r = strcmp(%s, %s); __r < 0 ? -1 : (__r > 0 ? 1 : 0); })"
         (emit_expr a_e) (emit_expr arg)
     (* Phase 34.1: float arithmetic + comparison + unary *)
     | Ast.App ({ node = Ast.Var "f_add"; _ }, a_e) ->
       Printf.sprintf "((%s) + (%s))" (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "f_sub"; _ }, a_e) ->
       Printf.sprintf "((%s) - (%s))" (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "f_mul"; _ }, a_e) ->
       Printf.sprintf "((%s) * (%s))" (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "f_div"; _ }, a_e) ->
       Printf.sprintf "((%s) / (%s))" (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "f_lt"; _ }, a_e) ->
       Printf.sprintf "((%s) < (%s))" (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "f_le"; _ }, a_e) ->
       Printf.sprintf "((%s) <= (%s))" (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "f_gt"; _ }, a_e) ->
       Printf.sprintf "((%s) > (%s))" (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "f_ge"; _ }, a_e) ->
       Printf.sprintf "((%s) >= (%s))" (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "f_min"; _ }, a_e) ->
       Printf.sprintf "({ double __a = (%s); double __b = (%s); __a < __b ? __a : __b; })"
         (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "f_max"; _ }, a_e) ->
       Printf.sprintf "({ double __a = (%s); double __b = (%s); __a > __b ? __a : __b; })"
         (emit_expr a_e) (emit_expr arg)
     | Ast.Var "f_neg" ->
       Printf.sprintf "(-(%s))" (emit_expr arg)
     | Ast.Var "f_abs" ->
       Printf.sprintf "((%s) < 0.0 ? -(%s) : (%s))"
         (emit_expr arg) (emit_expr arg) (emit_expr arg)
     | Ast.Var "float_of_int" ->
       Printf.sprintf "((double)(%s))" (emit_expr arg)
     | Ast.Var "int_of_float" ->
       Printf.sprintf "((int)(%s))" (emit_expr arg)
     | Ast.Var "str_of_float" ->
       Printf.sprintf "__lang_str_of_float(%s)" (emit_expr arg)
     | Ast.Var "float_of_str" ->
       Printf.sprintf "(atof(%s))" (emit_expr arg)
     (* Phase 34.4: libm math functions — auto-linked via clang -lm *)
     | Ast.Var "sqrt" ->
       Printf.sprintf "sqrt(%s)" (emit_expr arg)
     | Ast.Var "sin" ->
       Printf.sprintf "sin(%s)" (emit_expr arg)
     | Ast.Var "cos" ->
       Printf.sprintf "cos(%s)" (emit_expr arg)
     | Ast.Var "tan" ->
       Printf.sprintf "tan(%s)" (emit_expr arg)
     | Ast.App ({ node = Ast.Var "f_pow"; _ }, a_e) ->
       Printf.sprintf "pow(%s, %s)" (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "atan2"; _ }, a_e) ->
       Printf.sprintf "atan2(%s, %s)" (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "str_split"; _ }, s_e) ->
       (* Phase 24.3: str_split s delim — curried. Returns list_str. *)
       str_split_used := true;
       Printf.sprintf "__lang_str_split(%s, %s)"
         (emit_expr s_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "str_join"; _ }, sep_e) ->
       (* Phase 24.3: str_join sep xs — curried. xs : str list. *)
       str_join_used := true;
       Printf.sprintf "__lang_str_join(%s, %s)"
         (emit_expr sep_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "str_count"; _ }, s_e) ->
       Printf.sprintf "__lang_str_count(%s, %s)"
         (emit_expr s_e) (emit_expr arg)
     | Ast.Var "str_trim" ->
       (* Phase 36: str_trim s — strip leading + trailing whitespace *)
       Printf.sprintf "__lang_str_trim(%s)" (emit_expr arg)
     | Ast.App ({ node = Ast.Var "str_starts_with"; _ }, s_e) ->
       (* Phase 36: str_starts_with s p — curried 2-arg *)
       Printf.sprintf "__lang_str_starts_with(%s, %s)"
         (emit_expr s_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "str_eq"; _ }, a_e) ->
       (* str_eq a b — curried 2-arg; same as the `==`-on-str path
          (strcmp). Interp / Wasm have str_eq as a function; the C backend
          previously only had the `==` operator (mq dogfood P6). *)
       Printf.sprintf "(strcmp(%s, %s) == 0)"
         (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_replace"; _ }, s_e); _ }, old_e) ->
       (* Phase 36: str_replace s old new — curried 3-arg *)
       Printf.sprintf "__lang_str_replace(%s, %s, %s)"
         (emit_expr s_e) (emit_expr old_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "str_ends_with"; _ }, s_e) ->
       (* Phase 36: str_ends_with s p — curried 2-arg *)
       Printf.sprintf "__lang_str_ends_with(%s, %s)"
         (emit_expr s_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "str_contains"; _ }, h_e) ->
       (* Phase 36: str_contains haystack needle — bool *)
       Printf.sprintf "(strstr(%s, %s) != NULL)"
         (emit_expr h_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "str_repeat"; _ }, s_e) ->
       Printf.sprintf "__lang_str_repeat(%s, %s)"
         (emit_expr s_e) (emit_expr arg)
     | Ast.Var "str_rev" ->
       Printf.sprintf "__lang_str_rev(%s)" (emit_expr arg)
     | Ast.Var "not" ->
       Printf.sprintf "(!(%s))" (emit_expr arg)
     | Ast.Var "abs" ->
       Printf.sprintf "({ int __a = (%s); __a < 0 ? -__a : __a; })" (emit_expr arg)
     | Ast.App ({ node = Ast.Var "min"; _ }, a_e) ->
       Printf.sprintf "({ int __a = (%s); int __b = (%s); __a < __b ? __a : __b; })"
         (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "max"; _ }, a_e) ->
       Printf.sprintf "({ int __a = (%s); int __b = (%s); __a > __b ? __a : __b; })"
         (emit_expr a_e) (emit_expr arg)
     | Ast.App ({ node = Ast.App ({ node = Ast.Var "clamp"; _ }, lo_e); _ }, hi_e) ->
       (* Phase 36: clamp lo hi x — curried 3-arg, same order as interp *)
       Printf.sprintf "({ int __lo = (%s); int __hi = (%s); int __x = (%s); __x < __lo ? __lo : (__x > __hi ? __hi : __x); })"
         (emit_expr lo_e) (emit_expr hi_e) (emit_expr arg)
     | Ast.Var "chr" ->
       (* Phase 36: chr n — int in [0,255] → single-byte str via char_table *)
       Printf.sprintf "__lang_char_at_chr(%s)" (emit_expr arg)
     | Ast.Var "ord" ->
       (* Phase 36: ord s — single-byte str → int *)
       Printf.sprintf "((int)(unsigned char)((%s)[0]))" (emit_expr arg)
     | Ast.Var "to_upper" ->
       Printf.sprintf "__lang_to_upper(%s)" (emit_expr arg)
     | Ast.Var "to_lower" ->
       Printf.sprintf "__lang_to_lower(%s)" (emit_expr arg)
     | Ast.Var "even" ->
       Printf.sprintf "(((%s) %% 2) == 0)" (emit_expr arg)
     | Ast.Var "odd" ->
       Printf.sprintf "(((%s) %% 2) != 0)" (emit_expr arg)
     | Ast.App ({ node = Ast.Var "gcd"; _ }, a_e) ->
       Printf.sprintf "__lang_gcd(%s, %s)" (emit_expr a_e) (emit_expr arg)
     | Ast.Var "bool_of_str" ->
       (* Phase 36: bool_of_str s — "true" → true, others → false (matches interp) *)
       Printf.sprintf "(strcmp(%s, \"true\") == 0)" (emit_expr arg)
     | Ast.App ({ node = Ast.Var "write_file"; _ }, path_e) ->
       (* Phase 24.4: write_file path content — curried. *)
       Printf.sprintf "__lang_write_file(%s, %s)"
         (emit_expr path_e) (emit_expr arg)
     | Ast.Var "read_file" ->
       Printf.sprintf "__lang_read_file(%s)" (emit_expr arg)
     | Ast.Var "args" ->
       (* Native CLI: argv[1..] as a str list. The unit arg has no effect;
          evaluate it for side-effect-freedom, then build the list. *)
       args_used := true;
       Printf.sprintf "((void)(%s), __lang_args())" (emit_expr arg)
     | Ast.Var "read_stdin" ->
       (* Native CLI: read all of stdin as a str. Unit arg has no effect. *)
       Printf.sprintf "((void)(%s), __lang_read_stdin())" (emit_expr arg)
     | Ast.Var "run" ->
       (* v0.1.13 (mk dogfood): run a command line, return its exit code. *)
       Printf.sprintf "__lang_run(%s)" (emit_expr arg)
     | Ast.Var "tty_raw" ->
       (* v0.1.18 (mrog dogfood): raw terminal mode on stdin. *)
       Printf.sprintf "((void)(%s), __lang_tty_raw())" (emit_expr arg)
     | Ast.Var "tty_restore" ->
       Printf.sprintf "((void)(%s), __lang_tty_restore())" (emit_expr arg)
     | Ast.Var "read_key" ->
       Printf.sprintf "((void)(%s), __lang_read_key())" (emit_expr arg)
     | Ast.Var "random_int" ->
       (* v0.1.20 (mrog dogfood P3): uniform int in [0, n). *)
       Printf.sprintf "__lang_random_int(%s)" (emit_expr arg)
     | Ast.Var "list_dir" ->
       (* Phase 44: list_dir path — sorted entries (excl. `.` / `..`), diff = 0
          with interp. Returns list_str, so set the gating flag *)
       list_dir_used := true;
       Printf.sprintf "__lang_list_dir(%s)" (emit_expr arg)
     | Ast.Var "mkdir_p" ->
       (* Phase 44: equivalent to mkdir -p; skip if already exists *)
       Printf.sprintf "__lang_mkdir_p(%s)" (emit_expr arg)
     | Ast.Var "file_exists" ->
       (* v0.1.15 (mk dogfood P3): whether a path exists (guards file_mtime,
          which raises on a missing path). *)
       Printf.sprintf "__lang_file_exists(%s)" (emit_expr arg)
     | Ast.Var "file_size" ->
       (* v0.1.21 (mwasm dogfood P1): true byte length via stat. *)
       Printf.sprintf "__lang_file_size(%s)" (emit_expr arg)
     | Ast.Var "file_mtime" ->
       (* Phase 44.6: return stat(path).st_mtime as float (seconds) *)
       Printf.sprintf "__lang_file_mtime(%s)" (emit_expr arg)
     | Ast.Var "sleep_ms" ->
       (* Phase 44.6: usleep(ms * 1000), returning unit (0) *)
       Printf.sprintf "__lang_sleep_ms(%s)" (emit_expr arg)
     | Ast.App ({ node = Ast.Var "char_at"; _ }, s_e) ->
       (* Phase 22.3: char_at s i — curried, via a static 256-entry table *)
       Printf.sprintf "__lang_char_at(%s, %s)"
         (emit_expr s_e) (emit_expr arg)
     | Ast.App ({ node = Ast.App ({ node = Ast.Var "substring"; _ }, s_e); _ }, start_e) ->
       (* Phase 22.5: substring s start end_ — 3-arg curried *)
       Printf.sprintf "__lang_substring(%s, %s, %s)"
         (emit_expr s_e) (emit_expr start_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "try_or"; _ }, fn_e) ->
       (* Phase 22.5: try_or fn default — catch fail via setjmp and return
          default on failure. __lang_fail_impl does longjmp when jmpbuf is set,
          abort when unset. Save/restore to support nesting. *)
       let default_c = emit_expr arg in
       let fn_invoke_c =
         Printf.sprintf "({ __auto_type __c = %s; __c.fn(__c.env, 0); })"
           (emit_expr fn_e)
       in
       Printf.sprintf
         "({ jmp_buf __saved_jmp; int __saved_set = __lang_fail_jmpbuf_set; \
             memcpy(__saved_jmp, __lang_fail_jmpbuf, sizeof(jmp_buf)); \
             __lang_fail_jmpbuf_set = 1; \
             __auto_type __default = (%s); \
             __auto_type __res = __default; \
             if (setjmp(__lang_fail_jmpbuf) == 0) { __res = (%s); } \
             __lang_fail_jmpbuf_set = __saved_set; \
             memcpy(__lang_fail_jmpbuf, __saved_jmp, sizeof(jmp_buf)); \
             __res; })"
         default_c fn_invoke_c
     (* Phase 30.0 (DEFERRED §1.12 fix): if a user-defined fn exists with the
        same name, skip builtin dispatch and fall through to the regular user
        fn call path. C version of LLVM Phase 25.7. *)
     | Ast.Var "is_digit" when not (Hashtbl.mem toplevel_fn_names "is_digit") ->
       Printf.sprintf "__lang_is_digit(%s)" (emit_expr arg)
     | Ast.Var "is_alpha" when not (Hashtbl.mem toplevel_fn_names "is_alpha") ->
       Printf.sprintf "__lang_is_alpha(%s)" (emit_expr arg)
     | Ast.Var "is_space" when not (Hashtbl.mem toplevel_fn_names "is_space") ->
       Printf.sprintf "__lang_is_space(%s)" (emit_expr arg)
     | Ast.Var "str_of_int" ->
       (* Phase 22.3: str_of_int is the same as show_int. Emit as an alias. *)
       Printf.sprintf "show_int(%s)" (emit_expr arg)
     | Ast.Var "int_of_str" ->
       (* Phase 22.5: int_of_str s — via atoi (sign + digits). Fail handling
          is omitted (atoi silently returns 0 on invalid input). *)
       Printf.sprintf "atoi(%s)" (emit_expr arg)
     | Ast.Var "str_unescape" ->
       Printf.sprintf "__lang_str_unescape(%s)" (emit_expr arg)
     | Ast.Var "fail" ->
       (* Phase 22.4/22.5: fail msg — noreturn helper followed by a default
          literal chosen based on the expected context type. Primitive types
          use dedicated helpers; non-primitive (tuple / record / variant)
          types resolve the type name via inline c_type_of and append a
          (TY){0} compound literal. *)
       let result_ty =
         match e.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyInt
       in
       let arg_c = emit_expr arg in
       let inline_c_type_of t =
         match Ast.walk t with
         | Ast.TyInt | Ast.TyBool | Ast.TyUnit -> "int"
         | Ast.TyStr -> "const char*"
         | Ast.TyTuple ts -> tuple_struct_name ts
         | Ast.TyCon (n, args) ->
           (* Phase 22.6: polymorphic types need mono-specialized name
              (`list` instantiated to `'a = json` → `list_json`). *)
           if args = [] then n else mono_variant_name n (List.map Ast.walk args)
         | _ -> "int"
       in
       (match result_ty with
        | Ast.TyStr ->
          Printf.sprintf "__lang_fail_str(%s)" arg_c
        | Ast.TyInt | Ast.TyBool | Ast.TyUnit ->
          Printf.sprintf "__lang_fail_int(%s)" arg_c
        | other ->
          let c_ty = inline_c_type_of other in
          Printf.sprintf "({ __lang_fail_impl(%s); (%s){0}; })" arg_c c_ty)
     | Ast.Var "exit" ->
       (* `exit n` — call libc exit(n) (noreturn), then a default value of the
          expected type so the statement-expression type-checks (unreachable).
          Closes mq PAIN P1's last item (native process exit code). Mirrors
          `fail`, which also has an 'a (bottom) result. *)
       let arg_c = emit_expr arg in
       let default =
         match (match e.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyInt) with
         | Ast.TyStr -> "\"\""
         | Ast.TyInt | Ast.TyBool | Ast.TyUnit -> "0"
         | Ast.TyTuple ts -> Printf.sprintf "(%s){0}" (tuple_struct_name ts)
         | Ast.TyCon (n, args) ->
           let cty = if args = [] then n
                     else mono_variant_name n (List.map Ast.walk args) in
           Printf.sprintf "(%s){0}" cty
         | _ -> "0"
       in
       Printf.sprintf "({ exit(%s); %s; })" arg_c default
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
     | Ast.Var "to_json" ->
       (* Polymorphic builtin — dispatch to the type-specialized
          to_json_<tag> function based on arg's inferred type. *)
       let arg_ty =
         match arg.Ast.ty with
         | Some t -> Ast.walk t
         | None -> unsupported e.loc "to_json: missing arg type info"
       in
       Printf.sprintf "to_json_%s(%s)" (ty_tag arg_ty) (emit_expr arg)
     | Ast.Var "of_json" ->
       (* Deserialization mirror: dispatch on the call node's RESULT type
          (the `'a` in `str -> 'a`), read from this App node's inferred ty. *)
       let target_ty =
         match e.Ast.ty with
         | Some t -> Ast.walk t
         | None ->
           unsupported e.loc
             "of_json: cannot infer target type (add an annotation, e.g. `(of_json s : T)`)"
       in
       Printf.sprintf "of_json_%s(%s)" (ty_tag target_ty) (emit_expr arg)
     | Ast.Var "of_json_opt" ->
       (* result is `T option`; dispatch on the inner T's tag. *)
       let inner =
         match e.Ast.ty with
         | Some t ->
           (match Ast.walk t with
            | Ast.TyCon ("option", [inner]) -> Ast.walk inner
            | _ -> unsupported e.loc "of_json_opt: result type is not an option")
         | None -> unsupported e.loc "of_json_opt: cannot infer target type"
       in
       Printf.sprintf "of_json_opt_%s(%s)" (ty_tag inner) (emit_expr arg)
     | Ast.Var "mk_logger" ->
       (* Phase 16.3 / DEFERRED §1.5: emit a runtime helper call that
          returns a Logger record (3 closure_str_unit fields capturing
          the prefix as their env). *)
       logger_used := true;
       Printf.sprintf "__mere_mk_logger(%s)" (emit_expr arg)
     | Ast.Var "mk_metrics" ->
       (* Phase 16.3: mk_metrics () — Metrics record with `inc :
          str -> unit` and `record : str -> int -> unit` curried
          closure. *)
       metrics_used := true;
       Printf.sprintf "__mere_mk_metrics(%s)" (emit_expr arg)
     | Ast.Var "vec_new" ->
       (* Phase 15.1/15.2: vec_new () — extract the region and element type
          from the result type's TyCon args. region = __heap uses the default
          region; otherwise use __region_<R>. Sanitize the element type via
          ty_tag and build the helper name `mere_vec_<tag>_new` (registration
          is delegated to c_type_of — c_type_of runs first here too). *)
       let (region_name, elem_tag) =
         match e.Ast.ty with
         | Some t ->
           (match Ast.walk t with
            | Ast.TyCon ("Vec", [Ast.TyRef (_, r, Ast.TyUnit); et]) ->
              let et = Ast.walk et in
              if ty_is_concrete et then begin
                let tag = ty_tag et in
                if not (Hashtbl.mem vec_instances tag) then
                  Hashtbl.add vec_instances tag et;
                (r, tag)
              end else unsupported e.loc "vec_new: unresolved element type"
            | _ -> unsupported e.loc "vec_new: missing Vec result type")
         | None -> unsupported e.loc "vec_new: missing type info"
       in
       let region_var =
         if region_name = "__heap" then "__lang_default_region"
         else "__region_" ^ region_name
       in
       Printf.sprintf "mere_vec_%s_new(&%s)" elem_tag region_var
     | Ast.Var "vec_len" ->
       let elem_tag = vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
       Printf.sprintf "mere_vec_%s_len(%s)" elem_tag (emit_expr arg)
     | Ast.App ({ node = Ast.Var "vec_push"; _ }, vec_e) ->
       (* `vec_push v x` is curried: App (App (Var "vec_push", v), x).
          The outer App here has inner = App (Var "vec_push", vec_e) and
          arg = x. Return value is unit (int 0). *)
       let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
       Printf.sprintf "mere_vec_%s_push(%s, %s)"
         elem_tag (emit_expr vec_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "vec_get"; _ }, vec_e) ->
       (* `vec_get v i` curried. *)
       let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
       Printf.sprintf "mere_vec_%s_get(%s, %s)"
         elem_tag (emit_expr vec_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "vec_iter"; _ }, vec_e) ->
       (* `vec_iter v f` curried: App (App (Var vec_iter, v), f).
          Phase 15.5: emit inline loop, closure dispatch per element. *)
       let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
       Printf.sprintf
         "({ __auto_type __vc = %s; __auto_type __cl = %s; \
          for (int __i = 0; __i < __vc->len; __i++) { \
            __cl.fn(__cl.env, mere_vec_%s_get(__vc, __i)); \
          } 0; })"
         (emit_expr vec_e) (emit_expr arg) elem_tag
     | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_fold"; _ }, vec_e); _ }, acc_e) ->
       (* `vec_fold v acc f`: outer App's arg is the closure `f`,
          inner App's arg is `acc`, innermost is `v`.
          f : U -> T -> U, so f(env, acc) returns inner closure_T_U.
          Phase 15.5: inline loop with accumulator. *)
       let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
       Printf.sprintf
         "({ __auto_type __vc = %s; __auto_type __acc = %s; \
          __auto_type __outer = %s; \
          for (int __i = 0; __i < __vc->len; __i++) { \
            __auto_type __inner = __outer.fn(__outer.env, __acc); \
            __acc = __inner.fn(__inner.env, mere_vec_%s_get(__vc, __i)); \
          } __acc; })"
         (emit_expr vec_e) (emit_expr acc_e) (emit_expr arg) elem_tag
     | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_set"; _ }, vec_e); _ }, idx_e) ->
       (* `vec_set v i x`: outer App arg = x, inner App arg = i, innermost = v.
          Phase 15.5: dispatch to per-T `mere_vec_<tag>_set` runtime helper. *)
       let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
       Printf.sprintf "mere_vec_%s_set(%s, %s, %s)"
         elem_tag (emit_expr vec_e) (emit_expr idx_e) (emit_expr arg)
     | Ast.Var "vec_reverse" ->
       (* Phase 19.3: in-place reverse via swap loop. Returns 0 (unit). *)
       let elem_tag = vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
       let _ = elem_tag in
       Printf.sprintf
         "({ __auto_type __vc = %s; \
          int __lo = 0, __hi = __vc->len - 1; \
          while (__lo < __hi) { \
            __auto_type __tmp = __vc->data[__lo]; \
            __vc->data[__lo] = __vc->data[__hi]; \
            __vc->data[__hi] = __tmp; \
            __lo++; __hi--; \
          } 0; })"
         (emit_expr arg)
     | Ast.App ({ node = Ast.Var "vec_concat"; _ }, a_e) ->
       (* Phase 19.3: vec_concat a b — allocate new Vec in a's region,
          push all of a's then b's elements. *)
       let elem_tag = vec_elem_tag_of a_e.Ast.ty a_e.Ast.loc in
       Printf.sprintf
         "({ __auto_type __va = %s; __auto_type __vb = %s; \
          mere_vec_%s* __new = mere_vec_%s_new(__va->region); \
          for (int __i = 0; __i < __va->len; __i++) \
            mere_vec_%s_push(__new, mere_vec_%s_get(__va, __i)); \
          for (int __i = 0; __i < __vb->len; __i++) \
            mere_vec_%s_push(__new, mere_vec_%s_get(__vb, __i)); \
          __new; })"
         (emit_expr a_e) (emit_expr arg)
         elem_tag elem_tag elem_tag elem_tag elem_tag elem_tag
     | Ast.App ({ node = Ast.Var "vec_sort"; _ }, vec_e) ->
       (* Phase 19.3: vec_sort v cmp — in-place insertion sort with
          comparator (T -> T -> int) curried. cmp.fn(env, a) returns
          inner closure, then inner.fn(inner.env, b) returns int.
          Insertion sort is O(n²) but simple and inline-friendly;
          replace with quicksort if perf needed. *)
       let _ = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
       Printf.sprintf
         "({ __auto_type __vs = %s; __auto_type __cmp = %s; \
          for (int __i = 1; __i < __vs->len; __i++) { \
            __auto_type __key = __vs->data[__i]; \
            int __j = __i - 1; \
            while (__j >= 0) { \
              __auto_type __inner = __cmp.fn(__cmp.env, __vs->data[__j]); \
              if (__inner.fn(__inner.env, __key) <= 0) break; \
              __vs->data[__j + 1] = __vs->data[__j]; \
              __j--; \
            } \
            __vs->data[__j + 1] = __key; \
          } 0; })"
         (emit_expr vec_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "vec_map"; _ }, vec_e) ->
       (* Phase 15.6: vec_map v f — returns a region-preserving new Vec.
          Extract v's element type T and the result Vec's element type U
          from the AST. Emit inline via a GCC/Clang statement expression. *)
       let t_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
       let u_tag = vec_elem_tag_of e.Ast.ty e.Ast.loc in
       Printf.sprintf
         "({ __auto_type __vc = %s; __auto_type __cl = %s; \
          mere_vec_%s* __new = mere_vec_%s_new(__vc->region); \
          for (int __i = 0; __i < __vc->len; __i++) { \
            mere_vec_%s_push(__new, __cl.fn(__cl.env, mere_vec_%s_get(__vc, __i))); \
          } __new; })"
         (emit_expr vec_e) (emit_expr arg) u_tag u_tag u_tag t_tag
     | Ast.Var "owned_vec_new" ->
       (* Phase 15.7: owned_vec_new () — heap-allocated. Extract the element
          type T from the resulting OwnedVec[T]. *)
       let elem_tag = owned_vec_elem_tag_of e.Ast.ty e.Ast.loc in
       Printf.sprintf "mere_owned_vec_%s_new()" elem_tag
     | Ast.Var "owned_vec_len" ->
       let elem_tag = owned_vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
       Printf.sprintf "mere_owned_vec_%s_len(%s)" elem_tag (emit_expr arg)
     | Ast.App ({ node = Ast.Var "owned_vec_push"; _ }, vec_e) ->
       let elem_tag = owned_vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
       Printf.sprintf "mere_owned_vec_%s_push(%s, %s)"
         elem_tag (emit_expr vec_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "owned_vec_get"; _ }, vec_e) ->
       let elem_tag = owned_vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
       Printf.sprintf "mere_owned_vec_%s_get(%s, %s)"
         elem_tag (emit_expr vec_e) (emit_expr arg)
     | Ast.Var "vec_to_list" ->
       (* Phase 15.12: vec_to_list v — deep-copy region Vec[R, T] into a
          `T list`. Build the Cons chain inline, bottom-up. The element type
          T, result mono name (`list_<T>`), Cons/Nil tags, and Cons tuple
          struct name are all resolved at codegen time. *)
       let t_tag = vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
       let t_ty = Hashtbl.find vec_instances t_tag in
       let result_ty =
         match e.Ast.ty with
         | Some t -> Ast.walk t
         | None -> unsupported e.Ast.loc "vec_to_list: missing result type"
       in
       let mono_list =
         match result_ty with
         | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
           mono_variant_name n (List.map Ast.walk args)
         | Ast.TyCon (n, []) -> n
         | _ -> unsupported e.Ast.loc "vec_to_list: result is not a list type"
       in
       (* Cons payload is a tuple (T, list_T). The tuple struct name. *)
       let tup_name =
         tuple_struct_name [t_ty; Ast.TyCon (mono_list, [])]
       in
       let cons_tag =
         try Hashtbl.find variant_tags "Cons"
         with Not_found ->
           unsupported e.Ast.loc
             "vec_to_list: result type must have a `Cons` constructor"
       in
       let nil_tag =
         try Hashtbl.find variant_tags "Nil"
         with Not_found ->
           unsupported e.Ast.loc
             "vec_to_list: result type must have a `Nil` constructor"
       in
       Printf.sprintf
         "({ __auto_type __v = %s; \
          %s __acc = (%s)__lang_region_alloc(&__lang_default_region, sizeof(%s_node)); \
          __acc->tag = %d; \
          for (int __i = __v->len - 1; __i >= 0; __i--) { \
            %s __new_node = (%s)__lang_region_alloc(&__lang_default_region, sizeof(%s_node)); \
            __new_node->tag = %d; \
            __new_node->payload.Cons.f0 = mere_vec_%s_get(__v, __i); \
            __new_node->payload.Cons.f1 = __acc; \
            __acc = __new_node; \
          } __acc; })"
         (emit_expr arg)
         mono_list mono_list mono_list
         nil_tag
         mono_list mono_list mono_list
         cons_tag
         t_tag
         |> fun s -> ignore tup_name; s
     | Ast.Var "vec_to_owned" ->
       (* Phase 15.7: vec_to_owned v — deep-copy a Vec in a region into a heap
          OwnedVec. Extract the element type T from v. *)
       let t_tag = vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
       (* Result is OwnedVec[T] — register that too. *)
       (try
          let elem_ty = Hashtbl.find vec_instances t_tag in
          if not (Hashtbl.mem owned_vec_instances t_tag) then
            Hashtbl.add owned_vec_instances t_tag elem_ty
        with Not_found -> ());
       Printf.sprintf
         "({ __auto_type __vc = %s; __auto_type __new = mere_owned_vec_%s_new(); \
          for (int __i = 0; __i < __vc->len; __i++) { \
            mere_owned_vec_%s_push(__new, mere_vec_%s_get(__vc, __i)); \
          } __new; })"
         (emit_expr arg) t_tag t_tag t_tag
     | Ast.Var "len" ->
       (* Phase 15.11: len dispatches at compile time based on arg.ty.
          Vec / OwnedVec / StrBuf / Map → route to the existing _len helpers;
          str → strlen; tuple → static arity constant. *)
       let arg_ty =
         match arg.Ast.ty with
         | Some t -> Ast.walk t
         | None -> unsupported arg.Ast.loc "len: missing arg type info"
       in
       (match arg_ty with
        | Ast.TyCon ("Vec", _) ->
          let t_tag = vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
          Printf.sprintf "mere_vec_%s_len(%s)" t_tag (emit_expr arg)
        | Ast.TyCon ("OwnedVec", _) ->
          let t_tag = owned_vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
          Printf.sprintf "mere_owned_vec_%s_len(%s)" t_tag (emit_expr arg)
        | Ast.TyCon ("StrBuf", _) ->
          strbuf_used := true;
          Printf.sprintf "mere_strbuf_len(%s)" (emit_expr arg)
        | Ast.TyCon ("Map", _) ->
          let (k_tag, v_tag) = map_kv_tags_of arg.Ast.ty arg.Ast.loc in
          Printf.sprintf "mere_map_%s_%s_len(%s)"
            k_tag v_tag (emit_expr arg)
        | Ast.TyStr ->
          Printf.sprintf "((int)strlen(%s))" (emit_expr arg)
        | Ast.TyTuple ts ->
          (* Static arity — just emit the constant. Arg evaluated for
             side effects but discarded. *)
          Printf.sprintf "({ (void)(%s); %d; })"
            (emit_expr arg) (List.length ts)
        | Ast.TyCon (n, _) when Hashtbl.mem polymorphic_variants n
                             && Hashtbl.mem variant_tags "Cons"
                             && Hashtbl.mem variant_tags "Nil" ->
          (* Phase 15.12: `len` on `T list` (Nil/Cons chain). Walk the
             cons chain counting. Works for any user-declared
             `type 'a list = Nil | Cons of 'a * 'a list`-shaped variant. *)
          let cons_tag = Hashtbl.find variant_tags "Cons" in
          Printf.sprintf
            "({ __auto_type __l = %s; int __n = 0; \
             while (__l->tag == %d) { __n++; __l = __l->payload.Cons.f1; } __n; })"
            (emit_expr arg) cons_tag
        | _ ->
          unsupported e.loc
            "len: arg type has no codegen-defined length (use vec_len / strbuf_len / map_len / str_len for specific types)")
     | Ast.Var "map_new" ->
       (* Phase 15.10: map_new () — extract region and (K, V) from the result type. *)
       let (k_tag, v_tag) = map_kv_tags_of e.Ast.ty e.Ast.loc in
       let region_name =
         match e.Ast.ty with
         | Some t ->
           (match Ast.walk t with
            | Ast.TyCon ("Map", [Ast.TyRef (_, r, Ast.TyUnit); _; _]) -> r
            | _ -> "__heap")
         | None -> "__heap"
       in
       let region_var =
         if region_name = "__heap" then "__lang_default_region"
         else "__region_" ^ region_name
       in
       Printf.sprintf "mere_map_%s_%s_new(&%s)" k_tag v_tag region_var
     | Ast.Var "map_len" ->
       let (k_tag, v_tag) = map_kv_tags_of arg.Ast.ty arg.Ast.loc in
       Printf.sprintf "mere_map_%s_%s_len(%s)" k_tag v_tag (emit_expr arg)
     | Ast.App ({ node = Ast.Var "map_get"; _ }, m_e) ->
       let (k_tag, v_tag) = map_kv_tags_of m_e.Ast.ty m_e.Ast.loc in
       Printf.sprintf "mere_map_%s_%s_get(%s, %s)"
         k_tag v_tag (emit_expr m_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "map_has"; _ }, m_e) ->
       let (k_tag, v_tag) = map_kv_tags_of m_e.Ast.ty m_e.Ast.loc in
       Printf.sprintf "mere_map_%s_%s_has(%s, %s)"
         k_tag v_tag (emit_expr m_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "map_delete"; _ }, m_e) ->
       (* Phase 39.A' #2: map_delete m k — call the runtime helper. *)
       let (k_tag, v_tag) = map_kv_tags_of m_e.Ast.ty m_e.Ast.loc in
       Printf.sprintf "mere_map_%s_%s_delete(%s, %s)"
         k_tag v_tag (emit_expr m_e) (emit_expr arg)
     | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_set"; _ }, m_e); _ }, k_e) ->
       (* map_set m k v : outer arg = v, inner App arg = k, innermost = m *)
       let (k_tag, v_tag) = map_kv_tags_of m_e.Ast.ty m_e.Ast.loc in
       Printf.sprintf "mere_map_%s_%s_set(%s, %s, %s)"
         k_tag v_tag (emit_expr m_e) (emit_expr k_e) (emit_expr arg)
     | Ast.App ({ node = Ast.Var "map_iter"; _ }, m_e) ->
       (* Phase 19.2: `map_iter m f` curried. closure f : K -> V -> unit,
          so f.fn(env, k) returns inner closure_V_unit, then
          inner.fn(inner.env, v) returns unit. Inline loop over keys/values
          parallel arrays. __auto_type infers types from the runtime call. *)
       let _ = map_kv_tags_of m_e.Ast.ty m_e.Ast.loc in
       Printf.sprintf
         "({ __auto_type __m = %s; __auto_type __outer = %s; \
          for (int __i = 0; __i < __m->len; __i++) { \
            __auto_type __inner = __outer.fn(__outer.env, __m->keys[__i]); \
            __inner.fn(__inner.env, __m->values[__i]); \
          } 0; })"
         (emit_expr m_e) (emit_expr arg)
     | Ast.Var "strbuf_new" ->
       (* Phase 15.9: strbuf_new () — extract the region from the result type's
          TyCon arg. Same convention as Vec[R, T]. *)
       strbuf_used := true;
       let region_name =
         match e.Ast.ty with
         | Some t ->
           (match Ast.walk t with
            | Ast.TyCon ("StrBuf", [Ast.TyRef (_, r, Ast.TyUnit)]) -> r
            | _ -> "__heap")
         | None -> "__heap"
       in
       let region_var =
         if region_name = "__heap" then "__lang_default_region"
         else "__region_" ^ region_name
       in
       Printf.sprintf "mere_strbuf_new(&%s)" region_var
     | Ast.Var "strbuf_len" ->
       strbuf_used := true;
       Printf.sprintf "mere_strbuf_len(%s)" (emit_expr arg)
     | Ast.Var "strbuf_to_str" ->
       strbuf_used := true;
       Printf.sprintf "mere_strbuf_to_str(%s)" (emit_expr arg)
     | Ast.App ({ node = Ast.Var "strbuf_push"; _ }, sb_e) ->
       strbuf_used := true;
       Printf.sprintf "mere_strbuf_push(%s, %s)"
         (emit_expr sb_e) (emit_expr arg)
     | Ast.Var "owned_vec_to_vec" ->
       (* Phase 15.7: owned_vec_to_vec o — deep-copy a heap OwnedVec into a
          region Vec. Extract the region from the result Vec's TyRef marker. *)
       let t_tag = owned_vec_elem_tag_of arg.Ast.ty arg.Ast.loc in
       let region_name =
         match e.Ast.ty with
         | Some t ->
           (match Ast.walk t with
            | Ast.TyCon ("Vec", [Ast.TyRef (_, r, Ast.TyUnit); _]) -> r
            | _ -> "__heap")
         | None -> "__heap"
       in
       let region_var =
         if region_name = "__heap" then "__lang_default_region"
         else "__region_" ^ region_name
       in
       (* Result is Vec[R, T] — register element type for runtime emission. *)
       (try
          let elem_ty = Hashtbl.find owned_vec_instances t_tag in
          if not (Hashtbl.mem vec_instances t_tag) then
            Hashtbl.add vec_instances t_tag elem_ty
        with Not_found -> ());
       Printf.sprintf
         "({ __auto_type __ov = %s; __auto_type __new = mere_vec_%s_new(&%s); \
          for (int __i = 0; __i < __ov->len; __i++) { \
            mere_vec_%s_push(__new, mere_owned_vec_%s_get(__ov, __i)); \
          } __new; })"
         (emit_expr arg) t_tag region_var t_tag t_tag
     | Ast.App ({ node = Ast.Var "vec_filter"; _ }, vec_e) ->
       (* Phase 15.6: vec_filter v f — region-preserving; keep only elements
          where the predicate is true. Element type T is the same for v and
          the result. Use __auto_type to defer C type resolution to the
          compiler (since c_type_of is not visible from here). *)
       let elem_tag = vec_elem_tag_of vec_e.Ast.ty vec_e.Ast.loc in
       Printf.sprintf
         "({ __auto_type __vc = %s; __auto_type __cl = %s; \
          mere_vec_%s* __new = mere_vec_%s_new(__vc->region); \
          for (int __i = 0; __i < __vc->len; __i++) { \
            __auto_type __x = mere_vec_%s_get(__vc, __i); \
            if (__cl.fn(__cl.env, __x)) { mere_vec_%s_push(__new, __x); } \
          } __new; })"
         (emit_expr vec_e) (emit_expr arg) elem_tag elem_tag
         elem_tag elem_tag
     | Ast.Var name when Hashtbl.mem inner_lifts name ->
       (* Defunctionalized direct call (Phase 4.8).
          Phase 22.5 fix: capture name might refer to a closure-env field
          if the call site is inside an adapter (e.g., `parse_number =
          fn s -> fn i -> ...lifted_scan i...` where the second fn is
          a closure capturing s). Route capture refs through
          current_env_subst the same way bare Var emission does. *)
       let li = Hashtbl.find inner_lifts name in
       let cap_args = List.map (fun (n, _) ->
         match List.assoc_opt n !current_env_subst with
         | Some s -> s
         | None -> n
       ) li.captures in
       li.lifted_name ^ "(" ^
       String.concat ", " (cap_args @ [emit_expr arg]) ^ ")"
     | Ast.Var name when Hashtbl.mem toplevel_fn_names name
                         && not (List.mem_assoc name !current_var_types)
                         && not (List.mem_assoc name !current_env_subst) ->
       (* Direct call to a known top-level fn — fast path, no closure.
          Guarded so a same-named local binding / captured parameter (e.g.
          the prelude `list_fold`'s parameter `f` vs a user top-level `let
          f`) falls through to the closure-value call path instead. *)
       (* Phase 23.3: per-instantiation dispatch. If name is multi-inst,
          use the call site's Var.ty (walked, which is the specific
          arrow type for this use) to pick the mangled name. *)
       let fn_name =
         if Hashtbl.mem multi_inst_fns name then
           match f.Ast.ty with
           | Some t ->
             (match Ast.walk t with
              | Ast.TyArrow _ as arrow -> mangled_inst_name name arrow
              | _ -> c_safe_name name)
           | None -> c_safe_name name
         else c_safe_name name
       in
       fn_name ^ "(" ^ emit_expr arg ^ ")"
     | _ ->
       (* Closure dispatch via the closure value's fn pointer + env. *)
       Printf.sprintf
         "({ __auto_type __c = %s; __c.fn(__c.env, %s); })"
         (emit_expr f) (emit_expr arg)))
  | Ast.Constr (raw_name, arg_opt) ->
    (* Phase 41 + 42: since alias_ctor also registers `Traffic.Red` in
       Typer.constructors, look up the qualified raw_name **first** (to
       disambiguate Light/Red vs Color/Red when two modules share a ctor
       name `Red`). If the raw lookup misses, fall back to the canonical
       name (`Red`). variant_tags is keyed only by bare names, so use the
       canonical name there. *)
    let info =
      match Hashtbl.find_opt Typer.constructors raw_name with
      | Some i -> i
      | None ->
        let cname = Ast.canonical_ctor raw_name in
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some i -> i
         | None -> unsupported e.loc ("unknown constructor: " ^ raw_name))
    in
    let name = Ast.canonical_ctor raw_name in
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
    (* Phase 36 (DEFERRED §1.15 fix): emit the payload arg ONCE.
       The old code called `emit_expr arg` from both the payload_str
       initializer (used by the non-recursive branch) AND from the
       recursive branch's `__p->payload` assignment, so nested Cons
       triggered exponential 2^N re-emission. *)
    let arg_c_opt =
      match arg_opt with
      | None -> None
      | Some arg -> Some (emit_expr arg)
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
        (match arg_c_opt with
         | None -> ""
         | Some arg_c -> "; __p->payload." ^ name ^ " = " ^ arg_c)
    else
      let payload_str =
        match arg_c_opt with
        | None -> ""
        | Some arg_c -> Printf.sprintf ", .payload.%s = %s" name arg_c
      in
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
    (* Phase 22.5 fix: non-exhaustive fallthrough — emit a value of the
       MATCH result type, not always `0` (int). Otherwise tuple/record
       returning matches break with "incompatible operand types". *)
    let match_result_ty =
      match e.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyInt
    in
    let fallthrough_default =
      match match_result_ty with
      | Ast.TyInt | Ast.TyBool | Ast.TyUnit -> "({ abort(); 0; })"
      | Ast.TyStr -> "({ abort(); \"\"; })"
      | Ast.TyTuple ts ->
        Printf.sprintf "({ abort(); (%s){0}; })" (tuple_struct_name ts)
      | Ast.TyCon (n, args) ->
        (* Phase 22.6: polymorphic types need mono name. *)
        let c_n =
          if args = [] then n
          else mono_variant_name n (List.map Ast.walk args)
        in
        Printf.sprintf "({ abort(); (%s){0}; })" c_n
      | _ -> "({ abort(); 0; })"
    in
    (* Emit nested ternaries — each arm's body is wrapped in a
       statement expression so the pattern bindings are in scope for
       the guard (if any) and the body. *)
    let rec emit_arms = function
      | [] -> fallthrough_default
      | (pat, guard, body) :: rest ->
        let (test, bindings) = compile_pattern pat "__scrut" scrut_ty in
        let next = emit_arms rest in
        (* Phase 28.1 (DEFERRED §1.9 fix): add pattern-bound names to
           current_var_types so nested closures emitted within the arm
           body can capture them. Otherwise the free_vars filter strips
           them out and emits undeclared-identifier C. *)
        let pat_bindings = pattern_vars_with_types pat scrut_ty in
        let with_pat f =
          let prev = !current_var_types in
          current_var_types := pat_bindings @ prev;
          let r = try f () with ex -> current_var_types := prev; raise ex in
          current_var_types := prev;
          r
        in
        let body_c = with_pat (fun () -> emit_expr body) in
        let bound =
          match guard with
          | None ->
            Printf.sprintf "({ %s%s; })" bindings body_c
          | Some g ->
            let guard_c = with_pat (fun () -> emit_expr g) in
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
  | Ast.Ref (_mode, region, inner) ->
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
           | Ast.TyCon (_, [Ast.TyRef (_, r, _)]) -> r
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
      (* Regular record literal. Use mono name if polymorphic.
         Phase 42: convert M-qualified record names (`Shapes.Rect`) to a
         C identifier via c_safe_name (`Shapes__Rect`). *)
      let cstruct =
        if Hashtbl.mem polymorphic_records name then
          match e.Ast.ty with
          | Some t ->
            (match Ast.walk t with
             | Ast.TyCon (n, args) when n = name ->
               mono_record_name n (List.map Ast.walk args)
             | _ -> c_safe_name name)
          | None -> c_safe_name name
        else c_safe_name name
      in
      "((" ^ cstruct ^ "){" ^ String.concat ", " parts ^ "})"
    end
  | Ast.Field_get (inner, fname) ->
    (* `->` for view (pointer) values OR for `&[mode] R T` borrowed
       records (Phase 19.x: c_type_of TyRef → inner*, so field access
       needs ptr arrow). `.` for plain records. *)
    let dot =
      match inner.Ast.ty with
      | Some t when is_view_type t -> "->"
      | Some t ->
        (match Ast.walk t with
         | Ast.TyRef _ -> "->"
         | _ -> ".")
      | None -> "."
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
  | Ast.P_constr (raw_cname, sub_opt) ->
    (* Phase 41 + 42: qualified ctor pattern (`| M.Foo -> ...`).
       variant_tags is keyed by bare names, so look up using canonical. *)
    let cname = Ast.canonical_ctor raw_cname in
    let tag =
      try Hashtbl.find variant_tags cname
      with Not_found ->
        unsupported pat.Ast.ploc ("unknown constructor in pattern: " ^ raw_cname)
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
  | Ast.TyCon ("Vec", args) ->
    (* Phase 15.2: Vec[R, T] — expand T to a concrete type and produce
       `mere_vec_<tag>*`. args have not been walked yet, so walk them here
       before inspection. Sanitize the element type via ty_tag and register
       it in `vec_instances` (runtime generation is batched in emit_program). *)
    (match List.map Ast.walk args with
     | [_; elem_ty] when ty_is_concrete elem_ty ->
       let tag = ty_tag elem_ty in
       if not (Hashtbl.mem vec_instances tag) then
         Hashtbl.add vec_instances tag elem_ty;
       "mere_vec_" ^ tag ^ "*"
     | _ ->
       raise (Codegen_error (Loc.dummy,
         "unsupported in C codegen subset: Vec[R, <unresolved>] (element type must be concrete; monomorphize failed if a tyvar remains)")))
  | Ast.TyCon ("OwnedVec", args) ->
    (* Phase 15.7: OwnedVec[T] — heap-allocated. Walk the element type T and
       return `mere_owned_vec_<tag>*`. Monomorphization runs in parallel with
       Vec[R, T]. *)
    (match List.map Ast.walk args with
     | [elem_ty] when ty_is_concrete elem_ty ->
       let tag = ty_tag elem_ty in
       if not (Hashtbl.mem owned_vec_instances tag) then
         Hashtbl.add owned_vec_instances tag elem_ty;
       "mere_owned_vec_" ^ tag ^ "*"
     | _ ->
       raise (Codegen_error (Loc.dummy,
         "unsupported in C codegen subset: OwnedVec[<unresolved>] (element type must be concrete)")))
  | Ast.TyCon ("StrBuf", _) ->
    (* Phase 15.9: StrBuf[R] — single non-polymorphic type, `mere_strbuf*`.
       Unlike Vec, the region marker is not used; tracking is done via a
       region ptr inside the struct. *)
    strbuf_used := true;
    "mere_strbuf*"
  | Ast.TyCon ("Channel", args) ->
    (* Q-012: Channel[T] — heap-allocated blocking FIFO, monomorphized per
       element type to `mere_channel_<tag>*` (registered in channel_instances,
       runtime batched in emit_program). *)
    (match List.map Ast.walk args with
     | [elem_ty] when ty_is_concrete elem_ty ->
       let tag = ty_tag elem_ty in
       if not (Hashtbl.mem channel_instances tag) then
         Hashtbl.add channel_instances tag elem_ty;
       "mere_channel_" ^ tag ^ "*"
     | _ ->
       raise (Codegen_error (Loc.dummy,
         "unsupported in C codegen subset: Channel[<unresolved>] (element type must be concrete)")))
  | Ast.TyCon ("Map", args) ->
    (* Phase 15.10/15.14/15.15: Map[R, K, V] — per-(K, V) monomorphize.
       K = int / bool / str / tuple / record / nullary variant. *)
    (match List.map Ast.walk args with
     | [_; k_ty; v_ty]
       when ty_is_concrete k_ty && ty_is_concrete v_ty ->
       let k_tag = ty_tag k_ty in
       let v_tag = ty_tag v_ty in
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
         raise (Codegen_error (Loc.dummy,
           "Map key type must be int / bool / str / tuple / record / variant in C codegen (Phase 15.10-15.16)"));
       let key = k_tag ^ "__" ^ v_tag in
       if not (Hashtbl.mem map_instances key) then
         Hashtbl.add map_instances key (k_ty, v_ty);
       Printf.sprintf "mere_map_%s_%s*" k_tag v_tag
     | _ ->
       raise (Codegen_error (Loc.dummy,
         "unsupported in C codegen subset: Map[<unresolved>] (K and V must be concrete)")))
  | Ast.TyInt | Ast.TyBool -> "int"
  | Ast.TyFloat -> "double"  (* Phase 34.1: IEEE 754 double *)
  | Ast.TyStr -> "const char*"
  | Ast.TyUnit -> "int"  (* unit becomes int 0; keeps return-type uniform *)
  | Ast.TyTuple ts -> tuple_struct_name ts
  | Ast.TyArrow (p, r) -> closure_struct_name p r
  | Ast.TyRef (_, _, inner) ->
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
    (* Monomorphic user-declared record type. Phase 42: for M-qualified
       names, convert `Shapes.Rect` to the C identifier `Shapes__Rect`. *)
    c_safe_name name
  | Ast.TyCon (name, args) when Hashtbl.mem polymorphic_variants name ->
    (* Polymorphic variant instantiation — pick the specialized name
       (`list_int`, `opt_str`, ...). For recursive instantiations this
       name is the ptr typedef; for non-recursive it's the struct. *)
    mono_variant_name name (List.map Ast.walk args)
  | Ast.TyCon (name, _) when Hashtbl.mem Typer.types name ->
    (* Monomorphic user-declared variant type. Phase 42: also sanitize any
       M-qualified type name (anticipated for future). Currently variant
       aliases are normalized to the bare name (Light) by the parser, but
       we run them through defensively just like records. *)
    c_safe_name name
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
    | Ast.Let (pat, value, rest) ->
      (* Phase 24.4: walk through ALL top-level Let chains so a non-Fun
         Let (e.g., `let path = "/tmp/x"`) doesn't break the chain and
         block subsequent `let rec` from being lifted. Fun-valued Lets
         with P_var → extract as skel + drop from body. Other Lets →
         keep in body + walk rest.
         Phase 37.A: `let _ = while ... ;` at top-level desugars to
         `Let (P_wild, Let_rec (bs, call_loop), rest)`. Recognize that
         shape and lift the inner Let_rec bindings as top-level skels,
         replacing the value with the inner Let_rec body. *)
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
    | Ast.Ref (_, _, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  go e;
  !found

(* Phase 23.1 (DEFERRED §1.7 multi-instantiation): collect ALL distinct
   concrete arrow types at use sites of `name`. Used to detect when a
   single-specialization emit would silently miscompile.

   Phase 23.3: takes a list of exprs to scan, so chained-poly multi-inst
   can include cloned bodies of already-specialized parent fns (e.g.,
   to detect rev_aux's multi-inst from rev's cloned bodies). *)
let find_all_concrete_arrows_in (name : string) (exprs : Ast.expr list) : Ast.ty list =
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

(* Phase 23.3: deep-clone an expression with fresh tyvars.
   For multi-instantiation specialization of poly fns: the original
   body's tyvars are shared (mutable refs) so we can't independently
   unify them to different concrete types. Cloning produces a body
   tree where every TyVar.id is fresh and link=None. Tyvar identity
   within the clone is preserved via a per-clone id→fresh map.

   Concrete types (TyInt, TyArrow with no vars, etc.) are recreated
   structurally — cheap and correct. TyParam (source-level 'a) is
   preserved as-is. *)
let clone_with_fresh_tyvars (e : Ast.expr) : Ast.expr =
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

(* Build fn_decls from the typer-annotated AST. For each skeleton, prefer
   the Fun's own .ty if it's already concrete; otherwise (let-poly
   generalized it) recover a concrete arrow type by scanning the main
   expression for a use-site Var with the same name. *)
let resolve_fn_types (skels : fn_skel list) (root : Ast.expr) : fn_decl list =
  (* Phase 21.1 (DEFERRED §1.7) + 21.2 multi-pass:
     - Each pass tries to resolve each yet-unresolved fn by either (a)
       observing its Fun.ty has become concrete via prior unify, or (b)
       calling find_concrete_arrow to locate an external use site, then
       unifying.
     - Repeat until no progress. This handles chained poly helpers
       (e.g., list_rev calls list_rev_into; once list_rev is unified
       via its top-level use, list_rev_into's Var inside list_rev's
       body has concrete .ty and find_concrete_arrow picks it up next
       pass).
     - Unused poly fns (stdlib helpers user didn't reference) stay
       unresolved and are silently filtered out. *)
  let resolved : (string, Ast.ty) Hashtbl.t = Hashtbl.create 16 in
  let progress = ref true in
  Hashtbl.reset multi_inst_fns;
  let multi_specs : (string, (Ast.ty * Ast.expr) list) Hashtbl.t =
    Hashtbl.create 4
  in
  (* Phase 43 (DEFERRED §1.7 fix): the clone helper for multi-inst, reused
     in 2 paths (initial scan + re-scan of existing multi_specs entries
     when new instantiations are discovered). *)
  let make_spec arrow s =
    let cloned_fun = clone_with_fresh_tyvars s.sfun in
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
        (* Phase 43 fix (DEFERRED §1.7): re-scan multi-inst fns each pass.
           When a chained poly call site becomes concrete in a later pass
           (e.g., `let bool_eq = fn b -> poly_eq true b` resolves bool ->
           int → bool_eq's body's `poly_eq true b` adds bool arrow to
           poly_eq specs), grow the spec list. *)
        let all = find_all_concrete_arrows_in s.sname (root :: extra_exprs ()) in
        let existing = Hashtbl.find multi_specs s.sname in
        let existing_arrows = List.map fst existing in
        (* Type equality via pp_ty string compare (simple but sufficient — same
           pattern used by ty_tag for naming) *)
        let new_arrows = List.filter (fun a ->
          let a_str = Ast.pp_ty (Ast.walk a) in
          not (List.exists (fun e -> Ast.pp_ty (Ast.walk e) = a_str) existing_arrows)) all
        in
        if new_arrows <> [] then begin
          let new_specs = List.map (fun a -> make_spec a s) new_arrows in
          Hashtbl.replace multi_specs s.sname (existing @ new_specs);
          (* multi_inst_fns is used by emit_expr to pick mangled name;
             keep the arrow list in sync. *)
          Hashtbl.replace multi_inst_fns s.sname (existing_arrows @ new_arrows);
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
          let all = find_all_concrete_arrows_in s.sname (root :: extra_exprs ()) in
          match all with
          | _ :: _ ->
            if List.length all > 1 then begin
              Hashtbl.add multi_inst_fns s.sname all;
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
      (* Emit one fn_decl per instantiation, mangled name + cloned body. *)
      List.map (fun (arrow, cloned_body) ->
        match Ast.walk arrow with
        | Ast.TyArrow (p, r) ->
          { name = mangled_inst_name s.sname arrow;
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
       | None -> []  (* unused poly fn — skip *)
       | Some (Ast.TyArrow (p, r)) ->
         [{ name = s.sname; param = s.sparam; body = s.sbody;
            param_ty = Ast.walk p; return_ty = Ast.walk r }]
       | Some other ->
         raise (Codegen_error (s.sfun.Ast.loc,
           Printf.sprintf "function `%s` has non-arrow inferred type `%s`"
             s.sname (Ast.pp_ty other))))
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
  l_host      : string;
    (* Phase 22.5: which top-level fn this was lifted out of — used to
       switch inner_lifts scope at emit time so sibling lifted fns in
       the same host see each other's mappings (e.g., mutual recursion
       inside a `let rec ... and ...`). *)
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
  (* Phase 22.5: switch inner_lifts to this host's scope before
     emitting body, so call-site dispatch finds the right local
     lifted-fn (e.g., `loop` in parse_add vs parse_term). *)
  set_inner_lifts_for_host f.name;
  let body_c =
    with_var_types [(f.param, f.param_ty)] (fun () ->
      with_expected_ty f.return_ty (fun () -> emit_expr f.body))
  in
  Printf.sprintf "%s %s(%s %s) {\n  return %s;\n}"
    (c_type_of f.return_ty)
    (c_safe_name f.name)
    (c_type_of f.param_ty)
    f.param
    body_c

let emit_lifted_fn (f : lifted_fn) : string =
  (* Same host scope as the host fn it was lifted from — for sibling
     mutual recursion inside `let rec ... and ...`. *)
  set_inner_lifts_for_host f.l_host;
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
    (c_type_of f.return_ty) (c_safe_name f.name) (c_type_of f.param_ty)

(* Closure-value wrapper for a top-level fn: an env-ignoring adapter
   plus a const closure literal that can be passed as a value. *)
let emit_closure_wrapper (f : fn_decl) : string =
  let cstruct = closure_struct_name f.param_ty f.return_ty in
  let cret = c_type_of f.return_ty in
  let carg = c_type_of f.param_ty in
  let safe = c_safe_name f.name in
  (* Phase 36 (DEFERRED §1.19 fix): `_as_value` is declared `const` (no
     `static`) so the forward decl in `closure_wrapper_forward_decls` can
     link to it. The closure_fn helper stays `static`. *)
  Printf.sprintf
    "static %s %s_closure_fn(void* __env, %s %s) {\n  \
       (void)__env;\n  \
       return %s(%s);\n\
     }\n\
     const %s %s_as_value = {.env = NULL, .fn = %s_closure_fn};"
    cret safe carg f.param
    safe f.param
    cstruct safe safe

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
    (* Phase 23.5: escape special chars so show_str's output matches
       interp (which shows backslash-n as 2 literal chars, not a real
       newline). *)
    header ^ " { char* buf; asprintf(&buf, \"\\\"%s\\\"\", __lang_str_escape(v)); return buf; }"
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
          (* Phase 41: since alias_ctor also registers `Json.JNull`, the show
             fn iteration accepts only the canonical bare name to avoid duplicates. *)
          if info.type_name = name && Ast.canonical_ctor cname = cname
          then (cname, info.arg) :: acc
          else acc)
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

(* JSON sibling of emit_show_fn: emits `to_json_<tag>` producing JSON.
   Records drop their type name and become objects, lists/tuples become
   arrays, nullary ctors become "Name", ctors with a payload become
   {"Name": payload}. Mirrors emit_show_fn structurally; recursive calls go
   to to_json_<tag>. Kept in sync with eval.ml's to_json_string. *)
let emit_to_json_fn (tag : string) (t : Ast.ty) : string =
  let cty = c_type_of t in
  let header = Printf.sprintf "static const char* to_json_%s(%s v)" tag cty in
  match Ast.walk t with
  | Ast.TyInt ->
    header ^ " {\n  char* buf; asprintf(&buf, \"%d\", v); return buf;\n}"
  | Ast.TyBool ->
    header ^ " { return v ? \"true\" : \"false\"; }"
  | Ast.TyStr ->
    header ^ " { char* buf; asprintf(&buf, \"\\\"%s\\\"\", __lang_str_escape(v)); return buf; }"
  | Ast.TyUnit ->
    header ^ " { (void)v; return \"null\"; }"
  | Ast.TyArrow _ ->
    header ^ " { (void)v; return \"null\"; }"
  | Ast.TyTuple ts ->
    let parts =
      List.mapi (fun i et ->
        Printf.sprintf "to_json_%s(v.f%d)" (ty_tag et) i) ts
    in
    let fmt = "[" ^ String.concat "," (List.map (fun _ -> "%s") ts) ^ "]" in
    Printf.sprintf "%s {\n  char* buf; asprintf(&buf, \"%s\", %s); return buf;\n}"
      header fmt (String.concat ", " parts)
  | Ast.TyCon ("list", [elem_ty]) when Hashtbl.mem polymorphic_variants "list" ->
    let elem = "to_json_" ^ ty_tag (Ast.walk elem_ty) in
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
             asprintf(&__buf, \"%%s,%%s\", __acc, %s(__cur->payload.Cons.f0));\n  \
           }\n  \
           __acc = __buf;\n  \
           __cur = __cur->payload.Cons.f1;\n  \
           __first = 0;\n  \
         }\n  \
         char* __buf; asprintf(&__buf, \"%%s]\", __acc); return __buf;\n\
       }"
      header cty elem elem
  | Ast.TyCon ("option", [inner]) ->
    (* option is a transparent JSON nullable: None -> null, Some x -> x.
       Matches the interpreter and keeps of_json round-trip. *)
    let is_ptr = is_recursive_variant cty in
    let dot = if is_ptr then "->" else "." in
    let none_tag = try Hashtbl.find variant_tags "None" with Not_found -> 0 in
    Printf.sprintf
      "%s {\n  if (v%stag == %d) return \"null\";\n  return to_json_%s(v%spayload.Some);\n}"
      header dot none_tag (ty_tag (Ast.walk inner)) dot
  | Ast.TyCon (name, _) when Hashtbl.mem Typer.records name ->
    let info = Hashtbl.find Typer.records name in
    let fields_parts =
      List.map (fun (fname, ft) ->
        Printf.sprintf "to_json_%s(v.%s)" (ty_tag ft) fname)
        info.Typer.r_fields
    in
    let fmt =
      "{" ^
      String.concat ","
        (List.map (fun (fname, _) -> "\\\"" ^ fname ^ "\\\":%s") info.Typer.r_fields) ^
      "}"
    in
    Printf.sprintf "%s {\n  char* buf; asprintf(&buf, \"%s\", %s); return buf;\n}"
      header fmt (String.concat ", " fields_parts)
  | Ast.TyCon (name, args) ->
    let variants =
      if Hashtbl.mem polymorphic_variants name then
        let (params, vs) = Hashtbl.find polymorphic_variants name in
        subst_variants params args vs
      else
        Hashtbl.fold (fun cname (info : Typer.constr_info) acc ->
          if info.type_name = name && Ast.canonical_ctor cname = cname
          then (cname, info.arg) :: acc
          else acc)
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
          Printf.sprintf "  if (v%stag == %d) return \"\\\"%s\\\"\";"
            dot tag_n cname
        | Some ty ->
          Printf.sprintf
            "  if (v%stag == %d) { char* buf; asprintf(&buf, \"{\\\"%s\\\":%%s}\", to_json_%s(v%spayload.%s)); return buf; }"
            dot tag_n cname (ty_tag ty) dot cname)
        variants
    in
    Printf.sprintf "%s {\n%s\n  return \"null\";\n}"
      header (String.concat "\n" cases)
  | _ ->
    Printf.sprintf "%s { (void)v; return \"null\"; }" header

let emit_to_json_fn_forward_decl (tag : string) (t : Ast.ty) : string =
  Printf.sprintf "static const char* to_json_%s(%s);" tag (c_type_of t)

(* ===== of_json: the deserialization mirror =====
   A tiny JSON parser builds a generic mj_node tree; per-type __ojnode_<tag>
   decoders walk it into the target C value, and the public of_json_<tag>
   entry parses then decodes. Emitted only when the program uses of_json
   (of_json_types non-empty). *)
let of_json_runtime : string = {ojson|
typedef enum { MJ_NULL, MJ_BOOL, MJ_NUM, MJ_STR, MJ_ARR, MJ_OBJ } mj_kind;
typedef struct mj_node {
  mj_kind kind;
  int b;                    /* MJ_BOOL */
  const char* text;         /* MJ_STR (unescaped) or MJ_NUM (raw lexeme) */
  struct mj_node** items;   /* MJ_ARR elements / MJ_OBJ values */
  const char** keys;        /* MJ_OBJ keys */
  int len;
} mj_node;
/* of_json fails fast (exit); of_json_opt installs a longjmp handler so a
   parse/shape error unwinds to a `return None` instead of crashing. */
static jmp_buf __mj_jb;
static int __mj_active = 0;
static void __mj_die(const char* msg) {
  if (__mj_active) longjmp(__mj_jb, 1);
  fprintf(stderr, "of_json: %s\n", msg); exit(1);
}
static mj_node* __mj_alloc(mj_kind k) {
  mj_node* n = (mj_node*)calloc(1, sizeof(mj_node)); n->kind = k; return n; }
typedef struct { const char* s; int pos; int n; } __mj_ps;
static void __mj_ws(__mj_ps* p) {
  while (p->pos < p->n) { char c = p->s[p->pos];
    if (c==' '||c=='\t'||c=='\n'||c=='\r') p->pos++; else break; } }
static char* __mj_pstr(__mj_ps* p) {
  p->pos++; /* opening quote */
  size_t cap = 16, len = 0; char* buf = (char*)malloc(cap);
  while (p->pos < p->n) {
    char c = p->s[p->pos];
    if (c == '"') { p->pos++; buf[len] = 0; return buf; }
    if (c == '\\' && p->pos + 1 < p->n) {
      p->pos++; char e = p->s[p->pos]; char out = e;
      if (e=='n') out='\n'; else if (e=='t') out='\t'; else if (e=='r') out='\r';
      else if (e=='b') out='\b'; else if (e=='f') out='\f';
      if (len+1 >= cap) { cap*=2; buf=(char*)realloc(buf,cap); }
      buf[len++] = out; p->pos++;
    } else {
      if (len+1 >= cap) { cap*=2; buf=(char*)realloc(buf,cap); }
      buf[len++] = c; p->pos++;
    }
  }
  __mj_die("unterminated string"); return 0;
}
static mj_node* __mj_val(__mj_ps* p);
static mj_node* __mj_arr(__mj_ps* p) {
  p->pos++; __mj_ws(p);
  mj_node* node = __mj_alloc(MJ_ARR);
  size_t cap = 8; node->items = (mj_node**)malloc(cap*sizeof(mj_node*));
  if (p->pos < p->n && p->s[p->pos]==']') { p->pos++; return node; }
  for (;;) {
    mj_node* v = __mj_val(p);
    if ((size_t)node->len >= cap) { cap*=2; node->items=(mj_node**)realloc(node->items,cap*sizeof(mj_node*)); }
    node->items[node->len++] = v; __mj_ws(p);
    if (p->pos<p->n && p->s[p->pos]==',') { p->pos++; __mj_ws(p); continue; }
    if (p->pos<p->n && p->s[p->pos]==']') { p->pos++; break; }
    __mj_die("expected ',' or ']' in array");
  }
  return node;
}
static mj_node* __mj_obj(__mj_ps* p) {
  p->pos++; __mj_ws(p);
  mj_node* node = __mj_alloc(MJ_OBJ);
  size_t cap = 8;
  node->items = (mj_node**)malloc(cap*sizeof(mj_node*));
  node->keys = (const char**)malloc(cap*sizeof(char*));
  if (p->pos<p->n && p->s[p->pos]=='}') { p->pos++; return node; }
  for (;;) {
    __mj_ws(p);
    if (!(p->pos<p->n && p->s[p->pos]=='"')) __mj_die("expected object key");
    char* k = __mj_pstr(p); __mj_ws(p);
    if (!(p->pos<p->n && p->s[p->pos]==':')) __mj_die("expected ':'");
    p->pos++;
    mj_node* v = __mj_val(p);
    if ((size_t)node->len >= cap) { cap*=2;
      node->items=(mj_node**)realloc(node->items,cap*sizeof(mj_node*));
      node->keys=(const char**)realloc(node->keys,cap*sizeof(char*)); }
    node->keys[node->len] = k; node->items[node->len] = v; node->len++; __mj_ws(p);
    if (p->pos<p->n && p->s[p->pos]==',') { p->pos++; continue; }
    if (p->pos<p->n && p->s[p->pos]=='}') { p->pos++; break; }
    __mj_die("expected ',' or '}' in object");
  }
  return node;
}
static mj_node* __mj_val(__mj_ps* p) {
  __mj_ws(p);
  if (p->pos >= p->n) __mj_die("unexpected end of input");
  char c = p->s[p->pos];
  if (c=='{') return __mj_obj(p);
  if (c=='[') return __mj_arr(p);
  if (c=='"') { mj_node* n = __mj_alloc(MJ_STR); n->text = __mj_pstr(p); return n; }
  if (c=='t') { if (p->pos+4<=p->n && strncmp(p->s+p->pos,"true",4)==0) { p->pos+=4; mj_node* n=__mj_alloc(MJ_BOOL); n->b=1; return n; } __mj_die("expected true"); }
  if (c=='f') { if (p->pos+5<=p->n && strncmp(p->s+p->pos,"false",5)==0) { p->pos+=5; mj_node* n=__mj_alloc(MJ_BOOL); n->b=0; return n; } __mj_die("expected false"); }
  if (c=='n') { if (p->pos+4<=p->n && strncmp(p->s+p->pos,"null",4)==0) { p->pos+=4; return __mj_alloc(MJ_NULL); } __mj_die("expected null"); }
  if (c=='-' || (c>='0'&&c<='9')) {
    int start = p->pos; if (c=='-') p->pos++;
    while (p->pos<p->n) { char d=p->s[p->pos];
      if ((d>='0'&&d<='9')||d=='.'||d=='e'||d=='E'||d=='+'||d=='-') p->pos++; else break; }
    int len = p->pos-start; char* t=(char*)malloc(len+1); memcpy(t,p->s+start,len); t[len]=0;
    mj_node* n=__mj_alloc(MJ_NUM); n->text=t; return n;
  }
  __mj_die("unexpected character"); return 0;
}
static mj_node* __mj_parse(const char* s) {
  __mj_ps p; p.s=s; p.pos=0; p.n=(int)strlen(s);
  mj_node* v=__mj_val(&p); __mj_ws(&p); return v;
}
static mj_node* __mj_field(mj_node* o, const char* key) {
  if (o->kind != MJ_OBJ) __mj_die("expected a JSON object");
  for (int i=0;i<o->len;i++) if (strcmp(o->keys[i],key)==0) return o->items[i];
  __mj_die("missing object field"); return 0;
}
|ojson}

(* Emit both the node decoder `__ojnode_<tag>` and the string entry
   `of_json_<tag>` for one target type. *)
let emit_of_json_fn (tag : string) (t : Ast.ty) : string =
  let cty = c_type_of t in
  (* Recursive variants (e.g. list) are a typedef aliasing a node pointer, so
     the pointer-ness is hidden — detect via recursive_variants (keyed by the
     mono type name, which equals cty here), not a trailing '*'. *)
  let is_ptr = is_recursive_variant cty in
  let node_hdr = Printf.sprintf "static %s __ojnode_%s(mj_node* j)" cty tag in
  (* construct a constructor value (recursive -> heap node; else compound). *)
  let construct cname tag_n arg_c_opt =
    if is_ptr then
      let node = cty ^ "_node" in
      Printf.sprintf
        "({ %s* __p = (%s*)__lang_region_alloc(&__lang_default_region, sizeof(%s)); __p->tag = %d%s; __p; })"
        node node node tag_n
        (match arg_c_opt with None -> "" | Some a -> "; __p->payload." ^ cname ^ " = " ^ a)
    else
      Printf.sprintf "((%s){.tag = %d%s})" cty tag_n
        (match arg_c_opt with None -> "" | Some a -> ", .payload." ^ cname ^ " = " ^ a)
  in
  let body =
    match Ast.walk t with
    | Ast.TyInt -> "  return (int)strtol(j->text, 0, 10);"
    | Ast.TyBool -> "  return j->b;"
    | Ast.TyStr -> "  return j->text;"
    | Ast.TyFloat -> "  return strtod(j->text, 0);"
    | Ast.TyUnit -> "  (void)j; return 0;"
    | Ast.TyArrow _ -> "  (void)j; __mj_die(\"cannot decode a function\"); return 0;"
    | Ast.TyTuple ts ->
      let inits =
        List.mapi (fun i et ->
          Printf.sprintf ".f%d = __ojnode_%s(j->items[%d])" i (ty_tag (Ast.walk et)) i) ts
      in
      Printf.sprintf
        "  if (j->kind != MJ_ARR || j->len != %d) __mj_die(\"expected a %d-element array\");\n  return ((%s){%s});"
        (List.length ts) (List.length ts) cty (String.concat ", " inits)
    | Ast.TyCon ("list", [elem]) ->
      let elem_tag = ty_tag (Ast.walk elem) in
      let nil_tag = try Hashtbl.find variant_tags "Nil" with Not_found -> 0 in
      let cons_tag = try Hashtbl.find variant_tags "Cons" with Not_found -> 1 in
      let node = cty ^ "_node" in
      Printf.sprintf
        "  if (j->kind != MJ_ARR) __mj_die(\"expected a JSON array\");\n  \
         %s __acc = ({ %s* __nil = (%s*)__lang_region_alloc(&__lang_default_region, sizeof(%s)); __nil->tag = %d; __nil; });\n  \
         for (int __i = j->len - 1; __i >= 0; __i--) {\n    \
           %s* __n = (%s*)__lang_region_alloc(&__lang_default_region, sizeof(%s));\n    \
           __n->tag = %d;\n    \
           __n->payload.Cons.f0 = __ojnode_%s(j->items[__i]);\n    \
           __n->payload.Cons.f1 = __acc;\n    \
           __acc = __n;\n  }\n  return __acc;"
        cty node node node nil_tag node node node cons_tag elem_tag
    | Ast.TyCon ("option", [inner]) ->
      let inner_tag = ty_tag (Ast.walk inner) in
      let none_tag = try Hashtbl.find variant_tags "None" with Not_found -> 0 in
      let some_tag = try Hashtbl.find variant_tags "Some" with Not_found -> 1 in
      Printf.sprintf
        "  if (j->kind == MJ_NULL) return %s;\n  return %s;"
        (construct "None" none_tag None)
        (construct "Some" some_tag (Some (Printf.sprintf "__ojnode_%s(j)" inner_tag)))
    | Ast.TyCon (name, _) when Hashtbl.mem Typer.records name ->
      let info = Hashtbl.find Typer.records name in
      let inits =
        List.map (fun (fname, ft) ->
          Printf.sprintf ".%s = __ojnode_%s(__mj_field(j, \"%s\"))"
            fname (ty_tag (Ast.walk ft)) fname)
          info.Typer.r_fields
      in
      Printf.sprintf "  return ((%s){%s});" cty (String.concat ", " inits)
    | Ast.TyCon (name, args) ->
      (* general variant: JSON string -> nullary ctor; {"Ctor":payload} -> Ctor payload *)
      let variants =
        if Hashtbl.mem polymorphic_variants name then
          let (params, vs) = Hashtbl.find polymorphic_variants name in
          subst_variants params args vs
        else
          Hashtbl.fold (fun cname (info : Typer.constr_info) acc ->
            if info.type_name = name && Ast.canonical_ctor cname = cname
            then (cname, info.arg) :: acc else acc)
            Typer.constructors []
      in
      let nullary_cases =
        List.filter_map (fun (cname, arg_opt) ->
          let tag_n = try Hashtbl.find variant_tags cname with Not_found -> 0 in
          match arg_opt with
          | None ->
            Some (Printf.sprintf
              "    if (strcmp(j->text, \"%s\") == 0) return %s;"
              cname (construct cname tag_n None))
          | Some _ -> None) variants
      in
      let payload_cases =
        List.filter_map (fun (cname, arg_opt) ->
          let tag_n = try Hashtbl.find variant_tags cname with Not_found -> 0 in
          match arg_opt with
          | Some ty ->
            Some (Printf.sprintf
              "    if (strcmp(__k, \"%s\") == 0) return %s;"
              cname
              (construct cname tag_n
                 (Some (Printf.sprintf "__ojnode_%s(__v)" (ty_tag (Ast.walk ty))))))
          | None -> None) variants
      in
      Printf.sprintf
        "  if (j->kind == MJ_STR) {\n%s\n  }\n  \
         if (j->kind == MJ_OBJ && j->len == 1) {\n    \
           const char* __k = j->keys[0]; mj_node* __v = j->items[0];\n%s\n  }\n  \
         __mj_die(\"cannot decode variant %s\"); return %s;"
        (String.concat "\n" nullary_cases)
        (String.concat "\n" payload_cases)
        name
        (if is_ptr then "0" else Printf.sprintf "((%s){0})" cty)
    | _ ->
      Printf.sprintf "  (void)j; __mj_die(\"unsupported of_json target\"); return %s;"
        (if is_ptr then "0" else Printf.sprintf "((%s){0})" cty)
  in
  Printf.sprintf
    "%s {\n%s\n}\nstatic %s of_json_%s(const char* __s) { return __ojnode_%s(__mj_parse(__s)); }"
    node_hdr body cty tag tag

let emit_of_json_fn_forward_decl (tag : string) (t : Ast.ty) : string =
  let cty = c_type_of t in
  Printf.sprintf "static %s __ojnode_%s(mj_node*); static %s of_json_%s(const char*);"
    cty tag cty tag

(* of_json_opt_<inner_tag>: decode `inner` and wrap in Some, returning None on
   any error (via the runtime longjmp handler). `inner_t` is the inner type T;
   the function returns `T option`. *)
let emit_of_json_opt_fn (inner_tag : string) (inner_t : Ast.ty) : string =
  let opt_ty = Ast.TyCon ("option", [inner_t]) in
  let opt_cty = c_type_of opt_ty in
  let none_tag = try Hashtbl.find variant_tags "None" with Not_found -> 0 in
  let some_tag = try Hashtbl.find variant_tags "Some" with Not_found -> 1 in
  let none_v = Printf.sprintf "((%s){.tag = %d})" opt_cty none_tag in
  Printf.sprintf
    "static %s of_json_opt_%s(const char* __s) {\n  \
       volatile int __saved = __mj_active; __mj_active = 1;\n  \
       if (setjmp(__mj_jb)) { __mj_active = __saved; return %s; }\n  \
       %s __v = ((%s){.tag = %d, .payload.Some = __ojnode_%s(__mj_parse(__s))});\n  \
       __mj_active = __saved; return __v;\n}"
    opt_cty inner_tag none_v opt_cty opt_cty some_tag inner_tag

let emit_of_json_opt_fn_forward_decl (inner_tag : string) (inner_t : Ast.ty) : string =
  let opt_cty = c_type_of (Ast.TyCon ("option", [inner_t])) in
  Printf.sprintf "static %s of_json_opt_%s(const char*);" opt_cty inner_tag

(* Structural equality for compound types (tuple / record / variant). C
   can't `==` a struct, so `a == b` on such a value lowers to eq_<tag>(a, b)
   (see the Cmp handler). Recurses field/element/payload-wise, matching the
   interpreter's value_eq. The derive-style sibling of show / to_json. *)
let emit_eq_fn (tag : string) (t : Ast.ty) : string =
  let cty = c_type_of t in
  let header = Printf.sprintf "static int eq_%s(%s a, %s b)" tag cty cty in
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool -> header ^ " { return a == b; }"
  | Ast.TyStr -> header ^ " { return strcmp(a, b) == 0; }"
  | Ast.TyUnit -> header ^ " { (void)a; (void)b; return 1; }"
  | Ast.TyArrow _ -> header ^ " { (void)a; (void)b; return 0; }"
  | Ast.TyTuple ts ->
    let conds =
      List.mapi (fun i et ->
        Printf.sprintf "eq_%s(a.f%d, b.f%d)" (ty_tag et) i i) ts in
    Printf.sprintf "%s { return %s; }"
      header (if conds = [] then "1" else String.concat " && " conds)
  | Ast.TyCon (name, _) when Hashtbl.mem Typer.records name ->
    let info = Hashtbl.find Typer.records name in
    let conds =
      List.map (fun (fname, ft) ->
        Printf.sprintf "eq_%s(a.%s, b.%s)" (ty_tag ft) fname fname)
        info.Typer.r_fields in
    Printf.sprintf "%s { return %s; }"
      header (if conds = [] then "1" else String.concat " && " conds)
  | Ast.TyCon (name, args) ->
    let variants =
      if Hashtbl.mem polymorphic_variants name then
        let (params, vs) = Hashtbl.find polymorphic_variants name in
        subst_variants params args vs
      else
        Hashtbl.fold (fun cname (info : Typer.constr_info) acc ->
          if info.type_name = name && Ast.canonical_ctor cname = cname
          then (cname, info.arg) :: acc else acc)
          Typer.constructors []
    in
    let is_ptr = is_recursive_variant cty in
    let dot = if is_ptr then "->" else "." in
    let cases =
      List.filter_map (fun (cname, arg_opt) ->
        match arg_opt with
        | None -> None
        | Some ty ->
          let tag_n = try Hashtbl.find variant_tags cname with Not_found -> 0 in
          Some (Printf.sprintf
            "  if (a%stag == %d) return eq_%s(a%spayload.%s, b%spayload.%s);"
            dot tag_n (ty_tag ty) dot cname dot cname))
        variants
    in
    Printf.sprintf "%s {\n  if (a%stag != b%stag) return 0;\n%s\n  return 1;\n}"
      header dot dot (String.concat "\n" cases)
  | _ -> header ^ " { (void)a; (void)b; return 0; }"

let emit_eq_fn_forward_decl (tag : string) (t : Ast.ty) : string =
  Printf.sprintf "static int eq_%s(%s, %s);" tag (c_type_of t) (c_type_of t)

(* v0.1.11 derive-ord: structural compare returning <0/0/>0, the ordering
   sibling of emit_eq_fn. Lexicographic: tuple by component order, record by
   declared field order, variant by tag (declaration order) then payload —
   matching the interpreter's value_compare so all backends agree. *)
let emit_cmp_fn (tag : string) (t : Ast.ty) : string =
  let cty = c_type_of t in
  let header = Printf.sprintf "static int cmp_%s(%s a, %s b)" tag cty cty in
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool ->
    header ^ " { return (a > b) - (a < b); }"
  | Ast.TyFloat ->
    header ^ " { return (a > b) - (a < b); }"
  | Ast.TyStr -> header ^ " { return strcmp(a, b); }"
  | Ast.TyUnit -> header ^ " { (void)a; (void)b; return 0; }"
  | Ast.TyArrow _ -> header ^ " { (void)a; (void)b; return 0; }"
  | Ast.TyTuple ts ->
    let steps =
      List.mapi (fun i et ->
        Printf.sprintf "  c = cmp_%s(a.f%d, b.f%d); if (c) return c;"
          (ty_tag et) i i) ts in
    Printf.sprintf "%s {\n  int c;\n%s\n  return 0;\n}"
      header (String.concat "\n" steps)
  | Ast.TyCon (name, _) when Hashtbl.mem Typer.records name ->
    let info = Hashtbl.find Typer.records name in
    let steps =
      List.map (fun (fname, ft) ->
        Printf.sprintf "  c = cmp_%s(a.%s, b.%s); if (c) return c;"
          (ty_tag ft) fname fname)
        info.Typer.r_fields in
    Printf.sprintf "%s {\n  int c;\n%s\n  return 0;\n}"
      header (String.concat "\n" steps)
  | Ast.TyCon (name, args) ->
    let variants =
      if Hashtbl.mem polymorphic_variants name then
        let (params, vs) = Hashtbl.find polymorphic_variants name in
        subst_variants params args vs
      else
        Hashtbl.fold (fun cname (info : Typer.constr_info) acc ->
          if info.type_name = name && Ast.canonical_ctor cname = cname
          then (cname, info.arg) :: acc else acc)
          Typer.constructors []
    in
    let is_ptr = is_recursive_variant cty in
    let dot = if is_ptr then "->" else "." in
    let cases =
      List.filter_map (fun (cname, arg_opt) ->
        match arg_opt with
        | None -> None
        | Some ty ->
          let tag_n = try Hashtbl.find variant_tags cname with Not_found -> 0 in
          Some (Printf.sprintf
            "  if (a%stag == %d) return cmp_%s(a%spayload.%s, b%spayload.%s);"
            dot tag_n (ty_tag ty) dot cname dot cname))
        variants
    in
    Printf.sprintf
      "%s {\n  if (a%stag != b%stag) return (a%stag > b%stag) - (a%stag < b%stag);\n%s\n  return 0;\n}"
      header dot dot dot dot dot dot (String.concat "\n" cases)
  | _ -> header ^ " { (void)a; (void)b; return 0; }"

let emit_cmp_fn_forward_decl (tag : string) (t : Ast.ty) : string =
  Printf.sprintf "static int cmp_%s(%s, %s);" tag (c_type_of t) (c_type_of t)

let emit_closure_adapter_forward_decl (ce : closure_emission) : string =
  Printf.sprintf "static %s %s(void*, %s);"
    (c_type_of ce.ce_return_ty) ce.ce_adapter_name
    (c_type_of ce.ce_param_ty)

(* Render an anonymous-closure adapter, emitting its body with the
   capture-name → env-pointer substitution map. *)
let emit_closure_adapter (ce : closure_emission) : string =
  (* Phase 22.5: switch inner_lifts to the host scope that was active
     when this closure was queued, so any Let_rec inside the closure
     body finds its inner-lifted siblings. *)
  set_inner_lifts_for_host ce.ce_host;
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
(* Native FFI runtime (Stage 1 of the native full-stack arc).

   contrib/db (pg / mysql / redis) and other wire-protocol code are written
   against a Wasm-style flat byte memory: addresses are 32-bit `int`
   offsets, and the `mem_*` / `str_ptr` / `tcp_*` externs are provided by
   the Node host over the Wasm linear memory. On the native (C) backend
   there is no such shared linear memory, and a Mere `int` is 32-bit — too
   narrow for a real 64-bit pointer. So we give the native runtime its own
   flat arena (`__mem`, addressed by 32-bit offsets, exactly like Wasm's
   memory) and implement the same extern set against it with POSIX sockets.
   Same Mere source then runs on both "Wasm + Node host" and native.

   These names, when declared `extern fn` and used, get a `static`
   definition emitted here instead of an `extern` prototype — so
   `mere -c app.mere | clang` yields a self-contained native binary. *)
let native_ffi_names =
  [ "tcp_connect"; "tcp_listen"; "tcp_accept";
    "tcp_write"; "tcp_read"; "tcp_close"; "tcp_set_timeout";
    "str_ptr"; "mem_alloc"; "mem_set_u8"; "mem_get_u8";
    "mem_set_u32be"; "mem_get_u32be"; "mem_set_u16be"; "mem_get_u16be";
    "mem_copy_str"; "mem_to_str"; "bytes_from_hex_alloc"; "bytes_to_hex_len" ]

(* TLS externs. Not implemented natively yet (needs libssl FFI). Stubbed so
   a native build LINKS and plaintext connections work; referenced by the
   STARTTLS path but not called unless a program requests SSL. *)
let native_ffi_stub_names =
  [ "tcp_starttls"; "tcp_starttls_verified" ]

(* Native HTTP server externs (Stage 3). Implemented in native_http_runtime,
   emitted after the closure typedefs (http_serve takes a `str -> str`
   closure = the `closure_str_str` struct). Single-threaded accept loop;
   response metadata is per-request global state. *)
let native_http_names =
  [ "http_serve"; "http_current_body"; "http_set_status";
    "http_set_content_type"; "http_set_header"; "http_get_header" ]

(* Native utility + crypto externs with real implementations: SHA-256 and
   friends (password hashing, and the SCRAM-SHA-256 handshake contrib/db/pg
   needs for password auth) plus a random request/session id. The Node host
   provides these via crypto glue; here they get real native impls, so
   native pg can authenticate to a password Postgres over plaintext (TLS is
   still stubbed). Binary crosses the FFI boundary as hex strings (Mere str
   is NUL-terminated), matching the Node contract. *)
let native_util_names =
  [ "sha256_hex"; "gen_request_id";
    "sha256_of_hex"; "hmac_sha256_hex_str"; "pbkdf2_sha256_hex";
    "base64_encode_hex"; "base64_decode_to_hex"; "random_b64"; "hex_xor" ]

let is_native_ffi name =
  List.mem name native_ffi_names
  || List.mem name native_ffi_stub_names
  || List.mem name native_http_names
  || List.mem name native_util_names

let native_http_runtime =
  String.concat "\n"
    [ "/* --- native HTTP server (Stage 3): single-threaded accept loop, ";
      "   per-request response state. Same extern contract as the Node host: ";
      "   the handler gets \"METHOD URL\", sets status/content-type/headers via ";
      "   the http_set_* externs, and returns the response body. --- */";
      "#include <arpa/inet.h>";
      "static int  __http_status = 200;";
      "static char __http_ctype[256] = \"text/plain\";";
      "static char __http_extra_hdrs[8192]; static int __http_extra_len = 0;";
      "static char __http_req_body[1 << 20]; static int __http_req_body_len = 0;";
      "static char __http_req_head[16384]; static int __http_req_head_len = 0;";
      "";
      "static char* http_current_body(void) { return __http_req_body; }";
      "static int http_set_status(int c) { __http_status = c; return 0; }";
      "static int http_set_content_type(const char* ct) {";
      "  strncpy(__http_ctype, ct, sizeof __http_ctype - 1);";
      "  __http_ctype[sizeof __http_ctype - 1] = 0; return 0;";
      "}";
      "static int http_set_header(const char* k, const char* v) {";
      "  int r = snprintf(__http_extra_hdrs + __http_extra_len,";
      "                   sizeof __http_extra_hdrs - __http_extra_len,";
      "                   \"%s: %s\\r\\n\", k, v);";
      "  if (r > 0) __http_extra_len += r; return 0;";
      "}";
      "/* case-insensitive lookup of a request header value (\"\" if absent). */";
      "static char* http_get_header(const char* name) {";
      "  static char val[4096];";
      "  int nl = (int)strlen(name);";
      "  const char* p = __http_req_head;";
      "  while (*p) {";
      "    const char* line = p;";
      "    const char* eol = strstr(line, \"\\r\\n\");";
      "    int linelen = eol ? (int)(eol - line) : (int)strlen(line);";
      "    const char* colon = memchr(line, ':', linelen);";
      "    if (colon) {";
      "      int keylen = (int)(colon - line);";
      "      if (keylen == nl && strncasecmp(line, name, nl) == 0) {";
      "        const char* v = colon + 1;";
      "        while (*v == ' ' || *v == '\\t') v++;";
      "        int vlen = eol ? (int)(eol - v) : (int)strlen(v);";
      "        if (vlen > (int)sizeof val - 1) vlen = sizeof val - 1;";
      "        memcpy(val, v, vlen); val[vlen] = 0; return val;";
      "      }";
      "    }";
      "    if (!eol) break; p = eol + 2;";
      "  }";
      "  val[0] = 0; return val;";
      "}";
      "";
      "static int http_serve(int port, closure_str_str handler) {";
      "  int srv = socket(AF_INET, SOCK_STREAM, 0);";
      "  int one = 1; setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);";
      "  struct sockaddr_in addr; memset(&addr, 0, sizeof addr);";
      "  addr.sin_family = AF_INET; addr.sin_addr.s_addr = INADDR_ANY;";
      "  addr.sin_port = htons((unsigned short)port);";
      "  if (bind(srv, (struct sockaddr*)&addr, sizeof addr) != 0) { perror(\"bind\"); return -1; }";
      "  listen(srv, 64);";
      "  fprintf(stderr, \"native http: listening on :%d\\n\", port);";
      "  static char buf[1 << 20];";
      "  for (;;) {";
      "    int c = accept(srv, 0, 0);";
      "    if (c < 0) continue;";
      "    int n = 0, hdr_end = -1;";
      "    while (n < (int)sizeof buf - 1) {";
      "      int r = (int)read(c, buf + n, sizeof buf - 1 - n);";
      "      if (r <= 0) break; n += r; buf[n] = 0;";
      "      char* e = strstr(buf, \"\\r\\n\\r\\n\");";
      "      if (e) { hdr_end = (int)(e - buf) + 4; break; }";
      "    }";
      "    if (hdr_end < 0) { close(c); continue; }";
      "    /* request head (request line + headers) for http_get_header */";
      "    __http_req_head_len = hdr_end < (int)sizeof __http_req_head - 1 ? hdr_end : (int)sizeof __http_req_head - 1;";
      "    memcpy(__http_req_head, buf, __http_req_head_len); __http_req_head[__http_req_head_len] = 0;";
      "    /* Content-Length → read the rest of the body */";
      "    int clen = 0;";
      "    { char* cl = __http_req_head;";
      "      while (*cl) { if (strncasecmp(cl, \"content-length:\", 15) == 0) { clen = atoi(cl + 15); break; }";
      "                    char* e2 = strstr(cl, \"\\r\\n\"); if (!e2) break; cl = e2 + 2; } }";
      "    while (n - hdr_end < clen && n < (int)sizeof buf - 1) {";
      "      int r = (int)read(c, buf + n, sizeof buf - 1 - n); if (r <= 0) break; n += r;";
      "    }";
      "    __http_req_body_len = n - hdr_end;";
      "    if (__http_req_body_len > (int)sizeof __http_req_body - 1) __http_req_body_len = sizeof __http_req_body - 1;";
      "    memcpy(__http_req_body, buf + hdr_end, __http_req_body_len); __http_req_body[__http_req_body_len] = 0;";
      "    /* build \"METHOD URL\" from the request line */";
      "    static char reqline[8192]; int sp1 = -1, sp2 = -1;";
      "    for (int i = 0; i < hdr_end && buf[i] != '\\r'; i++) {";
      "      if (buf[i] == ' ') { if (sp1 < 0) sp1 = i; else if (sp2 < 0) { sp2 = i; break; } }";
      "    }";
      "    int ml = sp2 > 0 ? sp2 : (sp1 > 0 ? sp1 : 0);";
      "    if (ml > (int)sizeof reqline - 1) ml = sizeof reqline - 1;";
      "    memcpy(reqline, buf, ml); reqline[ml] = 0;";
      "    /* reset per-request response state */";
      "    __http_status = 200; strcpy(__http_ctype, \"text/plain\");";
      "    __http_extra_len = 0; __http_extra_hdrs[0] = 0;";
      "    const char* body = handler.fn(handler.env, reqline);";
      "    if (!body) body = \"\";";
      "    char head[9216]; size_t blen = strlen(body);";
      "    int hn = snprintf(head, sizeof head,";
      "      \"HTTP/1.1 %d\\r\\nContent-Type: %s\\r\\nContent-Length: %zu\\r\\n%sConnection: close\\r\\n\\r\\n\",";
      "      __http_status, __http_ctype, blen, __http_extra_hdrs);";
      "    write(c, head, hn); write(c, body, blen); close(c);";
      "  }";
      "  return 0;";
      "}" ]

let native_ffi_runtime =
  String.concat "\n"
    [ "/* --- native FFI runtime: Wasm-style byte arena + POSIX TCP --- */";
      "#include <sys/socket.h>";
      "#include <netinet/in.h>";
      "#include <netdb.h>";
      "#include <sys/time.h>";
      "#include <stdint.h>";
      "#include <signal.h>";
      "";
      "#define __MEM_CAP (16 * 1024 * 1024)";
      "static unsigned char __mem[__MEM_CAP];";
      "static int __mem_top = 8;  /* leave low offsets as a null-ish guard */";
      "";
      "static int mem_alloc(int n) {";
      "  int p = __mem_top; __mem_top += (n <= 0 ? 1 : n); return p;";
      "}";
      "static int mem_set_u8(int p, int off, int b) { __mem[p + off] = (unsigned char)b; return 0; }";
      "static int mem_get_u8(int p, int off) { return __mem[p + off]; }";
      "static int mem_set_u32be(int p, int off, int v) {";
      "  unsigned char* q = __mem + p + off;";
      "  q[0] = (v >> 24) & 0xff; q[1] = (v >> 16) & 0xff;";
      "  q[2] = (v >> 8) & 0xff;  q[3] = v & 0xff; return 0;";
      "}";
      "static int mem_get_u32be(int p, int off) {";
      "  unsigned char* q = __mem + p + off;";
      "  return (q[0] << 24) | (q[1] << 16) | (q[2] << 8) | q[3];";
      "}";
      "static int mem_set_u16be(int p, int off, int v) {";
      "  unsigned char* q = __mem + p + off;";
      "  q[0] = (v >> 8) & 0xff; q[1] = v & 0xff; return 0;";
      "}";
      "static int mem_get_u16be(int p, int off) {";
      "  unsigned char* q = __mem + p + off;";
      "  return (q[0] << 8) | q[1];";
      "}";
      "/* str_ptr: place a Mere str's bytes in the arena, return the offset";
      "   (Wasm gets this for free since a str is already an offset there). */";
      "static int str_ptr(const char* s) {";
      "  int n = (int)strlen(s); int p = __mem_top;";
      "  memcpy(__mem + p, s, n); __mem[p + n] = 0; __mem_top += n + 1; return p;";
      "}";
      "/* mem_copy_str: copy a NUL-terminated str into __mem[dst+off], return len. */";
      "static int mem_copy_str(int dst, int off, const char* s) {";
      "  int d = dst + off; int i = 0;";
      "  while (s[i]) { __mem[d++] = (unsigned char)s[i++]; }";
      "  return d - dst;";
      "}";
      "/* mem_to_str: materialize len arena bytes as a fresh Mere str. */";
      "static char* mem_to_str(int p, int len) {";
      "  char* s = (char*)malloc(len + 1);";
      "  memcpy(s, __mem + p, len); s[len] = 0; return s;";
      "}";
      "";
      "static int tcp_connect(const char* host, int port) {";
      "  struct addrinfo hints, *res; char portstr[16];";
      "  memset(&hints, 0, sizeof hints);";
      "  hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;";
      "  snprintf(portstr, sizeof portstr, \"%d\", port);";
      "  if (getaddrinfo(host, portstr, &hints, &res) != 0) return -1;";
      "  int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);";
      "  if (fd < 0) { freeaddrinfo(res); return -1; }";
      "  if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) { close(fd); freeaddrinfo(res); return -1; }";
      "  freeaddrinfo(res); return fd;";
      "}";
      "/* tcp_listen: bind a TCP listener on `port` (all interfaces) and return";
      "   the listening fd, or -1 on failure. SO_REUSEADDR so a restart after";
      "   a crash does not hit TIME_WAIT. SIGPIPE ignored so a client that";
      "   disconnects mid-write kills the connection, not the whole server. */";
      "static int tcp_listen(int port) {";
      "  signal(SIGPIPE, SIG_IGN);";
      "  int srv = socket(AF_INET, SOCK_STREAM, 0);";
      "  if (srv < 0) return -1;";
      "  int one = 1; setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);";
      "  struct sockaddr_in addr; memset(&addr, 0, sizeof addr);";
      "  addr.sin_family = AF_INET; addr.sin_addr.s_addr = INADDR_ANY;";
      "  addr.sin_port = htons((unsigned short)port);";
      "  if (bind(srv, (struct sockaddr*)&addr, sizeof addr) != 0) { close(srv); return -1; }";
      "  if (listen(srv, 128) != 0) { close(srv); return -1; }";
      "  return srv;";
      "}";
      "/* tcp_accept: block until a client connects to the listening fd, and";
      "   return the connected client fd, or -1 on failure. */";
      "static int tcp_accept(int srv) { return (int)accept(srv, 0, 0); }";
      "static int tcp_write(int fd, int p, int len) { return (int)write(fd, __mem + p, (size_t)len); }";
      "static int tcp_read(int fd, int p, int cap) { return (int)read(fd, __mem + p, (size_t)cap); }";
      "static int tcp_close(int fd) { close(fd); return 0; }";
      "static int tcp_set_timeout(int fd, int ms) {";
      "  struct timeval tv; tv.tv_sec = ms / 1000; tv.tv_usec = (ms % 1000) * 1000;";
      "  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);";
      "  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);";
      "  return 0;";
      "}";
      "";
      "/* --- crypto: real SHA-256 core + HMAC-SHA256 + PBKDF2 + base64,";
      "   backing the SCRAM-SHA-256 handshake contrib/db/pg uses for password";
      "   auth. Binary crosses the FFI as hex strings. TLS (tcp_starttls) is";
      "   still stubbed (needs libssl); SCRAM works over a plaintext socket. */";
      "static void __sha256(const unsigned char* data, size_t len, unsigned char out[32]) {";
      "  static const uint32_t K[64] = {";
      "    0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,";
      "    0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,";
      "    0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,";
      "    0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,";
      "    0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,";
      "    0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,";
      "    0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,";
      "    0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u };";
      "  uint32_t h[8] = {0x6a09e667u,0xbb67ae85u,0x3c6ef372u,0xa54ff53au,0x510e527fu,0x9b05688cu,0x1f83d9abu,0x5be0cd19u};";
      "  size_t total = ((len + 8) / 64 + 1) * 64;";
      "  unsigned char* m = (unsigned char*)calloc(total, 1);";
      "  memcpy(m, data, len); m[len] = 0x80;";
      "  uint64_t bits = (uint64_t)len * 8;";
      "  for (int i = 0; i < 8; i++) m[total - 1 - i] = (unsigned char)(bits >> (8 * i));";
      "  for (size_t off = 0; off < total; off += 64) {";
      "    uint32_t w[64];";
      "    for (int i = 0; i < 16; i++)";
      "      w[i] = (m[off+i*4]<<24)|(m[off+i*4+1]<<16)|(m[off+i*4+2]<<8)|m[off+i*4+3];";
      "    for (int i = 16; i < 64; i++) {";
      "      uint32_t s0 = (w[i-15]>>7|w[i-15]<<25)^(w[i-15]>>18|w[i-15]<<14)^(w[i-15]>>3);";
      "      uint32_t s1 = (w[i-2]>>17|w[i-2]<<15)^(w[i-2]>>19|w[i-2]<<13)^(w[i-2]>>10);";
      "      w[i] = w[i-16] + s0 + w[i-7] + s1;";
      "    }";
      "    uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];";
      "    for (int i = 0; i < 64; i++) {";
      "      uint32_t S1=(e>>6|e<<26)^(e>>11|e<<21)^(e>>25|e<<7);";
      "      uint32_t ch=(e&f)^(~e&g);";
      "      uint32_t t1=hh+S1+ch+K[i]+w[i];";
      "      uint32_t S0=(a>>2|a<<30)^(a>>13|a<<19)^(a>>22|a<<10);";
      "      uint32_t maj=(a&b)^(a&c)^(b&c);";
      "      uint32_t t2=S0+maj;";
      "      hh=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;";
      "    }";
      "    h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=hh;";
      "  }";
      "  free(m);";
      "  for (int i = 0; i < 8; i++) {";
      "    out[i*4]=(h[i]>>24)&0xff; out[i*4+1]=(h[i]>>16)&0xff;";
      "    out[i*4+2]=(h[i]>>8)&0xff; out[i*4+3]=h[i]&0xff;";
      "  }";
      "}";
      "static const char __hexd[] = \"0123456789abcdef\";";
      "static char* __to_hex(const unsigned char* b, int n) {";
      "  char* s = (char*)malloc(n*2+1);";
      "  for (int i=0;i<n;i++){ s[i*2]=__hexd[b[i]>>4]; s[i*2+1]=__hexd[b[i]&15]; }";
      "  s[n*2]=0; return s;";
      "}";
      "static int __hexval(char c){ if(c>='0'&&c<='9')return c-'0'; if(c>='a'&&c<='f')return c-'a'+10; if(c>='A'&&c<='F')return c-'A'+10; return 0; }";
      "static int __from_hex(const char* s, unsigned char* out) {";
      "  int n=(int)strlen(s)/2; for(int i=0;i<n;i++) out[i]=(__hexval(s[i*2])<<4)|__hexval(s[i*2+1]); return n;";
      "}";
      "static const char __b64e[] = \"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/\";";
      "static char* __to_b64(const unsigned char* d, int n) {";
      "  int ol=((n+2)/3)*4; char* o=(char*)malloc(ol+1); int j=0;";
      "  for(int i=0;i<n;i+=3){ int v=d[i]<<16; if(i+1<n)v|=d[i+1]<<8; if(i+2<n)v|=d[i+2];";
      "    o[j++]=__b64e[(v>>18)&63]; o[j++]=__b64e[(v>>12)&63];";
      "    o[j++]=(i+1<n)?__b64e[(v>>6)&63]:'='; o[j++]=(i+2<n)?__b64e[v&63]:'='; }";
      "  o[ol]=0; return o;";
      "}";
      "static int __b64val(char c){ if(c>='A'&&c<='Z')return c-'A'; if(c>='a'&&c<='z')return c-'a'+26; if(c>='0'&&c<='9')return c-'0'+52; if(c=='+')return 62; if(c=='/')return 63; return -1; }";
      "static int __from_b64(const char* s, unsigned char* out) {";
      "  int n=0; unsigned int v=0; int bits=0;";
      "  for(int i=0;s[i];i++){ if(s[i]=='=')break; int c=__b64val(s[i]); if(c<0)continue;";
      "    v=(v<<6)|c; bits+=6; if(bits>=8){ bits-=8; out[n++]=(v>>bits)&0xff; } }";
      "  return n;";
      "}";
      "static void __hmac_sha256(const unsigned char* key, int klen, const unsigned char* msg, int mlen, unsigned char out[32]) {";
      "  unsigned char k[64]; memset(k,0,64);";
      "  if (klen>64) __sha256(key,klen,k); else memcpy(k,key,klen);";
      "  unsigned char ipad[64], opad[64];";
      "  for(int i=0;i<64;i++){ ipad[i]=k[i]^0x36; opad[i]=k[i]^0x5c; }";
      "  unsigned char inner[32]; unsigned char* buf=(unsigned char*)malloc(64+mlen);";
      "  memcpy(buf,ipad,64); memcpy(buf+64,msg,mlen); __sha256(buf,64+mlen,inner); free(buf);";
      "  unsigned char buf2[96]; memcpy(buf2,opad,64); memcpy(buf2+64,inner,32); __sha256(buf2,96,out);";
      "}";
      "/* --- the hex-boundary crypto externs contrib/db/pg's SCRAM path calls --- */";
      "static char* sha256_hex(const char* msg){ unsigned char d[32]; __sha256((const unsigned char*)msg, strlen(msg), d); return __to_hex(d,32); }";
      "static char* sha256_of_hex(const char* hex){ unsigned char* b=(unsigned char*)malloc(strlen(hex)/2+1); int n=__from_hex(hex,b); unsigned char d[32]; __sha256(b,n,d); free(b); return __to_hex(d,32); }";
      "static char* hmac_sha256_hex_str(const char* key_hex, const char* msg){ unsigned char* k=(unsigned char*)malloc(strlen(key_hex)/2+1); int kn=__from_hex(key_hex,k); unsigned char d[32]; __hmac_sha256(k,kn,(const unsigned char*)msg,(int)strlen(msg),d); free(k); return __to_hex(d,32); }";
      "static char* pbkdf2_sha256_hex(const char* pw, const char* salt_hex, int iters, int keylen){";
      "  unsigned char salt[512]; int slen=__from_hex(salt_hex,salt);";
      "  int pwlen=(int)strlen(pw); unsigned char* dk=(unsigned char*)malloc(keylen>0?keylen:1);";
      "  int done=0; unsigned int blk=1;";
      "  while(done<keylen){";
      "    unsigned char* sb=(unsigned char*)malloc(slen+4); memcpy(sb,salt,slen);";
      "    sb[slen]=(blk>>24)&0xff; sb[slen+1]=(blk>>16)&0xff; sb[slen+2]=(blk>>8)&0xff; sb[slen+3]=blk&0xff;";
      "    unsigned char u[32], t[32]; __hmac_sha256((const unsigned char*)pw,pwlen,sb,slen+4,u); free(sb); memcpy(t,u,32);";
      "    for(int i=1;i<iters;i++){ __hmac_sha256((const unsigned char*)pw,pwlen,u,32,u); for(int j=0;j<32;j++) t[j]^=u[j]; }";
      "    int take=(keylen-done<32)?(keylen-done):32; memcpy(dk+done,t,take); done+=take; blk++;";
      "  }";
      "  char* r=__to_hex(dk,keylen); free(dk); return r;";
      "}";
      "static char* base64_encode_hex(const char* hex){ unsigned char* b=(unsigned char*)malloc(strlen(hex)/2+1); int n=__from_hex(hex,b); char* r=__to_b64(b,n); free(b); return r; }";
      "static char* base64_decode_to_hex(const char* b64){ unsigned char* b=(unsigned char*)malloc(strlen(b64)+1); int n=__from_b64(b64,b); char* r=__to_hex(b,n); free(b); return r; }";
      "static char* random_b64(int n){ if(n<1)n=1; unsigned char* b=(unsigned char*)malloc(n); FILE* f=fopen(\"/dev/urandom\",\"rb\"); if(f){ size_t g=fread(b,1,n,f); (void)g; fclose(f);} else for(int i=0;i<n;i++) b[i]=rand()&0xff; char* r=__to_b64(b,n); free(b); return r; }";
      "static char* hex_xor(const char* a, const char* b){ int la=(int)strlen(a)/2, lb=(int)strlen(b)/2; if(la!=lb) return strdup(\"\"); unsigned char* ba=(unsigned char*)malloc(la?la:1); unsigned char* bb=(unsigned char*)malloc(lb?lb:1); __from_hex(a,ba); __from_hex(b,bb); for(int i=0;i<la;i++) ba[i]^=bb[i]; char* r=__to_hex(ba,la); free(ba); free(bb); return r; }";
      "static int tcp_starttls(int fd, const char* host){ (void)fd;(void)host; fprintf(stderr,\"native: tcp_starttls unsupported (TLS not implemented; use a plaintext connection)\\n\"); return -1; }";
      "static int tcp_starttls_verified(int fd, const char* h, const char* ca){ (void)fd;(void)h;(void)ca; fprintf(stderr,\"native: tcp_starttls_verified unsupported (TLS not implemented)\\n\"); return -1; }";
      "/* gen_request_id: 16 random bytes (from /dev/urandom) as a 32-char hex id. */";
      "static char* gen_request_id(void) {";
      "  unsigned char b[16]; FILE* f = fopen(\"/dev/urandom\", \"rb\");";
      "  if (f) { size_t got = fread(b, 1, 16, f); (void)got; fclose(f); }";
      "  else { for (int i = 0; i < 16; i++) b[i] = (unsigned char)(rand() & 0xff); }";
      "  char* id = (char*)malloc(33); static const char* hx = \"0123456789abcdef\";";
      "  for (int i = 0; i < 16; i++) { id[i*2] = hx[b[i]>>4]; id[i*2+1] = hx[b[i]&15]; }";
      "  id[32] = 0; return id;";
      "}";
      "/* arena <-> hex helpers (contrib/db/redis binary values). */";
      "static int bytes_from_hex_alloc(const char* hex){ int n=(int)strlen(hex)/2; int p=mem_alloc(n); __from_hex(hex, __mem + p); return p; }";
      "static char* bytes_to_hex_len(int p, int len){ return __to_hex(__mem + p, len); }" ]

let str_concat_helper =
  String.concat "\n"
    [ "static const char* __lang_str_concat(const char* a, const char* b) {";
      "  size_t la = strlen(a), lb = strlen(b);";
      "  char* r = (char*) __lang_region_alloc(&__lang_default_region, la + lb + 1);";
      "  memcpy(r, a, la);";
      "  memcpy(r + la, b, lb);";
      "  r[la + lb] = '\\0';";
      "  return r;";
      "}";
      "";
      (* Phase 19.1.1: str_index_of — return position of needle in
         haystack, -1 if not found. Empty needle returns 0. *)
      "static int __lang_str_index_of(const char* h, const char* n) {";
      "  if (n[0] == '\\0') return 0;";
      "  const char* p = strstr(h, n);";
      "  return p == NULL ? -1 : (int)(p - h);";
      "}";
      "";
      (* Phase 22.3: char-string helpers. In Mere a char is represented as a
         single-character str. A 256-entry static table holds a per-char
         pointer, and char_at returns the matching entry from the table.
         is_digit / is_alpha / is_space classify the first byte via ctype.h. *)
      "static char __lang_char_table[256][2];";
      "static int __lang_char_table_init = 0;";
      "static void __lang_char_table_setup(void) {";
      "  if (__lang_char_table_init) return;";
      "  for (int k = 0; k < 256; k++) {";
      "    __lang_char_table[k][0] = (char)k;";
      "    __lang_char_table[k][1] = '\\0';";
      "  }";
      "  __lang_char_table_init = 1;";
      "}";
      "static const char* __lang_char_at(const char* s, int i) {";
      "  __lang_char_table_setup();";
      "  return __lang_char_table[(unsigned char)s[i]];";
      "}";
      "static int __lang_is_digit(const char* s) {";
      "  unsigned char c = (unsigned char)s[0];";
      "  return c >= '0' && c <= '9';";
      "}";
      "static int __lang_is_alpha(const char* s) {";
      "  unsigned char c = (unsigned char)s[0];";
      "  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');";
      "}";
      "static int __lang_is_space(const char* s) {";
      "  unsigned char c = (unsigned char)s[0];";
      "  return c == ' ' || c == '\\t' || c == '\\n' || c == '\\r';";
      "}";
      "";
      (* Phase 22.4: fail builtin — print to stderr + abort. The noreturn
         attribute tells the C compiler this is unreachable, but each call
         site still needs to be wrapped as a (void expr) followed by a
         default value matching the expected return type. We provide a
         static helper that returns int (= 0) and let the call site cast as
         needed. When combined with show-style helpers we need to return a
         str, so we provide two variants (__lang_fail_int / __lang_fail_str)
         depending on the return type. *)
      "static int __lang_fail_jmpbuf_set = 0;";
      "static jmp_buf __lang_fail_jmpbuf;";
      "__attribute__((noreturn)) static void __lang_fail_impl(const char* msg) {";
      "  fprintf(stderr, \"fail: %s\\n\", msg);";
      "  if (__lang_fail_jmpbuf_set) { longjmp(__lang_fail_jmpbuf, 1); }";
      "  abort();";
      "}";
      "static int __lang_fail_int(const char* msg) {";
      "  __lang_fail_impl(msg); return 0;";
      "}";
      "static const char* __lang_fail_str(const char* msg) {";
      "  __lang_fail_impl(msg); return \"\";";
      "}";
      "";
      (* Phase 22.5: substring s start end_ — region alloc + memcpy. *)
      "static const char* __lang_substring(const char* s, int start, int end_) {";
      "  int len = end_ - start;";
      "  if (len < 0) len = 0;";
      "  char* r = (char*) __lang_region_alloc(&__lang_default_region, len + 1);";
      "  memcpy(r, s + start, (size_t)len);";
      "  r[len] = '\\0';";
      "  return r;";
      "}";
      "";
      (* Phase 23.5: str_escape — show_str outputs through this helper.
         Convert newline / tab / backslash / double-quote into backslash
         escape form. Stays consistent with interp's show_str. *)
      "static const char* __lang_str_escape(const char* s) {";
      "  size_t n = strlen(s);";
      "  char* r = (char*) __lang_region_alloc(&__lang_default_region, n * 2 + 1);";
      "  size_t j = 0;";
      "  for (size_t i = 0; i < n; i++) {";
      "    char c = s[i];";
      "    switch (c) {";
      "      case '\\n': r[j++] = '\\\\'; r[j++] = 'n'; break;";
      "      case '\\t': r[j++] = '\\\\'; r[j++] = 't'; break;";
      "      case '\\r': r[j++] = '\\\\'; r[j++] = 'r'; break;";
      "      case '\\\\': r[j++] = '\\\\'; r[j++] = '\\\\'; break;";
      "      case '\\\"': r[j++] = '\\\\'; r[j++] = '\\\"'; break;";
      "      default:   r[j++] = c; break;";
      "    }";
      "  }";
      "  r[j] = '\\0';";
      "  return r;";
      "}";
      "";
      (* Phase 24.4: str_count s needle — non-overlapping count. *)
      "static int __lang_str_count(const char* s, const char* n) {";
      "  if (n[0] == '\\0') return 0;";
      "  size_t slen = strlen(s);";
      "  size_t nlen = strlen(n);";
      "  int acc = 0;";
      "  for (size_t i = 0; i + nlen <= slen; ) {";
      "    if (memcmp(s + i, n, nlen) == 0) { acc++; i += nlen; }";
      "    else i++;";
      "  }";
      "  return acc;";
      "}";
      "";
      (* Phase 36: str_trim — strip leading + trailing ASCII whitespace
         (OCaml String.trim semantics: space / tab / newline / cr / form-feed). *)
      "static const char* __lang_str_trim(const char* s) {";
      "  while (*s == ' ' || *s == '\\t' || *s == '\\n' || *s == '\\r' || *s == '\\x0c') s++;";
      "  size_t len = strlen(s);";
      "  while (len > 0) {";
      "    char c = s[len - 1];";
      "    if (c == ' ' || c == '\\t' || c == '\\n' || c == '\\r' || c == '\\x0c') len--;";
      "    else break;";
      "  }";
      "  char* buf = (char*)__lang_region_alloc(&__lang_default_region, len + 1);";
      "  if (len > 0) memcpy(buf, s, len);";
      "  buf[len] = '\\0';";
      "  return buf;";
      "}";
      "";
      (* Phase 36: str_starts_with — bool. *)
      "static int __lang_str_starts_with(const char* s, const char* p) {";
      "  size_t pl = strlen(p);";
      "  return strncmp(s, p, pl) == 0;";
      "}";
      "";
      (* Phase 36: str_ends_with — bool. *)
      "static int __lang_str_ends_with(const char* s, const char* p) {";
      "  size_t sl = strlen(s);";
      "  size_t pl = strlen(p);";
      "  if (pl > sl) return 0;";
      "  return memcmp(s + sl - pl, p, pl) == 0;";
      "}";
      "";
      (* Phase 36: str_repeat s n — concat n copies of s. *)
      "static const char* __lang_str_repeat(const char* s, int n) {";
      "  if (n <= 0) return \"\";";
      "  size_t sl = strlen(s);";
      "  size_t total = sl * (size_t)n;";
      "  char* buf = (char*)__lang_region_alloc(&__lang_default_region, total + 1);";
      "  for (int i = 0; i < n; i++) memcpy(buf + i * sl, s, sl);";
      "  buf[total] = '\\0';";
      "  return buf;";
      "}";
      "";
      (* Phase 36: str_rev — byte-level reverse. *)
      "static const char* __lang_str_rev(const char* s) {";
      "  size_t sl = strlen(s);";
      "  char* buf = (char*)__lang_region_alloc(&__lang_default_region, sl + 1);";
      "  for (size_t i = 0; i < sl; i++) buf[i] = s[sl - 1 - i];";
      "  buf[sl] = '\\0';";
      "  return buf;";
      "}";
      "";
      (* Phase 36: chr n — return pointer to char_table entry for byte n. *)
      "static const char* __lang_char_at_chr(int n) {";
      "  __lang_char_table_setup();";
      "  return __lang_char_table[(unsigned char)n];";
      "}";
      "";
      (* Phase 36: to_upper / to_lower — ASCII case conversion. *)
      "static const char* __lang_to_upper(const char* s) {";
      "  size_t sl = strlen(s);";
      "  char* buf = (char*)__lang_region_alloc(&__lang_default_region, sl + 1);";
      "  for (size_t i = 0; i < sl; i++) {";
      "    char c = s[i];";
      "    buf[i] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;";
      "  }";
      "  buf[sl] = '\\0';";
      "  return buf;";
      "}";
      "static const char* __lang_to_lower(const char* s) {";
      "  size_t sl = strlen(s);";
      "  char* buf = (char*)__lang_region_alloc(&__lang_default_region, sl + 1);";
      "  for (size_t i = 0; i < sl; i++) {";
      "    char c = s[i];";
      "    buf[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;";
      "  }";
      "  buf[sl] = '\\0';";
      "  return buf;";
      "}";
      "";
      (* Phase 36: gcd via Euclid (abs(a), abs(b)) *)
      "static int __lang_gcd(int a, int b) {";
      "  if (a < 0) a = -a;";
      "  if (b < 0) b = -b;";
      "  while (b != 0) { int t = b; b = a % b; a = t; }";
      "  return a;";
      "}";
      "";
      (* Phase 36: str_replace — return s with all non-overlapping occurrences
         of old replaced by new_str. Empty old returns s unchanged. *)
      "static const char* __lang_str_replace(const char* s, const char* old, const char* new_str) {";
      "  if (old[0] == '\\0') return s;";
      "  size_t slen = strlen(s);";
      "  size_t olen = strlen(old);";
      "  size_t nlen = strlen(new_str);";
      "  /* Worst-case size: every char becomes new_str-length. */";
      "  size_t cap = slen + 1;";
      "  if (nlen > olen) cap += (slen / (olen > 0 ? olen : 1)) * (nlen - olen) + nlen;";
      "  char* buf = (char*)__lang_region_alloc(&__lang_default_region, cap);";
      "  size_t bi = 0;";
      "  for (size_t i = 0; i < slen; ) {";
      "    if (i + olen <= slen && memcmp(s + i, old, olen) == 0) {";
      "      memcpy(buf + bi, new_str, nlen); bi += nlen; i += olen;";
      "    } else {";
      "      buf[bi++] = s[i++];";
      "    }";
      "  }";
      "  buf[bi] = '\\0';";
      "  return buf;";
      "}";
      "";
      (* Phase 24.4: read_file / write_file — stdio wrapping with region
         alloc for read_file's returned buffer. Errors → fail via
         __lang_fail_impl which longjmps if try_or is active. *)
      "static const char* __lang_read_file(const char* path) {";
      "  FILE* f = fopen(path, \"rb\");";
      "  if (!f) __lang_fail_impl(path);";
      "  fseek(f, 0, SEEK_END);";
      "  long len = ftell(f);";
      "  fseek(f, 0, SEEK_SET);";
      "  char* buf = (char*)__lang_region_alloc(&__lang_default_region, (size_t)len + 1);";
      "  if (len > 0) { size_t r = fread(buf, 1, (size_t)len, f); (void)r; }";
      "  buf[len] = '\\0';";
      "  fclose(f);";
      "  return buf;";
      "}";
      "static const char* __lang_read_stdin(void) {";
      "  size_t cap = 4096, n = 0;";
      "  char* tmp = (char*)malloc(cap);";
      "  size_t r;";
      "  while ((r = fread(tmp + n, 1, cap - n, stdin)) > 0) {";
      "    n += r;";
      "    if (n == cap) { cap *= 2; tmp = (char*)realloc(tmp, cap); }";
      "  }";
      "  char* buf = (char*)__lang_region_alloc(&__lang_default_region, n + 1);";
      "  memcpy(buf, tmp, n); buf[n] = '\\0';";
      "  free(tmp);";
      "  return buf;";
      "}";
      "static int __lang_write_file(const char* path, const char* content) {";
      "  FILE* f = fopen(path, \"wb\");";
      "  if (!f) __lang_fail_impl(path);";
      "  size_t len = strlen(content);";
      "  if (len > 0) { size_t w = fwrite(content, 1, len, f); (void)w; }";
      "  fclose(f);";
      "  return 0;";
      "}";
      "";
      (* v0.1.13 (mk dogfood): run a command via the shell, inherit stdio,
         return its exit code.
         v0.1.16 (mk dogfood P4): posix_spawn, NOT system() — macOS libc
         serializes concurrent system() calls behind a global lock, so
         parallel `run`s (spawn / par_map) ran one at a time. *)
      "#include <sys/wait.h>";
      "#include <spawn.h>";
      "extern char **environ;";
      "static int __lang_run(const char* cmd) {";
      "  pid_t pid;";
      "  char* argv[] = { \"sh\", \"-c\", (char*)cmd, NULL };";
      "  if (posix_spawn(&pid, \"/bin/sh\", NULL, NULL, argv, environ) != 0)";
      "    return -1;";
      "  int st;";
      "  if (waitpid(pid, &st, 0) < 0) return -1;";
      "  if (WIFEXITED(st)) return WEXITSTATUS(st);";
      "  if (WIFSIGNALED(st)) return 128 + WTERMSIG(st);";
      "  return -1;";
      "}";
      "";
      (* v0.1.18 (mrog dogfood): raw terminal mode + single-key input.
         Raw = no echo, no canonical buffering; ISIG stays on (Ctrl-C
         works). tty_restore puts back the termios saved by the first
         tty_raw. read_key blocks for one byte; "" on EOF. *)
      "#include <termios.h>";
      "static struct termios __lang_saved_tio;";
      "static int __lang_tio_saved = 0;";
      "static int __lang_tty_raw(void) {";
      "  if (!isatty(0)) return 0;";
      "  struct termios tio;";
      "  if (tcgetattr(0, &tio) != 0) return 0;";
      "  if (!__lang_tio_saved) { __lang_saved_tio = tio; __lang_tio_saved = 1; }";
      "  tio.c_lflag &= ~(ICANON | ECHO);";
      "  tio.c_cc[VMIN] = 1; tio.c_cc[VTIME] = 0;";
      "  tcsetattr(0, TCSANOW, &tio);";
      "  return 0;";
      "}";
      "static int __lang_tty_restore(void) {";
      "  if (__lang_tio_saved && isatty(0)) tcsetattr(0, TCSANOW, &__lang_saved_tio);";
      "  return 0;";
      "}";
      "static const char* __lang_read_key(void) {";
      "  char c;";
      "  ssize_t n = read(0, &c, 1);";
      "  char* s = (char*)__lang_region_alloc(&__lang_default_region, 2);";
      "  if (n <= 0) { s[0] = 0; return s; }";
      "  s[0] = c; s[1] = 0;";
      "  return s;";
      "}";
      "";
      (* v0.1.20 (mrog dogfood P3): random_int n — uniform in [0, n).
         Seeded once from time^pid; n <= 0 fails like the interpreter. *)
      "#include <time.h>";
      "static int __lang_random_int(int n) {";
      "  static int __seeded = 0;";
      "  if (!__seeded) { srand((unsigned)(time(NULL) ^ getpid())); __seeded = 1; }";
      "  if (n <= 0) __lang_fail_impl(\"random_int: bound must be positive\");";
      "  return rand() % n;";
      "}";
      "";
      (* Phase 44: mkdir_p doesn't depend on list_str, so it can live in the header *)
      "#include <sys/stat.h>";
      "#include <errno.h>";
      "#include <unistd.h>";   (* Phase 44.6: usleep *)
      "static double __lang_file_mtime(const char* path) {";
      "  struct stat st;";
      "  if (stat(path, &st) != 0) __lang_fail_impl(path);";
      "  return (double)st.st_mtime;";
      "}";
      (* v0.1.21 (mwasm dogfood P1): true byte length via stat. *)
      "static int __lang_file_size(const char* path) {";
      "  struct stat st;";
      "  if (stat(path, &st) != 0) __lang_fail_impl(path);";
      "  return (int)st.st_size;";
      "}";
      (* v0.1.15 (mk dogfood P3): file_exists — stat succeeds. *)
      "static int __lang_file_exists(const char* path) {";
      "  struct stat st;";
      "  return stat(path, &st) == 0;";
      "}";
      "static int __lang_sleep_ms(int ms) {";
      "  if (ms <= 0) return 0;";
      "  usleep((useconds_t)ms * 1000);";
      "  return 0;";
      "}";
      "static int __lang_mkdir_p(const char* path) {";
      "  /* recursive mkdir -p: skip if exists; on failure call __lang_fail_impl */";
      "  size_t n = strlen(path);";
      "  if (n == 0) return 0;";
      "  char* buf = (char*)malloc(n + 1);";
      "  memcpy(buf, path, n + 1);";
      "  for (size_t i = 1; i <= n; i++) {";
      "    if (buf[i] == '/' || buf[i] == '\\0') {";
      "      char saved = buf[i];";
      "      buf[i] = '\\0';";
      "      if (mkdir(buf, 0755) != 0 && errno != EEXIST) {";
      "        free(buf);";
      "        __lang_fail_impl(path);";
      "      }";
      "      buf[i] = saved;";
      "    }";
      "  }";
      "  free(buf);";
      "  return 0;";
      "}";
      "";
      (* Phase 22.6: str_unescape — interpret backslash escapes (n / t / r /
         backslash / quote / slash); pass others through unchanged. Handles
         escapes inside string literals for json_parser and the like. *)
      "static const char* __lang_str_unescape(const char* s) {";
      "  size_t n = strlen(s);";
      "  char* r = (char*) __lang_region_alloc(&__lang_default_region, n + 1);";
      "  size_t i = 0, j = 0;";
      "  while (i < n) {";
      "    if (s[i] == '\\\\' && i + 1 < n) {";
      "      char c = s[i + 1];";
      "      switch (c) {";
      "        case 'n': r[j++] = '\\n'; break;";
      "        case 't': r[j++] = '\\t'; break;";
      "        case 'r': r[j++] = '\\r'; break;";
      "        case '\\\\': r[j++] = '\\\\'; break;";
      "        case '\"': r[j++] = '\"'; break;";
      "        case '/': r[j++] = '/'; break;";
      "        default: r[j++] = c; break;";
      "      }";
      "      i += 2;";
      "    } else {";
      "      r[j++] = s[i++];";
      "    }";
      "  }";
      "  r[j] = '\\0';";
      "  return r;";
      "}";
      "";
      (* Phase 34.1 / v0.1.12: str_of_float — %.12g, then append ".0" for
         integer-valued floats (kept identical to the interp's format_float
         and the Wasm JS host). *)
      "static const char* __lang_str_of_float(double f) {";
      "  char* buf;";
      "  asprintf(&buf, \"%.12g\", f);";
      "  int has_dot = 0;";
      "  for (char* p = buf; *p; p++) {";
      "    if (*p == '.' || *p == 'e' || *p == 'E' || *p == 'n' || *p == 'i') {";
      "      has_dot = 1; break;";
      "    }";
      "  }";
      "  if (!has_dot) {";
      "    char* buf2;";
      "    asprintf(&buf2, \"%s.0\", buf);";
      "    free(buf);";
      "    return (const char*) buf2;";
      "  }";
      "  return (const char*) buf;";
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
      "/* Program-lifetime arena for closure envs and other long-lived";
      "   allocations that outlive any user `region R { ... }` block. It is";
      "   never freed, so pointers into it stay valid for the whole run —";
      "   including in spawned threads (Q-012). Only its bump pointer needs";
      "   guarding: allocations from THIS region take a lock, while per-block";
      "   regions (thread-local stack locals) stay lock-free. */";
      "static __lang_region __lang_default_region;";
      "static pthread_mutex_t __lang_default_region_lock = PTHREAD_MUTEX_INITIALIZER;";
      "";
      "static void* __lang_region_alloc(__lang_region* r, size_t n) {";
      "  int shared = (r == &__lang_default_region);";
      "  if (shared) pthread_mutex_lock(&__lang_default_region_lock);";
      "  size_t aligned = (n + 7) & ~((size_t)7);";
      "  if (r->top + aligned > r->base + r->cap) {";
      "    fprintf(stderr, \"region OOM\\n\"); abort();";
      "  }";
      "  void* p = r->top;";
      "  r->top += aligned;";
      "  if (shared) pthread_mutex_unlock(&__lang_default_region_lock);";
      "  return p;";
      "}";
      "";
      "static void __lang_region_free(__lang_region* r) {";
      "  free(r->base);";
      "}" ]

(* Phase 15.10: Map[R, K, V] runtime — region-allocated linear-scan
   associative array. K supports only int / str; V is any concrete type.
   Storage is two parallel arrays (keys[], values[]); when cap is hit, a
   new array is allocated in the same region (arena semantics). *)
let emit_map_runtime_for (k_ty : Ast.ty) (v_ty : Ast.ty) : string =
  let k_tag = ty_tag k_ty in
  let v_tag = ty_tag v_ty in
  let c_k = c_type_of k_ty in
  let c_v = c_type_of v_ty in
  let struct_name = Printf.sprintf "mere_map_%s_%s" k_tag v_tag in
  let rec key_eq_for k a b =
    match Ast.walk k with
    | Ast.TyInt | Ast.TyBool -> Printf.sprintf "(%s) == (%s)" a b
    | Ast.TyStr -> Printf.sprintf "strcmp((%s), (%s)) == 0" a b
    | Ast.TyTuple ts ->
      let parts = List.mapi (fun i t ->
        key_eq_for t
          (Printf.sprintf "(%s).f%d" a i)
          (Printf.sprintf "(%s).f%d" b i)) ts in
      "(" ^ String.concat " && " parts ^ ")"
    | Ast.TyCon (rname, _) when Hashtbl.mem Typer.records rname ->
      (* Phase 15.15: record key — compare each field recursively. *)
      let info = Hashtbl.find Typer.records rname in
      let parts = List.map (fun (fname, fty) ->
        key_eq_for fty
          (Printf.sprintf "(%s).%s" a fname)
          (Printf.sprintf "(%s).%s" b fname)) info.Typer.r_fields in
      "(" ^ String.concat " && " parts ^ ")"
    | Ast.TyCon (vname, _) when Hashtbl.mem Exhaustive.type_variants vname ->
      (* Phase 15.15/15.16: variant key — first check tags match, then
         for matching tag, recursively compare the payload (if any).
         Emit as a tag-keyed ternary chain. Nullary ctors short-circuit
         to `1` (their tag match is the only test). *)
      let ctors = Hashtbl.find Exhaustive.type_variants vname in
      let has_payload = List.exists (fun (_, p) -> p <> None) ctors in
      if not has_payload then
        (* All nullary — just compare tags. *)
        Printf.sprintf "(%s).tag == (%s).tag" a b
      else begin
        let cases =
          List.map (fun (cname, payload) ->
            let tag_v = Hashtbl.find variant_tags cname in
            match payload with
            | None -> Printf.sprintf "(%s).tag == %d ? 1" a tag_v
            | Some pt ->
              let pa = Printf.sprintf "(%s).payload.%s" a cname in
              let pb = Printf.sprintf "(%s).payload.%s" b cname in
              Printf.sprintf "(%s).tag == %d ? (%s)"
                a tag_v (key_eq_for (Ast.walk pt) pa pb)
          ) ctors
        in
        Printf.sprintf "((%s).tag == (%s).tag && (%s : 0))"
          a b (String.concat " : " cases)
      end
    | _ -> Printf.sprintf "(%s) == (%s)" a b
  in
  let key_eq_expr a b = key_eq_for k_ty a b in
  String.concat "\n"
    [ Printf.sprintf "typedef struct %s {" struct_name;
      Printf.sprintf "  %s* keys;" c_k;
      Printf.sprintf "  %s* values;" c_v;
      "  int len;";
      "  int cap;";
      "  __lang_region* region;";
      Printf.sprintf "} %s;" struct_name;
      "";
      (* new *)
      Printf.sprintf "static %s* %s_new(__lang_region* r) {" struct_name struct_name;
      Printf.sprintf "  %s* m = (%s*)__lang_region_alloc(r, sizeof(%s));"
        struct_name struct_name struct_name;
      "  m->cap = 4;";
      "  m->len = 0;";
      Printf.sprintf "  m->keys = (%s*)__lang_region_alloc(r, sizeof(%s) * 4);" c_k c_k;
      Printf.sprintf "  m->values = (%s*)__lang_region_alloc(r, sizeof(%s) * 4);" c_v c_v;
      "  m->region = r;";
      "  return m;";
      "}";
      "";
      (* set: replace if key exists, otherwise append (grow the array on cap hit) *)
      Printf.sprintf "static int %s_set(%s* m, %s k, %s v) {"
        struct_name struct_name c_k c_v;
      "  for (int i = 0; i < m->len; i++) {";
      Printf.sprintf "    if (%s) { m->values[i] = v; return 0; }"
        (key_eq_expr "m->keys[i]" "k");
      "  }";
      "  if (m->len == m->cap) {";
      "    int new_cap = m->cap * 2;";
      Printf.sprintf "    %s* nk = (%s*)__lang_region_alloc(m->region, sizeof(%s) * new_cap);" c_k c_k c_k;
      Printf.sprintf "    %s* nv = (%s*)__lang_region_alloc(m->region, sizeof(%s) * new_cap);" c_v c_v c_v;
      "    for (int i = 0; i < m->len; i++) {";
      "      nk[i] = m->keys[i];";
      "      nv[i] = m->values[i];";
      "    }";
      "    m->keys = nk;";
      "    m->values = nv;";
      "    m->cap = new_cap;";
      "  }";
      "  m->keys[m->len] = k;";
      "  m->values[m->len] = v;";
      "  m->len++;";
      "  return 0; /* unit */";
      "}";
      "";
      (* get *)
      Printf.sprintf "static %s %s_get(%s* m, %s k) {"
        c_v struct_name struct_name c_k;
      "  for (int i = 0; i < m->len; i++) {";
      Printf.sprintf "    if (%s) return m->values[i];"
        (key_eq_expr "m->keys[i]" "k");
      "  }";
      "  fprintf(stderr, \"map_get: key not found\\n\");";
      "  abort();";
      "}";
      "";
      (* has *)
      Printf.sprintf "static int %s_has(%s* m, %s k) {"
        struct_name struct_name c_k;
      "  for (int i = 0; i < m->len; i++) {";
      Printf.sprintf "    if (%s) return 1;"
        (key_eq_expr "m->keys[i]" "k");
      "  }";
      "  return 0;";
      "}";
      "";
      (* len *)
      Printf.sprintf "static int %s_len(%s* m) { return m->len; }"
        struct_name struct_name;
      "";
      (* Phase 39.A' #2: delete — remove the matching key by shifting the
         keys / values arrays. No-op if the key is absent. *)
      Printf.sprintf "static int %s_delete(%s* m, %s k) {"
        struct_name struct_name c_k;
      "  for (int i = 0; i < m->len; i++) {";
      Printf.sprintf "    if (%s) {" (key_eq_expr "m->keys[i]" "k");
      "      for (int j = i; j < m->len - 1; j++) {";
      "        m->keys[j] = m->keys[j+1];";
      "        m->values[j] = m->values[j+1];";
      "      }";
      "      m->len--;";
      "      return 0;";
      "    }";
      "  }";
      "  return 0;";
      "}" ]

(* Phase 15.9: StrBuf[R] runtime — region-allocated mutable string buffer.
   Single-instance (StrBuf has no element type parameter, it's always bytes).
   to_str returns a null-terminated copy in the region. *)
let strbuf_runtime =
  String.concat "\n"
    [ "typedef struct mere_strbuf {";
      "  char* data;";
      "  int len;";
      "  int cap;";
      "  __lang_region* region;";
      "} mere_strbuf;";
      "";
      "static mere_strbuf* mere_strbuf_new(__lang_region* r) {";
      "  mere_strbuf* sb = (mere_strbuf*)__lang_region_alloc(r, sizeof(mere_strbuf));";
      "  sb->cap = 16;";
      "  sb->len = 0;";
      "  sb->data = (char*)__lang_region_alloc(r, sizeof(char) * 16);";
      "  sb->region = r;";
      "  return sb;";
      "}";
      "";
      "static int mere_strbuf_push(mere_strbuf* sb, const char* s) {";
      "  int slen = (int)strlen(s);";
      "  while (sb->len + slen > sb->cap) {";
      "    int new_cap = sb->cap * 2;";
      "    char* new_data = (char*)__lang_region_alloc(sb->region, sizeof(char) * new_cap);";
      "    for (int i = 0; i < sb->len; i++) new_data[i] = sb->data[i];";
      "    sb->data = new_data;";
      "    sb->cap = new_cap;";
      "  }";
      "  for (int i = 0; i < slen; i++) sb->data[sb->len + i] = s[i];";
      "  sb->len += slen;";
      "  return 0; /* unit */";
      "}";
      "";
      "static const char* mere_strbuf_to_str(mere_strbuf* sb) {";
      "  /* Phase 36 (DEFERRED §1.16 fix): allocate result in the process-";
      "     wide default region so the returned str outlives the StrBuf's";
      "     scoped region. Avoids dangling pointers when";
      "     `region R { ...; strbuf_to_str b }` returns a value out of R. */";
      "  char* r = (char*)__lang_region_alloc(&__lang_default_region, sb->len + 1);";
      "  for (int i = 0; i < sb->len; i++) r[i] = sb->data[i];";
      "  r[sb->len] = '\\0';";
      "  return r;";
      "}";
      "";
      "static int mere_strbuf_len(mere_strbuf* sb) { return sb->len; }" ]

(* Phase 16.3 / DEFERRED §1.5: codegen runtime for mk_logger / mk_metrics.
   To expose the cap (implemented as V_builtin in the interpreter) on the C
   side too, provide factory functions returning the Logger / Metrics struct
   types (already registered by the typer and codegen'd as records).

   The 3 fields of Logger (info / warn / error) are all `closure_str_unit`
   (= `{ void* env, int (*fn)(void*, const char*) }`). The env stores the
   prefix string directly (it's a string literal, so no copy needed).

   Metrics' `record` is in curried form `str -> int -> unit`, so the outer
   closure returns the inner closure. The inner closure's env must carry the
   field name; allocate it from the default region and reuse. *)
let logger_runtime =
  String.concat "\n"
    [ "/* Phase 16.3: mk_logger runtime — returns a Logger record holding";
      "   3 closure_str_unit fields. The prefix is bound as env. */";
      "static int __mere_logger_info_fn(void* env, const char* msg) {";
      "  printf(\"%s [INFO] %s\\n\", (const char*)env, msg);";
      "  return 0;";
      "}";
      "static int __mere_logger_warn_fn(void* env, const char* msg) {";
      "  printf(\"%s [WARN] %s\\n\", (const char*)env, msg);";
      "  return 0;";
      "}";
      "static int __mere_logger_error_fn(void* env, const char* msg) {";
      "  printf(\"%s [ERROR] %s\\n\", (const char*)env, msg);";
      "  return 0;";
      "}";
      "static Logger __mere_mk_logger(const char* prefix) {";
      "  return (Logger){";
      "    .info  = {.env = (void*)prefix, .fn = __mere_logger_info_fn},";
      "    .warn  = {.env = (void*)prefix, .fn = __mere_logger_warn_fn},";
      "    .error = {.env = (void*)prefix, .fn = __mere_logger_error_fn},";
      "  };";
      "}" ]

let metrics_runtime =
  String.concat "\n"
    [ "/* Phase 16.3: mk_metrics runtime — Metrics record (inc / record).";
      "   record is curried (str -> int -> unit); the inner closure's env";
      "   carries the field name. */";
      "static int __mere_metrics_inc_fn(void* env, const char* name) {";
      "  (void)env;";
      "  printf(\"[METRIC] inc %s\\n\", name);";
      "  return 0;";
      "}";
      "static int __mere_metrics_record_inner_fn(void* env, int n) {";
      "  printf(\"[METRIC] %s=%d\\n\", (const char*)env, n);";
      "  return 0;";
      "}";
      "static closure_int_unit __mere_metrics_record_outer_fn(void* env, const char* name) {";
      "  (void)env;";
      "  /* Assume name is a string literal (same assumption as interpreter);";
      "     no copy needed, hand it directly to env. */";
      "  return (closure_int_unit){.env = (void*)name, .fn = __mere_metrics_record_inner_fn};";
      "}";
      "static Metrics __mere_mk_metrics(int unit_arg) {";
      "  (void)unit_arg;";
      "  return (Metrics){";
      "    .inc    = {.env = NULL, .fn = __mere_metrics_inc_fn},";
      "    .record = {.env = NULL, .fn = __mere_metrics_record_outer_fn},";
      "  };";
      "}" ]

(* Phase 24.3: str_split / str_join helpers.
   list_str = list_str_node* (a mono variant typedef; the prelude's
   `type 'a list = Nil | Cons of 'a * 'a list` instantiated at 'str).
   tag 0 = Nil, tag 1 = Cons (assigned in source order by the typer's
   register_type). *)
let str_list_helpers =
  String.concat "\n"
    [ "/* Phase 24.3: str_split builds a list_str by tokenizing s by delim. */";
      "static list_str __lang_str_split(const char* s, const char* delim) {";
      "  size_t slen = strlen(s);";
      "  size_t dlen = strlen(delim);";
      "  list_str nil_node = (list_str)__lang_region_alloc(&__lang_default_region, sizeof(struct list_str_node));";
      "  nil_node->tag = 0;";
      "  if (dlen == 0) {";
      "    /* empty delim: return the whole string as a single element (matches interp) */";
      "    list_str cons = (list_str)__lang_region_alloc(&__lang_default_region, sizeof(struct list_str_node));";
      "    cons->tag = 1;";
      "    cons->payload.Cons.f0 = s;";
      "    cons->payload.Cons.f1 = nil_node;";
      "    return cons;";
      "  }";
      "  /* count tokens */";
      "  size_t n = 1;";
      "  for (size_t i = 0; i + dlen <= slen; ) {";
      "    if (memcmp(s + i, delim, dlen) == 0) { n++; i += dlen; }";
      "    else i++;";
      "  }";
      "  /* allocate cons cells */";
      "  list_str* cells = (list_str*)__lang_region_alloc(&__lang_default_region, n * sizeof(list_str));";
      "  for (size_t k = 0; k < n; k++) {";
      "    cells[k] = (list_str)__lang_region_alloc(&__lang_default_region, sizeof(struct list_str_node));";
      "    cells[k]->tag = 1;";
      "  }";
      "  /* fill tokens + link */";
      "  size_t start = 0, idx = 0;";
      "  for (size_t i = 0; i + dlen <= slen; ) {";
      "    if (memcmp(s + i, delim, dlen) == 0) {";
      "      size_t tlen = i - start;";
      "      char* tok = (char*)__lang_region_alloc(&__lang_default_region, tlen + 1);";
      "      memcpy(tok, s + start, tlen);";
      "      tok[tlen] = '\\0';";
      "      cells[idx]->payload.Cons.f0 = tok;";
      "      cells[idx]->payload.Cons.f1 = cells[idx + 1];";
      "      idx++;";
      "      start = i + dlen;";
      "      i = start;";
      "    } else i++;";
      "  }";
      "  /* last token */";
      "  size_t tlen = slen - start;";
      "  char* tok = (char*)__lang_region_alloc(&__lang_default_region, tlen + 1);";
      "  memcpy(tok, s + start, tlen);";
      "  tok[tlen] = '\\0';";
      "  cells[idx]->payload.Cons.f0 = tok;";
      "  cells[idx]->payload.Cons.f1 = nil_node;";
      "  return cells[0];";
      "}";
      "";
      "/* Phase 24.3: str_join sep xs — concat list_str elements with sep. */";
      "static const char* __lang_str_join(const char* sep, list_str xs) {";
      "  if (xs->tag == 0) return \"\";";
      "  size_t seplen = strlen(sep);";
      "  size_t total = 0;";
      "  int first = 1;";
      "  list_str cur = xs;";
      "  while (cur->tag == 1) {";
      "    if (!first) total += seplen;";
      "    total += strlen(cur->payload.Cons.f0);";
      "    first = 0;";
      "    cur = cur->payload.Cons.f1;";
      "  }";
      "  char* r = (char*)__lang_region_alloc(&__lang_default_region, total + 1);";
      "  size_t pos = 0;";
      "  first = 1;";
      "  cur = xs;";
      "  while (cur->tag == 1) {";
      "    if (!first) {";
      "      memcpy(r + pos, sep, seplen);";
      "      pos += seplen;";
      "    }";
      "    size_t l = strlen(cur->payload.Cons.f0);";
      "    memcpy(r + pos, cur->payload.Cons.f0, l);";
      "    pos += l;";
      "    first = 0;";
      "    cur = cur->payload.Cons.f1;";
      "  }";
      "  r[pos] = '\\0';";
      "  return r;";
      "}";
      "";
      (* Phase 44: list_dir — turn dir entries (sorted, excluding `.` / `..`)
         into a list_str. Use qsort for a stable order to guarantee diff = 0
         with interp (eval.ml). *)
      "#include <dirent.h>";
      "static int __lang_list_dir_qsort(const void* a, const void* b) {";
      "  return strcmp(*(const char* const*)a, *(const char* const*)b);";
      "}";
      "static list_str __lang_list_dir(const char* path) {";
      "  DIR* d = opendir(path);";
      "  if (!d) __lang_fail_impl(path);";
      "  size_t cap = 16, n = 0;";
      "  const char** arr = (const char**)malloc(cap * sizeof(char*));";
      "  struct dirent* ent;";
      "  while ((ent = readdir(d)) != NULL) {";
      "    if (strcmp(ent->d_name, \".\") == 0 || strcmp(ent->d_name, \"..\") == 0) continue;";
      "    if (n == cap) { cap *= 2; arr = (const char**)realloc(arr, cap * sizeof(char*)); }";
      "    size_t nlen = strlen(ent->d_name);";
      "    char* copy = (char*)__lang_region_alloc(&__lang_default_region, nlen + 1);";
      "    memcpy(copy, ent->d_name, nlen + 1);";
      "    arr[n++] = copy;";
      "  }";
      "  closedir(d);";
      "  qsort(arr, n, sizeof(char*), __lang_list_dir_qsort);";
      "  list_str nil_node = (list_str)__lang_region_alloc(&__lang_default_region, sizeof(struct list_str_node));";
      "  nil_node->tag = 0;";
      "  list_str head = nil_node;";
      "  for (size_t k = 0; k < n; k++) {";
      "    size_t i = n - 1 - k;";
      "    list_str cons = (list_str)__lang_region_alloc(&__lang_default_region, sizeof(struct list_str_node));";
      "    cons->tag = 1;";
      "    cons->payload.Cons.f0 = arr[i];";
      "    cons->payload.Cons.f1 = head;";
      "    head = cons;";
      "  }";
      "  free(arr);";
      "  return head;";
      "}";
      "";
      (* Native CLI: argv[1..] as a str list, preserving order. argc/argv are
         captured into these globals by main(). Mirrors interp's `args`
         (argv[0], the program name, is dropped). *)
      "int __lang_argc = 0;";
      "char** __lang_argv = 0;";
      "static list_str __lang_args(void) {";
      "  list_str head = (list_str)__lang_region_alloc(&__lang_default_region, sizeof(struct list_str_node));";
      "  head->tag = 0;";
      "  for (int k = 1; k < __lang_argc; k++) {";
      "    int i = __lang_argc - k;  /* reverse so argv[1] ends up first */";
      "    const char* a = __lang_argv[i];";
      "    size_t nlen = strlen(a);";
      "    char* copy = (char*)__lang_region_alloc(&__lang_default_region, nlen + 1);";
      "    memcpy(copy, a, nlen + 1);";
      "    list_str cons = (list_str)__lang_region_alloc(&__lang_default_region, sizeof(struct list_str_node));";
      "    cons->tag = 1;";
      "    cons->payload.Cons.f0 = copy;";
      "    cons->payload.Cons.f1 = head;";
      "    head = cons;";
      "  }";
      "  return head;";
      "}" ]

(* Phase 15.8: registry that tracks all OwnedVecs. Every struct allocated by
   `owned_vec_new` / `vec_to_owned` is registered in a thread-local list;
   at the end of main, `__mere_owned_vec_free_all` iterates and calls
   `free(v->data); free(v);`. This keeps memory analyzers like valgrind
   clean (leaving it to process exit would be reported as a "leak"). All
   mere_owned_vec_<T> share the same struct layout `{ T*, int, int }`, so
   the first field's void* data can be read generically. *)
let owned_vec_registry_runtime =
  String.concat "\n"
    [ "/* Phase 15.8: registry of heap-allocated OwnedVecs. Bulk-freed at";
      "   process end. */";
      "typedef struct __mere_owned_vec_base {";
      "  void* data;";
      "  int len;";
      "  int cap;";
      "} __mere_owned_vec_base;";
      "";
      "static void** __mere_owned_vec_registry = NULL;";
      "static int __mere_owned_vec_count = 0;";
      "static int __mere_owned_vec_cap = 0;";
      "";
      "static void __mere_owned_vec_register(void* v) {";
      "  if (__mere_owned_vec_count == __mere_owned_vec_cap) {";
      "    __mere_owned_vec_cap = __mere_owned_vec_cap == 0 ? 8 : __mere_owned_vec_cap * 2;";
      "    __mere_owned_vec_registry = (void**)realloc(";
      "      __mere_owned_vec_registry, sizeof(void*) * __mere_owned_vec_cap);";
      "  }";
      "  __mere_owned_vec_registry[__mere_owned_vec_count++] = v;";
      "}";
      "";
      "static void __mere_owned_vec_free_all(void) {";
      "  for (int i = 0; i < __mere_owned_vec_count; i++) {";
      "    __mere_owned_vec_base* v = (__mere_owned_vec_base*)__mere_owned_vec_registry[i];";
      "    free(v->data);";
      "    free(v);";
      "  }";
      "  free(__mere_owned_vec_registry);";
      "  __mere_owned_vec_registry = NULL;";
      "  __mere_owned_vec_count = 0;";
      "  __mere_owned_vec_cap = 0;";
      "}" ]

(* Phase 15.7/15.8: emit one OwnedVec[T] runtime per concrete element type.
   Heap-allocated (malloc / realloc). Each `_new` registers itself in the
   process-wide registry so main can free everything at program exit. *)
let emit_owned_vec_runtime_for (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_elem = c_type_of elem_ty in
  let struct_name = "mere_owned_vec_" ^ tag in
  String.concat "\n"
    [ Printf.sprintf "typedef struct %s {" struct_name;
      Printf.sprintf "  %s* data;" c_elem;
      "  int len;";
      "  int cap;";
      Printf.sprintf "} %s;" struct_name;
      "";
      Printf.sprintf "static %s* %s_new(void) {" struct_name struct_name;
      Printf.sprintf "  %s* v = (%s*)malloc(sizeof(%s));"
        struct_name struct_name struct_name;
      "  v->cap = 4;";
      "  v->len = 0;";
      Printf.sprintf "  v->data = (%s*)malloc(sizeof(%s) * 4);" c_elem c_elem;
      "  __mere_owned_vec_register(v);";
      "  return v;";
      "}";
      "";
      Printf.sprintf "static int %s_push(%s* v, %s x) {"
        struct_name struct_name c_elem;
      "  if (v->len == v->cap) {";
      "    v->cap *= 2;";
      Printf.sprintf "    v->data = (%s*)realloc(v->data, sizeof(%s) * v->cap);"
        c_elem c_elem;
      "  }";
      "  v->data[v->len++] = x;";
      "  return 0; /* unit */";
      "}";
      "";
      Printf.sprintf "static %s %s_get(%s* v, int i) {" c_elem struct_name struct_name;
      "  if (i < 0 || i >= v->len) {";
      "    fprintf(stderr, \"owned_vec_get: index %d out of bounds (len = %d)\\n\", i, v->len);";
      "    abort();";
      "  }";
      "  return v->data[i];";
      "}";
      "";
      Printf.sprintf "static int %s_len(%s* v) { return v->len; }"
        struct_name struct_name ]

(* Phase 15.2/15.5: Vec[R, T] runtime — emit struct + 5 helpers
   (new / push / get / len / set) per concrete element type. *)
let emit_vec_runtime_for (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let c_elem = c_type_of elem_ty in
  let struct_name = "mere_vec_" ^ tag in
  String.concat "\n"
    [ Printf.sprintf "typedef struct %s {" struct_name;
      Printf.sprintf "  %s* data;" c_elem;
      "  int len;";
      "  int cap;";
      "  __lang_region* region;";
      Printf.sprintf "} %s;" struct_name;
      "";
      Printf.sprintf "static %s* %s_new(__lang_region* r) {" struct_name struct_name;
      Printf.sprintf "  %s* v = (%s*)__lang_region_alloc(r, sizeof(%s));"
        struct_name struct_name struct_name;
      "  v->cap = 4;";
      "  v->len = 0;";
      Printf.sprintf "  v->data = (%s*)__lang_region_alloc(r, sizeof(%s) * 4);" c_elem c_elem;
      "  v->region = r;";
      "  return v;";
      "}";
      "";
      Printf.sprintf "static int %s_push(%s* v, %s x) {" struct_name struct_name c_elem;
      "  if (v->len == v->cap) {";
      "    int new_cap = v->cap * 2;";
      Printf.sprintf "    %s* new_data = (%s*)__lang_region_alloc(v->region, sizeof(%s) * new_cap);"
        c_elem c_elem c_elem;
      "    for (int i = 0; i < v->len; i++) new_data[i] = v->data[i];";
      "    v->data = new_data;";
      "    v->cap = new_cap;";
      "  }";
      "  v->data[v->len++] = x;";
      "  return 0; /* unit */";
      "}";
      "";
      Printf.sprintf "static %s %s_get(%s* v, int i) {" c_elem struct_name struct_name;
      "  if (i < 0 || i >= v->len) {";
      "    fprintf(stderr, \"vec_get: index %d out of bounds (len = %d)\\n\", i, v->len);";
      "    abort();";
      "  }";
      "  return v->data[i];";
      "}";
      "";
      Printf.sprintf "static int %s_len(%s* v) { return v->len; }" struct_name struct_name;
      "";
      Printf.sprintf "static int %s_set(%s* v, int i, %s x) {"
        struct_name struct_name c_elem;
      "  if (i < 0 || i >= v->len) {";
      "    fprintf(stderr, \"vec_set: index %d out of bounds (len = %d)\\n\", i, v->len);";
      "    abort();";
      "  }";
      "  v->data[i] = x;";
      "  return 0; /* unit */";
      "}" ]

let main_format_of (t : Ast.ty) : string option =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool -> Some "%d"
  | Ast.TyFloat -> Some "%g"  (* Phase 34.1: IEEE 754 double *)
  | Ast.TyStr -> Some "%s"
  | Ast.TyUnit -> Some "()"  (* Phase 27.0: print "()" to match interp *)
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
    (fns : fn_decl list)
    (main_body : Ast.expr) : lifted_fn list =
  Hashtbl.reset inner_lifts;
  Hashtbl.reset inner_lifts_by_host;
  inner_fn_counter := 0;
  let lifted = ref [] in
  (* Tracks which host fn we're currently inside; written by the outer
     List.iter that calls walk_in_fn per top-level fn. lift_one /
     Let_rec writes into inner_lifts_by_host[current_host]. *)
  let current_host = ref "" in
  (* Globals = top-level lifted fns + builtins (anything in Typer's
     initial env). Closure captures must exclude these. *)
  let builtin_names = List.map fst Typer.initial_env in
  let known = ref (toplevel_names @ builtin_names) in
  let lift_one host_param host_locals n p fn_body value_loc value_ty =
    (* Phase 24.1: subtract host_locals from `known` so that builtins
       shadowed by a local `let` in the host fn (e.g., `let len = ...`)
       are NOT excluded from free_vars — they should be captured. *)
    let effective_known =
      List.filter (fun k -> not (List.mem k host_locals)) !known
    in
    let body_fvs = free_vars fn_body (p :: effective_known) in
    let captures =
      List.map (fun fv ->
        let ty = lookup_var_ty fn_body fv in
        (fv, ty)) body_fvs
    in
    (* Phase 24.1: previously restricted captures to primitive types
       (int / bool / str / unit). Anonymous closures (pending_closures
       path) have always supported all types via c_type_of, so the
       same should work for inner-lifted fns. Allow all types that
       can be emitted by c_type_of; defer the check to env struct
       emission where c_type_of will raise on truly-unsupported types
       (e.g., float). *)
    List.iter (fun (_, _ty) -> ()) captures;
    let lifted_name = fresh_inner_name n in
    let return_ty, param_ty =
      match value_ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyArrow (a, b) -> (Ast.walk b, Ast.walk a)
         | _ ->
           raise (Codegen_error (value_loc,
             "inner fn has non-arrow inferred type")))
      | None ->
        raise (Codegen_error (value_loc,
          "inner fn missing inferred type (typer not run?)"))
    in
    let lf = {
      l_name = lifted_name; l_captures = captures;
      l_param = p; l_param_ty = param_ty;
      l_body = fn_body; l_return_ty = return_ty;
      l_host = !current_host;
    } in
    lifted := lf :: !lifted;
    let entry = { lifted_name; captures } in
    Hashtbl.replace inner_lifts n entry;  (* keep last-write for back-compat *)
    let host_tbl =
      match Hashtbl.find_opt inner_lifts_by_host !current_host with
      | Some t -> t
      | None ->
        let t = Hashtbl.create 4 in
        Hashtbl.add inner_lifts_by_host !current_host t;
        t
    in
    Hashtbl.replace host_tbl n entry;
    known := lifted_name :: !known;
    (host_param, fn_body)
  in
  let rec walk_in_fn (host_param : string) (host_locals : string list) (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, body) ->
      (match pat.Ast.pnode, value.Ast.node with
       | Ast.P_var n, Ast.Fun (p, _, fn_body) ->
         let (host_param, fn_body) =
           lift_one host_param host_locals n p fn_body value.Ast.loc value.Ast.ty
         in
         walk_in_fn p [] fn_body;
         walk_in_fn host_param (n :: host_locals) body
       | _ ->
         walk_in_fn host_param host_locals value;
         (* Phase 24.1: extend host_locals with the pattern's bound names
            so inner fns lifted in `body` can detect shadowed builtins. *)
         walk_in_fn host_param (pattern_vars pat @ host_locals) body)
    | Ast.Let_rec (bindings, body) ->
      let rec_names = List.map fst bindings in
      let known_before = !known in
      let fn_specs = List.map (fun (n, value) ->
        match value.Ast.node with
        | Ast.Fun (p, _, fn_body) ->
          (n, p, fn_body, value.Ast.loc, value.Ast.ty)
        | _ ->
          raise (Codegen_error (value.Ast.loc,
            "inner let-rec binding must be a single-arg function"))
      ) bindings in
      known := rec_names @ !known;
      List.iter (fun (n, p, fn_body, loc, vty) ->
        let _ = lift_one host_param host_locals n p fn_body loc vty in ()
      ) fn_specs;
      List.iter (fun (_, p, fn_body, _, _) ->
        walk_in_fn p [] fn_body) fn_specs;
      let _ = known_before in
      walk_in_fn host_param (rec_names @ host_locals) body
    | Ast.Fun (_, _, body) ->
      walk_in_fn host_param host_locals body
    | _ -> walk_children walk_in_fn host_param host_locals e
  and walk_children walker host_param host_locals e =
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walker host_param host_locals a; walker host_param host_locals b
    | Ast.Neg a | Ast.Annot (a, _) -> walker host_param host_locals a
    | Ast.Let (_, v, b) -> walker host_param host_locals v; walker host_param host_locals b
    | Ast.Let_rec (bs, b) ->
      List.iter (fun (_, v) -> walker host_param host_locals v) bs;
      walker host_param host_locals b
    | Ast.With (_, v, b) -> walker host_param host_locals v; walker host_param host_locals b
    | Ast.If (c, t, e_) ->
      walker host_param host_locals c;
      walker host_param host_locals t;
      walker host_param host_locals e_
    | Ast.Fun (_, _, b) -> walker host_param host_locals b
    | Ast.Constr (_, Some a) -> walker host_param host_locals a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walker host_param host_locals s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walker host_param host_locals ge | None -> ());
        walker host_param host_locals b) arms
    | Ast.Tuple es -> List.iter (walker host_param host_locals) es
    | Ast.Region_block (_, b) -> walker host_param host_locals b
    | Ast.Ref (_, _, a) -> walker host_param host_locals a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walker host_param host_locals e) fs
    | Ast.Field_get (a, _) -> walker host_param host_locals a
    | Ast.Record_update (a, fs) ->
      walker host_param host_locals a; List.iter (fun (_, e) -> walker host_param host_locals e) fs
  in
  List.iter (fun (f : fn_decl) ->
    current_host := f.name;
    walk_in_fn f.param [f.param] f.body) fns;
  (* Also lift inner `let rec` in the top-level program expression, under the
     synthetic host "$main" — so a recursive helper written directly in main
     (not inside a fn) is lifted like a fn-body one instead of being rejected. *)
  current_host := "$main";
  walk_in_fn "" [] main_body;
  (* Phase 45 (DEFERRED §8): compute transitive capture closure to resolve
     mutual references between inner-lifted fns.

     Problem: when lifted fn A calls lifted fn B and B captures `base`,
     A's body emits `__lifted_B(base, ...)`, but `base` is not in A's
     scope so the C compile fails.

     Solution: make A also capture `base` transitively. Extend A's
     captures to direct captures + ⋃ (called inner fns' captures) and
     iterate to fixpoint. This adds a `base` field to A's env so A's
     body can access it via `env_self->base`. *)
  let all_lifted = List.rev !lifted in
  (* Reverse map from Mere name to lifted_name (used to walk Vars in bodies) *)
  let mere_to_lifted : (string, string) Hashtbl.t = Hashtbl.create 8 in
  Hashtbl.iter (fun mname entry ->
    Hashtbl.replace mere_to_lifted mname entry.lifted_name) inner_lifts;
  (* Hashtbl holding the latest captures for each lifted_name.
     NOTE: exclude inner-lifted fn names from direct captures (they are not
        runtime values; emit_expr expands them inline as `__lifted_X(caps, arg)`.
        Carrying them as captures would try to reference the helper identifier
        in C and fail). *)
  let captures_map : (string, (string * Ast.ty) list) Hashtbl.t =
    Hashtbl.create 8
  in
  List.iter (fun lf ->
    let filtered = List.filter (fun (n, _) ->
      not (Hashtbl.mem mere_to_lifted n)) lf.l_captures in
    Hashtbl.replace captures_map lf.l_name filtered)
    all_lifted;
  (* fixpoint loop *)
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter (fun lf ->
      (* Collect names of other inner-lifted fns referenced in lf's body *)
      let called_inner = ref [] in
      (* Resolve an inner-fn name to the lifted fn IN lf's OWN host. The
         global `inner_lifts` / `mere_to_lifted` is last-write-wins, so two
         hosts that each have a same-named inner fn (e.g. both a `loop`, as
         in contrib/json and contrib/csv) would otherwise collide: lf's
         recursive self-call would resolve to the *other* host's lifted fn,
         and lf would inherit its captures (a spurious variable → undeclared
         identifier at C compile time). Resolving per host fixes it. *)
      let lifted_in_host n =
        match Hashtbl.find_opt inner_lifts_by_host lf.l_host with
        | Some tbl ->
          (match Hashtbl.find_opt tbl n with
           | Some e -> Some e.lifted_name
           | None -> None)
        | None -> None
      in
      let rec scan (e : Ast.expr) =
        (match e.Ast.node with
         | Ast.Var n ->
           (match lifted_in_host n with
            | Some cl_name when cl_name <> lf.l_name ->
              if not (List.mem cl_name !called_inner) then
                called_inner := cl_name :: !called_inner
            | _ -> ())
         | _ -> ());
        walk_children (fun _ _ e -> scan e) "" [] e
      in
      scan lf.l_body;
      let cur_caps = Hashtbl.find captures_map lf.l_name in
      let new_caps = ref cur_caps in
      List.iter (fun called_lifted_name ->
        let other_caps = Hashtbl.find captures_map called_lifted_name in
        List.iter (fun (cap_n, cap_t) ->
          (* skip if cap_n matches lf's param (params don't need to be captured)
             skip if cap_n is another inner-lifted fn name (will be picked up
             transitively via another path)
             skip if cap_n is already in new_caps *)
          if cap_n = lf.l_param then ()
          else if Hashtbl.mem mere_to_lifted cap_n then ()
          else if List.mem_assoc cap_n !new_caps then ()
          else begin
            new_caps := !new_caps @ [(cap_n, cap_t)];
            changed := true
          end
        ) other_caps
      ) !called_inner;
      Hashtbl.replace captures_map lf.l_name !new_caps
    ) all_lifted
  done;
  (* Reflect the extended captures into all_lifted + inner_lifts_by_host *)
  let updated_lifted = List.map (fun lf ->
    let new_caps = Hashtbl.find captures_map lf.l_name in
    { lf with l_captures = new_caps }) all_lifted
  in
  Hashtbl.iter (fun _host tbl ->
    Hashtbl.iter (fun mere_n entry ->
      let new_caps = Hashtbl.find captures_map entry.lifted_name in
      Hashtbl.replace tbl mere_n { entry with captures = new_caps }
    ) tbl) inner_lifts_by_host;
  (* Also sync the old inner_lifts (last-write) — emit_expr reads it directly *)
  Hashtbl.iter (fun mere_n entry ->
    let new_caps = Hashtbl.find captures_map entry.lifted_name in
    Hashtbl.replace inner_lifts mere_n { entry with captures = new_caps }
  ) inner_lifts;
  updated_lifted


(* Walk the AST for `App (Var "show", arg)` calls and add each arg's
   type to `show_types` so emit_program can synthesize the right
   specialized show functions. Recurses into types so e.g. `show (1, 2)`
   also triggers show_int (for the elements). *)
let collect_show_types (root : Ast.expr) (fns : fn_decl list) : unit =
  let rec add_into tbl t =
    let t = Ast.walk t in
    if not (ty_is_concrete t) then ()
    else
      let tag = ty_tag t in
      (* Guard before recursion so recursive variants (e.g. list) don't
         infinite-loop through their self-referential payloads. *)
      if Hashtbl.mem tbl tag then ()
      else begin
        Hashtbl.add tbl tag t;
        match t with
        | Ast.TyTuple ts -> List.iter (add_into tbl) ts
        | Ast.TyArrow _ -> ()
        | Ast.TyCon (name, args) ->
          List.iter (add_into tbl) args;
          if Hashtbl.mem Typer.records name then
            let info = Hashtbl.find Typer.records name in
            List.iter (fun (_, ft) -> add_into tbl ft) info.Typer.r_fields
          else if Hashtbl.mem polymorphic_variants name then begin
            let (params, variants) = Hashtbl.find polymorphic_variants name in
            let svariants = subst_variants params args variants in
            List.iter (fun (_, arg_opt) ->
              match arg_opt with Some t -> add_into tbl t | None -> ()) svariants
          end
          else if Hashtbl.mem Typer.types name then begin
            let variants =
              Hashtbl.fold (fun cname (info : Typer.constr_info) acc ->
                if info.type_name = name then (cname, info.arg) :: acc else acc)
                Typer.constructors []
            in
            List.iter (fun (_, arg_opt) ->
              match arg_opt with Some t -> add_into tbl t | None -> ()) variants
          end
        | _ -> ()
      end
  in
  let add_with_deps t = add_into show_types t in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
       (match arg.Ast.ty with
        | Some t -> add_with_deps t
        | None -> ())
     | Ast.App ({ node = Ast.Var "to_json"; _ }, arg) ->
       (match arg.Ast.ty with
        | Some t -> add_into to_json_types t
        | None -> ())
     | Ast.App ({ node = Ast.Var "of_json"; _ }, _) ->
       (* of_json specializes on the RESULT type (this App node's ty). *)
       (match e.Ast.ty with
        | Some t -> add_into of_json_types t
        | None -> ())
     | Ast.App ({ node = Ast.Var "of_json_opt"; _ }, _) ->
       (* result is `T option`; the node decoder is for T, the option wrapper
          for `T option`. Register both. *)
       (match e.Ast.ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyCon ("option", [inner]) ->
             add_into of_json_types inner;
             let it = Ast.walk inner in
             Hashtbl.replace of_json_opt_types (ty_tag it) it
           | _ -> ())
        | None -> ())
     (* Structural == / != on a compound type needs eq_<tag> (and its deps). *)
     | Ast.Cmp ((Ast.Eq | Ast.Ne), a, _) ->
       (match a.Ast.ty with
        | Some t when needs_struct_eq t -> add_into eq_types t
        | _ -> ())
     (* v0.1.11 derive-ord: < <= > >= on a compound type needs cmp_<tag>
        (and its deps: field/element/payload compares down to scalars). *)
     | Ast.Cmp ((Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge), a, _) ->
       (match a.Ast.ty with
        | Some t when needs_struct_cmp t -> add_into cmp_types t
        | _ -> ())
     (* str_of_int lowers to show_int(), so ensure show_int is emitted even
        when the program never uses `show` directly (mq dogfood P9). *)
     | Ast.App ({ node = Ast.Var "str_of_int"; _ }, _) ->
       add_with_deps Ast.TyInt
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

(* Walk a typed AST + fn signatures to find every concrete instantiation
   of a polymorphic variant. Populates `mono_variant_instances`.
   `variant_decls` is the list of `Top_type (name, params, variants)`
   from the program — payload types declared there may contain
   polymorphic instantiations (`list (str * expr)`, `option pattern`,
   ...) that the expression-tree walk never sees, so the function also
   walks them. DEFERRED §8.3 fix (2026-06-26). *)
let collect_mono_variant_instances
    (root : Ast.expr) (fns : fn_decl list)
    (variant_decls : (string * string list * (string * Ast.ty option) list) list)
    : unit =
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
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty) fns;
  (* DEFERRED §8.3 fix: monomorphic variant decls (`type expr = | ELetRec
     of (str * expr) list * expr | ...`) declare payload types
     containing concrete `list T` / `option T` specializations whose
     typedefs the program never directly constructs. Walking the
     declarations here registers them. *)
  List.iter (fun (_name, params, variants) ->
    if params = [] then
      List.iter (fun (_cname, arg_opt) ->
        match arg_opt with Some t -> walk_ty t | None -> ()) variants
  ) variant_decls;
  (* Also walk substituted payload types of each collected instance so
     tuples that appear only inside variant payloads (e.g.
     `tuple_int_list_int` inside Cons) get found by later collectors.
     Run this AFTER the variant_decls walk so newly-registered
     specializations have their inner payloads walked too. *)
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
  let seen_records : (string, unit) Hashtbl.t = Hashtbl.create 4 in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyArrow (p, r) ->
      (* Walk children FIRST so simpler arrows are added before the
         outer arrow that references them — keeps C typedef ordering
         legal (typedef body needs prior types to be fully defined). *)
      walk_ty p; walk_ty r;
      add (Ast.walk p) (Ast.walk r)
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyCon (name, args) ->
      List.iter walk_ty args;
      (* Phase 16.3: also walk the field types of known records. For records
         like Logger / Metrics whose fields hold closure types, closure_X_Y
         only appears via a field, so we need arrow_pairs to pick those up. *)
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
    walk_ty f.param_ty; walk_ty f.return_ty;
    (* Phase 23.3: also include the fn's OWN arrow (param → return) so
       the closure_wrapper's `<fn>_as_value` typedef references an
       arrow type that's actually been declared. Multi-inst fns have
       fn_decls whose top-level arrow isn't visible in the original
       AST's annotations (since cloning happened in codegen). *)
    add (Ast.walk f.param_ty) (Ast.walk f.return_ty)) fns;
  List.rev !order

(* Walk a single type and return every concrete tuple shape it contains.
   Used at the call site in emit_program to register tuples that appear
   in monomorphic variant payload types (`ELogic of logicop * expr * expr`
   declares `tuple_logicop_expr_expr` even if no expression in the
   program annotates with that exact shape). Without this, the typedef
   would be missing and cc would complain about an undeclared type. *)
let collect_tuple_shapes_in_ty (root_ty : Ast.ty) : Ast.ty list list =
  let order = ref [] in
  let seen = Hashtbl.create 4 in
  let rec walk t =
    match Ast.walk t with
    | Ast.TyTuple ts ->
      if List.for_all ty_is_concrete ts then begin
        let key = tuple_struct_name ts in
        if not (Hashtbl.mem seen key) then begin
          Hashtbl.add seen key ();
          order := ts :: !order
        end
      end;
      List.iter walk ts
    | Ast.TyArrow (a, b) -> walk a; walk b
    | Ast.TyCon (_, args) -> List.iter walk args
    | Ast.TyRef (_, _, inner) -> walk inner
    | _ -> ()
  in
  walk root_ty;
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
    | Ast.Ref (_, _, a) -> walk_expr a
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
    | Ast.Ref (_, _, a) -> walk_expr a
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
       types accept forward-declared structs). Phase 42: convert
       M-qualified record type names (`Shapes.Rect`) to C identifiers
       (`Shapes__Rect`). *)
    let cn = c_safe_name name in
    Printf.sprintf "typedef struct %s %s;" cn cn

let emit_record_struct_body (name : string) : string =
  let info = Hashtbl.find Typer.records name in
  if info.Typer.r_params <> [] then ""
  else
    let fields =
      List.map (fun (fname, ft) ->
        Printf.sprintf "  %s %s;" (c_type_of ft) fname) info.Typer.r_fields
    in
    Printf.sprintf "struct %s {\n%s\n};" (c_safe_name name)
      (String.concat "\n" fields)

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
    | Ast.TyRef (_, _, inner) -> mentions inner
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
  let () =
    (* Phase 36 (DEFERRED §1.17 fix): user shadowing a builtin polymorphic
       variant (e.g. `type result = Won | Draw`) — drop the stale builtin
       entry so later lookups don't see params=['a, 'e] mismatched with
       the 0-arg shadowing. *)
    if Hashtbl.mem polymorphic_variants name then
      Hashtbl.remove polymorphic_variants name
  in
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
        | Ast.TyRef (_, _, inner) -> ty_mentions inner
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

(* Q-012: per-element-type channel runtime. A heap-allocated ring buffer
   guarded by a mutex + condition variable; recv blocks until an element is
   available. Element tag `tag`, C element type `cty`. *)
let emit_channel_runtime_for (elem_ty : Ast.ty) : string =
  let tag = ty_tag elem_ty in
  let cty = c_type_of elem_ty in
  let s = "mere_channel_" ^ tag in
  String.concat "\n"
    [ Printf.sprintf "typedef struct %s {" s;
      Printf.sprintf "  %s* buf;" cty;
      "  int len; int cap; int head;";
      "  pthread_mutex_t m;";
      "  pthread_cond_t c;";
      Printf.sprintf "} %s;" s;
      "";
      Printf.sprintf "static %s* %s_new(void) {" s s;
      Printf.sprintf "  %s* ch = (%s*)malloc(sizeof(%s));" s s s;
      "  ch->cap = 8; ch->len = 0; ch->head = 0;";
      Printf.sprintf "  ch->buf = (%s*)malloc(sizeof(%s) * (size_t)ch->cap);" cty cty;
      "  pthread_mutex_init(&ch->m, NULL);";
      "  pthread_cond_init(&ch->c, NULL);";
      "  return ch;";
      "}";
      "";
      Printf.sprintf "static int %s_send(%s* ch, %s v) {" s s cty;
      "  pthread_mutex_lock(&ch->m);";
      "  if (ch->len == ch->cap) {";
      "    int nc = ch->cap * 2;";
      Printf.sprintf "    %s* nb = (%s*)malloc(sizeof(%s) * (size_t)nc);" cty cty cty;
      "    for (int i = 0; i < ch->len; i++) nb[i] = ch->buf[(ch->head + i) % ch->cap];";
      "    free(ch->buf); ch->buf = nb; ch->head = 0; ch->cap = nc;";
      "  }";
      "  ch->buf[(ch->head + ch->len) % ch->cap] = v;";
      "  ch->len++;";
      "  pthread_cond_signal(&ch->c);";
      "  pthread_mutex_unlock(&ch->m);";
      "  return 0;";
      "}";
      "";
      Printf.sprintf "static %s %s_recv(%s* ch) {" cty s s;
      "  pthread_mutex_lock(&ch->m);";
      "  while (ch->len == 0) pthread_cond_wait(&ch->c, &ch->m);";
      Printf.sprintf "  %s v = ch->buf[ch->head];" cty;
      "  ch->head = (ch->head + 1) % ch->cap;";
      "  ch->len--;";
      "  pthread_mutex_unlock(&ch->m);";
      "  return v;";
      "}" ]

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
  Hashtbl.reset inner_lift_closures_emitted;
  inner_lift_closure_pending := [];
  Hashtbl.reset mono_record_instances;
  Hashtbl.reset vec_instances;
  Hashtbl.reset owned_vec_instances;
  Hashtbl.reset channel_instances;
  Hashtbl.reset map_instances;
  Hashtbl.reset extern_fn_decls;
  (* Phase 32.2 (C1 FFI): walk prog.decls to register extern fn names + types. *)
  List.iter (fun decl ->
    match decl with
    | Ast.Top_extern (name, ty) ->
      Hashtbl.replace extern_fn_decls name (Ast.walk ty)
    | _ -> ()
  ) prog.decls;
  strbuf_used := false;
  logger_used := false;
  metrics_used := false;
  str_split_used := false;
  str_join_used := false;
  list_dir_used := false;
  args_used := false;
  let variant_decls =
    (* Phase 36 (DEFERRED §1.17 fix): dedupe by name keeping LAST occurrence
       so user-side `type result = ...` shadows the builtin entry. *)
    let raw = List.filter_map (fun decl ->
      match decl with
      | Ast.Top_type (name, params, variants) -> Some (name, params, variants)
      | _ -> None) prog.decls
    in
    let last_of_name = Hashtbl.create 16 in
    List.iter (fun ((name, _, _) as e) ->
      Hashtbl.replace last_of_name name e) raw;
    let emitted = Hashtbl.create 16 in
    List.filter (fun (name, _, _) ->
      if Hashtbl.mem emitted name then false
      else begin
        Hashtbl.add emitted name ();
        true
      end) (List.map (fun (n, _, _) -> Hashtbl.find last_of_name n) raw)
  in
  let variant_typedefs =
    List.map (fun (name, params, variants) ->
      emit_variant_typedef name params variants) variant_decls
  in
  let variant_typedefs =
    List.filter (fun s -> s <> "") variant_typedefs
  in
  let _ = (* unused — replaced by unified_struct_bodies (Phase 22.5) *)
    List.filter_map (fun (name, _, variants) ->
      emit_variant_struct_body name variants) variant_decls
  in
  let main_expr = Ast.desugar_program prog in
  (* Phase 15.2: resolve let-bound Vec element types.
     `let v = vec_new () in body` generalizes v to `forall T. Vec[..., T]`,
     so each use of v in body gets a *fresh* element tyvar. Some of those
     tyvars get linked to a concrete type (e.g., `vec_push v 10` links to
     int), others stay unlinked (e.g., `vec_len v` doesn't constrain the
     element).
     Strategy: for each `Let(P_var name, value, body)` whose value.ty is
     a Vec, walk body and unify value.ty with every `Var name`.ty
     encountered. unify chains the tyvars together, so once any one is
     resolved (by e.g. vec_push), all others share that resolution. *)
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
         | Ast.P_var n when n = name -> ()  (* shadowed *)
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
  let skels, body_expr = lift_fn_skels main_expr in
  (* Phase 30.2 (DEFERRED §1.10 fix): extract top-level non-fn `let X = E`
     bindings from the post-lift body and emit as file-scope C globals,
     initialized at main start, so top-level fn bodies can reference them.
     Only lets whose name appears in some skel's free_vars get globalized,
     otherwise they stay as __let_tmp_X in main (preserving existing
     behavior for programs that don't need globals). *)
  let fvs_used_in_skels =
    List.fold_left (fun acc s ->
      let fvs = free_vars s.sbody [s.sparam] in
      List.sort_uniq compare (fvs @ acc))
      [] skels
  in
  let needs_global name = List.mem name fvs_used_in_skels in
  (* Phase 36 (DEFERRED §1.18 fix): keep the Let bindings in body_expr
     so global init happens at the SOURCE-ORDER position (interleaved
     with side-effecting code in main_body), not pre-emitted upfront
     where dependent reads (e.g. `let n = owned_vec_len names` after a
     map_iter that populates names) would see stale empty values.
     We still record (name, ty) for emitting the file-scope `static T X;`
     declaration. *)
  let top_globals_list =
    let rec go e =
      match e.Ast.node with
      | Ast.Let (pat, value, rest) ->
        (match pat.Ast.pnode with
         | Ast.P_var name when needs_global name ->
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
  Hashtbl.reset top_globals;
  List.iter (fun (n, _, _) -> Hashtbl.add top_globals n ()) top_globals_list;
  (* Phase 24.2: dedup skels by name keeping the LAST occurrence — this
     handles shadowing (e.g., user defines `let rec list_iter = ...` that
     shadows the prelude's `list_iter`). Without dedup, both end up in
     `fns` with the same name, the prelude's body would emit and the
     user's body would emit a duplicate (with possibly unresolved tyvars
     since find_concrete_arrow only links the first). *)
  let skels =
    let seen : (string, unit) Hashtbl.t = Hashtbl.create 8 in
    List.rev (
      List.filter (fun s ->
        if Hashtbl.mem seen s.sname then false
        else (Hashtbl.add seen s.sname (); true)
      ) (List.rev skels)
    )
  in
  let fns = resolve_fn_types skels main_expr in
  (* Populate toplevel_fn_names so emit_expr can pick direct vs closure
     call and value-position references can use the closure wrapper. *)
  Hashtbl.reset toplevel_fn_names;
  List.iter (fun f -> Hashtbl.replace toplevel_fn_names f.name ()) fns;
  (* Phase 23.3: also register the unmangled SKEL names so call sites
     `Ast.Var "rev_aux"` (which use the original Mere name) hit the
     toplevel_fn_names branch and get dispatched (then mangled by
     multi_inst_fns lookup). *)
  List.iter (fun s -> Hashtbl.replace toplevel_fn_names s.sname ()) skels;
  (* Polymorphic variant monomorphization: collect concrete
     instantiations from the AST + fn signatures, then emit specialized
     typedefs (forward+ptr for recursive instances, full struct for
     non-recursive). Bodies come after tuple/record typedefs. *)
  Hashtbl.reset show_types;
  Hashtbl.reset to_json_types;
  Hashtbl.reset of_json_types;
  Hashtbl.reset of_json_opt_types;
  Hashtbl.reset eq_types;
  Hashtbl.reset cmp_types;
  (* Pre-populate polymorphic_records so the collector sees them. The
     typedef emission itself (which depends on c_type_of being correct
     for nested types) happens later via mono_record_typedefs. *)
  Hashtbl.iter (fun rname (info : Typer.record_info) ->
    if info.r_params <> [] then
      Hashtbl.replace polymorphic_records rname
        (info.r_params, info.r_fields))
    Typer.records;
  collect_mono_variant_instances main_expr fns variant_decls;
  collect_show_types main_expr fns;
  let mono_variant_typedefs =
    Hashtbl.fold (fun _ (vn, args) acc ->
      emit_mono_variant_typedef vn args :: acc) mono_variant_instances []
  in
  (* Phase 36 (DEFERRED §1.20 fix): mono variant / record struct bodies
     are now emitted through the unified topo-sorted pipeline below, not
     here. Keep this empty to avoid duplicate emission. *)
  let mono_variant_struct_bodies = ([] : string list) in
  let mono_record_typedefs =
    Hashtbl.fold (fun _ (rn, args) acc ->
      emit_mono_record_typedef rn args :: acc) mono_record_instances []
  in
  let mono_record_struct_bodies = ([] : string list) in
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
    (* DEFERRED §8.3 fix (2026-06-26): also pull tuple shapes out of
       MONOMORPHIC variant declarations. `collect_tuple_shapes` walks
       expression `.ty` annotations and fn signatures, but a variant
       declared `EBin of binop * expr * expr` registers a struct field
       of type `tuple_binop_expr_expr` regardless of whether the
       program's expression tree ever annotates a node with that exact
       shape — so without this step, `emit_variant_typedef` emits a
       struct referencing an undeclared tuple typedef. Phase 49.1's
       original bug (`tuple_logicop_expr_expr`) regressed in 50.7 when
       ast.mere lifted the parser's superset of variants into shared
       scope; this restores the C backend for parser.mere + fmt.mere. *)
    let from_variant_decls =
      List.concat_map (fun (_name, params, variants) ->
        if params <> [] then []
        else
          List.concat_map (fun (_cname, arg_opt) ->
            match arg_opt with
            | Some t -> collect_tuple_shapes_in_ty t
            | None -> []
          ) variants
      ) variant_decls
    in
    let all = from_expr @ from_fns @ from_variants @ from_variant_decls in
    (* Dedup by struct name. *)
    let seen = Hashtbl.create 8 in
    let deduped =
      List.filter (fun ts ->
        let k = tuple_struct_name ts in
        if Hashtbl.mem seen k then false
        else (Hashtbl.add seen k (); true)
      ) all
    in
    (* Phase 22.4: topo sort so a tuple shape with a tuple-typed field
       has its inner-tuple struct body emitted FIRST. C requires complete
       struct types at point of use in field declarations. *)
    let name_index : (string, Ast.ty list) Hashtbl.t = Hashtbl.create 8 in
    List.iter (fun ts -> Hashtbl.add name_index (tuple_struct_name ts) ts) deduped;
    let visited : (string, unit) Hashtbl.t = Hashtbl.create 8 in
    let result = ref [] in
    let rec visit ts =
      let k = tuple_struct_name ts in
      if not (Hashtbl.mem visited k) then begin
        Hashtbl.add visited k ();
        List.iter (fun elem ->
          match Ast.walk elem with
          | Ast.TyTuple _ as inner ->
            let dep_name = tuple_struct_name (
              match inner with Ast.TyTuple ts -> ts | _ -> []) in
            (match Hashtbl.find_opt name_index dep_name with
             | Some dep_ts -> visit dep_ts
             | None -> ())
          | _ -> ()
        ) ts;
        result := ts :: !result
      end
    in
    List.iter visit deduped;
    List.rev !result
  in
  let tuple_typedefs = List.map emit_tuple_typedef tuple_shapes in
  let record_names = collect_record_names main_expr fns in
  let record_typedefs = List.map emit_record_typedef record_names in
  (* Phase 22.5: unified topo sort across all struct bodies (tuples,
     non-recursive variants, recursive variants, records). Deps reflect
     "this struct needs the complete body of X". Pointer-typed refs
     (recursive variants, which typedef to `*_node*`) don't introduce
     deps — only forward decls matter for those.

     We collect a list of (name, body, deps), then topo-sort and emit. *)
  let ty_deps (t : Ast.ty) : string list =
    match Ast.walk t with
    | Ast.TyTuple ts -> [tuple_struct_name ts]
    (* Phase 36 (DEFERRED §1.20 fix): polymorphic variant / record
       instances must use their mono struct name (e.g. option_Row),
       not the type-cons name (opt). Check polymorphic_variants /
       polymorphic_records BEFORE the variant_decls / records check. *)
    | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
      let args' = List.map Ast.walk args in
      if List.for_all ty_is_concrete args'
         && not (is_recursive_variant (mono_variant_name n args'))
      then [mono_variant_name n args']
      else []
    | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
      let args' = List.map Ast.walk args in
      if List.for_all ty_is_concrete args'
      then [mono_record_name n args']
      else []
    | Ast.TyCon (n, _) when is_recursive_variant n -> []  (* pointer *)
    | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n -> [n]
    | Ast.TyCon (n, _) when List.exists (fun (vn, _, _) -> vn = n) variant_decls -> [n]
    | _ -> []
  in
  let variant_deps_of name variants =
    let node_name = if is_recursive_variant name then name ^ "_node" else name in
    let payload_deps =
      List.concat_map (fun (_, arg_opt) ->
        match arg_opt with
        | None -> []
        | Some t -> ty_deps t) variants
    in
    (node_name, payload_deps)
  in
  let tuple_deps_of shape =
    let name = tuple_struct_name shape in
    let elem_deps = List.concat_map ty_deps shape in
    (name, elem_deps)
  in
  let record_deps_of name =
    let info = Hashtbl.find Typer.records name in
    let field_deps =
      List.concat_map (fun (_, t) -> ty_deps t) info.Typer.r_fields
    in
    (name, field_deps)
  in
  (* Build the node list *)
  let nodes : (string * string * string list) list ref = ref [] in
  List.iter (fun (name, _, variants) ->
    match emit_variant_struct_body name variants with
    | Some body ->
      let (n, deps) = variant_deps_of name variants in
      nodes := (n, body, deps) :: !nodes
    | None -> ()
  ) variant_decls;
  List.iter (fun shape ->
    let body = emit_tuple_struct_body shape in
    let (n, deps) = tuple_deps_of shape in
    nodes := (n, body, deps) :: !nodes
  ) tuple_shapes;
  List.iter (fun name ->
    let body = emit_record_struct_body name in
    if body <> "" then begin
      let (n, deps) = record_deps_of name in
      nodes := (n, body, deps) :: !nodes
    end
  ) record_names;
  (* Phase 36 (DEFERRED §1.20 fix): mono polymorphic variant / record
     bodies (e.g. option_Row) also participate in the topo sort. Without
     this, tuple/record bodies that have an option_Row field get emitted
     before option_Row itself → "field has incomplete type" at clang. *)
  Hashtbl.iter (fun _ (vn, args) ->
    match emit_mono_variant_struct_body vn args with
    | Some body ->
      let svariants =
        let (params, variants) = Hashtbl.find polymorphic_variants vn in
        subst_variants params args variants
      in
      let recursive = mono_variant_is_recursive vn args svariants in
      let node_name =
        if recursive then mono_variant_name vn args ^ "_node"
        else mono_variant_name vn args
      in
      let deps =
        List.concat_map (fun (_, arg_opt) ->
          match arg_opt with
          | None -> []
          | Some t -> ty_deps t) svariants
      in
      nodes := (node_name, body, deps) :: !nodes
    | None -> ()
  ) mono_variant_instances;
  Hashtbl.iter (fun _ (rn, args) ->
    let body = emit_mono_record_struct_body rn args in
    if body <> "" then begin
      let (params, fields) = Hashtbl.find polymorphic_records rn in
      let mapping = List.combine params args in
      let deps =
        List.concat_map (fun (_, ft) ->
          ty_deps (subst_params mapping ft)) fields
      in
      nodes := (mono_record_name rn args, body, deps) :: !nodes
    end
  ) mono_record_instances;
  (* Topo sort *)
  let name_to_node : (string, string * string list) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (n, b, d) -> Hashtbl.add name_to_node n (b, d)) !nodes;
  let visited : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let sorted_bodies = ref [] in
  let rec visit n =
    if Hashtbl.mem visited n then ()
    else begin
      Hashtbl.add visited n ();
      match Hashtbl.find_opt name_to_node n with
      | None -> ()
      | Some (body, deps) ->
        List.iter visit deps;
        sorted_bodies := body :: !sorted_bodies
    end
  in
  List.iter (fun (n, _, _) -> visit n) !nodes;
  let unified_struct_bodies = List.rev !sorted_bodies in
  (* Keep these two empty so the parts list later sees no leftover bodies
     in the per-category positions — we emit everything via
     unified_struct_bodies. *)
  let record_struct_bodies = [] in
  let tuple_struct_bodies = [] in
  let _ = record_struct_bodies in
  let _ = tuple_struct_bodies in
  (* Closure / inner-fn lifting (defunctionalization). Done AFTER
     top-level fn types are resolved so we know toplevel names. *)
  (* Phase 23.3: include skel names too — multi-inst fns have mangled
     fn names in `fns` (e.g., rev__list_json), but call sites in inner
     fn bodies use the original Mere name (`rev`). lift_inner_fns must
     see these as "globals" to NOT include them in captures. *)
  let toplevel_names =
    List.map (fun f -> f.name) fns @ List.map (fun s -> s.sname) skels in
  let inner_fns = lift_inner_fns toplevel_names fns body_expr in
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
  (* Phase 36 (DEFERRED §1.18 fix): globals are now initialized inline
     in main_body (the Let bindings stayed in body_expr), so we no longer
     pre-emit init code. Only the file-scope declarations are emitted. *)
  let top_global_inits = ([] : string list) in
  let top_global_decls =
    List.map (fun (name, _, ty) ->
      Printf.sprintf "static %s %s;" (c_type_of ty) (c_safe_name name))
      top_globals_list
  in
  (* main's own inner-lifted fns live under host "$main" (see lift_inner_fns). *)
  set_inner_lifts_for_host "$main";
  let main_body = emit_expr body_expr in
  (* Phase 15.5: main_body may contain anonymous `Fun` nodes that push
     additional closure adapters onto pending_closures (e.g.,
     `vec_iter v (fn x -> ...)`). Drain again so the env typedefs and
     adapter definitions are emitted. *)
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
  let to_json_fn_forward_decls =
    Hashtbl.fold (fun tag t acc ->
      emit_to_json_fn_forward_decl tag t :: acc) to_json_types []
  in
  let to_json_fn_defs =
    Hashtbl.fold (fun tag t acc ->
      emit_to_json_fn tag t :: acc) to_json_types []
  in
  let of_json_fn_forward_decls =
    Hashtbl.fold (fun tag t acc ->
      emit_of_json_fn_forward_decl tag t :: acc) of_json_types []
  in
  let of_json_fn_defs =
    Hashtbl.fold (fun tag t acc ->
      emit_of_json_fn tag t :: acc) of_json_types []
  in
  let of_json_opt_fn_forward_decls =
    Hashtbl.fold (fun tag t acc ->
      emit_of_json_opt_fn_forward_decl tag t :: acc) of_json_opt_types []
  in
  let of_json_opt_fn_defs =
    Hashtbl.fold (fun tag t acc ->
      emit_of_json_opt_fn tag t :: acc) of_json_opt_types []
  in
  let eq_fn_forward_decls =
    Hashtbl.fold (fun tag t acc ->
      emit_eq_fn_forward_decl tag t :: acc) eq_types []
  in
  let eq_fn_defs =
    Hashtbl.fold (fun tag t acc ->
      emit_eq_fn tag t :: acc) eq_types []
  in
  let cmp_fn_forward_decls =
    Hashtbl.fold (fun tag t acc ->
      emit_cmp_fn_forward_decl tag t :: acc) cmp_types []
  in
  let cmp_fn_defs =
    Hashtbl.fold (fun tag t acc ->
      emit_cmp_fn tag t :: acc) cmp_types []
  in
  (* Phase 36 (DEFERRED §1.19 fix, C side): forward declare each fn's
     `<name>_as_value` closure constant so fn bodies that reference a
     top-level fn as a first-class value (e.g. `list_filter xs is_prime`)
     can link properly. The full definition is in closure_wrappers, which
     is emitted after fn_defs_main. *)
  let closure_wrapper_forward_decls =
    List.map (fun (f : fn_decl) ->
      let cstruct = closure_struct_name f.param_ty f.return_ty in
      Printf.sprintf "extern const %s %s_as_value;" cstruct (c_safe_name f.name))
      fns
  in
  (* Phase 39.A2: generate env typedef + adapter body for each
     inner-lifted fn used as a value. *)
  let inner_lift_closure_decls =
    List.rev_map (fun (lifted_name, captures, _arg_ty, _ret_ty) ->
      let env_struct_name = lifted_name ^ "_env" in
      let env_fields =
        if captures = [] then "char __unused;"  (* ensure sizeof > 0 even with 0 captures *)
        else
          String.concat " "
            (List.map (fun (n, ty) ->
               Printf.sprintf "%s %s;" (c_type_of ty) (c_safe_name n))
               captures)
      in
      Printf.sprintf "typedef struct { %s } %s;" env_fields env_struct_name
    ) !inner_lift_closure_pending
  in
  let inner_lift_closure_adapter_forward_decls =
    List.rev_map (fun (lifted_name, _captures, arg_ty, ret_ty) ->
      let adapter_name = lifted_name ^ "_inner_closure_fn" in
      Printf.sprintf "static %s %s(void* __env_p, %s __inner_arg);"
        (c_type_of ret_ty) adapter_name (c_type_of arg_ty)
    ) !inner_lift_closure_pending
  in
  let forward_decls =
    List.map emit_fn_forward_decl fns
    @ List.map emit_lifted_fn_forward_decl inner_fns
    @ closure_adapter_forward_decls
    @ closure_wrapper_forward_decls
    @ show_fn_forward_decls
    @ to_json_fn_forward_decls
    (* of_json: the JSON-parser runtime (defines mj_node) must precede the
       __ojnode_<tag> forward decls that reference it. Emitted when either
       of_json or of_json_opt is used. *)
    @ (if Hashtbl.length of_json_types = 0 && Hashtbl.length of_json_opt_types = 0
       then []
       else of_json_runtime :: (of_json_fn_forward_decls @ of_json_opt_fn_forward_decls))
    @ eq_fn_forward_decls
    @ cmp_fn_forward_decls
    @ inner_lift_closure_adapter_forward_decls
  in
  let inner_lift_closure_adapters =
    List.rev_map (fun (lifted_name, captures, arg_ty, ret_ty) ->
      let env_struct_name = lifted_name ^ "_env" in
      let adapter_name = lifted_name ^ "_inner_closure_fn" in
      let unpack =
        String.concat " "
          (List.map (fun (n, _) ->
             Printf.sprintf "__auto_type %s = __env_self->%s;"
               (c_safe_name n) (c_safe_name n))
             captures)
      in
      let cap_args =
        String.concat ", "
          (List.map (fun (n, _) -> c_safe_name n) captures
           @ [c_safe_name "__inner_arg"])
      in
      Printf.sprintf
        "static %s %s(void* __env_p, %s %s) { %s* __env_self = __env_p; (void)__env_self; %s return %s(%s); }"
        (c_type_of ret_ty) adapter_name (c_type_of arg_ty)
        (c_safe_name "__inner_arg")
        env_struct_name unpack lifted_name cap_args
    ) !inner_lift_closure_pending
  in
  let fn_defs =
    fn_defs_main
    @ closure_adapters
    @ closure_wrappers
    @ show_fn_defs
    @ to_json_fn_defs
    @ of_json_fn_defs
    @ of_json_opt_fn_defs
    @ eq_fn_defs
    @ cmp_fn_defs
    @ inner_lift_closure_adapters
  in
  (* Phase 15.2: vec_instances is populated during fn / main emission
     via c_type_of and emit_expr. Emit one runtime block per element
     type now, after main_body has run through emit_expr. *)
  let vec_runtimes =
    Hashtbl.fold (fun _tag elem_ty acc ->
      emit_vec_runtime_for elem_ty :: acc) vec_instances []
  in
  let owned_vec_runtimes =
    Hashtbl.fold (fun _tag elem_ty acc ->
      emit_owned_vec_runtime_for elem_ty :: acc) owned_vec_instances []
  in
  let channel_runtimes =
    Hashtbl.fold (fun _tag elem_ty acc ->
      emit_channel_runtime_for elem_ty :: acc) channel_instances []
  in
  let channel_forward_typedefs =
    Hashtbl.fold (fun tag _ acc ->
      Printf.sprintf "typedef struct mere_channel_%s mere_channel_%s;" tag tag :: acc)
      channel_instances []
  in
  let map_runtimes =
    Hashtbl.fold (fun _key (k_ty, v_ty) acc ->
      emit_map_runtime_for k_ty v_ty :: acc) map_instances []
  in
  let map_forward_typedefs =
    Hashtbl.fold (fun _key (k_ty, v_ty) acc ->
      let k_tag = ty_tag k_ty and v_tag = ty_tag v_ty in
      Printf.sprintf "typedef struct mere_map_%s_%s mere_map_%s_%s;"
        k_tag v_tag k_tag v_tag :: acc) map_instances []
  in
  (* Forward typedefs so closure typedefs / fn forward decls can
     reference `mere_vec_T*` / `mere_owned_vec_T*` before the runtime
     struct body appears. *)
  let vec_forward_typedefs =
    Hashtbl.fold (fun tag _ acc ->
      Printf.sprintf "typedef struct mere_vec_%s mere_vec_%s;" tag tag :: acc)
      vec_instances []
  in
  let owned_vec_forward_typedefs =
    Hashtbl.fold (fun tag _ acc ->
      Printf.sprintf "typedef struct mere_owned_vec_%s mere_owned_vec_%s;" tag tag :: acc)
      owned_vec_instances []
  in
  let main_stmt =
    match main_format_of main_ty with
    | None -> "  (void)(" ^ main_body ^ ");  /* unit result */"
    | Some "()" ->
      (* Phase 27.0: unit main — evaluate body for side effects, then
         print "()\n" to match interp's Eval.to_string V_unit output. *)
      "  (void)(" ^ main_body ^ ");\n  printf(\"()\\n\");"
    | Some "%g" ->
      (* Phase 34.1: float main — go through the __lang_str_of_float helper
         to match interp's string_of_float (OCaml's %.12g + a trailing `.`
         for integer-valued floats). *)
      "  puts(__lang_str_of_float(" ^ main_body ^ "));"
    | Some fmt -> "  printf(\"" ^ fmt ^ "\\n\", " ^ main_body ^ ");"
  in
  let parts =
    [ "#include <stdio.h>";
      "#include <stdlib.h>";
      "#include <string.h>";
      "#include <setjmp.h>";
      "#include <math.h>";  (* Phase 34.4: sqrt / sin / cos / tan / pow / atan2 *)
      "#include <pthread.h>";  (* Q-012: spawn / join. Link with -pthread on Linux. *)
      "#include <unistd.h>";   (* native FFI: read / write / close *)
      "";
      (* Stage 1 native full-stack: if any Wasm-memory-model FFI extern
         (tcp_* / mem_* / str_ptr) is used, emit the native runtime that
         backs them (a flat byte arena + POSIX sockets) instead of leaving
         them as unresolved `extern` prototypes. *)
      (if Hashtbl.fold (fun n _ acc -> acc || is_native_ffi n)
            extern_fn_decls false
       then native_ffi_runtime ^ "\n"
       else "");
      region_runtime_helpers;
      "";
      (* Q-012: concurrency runtime. `spawn` runs a `unit -> unit` closure on a
         fresh OS thread; the trampoline invokes the closure the same way the
         rest of the codegen does (c.fn(c.env, 0), unit == int 0). A
         ThreadHandle wraps the pthread_t so `join` can wait on it. NOTE: this
         MVP supports closures that capture nothing (env == NULL); captured
         env lives in the shared region allocator, whose thread-safety is a
         separate design item (see internal notes, Q-012-C-mem). *)
      "typedef struct { pthread_t tid; } ThreadHandle;";
      "typedef struct { void* env; int (*fn)(void*, int); } __mere_unit_closure;";
      "static void* __mere_spawn_trampoline(void* __p) {";
      "  __mere_unit_closure* __c = (__mere_unit_closure*)__p;";
      "  __c->fn(__c->env, 0);";
      "  free(__c);";
      "  return NULL;";
      "}";
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
    (* Forward typedef of Vec[R, T] / OwnedVec[T] / StrBuf[R] runtime
       structs so closure typedefs (which may carry these values) can
       compile before the full runtime struct body is emitted. *)
    @ (if vec_forward_typedefs = [] then [] else vec_forward_typedefs @ [""])
    @ (if owned_vec_forward_typedefs = [] then []
       else owned_vec_forward_typedefs @ [""])
    @ (if channel_forward_typedefs = [] then []
       else channel_forward_typedefs @ [""])
    @ (if !strbuf_used then
         ["typedef struct mere_strbuf mere_strbuf;"; ""]
       else [])
    @ (if map_forward_typedefs = [] then []
       else map_forward_typedefs @ [""])
    (* Closure typedefs reference user struct names (e.g.,
       `closure_int_Conn`) but only via function pointer types, which C
       accepts with forward-declared structs. *)
    @ (if closure_typedefs = [] then [] else closure_typedefs @ [""])
    (* Stage 3 native full-stack: emit the native HTTP server after the
       closure typedefs (http_serve takes a `closure_str_str` handler). *)
    @ (if Hashtbl.fold (fun n _ acc -> acc || List.mem n native_http_names)
            extern_fn_decls false
       then [native_http_runtime; ""]
       else [])
    (* Now the struct bodies themselves — fields may reference closure
       types (e.g., `closure_unit_unit close;` inside a Drop record), so
       these need to come AFTER closure typedefs.

       §1.8 fix: variant struct bodies must come BEFORE record struct
       bodies, because records can have variant-typed fields (e.g.,
       `Tx { kind: tx_kind }` in inventory.mere), and C requires the
       field type to have a complete struct body at the point of use. *)
    (* Phase 22.5: unified topo-sorted struct bodies (tuples + non-rec
       variants + recursive variants + records) — replaces the per-
       category ordering. mono_variant / mono_record specializations
       are still emitted separately below since they're generated by
       a different code path. *)
    @ (if unified_struct_bodies = [] then [] else unified_struct_bodies @ [""])
    @ (if mono_variant_struct_bodies = [] then [] else mono_variant_struct_bodies @ [""])
    @ (if mono_record_struct_bodies = [] then [] else mono_record_struct_bodies @ [""])
    @ (if closure_env_typedefs = [] then [] else closure_env_typedefs @ [""])
    @ (if inner_lift_closure_decls = [] then []
       else inner_lift_closure_decls @ [""])
    (* Vec[R, T] / OwnedVec[T] / StrBuf[R] runtime — depends on the
       element type's C struct being complete, so emit after tuple /
       record / variant bodies. OwnedVec registry first (each _new references it). *)
    @ (if vec_runtimes = [] then [] else vec_runtimes @ [""])
    @ (if owned_vec_runtimes = [] then []
       else owned_vec_registry_runtime :: "" :: owned_vec_runtimes @ [""])
    @ (if channel_runtimes = [] then [] else channel_runtimes @ [""])
    @ (if !strbuf_used then [strbuf_runtime; ""] else [])
    @ (if map_runtimes = [] then [] else map_runtimes @ [""])
    (* Phase 16.3: Logger / Metrics runtime — depends on Logger /
       Metrics struct bodies (= records) and closure_str_unit /
       closure_int_unit typedefs, so emit after struct bodies. *)
    @ (if !logger_used then [logger_runtime; ""] else [])
    @ (if !metrics_used then [metrics_runtime; ""] else [])
    (* Phase 24.3: str_split / str_join — references list_str_node so
       emit after mono variant bodies (= list_str). *)
    @ (if !str_split_used || !str_join_used || !list_dir_used || !args_used then [str_list_helpers; ""] else [])
    @ (if forward_decls = [] then [] else forward_decls @ [""])
    @ (let extern_decls =
         Hashtbl.fold (fun name ty acc ->
           (* Native FFI externs (tcp_* / mem_* / str_ptr) get a `static`
              definition from native_ffi_runtime above — skip the `extern`
              prototype here so the two don't collide. *)
           if is_native_ffi name then acc else
           (* Map a Mere arrow type to a C extern declaration.
              int -> int      becomes  int <name>(int);
              unit -> int     becomes  int <name>(void);
              int -> unit     becomes  void <name>(int);
              str -> int      becomes  int <name>(const char ptr); *)
           let rec flatten t =
             match Ast.walk t with
             | Ast.TyArrow (p, r) ->
               let args, ret = flatten r in
               Ast.walk p :: args, ret
             | _ -> [], Ast.walk t
           in
           let args, ret = flatten ty in
           let c_param_ty = function
             | Ast.TyStr -> "const char*"
             | t -> c_type_of t
           in
           (* Phase 32.2: emit return str as `char*` (libc functions like
              getenv return char*; Mere internally uses const char*, so the
              implicit const conversion absorbs the difference). unit return
              becomes void. *)
           let c_ret = match ret with
             | Ast.TyUnit -> "void"
             | Ast.TyStr -> "char*"
             | t -> c_type_of t
           in
           let c_args =
             let real_args = List.filter (fun t -> t <> Ast.TyUnit) args in
             if real_args = [] then "void"
             else String.concat ", " (List.map c_param_ty real_args)
           in
           Printf.sprintf "extern %s %s(%s);" c_ret name c_args :: acc)
           extern_fn_decls []
       in
       if extern_decls = [] then []
       else "/* Phase 32.2 (C1 FFI): extern fn declarations */"
            :: extern_decls @ [""])
    @ (if top_global_decls = [] then []
       else "/* Phase 30.2: top-level non-fn let values as file-scope globals */"
            :: top_global_decls @ [""])
    @ (if fn_defs = [] then [] else fn_defs @ [""])
    @ (let eta_lines =
         Hashtbl.fold (fun adapter (builtin, ret_ty) acc ->
           (* Generate static adapter fn + const value for the eta-wrapped
              nullary factory builtin. *)
           let ret_c = c_type_of ret_ty in
           let cstruct = closure_struct_name Ast.TyUnit ret_ty in
           let body_c = match builtin with
             | "vec_new" ->
               let elem_tag =
                 match Ast.walk ret_ty with
                 | Ast.TyCon ("Vec", [_; et]) -> ty_tag (Ast.walk et)
                 | _ -> "?"
               in
               Printf.sprintf "mere_vec_%s_new(&__lang_default_region)" elem_tag
             | "owned_vec_new" ->
               let elem_tag =
                 match Ast.walk ret_ty with
                 | Ast.TyCon ("OwnedVec", [et]) -> ty_tag (Ast.walk et)
                 | _ -> "?"
               in
               Printf.sprintf "mere_owned_vec_%s_new()" elem_tag
             | "strbuf_new" ->
               "mere_strbuf_new(&__lang_default_region)"
             | "map_new" ->
               let (k_tag, v_tag) =
                 match Ast.walk ret_ty with
                 | Ast.TyCon ("Map", [_; k; v]) ->
                   (ty_tag (Ast.walk k), ty_tag (Ast.walk v))
                 | _ -> ("?", "?")
               in
               Printf.sprintf "mere_map_%s_%s_new(&__lang_default_region)" k_tag v_tag
             | _ -> "0"
           in
           let fn_def = Printf.sprintf
             "static %s %s_closure_fn(void* __env, int __u) { (void)__env; (void)__u; return %s; }\n\
              static const %s %s_as_value = {.env = NULL, .fn = %s_closure_fn};"
             ret_c adapter body_c cstruct adapter adapter
           in
           fn_def :: acc)
           eta_adapters []
       in
       if eta_lines = [] then []
       else "/* Phase 35.1: nullary factory builtins as first-class values */"
            :: eta_lines @ [""])
    @ [ "int main(int argc, char** argv) {";
        (if !args_used then "  __lang_argc = argc; __lang_argv = argv;"
         else "  (void)argc; (void)argv;");
        "  __lang_region_init(&__lang_default_region, 1 << 22);";
        (if top_global_inits = [] then ""
         else String.concat "\n" top_global_inits);
        main_stmt;
        (* Phase 15.8: free all OwnedVec allocations registered during run. *)
        (if Hashtbl.length owned_vec_instances > 0
         then "  __mere_owned_vec_free_all();" else "");
        "  __lang_region_free(&__lang_default_region);";
        "  return 0;";
        "}";
        "" ]
  in
  String.concat "\n" parts
