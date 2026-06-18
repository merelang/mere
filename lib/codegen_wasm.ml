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
  | _ ->
    unsupported e.Ast.loc "node kind not yet in Phase 6 MVP"

let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  ignore main_ty;
  reset ();
  let body_expr = Ast.desugar_program prog in
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
  Printf.sprintf
    "(module\n  (func $main (export \"main\") (result i32)\n%s%s)\n)\n"
    local_decl indented_body
