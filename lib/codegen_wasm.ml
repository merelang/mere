(* Wasm (WebAssembly) codegen — Phase 6.1 MVP.

   Emits WAT (WebAssembly Text format), an S-expression representation
   that `wat2wasm` (wabt) parses into a `.wasm` binary. Mirrors the
   first slice scope of the other backends: int / bool / arith / cmp /
   logic / Neg / If / Let (P_var) / Var / Annot.

   Wasm is stack-based (no SSA), so emission is a different shape from
   the C / LLVM backends: each expression pushes its result onto the
   stack; the surrounding context pops in the order the instructions
   were emitted.

   The runtime is just `WebAssembly.instantiate(...)`; the main module
   exports a `main` function whose return type is i32 (Lang bool also
   widens to i32). Strings / records / variants are deferred to later
   slices since they need linear memory + (typically) a small runtime. *)

exception Codegen_error of Loc.t * string

let unsupported loc what =
  raise (Codegen_error (loc, "unsupported (wasm codegen, Phase 6.1 MVP): " ^ what))

(* Accumulator for the function body's instructions (one WAT token per
   list entry). The driver concatenates them with newlines + indent. *)
let instrs : string list ref = ref []
let emit_instr s = instrs := s :: !instrs

(* Local slot bookkeeping. Lang variables map to Wasm locals; we mint
   a fresh slot per Let binding. Wasm locals are typed, so we track the
   declared type per slot. Most slots are i32 (Mere's uniform value model),
   but we keep a type list to handle Phase 34.3's f64 temp slots for float. *)
let local_counter = ref 0
let local_types : string list ref = ref []  (* in declaration order; index = slot *)
let locals : (string * int) list ref = ref []
let fresh_local () =
  let n = !local_counter in
  incr local_counter;
  local_types := !local_types @ ["i32"];
  n
let fresh_local_f64 () =
  let n = !local_counter in
  incr local_counter;
  local_types := !local_types @ ["f64"];
  n

(* String literals live in linear memory. Each Str_lit is laid out
   sequentially starting at `str_initial_offset` (we reserve the first
   slot of memory for the bump-allocator's top pointer just out of
   habit, even though it actually lives in a Wasm global). *)
let str_initial_offset = 16
let str_data_decls : string list ref = ref []
let str_offset_counter = ref str_initial_offset

(* WAT data-string escape: printable ASCII as-is, otherwise \HH. *)
let wasm_string_escape (s : string) : string =
  let buf = Buffer.create (String.length s + 4) in
  String.iter (fun c ->
    let code = Char.code c in
    if code >= 32 && code <= 126 && c <> '"' && c <> '\\' then
      Buffer.add_char buf c
    else
      Buffer.add_string buf (Printf.sprintf "\\%02x" code)
  ) s;
  Buffer.contents buf

let fresh_str_offset (s : string) : int =
  let off = !str_offset_counter in
  let bytes_len = String.length s + 1 in
  str_offset_counter := off + bytes_len;
  let escaped = wasm_string_escape s in
  str_data_decls :=
    Printf.sprintf "  (data (i32.const %d) \"%s\\00\")" off escaped
    :: !str_data_decls;
  off

(* Reset per emit_program. *)
let reset () =
  instrs := [];
  local_counter := 0;
  local_types := [];
  locals := []

(* ── Function lifting (Phase 6.2) ── *)

type fn_skel = {
  sname : string;
  sparam : string;
  sbody : Ast.expr;
  sfun : Ast.expr;
}

type fn_decl = {
  name : string;
  param : string;
  body : Ast.expr;
  param_ty : Ast.ty;
  return_ty : Ast.ty;
}

let toplevel_fn_names : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Phase 30.2c (DEFERRED §1.10 fix, Wasm): keep the names of top-level
   non-fn lets. In Wasm all values are i32 (literal int / ptr to linear
   memory), so declare them as (global $<name> (mut i32) (i32.const 0)) and
   initialize via `global.set` at the start of main. emit_expr Var "name"
   becomes `global.get $<name>`. *)
let top_globals_wasm : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Phase 32.4 (C1 FFI, Wasm): declare extern fns as env host imports and
   call them via `call $<name>`. The Node.js host harness
   (scripts/run_wasm.js) provides default impls in env (getpid / getppid etc.). *)
let extern_fn_decls_wasm : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Phase 15.4: Vec[R, T] runtime used flag. All Mere values lower to a
   4-byte i32 in Wasm (scalars are direct, structured types are linear-
   memory offsets), so a single $mere_vec_* runtime handles every element
   type — no per-T monomorphization is needed (unlike C / LLVM which use
   typed structs). The flag is set the first time emit_expr / ty
   inspection sees a Vec value; emit_program emits the helpers iff true. *)
let vec_used = ref false

(* Phase 15.5: vec_iter / vec_fold reference `(type $cl)` and use
   `call_indirect`, which both require a funcref table to be declared
   in the module. Track usage so emit_program can declare a (possibly
   empty) table when these helpers are emitted. *)
let vec_higher_order_used = ref false

(* Phase 15.9: StrBuf[R] usage flag — runtime is single non-polymorphic. *)
let strbuf_used = ref false

(* Phase 16.3: Logger / Metrics builtin usage flags. *)
let logger_used = ref false
let metrics_used = ref false
(* Q-012: set when the program uses spawn / join / channel. Switches the
   module to host-imported shared memory + pulls the pthread-like host
   imports (mere_spawn / mere_join). *)
let uses_threads = ref false
(* Phase 26.1: stdlib builtin usage flags for Wasm. *)
let char_table_used = ref false
let fail_used = ref false
let substring_used = ref false
let int_of_str_used = ref false
let str_unescape_used = ref false
(* Phase 26.5: stdlib catch-up — str_split / str_join / str_count / file I/O. *)
let str_split_used = ref false
let str_join_used = ref false
let str_count_used = ref false
let file_io_used = ref false

(* Phase 15.10/15.14: Map[R, K, V] — in Wasm all values are i32, so no per-V
   is needed; only per-K. Register K's type in `map_key_types`, and
   emit_program emits one set of per-K helpers per entry. `map_int_used` /
   `map_str_used` are kept for backward compatibility (new code goes
   through the table). *)
let map_int_used = ref false
let map_str_used = ref false
let map_key_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.12: vec_to_list and len-on-list share the same list structure,
   so emit the runtime if either is used. Tag values are determined at codegen
   time. *)
let vec_to_list_used = ref false
let list_len_used = ref false

(* Names bound by a pattern (for the free-vars walk). *)
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

(* ── Closure machinery (Phase 6.7) ──
   Wasm closures are 8-byte memory structs `{ env_offset, fn_table_idx }`.
   The fn pointer is a `funcref` table index, not a memory pointer —
   indirect calls go through `call_indirect (type $cl)`. Every
   closure-callable function has signature `(env, x) -> result` and is
   registered in the module's table. *)

(* Function names that appear in the module's `(elem ...)` section.
   List position == table index. *)
let table_entries : string list ref = ref []
let register_in_table (name : string) : int =
  let idx = List.length !table_entries in
  table_entries := !table_entries @ [name];
  idx

(* Top-level fn name → its closure adapter's table index. Populated
   when we emit the per-top-level-fn `<name>_closure` wrapper. *)
let fn_closure_table_idx : (string, int) Hashtbl.t = Hashtbl.create 4

(* Phase 35.3: eta-wrapped nullary factory adapters (vec_new / owned_vec_new
   / strbuf_new / map_new_<k_tag>) used as first-class values. Key = adapter
   slug, value = (builtin name, ret_ty, table_idx). *)
(* Phase 38.C (DEFERRED §1.2 A2): syntactic eta-expansion for multi-arg curried
   builtins used in value position (same logic as the helper of the same name
   in codegen_c / codegen_llvm). Routes through an anonymous Fun adapter +
   each builtin's direct-call fast path (line 1653 etc.). *)
let synthesize_curried_eta_wasm (name : string) (arrow_ty : Ast.ty) (loc : Loc.t)
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

let eta_adapters_wasm : (string, string * Ast.ty * int) Hashtbl.t =
  Hashtbl.create 4

(* Anonymous-Fun closure emission state. *)
type closure_emission = {
  ce_adapter_name : string;
  ce_param        : string;
  ce_body         : Ast.expr;
  ce_captures     : (string * int) list;  (* (name, source local slot) *)
  ce_table_idx    : int;
  mutable ce_host : string;  (* Phase 26.3: host scope at queue time *)
}
let pending_closures : closure_emission list ref = ref []
let anon_counter = ref 0
let fresh_anon_name () =
  let n = !anon_counter in
  incr anon_counter;
  Printf.sprintf "anon_%d_fn" n

(* Phase 26.3: inner-fn lifting (port from codegen_llvm Phase 25.3).
   Inner `let X = fn ...` / `let rec X = fn ... and Y = ...` are lifted
   to top-level Wasm fns; captures are prepended as i32 params. *)
type lifted_inner_wasm = {
  lifted_name : string;
  captures    : string list;  (* free var names in order *)
}
let inner_lifts_wasm : (string, lifted_inner_wasm) Hashtbl.t = Hashtbl.create 8
let inner_lifts_by_host_wasm : (string, (string, lifted_inner_wasm) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 8

(* Phase 39.A2 (Wasm port): inner-lifted fn at value position. For each fn,
   register an adapter in the fn table; at the use site, alloc env in the bump
   heap + store captures + write the closure value (env_offset, table_idx) to
   memory. *)
let inner_lift_closures_emitted_wasm : (string, int) Hashtbl.t = Hashtbl.create 4
let inner_lift_closure_pending_wasm :
  (string * string list * int) list ref = ref []
let set_inner_lifts_for_host_wasm (host : string) : unit =
  Hashtbl.reset inner_lifts_wasm;
  (match Hashtbl.find_opt inner_lifts_by_host_wasm host with
   | Some tbl -> Hashtbl.iter (fun k v -> Hashtbl.add inner_lifts_wasm k v) tbl
   | None -> ())

(* Wasm tail-call proposal — set to true only while emit_expr is
   producing a value in tail position of the enclosing function
   body. The App emissions look at the flag and switch `call` /
   `call_indirect` to `return_call` / `return_call_indirect` when
   set, so deeply tail-recursive Mere code (parser walkers, list
   iterations) doesn't grow the JS stack. Requires wat2wasm's
   `--enable-tail-call` (or an equivalent V8 default). *)
let wasm_tail_pos = ref false

(* True only while emit_expr is walking the top-level `let a = … in
   let b = … in … 0` spine of the main body. This is the ONE context
   where a `let x = v in …` with x registered in top_globals_wasm
   should compile to `global.set $x` (the Phase 36 initialization
   trick). Any nested `let x = v in …` inside a fn body that happens
   to share a name with a top-level global is a plain local
   shadowing binding, and gets a fresh slot.

   Bug this closes: a top-level `let entries = kv_load … in` at the
   importing file's top makes `entries` a global; when a value-
   position `let entries = _map_entries …` inside an imported
   module's fn body was emitted, the name-only check misrouted it
   to `global.set $entries`, silently overwriting the KV strbuf
   pointer with an unrelated Entry list. Downstream kv_save then
   wrote 0 bytes to disk. *)
let wasm_in_top_level_body = ref false

type lifted_fn_wasm = {
  l_name     : string;
  l_captures : string list;
  l_param    : string;
  l_body     : Ast.expr;
  l_host     : string;
}

let inner_fn_counter_wasm = ref 0
let fresh_inner_name_wasm (base : string) : string =
  let n = !inner_fn_counter_wasm in
  incr inner_fn_counter_wasm;
  Printf.sprintf "__lifted_%s_%d" base n

let lifted_fns_wasm : lifted_fn_wasm list ref = ref []

(* Phase 26.3: name of the currently-emitting top-level (or lifted) fn,
   so anonymous-Fun closures queued in pending_closures can remember
   their host scope for inner_lifts dispatch. *)
let current_host_fn_wasm : string ref = ref ""

(* Each variant constructor → integer tag. Populated up front from
   Exhaustive.type_variants. *)
let variant_tags : (string, int) Hashtbl.t = Hashtbl.create 16

(* Types whose `show_<ty_tag>` function we need to emit. *)
let show_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Same, for `to_json_<ty_tag>` (derive JSON sibling of show). *)
let to_json_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* `of_json` — keyed by target (result) type tag. When non-empty, the WAT
   JSON-parser runtime is emitted. *)
let of_json_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* `of_json_opt` — keyed by the INNER type tag (result is `T option`). *)
let of_json_opt_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Compound types compared with == / != — need a structural `eq_<tag>`
   (Wasm `i32.eq` on a compound value compares linear-memory offsets, not
   contents). Keyed by ty_tag. *)
let eq_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

