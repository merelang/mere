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

(* Walk a Lang type to its LLVM type. MVP: int + bool only. *)
let llvm_ty_of (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt -> "i32"
  | Ast.TyBool -> "i1"
  | _ -> "i32"  (* best-effort fallback; typer should reject str/etc. before this *)

(* Emit `expr` as a sequence of SSA instructions; return the register (or
   literal) holding the result. Caller is expected to know the expected
   LLVM type from the AST's `.ty` annotation. *)
let rec emit_expr (env : env) (e : Ast.expr) : string =
  match e.Ast.node with
  | Ast.Int_lit n -> string_of_int n
  | Ast.Bool_lit b -> if b then "1" else "0"
  | Ast.Var name -> lookup env name e.Ast.loc
  | Ast.Annot (inner, _) -> emit_expr env inner
  | Ast.Neg inner ->
    let v = emit_expr env inner in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = sub i32 0, %s" r v);
    r
  | Ast.Bin (Ast.Concat, _, _) ->
    unsupported e.Ast.loc "string concat (++) — Phase 5 later slice"
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
       emit_expr ((name, rv) :: env) body
     | _ ->
       unsupported pat.Ast.ploc "non-P_var let pattern — Phase 5 later slice")
  | Ast.Str_lit _ | Ast.Float_lit _ | Ast.Unit_lit
  | Ast.Let_rec _ | Ast.With _ | Ast.Fun _ | Ast.App _
  | Ast.Constr _ | Ast.Match _ | Ast.Tuple _
  | Ast.Region_block _ | Ast.Ref _
  | Ast.Record_lit _ | Ast.Field_get _ | Ast.Record_update _ ->
    unsupported e.Ast.loc "node kind not yet in Phase 5 MVP"

(* Convert the program's main result type to (LLVM type, printf format).
   `unit` skips printing entirely. *)
let main_format_of (t : Ast.ty) : (string * string) option =
  match Ast.walk t with
  | Ast.TyInt -> Some ("i32", "%d")
  | Ast.TyBool -> Some ("i32", "%d")  (* zext from i1 *)
  | Ast.TyUnit -> None
  | _ -> Some ("i32", "%d")

let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
  let body_expr = Ast.desugar_program prog in
  emit_instr "entry:";
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
  emit_instr "  ret i32 0";
  let body = String.concat "\n" (List.rev !instrs) in
  let format_globals =
    (* The byte length includes the null terminator and counts LLVM
       escapes (`\0A`) as 1 byte each. We hardcode the few formats we
       use rather than maintain a generic length calculator. *)
    match main_format_of main_ty with
    | None -> []
    | Some _ ->
      [ "@.fmt_d = private constant [4 x i8] c\"%d\\0A\\00\"" ]
  in
  let parts =
    [ "; LLVM IR generated by lang-ml (Phase 5.1 MVP)";
      "target triple = \"" ^ "x86_64-apple-macosx" ^ "\"";  (* clang will retarget if needed *)
      "" ]
    @ format_globals
    @ [ "";
        "declare i32 @printf(ptr, ...)";
        "";
        "define i32 @main() {";
        body;
        "}";
        "" ]
  in
  String.concat "\n" parts
