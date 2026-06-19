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
    | Ast.Ref (_, a) -> go a bound
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

let rec ty_is_concrete (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, inner) -> ty_is_concrete inner
  | Ast.TyVar _ | Ast.TyParam _ | Ast.TyFloat -> false

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
    | Ast.Ref (_, a) -> go a
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

(* Emit `expr` so its result lands on top of the Wasm operand stack. *)
let rec emit_expr (e : Ast.expr) : unit =
  match e.Ast.node with
  | Ast.Int_lit n ->
    emit_instr (Printf.sprintf "i32.const %d" n)
  | Ast.Bool_lit b ->
    emit_instr (Printf.sprintf "i32.const %d" (if b then 1 else 0))
  | Ast.Str_lit s ->
    let off = fresh_str_offset s in
    emit_instr (Printf.sprintf "i32.const %d" off)
  | Ast.Var name ->
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
  | Ast.App ({ node = Ast.Var "print"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $puts";
    emit_instr "i32.const 0"  (* unit / int 0 *)
  | Ast.App ({ node = Ast.Var "str_len"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_strlen"
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
  | Ast.Record_lit (name, fields) ->
    let info =
      match Hashtbl.find_opt Typer.records name with
      | Some i -> i
      | None -> unsupported e.Ast.loc ("unknown record type: " ^ name)
    in
    if info.Typer.r_params <> [] then
      unsupported e.Ast.loc "polymorphic record — Phase 6 later slice";
    if Hashtbl.mem Typer.views name then
      unsupported e.Ast.loc "view literal — Phase 6 later slice";
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
    let rname =
      match inner_ty with
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n -> n
      | _ -> unsupported e.Ast.loc "field access on non-record"
    in
    let info = Hashtbl.find Typer.records rname in
    let rec find_idx i = function
      | [] -> unsupported e.Ast.loc
                (Printf.sprintf "record `%s` has no field `%s`" rname fname)
      | (n, _) :: _ when n = fname -> i
      | _ :: rest -> find_idx (i + 1) rest
    in
    let idx = find_idx 0 info.Typer.r_fields in
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
    if info.Typer.params <> [] then
      unsupported e.Ast.loc "polymorphic variant — Phase 6 later slice";
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
    let type_name =
      match scrut_ty with
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.types n -> n
      | _ -> unsupported e.Ast.loc
               "match: scrutinee is not a user-declared variant (Phase 6 MVP)"
    in
    let payload_ty = variant_payload_ty type_name in
    let scrut_slot = fresh_local () in
    let tag_slot = fresh_local () in
    let payload_slot = match payload_ty with
      | None -> -1
      | Some _ -> fresh_local ()
    in
    emit_expr scrut;
    emit_instr (Printf.sprintf "local.set %d" scrut_slot);
    emit_instr (Printf.sprintf "local.get %d" scrut_slot);
    emit_instr "i32.load offset=0";
    emit_instr (Printf.sprintf "local.set %d" tag_slot);
    (match payload_ty with
     | None -> ()
     | Some _ ->
       emit_instr (Printf.sprintf "local.get %d" scrut_slot);
       emit_instr "i32.load offset=4";
       emit_instr (Printf.sprintf "local.set %d" payload_slot));
    (* Emit nested if/else chain. Each arm pushes its result; final
       fallthrough is `unreachable` to mirror typer-promised exhaustiveness. *)
    let rec emit_arms = function
      | [] ->
        emit_instr "unreachable"
      | (pat, guard, body) :: rest ->
        if guard <> None then
          unsupported pat.Ast.ploc "match guard — Phase 6 later slice";
        let tag_value, bindings =
          match pat.Ast.pnode with
          | Ast.P_wild -> (None, [])
          | Ast.P_var n -> (None, [(n, scrut_slot)])
          | Ast.P_constr (cname, sub) ->
            let t =
              match Hashtbl.find_opt variant_tags cname with
              | Some t -> t
              | None -> unsupported pat.Ast.ploc ("unknown ctor: " ^ cname)
            in
            let bs =
              match sub with
              | None -> []
              | Some sp ->
                (match sp.Ast.pnode, payload_ty with
                 | Ast.P_wild, _ -> []
                 | Ast.P_var n, Some _ -> [(n, payload_slot)]
                 | _, None ->
                   unsupported sp.Ast.ploc
                     "ctor sub-pattern on nullary-only variant"
                 | _ ->
                   unsupported sp.Ast.ploc
                     "ctor sub-pattern kind not yet in Phase 6 MVP")
            in
            (Some t, bs)
          | _ ->
            unsupported pat.Ast.ploc "pattern kind not yet in Phase 6 MVP"
        in
        match tag_value with
        | None ->
          (* Wildcard or var: always matches. *)
          let prev_locals = !locals in
          locals := bindings @ prev_locals;
          emit_expr body;
          locals := prev_locals
        | Some t ->
          emit_instr (Printf.sprintf "local.get %d" tag_slot);
          emit_instr (Printf.sprintf "i32.const %d" t);
          emit_instr "i32.eq";
          emit_instr "if (result i32)";
          let prev_locals = !locals in
          locals := bindings @ prev_locals;
          emit_expr body;
          locals := prev_locals;
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
    (local.get $r))|}

let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  ignore main_ty;
  reset ();
  Hashtbl.reset toplevel_fn_names;
  Hashtbl.reset variant_tags;
  Hashtbl.reset fn_closure_table_idx;
  table_entries := [];
  pending_closures := [];
  anon_counter := 0;
  str_data_decls := [];
  str_offset_counter := str_initial_offset;
  (* Pre-register variant tags from Exhaustive's registry. *)
  Hashtbl.iter (fun _name vs ->
    List.iteri (fun i (cname, _) ->
      Hashtbl.replace variant_tags cname i) vs
  ) Exhaustive.type_variants;
  let main_expr = Ast.desugar_program prog in
  let skels, body_expr = lift_fn_skels main_expr in
  List.iter (fun s -> Hashtbl.replace toplevel_fn_names s.sname ()) skels;
  let fns = resolve_fn_types skels main_expr in
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
  let fn_section =
    let all = fn_defs @ top_adapters @ anon_adapters in
    if all = [] then "" else String.concat "\n" all ^ "\n"
  in
  let data_section =
    if !str_data_decls = [] then ""
    else String.concat "\n" (List.rev !str_data_decls) ^ "\n"
  in
  let table_section =
    if !table_entries = [] then ""
    else begin
      let n = List.length !table_entries in
      let elem_names =
        String.concat " " (List.map (fun s -> "$" ^ s) !table_entries)
      in
      Printf.sprintf
        "  (table %d funcref)\n\
        \  (elem (i32.const 0) %s)\n"
        n elem_names
    end
  in
  let bump_init = !str_offset_counter in
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
     \  (func $main (export \"main\") (result i32)\n%s%s)\n\
     )\n"
    table_section bump_init data_section runtime_helpers fn_section
    local_decl indented_body