let needs_struct_eq (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyTuple _ -> true
  | Ast.TyCon (name, _) ->
    Hashtbl.mem Typer.records name
    || Hashtbl.mem Typer.types name
    || name = "list"
  | _ -> false

(* Cache: literal string → data segment offset, so repeated literals
   (e.g. `, ` between tuple elements) share one segment. *)
let show_str_offsets : (string, int) Hashtbl.t = Hashtbl.create 16
let intern_show_str (s : string) : int =
  match Hashtbl.find_opt show_str_offsets s with
  | Some off -> off
  | None ->
    let off = fresh_str_offset s in
    Hashtbl.add show_str_offsets s off;
    off

(* Phase 26.0: variant payload "presence" check (not type) — returns
   true if any ctor has a payload, false if all-nullary. Used to decide
   the variant cell size (8 bytes if any payload, else 4).
   In Wasm, all i32-wide values fit at offset 4 regardless of static
   type, so unlike Phase 6 MVP we no longer require uniform payload
   types — per-ctor type info is recovered via ctor_payload_ty at each
   constr / match site. Mirrors LLVM Phase 25.0 (boxed payload). *)
let variant_has_payload (vname : string) : bool =
  match Hashtbl.find_opt Exhaustive.type_variants vname with
  | None ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unknown variant type `%s` at Wasm codegen" vname))
  | Some vs ->
    List.exists (fun (_, p) -> p <> None) vs

(* Phase 26.0: per-ctor payload type. Used by Constr emit (to size the
   boxed payload alloc) and by match P_constr (to compile sub-patterns
   with the correct type). For poly variants the caller substitutes
   type params with concrete args from the surrounding context. *)
let ctor_payload_ty (cname : string) : Ast.ty option =
  match Hashtbl.find_opt Typer.constructors cname with
  | None -> None
  | Some info -> info.Typer.arg

(* Kept for backwards compatibility with code that hasn't been ported
   to per-ctor lookup yet; returns the first payload type seen across
   the variant's ctors, ignoring shape mismatches. *)
let variant_payload_ty (vname : string) : Ast.ty option =
  match Hashtbl.find_opt Exhaustive.type_variants vname with
  | None ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unknown variant type `%s` at Wasm codegen" vname))
  | Some vs ->
    let payloads = List.filter_map (fun (_, p) -> p) vs in
    (match payloads with [] -> None | p :: _ -> Some p)

(* Stable name fragment per type for show fn naming. Mirrors C/LLVM
   codegen's ty_tag so e.g. `int list` lowers to `show_list_int`. *)
let rec ty_tag (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyCon ("OwnedVec", _) ->
    raise (Codegen_error (Loc.dummy,
      "unsupported in Wasm codegen subset: OwnedVec (not implemented for Wasm in Phase 15)"))
  | Ast.TyCon ("StrBuf", _) ->
    (* Phase 27.3: StrBuf is implemented in Wasm too via the mere_strbuf_*
       runtime. Make ty_tag return a value so it can also be used via tuple
       / variant payload types. *)
    "strbuf"
  | Ast.TyCon ("Map", [_region; k_ty; v_ty]) ->
    (* Phase 43: In Wasm too, Map is an i32 pointer, so return a ty_tag so
       it can be treated as a carrier in tuple / closure env / variant
       payload. The K / V tags prevent identifier collisions
       (`map_str_int` vs `map_int_str`). *)
    "map_" ^ ty_tag k_ty ^ "_" ^ ty_tag v_ty
  | Ast.TyCon ("Map", _) ->
    raise (Codegen_error (Loc.dummy,
      "unsupported in Wasm codegen subset: Map (when region / K / V is not concrete)"))
  | Ast.TyInt -> "int"
  | Ast.TyBool -> "bool"
  | Ast.TyStr -> "str"
  | Ast.TyUnit -> "unit"
  | Ast.TyFloat -> "float"   (* Phase 43.1: float fn signature tag *)
  | Ast.TyTuple ts -> "tuple_" ^ String.concat "_" (List.map ty_tag ts)
  | Ast.TyArrow (p, r) -> "closure_" ^ ty_tag p ^ "_" ^ ty_tag r
  | Ast.TyCon (name, []) -> name
  | Ast.TyCon (name, args) ->
    name ^ "_" ^ String.concat "_" (List.map ty_tag args)
  | Ast.TyRef (_, r, Ast.TyUnit) ->
    (* Region marker — use the region name itself as the tag (same as C / LLVM). *)
    r
  | Ast.TyRef (_, _, inner) ->
    (* Phase 19.x: borrow types use the inner type's tag as-is (same as C / LLVM). *)
    ty_tag inner
  | _ ->
    raise (Codegen_error (Loc.dummy,
      "unsupported Wasm codegen type for ty_tag"))

let rec ty_is_concrete (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyFloat -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, _, inner) -> ty_is_concrete inner
  | Ast.TyVar _ | Ast.TyParam _ -> false  (* Phase 43.1: TyFloat was incorrectly listed as poly *)

(* Substitute TyParam → concrete throughout `t`. Used by add_show_type
   to specialize variant payloads / record fields against the actual
   args of a polymorphic instance. *)
let rec subst_params (mapping : (string * Ast.ty) list) (t : Ast.ty) : Ast.ty =
  match Ast.walk t with
  | Ast.TyParam p ->
    (try List.assoc p mapping with Not_found -> t)
  | Ast.TyArrow (a, b) ->
    Ast.TyArrow (subst_params mapping a, subst_params mapping b)
  | Ast.TyTuple ts -> Ast.TyTuple (List.map (subst_params mapping) ts)
  | Ast.TyCon (n, args) ->
    Ast.TyCon (n, List.map (subst_params mapping) args)
  | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, subst_params mapping inner)
  | other -> other

(* Register a type for show emission, then walk dependent types
   (tuple elems / record fields / variant payloads) recursively. The
   already-seen guard prevents infinite recursion on self-referential
   variants. *)
let rec add_type_into (tbl : (string, Ast.ty) Hashtbl.t) (t : Ast.ty) : unit =
  let t = Ast.walk t in
  if not (ty_is_concrete t) then ()
  else
    let tag = ty_tag t in
    if Hashtbl.mem tbl tag then ()
    else begin
      Hashtbl.add tbl tag t;
      match t with
      | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> ()
      | Ast.TyTuple ts -> List.iter (add_type_into tbl) ts
      | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
        let info = Hashtbl.find Typer.records n in
        let mapping =
          if info.Typer.r_params = [] then []
          else List.combine info.Typer.r_params args
        in
        List.iter (fun (_, ft) ->
          add_type_into tbl (subst_params mapping ft)) info.Typer.r_fields
      | Ast.TyCon (n, args) when Hashtbl.mem Typer.types n ->
        (match Hashtbl.find_opt Exhaustive.type_variants n with
         | None -> ()
         | Some vs ->
           let mapping =
             match vs with
             | (cname, _) :: _ ->
               (match Hashtbl.find_opt Typer.constructors cname with
                | Some info when info.Typer.params <> [] ->
                  List.combine info.Typer.params args
                | _ -> [])
             | [] -> []
           in
           List.iter (fun (_, arg_opt) ->
             match arg_opt with
             | Some t -> add_type_into tbl (subst_params mapping t)
             | None -> ()) vs)
      | _ -> ()
    end

let add_show_type (t : Ast.ty) : unit = add_type_into show_types t

let collect_show_types (root : Ast.expr) (fns : fn_decl list) : unit =
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
       (match arg.Ast.ty with
        | Some t -> add_show_type t
        | None -> ())
     | Ast.App ({ node = Ast.Var "to_json"; _ }, arg) ->
       (match arg.Ast.ty with
        | Some t -> add_type_into to_json_types t
        | None -> ())
     | Ast.App ({ node = Ast.Var "of_json"; _ }, _) ->
       (match e.Ast.ty with
        | Some t -> add_type_into of_json_types t
        | None -> ())
     | Ast.App ({ node = Ast.Var "of_json_opt"; _ }, _) ->
       (match e.Ast.ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyCon ("option", [inner]) ->
             add_type_into of_json_types inner;
             let it = Ast.walk inner in
             Hashtbl.replace of_json_opt_types (ty_tag it) it
           | _ -> ())
        | None -> ())
     | Ast.Cmp ((Ast.Eq | Ast.Ne), a, _) ->
       (match a.Ast.ty with
        | Some t when needs_struct_eq t -> add_type_into eq_types t
        | _ -> ())
     | Ast.App ({ node = Ast.Var "mk_metrics"; _ }, _) ->
       (* Phase 16.3: metrics.record uses show_int internally to format
          the integer payload, so register `int` ahead of show_fn_defs. *)
       add_show_type Ast.TyInt
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

let lift_fn_skels (e : Ast.expr) : fn_skel list * Ast.expr =
  (* Phase 26.5 (port of codegen_c Phase 24.4 / codegen_llvm Phase 25.9):
     walk through ALL top-level Let chains so a non-Fun Let
     (e.g., \`let path = "/tmp/x"\`) doesn't break the chain and block
     subsequent \`let rec\` from being lifted. Fun-valued P_var Lets →
     extract as skel + drop from body. Other Lets → keep in body + walk rest.
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
              "let rec binding must be a single-arg function in Wasm subset")))
          bindings
      in
      let more, rest' = go rest in
      skels @ more, rest'
    | _ -> [], e
  in
  go e

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

(* Phase 26.4: multi-instantiation specialization (Wasm version of LLVM
   Phase 25.5). Since Wasm IR uniformly uses i32, static specialization is
   technically unnecessary, but we set up the same infra as LLVM for future
   polymorphic `show`/`print`/etc. *)
let multi_inst_fns_wasm : (string, Ast.ty list) Hashtbl.t = Hashtbl.create 4

let mangled_inst_name_wasm (base : string) (arrow : Ast.ty) : string =
  let rec collect_tys t acc =
    match Ast.walk t with
    | Ast.TyArrow (a, b) -> collect_tys b (a :: acc)
    | _ -> List.rev (t :: acc)
  in
  let tys = collect_tys arrow [] in
  base ^ "__" ^ String.concat "__" (List.map ty_tag tys)

let find_all_concrete_arrows_in_wasm (name : string) (exprs : Ast.expr list)
  : Ast.ty list =
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

let clone_with_fresh_tyvars_wasm (e : Ast.expr) : Ast.expr =
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
  (* Phase 21.2 multi-pass + Phase 26.4 multi-instantiation specialization
     (Wasm version of LLVM Phase 25.5). *)
  let resolved : (string, Ast.ty) Hashtbl.t = Hashtbl.create 16 in
  let progress = ref true in
  Hashtbl.reset multi_inst_fns_wasm;
  let multi_specs : (string, (Ast.ty * Ast.expr) list) Hashtbl.t =
    Hashtbl.create 4
  in
  (* Phase 43: re-scan support for chained poly inst (see codegen_c.ml for the explanation) *)
  let make_spec arrow s =
    let cloned_fun = clone_with_fresh_tyvars_wasm s.sfun in
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
        let all = find_all_concrete_arrows_in_wasm s.sname (root :: extra_exprs ()) in
        let existing = Hashtbl.find multi_specs s.sname in
        let existing_arrows = List.map fst existing in
        let new_arrows = List.filter (fun a ->
          let a_str = Ast.pp_ty (Ast.walk a) in
          not (List.exists (fun e -> Ast.pp_ty (Ast.walk e) = a_str) existing_arrows)) all
        in
        if new_arrows <> [] then begin
          let new_specs = List.map (fun a -> make_spec a s) new_arrows in
          Hashtbl.replace multi_specs s.sname (existing @ new_specs);
          Hashtbl.replace multi_inst_fns_wasm s.sname (existing_arrows @ new_arrows);
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
          let all = find_all_concrete_arrows_in_wasm s.sname (root :: extra_exprs ()) in
          match all with
          | _ :: _ ->
            if List.length all > 1 then begin
              Hashtbl.add multi_inst_fns_wasm s.sname all;
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
          { name = mangled_inst_name_wasm s.sname arrow;
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

(* Phase 26.3: lift inner Let-Fun / Let_rec to top-level Wasm fns.
   Mirrors codegen_llvm.lift_inner_fns_llvm. Populates inner_lifts_wasm /
   inner_lifts_by_host_wasm + lifted_fns_wasm. *)
let lift_inner_fns_wasm (toplevel_names : string list) (fns : fn_decl list) : unit =
  Hashtbl.reset inner_lifts_wasm;
  Hashtbl.reset inner_lifts_by_host_wasm;
  inner_fn_counter_wasm := 0;
  lifted_fns_wasm := [];
  let builtin_names = List.map fst Typer.initial_env in
  let extern_names =
    Hashtbl.fold (fun k _ acc -> k :: acc) extern_fn_decls_wasm []
  in
  let known = ref (toplevel_names @ builtin_names @ extern_names) in
  let current_host = ref "" in
  let lift_one _host_param host_locals n p fn_body =
    let effective_known =
      List.filter (fun k -> not (List.mem k host_locals)) !known
    in
    let body_fvs = free_vars fn_body (p :: effective_known) in
    let lifted_name = fresh_inner_name_wasm n in
    let lf = {
      l_name = lifted_name; l_captures = body_fvs;
      l_param = p; l_body = fn_body;
      l_host = !current_host;
    } in
    lifted_fns_wasm := lf :: !lifted_fns_wasm;
    let entry = { lifted_name; captures = body_fvs } in
    Hashtbl.replace inner_lifts_wasm n entry;
    let host_tbl =
      match Hashtbl.find_opt inner_lifts_by_host_wasm !current_host with
      | Some t -> t
      | None ->
        let t = Hashtbl.create 4 in
        Hashtbl.add inner_lifts_by_host_wasm !current_host t;
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
         let fn_body = lift_one host_param host_locals n p fn_body in
         walk p [] fn_body;
         walk host_param (n :: host_locals) body
       | _ ->
         walk host_param host_locals value;
         walk host_param (pattern_vars pat @ host_locals) body)
    | Ast.Let_rec (bindings, body) ->
      let rec_names = List.map fst bindings in
      let fn_specs = List.map (fun (n, value) ->
        match value.Ast.node with
        | Ast.Fun (p, _, fn_body) -> (n, p, fn_body)
        | _ ->
          raise (Codegen_error (value.Ast.loc,
            "inner let-rec binding must be a single-arg fn"))) bindings
      in
      known := rec_names @ !known;
      List.iter (fun (n, p, fb) ->
        let _ = lift_one host_param host_locals n p fb in ()) fn_specs;
      List.iter (fun (_, p, fb) -> walk p [] fb) fn_specs;
      walk host_param (rec_names @ host_locals) body
    | Ast.Fun (_, _, b) -> walk host_param host_locals b
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk host_param host_locals a; walk host_param host_locals b
    | Ast.Neg a | Ast.Annot (a, _) -> walk host_param host_locals a
    | Ast.With (_, v, b) -> walk host_param host_locals v; walk host_param host_locals b
    | Ast.If (c, t, e_) ->
      walk host_param host_locals c;
      walk host_param host_locals t;
      walk host_param host_locals e_
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
    | Ast.Record_lit (_, fs) ->
      List.iter (fun (_, e) -> walk host_param host_locals e) fs
    | Ast.Field_get (a, _) -> walk host_param host_locals a
    | Ast.Record_update (a, fs) ->
      walk host_param host_locals a;
      List.iter (fun (_, e) -> walk host_param host_locals e) fs
  in
  List.iter (fun (f : fn_decl) ->
    current_host := f.name;
    walk f.param [f.param] f.body) fns;
  (* Phase 45 (DEFERRED §8): transitive capture closure for mutually-called
     inner-lifted fns. See the same-phase comment in codegen_c.ml for details *)
  let all_lifted = !lifted_fns_wasm in
  (* Build a per-host mere→lifted map. Using a single global map keyed
     only by raw name causes collisions when two different top-level
     fns each define an inner-lifted helper with the same source name
     (e.g. two separate `let rec walk = …` bodies) — the second
     silently overwrote the first, and the transitive-capture pass
     then attributed the wrong capture set to inter-sibling calls,
     surfacing as `inner-lifted capture X not in scope` at emit. *)
  let mere_to_lifted_by_host : (string, (string, string) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 8
  in
  Hashtbl.iter (fun host tbl ->
    let m = Hashtbl.create 4 in
    Hashtbl.iter (fun mname entry -> Hashtbl.replace m mname entry.lifted_name) tbl;
    Hashtbl.replace mere_to_lifted_by_host host m
  ) inner_lifts_by_host_wasm;
  let mere_to_lifted_for host =
    match Hashtbl.find_opt mere_to_lifted_by_host host with
    | Some m -> m
    | None -> Hashtbl.create 0
  in
  (* Note that Wasm captures are a string list, so the type differs *)
  let captures_map : (string, string list) Hashtbl.t =
    Hashtbl.create 8
  in
  List.iter (fun lf ->
    let host_map = mere_to_lifted_for lf.l_host in
    let filtered = List.filter (fun n ->
      not (Hashtbl.mem host_map n)) lf.l_captures in
    Hashtbl.replace captures_map lf.l_name filtered) all_lifted;
  let rec scan_for_called host_map called_acc (e : Ast.expr) cur_name =
    let acc = ref called_acc in
    (match e.Ast.node with
     | Ast.Var n when Hashtbl.mem host_map n
                   && Hashtbl.find host_map n <> cur_name ->
       let cl_name = Hashtbl.find host_map n in
       if not (List.mem cl_name !acc) then acc := cl_name :: !acc
     | _ -> ());
    let recurse sub = acc := scan_for_called host_map !acc sub cur_name in
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
      let host_map = mere_to_lifted_for lf.l_host in
      let called_inner = scan_for_called host_map [] lf.l_body lf.l_name in
      let cur_caps = Hashtbl.find captures_map lf.l_name in
      let new_caps = ref cur_caps in
      List.iter (fun called_lifted_name ->
        let other_caps = Hashtbl.find captures_map called_lifted_name in
        List.iter (fun cap_n ->
          if cap_n = lf.l_param then ()
          else if Hashtbl.mem host_map cap_n then ()
          else if List.mem cap_n !new_caps then ()
          else begin
            new_caps := !new_caps @ [cap_n];
            changed := true
          end
        ) other_caps
      ) called_inner;
      Hashtbl.replace captures_map lf.l_name !new_caps
    ) all_lifted
  done;
  lifted_fns_wasm := List.map (fun lf ->
    let new_caps = Hashtbl.find captures_map lf.l_name in
    { lf with l_captures = new_caps }) all_lifted;
  Hashtbl.iter (fun _host tbl ->
    Hashtbl.iter (fun mere_n entry ->
      let new_caps = Hashtbl.find captures_map entry.lifted_name in
      Hashtbl.replace tbl mere_n { entry with captures = new_caps }
    ) tbl) inner_lifts_by_host_wasm;
  Hashtbl.iter (fun mere_n entry ->
    let new_caps = Hashtbl.find captures_map entry.lifted_name in
    Hashtbl.replace inner_lifts_wasm mere_n { entry with captures = new_caps }
  ) inner_lifts_wasm

(* Map Lang binop / cmp / logic to Wasm opcodes. All operands are i32
   (bool also widens to i32). *)
let wasm_binop = function
  | Ast.Add -> "i32.add"
  | Ast.Sub -> "i32.sub"
  | Ast.Mul -> "i32.mul"
  | Ast.Div -> "i32.div_s"
  | Ast.Mod -> "i32.rem_s"
  | Ast.Concat -> raise Exit

let wasm_cmp = function
  | Ast.Eq -> "i32.eq"
  | Ast.Ne -> "i32.ne"
  | Ast.Lt -> "i32.lt_s"
  | Ast.Le -> "i32.le_s"
  | Ast.Gt -> "i32.gt_s"
  | Ast.Ge -> "i32.ge_s"

(* Phase 15.10: In Wasm all values are i32 so per-V is unnecessary; only
   branch helpers on K (int / str). *)
let map_key_tag_of_wasm (ty_opt : Ast.ty option) (loc : Loc.t) : string =
  match ty_opt with
  | Some t ->
    (match Ast.walk t with
     | Ast.TyCon ("Map", [_; k_ty; _]) ->
       let k_ty = Ast.walk k_ty in
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
           "Map key type must be int / bool / str / tuple / record / variant in Wasm codegen (Phase 15.10〜15.16)"));
       let tag = ty_tag k_ty in
       if not (Hashtbl.mem map_key_types tag) then
         Hashtbl.add map_key_types tag k_ty;
       tag
     | _ -> raise (Codegen_error (loc, "map_* expected a Map value")))
  | None -> raise (Codegen_error (loc, "map_*: missing type info"))

(* Phase 48.5: round `__lang_bump` up to the next 4-byte boundary.
   Wasm's `i32.store` / `i32.load` handle unaligned access transparently,
   so internal Mere code doesn't care, but host code that reads
   closure records via `Int32Array` would land on the wrong word if
   the record sat at an odd offset. Call this immediately before
   bump-allocating a closure record (8-byte { env, fn_idx } struct)
   so the pointer handed to host glue is always 4-byte aligned.
   See contrib/dom/dom.glue.js for the JS side (which now uses
   DataView anyway, but alignment is the proper Mere-side fix). *)
let emit_align_bump_4 () : unit =
  emit_instr "global.get $__lang_bump";
  emit_instr "i32.const 3";
  emit_instr "i32.add";
  emit_instr "i32.const -4";
  emit_instr "i32.and";
  emit_instr "global.set $__lang_bump"

(* Phase 34.3: Wasm float helper. Float values are **bump-alloc'd as 8 bytes
   (f64) and held as i32 pointers** (preserving the uniform i32 value model).
   `emit_float_alloc_from_f64_on_stack`: alloc + store the f64 value at the
   stack top, leaving an i32 ptr at the stack top. *)
let emit_float_alloc_from_f64_on_stack () : unit =
  (* Stack before: [..., f64] *)
  let tmp_f64 = fresh_local_f64 () in
  emit_instr (Printf.sprintf "local.set %d" tmp_f64);
  (* Stack: [...] — f64 saved in tmp local *)
  emit_instr "global.get $__lang_bump";
  emit_instr "i32.const 7";
  emit_instr "i32.add";
  emit_instr "i32.const -8";
  emit_instr "i32.and";
  emit_instr "global.set $__lang_bump";           (* align bump up to 8 *)
  emit_instr "global.get $__lang_bump";            (* push ptr (= aligned bump) *)
  emit_instr (Printf.sprintf "local.get %d" tmp_f64);
  emit_instr "f64.store offset=0 align=8";        (* memory[ptr] = f64 *)
  emit_instr "global.get $__lang_bump";            (* push ptr again (= return value) *)
  emit_instr "global.get $__lang_bump";
  emit_instr "i32.const 8";
  emit_instr "i32.add";
  emit_instr "global.set $__lang_bump"            (* bump += 8 *)
  (* Stack: [..., ptr] *)

(* Emit `expr` so its result lands on top of the Wasm operand stack. *)
let rec emit_expr (e : Ast.expr) : unit =
  (* Snapshot inbound tail-position + top-level-body flags. All
     descendant emit_expr calls default back to non-tail / non-top;
     tail-preserving nodes (If branches, Let body, Match arm bodies)
     reinstate `saved_tail`, and Let / Let_rec bodies additionally
     reinstate `saved_top` so a top-level let-spine stays top-level
     as it walks down. *)
  let saved_tail = !wasm_tail_pos in
  let saved_top = !wasm_in_top_level_body in
  wasm_tail_pos := false;
  wasm_in_top_level_body := false;
  match e.Ast.node with
  | Ast.Int_lit n ->
    emit_instr (Printf.sprintf "i32.const %d" n)
  | Ast.Float_lit f ->
    (* Phase 34.3: push the f64 literal, bump alloc to get an i32 ptr *)
    emit_instr (Printf.sprintf "f64.const %.17g" f);
    emit_float_alloc_from_f64_on_stack ()
  | Ast.Bool_lit b ->
    emit_instr (Printf.sprintf "i32.const %d" (if b then 1 else 0))
  | Ast.Unit_lit ->
    emit_instr "i32.const 0"
  | Ast.Str_lit s ->
    let off = fresh_str_offset s in
    emit_instr (Printf.sprintf "i32.const %d" off)
  | Ast.Var "pi" when not (List.mem_assoc "pi" !locals) ->
    (* Phase 34.3: float constants — heap-alloc and push an i32 ptr *)
    emit_instr "f64.const 3.14159265358979323846";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.Var "e" when not (List.mem_assoc "e" !locals) ->
    emit_instr "f64.const 2.7182818284590452354";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.Var name ->
    (* Phase 26.6 (port of codegen_c Phase 24.1 / codegen_llvm Phase 25.10):
       a local binding (locals) can shadow a stdlib builtin name like `len`.
       Treat as regular var if shadowed; only reject if it's the actual
       stdlib builtin as a value. *)
    let is_shadowed = List.mem_assoc name !locals in
    (* Phase 35.3: nullary factory builtins as first-class values via
       eta-wrap. Compute adapter slug + register a `(func $eta_<slug>` that
       will be emitted by emit_program. *)
    let is_nullary_factory = name = "vec_new" || name = "owned_vec_new"
                              || name = "strbuf_new" || name = "map_new" in
    let eta_table_idx_opt =
      if (not is_shadowed) && is_nullary_factory then
        match e.Ast.ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyArrow (_, ret_ty) when ty_is_concrete (Ast.walk ret_ty) ->
             let ret_ty = Ast.walk ret_ty in
             (* Pick adapter slug + set runtime usage flags *)
             let slug =
               match name, Ast.walk ret_ty with
               | "vec_new", _ -> vec_used := true; "vec_new"
               | "owned_vec_new", _ -> vec_used := true; "owned_vec_new"
               | "strbuf_new", _ -> strbuf_used := true; "strbuf_new"
               | "map_new", Ast.TyCon ("Map", [_; k_ty; _]) ->
                 let k_tag =
                   match Ast.walk k_ty with
                   | Ast.TyInt -> map_int_used := true; "int"
                   | Ast.TyStr -> map_str_used := true; "str"
                   | _ -> "?"
                 in
                 "map_new_" ^ k_tag
               | _ -> "?"
             in
             let idx =
               match Hashtbl.find_opt eta_adapters_wasm slug with
               | Some (_, _, i) -> i
               | None ->
                 let i = register_in_table ("eta_" ^ slug) in
                 Hashtbl.add eta_adapters_wasm slug (name, ret_ty, i);
                 i
             in
             Some idx
           | _ -> None)
        | None -> None
      else None
    in
    (* Phase 15.4: curried multi-arg builtins like vec_*, owned_vec_*,
       strbuf_*, map_* are still not first-class (eta is for nullary
       factories only). *)
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
      || name = "map_set" || name = "map_get" || name = "map_iter"
      || name = "map_has" || name = "map_len"
    in
    let is_phase38c_target =
      name = "owned_vec_push" || name = "owned_vec_get"
      || name = "vec_push" || name = "vec_get"
      || name = "strbuf_push"
      || name = "map_get" || name = "map_has"
      || name = "map_set" || name = "vec_set"
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
    let phase38c_emittable =
      let curried_ok =
        not is_shadowed && is_curried_collection_builtin && is_phase38c_target
      in
      let single_ok =
        not is_shadowed && is_single_arg_value_builtin
      in
      if curried_ok || single_ok then
        match e.Ast.ty with
        | Some t when ty_is_concrete (Ast.walk t) ->
          (match Ast.walk t with
           | Ast.TyArrow _ -> true
           | _ -> false)
        | _ -> false
      else false
    in
    if not is_shadowed && is_curried_collection_builtin && not phase38c_emittable then
      raise (Codegen_error (e.Ast.loc,
        "unsupported in Wasm codegen subset: " ^ name
        ^ " as a value (Phase 15.4-15.10: curried multi-arg builtin only supports direct application, partial support in progress in Phase 38.C)"));
    if not is_shadowed && is_single_arg_value_builtin && not phase38c_emittable then
      raise (Codegen_error (e.Ast.loc,
        "unsupported in Wasm codegen subset: " ^ name
        ^ " as a value: type is polymorphic (Phase 38.A1 MVP: wrap with `fn x -> " ^ name ^ " x`)"));
    if not is_shadowed && is_nullary_factory && eta_table_idx_opt = None then
      raise (Codegen_error (e.Ast.loc,
        "unsupported in Wasm codegen subset: " ^ name
        ^ " as a value: return type is polymorphic, can't monomorphize \
           (Phase 35.3 MVP: use direct app or manual eta `fn () -> " ^ name ^ " ()`)"));
    if not is_shadowed && (name = "len" || name = "vec_to_list") then
      raise (Codegen_error (e.Ast.loc,
        "unsupported in Wasm codegen subset: " ^ name
        ^ " as a value (Phase 15.11/15.12: len / vec_to_list only support direct application)"));
    if phase38c_emittable then begin
      (* Phase 38.C-5: emit the synthesized eta-expanded Fun chain.
         Inner App nodes hit the existing direct-call fast paths
         (line 1653+). *)
      let arrow =
        match e.Ast.ty with
        | Some t -> Ast.walk t
        | None -> assert false
      in
      emit_expr (synthesize_curried_eta_wasm name arrow e.Ast.loc)
    end else
    (match eta_table_idx_opt with
     | Some idx ->
       (* Allocate a closure value `{ env = 0, fn_idx = idx }` on the
          bump heap, just like the toplevel-fn case below. *)
       emit_align_bump_4 ();  (* Phase 48.5: 4-byte align for host glue *)
       let base = fresh_local () in
       emit_instr "global.get $__lang_bump";
       emit_instr (Printf.sprintf "local.set %d" base);
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr "i32.const 8";
       emit_instr "i32.add";
       emit_instr "global.set $__lang_bump";
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr "i32.const 0";
       emit_instr "i32.store offset=0";
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr (Printf.sprintf "i32.const %d" idx);
       emit_instr "i32.store offset=4";
       emit_instr (Printf.sprintf "local.get %d" base)
     | None ->
    (match List.assoc_opt name !locals with
     | Some slot -> emit_instr (Printf.sprintf "local.get %d" slot)
     | None when Hashtbl.mem fn_closure_table_idx name ->
       (* Top-level fn as a value: materialize a closure
          `{ env = 0, fn_idx = table_idx }`. *)
       let idx = Hashtbl.find fn_closure_table_idx name in
       emit_align_bump_4 ();  (* Phase 48.5: 4-byte align for host glue *)
       let base = fresh_local () in
       emit_instr "global.get $__lang_bump";
       emit_instr (Printf.sprintf "local.set %d" base);
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr "i32.const 8";
       emit_instr "i32.add";
       emit_instr "global.set $__lang_bump";
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr "i32.const 0";
       emit_instr "i32.store offset=0";
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr (Printf.sprintf "i32.const %d" idx);
       emit_instr "i32.store offset=4";
       emit_instr (Printf.sprintf "local.get %d" base)
     | None when Hashtbl.mem top_globals_wasm name ->
       (* Phase 30.2c: top-level non-fn let as a Wasm global *)
       emit_instr (Printf.sprintf "global.get $%s" name)
     | None when Hashtbl.mem inner_lifts_wasm name ->
       (* Phase 39.A2: materialize inner-lifted fn at value position.
          Alloc env in the bump heap + store captures + write the closure
          value (env_offset, fn_idx) as an 8-byte struct to the bump heap. *)
       let li = Hashtbl.find inner_lifts_wasm name in
       let cap_count = List.length li.captures in
       let env_size = max 4 (cap_count * 4) in
       let table_idx =
         match Hashtbl.find_opt inner_lift_closures_emitted_wasm li.lifted_name with
         | Some idx -> idx
         | None ->
           let adapter_name = li.lifted_name ^ "_inner_closure_fn" in
           let idx = register_in_table adapter_name in
           Hashtbl.add inner_lift_closures_emitted_wasm li.lifted_name idx;
           inner_lift_closure_pending_wasm :=
             (li.lifted_name, li.captures, idx)
             :: !inner_lift_closure_pending_wasm;
           idx
       in
       (* Reserve the env area *)
       let env_base = fresh_local () in
       emit_instr "global.get $__lang_bump";
       emit_instr (Printf.sprintf "local.set %d" env_base);
       emit_instr (Printf.sprintf "local.get %d" env_base);
       emit_instr (Printf.sprintf "i32.const %d" env_size);
       emit_instr "i32.add";
       emit_instr "global.set $__lang_bump";
       (* Store each capture into an env field *)
       List.iteri (fun i cn ->
         let cv_slot =
           match List.assoc_opt cn !locals with
           | Some s -> s
           | None ->
             unsupported e.Ast.loc
               ("inner-lifted fn `" ^ name ^ "`: cannot resolve capture `" ^ cn
                ^ "` (Wasm Phase 39.A2 MVP — only locals are supported)")
         in
         emit_instr (Printf.sprintf "local.get %d" env_base);
         emit_instr (Printf.sprintf "local.get %d" cv_slot);
         emit_instr (Printf.sprintf "i32.store offset=%d" (i * 4))
       ) li.captures;
       (* closure value `{env_offset, fn_table_idx}` written to the bump heap *)
       emit_align_bump_4 ();  (* Phase 48.5: 4-byte align for host glue *)
       let cl_base = fresh_local () in
       emit_instr "global.get $__lang_bump";
       emit_instr (Printf.sprintf "local.set %d" cl_base);
       emit_instr (Printf.sprintf "local.get %d" cl_base);
       emit_instr "i32.const 8";
       emit_instr "i32.add";
       emit_instr "global.set $__lang_bump";
       emit_instr (Printf.sprintf "local.get %d" cl_base);
       emit_instr (Printf.sprintf "local.get %d" env_base);
       emit_instr "i32.store offset=0";
       emit_instr (Printf.sprintf "local.get %d" cl_base);
       emit_instr (Printf.sprintf "i32.const %d" table_idx);
       emit_instr "i32.store offset=4";
       emit_instr (Printf.sprintf "local.get %d" cl_base)
     | None -> unsupported e.Ast.loc ("unbound variable: " ^ name)))
  | Ast.Annot (inner, _) -> emit_expr inner
  | Ast.Neg inner ->
    emit_instr "i32.const 0";
    emit_expr inner;
    emit_instr "i32.sub"
  | Ast.Bin (Ast.Concat, a, b) ->
    emit_expr a;
    emit_expr b;
    emit_instr "call $__lang_str_concat"
  | Ast.Bin (op, a, b) ->
    emit_expr a;
    emit_expr b;
    emit_instr (wasm_binop op)
  | Ast.Cmp (op, a, b) ->
    (* Phase 26.1: TyStr eq/ne via $__lang_streq; ordering (< <= > >=) via
       $__lang_str_compare (3-way, -1/0/1) compared to 0. *)
    let a_ty = match a.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyInt in
    (match a_ty, op with
     | Ast.TyStr, Ast.Eq ->
       emit_expr a; emit_expr b;
       emit_instr "call $__lang_streq"
     | Ast.TyStr, Ast.Ne ->
       emit_expr a; emit_expr b;
       emit_instr "call $__lang_streq";
       emit_instr "i32.eqz"
     | Ast.TyStr, (Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge) ->
       emit_expr a; emit_expr b;
       emit_instr "call $__lang_str_compare";
       emit_instr "i32.const 0";
       emit_instr (wasm_cmp op)
     | ty, Ast.Eq when needs_struct_eq ty ->
       emit_expr a; emit_expr b;
       emit_instr (Printf.sprintf "call $eq_%s" (ty_tag ty))
     | ty, Ast.Ne when needs_struct_eq ty ->
       emit_expr a; emit_expr b;
       emit_instr (Printf.sprintf "call $eq_%s" (ty_tag ty));
       emit_instr "i32.eqz"
     | _ ->
       emit_expr a;
       emit_expr b;
       emit_instr (wasm_cmp op))
  | Ast.Logic (op, a, b) ->
    emit_expr a;
    emit_expr b;
    emit_instr (match op with Ast.And -> "i32.and" | Ast.Or -> "i32.or")
  | Ast.If (cond, t, f) ->
    emit_expr cond;
    emit_instr "if (result i32)";
    wasm_tail_pos := saved_tail;
    emit_expr t;
    emit_instr "else";
    wasm_tail_pos := saved_tail;
    emit_expr f;
    emit_instr "end"
  | Ast.Let (pat, value, body) ->
    (match pat.Ast.pnode with
     | Ast.P_var name when Hashtbl.mem inner_lifts_wasm name ->
       (* Phase 26.3: inner Let-bound Fun lifted to top-level. The Fun
          value has been pushed up; just emit the body, which will dispatch
          via App-Var to the lifted name. *)
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body
     | Ast.P_var name when saved_top && Hashtbl.mem top_globals_wasm name ->
       (* Phase 36 (DEFERRED §1.18 fix): file-scope global. Assign at
          source-order position so subsequent reads (via Var emit which
          does `global.get $name`) see the updated value.

          Gated on saved_top so a nested `let x = v in …` inside a fn
          body that happens to share a name with a top-level global
          does NOT overwrite the global — it becomes a plain local
          shadowing instead. *)
       emit_expr value;
       emit_instr (Printf.sprintf "global.set $%s" name);
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body
     | Ast.P_var name ->
       let slot = fresh_local () in
       emit_expr value;
       emit_instr (Printf.sprintf "local.set %d" slot);
       let prev = !locals in
       locals := (name, slot) :: prev;
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body;
       locals := prev
     | Ast.P_wild | Ast.P_unit ->
       (* Phase 22.1: evaluate RHS for side effects, drop, then body. *)
       emit_expr value;
       emit_instr "drop";
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body
     | Ast.P_tuple ps ->
       (* Phase 22.1: `let (a, b, ...) = E in B` — Wasm tuples are flat
          memory blocks of i32 cells, so emit a tuple-ptr local then
          `i32.load offset=N*4` per index. *)
       let tup_slot = fresh_local () in
       emit_expr value;
       emit_instr (Printf.sprintf "local.set %d" tup_slot);
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
       let prev = !locals in
       let new_bindings = ref [] in
       List.iteri (fun i p ->
         match p.Ast.pnode with
         | Ast.P_var n ->
           let slot = fresh_local () in
           emit_instr (Printf.sprintf "local.get %d" tup_slot);
           emit_instr (Printf.sprintf "i32.load offset=%d" (i * 4));
           emit_instr (Printf.sprintf "local.set %d" slot);
           new_bindings := (n, slot) :: !new_bindings
         | Ast.P_wild -> ()
         | _ ->
           raise (Codegen_error (p.Ast.ploc,
             "nested let-tuple patterns not supported in Wasm codegen subset"))
       ) ps;
       locals := !new_bindings @ prev;
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body;
       locals := prev
     | _ ->
       (* General irrefutable pattern (constructor / record / as / …):
          desugar `let pat = value in body` to a single-arm
          `match value with | pat -> body`, reusing the full pattern
          compiler. Previously only P_var / P_tuple / P_wild were handled
          here (the interp accepted every pattern) — a backend parity gap
          surfaced by the mere-blog dogfood. Reinstate the Let-body tail /
          top-level flags so the synthesized match arm keeps tail position. *)
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr { e with Ast.node = Ast.Match (value, [(pat, None, body)]) })
  | Ast.Let_rec (bindings, body) ->
    (* Phase 26.3: inner let-rec lifting. If all bindings are registered
       in inner_lifts_wasm (= lifted to top level), just emit body. *)
    if List.for_all (fun (n, _) -> Hashtbl.mem inner_lifts_wasm n) bindings then
      (wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body)
    else
      unsupported e.Ast.loc "let rec inside an expression (only allowed at top level)"
  | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "show: missing arg type"
    in
    let tag = ty_tag arg_ty in
    emit_expr arg;
    emit_instr (Printf.sprintf "call $show_%s" tag)
  | Ast.App ({ node = Ast.Var "to_json"; _ }, arg) ->
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "to_json: missing arg type"
    in
    emit_expr arg;
    emit_instr (Printf.sprintf "call $to_json_%s" (ty_tag arg_ty))
  | Ast.App ({ node = Ast.Var "of_json"; _ }, arg) ->
    let target_ty =
      match e.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "of_json: cannot infer target type"
    in
    emit_expr arg;
    emit_instr (Printf.sprintf "call $of_json_%s" (ty_tag target_ty))
  | Ast.App ({ node = Ast.Var "of_json_opt"; _ }, arg) ->
    let inner =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon ("option", [inner]) -> Ast.walk inner
         | _ -> unsupported e.Ast.loc "of_json_opt: result type is not an option")
      | None -> unsupported e.Ast.loc "of_json_opt: cannot infer target type"
    in
    emit_expr arg;
    emit_instr (Printf.sprintf "call $of_json_opt_%s" (ty_tag inner))
  | Ast.App _ as outer_app when
    (let rec head_is_extern e =
       match e.Ast.node with
       | Ast.App (f, _) -> head_is_extern f
       | Ast.Var name -> Hashtbl.mem extern_fn_decls_wasm name
       | _ -> false
     in head_is_extern { Ast.node = outer_app; ty = e.Ast.ty; loc = e.Ast.loc }) ->
    (* Phase 32.6 (C1 FFI multi-arg Wasm): collect the curried App chain;
       push all args, then collapse into a single call $<name>. *)
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
    let ret_ty = result_ty (Hashtbl.find extern_fn_decls_wasm name) in
    List.iter (fun a ->
      match a.Ast.node with
      | Ast.Unit_lit -> ()
      | _ -> emit_expr a)
      args;
    emit_instr (Printf.sprintf "call $%s" name);
    (match ret_ty with
     | Ast.TyUnit -> emit_instr "i32.const 0"
     | _ -> ())
  | Ast.App ({ node = Ast.Var "print"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $puts";
    emit_instr "i32.const 0"  (* unit / int 0 *)
  (* Q-012: spawn a `unit -> unit` closure on a Wasm worker. The closure
     value is an i32 pointer to its { env_offset, fn_idx } record in the
     (shared) linear memory; the host reads it and runs the closure on a
     worker instance that shares the same module + memory. Returns the
     thread id (i32). *)
  | Ast.App ({ node = Ast.Var "spawn"; _ }, clos) ->
    uses_threads := true;
    emit_expr clos;
    emit_instr "call $mere_spawn"
  | Ast.App ({ node = Ast.Var "join"; _ }, h) ->
    uses_threads := true;
    emit_expr h;
    emit_instr "call $mere_join"  (* returns i32 0 = unit *)
  (* Q-012: channels as host imports over the shared memory (the host does
     the atomic mutex/cond via JS Atomics on the shared buffer). Elements are
     i32 (Mere's Wasm value width). *)
  | Ast.App ({ node = Ast.Var "channel_new"; _ }, arg) ->
    uses_threads := true;
    emit_expr arg;                (* unit; consumed by the import *)
    emit_instr "call $mere_channel_new"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "channel_send"; _ }, ch_e); _ }, v_e) ->
    uses_threads := true;
    emit_expr ch_e;
    emit_expr v_e;
    emit_instr "call $mere_channel_send"  (* returns i32 0 = unit *)
  | Ast.App ({ node = Ast.Var "channel_recv"; _ }, ch_e) ->
    uses_threads := true;
    emit_expr ch_e;
    emit_instr "call $mere_channel_recv"
  | Ast.App ({ node = Ast.Var "mk_logger"; _ }, arg) ->
    (* Phase 16.3 / DEFERRED §1.5: build a Logger record in linear
       memory (3 closure ptrs, each pointing to an 8-byte { env=prefix,
       fn_idx } block). *)
    logger_used := true;
    emit_expr arg;
    emit_instr "call $__mere_mk_logger"
  | Ast.App ({ node = Ast.Var "mk_metrics"; _ }, arg) ->
    (* Phase 16.3: mk_metrics () — unit arg is consumed (still pushed
       so stack stays balanced) and `$__mere_mk_metrics` returns the
       Metrics record. *)
    metrics_used := true;
    emit_expr arg;
    emit_instr "drop";
    emit_instr "call $__mere_mk_metrics"
  | Ast.App ({ node = Ast.Var "str_len"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_strlen"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_index_of"; _ }, h_e); _ }, n_e) ->
    (* Phase 19.1.1: str_index_of h n — curried. *)
    emit_expr h_e;
    emit_expr n_e;
    emit_instr "call $__lang_str_index_of"
  (* Phase 36: str_trim / str_starts_with / str_replace — runtime helpers
     emitted unconditionally as part of the str runtime block. *)
  | Ast.App ({ node = Ast.Var "str_trim"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_str_trim"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_starts_with"; _ }, s_e); _ }, p_e) ->
    emit_expr s_e;
    emit_expr p_e;
    emit_instr "call $__lang_str_starts_with"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "str_replace"; _ }, s_e); _ }, old_e); _ }, new_e) ->
    emit_expr s_e;
    emit_expr old_e;
    emit_expr new_e;
    emit_instr "call $__lang_str_replace"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_ends_with"; _ }, s_e); _ }, p_e) ->
    emit_expr s_e;
    emit_expr p_e;
    emit_instr "call $__lang_str_ends_with"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_contains"; _ }, h_e); _ }, n_e) ->
    (* Phase 36: str_contains h n — implement via str_index_of != -1 *)
    emit_expr h_e;
    emit_expr n_e;
    emit_instr "call $__lang_str_index_of";
    emit_instr "i32.const -1";
    emit_instr "i32.ne"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_repeat"; _ }, s_e); _ }, n_e) ->
    emit_expr s_e;
    emit_expr n_e;
    emit_instr "call $__lang_str_repeat"
  | Ast.App ({ node = Ast.Var "str_rev"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_str_rev"
  | Ast.App ({ node = Ast.Var "not"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i32.eqz"
  | Ast.App ({ node = Ast.Var "abs"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_abs"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "min"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $__lang_min"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "max"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $__lang_max"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "clamp"; _ }, lo_e); _ }, hi_e); _ }, x_e) ->
    emit_expr lo_e;
    emit_expr hi_e;
    emit_expr x_e;
    emit_instr "call $__lang_clamp"
  | Ast.App ({ node = Ast.Var "chr"; _ }, arg) ->
    char_table_used := true;
    emit_expr arg;
    emit_instr "call $__lang_char_at_chr"
  | Ast.App ({ node = Ast.Var "ord"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i32.load8_u"
  | Ast.App ({ node = Ast.Var "to_upper"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_to_upper"
  | Ast.App ({ node = Ast.Var "to_lower"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_to_lower"
  | Ast.App ({ node = Ast.Var "even"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i32.const 2";
    emit_instr "i32.rem_s";
    emit_instr "i32.eqz"
  | Ast.App ({ node = Ast.Var "odd"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i32.const 2";
    emit_instr "i32.rem_s";
    emit_instr "i32.const 0";
    emit_instr "i32.ne"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "gcd"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $__lang_gcd"
  | Ast.App ({ node = Ast.Var "bool_of_str"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_bool_of_str"
  (* Phase 26.1: fail / char / substring / int_of_str / str_of_int /
     str_unescape — Wasm version of LLVM Phase 25.1 / 25.4. *)
  | Ast.App ({ node = Ast.Var "fail"; _ }, arg) ->
    fail_used := true;
    emit_expr arg;
    emit_instr "call $__lang_fail"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "char_at"; _ }, s_e); _ }, i_e) ->
    char_table_used := true;
    emit_expr s_e;
    emit_expr i_e;
    emit_instr "call $__lang_char_at"
  (* Phase 30.0 (DEFERRED §1.12 fix): respect user-defined shadow *)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_compare"; _ }, a_e); _ }, b_e) ->
    (* Phase 31.0: str_compare a b — across all 3 backends, return the
       sign-normalized -1/0/1 that matches interp. *)
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $__lang_str_compare"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_eq"; _ }, a_e); _ }, b_e) ->
    (* Phase 54.17 (OCaml side): str_eq a b — explicit content-equality
       for two runtime str values. Uses the same $__lang_streq helper
       as the polymorphic ==/!= path. *)
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $__lang_streq"
  (* Phase 34.3: float arithmetic + comparison + unary + conversions.
     Values are i32 ptr (f64 in heap). Each op is load → op → alloc + store. *)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var fname; _ }, a_e); _ }, b_e)
    when fname = "f_add" || fname = "f_sub" || fname = "f_mul" || fname = "f_div" ->
    let op = match fname with
      | "f_add" -> "f64.add" | "f_sub" -> "f64.sub"
      | "f_mul" -> "f64.mul" | "f_div" -> "f64.div" | _ -> "f64.add"
    in
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_expr b_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr op;
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.App ({ node = Ast.Var fname; _ }, a_e); _ }, b_e)
    when fname = "f_lt" || fname = "f_le" || fname = "f_gt" || fname = "f_ge" ->
    let op = match fname with
      | "f_lt" -> "f64.lt" | "f_le" -> "f64.le"
      | "f_gt" -> "f64.gt" | "f_ge" -> "f64.ge" | _ -> "f64.lt"
    in
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_expr b_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr op  (* f64.lt etc. return i32 (bool) *)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var fname; _ }, a_e); _ }, b_e)
    when fname = "f_min" || fname = "f_max" ->
    let op = if fname = "f_min" then "f64.min" else "f64.max" in
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_expr b_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr op;
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "f_neg"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr "f64.neg";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "f_abs"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr "f64.abs";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "float_of_int"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "f64.convert_i32_s";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "int_of_float"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr "i32.trunc_f64_s"
  | Ast.App ({ node = Ast.Var "str_of_float"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr "call $__lang_str_of_float"  (* env import, returns i32 ptr to str *)
  | Ast.App ({ node = Ast.Var "float_of_str"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "call $__lang_float_of_str";  (* env import, f64 *)
    emit_float_alloc_from_f64_on_stack ()
  (* Phase 34.4: libm functions — only sqrt is a Wasm intrinsic; others are host imports *)
  | Ast.App ({ node = Ast.Var "sqrt"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr "f64.sqrt";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var fname; _ }, a_e)
    when fname = "sin" || fname = "cos" || fname = "tan" ->
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr (Printf.sprintf "call $__lang_%s" fname);
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "f_pow"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_expr b_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr "call $__lang_f_pow";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "atan2"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e;
    emit_instr "f64.load offset=0 align=8";
    emit_expr b_e;
    emit_instr "f64.load offset=0 align=8";
    emit_instr "call $__lang_atan2";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "is_digit"; _ }, arg)
    when not (Hashtbl.mem toplevel_fn_names "is_digit") ->
    emit_expr arg;
    emit_instr "call $__lang_is_digit"
  | Ast.App ({ node = Ast.Var "is_alpha"; _ }, arg)
    when not (Hashtbl.mem toplevel_fn_names "is_alpha") ->
    emit_expr arg;
    emit_instr "call $__lang_is_alpha"
  | Ast.App ({ node = Ast.Var "is_space"; _ }, arg)
    when not (Hashtbl.mem toplevel_fn_names "is_space") ->
    emit_expr arg;
    emit_instr "call $__lang_is_space"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "substring"; _ }, s_e); _ }, start_e); _ }, end_e) ->
    substring_used := true;
    emit_expr s_e;
    emit_expr start_e;
    emit_expr end_e;
    emit_instr "call $__lang_substring"
  | Ast.App ({ node = Ast.Var "int_of_str"; _ }, arg) ->
    int_of_str_used := true;
    emit_expr arg;
    emit_instr "call $__lang_int_of_str"
  | Ast.App ({ node = Ast.Var "str_of_int"; _ }, arg) ->
    (* str_of_int is an alias for show_int. *)
    emit_expr arg;
    emit_instr "call $show_int"
  | Ast.App ({ node = Ast.Var "str_unescape"; _ }, arg) ->
    str_unescape_used := true;
    emit_expr arg;
    emit_instr "call $__lang_str_unescape"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_split"; _ }, s_e); _ }, delim_e) ->
    (* Phase 26.5: str_split — returns list_str (boxed Cons cells). *)
    str_split_used := true;
    emit_expr s_e;
    emit_expr delim_e;
    emit_instr "call $__lang_str_split"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_join"; _ }, sep_e); _ }, xs_e) ->
    (* Phase 26.5: str_join — concatenate list_str separated by sep. *)
    str_join_used := true;
    emit_expr sep_e;
    emit_expr xs_e;
    emit_instr "call $__lang_str_join"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_count"; _ }, s_e); _ }, n_e) ->
    str_count_used := true;
    emit_expr s_e;
    emit_expr n_e;
    emit_instr "call $__lang_str_count"
  | Ast.App ({ node = Ast.Var "read_file"; _ }, path_e) ->
    (* Phase 26.5: WASI-lite — read_file delegated to host import. *)
    file_io_used := true;
    emit_expr path_e;
    emit_instr "call $__lang_read_file"
  | Ast.App ({ node = Ast.Var "list_dir"; _ }, _path_e) ->
    unsupported e.Ast.loc
      "list_dir is unsupported in Wasm codegen (Phase 44 MVP scope = interp + C only)"
  | Ast.App ({ node = Ast.Var "mkdir_p"; _ }, _path_e) ->
    unsupported e.Ast.loc
      "mkdir_p is unsupported in Wasm codegen (Phase 44 MVP scope = interp + C only)"
  | Ast.App ({ node = Ast.Var "file_mtime"; _ }, _) ->
    unsupported e.Ast.loc
      "file_mtime is unsupported in Wasm codegen (Phase 44.6 MVP = interp + C only)"
  | Ast.App ({ node = Ast.Var "sleep_ms"; _ }, _) ->
    unsupported e.Ast.loc
      "sleep_ms is unsupported in Wasm codegen (Phase 44.6 MVP = interp + C only)"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "write_file"; _ }, path_e); _ }, content_e) ->
    file_io_used := true;
    emit_expr path_e;
    emit_expr content_e;
    emit_instr "call $__lang_write_file"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "try_or"; _ }, fn_e); _ }, default_e) ->
    (* Phase 26.2: try_or fn default — Wasm version. Since there's no
       setjmp/longjmp, switch fail to a flag-based non-trapping mode and
       manage the try_or scope with a global active counter. After calling
       the inner closure, check the flag; if set, return default. *)
    fail_used := true;
    (* Save active counter (depth) — using a fresh local. *)
    let saved_active = fresh_local () in
    let result_slot = fresh_local () in
    emit_instr "global.get $__lang_fail_active";
    emit_instr (Printf.sprintf "local.set %d" saved_active);
    emit_instr "i32.const 1";
    emit_instr "global.set $__lang_fail_active";
    emit_instr "i32.const 0";
    emit_instr "global.set $__lang_fail_flag";
    (* Call fn () via closure indirect — fn_e is a closure value. *)
    let cl_slot = fresh_local () in
    emit_expr fn_e;
    emit_instr (Printf.sprintf "local.set %d" cl_slot);
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i32.load offset=0";   (* env *)
    emit_instr "i32.const 0";          (* unit arg *)
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i32.load offset=4";   (* fn_idx *)
    emit_instr "call_indirect (type $cl)";
    emit_instr (Printf.sprintf "local.set %d" result_slot);
    (* Restore active counter. *)
    emit_instr (Printf.sprintf "local.get %d" saved_active);
    emit_instr "global.set $__lang_fail_active";
    (* If fail flag set, drop result + emit default; else use result. *)
    emit_instr "global.get $__lang_fail_flag";
    emit_instr "if (result i32)";
    emit_instr "i32.const 0";
    emit_instr "global.set $__lang_fail_flag";
    emit_expr default_e;
    emit_instr "else";
    emit_instr (Printf.sprintf "local.get %d" result_slot);
    emit_instr "end"
  | Ast.App ({ node = Ast.Var "vec_new"; _ }, _arg) ->
    (* Phase 15.4: vec_new () — ignore region (Wasm's bump is a single
       global), and since all elements are 4-byte i32 a single runtime
       suffices. arg is a unit literal so don't push it. *)
    vec_used := true;
    emit_instr "call $mere_vec_new"
  | Ast.App ({ node = Ast.Var "vec_len"; _ }, arg) ->
    vec_used := true;
    emit_expr arg;
    emit_instr "call $mere_vec_len"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_push"; _ }, vec_e); _ }, val_e) ->
    vec_used := true;
    emit_expr vec_e;
    emit_expr val_e;
    emit_instr "call $mere_vec_push"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_get"; _ }, vec_e); _ }, idx_e) ->
    vec_used := true;
    emit_expr vec_e;
    emit_expr idx_e;
    emit_instr "call $mere_vec_get"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_set"; _ }, vec_e); _ }, idx_e); _ }, val_e) ->
    (* Phase 15.5: vec_set v i x *)
    vec_used := true;
    emit_expr vec_e;
    emit_expr idx_e;
    emit_expr val_e;
    emit_instr "call $mere_vec_set"
  | Ast.App ({ node = Ast.Var "vec_reverse"; _ }, vec_e) ->
    (* Phase 19.3: vec_reverse v — in-place *)
    vec_used := true;
    emit_expr vec_e;
    emit_instr "call $mere_vec_reverse"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_concat"; _ }, a_e); _ }, b_e) ->
    (* Phase 19.3: vec_concat a b — new Vec *)
    vec_used := true;
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $mere_vec_concat"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_sort"; _ }, vec_e); _ }, cmp_e) ->
    (* Phase 19.3: vec_sort v cmp — closure dispatch via call_indirect.
       In-place insertion sort with comparator returning int. *)
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr vec_e;
    emit_expr cmp_e;
    emit_instr "call $mere_vec_sort"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_iter"; _ }, vec_e); _ }, fn_e) ->
    (* Phase 15.5: vec_iter v f *)
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr vec_e;
    emit_expr fn_e;
    emit_instr "call $mere_vec_iter"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_fold"; _ }, vec_e); _ }, acc_e); _ }, fn_e) ->
    (* Phase 15.5: vec_fold v acc f *)
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr vec_e;
    emit_expr acc_e;
    emit_expr fn_e;
    emit_instr "call $mere_vec_fold"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_map"; _ }, vec_e); _ }, fn_e) ->
    (* Phase 15.6: vec_map v f *)
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr vec_e;
    emit_expr fn_e;
    emit_instr "call $mere_vec_map"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_filter"; _ }, vec_e); _ }, fn_e) ->
    (* Phase 15.6: vec_filter v f *)
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr vec_e;
    emit_expr fn_e;
    emit_instr "call $mere_vec_filter"
  | Ast.App ({ node = Ast.Var "owned_vec_new"; _ }, _arg) ->
    (* Phase 15.7: In Wasm, OwnedVec and Vec use the same bump runtime, so
       owned_vec_new = $mere_vec_new (alias). *)
    vec_used := true;
    emit_instr "call $mere_vec_new"
  | Ast.App ({ node = Ast.Var "owned_vec_len"; _ }, arg) ->
    vec_used := true;
    emit_expr arg;
    emit_instr "call $mere_vec_len"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "owned_vec_push"; _ }, vec_e); _ }, val_e) ->
    vec_used := true;
    emit_expr vec_e;
    emit_expr val_e;
    emit_instr "call $mere_vec_push"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "owned_vec_get"; _ }, vec_e); _ }, idx_e) ->
    vec_used := true;
    emit_expr vec_e;
    emit_expr idx_e;
    emit_instr "call $mere_vec_get"
  | Ast.App ({ node = Ast.Var "vec_to_owned"; _ }, vec_e) ->
    (* Phase 15.7: In Wasm the runtime representations of Vec and OwnedVec
       are the same, so just deep-copy with $mere_vec_clone. *)
    vec_used := true;
    emit_expr vec_e;
    emit_instr "call $mere_vec_clone"
  | Ast.App ({ node = Ast.Var "owned_vec_to_vec"; _ }, owned_e) ->
    vec_used := true;
    emit_expr owned_e;
    emit_instr "call $mere_vec_clone"
  | Ast.App ({ node = Ast.Var "len"; _ }, arg) ->
    (* Phase 15.11: len ad-hoc dispatch — route to the corresponding _len
       helper based on arg.ty. In Wasm all values are i32. *)
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> Ast.walk t
      | None -> raise (Codegen_error (arg.Ast.loc, "len: missing arg type info"))
    in
    (match arg_ty with
     | Ast.TyCon ("Vec", _) | Ast.TyCon ("OwnedVec", _) ->
       vec_used := true;
       emit_expr arg;
       emit_instr "call $mere_vec_len"
     | Ast.TyCon ("StrBuf", _) ->
       strbuf_used := true;
       emit_expr arg;
       emit_instr "call $mere_strbuf_len"
     | Ast.TyCon ("Map", _) ->
       let k_tag = map_key_tag_of_wasm arg.Ast.ty arg.Ast.loc in
       (if k_tag = "int" then map_int_used := true else map_str_used := true);
       emit_expr arg;
       emit_instr (Printf.sprintf "call $mere_map_%s_len" k_tag)
     | Ast.TyStr ->
       emit_expr arg;
       emit_instr "call $__lang_strlen"
     | Ast.TyTuple ts ->
       (* Static arity. arg may be side-effectful, so drop it. *)
       emit_expr arg;
       emit_instr "drop";
       emit_instr (Printf.sprintf "i32.const %d" (List.length ts))
     | Ast.TyCon (n, _)
       when Hashtbl.mem Exhaustive.type_variants n
            && Hashtbl.mem variant_tags "Cons"
            && Hashtbl.mem variant_tags "Nil" ->
       (* Phase 15.12: `len` on `T list` — shared $mere_list_len. *)
       list_len_used := true;
       emit_expr arg;
       emit_instr "call $mere_list_len"
     | _ ->
       raise (Codegen_error (e.Ast.loc,
         "len: arg type has no codegen-defined length")))
  | Ast.App ({ node = Ast.Var "map_new"; _ }, _arg) ->
    (* Phase 15.10: map_new () — in Wasm ignore region, pick only the key type. *)
    let k_tag = map_key_tag_of_wasm e.Ast.ty e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_instr (Printf.sprintf "call $mere_map_%s_new" k_tag)
  | Ast.App ({ node = Ast.Var "map_len"; _ }, arg) ->
    let k_tag = map_key_tag_of_wasm arg.Ast.ty arg.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_expr arg;
    emit_instr (Printf.sprintf "call $mere_map_%s_len" k_tag)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_get"; _ }, m_e); _ }, k_e) ->
    let k_tag = map_key_tag_of_wasm m_e.Ast.ty m_e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_expr m_e;
    emit_expr k_e;
    emit_instr (Printf.sprintf "call $mere_map_%s_get" k_tag)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_has"; _ }, m_e); _ }, k_e) ->
    let k_tag = map_key_tag_of_wasm m_e.Ast.ty m_e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_expr m_e;
    emit_expr k_e;
    emit_instr (Printf.sprintf "call $mere_map_%s_has" k_tag)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_delete"; _ }, m_e); _ }, k_e) ->
    (* Phase 39.A' #2: map_delete m k *)
    let k_tag = map_key_tag_of_wasm m_e.Ast.ty m_e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_expr m_e;
    emit_expr k_e;
    emit_instr (Printf.sprintf "call $mere_map_%s_delete" k_tag)
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "map_set"; _ }, m_e); _ }, k_e); _ }, v_e) ->
    let k_tag = map_key_tag_of_wasm m_e.Ast.ty m_e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_expr m_e;
    emit_expr k_e;
    emit_expr v_e;
    emit_instr (Printf.sprintf "call $mere_map_%s_set" k_tag)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_iter"; _ }, m_e); _ }, fn_e) ->
    (* Phase 19.2: map_iter m f — closure dispatch via call_indirect.
       Need both the table (vec_higher_order flag) and the basic vec
       helpers (since vec_higher_order_runtime contains vec_map / filter
       that call $mere_vec_new). Setting vec_used pulls them in. *)
    let k_tag = map_key_tag_of_wasm m_e.Ast.ty m_e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr m_e;
    emit_expr fn_e;
    emit_instr (Printf.sprintf "call $mere_map_%s_iter" k_tag)
  | Ast.App ({ node = Ast.Var "vec_to_list"; _ }, vec_e) ->
    (* Phase 15.12: vec_to_list — shared $mere_vec_to_list helper. *)
    vec_used := true;
    vec_to_list_used := true;
    emit_expr vec_e;
    emit_instr "call $mere_vec_to_list"
  | Ast.App ({ node = Ast.Var "strbuf_new"; _ }, _arg) ->
    (* Phase 15.9: strbuf_new () — ignore region (Wasm's bump is a single
       global). *)
    strbuf_used := true;
    emit_instr "call $mere_strbuf_new"
  | Ast.App ({ node = Ast.Var "strbuf_len"; _ }, arg) ->
    strbuf_used := true;
    emit_expr arg;
    emit_instr "call $mere_strbuf_len"
  | Ast.App ({ node = Ast.Var "strbuf_to_str"; _ }, arg) ->
    strbuf_used := true;
    emit_expr arg;
    emit_instr "call $mere_strbuf_to_str"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "strbuf_push"; _ }, sb_e); _ }, str_e) ->
    strbuf_used := true;
    emit_expr sb_e;
    emit_expr str_e;
    emit_instr "call $mere_strbuf_push"
  | Ast.App ({ node = Ast.Var "fst"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i32.load offset=0"
  | Ast.App ({ node = Ast.Var "snd"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i32.load offset=4"
  | Ast.App ({ node = Ast.Var name; _ }, arg)
    when Hashtbl.mem inner_lifts_wasm name ->
    (* Phase 26.3: inner-lifted call — emit captures (looked up via
       current locals) + arg, then call $<lifted_name>. *)
    let li = Hashtbl.find inner_lifts_wasm name in
    List.iter (fun cap ->
      match List.assoc_opt cap !locals with
      | Some slot -> emit_instr (Printf.sprintf "local.get %d" slot)
      | None when Hashtbl.mem top_globals_wasm cap ->
        emit_instr (Printf.sprintf "global.get $%s" cap)
      | None -> unsupported e.Ast.loc
          (Printf.sprintf "inner-lifted capture `%s` not in scope" cap)
    ) li.captures;
    emit_expr arg;
    let call_op = if saved_tail then "return_call" else "call" in
    emit_instr (Printf.sprintf "%s $%s" call_op li.lifted_name)
  | Ast.App ({ node = Ast.Var name; ty = f_ty; _ }, arg)
    when Hashtbl.mem toplevel_fn_names name ->
    emit_expr arg;
    let dispatch_name =
      if Hashtbl.mem multi_inst_fns_wasm name then
        match f_ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyArrow _ as arrow -> mangled_inst_name_wasm name arrow
           | _ -> name)
        | None -> name
      else name
    in
    let call_op = if saved_tail then "return_call" else "call" in
    emit_instr (Printf.sprintf "%s $%s" call_op dispatch_name)
  | Ast.App (f, arg) ->
    (* Indirect call via call_indirect on the closure value's table
       index. closure layout: { env @ offset 0, fn_idx @ offset 4 }. *)
    let cl_slot = fresh_local () in
    emit_expr f;
    emit_instr (Printf.sprintf "local.set %d" cl_slot);
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i32.load offset=0";
    emit_expr arg;
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i32.load offset=4";
    let call_op = if saved_tail then "return_call_indirect" else "call_indirect" in
    emit_instr (Printf.sprintf "%s (type $cl)" call_op)
  | Ast.Record_lit (name, fields) when Hashtbl.mem Typer.views name ->
    (* View literal: same memory layout as a record (i32 per field),
       allocated from the active region's bump pointer. In Wasm all
       Lang regions share a single bump pointer so we use it directly. *)
    let info = Hashtbl.find Typer.views name in
    let decl_fields = info.Typer.v_fields in
    let n = List.length decl_fields in
    let base_slot = fresh_local () in
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" base_slot);
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr (Printf.sprintf "i32.const %d" (4 * n));
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    List.iteri (fun i (fname, _) ->
      let v_expr =
        match List.assoc_opt fname fields with
        | Some v -> v
        | None -> unsupported e.Ast.loc
                    (Printf.sprintf "missing field `%s` in view literal" fname)
      in
      emit_instr (Printf.sprintf "local.get %d" base_slot);
      emit_expr v_expr;
      emit_instr (Printf.sprintf "i32.store offset=%d" (4 * i))
    ) decl_fields;
    emit_instr (Printf.sprintf "local.get %d" base_slot)
  | Ast.Record_lit (name, fields) ->
    let info =
      match Hashtbl.find_opt Typer.records name with
      | Some i -> i
      | None -> unsupported e.Ast.loc ("unknown record type: " ^ name)
    in
    (* Wasm layout is uniform (all fields are i32 / 4 bytes), so
       polymorphic records use the same code as monomorphic ones — no
       per-instance specialization needed unlike LLVM. *)
    let decl_fields = info.Typer.r_fields in
    let n = List.length decl_fields in
    let base_slot = fresh_local () in
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" base_slot);
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr (Printf.sprintf "i32.const %d" (4 * n));
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    List.iteri (fun i (fname, _) ->
      let v_expr =
        match List.assoc_opt fname fields with
        | Some v -> v
        | None -> unsupported e.Ast.loc
                    (Printf.sprintf "missing field `%s` in record literal" fname)
      in
      emit_instr (Printf.sprintf "local.get %d" base_slot);
      emit_expr v_expr;
      emit_instr (Printf.sprintf "i32.store offset=%d" (4 * i))
    ) decl_fields;
    emit_instr (Printf.sprintf "local.get %d" base_slot)
  | Ast.Field_get (inner, fname) ->
    let raw_ty =
      match inner.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "field access: missing inner type"
    in
    (* Phase 19.x: field access through a borrow — unwrap TyRef and treat
       as the inner T's record. In Wasm everything is i32 (ptr) so the
       record's value representation is unchanged and field access uses
       the same steps. *)
    let inner_ty =
      match raw_ty with
      | Ast.TyRef (_, _, t) -> Ast.walk t
      | _ -> raw_ty
    in
    let rname, fields =
      match inner_ty with
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.views n ->
        (n, (Hashtbl.find Typer.views n).Typer.v_fields)
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
        (n, (Hashtbl.find Typer.records n).Typer.r_fields)
      | _ -> unsupported e.Ast.loc "field access on non-record/view"
    in
    let rec find_idx i = function
      | [] -> unsupported e.Ast.loc
                (Printf.sprintf "%s has no field `%s`" rname fname)
      | (n, _) :: _ when n = fname -> i
      | _ :: rest -> find_idx (i + 1) rest
    in
    let idx = find_idx 0 fields in
    emit_expr inner;
    (* Phase 19.x: if through a borrow (raw_ty is TyRef), Ref has added a
       4-byte box, so we need an extra i32.load to unbox. *)
    (match raw_ty with
     | Ast.TyRef _ -> emit_instr "i32.load offset=0"
     | _ -> ());
    emit_instr (Printf.sprintf "i32.load offset=%d" (4 * idx))
  | Ast.Record_update (base, updates) ->
    let base_ty =
      match base.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "record update: missing base type"
    in
    let rname =
      match base_ty with
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n -> n
      | _ -> unsupported e.Ast.loc "record update on non-record"
    in
    let info = Hashtbl.find Typer.records rname in
    let decl_fields = info.Typer.r_fields in
    let n = List.length decl_fields in
    let src_slot = fresh_local () in
    let dst_slot = fresh_local () in
    (* Evaluate base into src local. *)
    emit_expr base;
    emit_instr (Printf.sprintf "local.set %d" src_slot);
    (* Reserve memory for new struct. *)
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" dst_slot);
    emit_instr (Printf.sprintf "local.get %d" dst_slot);
    emit_instr (Printf.sprintf "i32.const %d" (4 * n));
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    (* Fill in each field: from update if present, else load from src. *)
    List.iteri (fun i (fname, _) ->
      emit_instr (Printf.sprintf "local.get %d" dst_slot);
      (match List.assoc_opt fname updates with
       | Some v_expr -> emit_expr v_expr
       | None ->
         emit_instr (Printf.sprintf "local.get %d" src_slot);
         emit_instr (Printf.sprintf "i32.load offset=%d" (4 * i)));
      emit_instr (Printf.sprintf "i32.store offset=%d" (4 * i))
    ) decl_fields;
    emit_instr (Printf.sprintf "local.get %d" dst_slot)
  | Ast.Constr (raw_cname, arg_opt) ->
    (* Phase 42: try raw qualified lookup first for disambiguation, fall back
       to canonical. variant_tags is keyed by bare names, so use canonical. *)
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
    let tag =
      match Hashtbl.find_opt variant_tags cname with
      | Some t -> t
      | None -> unsupported e.Ast.loc ("constructor without tag: " ^ raw_cname)
    in
    (* Phase 26.0: cell size is 8 bytes whenever the variant has any
       payload-bearing ctor (uniform layout `{i32 tag, i32 payload_i32}`).
       The payload_i32 holds either an inline value (int / bool / str ptr)
       or a pointer to a separately-allocated tuple/record (already a
       Wasm-side pointer, so no extra boxing is needed). *)
    let has_payload = variant_has_payload type_name in
    let n_bytes = if has_payload then 8 else 4 in
    let base_slot = fresh_local () in
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" base_slot);
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr (Printf.sprintf "i32.const %d" n_bytes);
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    (* Store tag at offset 0. *)
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr (Printf.sprintf "i32.const %d" tag);
    emit_instr "i32.store offset=0";
    (match arg_opt with
     | None -> ()
     | Some arg ->
       emit_instr (Printf.sprintf "local.get %d" base_slot);
       emit_expr arg;
       emit_instr "i32.store offset=4");
    emit_instr (Printf.sprintf "local.get %d" base_slot)
  | Ast.Match (scrut, arms) ->
    let scrut_ty =
      match scrut.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "match: missing scrutinee type"
    in
    let scrut_slot = fresh_local () in
    emit_expr scrut;
    emit_instr (Printf.sprintf "local.set %d" scrut_slot);
    (* combine_and pushes both conds, runs i32.and, stores in a fresh local. *)
    let combine_and (a : int) (b : int) : int =
      let slot = fresh_local () in
      emit_instr (Printf.sprintf "local.get %d" a);
      emit_instr (Printf.sprintf "local.get %d" b);
      emit_instr "i32.and";
      emit_instr (Printf.sprintf "local.set %d" slot);
      slot
    in
    let true_cond () =
      let slot = fresh_local () in
      emit_instr "i32.const 1";
      emit_instr (Printf.sprintf "local.set %d" slot);
      slot
    in
    (* Fully recursive pattern compile. Returns (cond local slot,
       (name, value-slot) bindings). *)
    let rec compile_pat (pat : Ast.pattern) (v_slot : int) (v_ty : Ast.ty)
      : int * (string * int) list =
      match pat.Ast.pnode with
      | Ast.P_wild -> (true_cond (), [])
      | Ast.P_var n -> (true_cond (), [(n, v_slot)])
      | Ast.P_unit -> (true_cond (), [])
      | Ast.P_int n ->
        let slot = fresh_local () in
        emit_instr (Printf.sprintf "local.get %d" v_slot);
        emit_instr (Printf.sprintf "i32.const %d" n);
        emit_instr "i32.eq";
        emit_instr (Printf.sprintf "local.set %d" slot);
        (slot, [])
      | Ast.P_bool b ->
        let slot = fresh_local () in
        emit_instr (Printf.sprintf "local.get %d" v_slot);
        emit_instr (Printf.sprintf "i32.const %d" (if b then 1 else 0));
        emit_instr "i32.eq";
        emit_instr (Printf.sprintf "local.set %d" slot);
        (slot, [])
      | Ast.P_str s ->
        let lit_off = fresh_str_offset s in
        let slot = fresh_local () in
        emit_instr (Printf.sprintf "local.get %d" v_slot);
        emit_instr (Printf.sprintf "i32.const %d" lit_off);
        emit_instr "call $__lang_streq";
        emit_instr (Printf.sprintf "local.set %d" slot);
        (slot, [])
      | Ast.P_as (inner, n) ->
        let (c, bs) = compile_pat inner v_slot v_ty in
        (c, (n, v_slot) :: bs)
      | Ast.P_tuple pats ->
        let elem_tys =
          match Ast.walk v_ty with Ast.TyTuple ts -> ts | _ ->
            unsupported pat.Ast.ploc "P_tuple on non-tuple"
        in
        let conds_bs = List.mapi (fun i p ->
          let elem_slot = fresh_local () in
          emit_instr (Printf.sprintf "local.get %d" v_slot);
          emit_instr (Printf.sprintf "i32.load offset=%d" (i * 4));
          emit_instr (Printf.sprintf "local.set %d" elem_slot);
          let elem_ty = try List.nth elem_tys i with _ -> Ast.TyInt in
          compile_pat p elem_slot elem_ty
        ) pats in
        let conds = List.map fst conds_bs in
        let cond = List.fold_left combine_and (true_cond ()) conds in
        let bs = List.concat_map snd conds_bs in
        (cond, bs)
      | Ast.P_record (_, sub_fields) ->
        let fields =
          match Ast.walk v_ty with
          | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
            (Hashtbl.find Typer.records n).Typer.r_fields
          | Ast.TyCon (n, _) when Hashtbl.mem Typer.views n ->
            (Hashtbl.find Typer.views n).Typer.v_fields
          | _ -> unsupported pat.Ast.ploc "P_record on non-record"
        in
        let idx_of fname =
          let rec find i = function
            | [] -> -1
            | (n, _) :: _ when n = fname -> i
            | _ :: rest -> find (i + 1) rest
          in find 0 fields
        in
        let ty_of fname = List.assoc fname fields in
        let conds_bs = List.map (fun (fname, sub_p) ->
          let i = idx_of fname in
          let ft = ty_of fname in
          let f_slot = fresh_local () in
          emit_instr (Printf.sprintf "local.get %d" v_slot);
          emit_instr (Printf.sprintf "i32.load offset=%d" (i * 4));
          emit_instr (Printf.sprintf "local.set %d" f_slot);
          compile_pat sub_p f_slot ft
        ) sub_fields in
        let conds = List.map fst conds_bs in
        let cond = List.fold_left combine_and (true_cond ()) conds in
        let bs = List.concat_map snd conds_bs in
        (cond, bs)
      | Ast.P_constr (raw_cname, sub) ->
        (* Phase 41 + 42: try raw qualified ctor lookup first for
           multi-module disambiguation, fall back to canonical. *)
        let cname = Ast.canonical_ctor raw_cname in
        let info =
          match Hashtbl.find_opt Typer.constructors raw_cname with
          | Some i -> i
          | None ->
            (match Hashtbl.find_opt Typer.constructors cname with
             | Some i -> i
             | None -> unsupported pat.Ast.ploc ("unknown ctor: " ^ raw_cname))
        in
        let _type_name = info.Typer.type_name in
        (* Phase 26.0: per-ctor payload type. For poly variants, walk
           the scrutinee type to extract concrete args and substitute
           the ctor's declared type params. *)
        let pty_opt =
          match info.Typer.arg with
          | None -> None
          | Some t ->
            (match Ast.walk v_ty, info.Typer.params with
             | Ast.TyCon (_n, args), params
               when List.length args = List.length params && params <> [] ->
               let args = List.map Ast.walk args in
               let mapping = List.combine params args in
               Some (Ast.walk (subst_params mapping t))
             | _ -> Some (Ast.walk t))
        in
        let tag =
          match Hashtbl.find_opt variant_tags cname with
          | Some t -> t
          | None -> unsupported pat.Ast.ploc ("ctor without tag: " ^ cname)
        in
        let tag_cond = fresh_local () in
        emit_instr (Printf.sprintf "local.get %d" v_slot);
        emit_instr "i32.load offset=0";
        emit_instr (Printf.sprintf "i32.const %d" tag);
        emit_instr "i32.eq";
        emit_instr (Printf.sprintf "local.set %d" tag_cond);
        (match sub, pty_opt with
         | None, _ -> (tag_cond, [])
         | Some sub_pat, Some pty ->
           (* Phase 38.C1 fix: guard the sub-pattern's payload deref with
              the outer tag check. An unconditional load offset=4 + deeper
              deref would read wrong memory and trap when the outer tag
              mismatches (discovered with `LApp (Lam (x, b), arg)` in
              lambda_calc.mere). With `if tag_cond then sub_cond else 0 end`,
              the sub-pattern's load / dereference runs only when the tag
              matches. *)
           let pl_slot = fresh_local () in
           let result_slot = fresh_local () in
           emit_instr (Printf.sprintf "local.get %d" tag_cond);
           emit_instr "if (result i32)";
           emit_instr (Printf.sprintf "local.get %d" v_slot);
           emit_instr "i32.load offset=4";
           emit_instr (Printf.sprintf "local.set %d" pl_slot);
           let (sub_cond, sub_bs) = compile_pat sub_pat pl_slot pty in
           emit_instr (Printf.sprintf "local.get %d" sub_cond);
           emit_instr "else";
           emit_instr "i32.const 0";
           emit_instr "end";
           emit_instr (Printf.sprintf "local.set %d" result_slot);
           (result_slot, sub_bs)
         | Some _, None ->
           unsupported pat.Ast.ploc
             ("pattern has payload but constructor `" ^ cname ^
              "` has no payload type"))
      | Ast.P_or _ ->
        unsupported pat.Ast.ploc "P_or should have been flattened"
    in
    (* Pre-flatten or-patterns into multiple arms. *)
    let rec expand_or (pat, guard, body) =
      match pat.Ast.pnode with
      | Ast.P_or (a, b) ->
        expand_or (a, guard, body) @ expand_or (b, guard, body)
      | _ -> [(pat, guard, body)]
    in
    let arms = List.concat_map expand_or arms in
    let rec emit_arms = function
      | [] -> emit_instr "unreachable"
      | (pat, guard, body) :: rest ->
        let (cond_slot, bindings) = compile_pat pat scrut_slot scrut_ty in
        (* Guard: evaluate within arm-bindings scope, AND with cond. If
           cond is false, short-circuit (don't even evaluate guard). *)
        let final_cond =
          match guard with
          | None -> cond_slot
          | Some g ->
            let g_slot = fresh_local () in
            emit_instr (Printf.sprintf "local.get %d" cond_slot);
            emit_instr "if (result i32)";
            let prev = !locals in
            locals := bindings @ prev;
            emit_expr g;
            locals := prev;
            emit_instr "else";
            emit_instr "i32.const 0";
            emit_instr "end";
            emit_instr (Printf.sprintf "local.set %d" g_slot);
            g_slot
        in
        emit_instr (Printf.sprintf "local.get %d" final_cond);
        emit_instr "if (result i32)";
        let prev = !locals in
        locals := bindings @ prev;
        wasm_tail_pos := saved_tail;
        emit_expr body;
        locals := prev;
        emit_instr "else";
        wasm_tail_pos := saved_tail;
        emit_arms rest;
        emit_instr "end"
    in
    emit_arms arms
  | Ast.Fun (param, _, fn_body) ->
    (* Anonymous Fun in expression position: register an adapter in the
       function table, build a closure value `{ env, fn_idx }`. Captures
       go into a memory-resident env struct (or env = 0 if there are
       none). *)
    let raw_fvs = free_vars fn_body [param] in
    let captures =
      List.filter_map (fun n ->
        match List.assoc_opt n !locals with
        | Some slot -> Some (n, slot)
        | None -> None) raw_fvs
    in
    let n = List.length captures in
    let adapter_name = fresh_anon_name () in
    let table_idx = register_in_table adapter_name in
    pending_closures :=
      { ce_adapter_name = adapter_name;
        ce_param = param;
        ce_body = fn_body;
        ce_captures = captures;
        ce_table_idx = table_idx;
        ce_host = !current_host_fn_wasm }
      :: !pending_closures;
    let env_slot = fresh_local () in
    let cl_slot = fresh_local () in
    if n = 0 then begin
      emit_instr "i32.const 0";
      emit_instr (Printf.sprintf "local.set %d" env_slot)
    end else begin
      emit_instr "global.get $__lang_bump";
      emit_instr (Printf.sprintf "local.set %d" env_slot);
      emit_instr (Printf.sprintf "local.get %d" env_slot);
      emit_instr (Printf.sprintf "i32.const %d" (n * 4));
      emit_instr "i32.add";
      emit_instr "global.set $__lang_bump";
      List.iteri (fun i (_, src_slot) ->
        emit_instr (Printf.sprintf "local.get %d" env_slot);
        emit_instr (Printf.sprintf "local.get %d" src_slot);
        emit_instr (Printf.sprintf "i32.store offset=%d" (i * 4))
      ) captures
    end;
    (* Build closure value: { env, fn_idx } at fresh memory slot. *)
    emit_align_bump_4 ();  (* Phase 48.5: 4-byte align for host glue *)
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" cl_slot);
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i32.const 8";
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr (Printf.sprintf "local.get %d" env_slot);
    emit_instr "i32.store offset=0";
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr (Printf.sprintf "i32.const %d" table_idx);
    emit_instr "i32.store offset=4";
    emit_instr (Printf.sprintf "local.get %d" cl_slot)
  | Ast.Tuple elems ->
    (* All elements occupy 4 bytes (i32 / ptr-style offset). The tuple
       value is the base offset into linear memory. RESERVE the memory
       up-front (advance bump immediately) so nested tuples / concat
       inside element evaluation get their own non-overlapping memory. *)
    let n = List.length elems in
    let base_slot = fresh_local () in
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" base_slot);
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr (Printf.sprintf "i32.const %d" (4 * n));
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    List.iteri (fun i el ->
      emit_instr (Printf.sprintf "local.get %d" base_slot);
      emit_expr el;
      emit_instr (Printf.sprintf "i32.store offset=%d" (4 * i))
    ) elems;
    emit_instr (Printf.sprintf "local.get %d" base_slot)
  | Ast.Region_block (_, body) ->
    (* All Lang regions share the single Wasm linear-memory bump
       pointer. Earlier we used a save / restore pattern so any
       allocations inside the body were reclaimed on exit (LIFO).
       Phase 16.4 / DEFERRED §1.6: that approach is unsound when a
       value allocated inside the region escapes — e.g.,
         let v = region R { vec_to_owned (...) } in ...
       returns an OwnedVec whose data lives inside R's bump range.
       After restore, subsequent allocations overwrite that data,
       corrupting fields like a record's str pointer. We now do NOT
       restore bump on region exit — Wasm semantics become a plain
       arena-leak (matches what the other backends effectively do for
       OwnedVec via main-end sweep). *)
    emit_expr body
  | Ast.Ref (_, _, inner) ->
    (* `&R v` — region-alloc 4 bytes, store value, return ptr. *)
    let base_slot = fresh_local () in
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" base_slot);
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr "i32.const 4";
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_expr inner;
    emit_instr "i32.store offset=0";
    emit_instr (Printf.sprintf "local.get %d" base_slot)
  | Ast.With (name, value, body) ->
    (* `with c = v in body` — bind v, run body, auto-invoke c.close
       if v has a `close: unit -> unit` field. *)
    let v_slot = fresh_local () in
    emit_expr value;
    emit_instr (Printf.sprintf "local.set %d" v_slot);
    let close_idx =
      match value.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
           let fields = (Hashtbl.find Typer.records n).Typer.r_fields in
           let rec find i = function
             | [] -> None
             | (fname, _) :: _ when fname = "close" -> Some i
             | _ :: rest -> find (i + 1) rest
           in find 0 fields
         | _ -> None)
      | _ -> None
    in
    let prev_locals = !locals in
    locals := (name, v_slot) :: prev_locals;
    emit_expr body;
    locals := prev_locals;
    (match close_idx with
     | None -> ()
     | Some idx ->
       (* Stash body's result, then call c.close(unit), restore result. *)
       let result_slot = fresh_local () in
       emit_instr (Printf.sprintf "local.set %d" result_slot);
       let cl_slot = fresh_local () in
       emit_instr (Printf.sprintf "local.get %d" v_slot);
       emit_instr (Printf.sprintf "i32.load offset=%d" (4 * idx));
       emit_instr (Printf.sprintf "local.set %d" cl_slot);
       emit_instr (Printf.sprintf "local.get %d" cl_slot);
       emit_instr "i32.load offset=0";  (* env *)
       emit_instr "i32.const 0";        (* unit arg *)
       emit_instr (Printf.sprintf "local.get %d" cl_slot);
       emit_instr "i32.load offset=4";  (* fn_idx *)
       emit_instr "call_indirect (type $cl)";
       emit_instr "drop";               (* discard close's return *)
       emit_instr (Printf.sprintf "local.get %d" result_slot))
  (* Phase 34.3: since the entire AST structure is now covered above, OCaml
     considers the fallback `| _ ->` redundant. We'd like to keep explicit
     unsupported errors tagged by node_name, but leaving a wildcard in each
     case would produce unused warnings — so completely removed. *)

(* Emit one top-level fn definition. Params are positional locals
   starting at slot 0; let-binding locals are mint-ed afterwards.
   Body's stack-top value is the function's return. *)
let emit_fn_def (f : fn_decl) : string =
  let saved_instrs = !instrs in
  let saved_local_counter = !local_counter in
  let saved_locals = !locals in
  let saved_host = !current_host_fn_wasm in
  set_inner_lifts_for_host_wasm f.name;
  current_host_fn_wasm := f.name;
  instrs := [];
  (* Param sits at slot 0. let-bindings start from slot 1. *)
  local_counter := 1;
  locals := [(f.param, 0)];
  let saved_tail = !wasm_tail_pos in
  wasm_tail_pos := true;
  emit_expr f.body;
  wasm_tail_pos := saved_tail;
  let body_instrs = List.rev !instrs in
  let extra_locals = !local_counter - 1 in
  instrs := saved_instrs;
  local_counter := saved_local_counter;
  locals := saved_locals;
  current_host_fn_wasm := saved_host;
  let local_decl =
    if extra_locals <= 0 then ""
    else
      Printf.sprintf "    (local%s)\n"
        (String.concat "" (List.init extra_locals (fun _ -> " i32")))
  in
  let indented_body =
    String.concat "\n" (List.map (fun s -> "    " ^ s) body_instrs)
  in
  ignore f.param_ty;
  ignore f.return_ty;
  Printf.sprintf
    "  (func $%s (param i32) (result i32)\n%s%s)"
    f.name local_decl indented_body

(* Phase 26.3: emit a lifted inner fn as top-level Wasm fn. Captures
   come before the original param as i32 locals (positional). The body
   resolves recursive lifted siblings via set_inner_lifts_for_host_wasm. *)
let emit_lifted_fn_wasm (lf : lifted_fn_wasm) : string =
  set_inner_lifts_for_host_wasm lf.l_host;
  let saved_instrs = !instrs in
  let saved_local_counter = !local_counter in
  let saved_locals = !locals in
  let saved_host = !current_host_fn_wasm in
  instrs := [];
  current_host_fn_wasm := lf.l_host;
  (* Allocate slots: captures at 0..N-1, param at N. *)
  let n_caps = List.length lf.l_captures in
  local_counter := n_caps + 1;
  let cap_locals = List.mapi (fun i n -> (n, i)) lf.l_captures in
  locals := (lf.l_param, n_caps) :: cap_locals;
  let saved_tail = !wasm_tail_pos in
  wasm_tail_pos := true;
  emit_expr lf.l_body;
  wasm_tail_pos := saved_tail;
  let body_instrs = List.rev !instrs in
  let extra_locals = !local_counter - (n_caps + 1) in
  instrs := saved_instrs;
  local_counter := saved_local_counter;
  locals := saved_locals;
  current_host_fn_wasm := saved_host;
  let param_decls =
    String.concat " "
      (List.init (n_caps + 1) (fun _ -> "(param i32)"))
  in
  let local_decl =
    if extra_locals <= 0 then ""
    else
      Printf.sprintf "    (local%s)\n"
        (String.concat "" (List.init extra_locals (fun _ -> " i32")))
  in
  let indented_body =
    String.concat "\n" (List.map (fun s -> "    " ^ s) body_instrs)
  in
  Printf.sprintf
    "  (func $%s %s (result i32)\n%s%s)"
    lf.l_name param_decls local_decl indented_body

(* Env-ignoring adapter so top-level fn `f` can be used as a closure
   value: `(env, x) -> result` that just calls `$f(x)`. *)
let emit_top_adapter (f : fn_decl) : string =
  Printf.sprintf
    "  (func $%s_closure (param i32) (param i32) (result i32)\n\
     \    local.get 1\n\
     \    call $%s)" f.name f.name

(* Phase 35.3: eta adapter for a nullary factory builtin used as a value.
   `slug` is the registered key in [eta_adapters_wasm]; `builtin` is the
   underlying name (vec_new / owned_vec_new / strbuf_new / map_new). The
   adapter ignores both arguments (env, unit) and calls the appropriate
   runtime helper. *)
let emit_eta_adapter_wasm (slug : string) (builtin : string) : string =
  let body =
    match builtin with
    | "vec_new" | "owned_vec_new" -> "call $mere_vec_new"
    | "strbuf_new" -> "call $mere_strbuf_new"
    | "map_new" ->
      let k_tag =
        if String.length slug > 8
           && String.sub slug 0 8 = "map_new_"
        then String.sub slug 8 (String.length slug - 8)
        else "int"
      in
      Printf.sprintf "call $mere_map_%s_new" k_tag
    | _ -> "unreachable"
  in
  Printf.sprintf
    "  (func $eta_%s (param i32) (param i32) (result i32)\n\
     \    %s)" slug body

(* Adapter for an anonymous Fun. Slot 0 = env ptr, slot 1 = param;
   capture locals start at slot 2. Loads each capture from env at the
   appropriate offset, then evaluates the original Fun body. *)
let emit_anon_adapter (ce : closure_emission) : string =
  let saved_instrs = !instrs in
  let saved_local_counter = !local_counter in
  let saved_locals = !locals in
  let saved_host = !current_host_fn_wasm in
  (* Phase 26.3: restore the host scope this closure was queued under so
     its body can resolve recursive calls into inner-lifted siblings. *)
  set_inner_lifts_for_host_wasm ce.ce_host;
  current_host_fn_wasm := ce.ce_host;
  instrs := [];
  let env_slot = 0 in
  let param_slot = 1 in
  let n = List.length ce.ce_captures in
  let capture_locals =
    List.mapi (fun i (cname, _) ->
      let slot = 2 + i in
      emit_instr (Printf.sprintf "local.get %d" env_slot);
      emit_instr (Printf.sprintf "i32.load offset=%d" (i * 4));
      emit_instr (Printf.sprintf "local.set %d" slot);
      (cname, slot)
    ) ce.ce_captures
  in
  local_counter := 2 + n;
  locals := (ce.ce_param, param_slot) :: capture_locals;
  let saved_tail = !wasm_tail_pos in
  wasm_tail_pos := true;
  emit_expr ce.ce_body;
  wasm_tail_pos := saved_tail;
  let body_instrs = List.rev !instrs in
  let extra_locals = !local_counter - 2 in
  instrs := saved_instrs;
  local_counter := saved_local_counter;
  locals := saved_locals;
  current_host_fn_wasm := saved_host;
  let local_decl =
    if extra_locals <= 0 then ""
    else
      Printf.sprintf "    (local%s)\n"
        (String.concat "" (List.init extra_locals (fun _ -> " i32")))
  in
  let indented_body =
    String.concat "\n" (List.map (fun s -> "    " ^ s) body_instrs)
  in
  Printf.sprintf
    "  (func $%s (param i32) (param i32) (result i32)\n%s%s)"
    ce.ce_adapter_name local_decl indented_body

(* Emit `show_<tag>(x: i32) -> i32` for one type. Returns the WAT
   function definition as a string. *)
let emit_show_fn (tag : string) (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt ->
    (* int → decimal string in a fresh 16-byte buffer, write digits
       right-to-left, return pointer to the first digit. *)
    {|  (func $show_int (param $n i32) (result i32)
    (local $buf i32) (local $i i32) (local $abs i32) (local $neg i32)
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (global.get $__lang_bump) (i32.const 16)))
    (local.set $i (i32.const 15))
    (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 0))
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then
        (local.set $neg (i32.const 1))
        (local.set $abs (i32.sub (i32.const 0) (local.get $n))))
      (else
        (local.set $neg (i32.const 0))
        (local.set $abs (local.get $n))))
    (if (i32.eqz (local.get $abs))
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 48))
        (return (i32.add (local.get $buf) (local.get $i)))))
    (block $end
      (loop $lp
        (br_if $end (i32.eqz (local.get $abs)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i))
          (i32.add (i32.const 48) (i32.rem_u (local.get $abs) (i32.const 10))))
        (local.set $abs (i32.div_u (local.get $abs) (i32.const 10)))
        (br $lp)))
    (if (local.get $neg)
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 45))))
    (i32.add (local.get $buf) (local.get $i)))|}
  | Ast.TyBool ->
    let t_off = intern_show_str "true" in
    let f_off = intern_show_str "false" in
    Printf.sprintf
      "  (func $show_bool (param $b i32) (result i32)\n\
      \    (if (result i32) (local.get $b)\n\
      \      (then (i32.const %d))\n\
      \      (else (i32.const %d))))"
      t_off f_off
  | Ast.TyStr ->
    let q_off = intern_show_str "\"" in
    (* Phase 26.6 (port of LLVM Phase 25.6): run %s through
       __lang_str_escape so output matches interp's show_str behavior. *)
    Printf.sprintf
      "  (func $show_str (param $s i32) (result i32)\n\
      \    (call $__lang_str_concat\n\
      \      (call $__lang_str_concat (i32.const %d) (call $__lang_str_escape (local.get $s)))\n\
      \      (i32.const %d)))"
      q_off q_off
  | Ast.TyUnit ->
    let off = intern_show_str "()" in
    Printf.sprintf
      "  (func $show_unit (param $u i32) (result i32)\n\
      \    (i32.const %d))"
      off
  | Ast.TyTuple ts ->
    let comma = intern_show_str ", " in
    let lparen = intern_show_str "(" in
    let rparen = intern_show_str ")" in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $show_%s (param $x i32) (result i32)\n" tag);
    Buffer.add_string lines "    (local $r i32)\n";
    Buffer.add_string lines
      (Printf.sprintf "    (local.set $r (i32.const %d))\n" lparen);
    List.iteri (fun i ety ->
      if i > 0 then
        Buffer.add_string lines
          (Printf.sprintf
             "    (local.set $r (call $__lang_str_concat (local.get $r) (i32.const %d)))\n"
             comma);
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) \
            (call $show_%s (i32.load offset=%d (local.get $x)))))\n"
           (ty_tag ety) (i * 4))
    ) ts;
    Buffer.add_string lines
      (Printf.sprintf
         "    (call $__lang_str_concat (local.get $r) (i32.const %d)))"
         rparen);
    Buffer.contents lines
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
    let info = Hashtbl.find Typer.records n in
    let mapping =
      if info.Typer.r_params = [] then []
      else List.combine info.Typer.r_params args
    in
    let hdr = intern_show_str (n ^ " { ") in
    let suffix = intern_show_str " }" in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $show_%s (param $x i32) (result i32)\n" tag);
    Buffer.add_string lines "    (local $r i32)\n";
    Buffer.add_string lines
      (Printf.sprintf "    (local.set $r (i32.const %d))\n" hdr);
    List.iteri (fun i (fname, ft) ->
      let ft = subst_params mapping ft in
      let sep =
        if i = 0 then intern_show_str (fname ^ " = ")
        else intern_show_str (", " ^ fname ^ " = ")
      in
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) (i32.const %d)))\n"
           sep);
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) \
            (call $show_%s (i32.load offset=%d (local.get $x)))))\n"
           (ty_tag ft) (i * 4))
    ) info.Typer.r_fields;
    Buffer.add_string lines
      (Printf.sprintf
         "    (call $__lang_str_concat (local.get $r) (i32.const %d)))"
         suffix);
    Buffer.contents lines
  | Ast.TyCon ("list", [elem_ty]) ->
    (* `'a list = Nil | Cons of 'a * 'a list` special-case: render as
       `[a, b, c]`. Walk via cur/acc/first locals; for each Cons node
       at offset 0 the tag is 1 and offset 4 holds the (head, tail)
       tuple offset. *)
    let lb = intern_show_str "[" in
    let rb = intern_show_str "]" in
    let comma = intern_show_str ", " in
    Printf.sprintf
      "  (func $show_%s (param $x i32) (result i32)\n\
      \    (local $cur i32) (local $acc i32) (local $first i32)\n\
      \    (local $tag i32) (local $pl i32) (local $h i32)\n\
      \    (local.set $acc (i32.const %d))\n\
      \    (local.set $cur (local.get $x))\n\
      \    (local.set $first (i32.const 1))\n\
      \    (block $end\n\
      \      (loop $lp\n\
      \        (local.set $tag (i32.load offset=0 (local.get $cur)))\n\
      \        (br_if $end (i32.eqz (local.get $tag)))\n\
      \        (local.set $pl (i32.load offset=4 (local.get $cur)))\n\
      \        (local.set $h (i32.load offset=0 (local.get $pl)))\n\
      \        (if (i32.eqz (local.get $first))\n\
      \          (then\n\
      \            (local.set $acc (call $__lang_str_concat (local.get $acc) (i32.const %d)))))\n\
      \        (local.set $acc (call $__lang_str_concat (local.get $acc) (call $show_%s (local.get $h))))\n\
      \        (local.set $first (i32.const 0))\n\
      \        (local.set $cur (i32.load offset=4 (local.get $pl)))\n\
      \        (br $lp)))\n\
      \    (call $__lang_str_concat (local.get $acc) (i32.const %d)))"
      tag lb comma (ty_tag elem_ty) rb
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.types n ->
    let vs =
      match Hashtbl.find_opt Exhaustive.type_variants n with
      | Some vs -> vs
      | None -> []
    in
    let mapping =
      match vs with
      | (cname, _) :: _ ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some info when info.Typer.params <> [] ->
           List.combine info.Typer.params args
         | _ -> [])
      | [] -> []
    in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $show_%s (param $x i32) (result i32)\n" tag);
    Buffer.add_string lines "    (local $tag i32)\n";
    Buffer.add_string lines
      "    (local.set $tag (i32.load offset=0 (local.get $x)))\n";
    (* Nested if/else chain over each ctor's tag. *)
    let rec emit_branches = function
      | [] -> "(unreachable)"
      | (cname, arg_opt) :: rest ->
        let ctor_tag =
          match Hashtbl.find_opt variant_tags cname with
          | Some t -> t
          | None -> raise (Codegen_error (Loc.dummy,
            "ctor without tag in show_fn: " ^ cname))
        in
        let arm_body =
          match arg_opt with
          | None ->
            Printf.sprintf "(i32.const %d)" (intern_show_str cname)
          | Some pty ->
            let pty = subst_params mapping pty in
            let prefix = intern_show_str (cname ^ " ") in
            Printf.sprintf
              "(call $__lang_str_concat (i32.const %d) \
               (call $show_%s (i32.load offset=4 (local.get $x))))"
              prefix (ty_tag pty)
        in
        Printf.sprintf
          "(if (result i32) (i32.eq (local.get $tag) (i32.const %d))\n\
          \      (then %s)\n\
          \      (else %s))"
          ctor_tag arm_body (emit_branches rest)
    in
    Buffer.add_string lines (Printf.sprintf "    %s)" (emit_branches vs));
    Buffer.contents lines
  | _ ->
    let off = intern_show_str ("<?show_" ^ tag ^ "?>") in
    Printf.sprintf
      "  (func $show_%s (param $x i32) (result i32)\n\
      \    (i32.const %d))"
      tag off

(* JSON sibling of emit_show_fn (derive slice, Wasm). Emits `to_json_<tag>`
   producing JSON: records -> objects (quoted field names, no type tag),
   lists/tuples -> arrays, nullary ctor -> "Name", payload ctor ->
   {"Name": payload}. int/bool/str are byte-identical to show so their
   bodies are copied; the rest use JSON delimiters. Recursive calls go to
   to_json_<tag>. Kept in sync with eval.ml / codegen_c.ml. *)
let emit_to_json_fn (tag : string) (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt ->
    {|  (func $to_json_int (param $n i32) (result i32)
    (local $buf i32) (local $i i32) (local $abs i32) (local $neg i32)
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (global.get $__lang_bump) (i32.const 16)))
    (local.set $i (i32.const 15))
    (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 0))
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then
        (local.set $neg (i32.const 1))
        (local.set $abs (i32.sub (i32.const 0) (local.get $n))))
      (else
        (local.set $neg (i32.const 0))
        (local.set $abs (local.get $n))))
    (if (i32.eqz (local.get $abs))
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 48))
        (return (i32.add (local.get $buf) (local.get $i)))))
    (block $end
      (loop $lp
        (br_if $end (i32.eqz (local.get $abs)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i))
          (i32.add (i32.const 48) (i32.rem_u (local.get $abs) (i32.const 10))))
        (local.set $abs (i32.div_u (local.get $abs) (i32.const 10)))
        (br $lp)))
    (if (local.get $neg)
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 45))))
    (i32.add (local.get $buf) (local.get $i)))|}
  | Ast.TyBool ->
    let t_off = intern_show_str "true" in
    let f_off = intern_show_str "false" in
    Printf.sprintf
      "  (func $to_json_bool (param $b i32) (result i32)\n\
      \    (if (result i32) (local.get $b)\n\
      \      (then (i32.const %d))\n\
      \      (else (i32.const %d))))"
      t_off f_off
  | Ast.TyStr ->
    let q_off = intern_show_str "\"" in
    Printf.sprintf
      "  (func $to_json_str (param $s i32) (result i32)\n\
      \    (call $__lang_str_concat\n\
      \      (call $__lang_str_concat (i32.const %d) (call $__lang_str_escape (local.get $s)))\n\
      \      (i32.const %d)))"
      q_off q_off
  | Ast.TyUnit ->
    let off = intern_show_str "null" in
    Printf.sprintf
      "  (func $to_json_unit (param $u i32) (result i32) (i32.const %d))" off
  | Ast.TyArrow _ ->
    let off = intern_show_str "null" in
    Printf.sprintf
      "  (func $to_json_%s (param $u i32) (result i32) (i32.const %d))" tag off
  | Ast.TyTuple ts ->
    let comma = intern_show_str "," in
    let lb = intern_show_str "[" in
    let rb = intern_show_str "]" in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $to_json_%s (param $x i32) (result i32)\n" tag);
    Buffer.add_string lines "    (local $r i32)\n";
    Buffer.add_string lines
      (Printf.sprintf "    (local.set $r (i32.const %d))\n" lb);
    List.iteri (fun i ety ->
      if i > 0 then
        Buffer.add_string lines
          (Printf.sprintf
             "    (local.set $r (call $__lang_str_concat (local.get $r) (i32.const %d)))\n"
             comma);
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) \
            (call $to_json_%s (i32.load offset=%d (local.get $x)))))\n"
           (ty_tag ety) (i * 4))
    ) ts;
    Buffer.add_string lines
      (Printf.sprintf
         "    (call $__lang_str_concat (local.get $r) (i32.const %d)))" rb);
    Buffer.contents lines
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
    let info = Hashtbl.find Typer.records n in
    let mapping =
      if info.Typer.r_params = [] then []
      else List.combine info.Typer.r_params args
    in
    let hdr = intern_show_str "{" in
    let suffix = intern_show_str "}" in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $to_json_%s (param $x i32) (result i32)\n" tag);
    Buffer.add_string lines "    (local $r i32)\n";
    Buffer.add_string lines
      (Printf.sprintf "    (local.set $r (i32.const %d))\n" hdr);
    List.iteri (fun i (fname, ft) ->
      let ft = subst_params mapping ft in
      let sep =
        if i = 0 then intern_show_str ("\"" ^ fname ^ "\":")
        else intern_show_str (",\"" ^ fname ^ "\":")
      in
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) (i32.const %d)))\n"
           sep);
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) \
            (call $to_json_%s (i32.load offset=%d (local.get $x)))))\n"
           (ty_tag ft) (i * 4))
    ) info.Typer.r_fields;
    Buffer.add_string lines
      (Printf.sprintf
         "    (call $__lang_str_concat (local.get $r) (i32.const %d)))" suffix);
    Buffer.contents lines
  | Ast.TyCon ("list", [elem_ty]) ->
    let lb = intern_show_str "[" in
    let rb = intern_show_str "]" in
    let comma = intern_show_str "," in
    Printf.sprintf
      "  (func $to_json_%s (param $x i32) (result i32)\n\
      \    (local $cur i32) (local $acc i32) (local $first i32)\n\
      \    (local $tag i32) (local $pl i32) (local $h i32)\n\
      \    (local.set $acc (i32.const %d))\n\
      \    (local.set $cur (local.get $x))\n\
      \    (local.set $first (i32.const 1))\n\
      \    (block $end\n\
      \      (loop $lp\n\
      \        (local.set $tag (i32.load offset=0 (local.get $cur)))\n\
      \        (br_if $end (i32.eqz (local.get $tag)))\n\
      \        (local.set $pl (i32.load offset=4 (local.get $cur)))\n\
      \        (local.set $h (i32.load offset=0 (local.get $pl)))\n\
      \        (if (i32.eqz (local.get $first))\n\
      \          (then\n\
      \            (local.set $acc (call $__lang_str_concat (local.get $acc) (i32.const %d)))))\n\
      \        (local.set $acc (call $__lang_str_concat (local.get $acc) (call $to_json_%s (local.get $h))))\n\
      \        (local.set $first (i32.const 0))\n\
      \        (local.set $cur (i32.load offset=4 (local.get $pl)))\n\
      \        (br $lp)))\n\
      \    (call $__lang_str_concat (local.get $acc) (i32.const %d)))"
      tag lb comma (ty_tag elem_ty) rb
  | Ast.TyCon ("option", [inner]) ->
    (* option is a transparent JSON nullable: None -> null, Some x -> x.
       Kept in sync with codegen_c / eval so to_json round-trips. *)
    let none_tag = try Hashtbl.find variant_tags "None" with Not_found -> 0 in
    let null_off = intern_show_str "null" in
    Printf.sprintf
      "  (func $to_json_%s (param $x i32) (result i32)\n\
      \    (if (result i32) (i32.eq (i32.load offset=0 (local.get $x)) (i32.const %d))\n\
      \      (then (i32.const %d))\n\
      \      (else (call $to_json_%s (i32.load offset=4 (local.get $x))))))"
      tag none_tag null_off (ty_tag (Ast.walk inner))
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.types n ->
    let vs =
      match Hashtbl.find_opt Exhaustive.type_variants n with
      | Some vs -> vs | None -> []
    in
    let mapping =
      match vs with
      | (cname, _) :: _ ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some info when info.Typer.params <> [] ->
           List.combine info.Typer.params args
         | _ -> [])
      | [] -> []
    in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $to_json_%s (param $x i32) (result i32)\n" tag);
    Buffer.add_string lines "    (local $tag i32)\n";
    Buffer.add_string lines
      "    (local.set $tag (i32.load offset=0 (local.get $x)))\n";
    let rec emit_branches = function
      | [] -> "(unreachable)"
      | (cname, arg_opt) :: rest ->
        let ctor_tag =
          match Hashtbl.find_opt variant_tags cname with
          | Some t -> t
          | None -> raise (Codegen_error (Loc.dummy,
            "ctor without tag in to_json_fn: " ^ cname))
        in
        let arm_body =
          match arg_opt with
          | None ->
            Printf.sprintf "(i32.const %d)" (intern_show_str ("\"" ^ cname ^ "\""))
          | Some pty ->
            let pty = subst_params mapping pty in
            let prefix = intern_show_str ("{\"" ^ cname ^ "\":") in
            let suffix = intern_show_str "}" in
            Printf.sprintf
              "(call $__lang_str_concat (call $__lang_str_concat (i32.const %d) \
               (call $to_json_%s (i32.load offset=4 (local.get $x)))) (i32.const %d))"
              prefix (ty_tag pty) suffix
        in
        Printf.sprintf
          "(if (result i32) (i32.eq (local.get $tag) (i32.const %d))\n\
          \      (then %s)\n\
          \      (else %s))"
          ctor_tag arm_body (emit_branches rest)
    in
    Buffer.add_string lines (Printf.sprintf "    %s)" (emit_branches vs));
    Buffer.contents lines
  | _ ->
    let off = intern_show_str "null" in
    Printf.sprintf
      "  (func $to_json_%s (param $x i32) (result i32) (i32.const %d))" tag off

