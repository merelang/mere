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
let rec ty_tag (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt -> "int"
  | Ast.TyBool -> "bool"
  | Ast.TyStr -> "str"
  | Ast.TyUnit -> "unit"
  | Ast.TyTuple ts -> "tuple_" ^ String.concat "_" (List.map ty_tag ts)
  | other ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unsupported C codegen type element: %s" (Ast.pp_ty other)))

let tuple_struct_name (elems : Ast.ty list) : string =
  "tuple_" ^ String.concat "_" (List.map ty_tag elems)

(* Translate one Lang expression to a C expression string. *)
let rec emit_expr (e : Ast.expr) : string =
  match e.node with
  | Ast.Int_lit n -> string_of_int n
  | Ast.Bool_lit b -> if b then "1" else "0"
  | Ast.Str_lit s -> Ast.escape_string s
  | Ast.Var name -> name
  | Ast.Annot (inner, _) -> emit_expr inner
  | Ast.Neg a -> "(-" ^ emit_expr a ^ ")"
  | Ast.Bin (Ast.Concat, a, b) ->
    "__lang_str_concat(" ^ emit_expr a ^ ", " ^ emit_expr b ^ ")"
  | Ast.Bin (op, a, b) ->
    "(" ^ emit_expr a ^ " " ^ binop_to_c op ^ " " ^ emit_expr b ^ ")"
  | Ast.Cmp (op, a, b) ->
    "(" ^ emit_expr a ^ " " ^ cmpop_to_c op ^ " " ^ emit_expr b ^ ")"
  | Ast.Logic (op, a, b) ->
    "(" ^ emit_expr a ^ " " ^ logicop_to_c op ^ " " ^ emit_expr b ^ ")"
  | Ast.If (cond, then_, else_) ->
    "(" ^ emit_expr cond ^ " ? " ^ emit_expr then_ ^ " : " ^ emit_expr else_ ^ ")"
  | Ast.Let (pat, value, body) ->
    (match pat.pnode with
     | Ast.P_var name ->
       (* GCC/Clang statement expression so the whole let stays a C
          expression. `__auto_type` (GCC/Clang extension) lets us bind
          values of varying static types (int, const char*, ...) without
          threading typer info into codegen. *)
       "({ __auto_type " ^ name ^ " = " ^ emit_expr value ^ "; " ^ emit_expr body ^ "; })"
     | _ -> unsupported pat.ploc "non-variable let pattern")
  (* Unsupported nodes *)
  | Ast.Float_lit _   -> unsupported e.loc "float literals"
  | Ast.Unit_lit      -> "0"  (* unit becomes int 0 in C *)
  | Ast.Let_rec _     -> unsupported e.loc "let rec inside an expression (only allowed at top level)"
  | Ast.With _        -> unsupported e.loc "with"
  | Ast.Fun _         -> unsupported e.loc "functions in expression position (only top-level lifted fns supported)"
  | Ast.App (f, arg) ->
    (* Only `name(arg)` form: f must be a bare Var that names a lifted
       function or a recognized builtin. Curried multi-arg / closure
       values are out of scope. *)
    (match f.node with
     | Ast.Var "print" ->
       (* `print : str -> unit` → puts; statement expression yields 0
          so the surrounding context still sees an int value. *)
       "({ puts(" ^ emit_expr arg ^ "); 0; })"
     | Ast.Var "str_len" ->
       (* `str_len : str -> int` → cast away size_t. *)
       "((int) strlen(" ^ emit_expr arg ^ "))"
     | Ast.Var "fst" ->
       "(" ^ emit_expr arg ^ ").f0"
     | Ast.Var "snd" ->
       "(" ^ emit_expr arg ^ ").f1"
     | Ast.Var name ->
       name ^ "(" ^ emit_expr arg ^ ")"
     | _ ->
       unsupported e.loc
         "function application requires a direct named function (no closures / curry)")
  | Ast.Constr _      -> unsupported e.loc "data constructors"
  | Ast.Match _       -> unsupported e.loc "match"
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
  | Ast.Region_block _ -> unsupported e.loc "region blocks"
  | Ast.Ref _         -> unsupported e.loc "region references"
  | Ast.Record_lit _  -> unsupported e.loc "record literals"
  | Ast.Field_get _   -> unsupported e.loc "field access"
  | Ast.Record_update _ -> unsupported e.loc "record update"

type fn_decl = {
  name      : string;
  param     : string;
  body      : Ast.expr;
  param_ty  : Ast.ty;
  return_ty : Ast.ty;
}

(* Lang type → C type, restricted to the codegen subset. *)
let c_type_of (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool -> "int"
  | Ast.TyStr -> "const char*"
  | Ast.TyUnit -> "int"  (* unit becomes int 0; keeps return-type uniform *)
  | Ast.TyTuple ts -> tuple_struct_name ts
  | other ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf
        "unsupported C codegen type: %s (only int/bool/str/unit/tuple)"
        (Ast.pp_ty other)))

(* Skeleton info collected while walking the AST — types are filled in
   afterwards by inferring all fns together as one let-rec group. *)
type fn_skel = { sname : string; sparam : string; sbody : Ast.expr }

(* Walk the desugared main expression, extracting top-level fn bindings.
   Returns (fn skeletons in declaration order, residual main body). *)
