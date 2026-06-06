(* Recursive-descent parser.

   Program grammar:
     program  := top_decl* main_expr
     top_decl := 'let' 'rec'? ident '=' expr ';'

   Expression grammar (low to high precedence):
     expr      := base_expr (':' ty)?
     base_expr := 'if' expr 'then' expr 'else' expr
                | 'let' 'rec'? ident '=' expr 'in' expr
                | 'fn' ident '->' expr
                | cmp
     cmp       := sum (('==' | '<') sum)?
     sum       := term (('+' | '-' | '++') term)*
     term      := factor ('*' factor)*
     factor    := '-' factor | apply
     apply     := atom atom*
     atom      := Int | Str | Bool | '()' | Ident | '(' expr ')'
     ty        := atom_ty ('->' ty)?
     atom_ty   := 'int' | 'bool' | 'str' | 'unit' | '(' ty ')'
*)

exception Parse_error of Loc.t * string

let parse_program tokens =
  let open Lexer in
  let mk loc node = Ast.{ loc; node } in
  let pos_of = function
    | (pos, _) :: _ -> pos
    | [] -> Loc.dummy
  in
  let rec ty toks =
    let lhs, toks = atom_ty toks in
    match toks with
    | (_, T_arrow) :: rest ->
      let rhs, toks = ty rest in
      Ast.TyArrow (lhs, rhs), toks
    | _ -> lhs, toks
  and atom_ty toks =
    match toks with
    | (_, T_ident "int") :: rest -> Ast.TyInt, rest
    | (_, T_ident "bool") :: rest -> Ast.TyBool, rest
    | (_, T_ident "str") :: rest -> Ast.TyStr, rest
    | (_, T_ident "unit") :: rest -> Ast.TyUnit, rest
    | (_, T_lparen) :: rest ->
      let inner, toks = ty rest in
      (match toks with
       | (_, T_rparen) :: rest -> inner, rest
       | _ -> raise (Parse_error (pos_of toks, "expected ')' in type")))
    | _ -> raise (Parse_error (pos_of toks, "expected type (int/bool/str/unit/arrow)"))
  in
  let rec expr toks =
    let inner, toks = base_expr toks in
    match toks with
    | (_, T_colon) :: rest ->
      let t, toks = ty rest in
      mk inner.Ast.loc (Ast.Annot (inner, t)), toks
    | _ -> inner, toks
  and base_expr toks =
    match toks with
    | (pos, T_if) :: rest ->
      let cond, toks = expr rest in
      (match toks with
       | (_, T_then) :: rest ->
         let then_branch, toks = expr rest in
         (match toks with
          | (_, T_else) :: rest ->
            let else_branch, toks = expr rest in
            mk pos (Ast.If (cond, then_branch, else_branch)), toks
          | _ -> raise (Parse_error (pos_of toks, "expected 'else'")))
       | _ -> raise (Parse_error (pos_of toks, "expected 'then'")))
    | (pos, T_let) :: (_, T_rec) :: (_, T_ident name) :: (_, T_eq) :: rest ->
      let value, toks = expr rest in
      (match toks with
       | (_, T_in) :: rest ->
         let body, toks = expr rest in
         mk pos (Ast.Let_rec (name, value, body)), toks
       | _ ->
         raise (Parse_error (pos_of toks, "expected 'in' after let rec binding (use ';' for top-level)")))
    | (pos, T_let) :: (_, T_rec) :: _ ->
      raise (Parse_error (pos, "expected 'ident = expr' after 'let rec'"))
    | (pos, T_let) :: (_, T_ident name) :: (_, T_eq) :: rest ->
      let value, toks = expr rest in
      (match toks with
       | (_, T_in) :: rest ->
         let body, toks = expr rest in
         mk pos (Ast.Let (name, value, body)), toks
       | _ ->
         raise (Parse_error (pos_of toks, "expected 'in' after let binding (use ';' for top-level)")))
    | (pos, T_let) :: _ ->
      raise (Parse_error (pos, "expected 'ident = expr' or 'rec ident = expr' after 'let'"))
    | (pos, T_fn) :: (_, T_ident param) :: (_, T_arrow) :: rest ->
      let body, toks = expr rest in
      mk pos (Ast.Fun (param, body)), toks
    | (pos, T_fn) :: _ ->
      raise (Parse_error (pos, "expected 'ident -> expr' after 'fn'"))
    | _ -> cmp toks
  and cmp toks =
    let lhs, toks = sum toks in
    match toks with
    | (pos, T_eq_eq) :: rest ->
      let rhs, toks = sum rest in
      mk pos (Ast.Cmp (Ast.Eq, lhs, rhs)), toks
    | (pos, T_lt) :: rest ->
      let rhs, toks = sum rest in
      mk pos (Ast.Cmp (Ast.Lt, lhs, rhs)), toks
    | _ -> lhs, toks
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
    | (pos, T_plus_plus) :: rest ->
      let rhs, toks = term rest in
      sum_tail (mk pos (Ast.Bin (Ast.Concat, lhs, rhs))) toks
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
    | _ -> apply toks
  and apply toks =
    let head, toks = atom toks in
    apply_tail head toks
  and apply_tail f toks =
    match toks with
    | (_, (T_int _ | T_string _ | T_ident _ | T_lparen | T_true | T_false)) :: _ ->
      let arg, toks = atom toks in
      apply_tail (mk f.Ast.loc (Ast.App (f, arg))) toks
    | _ -> f, toks
  and atom toks =
    match toks with
    | (pos, T_int n) :: rest -> mk pos (Ast.Int_lit n), rest
    | (pos, T_string s) :: rest -> mk pos (Ast.Str_lit s), rest
    | (pos, T_true) :: rest -> mk pos (Ast.Bool_lit true), rest
    | (pos, T_false) :: rest -> mk pos (Ast.Bool_lit false), rest
    | (pos, T_ident name) :: rest -> mk pos (Ast.Var name), rest
    | (pos, T_lparen) :: (_, T_rparen) :: rest ->
      mk pos Ast.Unit_lit, rest
    | (_, T_lparen) :: rest ->
      let inner, toks = expr rest in
      (match toks with
       | (_, T_rparen) :: rest -> inner, rest
       | _ -> raise (Parse_error (pos_of toks, "expected ')'")))
    | (pos, _) :: _ ->
      raise (Parse_error (pos, "expected literal, identifier, '()' or '('"))
    | [] ->
      raise (Parse_error (Loc.dummy, "unexpected end of input"))
  in
  let finish decls main toks =
    match toks with
    | [(_, T_eof)] -> { Ast.decls = List.rev decls; main }
    | (pos, _) :: _ -> raise (Parse_error (pos, "trailing input"))
    | [] -> raise (Parse_error (Loc.dummy, "expected EOF"))
  in
  let rec parse_decls decls toks =
    match toks with
    | (pos, T_let) :: (_, T_rec) :: (_, T_ident name) :: (_, T_eq) :: rest ->
      let value, toks = expr rest in
      (match toks with
       | (_, T_semi) :: rest ->
         parse_decls (Ast.Top_let_rec (name, value) :: decls) rest
       | (_, T_in) :: rest ->
         let body, toks = expr rest in
         let main = mk pos (Ast.Let_rec (name, value, body)) in
         finish decls main toks
       | _ ->
         raise (Parse_error (pos_of toks, "expected ';' or 'in' after let rec binding")))
    | (pos, T_let) :: (_, T_rec) :: _ ->
      raise (Parse_error (pos, "expected 'ident = expr' after 'let rec'"))
    | (pos, T_let) :: (_, T_ident name) :: (_, T_eq) :: rest ->
      let value, toks = expr rest in
      (match toks with
       | (_, T_semi) :: rest ->
         parse_decls (Ast.Top_let (name, value) :: decls) rest
       | (_, T_in) :: rest ->
         let body, toks = expr rest in
         let main = mk pos (Ast.Let (name, value, body)) in
         finish decls main toks
       | _ ->
         raise (Parse_error (pos_of toks, "expected ';' or 'in' after let binding")))
    | (pos, T_let) :: _ ->
      raise (Parse_error (pos, "expected 'ident = expr' or 'rec ident = expr' after 'let'"))
    | _ ->
      let main, toks = expr toks in
      finish decls main toks
  in
  parse_decls [] tokens

let parse tokens =
  let prog = parse_program tokens in
  match prog.decls with
  | [] -> prog.main
  | _ ->
    raise (Parse_error (Loc.dummy,
      "this parser entry-point does not accept top-level decls; use parse_program"))