(* Structural equality for compound types on Wasm. A compound value is a
   linear-memory offset, so `i32.eq` would compare offsets, not contents —
   `eq_<tag>` compares field/element/payload-wise instead. Mirrors show /
   to_json; kept in sync with codegen_c / eval. *)
let emit_eq_fn (tag : string) (t : Ast.ty) : string =
  let and_chain items =
    List.fold_right (fun e acc -> Printf.sprintf "(i32.and %s %s)" e acc)
      items "(i32.const 1)"
  in
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool ->
    Printf.sprintf
      "  (func $eq_%s (param $a i32) (param $b i32) (result i32)\n\
      \    (i32.eq (local.get $a) (local.get $b)))" tag
  | Ast.TyStr ->
    Printf.sprintf
      "  (func $eq_%s (param $a i32) (param $b i32) (result i32)\n\
      \    (call $__lang_streq (local.get $a) (local.get $b)))" tag
  | Ast.TyUnit ->
    Printf.sprintf
      "  (func $eq_%s (param $a i32) (param $b i32) (result i32) (i32.const 1))" tag
  | Ast.TyArrow _ ->
    Printf.sprintf
      "  (func $eq_%s (param $a i32) (param $b i32) (result i32) (i32.const 0))" tag
  | Ast.TyTuple ts ->
    let elems =
      List.mapi (fun i et ->
        Printf.sprintf
          "(call $eq_%s (i32.load offset=%d (local.get $a)) (i32.load offset=%d (local.get $b)))"
          (ty_tag et) (i * 4) (i * 4)) ts
    in
    Printf.sprintf
      "  (func $eq_%s (param $a i32) (param $b i32) (result i32)\n    %s)"
      tag (and_chain elems)
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
    let info = Hashtbl.find Typer.records n in
    let mapping =
      if info.Typer.r_params = [] then []
      else List.combine info.Typer.r_params args
    in
    let elems =
      List.mapi (fun i (_, ft) ->
        let _ = subst_params mapping ft in
        Printf.sprintf
          "(call $eq_%s (i32.load offset=%d (local.get $a)) (i32.load offset=%d (local.get $b)))"
          (ty_tag (subst_params mapping ft)) (i * 4) (i * 4)) info.Typer.r_fields
    in
    Printf.sprintf
      "  (func $eq_%s (param $a i32) (param $b i32) (result i32)\n    %s)"
      tag (and_chain elems)
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.types n || n = "list" ->
    let vs =
      match Hashtbl.find_opt Exhaustive.type_variants n with
      | Some vs -> vs | None -> []
    in
    let mapping =
      match vs with
      | (cname, _) :: _ ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some info when info.Typer.params <> [] ->
           List.combine info.Typer.params args
         | _ -> [])
      | [] -> []
    in
    let rec payload_dispatch = function
      | [] -> "(i32.const 1)"
      | (cname, arg_opt) :: rest ->
        (match arg_opt with
         | None -> payload_dispatch rest
         | Some pty ->
           let pty = subst_params mapping pty in
           let ctag =
             match Hashtbl.find_opt variant_tags cname with
             | Some t -> t | None -> 0
           in
           Printf.sprintf
             "(if (result i32) (i32.eq (local.get $ta) (i32.const %d))\n\
             \      (then (call $eq_%s (i32.load offset=4 (local.get $a)) (i32.load offset=4 (local.get $b))))\n\
             \      (else %s))"
             ctag (ty_tag pty) (payload_dispatch rest))
    in
    Printf.sprintf
      "  (func $eq_%s (param $a i32) (param $b i32) (result i32)\n\
      \    (local $ta i32)\n\
      \    (local.set $ta (i32.load offset=0 (local.get $a)))\n\
      \    (if (result i32) (i32.ne (local.get $ta) (i32.load offset=0 (local.get $b)))\n\
      \      (then (i32.const 0))\n\
      \      (else %s)))"
      tag (payload_dispatch vs)
  | _ ->
    Printf.sprintf
      "  (func $eq_%s (param $a i32) (param $b i32) (result i32) (i32.const 0))" tag

