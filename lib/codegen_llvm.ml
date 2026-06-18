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
  | other ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unsupported LLVM codegen type element: %s" (Ast.pp_ty other)))

let tuple_struct_name (elems : Ast.ty list) : string =
  "tuple_" ^ String.concat "_" (List.map ty_tag elems)

(* Walk a Lang type to its LLVM type. Tuples / monomorphic records lower
   to named-struct references (`%tuple_int_int`, `%Point`); these are
   emitted as `type` definitions at the top of the module. *)
let llvm_ty_of (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt -> "i32"
  | Ast.TyBool -> "i1"
  | Ast.TyStr -> "ptr"
  | Ast.TyUnit -> "i32"  (* unit becomes int 0 *)
  | Ast.TyTuple ts -> "%" ^ tuple_struct_name ts
  | Ast.TyCon (name, []) when Hashtbl.mem Typer.records name -> "%" ^ name
  | _ -> "i32"  (* best-effort fallback; typer should reject before this *)

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
  | Ast.TyRef (_, inner) -> ty_is_concrete inner
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
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns;
  Hashtbl.fold (fun _ v acc -> v :: acc) seen []

let emit_tuple_typedef (elems : Ast.ty list) : string =
  let name = tuple_struct_name elems in
  let fields = String.concat ", " (List.map llvm_ty_of elems) in
  Printf.sprintf "%%%s = type { %s }" name fields

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
    | Ast.TyRef (_, inner) -> walk_ty inner
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
    | Ast.Ref (_, a) -> walk_expr a
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

(* Emit `expr` as a sequence of SSA instructions; return the register (or
   literal) holding the result. Caller is expected to know the expected
   LLVM type from the AST's `.ty` annotation. *)
let rec emit_expr (env : env) (e : Ast.expr) : string =
  match e.Ast.node with
  | Ast.Int_lit n -> string_of_int n
  | Ast.Bool_lit b -> if b then "1" else "0"
  | Ast.Str_lit s ->
    (* String literals lower to a private constant + return its symbol;
       since pointers are opaque, the global is directly usable as a ptr. *)
    fresh_str_global s
  | Ast.Var name -> lookup env name e.Ast.loc
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
       emit_expr ((name, rv) :: env) body
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
  | Ast.App ({ node = Ast.Var "print"; _ }, arg) ->
    let av = emit_expr env arg in
    emit_instr (Printf.sprintf "  call i32 @puts(ptr %s)" av);
    "0"  (* unit / int 0 *)
  | Ast.App ({ node = Ast.Var "str_len"; _ }, arg) ->
    let av = emit_expr env arg in
    let raw = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i64 @strlen(ptr %s)" raw av);
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = trunc i64 %s to i32" r raw);
    r
  | Ast.App ({ node = Ast.Var name; _ }, arg)
    when Hashtbl.mem toplevel_fn_names name ->
    let av = emit_expr env arg in
    (* Look up the call site's return type; default to i32. *)
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
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call %s @%s(%s %s)" r ret_ty name arg_ty av);
    r
  | Ast.App _ ->
    unsupported e.Ast.loc "indirect / first-class fn call — Phase 5 later slice"
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
  | Ast.Record_lit (name, fields) ->
    if Hashtbl.mem Typer.views name then
      unsupported e.Ast.loc "view literal — Phase 5 later slice"
    else begin
      let info =
        match Hashtbl.find_opt Typer.records name with
        | Some i -> i
        | None ->
          unsupported e.Ast.loc ("unknown record type: " ^ name)
      in
      if info.Typer.r_params <> [] then
        unsupported e.Ast.loc "polymorphic record — Phase 5 later slice";
      (* Build struct by inserting each field in declaration order. The
         source may list fields in any order — re-order to match the
         record's declared field list. *)
      let rec build prev = function
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
                        r name prev (llvm_ty_of fty) ev (field_index name fname));
          build r rest
      in
      build "undef" info.Typer.r_fields
    end
  | Ast.Field_get (inner, fname) ->
    let iv = emit_expr env inner in
    let rname =
      match inner.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n -> n
         | _ -> unsupported e.Ast.loc "field access on non-record")
      | None -> unsupported e.Ast.loc "field access: missing inner type"
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, %d"
                  r rname iv (field_index rname fname));
    r
  | Ast.Record_update (base, updates) ->
    let bv = emit_expr env base in
    let rname =
      match base.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n -> n
         | _ -> unsupported e.Ast.loc "record update on non-record")
      | None -> unsupported e.Ast.loc "record update: missing base type"
    in
    let fields = record_fields rname in
    let rec apply prev = function
      | [] -> prev
      | (fname, ex) :: rest ->
        let fty =
          try List.assoc fname fields
          with Not_found ->
            unsupported e.Ast.loc
              (Printf.sprintf "record `%s` has no field `%s`" rname fname)
        in
        let ev = emit_expr env ex in
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, %d"
                      r rname prev (llvm_ty_of fty) ev (field_index rname fname));
        apply r rest
    in
    apply bv updates
  | Ast.Float_lit _ | Ast.Unit_lit
  | Ast.Let_rec _ | Ast.With _ | Ast.Fun _
  | Ast.Constr _ | Ast.Match _
  | Ast.Region_block _ | Ast.Ref _ ->
    unsupported e.Ast.loc "node kind not yet in Phase 5 MVP"

