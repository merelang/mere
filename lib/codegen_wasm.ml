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
   a fresh slot per Let binding. *)
let local_counter = ref 0
let locals : (string * int) list ref = ref []
let fresh_local () =
  let n = !local_counter in
  incr local_counter;
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

(* Phase 15.10/15.14: Map[R, K, V] — Wasm では値が全部 i32 なので per-V
   は不要、per-K のみ。K の型を `map_key_types` に登録、emit_program で
   per-K helper を 1 セットずつ emit。`map_int_used` / `map_str_used` は
   後方互換 (新規 code はテーブル経由)。 *)
let map_int_used = ref false
let map_str_used = ref false
let map_key_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.12: vec_to_list と len-on-list で同じ list 構造を扱うため、
   どちらか使われたら runtime を emit。tag 値は codegen 時に確定。 *)
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

(* Anonymous-Fun closure emission state. *)
type closure_emission = {
  ce_adapter_name : string;
  ce_param        : string;
  ce_body         : Ast.expr;
  ce_captures     : (string * int) list;  (* (name, source local slot) *)
  ce_table_idx    : int;
}
let pending_closures : closure_emission list ref = ref []
let anon_counter = ref 0
let fresh_anon_name () =
  let n = !anon_counter in
  incr anon_counter;
  Printf.sprintf "anon_%d_fn" n

(* Each variant constructor → integer tag. Populated up front from
   Exhaustive.type_variants. *)
let variant_tags : (string, int) Hashtbl.t = Hashtbl.create 16

(* Types whose `show_<ty_tag>` function we need to emit. *)
let show_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

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

(* Single payload type for a variant (None if all-nullary). Mirrors the
   LLVM backend's `variant_payload_ty_of`: all payload-bearing
   constructors must share one payload type or we raise. *)
let variant_payload_ty (vname : string) : Ast.ty option =
  match Hashtbl.find_opt Exhaustive.type_variants vname with
  | None ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unknown variant type `%s` at Wasm codegen" vname))
  | Some vs ->
    let payloads = List.filter_map (fun (_, p) -> p) vs in
    (match payloads with
     | [] -> None
     | first :: rest ->
       (* Compare by string representation as a cheap shape test. *)
       let same = List.for_all (fun p -> p = first) rest in
       if same then Some first
       else
         raise (Codegen_error (Loc.dummy,
           Printf.sprintf
             "variant `%s` has constructors with different payload types — \
              Phase 6 MVP needs all payloads to be the same type" vname)))

(* Stable name fragment per type for show fn naming. Mirrors C/LLVM
   codegen's ty_tag so e.g. `int list` lowers to `show_list_int`. *)
let rec ty_tag (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyCon ("OwnedVec", _)
  | Ast.TyCon ("StrBuf", _) | Ast.TyCon ("Map", _) ->
    raise (Codegen_error (Loc.dummy,
      "unsupported in Wasm codegen subset: OwnedVec / StrBuf / Map (interpreter-only)"))
  | Ast.TyInt -> "int"
  | Ast.TyBool -> "bool"
  | Ast.TyStr -> "str"
  | Ast.TyUnit -> "unit"
  | Ast.TyTuple ts -> "tuple_" ^ String.concat "_" (List.map ty_tag ts)
  | Ast.TyArrow (p, r) -> "closure_" ^ ty_tag p ^ "_" ^ ty_tag r
  | Ast.TyCon (name, []) -> name
  | Ast.TyCon (name, args) ->
    name ^ "_" ^ String.concat "_" (List.map ty_tag args)
  | Ast.TyRef (_, r, Ast.TyUnit) ->
    (* Region marker — region 名そのものを tag に (C / LLVM と同じ). *)
    r
  | _ ->
    raise (Codegen_error (Loc.dummy,
      "unsupported Wasm codegen type for ty_tag"))

let rec ty_is_concrete (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, _, inner) -> ty_is_concrete inner
  | Ast.TyVar _ | Ast.TyParam _ | Ast.TyFloat -> false

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
let rec add_show_type (t : Ast.ty) : unit =
  let t = Ast.walk t in
  if not (ty_is_concrete t) then ()
  else
    let tag = ty_tag t in
    if Hashtbl.mem show_types tag then ()
    else begin
      Hashtbl.add show_types tag t;
      match t with
      | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> ()
      | Ast.TyTuple ts -> List.iter add_show_type ts
      | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
        let info = Hashtbl.find Typer.records n in
        let mapping =
          if info.Typer.r_params = [] then []
          else List.combine info.Typer.r_params args
        in
        List.iter (fun (_, ft) ->
          add_show_type (subst_params mapping ft)) info.Typer.r_fields
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
             | Some t -> add_show_type (subst_params mapping t)
             | None -> ()) vs)
      | _ -> ()
    end

