(* C codegen — first slice (Phase 4 prep).

   Subset:
     int / bool literals
     binary arithmetic   + - * / %
     unary negation      -
     comparisons         == != < <= > >=  (results in int 0/1)
     logical             && ||             (short-circuit via C's own)
     if-then-else        (both branches must have the same type)
     let bindings        (only P_var pattern, int- or bool-typed values)
     Var references
     Annot (drops the annotation, emits the inner expression)

   Not yet supported (will raise Codegen_error):
     functions / closures / app
     strings / records / variants / tuples / patterns / match
     region / view / Ref / with
     stdlib builtins beyond what the subset needs

   Top-level decls are flattened into nested `let` via Ast.desugar_program
   so we only need to translate one expression. The whole program becomes:

     #include <stdio.h>
     int main(void) {
       printf("%d\n", <EXPR>);
       return 0;
     }

   Let-bindings use GCC/Clang statement expressions `({ ... })` so the whole
   thing is one C expression — keeps emit_expr cleanly recursive.
*)

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
  | Ast.Var name -> name
  | Ast.Annot (inner, _) -> emit_expr inner
  | Ast.Neg a -> "(-" ^ emit_expr a ^ ")"
  | Ast.Bin (Ast.Concat, _, _) -> unsupported e.loc "string concat (++)"
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
       (* Use a GCC/Clang statement expression so the whole let stays a
          C expression. Type assumed `int` for now — bools collapse to
          int(0/1). String/record bindings will need a richer scheme. *)
       "({ int " ^ name ^ " = " ^ emit_expr value ^ "; " ^ emit_expr body ^ "; })"
     | _ -> unsupported pat.ploc "non-variable let pattern")
  (* Unsupported nodes *)
  | Ast.Float_lit _   -> unsupported e.loc "float literals"
  | Ast.Str_lit _     -> unsupported e.loc "string literals"
  | Ast.Unit_lit      -> unsupported e.loc "unit literal"
  | Ast.Let_rec _     -> unsupported e.loc "let rec"
  | Ast.With _        -> unsupported e.loc "with"
  | Ast.Fun _         -> unsupported e.loc "functions / closures"
  | Ast.App _         -> unsupported e.loc "function application"
  | Ast.Constr _      -> unsupported e.loc "data constructors"
  | Ast.Match _       -> unsupported e.loc "match"
  | Ast.Tuple _       -> unsupported e.loc "tuples"
  | Ast.Region_block _ -> unsupported e.loc "region blocks"
  | Ast.Ref _         -> unsupported e.loc "region references"
  | Ast.Record_lit _  -> unsupported e.loc "record literals"
  | Ast.Field_get _   -> unsupported e.loc "field access"
  | Ast.Record_update _ -> unsupported e.loc "record update"

(* Compile a whole program: flatten top-decls into nested lets, then wrap
   the main expression in a C `int main` that prints the result. *)
let emit_program (prog : Ast.program) : string =
  let main_expr = Ast.desugar_program prog in
  let body = emit_expr main_expr in
  String.concat "\n"
    [ "#include <stdio.h>";
      "";
      "int main(void) {";
      "  printf(\"%d\\n\", " ^ body ^ ");";
      "  return 0;";
      "}";
      "" ]