(* Emit a top-level fn definition. Each fn gets fresh register/label
   counters so the SSA names don't collide across functions. *)
let emit_fn_def (f : fn_decl) : string =
  reg_counter := 0;
  label_counter := 0;
  let saved = !instrs in
  instrs := [];
  emit_instr "entry:";
  (* Bind the param under its source name; in LLVM the param has its
     own SSA name "%<param>" supplied by the function header. *)
  let env = [(f.param, "%" ^ f.param)] in
  let rv = emit_expr env f.body in
  emit_instr (Printf.sprintf "  ret %s %s" (llvm_ty_of f.return_ty) rv);
  let body = String.concat "\n" (List.rev !instrs) in
  instrs := saved;
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
      "declare i64 @strlen(ptr)";
      "declare ptr @memcpy(ptr, ptr, i64)";
      "declare i32 @puts(ptr)";
      "declare i32 @printf(ptr, ...)" ]

let str_concat_helper =
  String.concat "\n"
    [ "define ptr @__lang_str_concat(ptr %a, ptr %b) {";
      "entry:";
      "  %la = call i64 @strlen(ptr %a)";
      "  %lb = call i64 @strlen(ptr %b)";
      "  %total = add i64 %la, %lb";
      "  %totalp1 = add i64 %total, 1";
      "  %r = call ptr @malloc(i64 %totalp1)";
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
  Hashtbl.reset toplevel_fn_names;
  let main_expr = Ast.desugar_program prog in
  (* Lift top-level fn bindings; the remainder is the actual main body. *)
  let skels, body_expr = lift_fn_skels main_expr in
  List.iter (fun s -> Hashtbl.replace toplevel_fn_names s.sname ()) skels;
  let fns = resolve_fn_types skels main_expr in
  let tuple_shapes = collect_tuple_shapes main_expr fns in
  let tuple_typedefs = List.map emit_tuple_typedef tuple_shapes in
  let record_names = collect_record_names main_expr fns in
  let record_typedefs = List.map emit_record_typedef record_names in
  let fn_defs = List.map emit_fn_def fns in
  (* Reset counters for the main body. *)
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
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
  let parts =
    [ "; LLVM IR generated by lang-ml (Phase 5)";
      "target triple = \"" ^ "x86_64-apple-macosx" ^ "\"";  (* clang will retarget if needed *)
      "" ]
    @ (if record_typedefs = [] then [] else record_typedefs @ [""])
    @ (if tuple_typedefs = [] then [] else tuple_typedefs @ [""])
    @ (if !str_globals = [] then [] else List.rev !str_globals @ [""])
    @ format_globals
    @ [ "";
        runtime_decls;
        "";
        str_concat_helper;
        "" ]
    @ (if fn_defs = [] then [] else fn_defs @ [""])
    @ [ "define i32 @main() {";
        body;
        "}";
        "" ]
  in
  String.concat "\n" parts