(* Static runtime helpers emitted into the Wasm module: strlen and
   str_concat both work on the linear memory. The bump pointer is a
   mutable global; concat advances it after copying the result. *)
let runtime_helpers = {|
  (func $__lang_strlen (param $s i32) (result i32)
    (local $i i32)
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eqz (i32.load8_u (i32.add (local.get $s) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $i))
  (func $__lang_str_concat (param $a i32) (param $b i32) (result i32)
    (local $la i32) (local $lb i32) (local $r i32) (local $i i32)
    (local.set $la (call $__lang_strlen (local.get $a)))
    (local.set $lb (call $__lang_strlen (local.get $b)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end_a
      (loop $lp_a
        (br_if $end_a (i32.eq (local.get $i) (local.get $la)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $a) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_a)))
    (local.set $i (i32.const 0))
    (block $end_b
      (loop $lp_b
        (br_if $end_b (i32.eq (local.get $i) (local.get $lb)))
        (i32.store8 (i32.add (i32.add (local.get $r) (local.get $la)) (local.get $i))
                    (i32.load8_u (i32.add (local.get $b) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_b)))
    (i32.store8 (i32.add (i32.add (local.get $r) (local.get $la)) (local.get $lb))
                (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (i32.add (local.get $r) (local.get $la)) (local.get $lb))
               (i32.const 1)))
    (local.get $r))
  (func $__lang_streq (param $a i32) (param $b i32) (result i32)
    (local $ba i32) (local $bb i32)
    (block $not_eq
      (loop $lp
        (local.set $ba (i32.load8_u (local.get $a)))
        (local.set $bb (i32.load8_u (local.get $b)))
        (br_if $not_eq (i32.ne (local.get $ba) (local.get $bb)))
        (if (i32.eqz (local.get $ba))
          (then (return (i32.const 1))))
        (local.set $a (i32.add (local.get $a) (i32.const 1)))
        (local.set $b (i32.add (local.get $b) (i32.const 1)))
        (br $lp)))
    (i32.const 0))
  ;; Phase 31.0: str_compare — returns -1 / 0 / 1 (sign-normalized, matches
  ;; interp's `compare s t` from OCaml stdlib).
  (func $__lang_str_compare (param $a i32) (param $b i32) (result i32)
    (local $ba i32) (local $bb i32)
    (loop $lp
      (local.set $ba (i32.load8_u (local.get $a)))
      (local.set $bb (i32.load8_u (local.get $b)))
      (if (i32.lt_u (local.get $ba) (local.get $bb))
        (then (return (i32.const -1))))
      (if (i32.gt_u (local.get $ba) (local.get $bb))
        (then (return (i32.const 1))))
      (if (i32.eqz (local.get $ba))
        (then (return (i32.const 0))))
      (local.set $a (i32.add (local.get $a) (i32.const 1)))
      (local.set $b (i32.add (local.get $b) (i32.const 1)))
      (br $lp))
    (unreachable))
  ;; Phase 19.1.1: str_index_of — returns position of needle in haystack,
  ;; -1 if not found. Empty needle returns 0.
  (func $__lang_str_index_of (param $h i32) (param $n i32) (result i32)
    (local $hlen i32) (local $nlen i32) (local $i i32) (local $j i32)
    (local $match i32)
    (local.set $hlen (call $__lang_strlen (local.get $h)))
    (local.set $nlen (call $__lang_strlen (local.get $n)))
    (if (i32.eqz (local.get $nlen)) (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (block $end_outer
      (loop $lp_outer
        ;; if i + nlen > hlen → not found
        (br_if $end_outer
               (i32.gt_s (i32.add (local.get $i) (local.get $nlen))
                         (local.get $hlen)))
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $nlen)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $h)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $n) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (if (local.get $match) (then (return (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i32.const -1))
  ;; Phase 36: __lang_is_ws — ASCII whitespace test (space/tab/lf/cr/ff)
  (func $__lang_is_ws (param $c i32) (result i32)
    (i32.or
      (i32.or
        (i32.or (i32.eq (local.get $c) (i32.const 32))
                (i32.eq (local.get $c) (i32.const 9)))
        (i32.or (i32.eq (local.get $c) (i32.const 10))
                (i32.eq (local.get $c) (i32.const 13))))
      (i32.eq (local.get $c) (i32.const 12))))
  ;; Phase 36: str_starts_with — bool (i32 0/1)
  (func $__lang_str_starts_with (param $s i32) (param $p i32) (result i32)
    (local $i i32) (local $cs i32) (local $cp i32)
    (local.set $i (i32.const 0))
    (loop $lp
      (local.set $cp (i32.load8_u (i32.add (local.get $p) (local.get $i))))
      (if (i32.eqz (local.get $cp)) (then (return (i32.const 1))))
      (local.set $cs (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (if (i32.ne (local.get $cs) (local.get $cp)) (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))
    (unreachable))
  ;; Phase 36: str_trim — strip leading + trailing whitespace
  (func $__lang_str_trim (param $s i32) (result i32)
    (local $p i32) (local $len i32) (local $r i32) (local $i i32) (local $c i32)
    (local.set $p (local.get $s))
    ;; skip leading whitespace
    (block $end_lead
      (loop $lp_lead
        (local.set $c (i32.load8_u (local.get $p)))
        (br_if $end_lead (i32.eqz (local.get $c)))
        (br_if $end_lead (i32.eqz (call $__lang_is_ws (local.get $c))))
        (local.set $p (i32.add (local.get $p) (i32.const 1)))
        (br $lp_lead)))
    ;; compute remaining length
    (local.set $len (call $__lang_strlen (local.get $p)))
    ;; trim trailing
    (block $end_trail
      (loop $lp_trail
        (br_if $end_trail (i32.eqz (local.get $len)))
        (local.set $c (i32.load8_u (i32.add (local.get $p)
                                            (i32.sub (local.get $len) (i32.const 1)))))
        (br_if $end_trail (i32.eqz (call $__lang_is_ws (local.get $c))))
        (local.set $len (i32.sub (local.get $len) (i32.const 1)))
        (br $lp_trail)))
    ;; copy [p, p+len) to bump
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end_copy
      (loop $lp_copy
        (br_if $end_copy (i32.eq (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $p) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_copy)))
    (i32.store8 (i32.add (local.get $r) (local.get $len)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $len)) (i32.const 1)))
    (local.get $r))
  ;; Phase 36: str_ends_with — bool (i32 0/1)
  (func $__lang_str_ends_with (param $s i32) (param $p i32) (result i32)
    (local $sl i32) (local $pl i32) (local $i i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $pl (call $__lang_strlen (local.get $p)))
    (if (i32.gt_s (local.get $pl) (local.get $sl)) (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (loop $lp
      (if (i32.eq (local.get $i) (local.get $pl)) (then (return (i32.const 1))))
      (if (i32.ne
            (i32.load8_u (i32.add (i32.add (local.get $s)
                                           (i32.sub (local.get $sl) (local.get $pl)))
                                  (local.get $i)))
            (i32.load8_u (i32.add (local.get $p) (local.get $i))))
        (then (return (i32.const 0))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))
    (unreachable))
  ;; Phase 36: str_repeat s n
  (func $__lang_str_repeat (param $s i32) (param $n i32) (result i32)
    (local $sl i32) (local $r i32) (local $i i32) (local $j i32)
    (if (i32.le_s (local.get $n) (i32.const 0))
      (then
        (local.set $r (global.get $__lang_bump))
        (i32.store8 (local.get $r) (i32.const 0))
        (global.set $__lang_bump (i32.add (local.get $r) (i32.const 1)))
        (return (local.get $r))))
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end_outer
      (loop $lp_outer
        (br_if $end_outer (i32.eq (local.get $i) (local.get $n)))
        (local.set $j (i32.const 0))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $sl)))
            (i32.store8 (i32.add (local.get $r)
                                 (i32.add (i32.mul (local.get $i) (local.get $sl))
                                          (local.get $j)))
                        (i32.load8_u (i32.add (local.get $s) (local.get $j))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i32.store8 (i32.add (local.get $r) (i32.mul (local.get $n) (local.get $sl)))
                (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (i32.mul (local.get $n) (local.get $sl)))
               (i32.const 1)))
    (local.get $r))
  ;; Phase 36: str_rev
  (func $__lang_str_rev (param $s i32) (result i32)
    (local $sl i32) (local $r i32) (local $i i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $sl)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $s)
                                          (i32.sub (i32.sub (local.get $sl) (local.get $i))
                                                   (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $sl)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $sl)) (i32.const 1)))
    (local.get $r))
  ;; Phase 36: chr n — return char_table entry pointer for byte n.
  ;; Mask to a single byte (n & 0xFF) so out-of-range input can't index
  ;; past the 256-entry table into adjacent memory. Matches the C backend
  ;; ((unsigned char)n) and the self-host $chr (i32.store8 truncation).
  (func $__lang_char_at_chr (param $n i32) (result i32)
    (call $__lang_char_at_setup)
    (i32.add (global.get $__lang_char_table)
      (i32.mul (i32.and (local.get $n) (i32.const 255)) (i32.const 2))))
  ;; Phase 36: abs / min / max / clamp
  (func $__lang_abs (param $n i32) (result i32)
    (if (i32.lt_s (local.get $n) (i32.const 0))
      (then (return (i32.sub (i32.const 0) (local.get $n)))))
    (local.get $n))
  (func $__lang_min (param $a i32) (param $b i32) (result i32)
    (if (i32.lt_s (local.get $a) (local.get $b))
      (then (return (local.get $a))))
    (local.get $b))
  (func $__lang_max (param $a i32) (param $b i32) (result i32)
    (if (i32.gt_s (local.get $a) (local.get $b))
      (then (return (local.get $a))))
    (local.get $b))
  (func $__lang_clamp (param $lo i32) (param $hi i32) (param $x i32) (result i32)
    (if (i32.lt_s (local.get $x) (local.get $lo))
      (then (return (local.get $lo))))
    (if (i32.gt_s (local.get $x) (local.get $hi))
      (then (return (local.get $hi))))
    (local.get $x))
  ;; Phase 36: to_upper / to_lower — ASCII case conversion
  (func $__lang_to_upper (param $s i32) (result i32)
    (local $sl i32) (local $r i32) (local $i i32) (local $c i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $sl)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (if (i32.and (i32.ge_u (local.get $c) (i32.const 97))
                     (i32.le_u (local.get $c) (i32.const 122)))
          (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))
        (i32.store8 (i32.add (local.get $r) (local.get $i)) (local.get $c))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $sl)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $sl)) (i32.const 1)))
    (local.get $r))
  (func $__lang_to_lower (param $s i32) (result i32)
    (local $sl i32) (local $r i32) (local $i i32) (local $c i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $sl)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (if (i32.and (i32.ge_u (local.get $c) (i32.const 65))
                     (i32.le_u (local.get $c) (i32.const 90)))
          (then (local.set $c (i32.add (local.get $c) (i32.const 32)))))
        (i32.store8 (i32.add (local.get $r) (local.get $i)) (local.get $c))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $sl)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $sl)) (i32.const 1)))
    (local.get $r))
  ;; Phase 36: gcd via iterative Euclid on |a|, |b|
  (func $__lang_gcd (param $a0 i32) (param $b0 i32) (result i32)
    (local $a i32) (local $b i32) (local $t i32)
    (local.set $a (local.get $a0))
    (local.set $b (local.get $b0))
    (if (i32.lt_s (local.get $a) (i32.const 0))
      (then (local.set $a (i32.sub (i32.const 0) (local.get $a)))))
    (if (i32.lt_s (local.get $b) (i32.const 0))
      (then (local.set $b (i32.sub (i32.const 0) (local.get $b)))))
    (block $end
      (loop $lp
        (br_if $end (i32.eqz (local.get $b)))
        (local.set $t (local.get $b))
        (local.set $b (i32.rem_s (local.get $a) (local.get $b)))
        (local.set $a (local.get $t))
        (br $lp)))
    (local.get $a))
  ;; Phase 36: bool_of_str — "true" → 1, otherwise → 0
  (func $__lang_bool_of_str (param $s i32) (result i32)
    (if (i32.ne (i32.load8_u (local.get $s)) (i32.const 116)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 1))) (i32.const 114)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 2))) (i32.const 117)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 3))) (i32.const 101)) (then (return (i32.const 0))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 4))) (i32.const 0)) (then (return (i32.const 0))))
    (i32.const 1))
  ;; Phase 36: str_replace s old new — replace all non-overlapping occurrences
  (func $__lang_str_replace (param $s i32) (param $old i32) (param $new i32) (result i32)
    (local $slen i32) (local $olen i32) (local $nlen i32)
    (local $r i32) (local $bi i32) (local $i i32) (local $j i32) (local $match i32)
    (local.set $olen (call $__lang_strlen (local.get $old)))
    (if (i32.eqz (local.get $olen)) (then (return (local.get $s))))
    (local.set $slen (call $__lang_strlen (local.get $s)))
    (local.set $nlen (call $__lang_strlen (local.get $new)))
    (local.set $r (global.get $__lang_bump))
    (local.set $bi (i32.const 0))
    (local.set $i (i32.const 0))
    (block $end_outer
      (loop $lp_outer
        (br_if $end_outer (i32.ge_s (local.get $i) (local.get $slen)))
        ;; check if remainder fits old
        (if (i32.le_s (i32.add (local.get $i) (local.get $olen)) (local.get $slen))
          (then
            (local.set $j (i32.const 0))
            (local.set $match (i32.const 1))
            (block $end_inner
              (loop $lp_inner
                (br_if $end_inner (i32.eq (local.get $j) (local.get $olen)))
                (if (i32.ne (i32.load8_u (i32.add (local.get $s)
                                                  (i32.add (local.get $i) (local.get $j))))
                            (i32.load8_u (i32.add (local.get $old) (local.get $j))))
                  (then (local.set $match (i32.const 0)) (br $end_inner)))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $lp_inner)))
            (if (local.get $match)
              (then
                ;; copy new
                (local.set $j (i32.const 0))
                (block $end_cn
                  (loop $lp_cn
                    (br_if $end_cn (i32.eq (local.get $j) (local.get $nlen)))
                    (i32.store8 (i32.add (local.get $r) (i32.add (local.get $bi) (local.get $j)))
                                (i32.load8_u (i32.add (local.get $new) (local.get $j))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $lp_cn)))
                (local.set $bi (i32.add (local.get $bi) (local.get $nlen)))
                (local.set $i (i32.add (local.get $i) (local.get $olen)))
                (br $lp_outer)))))
        ;; no match — copy one char
        (i32.store8 (i32.add (local.get $r) (local.get $bi))
                    (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (local.set $bi (i32.add (local.get $bi) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i32.store8 (i32.add (local.get $r) (local.get $bi)) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (local.get $bi)) (i32.const 1)))
    (local.get $r))
  ;; Phase 26.1/26.2: fail msg — if a try_or scope is active, set the
  ;; failure flag and return 0 (the caller's expected result type is i32
  ;; for everything in Wasm). Otherwise print + trap. The flag /
  ;; active-counter globals are declared at module level.
  (func $__lang_fail (param $msg i32) (result i32)
    (if (global.get $__lang_fail_active)
      (then
        (global.set $__lang_fail_flag (i32.const 1))
        (return (i32.const 0))))
    (call $puts (local.get $msg))
    (unreachable))
  ;; Phase 26.1: char_at s i — return pointer to a single-byte string
  ;; (preallocated 256-entry static char_table). Mirrors C/LLVM.
  ;; The table itself is set up at module-init by storing 256 pairs of
  ;; (char, \0) starting at the global offset $__lang_char_table.
  (func $__lang_char_at_setup
    (local $k i32) (local $base i32)
    (if (i32.eqz (global.get $__lang_char_table_initialized))
      (then
        (global.set $__lang_char_table_initialized (i32.const 1))
        (local.set $base (global.get $__lang_char_table))
        (local.set $k (i32.const 0))
        (block $end
          (loop $lp
            (br_if $end (i32.eq (local.get $k) (i32.const 256)))
            (i32.store8 (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 2)))
                        (local.get $k))
            (i32.store8 (i32.add (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 2))) (i32.const 1))
                        (i32.const 0))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br $lp))))))
  (func $__lang_char_at (param $s i32) (param $i i32) (result i32)
    (call $__lang_char_at_setup)
    (i32.add (global.get $__lang_char_table)
             (i32.mul (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 2))))
  (func $__lang_is_digit (param $s i32) (result i32)
    (local $c i32)
    (local.set $c (i32.load8_u (local.get $s)))
    (i32.and (i32.ge_s (local.get $c) (i32.const 48))
             (i32.le_s (local.get $c) (i32.const 57))))
  (func $__lang_is_alpha (param $s i32) (result i32)
    (local $c i32)
    (local.set $c (i32.load8_u (local.get $s)))
    (i32.or
      (i32.and (i32.ge_s (local.get $c) (i32.const 97))
               (i32.le_s (local.get $c) (i32.const 122)))
      (i32.and (i32.ge_s (local.get $c) (i32.const 65))
               (i32.le_s (local.get $c) (i32.const 90)))))
  (func $__lang_is_space (param $s i32) (result i32)
    (local $c i32)
    (local.set $c (i32.load8_u (local.get $s)))
    (i32.or
      (i32.or (i32.eq (local.get $c) (i32.const 32))
              (i32.eq (local.get $c) (i32.const 9)))
      (i32.or (i32.eq (local.get $c) (i32.const 10))
              (i32.eq (local.get $c) (i32.const 13)))))
  ;; Phase 26.1: substring s start end_ — region alloc + memcpy.
  (func $__lang_substring (param $s i32) (param $start i32) (param $end_ i32) (result i32)
    (local $len i32) (local $r i32) (local $i i32)
    (local.set $len (i32.sub (local.get $end_) (local.get $start)))
    (if (i32.lt_s (local.get $len) (i32.const 0))
      (then (local.set $len (i32.const 0))))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $s)
                                          (i32.add (local.get $start) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $len)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $len)) (i32.const 1)))
    (local.get $r))
  ;; Phase 26.1: int_of_str s — parse leading sign + digits. Stops at
  ;; first non-digit byte. Mirrors atoi semantics.
  (func $__lang_int_of_str (param $s i32) (result i32)
    (local $i i32) (local $sign i32) (local $acc i32) (local $c i32)
    (local.set $i (i32.const 0))
    (local.set $sign (i32.const 1))
    (local.set $acc (i32.const 0))
    (local.set $c (i32.load8_u (local.get $s)))
    (if (i32.eq (local.get $c) (i32.const 45))  ;; '-'
      (then
        (local.set $sign (i32.const -1))
        (local.set $i (i32.const 1))))
    (block $end
      (loop $lp
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (br_if $end (i32.eqz (local.get $c)))
        (br_if $end (i32.or
          (i32.lt_s (local.get $c) (i32.const 48))
          (i32.gt_s (local.get $c) (i32.const 57))))
        (local.set $acc (i32.add
          (i32.mul (local.get $acc) (i32.const 10))
          (i32.sub (local.get $c) (i32.const 48))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.mul (local.get $acc) (local.get $sign)))
  ;; Phase 26.1: str_unescape s — replace backslash-escape sequences
  ;; (\n, \t, \r, \\ , \", \/) with the actual byte. Region-allocated.
  (func $__lang_str_unescape (param $s i32) (result i32)
    (local $n i32) (local $r i32) (local $i i32) (local $j i32)
    (local $c i32) (local $ec i32)
    (local.set $n (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (local.set $j (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (if (i32.and
              (i32.eq (local.get $c) (i32.const 92))  ;; '\\'
              (i32.lt_s (i32.add (local.get $i) (i32.const 1)) (local.get $n)))
          (then
            (local.set $ec (i32.load8_u (i32.add (local.get $s) (i32.add (local.get $i) (i32.const 1)))))
            (if (i32.eq (local.get $ec) (i32.const 110))      ;; 'n'
              (then (local.set $ec (i32.const 10)))
              (else (if (i32.eq (local.get $ec) (i32.const 116))  ;; 't'
                (then (local.set $ec (i32.const 9)))
                (else (if (i32.eq (local.get $ec) (i32.const 114))  ;; 'r'
                  (then (local.set $ec (i32.const 13))))))))
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $ec))
            (local.set $i (i32.add (local.get $i) (i32.const 2)))
            (local.set $j (i32.add (local.get $j) (i32.const 1))))
          (else
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $c))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $j)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $j)) (i32.const 1)))
    (local.get $r))
  ;; Phase 26.6: str_escape s — backslash-escape newline / tab / cr / backslash
  ;; / quote. show_str pipes through this so output matches interp. Worst-case
  ;; 2x byte expansion, region-allocated.
  (func $__lang_str_escape (param $s i32) (result i32)
    (local $n i32) (local $r i32) (local $i i32) (local $j i32) (local $c i32) (local $ec i32)
    (local.set $n (call $__lang_strlen (local.get $s)))
    (local.set $r (global.get $__lang_bump))
    (local.set $i (i32.const 0))
    (local.set $j (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        ;; if c is special (10/9/13/92/34), emit backslash + replacement
        (if (i32.or
              (i32.or (i32.eq (local.get $c) (i32.const 10))
                      (i32.eq (local.get $c) (i32.const 9)))
              (i32.or (i32.or (i32.eq (local.get $c) (i32.const 13))
                              (i32.eq (local.get $c) (i32.const 92)))
                      (i32.eq (local.get $c) (i32.const 34))))
          (then
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (i32.const 92))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (local.set $ec (local.get $c))
            (if (i32.eq (local.get $c) (i32.const 10))
              (then (local.set $ec (i32.const 110))))
            (if (i32.eq (local.get $c) (i32.const 9))
              (then (local.set $ec (i32.const 116))))
            (if (i32.eq (local.get $c) (i32.const 13))
              (then (local.set $ec (i32.const 114))))
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $ec)))
          (else
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $c))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $j)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $j)) (i32.const 1)))
    (local.get $r))|}

