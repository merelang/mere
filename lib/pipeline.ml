(* Source string -> ... convenience functions. *)

let parse_program s =
  let tokens = Lexer.tokenize s in
  Parser.parse_program tokens

let parse_only s =
  let prog = parse_program s in
  Ast.desugar_program prog

let process s =
  let prog = parse_program s in
  let expr = Ast.desugar_program prog in
  let value = Eval.eval expr in
  Eval.to_string value

let type_of s =
  let prog = parse_program s in
  let expr = Ast.desugar_program prog in
  Ast.pp_ty (Typer.type_check expr)

let process_typed s =
  let prog = parse_program s in
  let expr = Ast.desugar_program prog in
  let _t = Typer.type_check expr in
  Eval.to_string (Eval.eval expr)