let collect_show_types (root : Ast.expr) (fns : fn_decl list) : unit =
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
       (match arg.Ast.ty with
        | Some t -> add_show_type t
        | None -> ())
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
  let rec go (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, rest)
      when (match pat.Ast.pnode with Ast.P_var _ -> true | _ -> false) ->
      (match value.Ast.node with
       | Ast.Fun (param, _, fn_body) ->
         let name =
           match pat.Ast.pnode with Ast.P_var n -> n | _ -> assert false in
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
               — Wasm codegen needs a monomorphic instantiation" s.sname))
    in
    match arrow with
    | Ast.TyArrow (p, r) ->
      { name = s.sname; param = s.sparam; body = s.sbody;
        param_ty = Ast.walk p; return_ty = Ast.walk r }
    | _ ->
      raise (Codegen_error (s.sfun.Ast.loc,
        Printf.sprintf "function `%s` has non-arrow inferred type" s.sname))
  ) skels

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

(* Phase 15.10: Wasm では値が全部 i32 なので per-V 不要、K (int / str)
   のみで helper を分岐。 *)
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

(* Emit `expr` so its result lands on top of the Wasm operand stack. *)
let rec emit_expr (e : Ast.expr) : unit =
  match e.Ast.node with
  | Ast.Int_lit n ->
    emit_instr (Printf.sprintf "i32.const %d" n)
  | Ast.Bool_lit b ->
    emit_instr (Printf.sprintf "i32.const %d" (if b then 1 else 0))
  | Ast.Unit_lit ->
    emit_instr "i32.const 0"
  | Ast.Str_lit s ->
    let off = fresh_str_offset s in
    emit_instr (Printf.sprintf "i32.const %d" off)
  | Ast.Var name ->
    (* Phase 15.4: vec_new / vec_push / vec_get / vec_len は App handler
       で special-case 処理。first-class value 用法のみここで reject。 *)
    if name = "vec_new" || name = "vec_push"
       || name = "vec_get" || name = "vec_len"
       || name = "vec_set" || name = "vec_iter" || name = "vec_fold"
       || name = "vec_reverse" || name = "vec_concat"
       || name = "vec_map" || name = "vec_filter"
       || name = "vec_to_owned" || name = "owned_vec_to_vec"
       || name = "owned_vec_new" || name = "owned_vec_push"
       || name = "owned_vec_get" || name = "owned_vec_len"
       || name = "strbuf_new" || name = "strbuf_push"
       || name = "strbuf_to_str" || name = "strbuf_len"
       || name = "map_new" || name = "map_set" || name = "map_get" || name = "map_iter"
       || name = "map_has" || name = "map_len" then
      raise (Codegen_error (e.Ast.loc,
        "unsupported in Wasm codegen subset: " ^ name
        ^ " as a value (Phase 15.4〜15.10: vec_* / owned_vec_* / strbuf_* / map_* は直接 application のみ対応)"));
    if name = "len" || name = "vec_to_list" then
      raise (Codegen_error (e.Ast.loc,
        "unsupported in Wasm codegen subset: " ^ name
        ^ " as a value (Phase 15.11/15.12: len / vec_to_list は直接 application のみ対応)"));
    (match List.assoc_opt name !locals with
     | Some slot -> emit_instr (Printf.sprintf "local.get %d" slot)
     | None when Hashtbl.mem fn_closure_table_idx name ->
       (* Top-level fn as a value: materialize a closure
          `{ env = 0, fn_idx = table_idx }`. *)
       let idx = Hashtbl.find fn_closure_table_idx name in
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
     | None -> unsupported e.Ast.loc ("unbound variable: " ^ name))
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
    emit_expr a;
    emit_expr b;
    emit_instr (wasm_cmp op)
  | Ast.Logic (op, a, b) ->
    emit_expr a;
    emit_expr b;
    emit_instr (match op with Ast.And -> "i32.and" | Ast.Or -> "i32.or")
  | Ast.If (cond, t, f) ->
    emit_expr cond;
    emit_instr "if (result i32)";
    emit_expr t;
    emit_instr "else";
    emit_expr f;
    emit_instr "end"
  | Ast.Let (pat, value, body) ->
    (match pat.Ast.pnode with
     | Ast.P_var name ->
       let slot = fresh_local () in
       emit_expr value;
       emit_instr (Printf.sprintf "local.set %d" slot);
       let prev = !locals in
       locals := (name, slot) :: prev;
       emit_expr body;
       locals := prev
     | _ ->
       unsupported pat.Ast.ploc "non-P_var let pattern — Phase 6 later slice")
  | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "show: missing arg type"
    in
    let tag = ty_tag arg_ty in
    emit_expr arg;
    emit_instr (Printf.sprintf "call $show_%s" tag)
  | Ast.App ({ node = Ast.Var "print"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $puts";
    emit_instr "i32.const 0"  (* unit / int 0 *)
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
  | Ast.App ({ node = Ast.Var "vec_new"; _ }, _arg) ->
    (* Phase 15.4: vec_new () — region は無視 (Wasm の bump はグローバル
       で一本)、要素は全て 4 byte i32 なので単一 runtime で OK。
       arg は unit literal なので積まない。 *)
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
    (* Phase 15.7: Wasm では OwnedVec も Vec も同じ bump runtime を使うので
       owned_vec_new = $mere_vec_new (alias)。 *)
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
    (* Phase 15.7: Wasm では Vec と OwnedVec の runtime 表現は同じなので、
       $mere_vec_clone で deep copy するだけ。 *)
    vec_used := true;
    emit_expr vec_e;
    emit_instr "call $mere_vec_clone"
  | Ast.App ({ node = Ast.Var "owned_vec_to_vec"; _ }, owned_e) ->
    vec_used := true;
    emit_expr owned_e;
    emit_instr "call $mere_vec_clone"
  | Ast.App ({ node = Ast.Var "len"; _ }, arg) ->
    (* Phase 15.11: len ad-hoc dispatch — arg.ty に基づいて対応する
       _len ヘルパに routing。Wasm では値は全て i32。 *)
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
       (* Static arity。arg は side-effectful の可能性があるので drop。 *)
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
    (* Phase 15.10: map_new () — Wasm では region 無視、key 型のみ pick. *)
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
    (* Phase 15.9: strbuf_new () — region は無視 (Wasm の bump はグローバル
       1 本)。 *)
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
    when Hashtbl.mem toplevel_fn_names name ->
    emit_expr arg;
    emit_instr (Printf.sprintf "call $%s" name)
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
    emit_instr "call_indirect (type $cl)"
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
    let inner_ty =
      match inner.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "field access: missing inner type"
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
  | Ast.Constr (cname, arg_opt) ->
    let info =
      match Hashtbl.find_opt Typer.constructors cname with
      | Some i -> i
      | None -> unsupported e.Ast.loc ("unknown constructor: " ^ cname)
    in
    let type_name = info.Typer.type_name in
    let tag =
      match Hashtbl.find_opt variant_tags cname with
      | Some t -> t
      | None -> unsupported e.Ast.loc ("constructor without tag: " ^ cname)
    in
    let payload_ty = variant_payload_ty type_name in
    let n_bytes = match payload_ty with None -> 4 | Some _ -> 8 in
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
    (match arg_opt, payload_ty with
     | None, _ -> ()
     | Some arg, Some _ ->
       emit_instr (Printf.sprintf "local.get %d" base_slot);
       emit_expr arg;
       emit_instr "i32.store offset=4"
     | Some _, None ->
       unsupported e.Ast.loc
         (Printf.sprintf
            "constructor `%s` has payload but variant lowered as nullary-only"
            cname));
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
      | Ast.P_constr (cname, sub) ->
        let info =
          match Hashtbl.find_opt Typer.constructors cname with
          | Some i -> i
          | None -> unsupported pat.Ast.ploc ("unknown ctor: " ^ cname)
        in
        let type_name = info.Typer.type_name in
        let payload_ty = variant_payload_ty type_name in
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
        (match sub, payload_ty with
         | None, _ -> (tag_cond, [])
         | Some sub_pat, Some pty ->
           let pl_slot = fresh_local () in
           emit_instr (Printf.sprintf "local.get %d" v_slot);
           emit_instr "i32.load offset=4";
           emit_instr (Printf.sprintf "local.set %d" pl_slot);
           let (sub_cond, sub_bs) = compile_pat sub_pat pl_slot pty in
           (combine_and tag_cond sub_cond, sub_bs)
         | Some _, None ->
           unsupported pat.Ast.ploc
             "pattern has payload but variant has no payload type")
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
        emit_expr body;
        locals := prev;
        emit_instr "else";
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
        ce_table_idx = table_idx }
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
  | _ ->
    unsupported e.Ast.loc "node kind not yet in Phase 6 MVP"

(* Emit one top-level fn definition. Params are positional locals
   starting at slot 0; let-binding locals are mint-ed afterwards.
   Body's stack-top value is the function's return. *)
let emit_fn_def (f : fn_decl) : string =
  let saved_instrs = !instrs in
  let saved_local_counter = !local_counter in
  let saved_locals = !locals in
  instrs := [];
  (* Param sits at slot 0. let-bindings start from slot 1. *)
  local_counter := 1;
  locals := [(f.param, 0)];
  emit_expr f.body;
  let body_instrs = List.rev !instrs in
  let extra_locals = !local_counter - 1 in
  instrs := saved_instrs;
  local_counter := saved_local_counter;
  locals := saved_locals;
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

(* Env-ignoring adapter so top-level fn `f` can be used as a closure
   value: `(env, x) -> result` that just calls `$f(x)`. *)
let emit_top_adapter (f : fn_decl) : string =
  Printf.sprintf
    "  (func $%s_closure (param i32) (param i32) (result i32)\n\
     \    local.get 1\n\
     \    call $%s)" f.name f.name

(* Adapter for an anonymous Fun. Slot 0 = env ptr, slot 1 = param;
   capture locals start at slot 2. Loads each capture from env at the
   appropriate offset, then evaluates the original Fun body. *)
let emit_anon_adapter (ce : closure_emission) : string =
  let saved_instrs = !instrs in
  let saved_local_counter = !local_counter in
  let saved_locals = !locals in
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
  emit_expr ce.ce_body;
  let body_instrs = List.rev !instrs in
  let extra_locals = !local_counter - 2 in
  instrs := saved_instrs;
  local_counter := saved_local_counter;
  locals := saved_locals;
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
    Printf.sprintf
      "  (func $show_str (param $s i32) (result i32)\n\
      \    (call $__lang_str_concat\n\
      \      (call $__lang_str_concat (i32.const %d) (local.get $s))\n\
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
    (i32.const -1))|}

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
  ;; Phase 15.7: OwnedVec の helpers — Wasm では値が全部 i32 で
  ;; bump アロケータも共有なので、Vec と OwnedVec のランタイム表現は
  ;; 同じ。owned_vec_* は $mere_vec_* に thin wrapper として alias。
  ;; deep copy (vec_to_owned / owned_vec_to_vec) は $mere_vec_clone を使う。
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
   Wasm の bump アロケータ ($__lang_bump) を使う。Layout:
   { data_ptr:i32, len:i32, cap:i32, _pad:i32 } = 16 byte (Vec と同じ). *)
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