(* Phase 26.5: list_str cell builders + str_split / str_join / str_count.
   Cells layout (Phase 26.0 boxed): {i32 tag, i32 payload_ptr}. For Cons,
   payload_ptr points to a 2-word tuple {str_ptr, list_str_ptr}. *)
let list_str_runtime_wasm = {|
  (func $__lang_list_str_nil (result i32)
    (local $p i32)
    (local.set $p (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 8)))
    (i32.store offset=0 (local.get $p) (i32.const 0))
    (local.get $p))
  (func $__lang_list_str_cons (param $head i32) (param $tail i32) (result i32)
    (local $p i32) (local $box i32)
    ;; Tuple payload box: 8 bytes (str_ptr + list_str_ptr).
    (local.set $box (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $box) (i32.const 8)))
    (i32.store offset=0 (local.get $box) (local.get $head))
    (i32.store offset=4 (local.get $box) (local.get $tail))
    ;; Cons cell: 8 bytes (tag=1 + payload_ptr).
    (local.set $p (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 8)))
    (i32.store offset=0 (local.get $p) (i32.const 1))
    (i32.store offset=4 (local.get $p) (local.get $box))
    (local.get $p))
  ;; str_split s delim — 2-pass: count tokens, then build list back-to-front.
  (func $__lang_str_split (param $s i32) (param $delim i32) (result i32)
    (local $sl i32) (local $dl i32) (local $i i32) (local $cnt i32)
    (local $starts i32) (local $lens i32) (local $tstart i32) (local $tidx i32)
    (local $tlen i32) (local $tk i32) (local $j i32) (local $match i32)
    (local $nil i32) (local $tail i32) (local $bi i32) (local $b_off i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $dl (call $__lang_strlen (local.get $delim)))
    ;; Empty delim: return Cons(s, Nil) (matches interp / C / LLVM).
    (if (i32.eqz (local.get $dl))
      (then
        (local.set $nil (call $__lang_list_str_nil))
        (return (call $__lang_list_str_cons (local.get $s) (local.get $nil)))))
    ;; Pass 1: count delim occurrences (non-overlapping).
    (local.set $i (i32.const 0))
    (local.set $cnt (i32.const 0))
    (block $end_c
      (loop $lp_c
        (br_if $end_c
               (i32.gt_s (i32.add (local.get $i) (local.get $dl))
                         (local.get $sl)))
        ;; Compare delim bytes.
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $dl)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $s)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $delim) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (if (local.get $match)
          (then
            (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (local.get $dl))))
          (else
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $lp_c)))
    ;; Allocate parallel (start, len) arrays — n = cnt + 1 tokens.
    (local.set $starts (global.get $__lang_bump))
    (global.set $__lang_bump
      (i32.add (global.get $__lang_bump)
               (i32.mul (i32.add (local.get $cnt) (i32.const 1)) (i32.const 4))))
    (local.set $lens (global.get $__lang_bump))
    (global.set $__lang_bump
      (i32.add (global.get $__lang_bump)
               (i32.mul (i32.add (local.get $cnt) (i32.const 1)) (i32.const 4))))
    ;; Pass 2: extract tokens into (start, len) arrays.
    (local.set $i (i32.const 0))
    (local.set $tstart (i32.const 0))
    (local.set $tidx (i32.const 0))
    (block $end_f
      (loop $lp_f
        (br_if $end_f
               (i32.gt_s (i32.add (local.get $i) (local.get $dl))
                         (local.get $sl)))
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner2
          (loop $lp_inner2
            (br_if $end_inner2 (i32.eq (local.get $j) (local.get $dl)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $s)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $delim) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner2)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner2)))
        (if (local.get $match)
          (then
            (i32.store
              (i32.add (local.get $starts) (i32.mul (local.get $tidx) (i32.const 4)))
              (local.get $tstart))
            (i32.store
              (i32.add (local.get $lens) (i32.mul (local.get $tidx) (i32.const 4)))
              (i32.sub (local.get $i) (local.get $tstart)))
            (local.set $tidx (i32.add (local.get $tidx) (i32.const 1)))
            (local.set $tstart (i32.add (local.get $i) (local.get $dl)))
            (local.set $i (i32.add (local.get $i) (local.get $dl))))
          (else
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $lp_f)))
    ;; Last token: (tstart, sl - tstart) at index $tidx.
    (i32.store
      (i32.add (local.get $starts) (i32.mul (local.get $tidx) (i32.const 4)))
      (local.get $tstart))
    (i32.store
      (i32.add (local.get $lens) (i32.mul (local.get $tidx) (i32.const 4)))
      (i32.sub (local.get $sl) (local.get $tstart)))
    ;; Build Cons list back-to-front from index $cnt down to 0.
    (local.set $nil (call $__lang_list_str_nil))
    (local.set $tail (local.get $nil))
    (local.set $bi (local.get $cnt))
    (block $end_b
      (loop $lp_b
        (local.set $b_off (i32.mul (local.get $bi) (i32.const 4)))
        (local.set $tstart (i32.load (i32.add (local.get $starts) (local.get $b_off))))
        (local.set $tlen (i32.load (i32.add (local.get $lens) (local.get $b_off))))
        (local.set $tk (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $tk) (i32.add (local.get $tlen) (i32.const 1))))
        ;; memcpy
        (local.set $j (i32.const 0))
        (block $end_cp
          (loop $lp_cp
            (br_if $end_cp (i32.eq (local.get $j) (local.get $tlen)))
            (i32.store8
              (i32.add (local.get $tk) (local.get $j))
              (i32.load8_u (i32.add (local.get $s)
                                    (i32.add (local.get $tstart) (local.get $j)))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_cp)))
        (i32.store8 (i32.add (local.get $tk) (local.get $tlen)) (i32.const 0))
        (local.set $tail (call $__lang_list_str_cons (local.get $tk) (local.get $tail)))
        (br_if $end_b (i32.eqz (local.get $bi)))
        (local.set $bi (i32.sub (local.get $bi) (i32.const 1)))
        (br $lp_b)))
    (local.get $tail))
  ;; str_join sep xs — walk list_str, concat with sep.
  (func $__lang_str_join (param $sep i32) (param $xs i32) (result i32)
    (local $sl i32) (local $cur i32) (local $box i32) (local $head i32)
    (local $total i32) (local $first i32) (local $r i32) (local $pos i32)
    (local $hl i32)
    (local.set $sl (call $__lang_strlen (local.get $sep)))
    ;; Pass 1: total length.
    (local.set $cur (local.get $xs))
    (local.set $total (i32.const 0))
    (local.set $first (i32.const 1))
    (block $end_len
      (loop $lp_len
        (br_if $end_len (i32.eqz (i32.load offset=0 (local.get $cur))))
        (local.set $box (i32.load offset=4 (local.get $cur)))
        (local.set $head (i32.load offset=0 (local.get $box)))
        (if (i32.eqz (local.get $first))
          (then (local.set $total (i32.add (local.get $total) (local.get $sl)))))
        (local.set $total
          (i32.add (local.get $total)
                   (call $__lang_strlen (local.get $head))))
        (local.set $first (i32.const 0))
        (local.set $cur (i32.load offset=4 (local.get $box)))
        (br $lp_len)))
    ;; Allocate result + null terminator.
    (local.set $r (global.get $__lang_bump))
    (global.set $__lang_bump
      (i32.add (local.get $r) (i32.add (local.get $total) (i32.const 1))))
    ;; Pass 2: write.
    (local.set $cur (local.get $xs))
    (local.set $pos (i32.const 0))
    (local.set $first (i32.const 1))
    (block $end_w
      (loop $lp_w
        (br_if $end_w (i32.eqz (i32.load offset=0 (local.get $cur))))
        (local.set $box (i32.load offset=4 (local.get $cur)))
        (local.set $head (i32.load offset=0 (local.get $box)))
        (if (i32.eqz (local.get $first))
          (then
            ;; memcpy sep.
            (local.set $hl (i32.const 0))
            (block $end_cs
              (loop $lp_cs
                (br_if $end_cs (i32.eq (local.get $hl) (local.get $sl)))
                (i32.store8
                  (i32.add (local.get $r) (i32.add (local.get $pos) (local.get $hl)))
                  (i32.load8_u (i32.add (local.get $sep) (local.get $hl))))
                (local.set $hl (i32.add (local.get $hl) (i32.const 1)))
                (br $lp_cs)))
            (local.set $pos (i32.add (local.get $pos) (local.get $sl)))))
        ;; memcpy head.
        (local.set $hl (call $__lang_strlen (local.get $head)))
        (local.set $first (i32.const 0))
        (block $end_ch
          (local.set $first (i32.const 0))
          (loop $lp_ch
            (local.tee $first (i32.const 0))
            (drop)
            (br_if $end_ch (i32.eqz (local.get $hl)))
            (i32.store8
              (i32.add (local.get $r) (local.get $pos))
              (i32.load8_u (local.get $head)))
            (local.set $head (i32.add (local.get $head) (i32.const 1)))
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (local.set $hl (i32.sub (local.get $hl) (i32.const 1)))
            (br $lp_ch)))
        (local.set $first (i32.const 0))
        (local.set $cur (i32.load offset=4 (local.get $box)))
        (br $lp_w)))
    (i32.store8 (i32.add (local.get $r) (local.get $total)) (i32.const 0))
    (local.get $r))
  ;; str_count s n — non-overlapping count of n in s.
  (func $__lang_str_count (param $s i32) (param $n i32) (result i32)
    (local $sl i32) (local $nl i32) (local $i i32) (local $j i32)
    (local $acc i32) (local $match i32)
    (local.set $sl (call $__lang_strlen (local.get $s)))
    (local.set $nl (call $__lang_strlen (local.get $n)))
    (if (i32.eqz (local.get $nl)) (then (return (i32.const 0))))
    (local.set $i (i32.const 0))
    (local.set $acc (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end
               (i32.gt_s (i32.add (local.get $i) (local.get $nl))
                         (local.get $sl)))
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $nl)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $s)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $n) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (if (local.get $match)
          (then
            (local.set $acc (i32.add (local.get $acc) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (local.get $nl))))
          (else
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $lp)))
    (local.get $acc))|}

