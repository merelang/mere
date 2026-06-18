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
  | Ast.Var name ->
    (match List.assoc_opt name !locals with
     | Some slot -> emit_instr (Printf.sprintf "local.get %d" slot)
     | None -> unsupported e.Ast.loc ("unbound variable: " ^ name))
  | Ast.Annot (inner, _) -> emit_expr inner
  | Ast.Neg inner ->
    emit_instr "i32.const 0";
    emit_expr inner;
    emit_instr "i32.sub"
  | Ast.Bin (Ast.Concat, _, _) ->
    unsupported e.Ast.loc "string concat (++) — Phase 6 later slice"
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
  | Ast.App ({ node = Ast.Var name; _ }, arg)
    when Hashtbl.mem toplevel_fn_names name ->
    emit_expr arg;
    emit_instr (Printf.sprintf "call $%s" name)
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

let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  ignore main_ty;
  reset ();
  Hashtbl.reset toplevel_fn_names;
  let main_expr = Ast.desugar_program prog in
  let skels, body_expr = lift_fn_skels main_expr in
  List.iter (fun s -> Hashtbl.replace toplevel_fn_names s.sname ()) skels;
  let fns = resolve_fn_types skels main_expr in
  let fn_defs = List.map emit_fn_def fns in
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
  let fn_section =
    if fn_defs = [] then "" else
      String.concat "\n" fn_defs ^ "\n"
  in
  Printf.sprintf
    "(module\n%s  (func $main (export \"main\") (result i32)\n%s%s)\n)\n"
    fn_section local_decl indented_body
