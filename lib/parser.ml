(* Recursive-descent parser. Grammar:
     expr   := sum
     sum    := term (('+' | '-') term)*    (* left-assoc *)
     term   := factor ('*' factor)*        (* left-assoc *)
     factor := '-' factor | atom
     atom   := Int | '(' expr ')'
*)

exception Parse_error of Loc.t * string

let parse tokens =
  let open Lexer in
  let mk loc node = Ast.{ loc; node } in
  let pos_of = function
    | (pos, _) :: _ -> pos
    | [] -> Loc.dummy
  in
  let rec expr toks = sum toks
  and sum toks =
    let lhs, toks = term toks in
    sum_tail lhs toks
  and sum_tail lhs toks =
    match toks with
    | (pos, T_plus) :: rest ->
      let rhs, toks = term rest in
      sum_tail (mk pos (Ast.Bin (Ast.Add, lhs, rhs))) toks
    | (pos, T_minus) :: rest ->
      let rhs, toks = term rest in
      sum_tail (mk pos (Ast.Bin (Ast.Sub, lhs, rhs))) toks
    | _ -> lhs, toks
  and term toks =
    let lhs, toks = factor toks in
    term_tail lhs toks
  and term_tail lhs toks =
    match toks with
    | (pos, T_star) :: rest ->
      let rhs, toks = factor rest in
      term_tail (mk pos (Ast.Bin (Ast.Mul, lhs, rhs))) toks
    | _ -> lhs, toks
  and factor toks =
    match toks with
    | (pos, T_minus) :: rest ->
      let inner, toks = factor rest in
      mk pos (Ast.Neg inner), toks
    | _ -> atom toks
  and atom toks =
    match toks with
    | (pos, T_int n) :: rest -> mk pos (Ast.Int_lit n), rest
    | (_, T_lparen) :: rest ->
      let inner, toks = expr rest in
      (match toks with
       | (_, T_rparen) :: rest -> inner, rest
       | _ -> raise (Parse_error (pos_of toks, "expected ')'")))
    | (pos, _) :: _ ->
      raise (Parse_error (pos, "expected integer or '('"))
    | [] ->
      raise (Parse_error (Loc.dummy, "unexpected end of input"))
  in
  let result, toks = expr tokens in
  match toks with
  | [(_, T_eof)] -> result
  | (pos, _) :: _ -> raise (Parse_error (pos, "trailing input"))
  | [] -> raise (Parse_error (Loc.dummy, "expected EOF"))