let lift_fn_skels (e : Ast.expr) : fn_skel list * Ast.expr =
  let rec go (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, rest)
      when (match pat.Ast.pnode with Ast.P_var _ -> true | _ -> false) ->
      (match value.Ast.node with
       | Ast.Fun (param, _, fn_body) ->
         let name =
           match pat.Ast.pnode with Ast.P_var n -> n | _ -> assert false
         in
         let more, rest' = go rest in
         { sname = name; sparam = param; sbody = fn_body } :: more, rest'
       | _ -> [], e)
    | Ast.Let_rec (bindings, rest) ->
      let skels =
        List.map (fun (n, v) ->
          match v.Ast.node with
          | Ast.Fun (p, _, fb) -> { sname = n; sparam = p; sbody = fb }
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

(* Infer types for the lifted fn group via let-rec style: pre-bind all
   names to fresh tyvars, infer each body, unify. Returns full fn_decls. *)
let resolve_fn_types (skels : fn_skel list) : fn_decl list =
  let alphas = List.map (fun _ -> Typer.fresh_var ()) skels in
  let env_rec =
    List.fold_left2 (fun acc s a -> (s.sname, Typer.mono a) :: acc)
      Typer.initial_env skels alphas
  in
  List.iter2 (fun s alpha ->
    let fun_expr =
      Ast.{ loc = Loc.dummy;
            ty = None;
            node = Ast.Fun (s.sparam, None, s.sbody) } in
    let t = Typer.infer env_rec fun_expr in
    Typer.unify Loc.dummy alpha t
  ) skels alphas;
  List.map2 (fun s alpha ->
    match Ast.walk alpha with
    | Ast.TyArrow (p, r) ->
      { name = s.sname; param = s.sparam; body = s.sbody;
        param_ty = Ast.walk p; return_ty = Ast.walk r }
    | other ->
      raise (Codegen_error (Loc.dummy,
        Printf.sprintf "function `%s` has non-arrow inferred type `%s`"
          s.sname (Ast.pp_ty other)))
  ) skels alphas

let emit_fn (f : fn_decl) : string =
  Printf.sprintf "%s %s(%s %s) {\n  return %s;\n}"
    (c_type_of f.return_ty)
    f.name
    (c_type_of f.param_ty)
    f.param
    (emit_expr f.body)

let emit_fn_forward_decl (f : fn_decl) : string =
  Printf.sprintf "%s %s(%s);"
    (c_type_of f.return_ty) f.name (c_type_of f.param_ty)

(* String-concat runtime helper: allocates a new heap buffer of size
   |a| + |b| + 1 and concatenates. Memory is leaked — fine for short-lived
   programs (and matches the GC-less interpreter's current laxity). A
   future slice will swap in proper region / arena allocation. *)
let str_concat_helper =
  String.concat "\n"
    [ "static const char* __lang_str_concat(const char* a, const char* b) {";
      "  size_t la = strlen(a), lb = strlen(b);";
      "  char* r = (char*) malloc(la + lb + 1);";
      "  memcpy(r, a, la);";
      "  memcpy(r + la, b, lb);";
      "  r[la + lb] = '\\0';";
      "  return r;";
      "}" ]

let main_format_of (t : Ast.ty) : string option =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool -> Some "%d"
  | Ast.TyStr -> Some "%s"
  | Ast.TyUnit -> None
  | _ -> Some "%d"  (* best-effort; type-checker should have caught issues *)

(* Compile a whole program: flatten top-decls into nested lets, lift
   top-level fn bindings into C functions (with forward declarations to
   support self / mutual recursion), and emit the residual body inside
   `int main()`. `main_ty` drives the printf format (int/bool → %d, str
   → %s, unit → no printf). *)
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
    | Ast.TyTuple ts -> add ts; List.iter walk_ty ts
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
    | Ast.Ref (_, a) -> walk_expr a
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
  let fields =
    List.mapi (fun i t ->
      Printf.sprintf "  %s f%d;" (c_type_of t) i) elems
  in
  Printf.sprintf "typedef struct {\n%s\n} %s;"
    (String.concat "\n" fields) name

let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  let main_expr = Ast.desugar_program prog in
  let skels, body_expr = lift_fn_skels main_expr in
  let fns = resolve_fn_types skels in
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
    let all = from_expr @ from_fns in
    (* Dedup by struct name. *)
    let seen = Hashtbl.create 8 in
    List.filter (fun ts ->
      let k = tuple_struct_name ts in
      if Hashtbl.mem seen k then false
      else (Hashtbl.add seen k (); true)
    ) all
  in
  let tuple_typedefs = List.map emit_tuple_typedef tuple_shapes in
  let forward_decls = List.map emit_fn_forward_decl fns in
  let fn_defs = List.map emit_fn fns in
  let main_body = emit_expr body_expr in
  let main_stmt =
    match main_format_of main_ty with
    | None -> "  (void)(" ^ main_body ^ ");  /* unit result */"
    | Some fmt -> "  printf(\"" ^ fmt ^ "\\n\", " ^ main_body ^ ");"
  in
  let parts =
    [ "#include <stdio.h>";
      "#include <stdlib.h>";
      "#include <string.h>";
      "";
      str_concat_helper;
      "" ]
    @ (if tuple_typedefs = [] then [] else tuple_typedefs @ [""])
    @ (if forward_decls = [] then [] else forward_decls @ [""])
    @ (if fn_defs = [] then [] else fn_defs @ [""])
    @ [ "int main(void) {";
        main_stmt;
        "  return 0;";
        "}";
        "" ]
  in
  String.concat "\n" parts
