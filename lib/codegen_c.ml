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
       function or a recognized builtin (currently `print`). Curried
       multi-arg / closure values are out of scope. *)
    (match f.node with
     | Ast.Var "print" ->
       (* `print : str -> unit` → puts; statement expression yields 0
          so the surrounding context still sees an int value. *)
       "({ puts(" ^ emit_expr arg ^ "); 0; })"
     | Ast.Var name ->
       name ^ "(" ^ emit_expr arg ^ ")"
     | _ ->
       unsupported e.loc
         "function application requires a direct named function (no closures / curry)")
  | Ast.Constr _      -> unsupported e.loc "data constructors"
  | Ast.Match _       -> unsupported e.loc "match"
  | Ast.Tuple _       -> unsupported e.loc "tuples"
  | Ast.Region_block _ -> unsupported e.loc "region blocks"
  | Ast.Ref _         -> unsupported e.loc "region references"
  | Ast.Record_lit _  -> unsupported e.loc "record literals"
  | Ast.Field_get _   -> unsupported e.loc "field access"
  | Ast.Record_update _ -> unsupported e.loc "record update"

type fn_decl = {
  name  : string;
  param : string;
  body  : Ast.expr;
}

(* Walk the desugared main expression, extracting top-level fn bindings
   into a list of fn_decls. Stops at the first non-let / non-fn-let node
   and returns it as the residual main body. *)
let lift_fns (e : Ast.expr) : fn_decl list * Ast.expr =
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
         { name; param; body = fn_body } :: more, rest'
       | _ -> [], e)
    | Ast.Let_rec (bindings, rest) ->
      let fns =
        List.map (fun (n, v) ->
          match v.Ast.node with
          | Ast.Fun (p, _, fb) -> { name = n; param = p; body = fb }
          | _ ->
            raise (Codegen_error (v.Ast.loc,
              "let rec binding must be a single-arg function in C subset")))
          bindings
      in
      let more, rest' = go rest in
      fns @ more, rest'
    | _ -> [], e
  in
  go e

let emit_fn (f : fn_decl) : string =
  Printf.sprintf "int %s(int %s) {\n  return %s;\n}"
    f.name f.param (emit_expr f.body)

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
let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  let main_expr = Ast.desugar_program prog in
  let fns, body_expr = lift_fns main_expr in
  let forward_decls =
    List.map (fun f -> "int " ^ f.name ^ "(int);") fns
  in
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
    @ (if forward_decls = [] then [] else forward_decls @ [""])
    @ (if fn_defs = [] then [] else fn_defs @ [""])
    @ [ "int main(void) {";
        main_stmt;
        "  return 0;";
        "}";
        "" ]
  in
  String.concat "\n" parts
