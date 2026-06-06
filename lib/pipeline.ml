(* Convenience: source string -> evaluated value (as a string). *)

let process s =
  let tokens = Lexer.tokenize s in
  let ast = Parser.parse tokens in
  let value = Eval.eval ast in
  Eval.to_string value

let parse_only s =
  let tokens = Lexer.tokenize s in
  Parser.parse tokens