(* Phase 15.4: Vec[R, T] runtime — all element types share one
   implementation because every Mere value lowers to a 4-byte i32 in
   Wasm (scalars direct, structured types are memory offsets).
   Layout: 16 bytes per vec — { data_ptr:i32, len:i32, cap:i32, _pad:i32 }.
   `_pad` keeps the struct 16-byte-aligned (matches C / LLVM layout).
   Push reallocates by appending a fresh buffer at the bump pointer
   (arena semantics — old buffers leak until process exit). *)
let vec_runtime = {|
  (func $mere_vec_new (result i32)
    (local $v i32) (local $buf i32)
    (local.set $v (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $v) (i32.const 16)))
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $buf) (i32.const 16)))
    (i32.store offset=0 (local.get $v) (local.get $buf))
    (i32.store offset=4 (local.get $v) (i32.const 0))
    (i32.store offset=8 (local.get $v) (i32.const 4))
    (local.get $v))
  (func $mere_vec_push (param $v i32) (param $x i32) (result i32)
    (local $len i32) (local $cap i32) (local $buf i32)
    (local $new_buf i32) (local $i i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $cap (i32.load offset=8 (local.get $v)))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_buf (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_buf)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $buf (i32.load offset=0 (local.get $v)))
        (local.set $i (i32.const 0))
        (block $copy_end
          (loop $copy_lp
            (br_if $copy_end (i32.eq (local.get $i) (local.get $len)))
            (i32.store
              (i32.add (local.get $new_buf)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load
                (i32.add (local.get $buf)
                         (i32.mul (local.get $i) (i32.const 4)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $copy_lp)))
        (i32.store offset=0 (local.get $v) (local.get $new_buf))
        (i32.store offset=8 (local.get $v) (local.get $cap))))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i32.store
      (i32.add (local.get $buf)
               (i32.mul (local.get $len) (i32.const 4)))
      (local.get $x))
    (i32.store offset=4 (local.get $v) (i32.add (local.get $len) (i32.const 1)))
    (i32.const 0))
  (func $mere_vec_get (param $v i32) (param $i i32) (result i32)
    (local $len i32) (local $buf i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (local.get $len)))
      (then (unreachable)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i32.load
      (i32.add (local.get $buf)
               (i32.mul (local.get $i) (i32.const 4)))))
  (func $mere_vec_len (param $v i32) (result i32)
    (i32.load offset=4 (local.get $v)))
  (func $mere_vec_set (param $v i32) (param $i i32) (param $x i32) (result i32)
    (local $len i32) (local $buf i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (local.get $len)))
      (then (unreachable)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i32.store
      (i32.add (local.get $buf) (i32.mul (local.get $i) (i32.const 4)))
      (local.get $x))
    (i32.const 0))
  ;; Phase 15.7: OwnedVec helpers — in Wasm all values are i32 and the
  ;; bump allocator is also shared, so the runtime representations of Vec
  ;; and OwnedVec are the same. owned_vec_* aliases as a thin wrapper to
  ;; $mere_vec_*. Deep copy (vec_to_owned / owned_vec_to_vec) uses $mere_vec_clone.
  (func $mere_vec_clone (param $src i32) (result i32)
    (local $new i32) (local $i i32) (local $len i32) (local $buf i32)
    (local.set $new (call $mere_vec_new))
    (local.set $len (i32.load offset=4 (local.get $src)))
    (local.set $buf (i32.load offset=0 (local.get $src)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (drop (call $mere_vec_push
                 (local.get $new)
                 (i32.load (i32.add (local.get $buf)
                                    (i32.mul (local.get $i) (i32.const 4))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $new))
  ;; Phase 19.3: vec_reverse — in-place swap, returns 0 (unit).
  (func $mere_vec_reverse (param $v i32) (result i32)
    (local $lo i32) (local $hi i32) (local $buf i32) (local $tmp i32)
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $lo (i32.const 0))
    (local.set $hi (i32.sub (i32.load offset=4 (local.get $v)) (i32.const 1)))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $lo) (local.get $hi)))
        (local.set $tmp (i32.load
          (i32.add (local.get $buf) (i32.mul (local.get $lo) (i32.const 4)))))
        (i32.store
          (i32.add (local.get $buf) (i32.mul (local.get $lo) (i32.const 4)))
          (i32.load (i32.add (local.get $buf)
                             (i32.mul (local.get $hi) (i32.const 4)))))
        (i32.store
          (i32.add (local.get $buf) (i32.mul (local.get $hi) (i32.const 4)))
          (local.get $tmp))
        (local.set $lo (i32.add (local.get $lo) (i32.const 1)))
        (local.set $hi (i32.sub (local.get $hi) (i32.const 1)))
        (br $lp)))
    (i32.const 0))
  ;; Phase 19.3: vec_sort — in-place insertion sort.
  ;; cmp: closure_T_(closure_T_int). outer_fn(env, a) → inner closure_T_int,
  ;; inner_fn(inner.env, b) → i32 (negative/0/positive).
  (func $mere_vec_sort (param $v i32) (param $cmp i32) (result i32)
    (local $i i32) (local $j i32) (local $len i32) (local $buf i32)
    (local $outer_env i32) (local $outer_fn i32)
    (local $key i32) (local $j_val i32)
    (local $inner_cl i32) (local $inner_env i32) (local $inner_fn i32)
    (local $cmp_res i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $outer_env (i32.load offset=0 (local.get $cmp)))
    (local.set $outer_fn  (i32.load offset=4 (local.get $cmp)))
    (local.set $i (i32.const 1))
    (block $end_outer
      (loop $lp_outer
        (br_if $end_outer (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $key (i32.load
          (i32.add (local.get $buf) (i32.mul (local.get $i) (i32.const 4)))))
        (local.set $j (i32.sub (local.get $i) (i32.const 1)))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.lt_s (local.get $j) (i32.const 0)))
            (local.set $j_val (i32.load
              (i32.add (local.get $buf) (i32.mul (local.get $j) (i32.const 4)))))
            (local.set $inner_cl
              (call_indirect (type $cl)
                (local.get $outer_env) (local.get $j_val) (local.get $outer_fn)))
            (local.set $inner_env (i32.load offset=0 (local.get $inner_cl)))
            (local.set $inner_fn  (i32.load offset=4 (local.get $inner_cl)))
            (local.set $cmp_res
              (call_indirect (type $cl)
                (local.get $inner_env) (local.get $key) (local.get $inner_fn)))
            (br_if $end_inner (i32.le_s (local.get $cmp_res) (i32.const 0)))
            ;; shift: data[j+1] = data[j]
            (i32.store
              (i32.add (local.get $buf)
                       (i32.mul (i32.add (local.get $j) (i32.const 1))
                                (i32.const 4)))
              (local.get $j_val))
            (local.set $j (i32.sub (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        ;; place key at j+1
        (i32.store
          (i32.add (local.get $buf)
                   (i32.mul (i32.add (local.get $j) (i32.const 1))
                            (i32.const 4)))
          (local.get $key))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i32.const 0))
  ;; Phase 19.3: vec_concat — new Vec, copy a then b.
  (func $mere_vec_concat (param $a i32) (param $b i32) (result i32)
    (local $new i32) (local $i i32) (local $alen i32) (local $blen i32)
    (local $abuf i32) (local $bbuf i32)
    (local.set $new (call $mere_vec_new))
    (local.set $alen (i32.load offset=4 (local.get $a)))
    (local.set $blen (i32.load offset=4 (local.get $b)))
    (local.set $abuf (i32.load offset=0 (local.get $a)))
    (local.set $bbuf (i32.load offset=0 (local.get $b)))
    (local.set $i (i32.const 0))
    (block $end_a
      (loop $lp_a
        (br_if $end_a (i32.eq (local.get $i) (local.get $alen)))
        (drop (call $mere_vec_push (local.get $new)
                (i32.load (i32.add (local.get $abuf)
                                   (i32.mul (local.get $i) (i32.const 4))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_a)))
    (local.set $i (i32.const 0))
    (block $end_b
      (loop $lp_b
        (br_if $end_b (i32.eq (local.get $i) (local.get $blen)))
        (drop (call $mere_vec_push (local.get $new)
                (i32.load (i32.add (local.get $bbuf)
                                   (i32.mul (local.get $i) (i32.const 4))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_b)))
    (local.get $new))|}

(* Phase 15.5: vec_iter / vec_fold helpers. References (type $cl) and
   uses call_indirect, so the module must declare a funcref table when
   this block is emitted (even if no closure entries exist). *)
let vec_higher_order_runtime = {|
  (func $mere_vec_iter (param $v i32) (param $cl i32) (result i32)
    (local $i i32) (local $len i32) (local $buf i32)
    (local $env i32) (local $fn i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $env (i32.load offset=0 (local.get $cl)))
    (local.set $fn (i32.load offset=4 (local.get $cl)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (drop
          (call_indirect (type $cl)
            (local.get $env)
            (i32.load (i32.add (local.get $buf)
                               (i32.mul (local.get $i) (i32.const 4))))
            (local.get $fn)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.const 0))
  (func $mere_vec_fold (param $v i32) (param $init_acc i32) (param $outer_cl i32) (result i32)
    (local $i i32) (local $len i32) (local $buf i32) (local $acc i32)
    (local $outer_env i32) (local $outer_fn i32)
    (local $inner_cl i32) (local $inner_env i32) (local $inner_fn i32) (local $elem i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $outer_env (i32.load offset=0 (local.get $outer_cl)))
    (local.set $outer_fn (i32.load offset=4 (local.get $outer_cl)))
    (local.set $acc (local.get $init_acc))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (local.set $elem
          (i32.load (i32.add (local.get $buf)
                             (i32.mul (local.get $i) (i32.const 4)))))
        ;; inner = outer(env, acc)
        (local.set $inner_cl
          (call_indirect (type $cl)
            (local.get $outer_env)
            (local.get $acc)
            (local.get $outer_fn)))
        (local.set $inner_env (i32.load offset=0 (local.get $inner_cl)))
        (local.set $inner_fn (i32.load offset=4 (local.get $inner_cl)))
        ;; acc = inner(inner_env, elem)
        (local.set $acc
          (call_indirect (type $cl)
            (local.get $inner_env)
            (local.get $elem)
            (local.get $inner_fn)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $acc))
  (func $mere_vec_map (param $v i32) (param $cl i32) (result i32)
    (local $new i32) (local $i i32) (local $len i32) (local $buf i32)
    (local $env i32) (local $fn i32) (local $mapped i32)
    (local.set $new (call $mere_vec_new))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $env (i32.load offset=0 (local.get $cl)))
    (local.set $fn (i32.load offset=4 (local.get $cl)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (local.set $mapped
          (call_indirect (type $cl)
            (local.get $env)
            (i32.load (i32.add (local.get $buf)
                               (i32.mul (local.get $i) (i32.const 4))))
            (local.get $fn)))
        (drop (call $mere_vec_push (local.get $new) (local.get $mapped)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $new))
  (func $mere_vec_filter (param $v i32) (param $cl i32) (result i32)
    (local $new i32) (local $i i32) (local $len i32) (local $buf i32)
    (local $env i32) (local $fn i32) (local $elem i32) (local $keep i32)
    (local.set $new (call $mere_vec_new))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $env (i32.load offset=0 (local.get $cl)))
    (local.set $fn (i32.load offset=4 (local.get $cl)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (local.set $elem
          (i32.load (i32.add (local.get $buf)
                             (i32.mul (local.get $i) (i32.const 4)))))
        (local.set $keep
          (call_indirect (type $cl)
            (local.get $env)
            (local.get $elem)
            (local.get $fn)))
        (if (local.get $keep)
          (then
            (drop (call $mere_vec_push (local.get $new) (local.get $elem)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $new))|}

(* Phase 15.9: StrBuf[R] runtime — single non-polymorphic helper set.
   Uses Wasm's bump allocator ($__lang_bump). Layout:
   { data_ptr:i32, len:i32, cap:i32, _pad:i32 } = 16 bytes (same as Vec). *)
let strbuf_runtime_wasm = {|
  (func $mere_strbuf_new (result i32)
    (local $sb i32) (local $buf i32)
    (local.set $sb (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $sb) (i32.const 16)))
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $buf) (i32.const 16)))
    (i32.store offset=0 (local.get $sb) (local.get $buf))
    (i32.store offset=4 (local.get $sb) (i32.const 0))
    (i32.store offset=8 (local.get $sb) (i32.const 16))
    (local.get $sb))
  (func $mere_strbuf_push (param $sb i32) (param $s i32) (result i32)
    (local $slen i32) (local $len i32) (local $cap i32) (local $buf i32)
    (local $new_buf i32) (local $i i32)
    (local.set $slen (call $__lang_strlen (local.get $s)))
    (block $resize_end
      (loop $resize_lp
        (local.set $len (i32.load offset=4 (local.get $sb)))
        (local.set $cap (i32.load offset=8 (local.get $sb)))
        (br_if $resize_end
          (i32.le_s (i32.add (local.get $len) (local.get $slen))
                    (local.get $cap)))
        ;; grow
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_buf (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_buf) (local.get $cap)))
        (local.set $buf (i32.load offset=0 (local.get $sb)))
        (local.set $i (i32.const 0))
        (block $cp_end
          (loop $cp_lp
            (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
            (i32.store8
              (i32.add (local.get $new_buf) (local.get $i))
              (i32.load8_u (i32.add (local.get $buf) (local.get $i))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp_lp)))
        (i32.store offset=0 (local.get $sb) (local.get $new_buf))
        (i32.store offset=8 (local.get $sb) (local.get $cap))
        (br $resize_lp)))
    ;; copy s into the buffer at offset len
    (local.set $buf (i32.load offset=0 (local.get $sb)))
    (local.set $len (i32.load offset=4 (local.get $sb)))
    (local.set $i (i32.const 0))
    (block $cp2_end
      (loop $cp2_lp
        (br_if $cp2_end (i32.eq (local.get $i) (local.get $slen)))
        (i32.store8
          (i32.add (i32.add (local.get $buf) (local.get $len)) (local.get $i))
          (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cp2_lp)))
    (i32.store offset=4 (local.get $sb)
      (i32.add (local.get $len) (local.get $slen)))
    (i32.const 0))
  (func $mere_strbuf_to_str (param $sb i32) (result i32)
    (local $len i32) (local $out i32) (local $buf i32) (local $i i32)
    (local.set $len (i32.load offset=4 (local.get $sb)))
    (local.set $buf (i32.load offset=0 (local.get $sb)))
    (local.set $out (global.get $__lang_bump))
    (global.set $__lang_bump
      (i32.add (local.get $out) (i32.add (local.get $len) (i32.const 1))))
    (local.set $i (i32.const 0))
    (block $cp_end
      (loop $cp_lp
        (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
        (i32.store8
          (i32.add (local.get $out) (local.get $i))
          (i32.load8_u (i32.add (local.get $buf) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cp_lp)))
    (i32.store8 (i32.add (local.get $out) (local.get $len)) (i32.const 0))
    (local.get $out))
  (func $mere_strbuf_len (param $sb i32) (result i32)
    (i32.load offset=4 (local.get $sb)))|}

(* Phase 15.10: Map[R, K, V] runtime — per-K only (V is i32 for all).
   Layout: { keys:i32, values:i32, len:i32, cap:i32 } = 16 bytes.
   Linear scan; on reaching cap, allocate a new array via bump
   (arena semantics). *)

(* Phase 15.14: emit a key-equality WAT function for K type. K can be
   int / bool / str / tuple (recursive over tuple). Result is `i32`
   (0/1). Tuple elements are i32 stored at offset 4*i within the
   tuple's memory block. *)
let emit_map_key_eq_wasm (k_ty : Ast.ty) : string =
  let k_tag = ty_tag k_ty in
  let local_counter = ref 0 in
  let fresh_loc prefix =
    incr local_counter;
    Printf.sprintf "$%s%d" prefix !local_counter
  in
  let locals = ref [] in
  let emit_eq_for_atom ty a_expr b_expr =
    match Ast.walk ty with
    | Ast.TyInt | Ast.TyBool ->
      Printf.sprintf "(i32.eq %s %s)" a_expr b_expr
    | Ast.TyStr ->
      Printf.sprintf "(call $__lang_streq %s %s)" a_expr b_expr
    | _ -> Printf.sprintf "(i32.eq %s %s)" a_expr b_expr
  in
  let compound_eq fields_offsets a_expr b_expr =
    (* For each (offset, field_ty) compute eq and AND together,
       loading from offset 4*idx. *)
    let a_loc = fresh_loc "ta" in
    let b_loc = fresh_loc "tb" in
    locals := (a_loc, "i32") :: !locals;
    locals := (b_loc, "i32") :: !locals;
    let setup =
      Printf.sprintf "(local.set %s %s) (local.set %s %s)" a_loc a_expr b_loc b_expr
    in
    let parts = List.map (fun (off, t) ->
      let fa = Printf.sprintf "(i32.load offset=%d (local.get %s))" off a_loc in
      let fb = Printf.sprintf "(i32.load offset=%d (local.get %s))" off b_loc in
      t, fa, fb) fields_offsets in
    parts, setup, a_loc, b_loc
  in
  let rec build ty a_expr b_expr =
    match Ast.walk ty with
    | Ast.TyTuple ts ->
      let fields_off = List.mapi (fun i t -> (i * 4, t)) ts in
      let parts, setup, _, _ = compound_eq fields_off a_expr b_expr in
      let combined =
        match parts with
        | [] -> "(i32.const 1)"
        | (t, a, b) :: rest ->
          let first = build t a b in
          List.fold_left (fun acc (t, a, b) ->
            Printf.sprintf "(i32.and %s %s)" acc (build t a b)) first rest
      in
      Printf.sprintf "(block (result i32) %s %s)" setup combined
    | Ast.TyCon (rname, _) when Hashtbl.mem Typer.records rname ->
      let info = Hashtbl.find Typer.records rname in
      let fields_off = List.mapi (fun i (_, ft) -> (i * 4, ft))
        info.Typer.r_fields in
      let parts, setup, _, _ = compound_eq fields_off a_expr b_expr in
      let combined =
        match parts with
        | [] -> "(i32.const 1)"
        | (t, a, b) :: rest ->
          let first = build t a b in
          List.fold_left (fun acc (t, a, b) ->
            Printf.sprintf "(i32.and %s %s)" acc (build t a b)) first rest
      in
      Printf.sprintf "(block (result i32) %s %s)" setup combined
    | Ast.TyCon (vname, _) when Hashtbl.mem Exhaustive.type_variants vname ->
      (* Phase 15.15/15.16: variant — compare tags at offset 0, then
         dispatch on tag to compare payload (or short-circuit to true for
         nullary ctors). *)
      let ctors = Hashtbl.find Exhaustive.type_variants vname in
      let has_payload = List.exists (fun (_, p) -> p <> None) ctors in
      if not has_payload then
        Printf.sprintf "(i32.eq (i32.load offset=0 %s) (i32.load offset=0 %s))"
          a_expr b_expr
      else begin
        let a_loc = fresh_loc "va" in
        let b_loc = fresh_loc "vb" in
        locals := (a_loc, "i32") :: !locals;
        locals := (b_loc, "i32") :: !locals;
        let setup =
          Printf.sprintf "(local.set %s %s) (local.set %s %s)" a_loc a_expr b_loc b_expr
        in
        let tag_a = Printf.sprintf "(i32.load offset=0 (local.get %s))" a_loc in
        let tag_b = Printf.sprintf "(i32.load offset=0 (local.get %s))" b_loc in
        let pl_a = Printf.sprintf "(i32.load offset=4 (local.get %s))" a_loc in
        let pl_b = Printf.sprintf "(i32.load offset=4 (local.get %s))" b_loc in
        let tags_eq =
          Printf.sprintf "(i32.eq %s %s)" tag_a tag_b
        in
        (* Build nested if/else chain over ctors. Default branch is 1
           (nullary or covered). *)
        let branches = List.filter_map (fun (cname, payload) ->
          match payload with
          | None -> None
          | Some pt ->
            let tv = Hashtbl.find variant_tags cname in
            Some (tv, Ast.walk pt)
        ) ctors in
        let rec emit_dispatch = function
          | [] -> "(i32.const 1)"
          | (tv, pt) :: rest ->
            let eq_pl = build pt pl_a pl_b in
            Printf.sprintf
              "(if (result i32) (i32.eq %s (i32.const %d)) (then %s) (else %s))"
              tag_a tv eq_pl (emit_dispatch rest)
        in
        Printf.sprintf
          "(block (result i32) %s (if (result i32) %s (then %s) (else (i32.const 0))))"
          setup tags_eq (emit_dispatch branches)
      end
    | _ -> emit_eq_for_atom ty a_expr b_expr
  in
  let body_expr = build k_ty "(local.get $a)" "(local.get $b)" in
  let local_decls =
    if !locals = [] then ""
    else
      "    " ^ String.concat " "
        (List.rev_map (fun (n, t) -> Printf.sprintf "(local %s %s)" n t) !locals)
      ^ "\n"
  in
  Printf.sprintf "  (func $mere_map_key_eq_%s (param $a i32) (param $b i32) (result i32)\n%s    %s)"
    k_tag local_decls body_expr

(* Phase 15.14: emit one Wasm map runtime per K type (new/set/get/has/len),
   each delegating to `$mere_map_key_eq_<K>`. Replaces the hardcoded
   map_int_runtime_wasm / map_str_runtime_wasm. *)
let emit_map_runtime_wasm (k_ty : Ast.ty) : string =
  let k_tag = ty_tag k_ty in
  Printf.sprintf "
  (func $mere_map_%s_new (result i32)
    (local $m i32) (local $keys i32) (local $values i32)
    (local.set $m (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $m) (i32.const 16)))
    (local.set $keys (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $keys) (i32.const 16)))
    (local.set $values (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $values) (i32.const 16)))
    (i32.store offset=0 (local.get $m) (local.get $keys))
    (i32.store offset=4 (local.get $m) (local.get $values))
    (i32.store offset=8 (local.get $m) (i32.const 0))
    (i32.store offset=12 (local.get $m) (i32.const 4))
    (local.get $m))
  (func $mere_map_%s_set (param $m i32) (param $k i32) (param $v i32) (result i32)
    (local $i i32) (local $len i32) (local $cap i32)
    (local $keys i32) (local $values i32)
    (local $new_keys i32) (local $new_values i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $mere_map_key_eq_%s
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            (i32.store
              (i32.add (local.get $values)
                       (i32.mul (local.get $i) (i32.const 4)))
              (local.get $v))
            (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (local.set $cap (i32.load offset=12 (local.get $m)))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_keys (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_keys)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $new_values (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_values)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $i (i32.const 0))
        (block $cp_end
          (loop $cp_lp
            (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
            (i32.store
              (i32.add (local.get $new_keys)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4)))))
            (i32.store
              (i32.add (local.get $new_values)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load (i32.add (local.get $values)
                                 (i32.mul (local.get $i) (i32.const 4)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp_lp)))
        (i32.store offset=0 (local.get $m) (local.get $new_keys))
        (i32.store offset=4 (local.get $m) (local.get $new_values))
        (i32.store offset=12 (local.get $m) (local.get $cap))
        (local.set $keys (local.get $new_keys))
        (local.set $values (local.get $new_values))))
    (i32.store
      (i32.add (local.get $keys) (i32.mul (local.get $len) (i32.const 4)))
      (local.get $k))
    (i32.store
      (i32.add (local.get $values) (i32.mul (local.get $len) (i32.const 4)))
      (local.get $v))
    (i32.store offset=8 (local.get $m)
      (i32.add (local.get $len) (i32.const 1)))
    (i32.const 0))
  (func $mere_map_%s_get (param $m i32) (param $k i32) (result i32)
    (local $i i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $mere_map_key_eq_%s
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            (return (i32.load (i32.add (local.get $values)
                                       (i32.mul (local.get $i) (i32.const 4)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (unreachable))
  (func $mere_map_%s_has (param $m i32) (param $k i32) (result i32)
    (local $i i32) (local $len i32) (local $keys i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $mere_map_key_eq_%s
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (i32.const 0))
  (func $mere_map_%s_len (param $m i32) (result i32)
    (i32.load offset=8 (local.get $m)))
  ;; Phase 19.2: map_iter — call outer(k) → inner closure, then inner(v).
  ;; outer closure: { env@0, fn_idx@4 }; outer(env, k) returns inner closure ptr.
  (func $mere_map_%s_iter (param $m i32) (param $cl i32) (result i32)
    (local $i i32) (local $len i32)
    (local $keys i32) (local $values i32)
    (local $outer_env i32) (local $outer_fn i32)
    (local $k i32) (local $v i32) (local $inner_cl i32)
    (local.set $len    (i32.load offset=8 (local.get $m)))
    (local.set $keys   (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $outer_env (i32.load offset=0 (local.get $cl)))
    (local.set $outer_fn  (i32.load offset=4 (local.get $cl)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (local.set $k (i32.load (i32.add (local.get $keys)
                                  (i32.mul (local.get $i) (i32.const 4)))))
        (local.set $v (i32.load (i32.add (local.get $values)
                                  (i32.mul (local.get $i) (i32.const 4)))))
        (local.set $inner_cl
          (call_indirect (type $cl) (local.get $outer_env) (local.get $k)
                         (local.get $outer_fn)))
        (drop (call_indirect (type $cl)
                (i32.load offset=0 (local.get $inner_cl))
                (local.get $v)
                (i32.load offset=4 (local.get $inner_cl))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.const 0))
  ;; Phase 39.A' #2: map_delete — when the key matches, shift keys/values down
  (func $mere_map_%s_delete (param $m i32) (param $k i32) (result i32)
    (local $i i32) (local $j i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $find_done
      (loop $find_lp
        (br_if $find_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $mere_map_key_eq_%s
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            (local.set $j (local.get $i))
            (block $shift_done
              (loop $shift_lp
                (br_if $shift_done (i32.ge_s (i32.add (local.get $j) (i32.const 1)) (local.get $len)))
                (i32.store
                  (i32.add (local.get $keys) (i32.mul (local.get $j) (i32.const 4)))
                  (i32.load (i32.add (local.get $keys) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)))))
                (i32.store
                  (i32.add (local.get $values) (i32.mul (local.get $j) (i32.const 4)))
                  (i32.load (i32.add (local.get $values) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $shift_lp)))
            (i32.store offset=8 (local.get $m) (i32.sub (local.get $len) (i32.const 1)))
            (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $find_lp)))
    (i32.const 0))"
    k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag

let map_int_runtime_wasm = {|
  (func $mere_map_int_new (result i32)
    (local $m i32) (local $keys i32) (local $values i32)
    (local.set $m (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $m) (i32.const 16)))
    (local.set $keys (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $keys) (i32.const 16)))
    (local.set $values (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $values) (i32.const 16)))
    (i32.store offset=0 (local.get $m) (local.get $keys))
    (i32.store offset=4 (local.get $m) (local.get $values))
    (i32.store offset=8 (local.get $m) (i32.const 0))
    (i32.store offset=12 (local.get $m) (i32.const 4))
    (local.get $m))
  (func $mere_map_int_set (param $m i32) (param $k i32) (param $v i32) (result i32)
    (local $i i32) (local $len i32) (local $cap i32)
    (local $keys i32) (local $values i32)
    (local $new_keys i32) (local $new_values i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.eq (i32.load (i32.add (local.get $keys)
                                       (i32.mul (local.get $i) (i32.const 4))))
                    (local.get $k))
          (then
            (i32.store
              (i32.add (local.get $values)
                       (i32.mul (local.get $i) (i32.const 4)))
              (local.get $v))
            (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    ;; not found: append, grow if full
    (local.set $cap (i32.load offset=12 (local.get $m)))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_keys (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_keys)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $new_values (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_values)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $i (i32.const 0))
        (block $cp_end
          (loop $cp_lp
            (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
            (i32.store
              (i32.add (local.get $new_keys)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4)))))
            (i32.store
              (i32.add (local.get $new_values)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load (i32.add (local.get $values)
                                 (i32.mul (local.get $i) (i32.const 4)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp_lp)))
        (i32.store offset=0 (local.get $m) (local.get $new_keys))
        (i32.store offset=4 (local.get $m) (local.get $new_values))
        (i32.store offset=12 (local.get $m) (local.get $cap))
        (local.set $keys (local.get $new_keys))
        (local.set $values (local.get $new_values))))
    (i32.store
      (i32.add (local.get $keys) (i32.mul (local.get $len) (i32.const 4)))
      (local.get $k))
    (i32.store
      (i32.add (local.get $values) (i32.mul (local.get $len) (i32.const 4)))
      (local.get $v))
    (i32.store offset=8 (local.get $m)
      (i32.add (local.get $len) (i32.const 1)))
    (i32.const 0))
  (func $mere_map_int_get (param $m i32) (param $k i32) (result i32)
    (local $i i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.eq (i32.load (i32.add (local.get $keys)
                                       (i32.mul (local.get $i) (i32.const 4))))
                    (local.get $k))
          (then
            (return (i32.load (i32.add (local.get $values)
                                       (i32.mul (local.get $i) (i32.const 4)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (unreachable))
  (func $mere_map_int_has (param $m i32) (param $k i32) (result i32)
    (local $i i32) (local $len i32) (local $keys i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.eq (i32.load (i32.add (local.get $keys)
                                       (i32.mul (local.get $i) (i32.const 4))))
                    (local.get $k))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (i32.const 0))
  (func $mere_map_int_len (param $m i32) (result i32)
    (i32.load offset=8 (local.get $m)))
  ;; Phase 39.A' #2: map_delete (int-key variant)
  (func $mere_map_int_delete (param $m i32) (param $k i32) (result i32)
    (local $i i32) (local $j i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $find_done
      (loop $find_lp
        (br_if $find_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.eq
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            (local.set $j (local.get $i))
            (block $shift_done
              (loop $shift_lp
                (br_if $shift_done (i32.ge_s (i32.add (local.get $j) (i32.const 1)) (local.get $len)))
                (i32.store
                  (i32.add (local.get $keys) (i32.mul (local.get $j) (i32.const 4)))
                  (i32.load (i32.add (local.get $keys) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)))))
                (i32.store
                  (i32.add (local.get $values) (i32.mul (local.get $j) (i32.const 4)))
                  (i32.load (i32.add (local.get $values) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $shift_lp)))
            (i32.store offset=8 (local.get $m) (i32.sub (local.get $len) (i32.const 1)))
            (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $find_lp)))
    (i32.const 0))|}

(* Same shape with $__lang_streq for key comparison (str keys). *)
let map_str_runtime_wasm = {|
  (func $mere_map_str_new (result i32)
    (local $m i32) (local $keys i32) (local $values i32)
    (local.set $m (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $m) (i32.const 16)))
    (local.set $keys (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $keys) (i32.const 16)))
    (local.set $values (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $values) (i32.const 16)))
    (i32.store offset=0 (local.get $m) (local.get $keys))
    (i32.store offset=4 (local.get $m) (local.get $values))
    (i32.store offset=8 (local.get $m) (i32.const 0))
    (i32.store offset=12 (local.get $m) (i32.const 4))
    (local.get $m))
  (func $mere_map_str_set (param $m i32) (param $k i32) (param $v i32) (result i32)
    (local $i i32) (local $len i32) (local $cap i32)
    (local $keys i32) (local $values i32)
    (local $new_keys i32) (local $new_values i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $__lang_streq
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            (i32.store
              (i32.add (local.get $values)
                       (i32.mul (local.get $i) (i32.const 4)))
              (local.get $v))
            (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (local.set $cap (i32.load offset=12 (local.get $m)))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_keys (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_keys)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $new_values (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_values)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $i (i32.const 0))
        (block $cp_end
          (loop $cp_lp
            (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
            (i32.store
              (i32.add (local.get $new_keys)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4)))))
            (i32.store
              (i32.add (local.get $new_values)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load (i32.add (local.get $values)
                                 (i32.mul (local.get $i) (i32.const 4)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp_lp)))
        (i32.store offset=0 (local.get $m) (local.get $new_keys))
        (i32.store offset=4 (local.get $m) (local.get $new_values))
        (i32.store offset=12 (local.get $m) (local.get $cap))
        (local.set $keys (local.get $new_keys))
        (local.set $values (local.get $new_values))))
    (i32.store
      (i32.add (local.get $keys) (i32.mul (local.get $len) (i32.const 4)))
      (local.get $k))
    (i32.store
      (i32.add (local.get $values) (i32.mul (local.get $len) (i32.const 4)))
      (local.get $v))
    (i32.store offset=8 (local.get $m)
      (i32.add (local.get $len) (i32.const 1)))
    (i32.const 0))
  (func $mere_map_str_get (param $m i32) (param $k i32) (result i32)
    (local $i i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $__lang_streq
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            (return (i32.load (i32.add (local.get $values)
                                       (i32.mul (local.get $i) (i32.const 4)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (unreachable))
  (func $mere_map_str_has (param $m i32) (param $k i32) (result i32)
    (local $i i32) (local $len i32) (local $keys i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $__lang_streq
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (i32.const 0))
  (func $mere_map_str_len (param $m i32) (result i32)
    (i32.load offset=8 (local.get $m)))
  ;; Phase 39.A' #2: map_delete (str-key variant) — when the key matches, shift keys/values
  (func $mere_map_str_delete (param $m i32) (param $k i32) (result i32)
    (local $i i32) (local $j i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $find_done
      (loop $find_lp
        (br_if $find_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $__lang_streq
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            ;; shift from i to len-1
            (local.set $j (local.get $i))
            (block $shift_done
              (loop $shift_lp
                (br_if $shift_done (i32.ge_s (i32.add (local.get $j) (i32.const 1)) (local.get $len)))
                (i32.store
                  (i32.add (local.get $keys) (i32.mul (local.get $j) (i32.const 4)))
                  (i32.load (i32.add (local.get $keys) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)))))
                (i32.store
                  (i32.add (local.get $values) (i32.mul (local.get $j) (i32.const 4)))
                  (i32.load (i32.add (local.get $values) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $shift_lp)))
            (i32.store offset=8 (local.get $m) (i32.sub (local.get $len) (i32.const 1)))
            (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $find_lp)))
    (i32.const 0))|}

(* ===== of_json (Wasm): JSON parser runtime + type-directed decoders =====
   A generic JSON tree is built in linear memory as 16-byte cells
   [kind@0, a@4, b@8, c@12]: NULL=0, BOOL=1(a=val), NUM=2(a=lexeme str),
   STR=3(a=str), ARR=4(a=count, b=head of {item@0,next@4} list),
   OBJ=5(a=count, b=head of {key@0,val@4,next@8} list). Parse errors set the
   global $__mj_err; strict of_json traps (unreachable), of_json_opt returns
   None. Mirrors the C backend (codegen_c). *)
let of_json_runtime_wasm : string = {ojw|
  (global $__mj_p (mut i32) (i32.const 0))
  (global $__mj_err (mut i32) (i32.const 0))
  (func $__oj_alloc (param $n i32) (result i32)
    (local $r i32)
    (local.set $r (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $r) (local.get $n)))
    (local.get $r))
  (func $__mj_ws
    (local $c i32)
    (block $end (loop $lp
      (local.set $c (i32.load8_u (global.get $__mj_p)))
      (br_if $end (i32.eqz (i32.or
        (i32.or (i32.eq (local.get $c) (i32.const 32)) (i32.eq (local.get $c) (i32.const 9)))
        (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 13))))))
      (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
      (br $lp))))
  (func $__mj_cell (param $kind i32) (result i32)
    (local $r i32)
    (local.set $r (call $__oj_alloc (i32.const 16)))
    (i32.store offset=0 (local.get $r) (local.get $kind))
    (i32.store offset=4 (local.get $r) (i32.const 0))
    (i32.store offset=8 (local.get $r) (i32.const 0))
    (i32.store offset=12 (local.get $r) (i32.const 0))
    (local.get $r))
  (func $__mj_atoi (param $s i32) (result i32)
    (local $r i32) (local $neg i32) (local $c i32)
    (local.set $r (i32.const 0)) (local.set $neg (i32.const 0))
    (if (i32.eq (i32.load8_u (local.get $s)) (i32.const 45))
      (then (local.set $neg (i32.const 1)) (local.set $s (i32.add (local.get $s) (i32.const 1)))))
    (block $end (loop $lp
      (local.set $c (i32.load8_u (local.get $s)))
      (br_if $end (i32.lt_u (local.get $c) (i32.const 48)))
      (br_if $end (i32.gt_u (local.get $c) (i32.const 57)))
      (local.set $r (i32.add (i32.mul (local.get $r) (i32.const 10)) (i32.sub (local.get $c) (i32.const 48))))
      (local.set $s (i32.add (local.get $s) (i32.const 1)))
      (br $lp)))
    (if (result i32) (local.get $neg) (then (i32.sub (i32.const 0) (local.get $r))) (else (local.get $r))))
  (func $__mj_pstr (result i32)
    (local $r i32) (local $len i32) (local $c i32) (local $e i32)
    (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
    (local.set $r (global.get $__lang_bump))
    (local.set $len (i32.const 0))
    (block $end (loop $lp
      (local.set $c (i32.load8_u (global.get $__mj_p)))
      (if (i32.eqz (local.get $c)) (then (global.set $__mj_err (i32.const 1)) (br $end)))
      (if (i32.eq (local.get $c) (i32.const 34))
        (then (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1))) (br $end)))
      (if (i32.eq (local.get $c) (i32.const 92))
        (then
          (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
          (local.set $e (i32.load8_u (global.get $__mj_p)))
          (local.set $c
            (if (result i32) (i32.eq (local.get $e) (i32.const 110)) (then (i32.const 10))
            (else (if (result i32) (i32.eq (local.get $e) (i32.const 116)) (then (i32.const 9))
            (else (if (result i32) (i32.eq (local.get $e) (i32.const 114)) (then (i32.const 13))
            (else (local.get $e))))))))))
      (i32.store8 (i32.add (local.get $r) (local.get $len)) (local.get $c))
      (local.set $len (i32.add (local.get $len) (i32.const 1)))
      (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
      (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $len)) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (local.get $len)) (i32.const 1)))
    (local.get $r))
  (func $__mj_num (result i32)
    (local $r i32) (local $len i32) (local $c i32)
    (local.set $r (global.get $__lang_bump))
    (local.set $len (i32.const 0))
    (block $end (loop $lp
      (local.set $c (i32.load8_u (global.get $__mj_p)))
      (br_if $end (i32.eqz (i32.or
        (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 57)))
        (i32.or (i32.eq (local.get $c) (i32.const 46))
        (i32.or (i32.eq (local.get $c) (i32.const 101))
        (i32.or (i32.eq (local.get $c) (i32.const 69))
        (i32.or (i32.eq (local.get $c) (i32.const 43))
                (i32.eq (local.get $c) (i32.const 45)))))))))
      (i32.store8 (i32.add (local.get $r) (local.get $len)) (local.get $c))
      (local.set $len (i32.add (local.get $len) (i32.const 1)))
      (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
      (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $len)) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (local.get $len)) (i32.const 1)))
    (local.get $r))
  (func $__mj_value (result i32)
    (local $c i32) (local $cell i32)
    (call $__mj_ws)
    (local.set $c (i32.load8_u (global.get $__mj_p)))
    (if (i32.eq (local.get $c) (i32.const 123)) (then (return (call $__mj_object))))
    (if (i32.eq (local.get $c) (i32.const 91)) (then (return (call $__mj_array))))
    (if (i32.eq (local.get $c) (i32.const 34))
      (then
        (local.set $cell (call $__mj_cell (i32.const 3)))
        (i32.store offset=4 (local.get $cell) (call $__mj_pstr))
        (return (local.get $cell))))
    (if (i32.eq (local.get $c) (i32.const 116))
      (then
        (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 4)))
        (local.set $cell (call $__mj_cell (i32.const 1)))
        (i32.store offset=4 (local.get $cell) (i32.const 1))
        (return (local.get $cell))))
    (if (i32.eq (local.get $c) (i32.const 102))
      (then
        (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 5)))
        (local.set $cell (call $__mj_cell (i32.const 1)))
        (i32.store offset=4 (local.get $cell) (i32.const 0))
        (return (local.get $cell))))
    (if (i32.eq (local.get $c) (i32.const 110))
      (then
        (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 4)))
        (return (call $__mj_cell (i32.const 0)))))
    (if (i32.or (i32.eq (local.get $c) (i32.const 45))
                (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 57))))
      (then
        (local.set $cell (call $__mj_cell (i32.const 2)))
        (i32.store offset=4 (local.get $cell) (call $__mj_num))
        (return (local.get $cell))))
    (global.set $__mj_err (i32.const 1))
    (call $__mj_cell (i32.const 0)))
  (func $__mj_array (result i32)
    (local $cell i32) (local $head i32) (local $tail i32) (local $count i32)
    (local $node i32) (local $item i32) (local $c i32)
    (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
    (local.set $head (i32.const 0)) (local.set $tail (i32.const 0)) (local.set $count (i32.const 0))
    (call $__mj_ws)
    (if (i32.eq (i32.load8_u (global.get $__mj_p)) (i32.const 93))
      (then
        (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
        (return (call $__mj_cell (i32.const 4)))))
    (block $done (loop $lp
      (local.set $item (call $__mj_value))
      (br_if $done (global.get $__mj_err))
      (local.set $node (call $__oj_alloc (i32.const 8)))
      (i32.store offset=0 (local.get $node) (local.get $item))
      (i32.store offset=4 (local.get $node) (i32.const 0))
      (if (i32.eqz (local.get $head))
        (then (local.set $head (local.get $node)) (local.set $tail (local.get $node)))
        (else (i32.store offset=4 (local.get $tail) (local.get $node)) (local.set $tail (local.get $node))))
      (local.set $count (i32.add (local.get $count) (i32.const 1)))
      (call $__mj_ws)
      (local.set $c (i32.load8_u (global.get $__mj_p)))
      (if (i32.eq (local.get $c) (i32.const 44))
        (then (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1))) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 93))
        (then (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1))) (br $done)))
      (global.set $__mj_err (i32.const 1)) (br $done)))
    (local.set $cell (call $__mj_cell (i32.const 4)))
    (i32.store offset=4 (local.get $cell) (local.get $count))
    (i32.store offset=8 (local.get $cell) (local.get $head))
    (local.get $cell))
  (func $__mj_object (result i32)
    (local $cell i32) (local $head i32) (local $tail i32) (local $count i32)
    (local $node i32) (local $key i32) (local $val i32) (local $c i32)
    (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
    (local.set $head (i32.const 0)) (local.set $tail (i32.const 0)) (local.set $count (i32.const 0))
    (call $__mj_ws)
    (if (i32.eq (i32.load8_u (global.get $__mj_p)) (i32.const 125))
      (then
        (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
        (return (call $__mj_cell (i32.const 5)))))
    (block $done (loop $lp
      (call $__mj_ws)
      (if (i32.ne (i32.load8_u (global.get $__mj_p)) (i32.const 34))
        (then (global.set $__mj_err (i32.const 1)) (br $done)))
      (local.set $key (call $__mj_pstr))
      (call $__mj_ws)
      (if (i32.ne (i32.load8_u (global.get $__mj_p)) (i32.const 58))
        (then (global.set $__mj_err (i32.const 1)) (br $done)))
      (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
      (local.set $val (call $__mj_value))
      (br_if $done (global.get $__mj_err))
      (local.set $node (call $__oj_alloc (i32.const 12)))
      (i32.store offset=0 (local.get $node) (local.get $key))
      (i32.store offset=4 (local.get $node) (local.get $val))
      (i32.store offset=8 (local.get $node) (i32.const 0))
      (if (i32.eqz (local.get $head))
        (then (local.set $head (local.get $node)) (local.set $tail (local.get $node)))
        (else (i32.store offset=8 (local.get $tail) (local.get $node)) (local.set $tail (local.get $node))))
      (local.set $count (i32.add (local.get $count) (i32.const 1)))
      (call $__mj_ws)
      (local.set $c (i32.load8_u (global.get $__mj_p)))
      (if (i32.eq (local.get $c) (i32.const 44))
        (then (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1))) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 125))
        (then (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1))) (br $done)))
      (global.set $__mj_err (i32.const 1)) (br $done)))
    (local.set $cell (call $__mj_cell (i32.const 5)))
    (i32.store offset=4 (local.get $cell) (local.get $count))
    (i32.store offset=8 (local.get $cell) (local.get $head))
    (local.get $cell))
  (func $__mj_parse (param $s i32) (result i32)
    (global.set $__mj_p (local.get $s))
    (global.set $__mj_err (i32.const 0))
    (call $__mj_value))
  (func $__mj_field (param $obj i32) (param $key i32) (result i32)
    (local $node i32)
    (if (i32.ne (i32.load offset=0 (local.get $obj)) (i32.const 5))
      (then (global.set $__mj_err (i32.const 1)) (return (i32.const 0))))
    (local.set $node (i32.load offset=8 (local.get $obj)))
    (block $done (loop $lp
      (br_if $done (i32.eqz (local.get $node)))
      (if (call $__lang_streq (i32.load offset=0 (local.get $node)) (local.get $key))
        (then (return (i32.load offset=4 (local.get $node)))))
      (local.set $node (i32.load offset=8 (local.get $node)))
      (br $lp)))
    (global.set $__mj_err (i32.const 1))
    (i32.const 0))
  (func $__mj_index (param $arr i32) (param $i i32) (result i32)
    (local $node i32)
    (local.set $node (i32.load offset=8 (local.get $arr)))
    (block $done (loop $lp
      (br_if $done (i32.eqz (local.get $i)))
      (br_if $done (i32.eqz (local.get $node)))
      (local.set $node (i32.load offset=4 (local.get $node)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $lp)))
    (if (result i32) (i32.eqz (local.get $node)) (then (i32.const 0)) (else (i32.load offset=0 (local.get $node)))))
|ojw}

(* Emit `$__ojnode_<tag>` (mj_node -> value) + `$of_json_<tag>` (str ->
   value; strict: traps on error). *)
let emit_of_json_fn (tag : string) (t : Ast.ty) : string =
  let b = Buffer.create 512 in
  let node = Printf.sprintf "$__ojnode_%s" tag in
  Buffer.add_string b (Printf.sprintf "  (func %s (param $j i32) (result i32)\n" node);
  (match Ast.walk t with
   | Ast.TyInt ->
     Buffer.add_string b
       "    (if (i32.ne (i32.load offset=0 (local.get $j)) (i32.const 2)) (then (global.set $__mj_err (i32.const 1)) (return (i32.const 0))))\n\
       \    (call $__mj_atoi (i32.load offset=4 (local.get $j))))\n"
   | Ast.TyBool ->
     Buffer.add_string b
       "    (if (i32.ne (i32.load offset=0 (local.get $j)) (i32.const 1)) (then (global.set $__mj_err (i32.const 1)) (return (i32.const 0))))\n\
       \    (i32.load offset=4 (local.get $j)))\n"
   | Ast.TyStr ->
     Buffer.add_string b
       "    (if (i32.ne (i32.load offset=0 (local.get $j)) (i32.const 3)) (then (global.set $__mj_err (i32.const 1)) (return (i32.const 0))))\n\
       \    (i32.load offset=4 (local.get $j)))\n"
   | Ast.TyUnit ->
     Buffer.add_string b "    (drop (local.get $j)) (i32.const 0))\n"
   | Ast.TyTuple ts ->
     let n = List.length ts in
     Buffer.add_string b "    (local $r i32)\n";
     Buffer.add_string b
       "    (if (i32.ne (i32.load offset=0 (local.get $j)) (i32.const 4)) (then (global.set $__mj_err (i32.const 1)) (return (i32.const 0))))\n";
     Buffer.add_string b (Printf.sprintf "    (local.set $r (call $__oj_alloc (i32.const %d)))\n" (4 * n));
     List.iteri (fun i et ->
       Buffer.add_string b
         (Printf.sprintf
            "    (i32.store offset=%d (local.get $r) (call $__ojnode_%s (call $__mj_index (local.get $j) (i32.const %d))))\n"
            (4 * i) (ty_tag (Ast.walk et)) i)) ts;
     Buffer.add_string b "    (local.get $r))\n"
   | Ast.TyCon ("list", [elem]) ->
     let elem_tag = ty_tag (Ast.walk elem) in
     let nil_tag = try Hashtbl.find variant_tags "Nil" with Not_found -> 0 in
     let cons_tag = try Hashtbl.find variant_tags "Cons" with Not_found -> 1 in
     Buffer.add_string b "    (local $it i32) (local $rev i32) (local $rn i32) (local $acc i32) (local $pl i32) (local $node i32)\n";
     Buffer.add_string b
       "    (if (i32.ne (i32.load offset=0 (local.get $j)) (i32.const 4)) (then (global.set $__mj_err (i32.const 1)) (return (i32.const 0))))\n";
     (* reverse the item list into $rev *)
     Buffer.add_string b "    (local.set $rev (i32.const 0))\n";
     Buffer.add_string b "    (local.set $it (i32.load offset=8 (local.get $j)))\n";
     Buffer.add_string b
       "    (block $r1 (loop $l1\n\
       \      (br_if $r1 (i32.eqz (local.get $it)))\n\
       \      (local.set $rn (call $__oj_alloc (i32.const 8)))\n\
       \      (i32.store offset=0 (local.get $rn) (i32.load offset=0 (local.get $it)))\n\
       \      (i32.store offset=4 (local.get $rn) (local.get $rev))\n\
       \      (local.set $rev (local.get $rn))\n\
       \      (local.set $it (i32.load offset=4 (local.get $it)))\n\
       \      (br $l1)))\n";
     (* acc = Nil *)
     Buffer.add_string b (Printf.sprintf "    (local.set $acc (call $__oj_alloc (i32.const 8)))\n    (i32.store offset=0 (local.get $acc) (i32.const %d))\n" nil_tag);
     (* fold rev: acc = Cons(decode item, acc) *)
     Buffer.add_string b
       (Printf.sprintf
       "    (block $r2 (loop $l2\n\
       \      (br_if $r2 (i32.eqz (local.get $rev)))\n\
       \      (local.set $pl (call $__oj_alloc (i32.const 8)))\n\
       \      (i32.store offset=0 (local.get $pl) (call $__ojnode_%s (i32.load offset=0 (local.get $rev))))\n\
       \      (i32.store offset=4 (local.get $pl) (local.get $acc))\n\
       \      (local.set $node (call $__oj_alloc (i32.const 8)))\n\
       \      (i32.store offset=0 (local.get $node) (i32.const %d))\n\
       \      (i32.store offset=4 (local.get $node) (local.get $pl))\n\
       \      (local.set $acc (local.get $node))\n\
       \      (local.set $rev (i32.load offset=4 (local.get $rev)))\n\
       \      (br $l2)))\n"
       elem_tag cons_tag);
     Buffer.add_string b "    (local.get $acc))\n"
   | Ast.TyCon ("option", [inner]) ->
     let inner_tag = ty_tag (Ast.walk inner) in
     let none_tag = try Hashtbl.find variant_tags "None" with Not_found -> 0 in
     let some_tag = try Hashtbl.find variant_tags "Some" with Not_found -> 1 in
     Buffer.add_string b "    (local $r i32)\n";
     Buffer.add_string b
       (Printf.sprintf
       "    (if (result i32) (i32.eq (i32.load offset=0 (local.get $j)) (i32.const 0))\n\
       \      (then\n\
       \        (local.set $r (call $__oj_alloc (i32.const 8)))\n\
       \        (i32.store offset=0 (local.get $r) (i32.const %d))\n\
       \        (local.get $r))\n\
       \      (else\n\
       \        (local.set $r (call $__oj_alloc (i32.const 8)))\n\
       \        (i32.store offset=0 (local.get $r) (i32.const %d))\n\
       \        (i32.store offset=4 (local.get $r) (call $__ojnode_%s (local.get $j)))\n\
       \        (local.get $r))))\n"
       none_tag some_tag inner_tag)
   | Ast.TyCon (name, args) when Hashtbl.mem Typer.records name ->
     let info = Hashtbl.find Typer.records name in
     let mapping = if info.Typer.r_params = [] then [] else List.combine info.Typer.r_params args in
     let n = List.length info.Typer.r_fields in
     Buffer.add_string b "    (local $r i32)\n";
     Buffer.add_string b (Printf.sprintf "    (local.set $r (call $__oj_alloc (i32.const %d)))\n" (4 * n));
     List.iteri (fun i (fname, ft) ->
       let ft = subst_params mapping ft in
       let key = intern_show_str fname in
       Buffer.add_string b
         (Printf.sprintf
            "    (i32.store offset=%d (local.get $r) (call $__ojnode_%s (call $__mj_field (local.get $j) (i32.const %d))))\n"
            (4 * i) (ty_tag (Ast.walk ft)) key)) info.Typer.r_fields;
     Buffer.add_string b "    (local.get $r))\n"
   | Ast.TyCon (name, args) ->
     (* general variant: STR -> nullary; OBJ{1} -> payload ctor *)
     let vs =
       match Hashtbl.find_opt Exhaustive.type_variants name with
       | Some vs -> vs | None -> []
     in
     let mapping =
       match vs with
       | (cname, _) :: _ ->
         (match Hashtbl.find_opt Typer.constructors cname with
          | Some info when info.Typer.params <> [] -> List.combine info.Typer.params args
          | _ -> [])
       | [] -> []
     in
     let variants =
       List.map (fun (cname, arg_opt) ->
         (cname, match arg_opt with Some t -> Some (subst_params mapping t) | None -> None)) vs
     in
     Buffer.add_string b "    (local $r i32) (local $k i32) (local $v i32)\n";
     (* nullary from STR *)
     Buffer.add_string b "    (if (i32.eq (i32.load offset=0 (local.get $j)) (i32.const 3)) (then\n";
     List.iter (fun (cname, arg_opt) ->
       match arg_opt with
       | None ->
         let tag_n = try Hashtbl.find variant_tags cname with Not_found -> 0 in
         let nm = intern_show_str cname in
         Buffer.add_string b
           (Printf.sprintf
              "      (if (call $__lang_streq (i32.load offset=4 (local.get $j)) (i32.const %d)) (then\n\
              \        (local.set $r (call $__oj_alloc (i32.const 8))) (i32.store offset=0 (local.get $r) (i32.const %d)) (return (local.get $r))))\n"
              nm tag_n)
       | Some _ -> ()) variants;
     Buffer.add_string b "      ))\n";
     (* payload from OBJ single-key *)
     Buffer.add_string b "    (if (i32.eq (i32.load offset=0 (local.get $j)) (i32.const 5)) (then\n";
     Buffer.add_string b "      (local.set $k (i32.load offset=0 (i32.load offset=8 (local.get $j))))\n";
     Buffer.add_string b "      (local.set $v (i32.load offset=4 (i32.load offset=8 (local.get $j))))\n";
     List.iter (fun (cname, arg_opt) ->
       match arg_opt with
       | Some ty ->
         let tag_n = try Hashtbl.find variant_tags cname with Not_found -> 0 in
         let nm = intern_show_str cname in
         Buffer.add_string b
           (Printf.sprintf
              "      (if (call $__lang_streq (local.get $k) (i32.const %d)) (then\n\
              \        (local.set $r (call $__oj_alloc (i32.const 8))) (i32.store offset=0 (local.get $r) (i32.const %d))\n\
              \        (i32.store offset=4 (local.get $r) (call $__ojnode_%s (local.get $v))) (return (local.get $r))))\n"
              nm tag_n (ty_tag (Ast.walk ty)))
       | None -> ()) variants;
     Buffer.add_string b "      ))\n";
     Buffer.add_string b "    (global.set $__mj_err (i32.const 1)) (i32.const 0))\n"
   | _ ->
     Buffer.add_string b "    (drop (local.get $j)) (global.set $__mj_err (i32.const 1)) (i32.const 0))\n");
  (* strict string entry: trap on error *)
  Buffer.add_string b
    (Printf.sprintf
       "  (func $of_json_%s (param $s i32) (result i32)\n\
       \    (local $v i32)\n\
       \    (local.set $v (call $__ojnode_%s (call $__mj_parse (local.get $s))))\n\
       \    (if (global.get $__mj_err) (then unreachable))\n\
       \    (local.get $v))\n"
       tag tag);
  Buffer.contents b

(* of_json_opt_<inner>: parse + decode; None on error, else Some. *)
let emit_of_json_opt_fn (inner_tag : string) (_inner_t : Ast.ty) : string =
  let none_tag = try Hashtbl.find variant_tags "None" with Not_found -> 0 in
  let some_tag = try Hashtbl.find variant_tags "Some" with Not_found -> 1 in
  Printf.sprintf
    "  (func $of_json_opt_%s (param $s i32) (result i32)\n\
    \    (local $v i32) (local $r i32)\n\
    \    (local.set $v (call $__ojnode_%s (call $__mj_parse (local.get $s))))\n\
    \    (local.set $r (call $__oj_alloc (i32.const 8)))\n\
    \    (if (result i32) (global.get $__mj_err)\n\
    \      (then (i32.store offset=0 (local.get $r) (i32.const %d)) (local.get $r))\n\
    \      (else (i32.store offset=0 (local.get $r) (i32.const %d)) (i32.store offset=4 (local.get $r) (local.get $v)) (local.get $r))))\n"
    inner_tag inner_tag none_tag some_tag

let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  ignore main_ty;
  reset ();
  Hashtbl.reset toplevel_fn_names;
  Hashtbl.reset variant_tags;
  Hashtbl.reset fn_closure_table_idx;
  Hashtbl.reset eta_adapters_wasm;
  Hashtbl.reset show_types;
  Hashtbl.reset to_json_types;
  Hashtbl.reset of_json_types;
  Hashtbl.reset of_json_opt_types;
  Hashtbl.reset eq_types;
  Hashtbl.reset show_str_offsets;
  table_entries := [];
  pending_closures := [];
  anon_counter := 0;
  Hashtbl.reset inner_lifts_wasm;
  Hashtbl.reset inner_lifts_by_host_wasm;
  inner_fn_counter_wasm := 0;
  lifted_fns_wasm := [];
  current_host_fn_wasm := "";
  Hashtbl.reset inner_lift_closures_emitted_wasm;
  inner_lift_closure_pending_wasm := [];
  Hashtbl.reset multi_inst_fns_wasm;
  str_data_decls := [];
  str_offset_counter := str_initial_offset;
  vec_used := false;
  vec_higher_order_used := false;
  strbuf_used := false;
  logger_used := false;
  metrics_used := false;
  uses_threads := false;
  char_table_used := false;
  fail_used := false;
  substring_used := false;
  int_of_str_used := false;
  str_unescape_used := false;
  str_split_used := false;
  str_join_used := false;
  str_count_used := false;
  file_io_used := false;
  map_int_used := false;
  map_str_used := false;
  Hashtbl.reset map_key_types;
  vec_to_list_used := false;
  list_len_used := false;
  (* Pre-register variant tags from Exhaustive's registry. *)
  Hashtbl.iter (fun _name vs ->
    List.iteri (fun i (cname, _) ->
      Hashtbl.replace variant_tags cname i) vs
  ) Exhaustive.type_variants;
  let main_expr = Ast.desugar_program prog in
  (* Phase 15.4: resolve let-bound Vec element types. Same trick as
     codegen_c / codegen_llvm — Mere's let-poly generalizes
     `let v = vec_new () in body` to `forall T. Vec[..., T]`, so each
     use of v in body gets a fresh element tyvar. Walk the typed AST
     and unify the binding-site element with each `Var name`.ty.
     Wasm doesn't need monomorphic types (everything is i32) but we
     still want the binding's recorded type to be concrete so
     downstream tooling / show / typed annotations behave consistently. *)
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
  (* Phase 32.4 (C1 FFI): walk prog.decls to register extern fn names. *)
  Hashtbl.reset extern_fn_decls_wasm;
  List.iter (fun decl ->
    match decl with
    | Ast.Top_extern (name, ty) ->
      Hashtbl.replace extern_fn_decls_wasm name (Ast.walk ty)
    | _ -> ()
  ) prog.decls;
  let skels, body_expr = lift_fn_skels main_expr in
  List.iter (fun s -> Hashtbl.replace toplevel_fn_names s.sname ()) skels;
  (* Phase 30.2c (DEFERRED §1.10): make those top-level non-fn lets that are
     referenced from skels' fn bodies into Wasm `(global $name (mut i32))`. *)
  let fvs_used_in_skels_wasm =
    List.fold_left (fun acc s ->
      let fvs = free_vars s.sbody [s.sparam] in
      List.sort_uniq compare (fvs @ acc))
      [] skels
  in
  let needs_global_wasm name = List.mem name fvs_used_in_skels_wasm in
  (* Phase 36 (DEFERRED §1.18 fix): keep Let bindings in body so global
     init happens at source-order position. emit_expr Let emits
     `global.set $name` for top_globals_wasm names. *)
  let top_globals_list =
    let rec go e =
      match e.Ast.node with
      | Ast.Let (pat, value, rest) ->
        (match pat.Ast.pnode with
         | Ast.P_var name when needs_global_wasm name ->
           (match value.Ast.node with
            | Ast.Fun _ -> go rest
            | _ -> (name, value) :: go rest)
         | _ -> go rest)
      | _ -> []
    in
    go body_expr
  in
  Hashtbl.reset top_globals_wasm;
  List.iter (fun (n, _) -> Hashtbl.add top_globals_wasm n ()) top_globals_list;
  let fns = resolve_fn_types skels main_expr in
  (* Phase 26.3 (port of LLVM Phase 25.7): dedupe by name, keeping the
     LAST occurrence — when user defines a name that's also in stdlib
     prelude, user's def (later in chain) should shadow. *)
  let fns =
    let seen : (string, unit) Hashtbl.t = Hashtbl.create 16 in
    List.rev (
      List.fold_left (fun acc f ->
        if Hashtbl.mem seen f.name then acc
        else begin Hashtbl.add seen f.name (); f :: acc end
      ) [] (List.rev fns)
    )
  in
  collect_show_types main_expr fns;
  (* Phase 27.2: register show_<main_ty> so the auto-print at end of main
     has the right helper available. *)
  add_show_type main_ty;
  (* Phase 26.3: lift inner fns to top-level. Must run BEFORE emit_fn_def.
     Phase 26.4: include multi-inst base names so inner free_var analysis
     treats them as known toplevels (not captured). Call sites get
     rewritten to mangled spec at emit time. *)
  let mangled_names = List.map (fun f -> f.name) fns in
  let multi_base_names =
    Hashtbl.fold (fun k _ acc -> k :: acc) multi_inst_fns_wasm []
  in
  let toplevel_names = mangled_names @ multi_base_names in
  lift_inner_fns_wasm toplevel_names fns;
  (* Phase 36 (DEFERRED §1.19 fix): register top-level closure adapter
     table indices BEFORE emit_fn_def so that fn bodies (and nested
     lambdas) can resolve `Var <top_fn>` as a closure value via
     fn_closure_table_idx. The actual adapter WAT is still emitted after
     the fn_defs (top_adapters / lifted_defs), but the index registry must
     be populated up front. *)
  let top_adapters =
    List.map (fun f ->
      let idx = register_in_table (f.name ^ "_closure") in
      Hashtbl.replace fn_closure_table_idx f.name idx;
      emit_top_adapter f
    ) fns
  in
  let fn_defs = List.map emit_fn_def fns in
  let lifted_defs = List.map emit_lifted_fn_wasm !lifted_fns_wasm in
  (* Emit one specialized `show_<tag>` function per registered type. *)
  let show_fn_defs =
    Hashtbl.fold (fun tag t acc -> emit_show_fn tag t :: acc) show_types []
  in
  let to_json_fn_defs =
    Hashtbl.fold (fun tag t acc -> emit_to_json_fn tag t :: acc) to_json_types []
  in
  let of_json_used =
    Hashtbl.length of_json_types > 0 || Hashtbl.length of_json_opt_types > 0
  in
  let of_json_fn_defs =
    (if of_json_used then [of_json_runtime_wasm] else [])
    @ Hashtbl.fold (fun tag t acc -> emit_of_json_fn tag t :: acc) of_json_types []
    @ Hashtbl.fold (fun tag t acc -> emit_of_json_opt_fn tag t :: acc) of_json_opt_types []
  in
  let eq_fn_defs =
    Hashtbl.fold (fun tag t acc -> emit_eq_fn tag t :: acc) eq_types []
  in
  (* Reset counters for the main body. *)
  reset ();
  (* Phase 36 (DEFERRED §1.18 fix): globals are initialized inline in
     body_expr via emit_expr Let emitting `global.set $name`. The
     top-level flag gates that behavior — nested let bindings inside
     fn bodies (imported modules etc.) that happen to share a name
     with a top-level global are plain locals. *)
  ignore top_globals_list;
  wasm_in_top_level_body := true;
  emit_expr body_expr;
  wasm_in_top_level_body := false;
  (* Phase 27.2: print main's result to stdout via $puts so wasm runtime
     output matches interp's `Pipeline.process s |> print_endline`. The
     stack-top has body's i32 result; pipe through show_<tag> if needed,
     then puts. Unit main: drop result, call puts on "()" literal. *)
  let main_ty_walked = Ast.walk main_ty in
  (match main_ty_walked with
   | Ast.TyInt ->
     emit_instr "call $show_int";
     emit_instr "call $puts";
     emit_instr "i32.const 0"
   | Ast.TyBool ->
     emit_instr "call $show_bool";
     emit_instr "call $puts";
     emit_instr "i32.const 0"
   | Ast.TyStr ->
     (* show_str wraps in quotes; here we want raw print of the main expr,
        but interp's Eval.to_string for V_str wraps in quotes too. *)
     emit_instr "call $show_str";
     emit_instr "call $puts";
     emit_instr "i32.const 0"
   | Ast.TyUnit ->
     emit_instr "drop";
     let unit_off = intern_show_str "()" in
     emit_instr (Printf.sprintf "i32.const %d" unit_off);
     emit_instr "call $puts";
     emit_instr "i32.const 0"
   | Ast.TyFloat ->
     (* Phase 34.3: float main result — load f64 from ptr, str_of_float via
        env import (JS formats like OCaml's string_of_float), then puts *)
     emit_instr "f64.load offset=0 align=8";
     emit_instr "call $__lang_str_of_float";
     emit_instr "call $puts";
     emit_instr "i32.const 0"
   | _ ->
     (* Best-effort: drop body and return 0. *)
     emit_instr "drop";
     emit_instr "i32.const 0");
  let body_instrs = List.rev !instrs in
  let local_count = !local_counter in
  let local_decl =
    if local_count = 0 then "" else
      (* Phase 34.3: declare typed locals (i32 / f64) via local_types *)
      let types =
        if List.length !local_types = local_count then !local_types
        else List.init local_count (fun _ -> "i32")
      in
      Printf.sprintf "    (local%s)\n"
        (String.concat "" (List.map (fun t -> " " ^ t) types))
  in
  let indented_body =
    String.concat "\n" (List.map (fun s -> "    " ^ s) body_instrs)
  in
  (* Drain pending anonymous-Fun adapters (Fun emits can nest, so
     adapter emission may push more — iterate to a fixpoint). *)
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
  (* Phase 39.A2: generate adapters for Inner-lifted fns as WAT.
     The adapter takes env_offset + arg, loads caps from env, and calls the
     lifted fn with caps... + arg. *)
  let inner_lift_adapter_strs =
    List.rev_map (fun (lifted_name, captures, _idx) ->
      let load_caps =
        List.mapi (fun i _ ->
          Printf.sprintf
            "    local.get 0\n    i32.load offset=%d"
            (i * 4))
          captures
        |> String.concat "\n"
      in
      Printf.sprintf
        "  (func $%s_inner_closure_fn (param i32) (param i32) (result i32)\n%s\n    local.get 1\n    call $%s)"
        lifted_name load_caps lifted_name
    ) !inner_lift_closure_pending_wasm
  in
  (* Phase 16.3 / DEFERRED §1.5: Logger / Metrics runtime — register
     helper fns in the table now (after main body has populated
     table_entries with user closures), so their indices are stable.
     The runtime body is built with the indices interpolated. *)
  let logger_runtime_section =
    if not !logger_used then "" else begin
      let info_idx  = register_in_table "__mere_logger_info_fn" in
      let warn_idx  = register_in_table "__mere_logger_warn_fn" in
      let error_idx = register_in_table "__mere_logger_error_fn" in
      let info_prefix_off  = fresh_str_offset " [INFO] " in
      let warn_prefix_off  = fresh_str_offset " [WARN] " in
      let error_prefix_off = fresh_str_offset " [ERROR] " in
      Printf.sprintf {|
  (func $__mere_logger_info_fn (param $env i32) (param $msg i32) (result i32)
    (local $tmp i32)
    (local.set $tmp (call $__lang_str_concat (local.get $env) (i32.const %d)))
    (local.set $tmp (call $__lang_str_concat (local.get $tmp) (local.get $msg)))
    (call $puts (local.get $tmp))
    (i32.const 0))
  (func $__mere_logger_warn_fn (param $env i32) (param $msg i32) (result i32)
    (local $tmp i32)
    (local.set $tmp (call $__lang_str_concat (local.get $env) (i32.const %d)))
    (local.set $tmp (call $__lang_str_concat (local.get $tmp) (local.get $msg)))
    (call $puts (local.get $tmp))
    (i32.const 0))
  (func $__mere_logger_error_fn (param $env i32) (param $msg i32) (result i32)
    (local $tmp i32)
    (local.set $tmp (call $__lang_str_concat (local.get $env) (i32.const %d)))
    (local.set $tmp (call $__lang_str_concat (local.get $tmp) (local.get $msg)))
    (call $puts (local.get $tmp))
    (i32.const 0))
  (func $__mere_mk_logger (param $prefix i32) (result i32)
    (local $logger i32) (local $cl i32)
    ;; Logger record: 3 ptrs to closures = 12 bytes
    (local.set $logger (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $logger) (i32.const 12)))
    ;; info closure (8 bytes: env, fn_idx)
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (local.get $prefix))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (i32.store offset=0 (local.get $logger) (local.get $cl))
    ;; warn
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (local.get $prefix))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (i32.store offset=4 (local.get $logger) (local.get $cl))
    ;; error
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (local.get $prefix))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (i32.store offset=8 (local.get $logger) (local.get $cl))
    (local.get $logger))|}
        info_prefix_off warn_prefix_off error_prefix_off
        info_idx warn_idx error_idx
    end
  in
  let metrics_runtime_section =
    if not !metrics_used then "" else begin
      let inc_idx   = register_in_table "__mere_metrics_inc_fn" in
      let rec_outer = register_in_table "__mere_metrics_record_outer_fn" in
      let rec_inner = register_in_table "__mere_metrics_record_inner_fn" in
      let inc_prefix_off = fresh_str_offset "[METRIC] inc " in
      let rec_prefix_off = fresh_str_offset "[METRIC] " in
      let eq_off         = fresh_str_offset "=" in
      Printf.sprintf {|
  (func $__mere_metrics_inc_fn (param $env i32) (param $name i32) (result i32)
    (local $tmp i32)
    (local.set $tmp (call $__lang_str_concat (i32.const %d) (local.get $name)))
    (call $puts (local.get $tmp))
    (i32.const 0))
  (func $__mere_metrics_record_inner_fn (param $env i32) (param $n i32) (result i32)
    (local $tmp i32) (local $ns i32)
    (local.set $ns (call $show_int (local.get $n)))
    (local.set $tmp (call $__lang_str_concat (i32.const %d) (local.get $env)))
    (local.set $tmp (call $__lang_str_concat (local.get $tmp) (i32.const %d)))
    (local.set $tmp (call $__lang_str_concat (local.get $tmp) (local.get $ns)))
    (call $puts (local.get $tmp))
    (i32.const 0))
  (func $__mere_metrics_record_outer_fn (param $env i32) (param $name i32) (result i32)
    (local $cl i32)
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (local.get $name))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (local.get $cl))
  (func $__mere_mk_metrics (result i32)
    (local $m i32) (local $cl i32)
    ;; Metrics record: 2 ptrs = 8 bytes
    (local.set $m (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $m) (i32.const 8)))
    ;; inc closure
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (i32.const 0))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (i32.store offset=0 (local.get $m) (local.get $cl))
    ;; record outer closure
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (i32.const 0))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (i32.store offset=4 (local.get $m) (local.get $cl))
    (local.get $m))|}
        inc_prefix_off rec_prefix_off eq_off rec_inner inc_idx rec_outer
    end
  in
  (* Phase 30.2c: declare top-level non-fn lets as Wasm globals (mut i32).
     All Mere values are i32 in Wasm (literal int or ptr into linear memory),
     so a single uniform i32 global per let works. *)
  let top_globals_section =
    if top_globals_list = [] then ""
    else
      String.concat "\n"
        (List.map (fun (name, _) ->
          Printf.sprintf "  (global $%s (mut i32) (i32.const 0))" name)
          top_globals_list) ^ "\n"
  in
  let eta_adapters =
    Hashtbl.fold (fun slug (builtin, _ret_ty, _idx) acc ->
      emit_eta_adapter_wasm slug builtin :: acc)
      eta_adapters_wasm []
  in
  let fn_section =
    let all = fn_defs @ lifted_defs @ top_adapters @ anon_adapters @ eta_adapters @ show_fn_defs @ to_json_fn_defs @ of_json_fn_defs @ eq_fn_defs @ inner_lift_adapter_strs in
    let all =
      if logger_runtime_section <> "" then all @ [logger_runtime_section]
      else all
    in
    let all =
      if metrics_runtime_section <> "" then all @ [metrics_runtime_section]
      else all
    in
    if all = [] then "" else String.concat "\n" all ^ "\n"
  in
  let data_section =
    if !str_data_decls = [] then ""
    else String.concat "\n" (List.rev !str_data_decls) ^ "\n"
  in
  let table_section =
    if !table_entries <> [] then begin
      let n = List.length !table_entries in
      let elem_names =
        String.concat " " (List.map (fun s -> "$" ^ s) !table_entries)
      in
      (* Phase 48.2 (C2 Stage 2): export the table as
         `__indirect_function_table` so JS host glue can pull a Mere
         closure out of the table and call it back. The export name
         matches the wasm-bindgen / LLVM convention. *)
      Printf.sprintf
        "  (table %d funcref)\n\
        \  (export \"__indirect_function_table\" (table 0))\n\
        \  (elem (i32.const 0) %s)\n"
        n elem_names
    end
    else if !vec_higher_order_used then
      (* No closure adapters in the table but the higher-order Vec
         helpers reference (type $cl) + call_indirect, which require a
         table. Declare a zero-element one. *)
      "  (table 0 funcref)\n\
      \  (export \"__indirect_function_table\" (table 0))\n"
    else ""
  in
  (* Phase 26.1: reserve 512 bytes for __lang_char_table (256 * 2-byte cells).
     Always reserved (low overhead) so the char_at helper can lazy-init it
     on first call without needing per-module conditional layout. *)
  let char_table_offset = !str_offset_counter in
  let bump_init = !str_offset_counter + 512 in
  (* Phase 26.5: list_str runtime + file I/O host imports — conditional. *)
  let list_str_runtime_section =
    if !str_split_used || !str_join_used || !str_count_used
    then list_str_runtime_wasm else ""
  in
  let file_io_imports =
    if !file_io_used then
      "  (import \"env\" \"read_file\" (func $__lang_read_file (param i32) (result i32)))\n\
      \  (import \"env\" \"write_file\" (func $__lang_write_file (param i32) (param i32) (result i32)))\n"
    else ""
  in
  (* Phase 34.3: float runtime imports (str_of_float / float_of_str).
     Conditional emit would require a check, so always import (harmless
     even when unused). *)
  let float_io_imports =
    "  (import \"env\" \"__lang_str_of_float\" (func $__lang_str_of_float (param f64) (result i32)))\n\
    \  (import \"env\" \"__lang_float_of_str\" (func $__lang_float_of_str (param i32) (result f64)))\n"
  in
  (* Phase 34.4: libm host imports (sin / cos / tan / pow / atan2). sqrt
     uses the Wasm intrinsic, so no host import is needed. *)
  let libm_imports =
    "  (import \"env\" \"__lang_sin\" (func $__lang_sin (param f64) (result f64)))\n\
    \  (import \"env\" \"__lang_cos\" (func $__lang_cos (param f64) (result f64)))\n\
    \  (import \"env\" \"__lang_tan\" (func $__lang_tan (param f64) (result f64)))\n\
    \  (import \"env\" \"__lang_f_pow\" (func $__lang_f_pow (param f64) (param f64) (result f64)))\n\
    \  (import \"env\" \"__lang_atan2\" (func $__lang_atan2 (param f64) (param f64) (result f64)))\n"
  in
  let file_io_imports = file_io_imports ^ float_io_imports ^ libm_imports in
  (* Phase 32.4 (C1 FFI): declare extern fns as env host imports.
     Represent str / bool / int / unit all as i32. Unit arguments produce
     no param; unit return produces no result. *)
  let extern_imports =
    Hashtbl.fold (fun name ty acc ->
      let rec flatten t =
        match Ast.walk t with
        | Ast.TyArrow (p, r) ->
          let args, ret = flatten r in
          Ast.walk p :: args, ret
        | _ -> [], Ast.walk t
      in
      let args, ret = flatten ty in
      let params =
        args
        |> List.filter (fun t -> t <> Ast.TyUnit)
        |> List.map (fun _ -> " (param i32)")
        |> String.concat ""
      in
      let result =
        match ret with
        | Ast.TyUnit -> ""
        | _ -> " (result i32)"
      in
      Printf.sprintf "  (import \"env\" \"%s\" (func $%s%s%s))\n"
        name name params result
      :: acc)
      extern_fn_decls_wasm []
  in
  let extern_imports = String.concat "" extern_imports in
  let file_io_imports = file_io_imports ^ extern_imports in
  (* Q-012: threading imports + memory mode. When the program spawns, the
     module imports one host-created shared memory (so every worker instance
     shares it) and pulls the spawn/join host functions; otherwise it keeps
     its own exported unshared memory. *)
  let file_io_imports =
    if !uses_threads then
      file_io_imports
      ^ "  (import \"env\" \"mere_spawn\" (func $mere_spawn (param i32) (result i32)))\n\
        \  (import \"env\" \"mere_join\" (func $mere_join (param i32) (result i32)))\n\
        \  (import \"env\" \"mere_channel_new\" (func $mere_channel_new (param i32) (result i32)))\n\
        \  (import \"env\" \"mere_channel_send\" (func $mere_channel_send (param i32) (param i32) (result i32)))\n\
        \  (import \"env\" \"mere_channel_recv\" (func $mere_channel_recv (param i32) (result i32)))\n"
    else file_io_imports
  in
  let memory_section =
    if !uses_threads then
      "  (import \"env\" \"memory\" (memory 1024 65536 shared))\n\
      \  (export \"memory\" (memory 0))\n"
    else "  (memory (export \"memory\") 1024)\n"
  in
  let vec_runtime_section = if !vec_used then vec_runtime else "" in
  let vec_higher_order_section =
    if !vec_higher_order_used then vec_higher_order_runtime else ""
  in
  let strbuf_section = if !strbuf_used then strbuf_runtime_wasm else "" in
  (* Phase 15.14: emit per-K key-eq helper + per-K map runtime for each K
     in map_key_types. *)
  let map_key_eq_section =
    String.concat "\n"
      (Hashtbl.fold (fun _tag k_ty acc ->
         emit_map_key_eq_wasm k_ty :: acc) map_key_types [])
  in
  let map_runtime_section =
    String.concat "\n"
      (Hashtbl.fold (fun _tag k_ty acc ->
         emit_map_runtime_wasm k_ty :: acc) map_key_types [])
  in
  (* Legacy flags (for tests that still toggle them) — no-op effect since
     the table is the authoritative source. *)
  let _ = !map_int_used and _ = !map_str_used in
  ignore map_int_runtime_wasm; ignore map_str_runtime_wasm;
  (* Phase 15.12: vec_to_list / list_len helpers. Tag values are taken from
     variant_tags at codegen time and baked-in. *)
  let cons_tag_v =
    try Hashtbl.find variant_tags "Cons" with Not_found -> 1
  in
  let nil_tag_v =
    try Hashtbl.find variant_tags "Nil" with Not_found -> 0
  in
  let vec_to_list_section =
    if not !vec_to_list_used then "" else
    Printf.sprintf "
  (func $mere_vec_to_list (param $v i32) (result i32)
    (local $len i32) (local $i i32) (local $acc i32)
    (local $tup i32) (local $node i32)
    (local.set $len (i32.load offset=4 (local.get $v)))
    ;; allocate Nil node (8 bytes)
    (local.set $acc (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $acc) (i32.const 8)))
    (i32.store offset=0 (local.get $acc) (i32.const %d))  ;; nil_tag
    (i32.store offset=4 (local.get $acc) (i32.const 0))
    (local.set $i (i32.sub (local.get $len) (i32.const 1)))
    (block $end
      (loop $lp
        (br_if $end (i32.lt_s (local.get $i) (i32.const 0)))
        ;; allocate tuple (8 bytes): { f0=vec[i], f1=acc }
        (local.set $tup (global.get $__lang_bump))
        (global.set $__lang_bump (i32.add (local.get $tup) (i32.const 8)))
        (i32.store offset=0 (local.get $tup)
          (call $mere_vec_get (local.get $v) (local.get $i)))
        (i32.store offset=4 (local.get $tup) (local.get $acc))
        ;; allocate Cons node (8 bytes): { tag=cons_tag, payload=tup }
        (local.set $node (global.get $__lang_bump))
        (global.set $__lang_bump (i32.add (local.get $node) (i32.const 8)))
        (i32.store offset=0 (local.get $node) (i32.const %d))  ;; cons_tag
        (i32.store offset=4 (local.get $node) (local.get $tup))
        (local.set $acc (local.get $node))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $acc))" nil_tag_v cons_tag_v
  in
  let list_len_section =
    if not !list_len_used then "" else
    Printf.sprintf "
  (func $mere_list_len (param $l i32) (result i32)
    (local $n i32) (local $tag i32) (local $payload i32)
    (local.set $n (i32.const 0))
    (block $end
      (loop $lp
        (local.set $tag (i32.load offset=0 (local.get $l)))
        (br_if $end (i32.ne (local.get $tag) (i32.const %d)))  ;; not Cons
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (local.set $payload (i32.load offset=4 (local.get $l)))
        ;; tuple.f1 (next list) at offset 4 of payload
        (local.set $l (i32.load offset=4 (local.get $payload)))
        (br $lp)))
    (local.get $n))" cons_tag_v
  in
  Printf.sprintf
    "(module\n\
     \  (type $cl (func (param i32) (param i32) (result i32)))\n\
     \  (import \"env\" \"puts\" (func $puts (param i32)))\n\
     %s\
     %s\
     %s\
     \  (global $__lang_bump (export \"__lang_bump\") (mut i32) (i32.const %d))\n\
     \  (global $__lang_char_table i32 (i32.const %d))\n\
     \  (global $__lang_char_table_initialized (mut i32) (i32.const 0))\n\
     \  (global $__lang_fail_flag (mut i32) (i32.const 0))\n\
     \  (global $__lang_fail_active (mut i32) (i32.const 0))\n\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     \  (func $main (export \"main\") (result i32)\n%s%s)\n\
     )\n"
    file_io_imports
    memory_section
    table_section bump_init char_table_offset
    top_globals_section
    data_section runtime_helpers
    list_str_runtime_section
    vec_runtime_section
    vec_higher_order_section strbuf_section map_key_eq_section map_runtime_section
    vec_to_list_section list_len_section
    fn_section local_decl indented_body