(* Phase 15.10: Map[R, K, V] runtime — per-K only (V は i32 共通)。
   Layout: { keys:i32, values:i32, len:i32, cap:i32 } = 16 byte。
   線形スキャン、cap 到達時は新配列を bump で確保 (arena semantics). *)

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
    (i32.const 0))"
    k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag

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
    (i32.load offset=8 (local.get $m)))|}

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
    (i32.load offset=8 (local.get $m)))|}

let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  ignore main_ty;
  reset ();
  Hashtbl.reset toplevel_fn_names;
  Hashtbl.reset variant_tags;
  Hashtbl.reset fn_closure_table_idx;
  Hashtbl.reset show_types;
  Hashtbl.reset show_str_offsets;
  table_entries := [];
  pending_closures := [];
  anon_counter := 0;
  str_data_decls := [];
  str_offset_counter := str_initial_offset;
  vec_used := false;
  vec_higher_order_used := false;
  strbuf_used := false;
  logger_used := false;
  metrics_used := false;
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
  let skels, body_expr = lift_fn_skels main_expr in
  List.iter (fun s -> Hashtbl.replace toplevel_fn_names s.sname ()) skels;
  let fns = resolve_fn_types skels main_expr in
  collect_show_types main_expr fns;
  let fn_defs = List.map emit_fn_def fns in
  (* Register top-level closure adapters in the table and remember
     their indices so `Var name` (value position) can find them. *)
  let top_adapters =
    List.map (fun f ->
      let idx = register_in_table (f.name ^ "_closure") in
      Hashtbl.replace fn_closure_table_idx f.name idx;
      emit_top_adapter f
    ) fns
  in
  (* Emit one specialized `show_<tag>` function per registered type. *)
  let show_fn_defs =
    Hashtbl.fold (fun tag t acc -> emit_show_fn tag t :: acc) show_types []
  in
  (* Reset counters for the main body. *)
  reset ();
  emit_expr body_expr;
  let body_instrs = List.rev !instrs in
  let local_count = !local_counter in
  let local_decl =
    if local_count = 0 then "" else
      Printf.sprintf "    (local%s)\n"
        (String.concat "" (List.init local_count (fun _ -> " i32")))
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
  let fn_section =
    let all = fn_defs @ top_adapters @ anon_adapters @ show_fn_defs in
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
      Printf.sprintf
        "  (table %d funcref)\n\
        \  (elem (i32.const 0) %s)\n"
        n elem_names
    end
    else if !vec_higher_order_used then
      (* No closure adapters in the table but the higher-order Vec
         helpers reference (type $cl) + call_indirect, which require a
         table. Declare a zero-element one. *)
      "  (table 0 funcref)\n"
    else ""
  in
  let bump_init = !str_offset_counter in
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
  (* Phase 15.12: vec_to_list / list_len helpers. tag 値は variant_tags
     から codegen 時に取り出して baked-in. *)
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
     \  (memory (export \"memory\") 1)\n\
     %s\
     \  (global $__lang_bump (mut i32) (i32.const %d))\n\
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
    table_section bump_init data_section runtime_helpers vec_runtime_section
    vec_higher_order_section strbuf_section map_key_eq_section map_runtime_section
    vec_to_list_section list_len_section
    fn_section local_decl indented_body
