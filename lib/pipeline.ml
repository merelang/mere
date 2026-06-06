(* Source string -> ... convenience functions. *)

let parse_only s =
  let tokens = Lexer.tokenize s in
  Parser.parse tokens

let process s =
  let ast = parse_only s in
  let value = Eval.eval ast in
  Eval.to_string value

let type_of s =
  let ast = parse_only s in
  Ast.pp_ty (Typer.type_check ast)

let process_typed s =
  let ast = parse_only s in
  let _t = Typer.type_check ast in
  Eval.to_string (Eval.eval ast)
