(* Recursive-descent parser with stateful constructor registry. *)

exception Parse_error of Loc.t * string

let starts_with_upper s =
  String.length s > 0 &&
  let c = s.[0] in
  c >= 'A' && c <= 'Z'

let constructors : (string, int) Hashtbl.t = Hashtbl.create 16

let is_primitive_type_name = function
  | "int" | "bool" | "str" | "unit" -> true
  | _ -> false

let parse_program tokens =
  let open Lexer in
  let mk loc node = Ast.{ loc; node } in
  let mkp loc node = Ast.{ ploc = loc; pnode = node } in
  let pos_of = function
    | (pos, _) :: _ -> pos
    | [] -> Loc.dummy
  in
  let lookup_constr name = Hashtbl.find_opt constructors name in
  (* Type parser. Precedence (low -> high):
       ty       := tuple_ty ('->' ty)?
       tuple_ty := app_ty ('*' app_ty)+ | app_ty
       app_ty   := simple_ty (IDENT_NON_PRIM)*    -- postfix `arg name` constructor
       simple_ty:= 'int' | 'bool' | 'str' | 'unit'
                 | IDENT_NON_PRIM       -- 0-arg TyCon
                 | T_tyvar              -- 'a (TyParam)
                 | '(' ty ')'  *)
  let rec ty toks =
    let lhs, toks = tuple_ty toks in
    match toks with
    | (_, T_arrow) :: rest ->
      let rhs, toks = ty rest in
      Ast.TyArrow (lhs, rhs), toks
    | _ -> lhs, toks
  and tuple_ty toks =
    let first, toks = app_ty toks in
    let rec collect acc toks =
      match toks with
      | (_, T_star) :: rest ->
        let next, toks = app_ty rest in
        collect (next :: acc) toks
      | _ -> List.rev acc, toks
    in
    let elements, toks = collect [first] toks in
    (match elements with
     | [t] -> t, toks
     | ts -> Ast.TyTuple ts, toks)
  and app_ty toks =
    let base, toks = simple_ty toks in
    let rec loop t toks =
      match toks with
      | (_, T_ident name) :: rest when not (is_primitive_type_name name) ->
        loop (Ast.TyCon (name, [t])) rest
      | _ -> t, toks
    in
    loop base toks
  and simple_ty toks =
    match toks with
    | (_, T_ident "int") :: rest -> Ast.TyInt, rest
    | (_, T_ident "bool") :: rest -> Ast.TyBool, rest
    | (_, T_ident "str") :: rest -> Ast.TyStr, rest
    | (_, T_ident "unit") :: rest -> Ast.TyUnit, rest
    | (_, T_ident name) :: rest -> Ast.TyCon (name, []), rest
    | (_, T_tyvar name) :: rest -> Ast.TyParam name, rest
    | (_, T_lparen) :: rest ->
      let inner, toks = ty rest in
      (match toks with
       | (_, T_rparen) :: rest -> inner, rest
       | _ -> raise (Parse_error (pos_of toks, "expected ')' in type")))
    | _ -> raise (Parse_error (pos_of toks, "expected type"))
  in
  let parse_variants toks =
    let toks = match toks with (_, T_pipe) :: rest -> rest | _ -> toks in
    let rec loop acc toks =
      match toks with
      | (_, T_ident name) :: rest when starts_with_upper name ->
        let payload, rest =
          match rest with
          | (_, T_of) :: rest_after_of ->
            let t, rest' = ty rest_after_of in
            Some t, rest'
          | _ -> None, rest
        in
        let acc = (name, payload) :: acc in
        (match rest with
         | (_, T_pipe) :: rest' -> loop acc rest'
         | _ -> List.rev acc, rest)
      | _ ->
        raise (Parse_error (pos_of toks,
          "expected variant constructor (capitalized identifier)"))
    in
    loop [] toks
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
         raise (Parse_error (pos_of toks, "expected 'in' after let rec binding")))
    | (pos, T_let) :: (_, T_rec) :: _ ->
      raise (Parse_error (pos, "expected 'ident = expr' after 'let rec'"))
    | (pos, T_let) :: (_, T_ident name) :: (_, T_eq) :: rest ->
      let value, toks = expr rest in
      (match toks with
       | (_, T_in) :: rest ->
         let body, toks = expr rest in
         mk pos (Ast.Let (name, value, body)), toks
       | _ ->
         raise (Parse_error (pos_of toks, "expected 'in' after let binding")))
    | (pos, T_let) :: _ ->
      raise (Parse_error (pos, "expected 'ident = expr' after 'let'"))
    | (pos, T_with) :: (_, T_ident name) :: (_, T_eq) :: rest ->
      let value, toks = expr rest in
      (* Allow multiple bindings separated by commas:
         `with x = e1, y = e2 in body` desugars to nested With's. *)
      let rec parse_more acc toks =
        match toks with
        | (_, T_comma) :: (_, T_ident n) :: (_, T_eq) :: rest ->
          let v, toks = expr rest in
          parse_more ((n, v) :: acc) toks
        | _ -> List.rev acc, toks
      in
      let more, toks = parse_more [] toks in
      (match toks with
       | (_, T_in) :: rest ->
         let body, toks = expr rest in
         let inner =
           List.fold_right (fun (n, v) acc ->
             mk pos (Ast.With (n, v, acc))
           ) more body
         in
         mk pos (Ast.With (name, value, inner)), toks
       | _ ->
         raise (Parse_error (pos_of toks, "expected 'in' after with binding")))
    | (pos, T_with) :: _ ->
      raise (Parse_error (pos, "expected 'ident = expr' after 'with'"))
    | (pos, T_fn) :: (_, T_ident param) :: (_, T_arrow) :: rest ->
      let body, toks = expr rest in
      mk pos (Ast.Fun (param, body)), toks
    | (pos, T_fn) :: _ ->
      raise (Parse_error (pos, "expected 'ident -> expr' after 'fn'"))
    | (pos, T_match) :: rest ->
      let scrut, toks = expr rest in
      (match toks with
       | (_, T_with) :: rest ->
         let arms, toks = parse_arms rest in
         mk pos (Ast.Match (scrut, arms)), toks
       | _ -> raise (Parse_error (pos_of toks, "expected 'with' after match")))
    | _ -> cmp toks
  and parse_arms toks =
    let toks = match toks with (_, T_pipe) :: rest -> rest | _ -> toks in
    let rec loop acc toks =
      let p, toks = pattern toks in
      let toks =
        match toks with
        | (_, T_arrow) :: rest -> rest
        | _ -> raise (Parse_error (pos_of toks, "expected '->' in match arm"))
      in
      let body, toks = expr toks in
      let acc = (p, body) :: acc in
      match toks with
      | (_, T_pipe) :: rest -> loop acc rest
      | _ -> List.rev acc, toks
    in
    loop [] toks
  and pattern toks =
    match toks with
    | (pos, T_underscore) :: rest -> mkp pos Ast.P_wild, rest
    | (pos, T_int n) :: rest -> mkp pos (Ast.P_int n), rest
    | (pos, T_string s) :: rest -> mkp pos (Ast.P_str s), rest
    | (pos, T_true) :: rest -> mkp pos (Ast.P_bool true), rest
    | (pos, T_false) :: rest -> mkp pos (Ast.P_bool false), rest
    | (pos, T_lparen) :: (_, T_rparen) :: rest -> mkp pos Ast.P_unit, rest
    | (pos, T_lparen) :: rest ->
      let first, toks = pattern rest in
      (match toks with
       | (_, T_comma) :: _ ->
         let rec collect acc toks =
           match toks with
           | (_, T_comma) :: rest ->
             let next, toks = pattern rest in
             collect (next :: acc) toks
           | _ -> List.rev acc, toks
         in
         let elements, toks = collect [first] toks in
         (match toks with
          | (_, T_rparen) :: rest -> mkp pos (Ast.P_tuple elements), rest
          | _ -> raise (Parse_error (pos_of toks, "expected ')' in tuple pattern")))
       | (_, T_rparen) :: rest -> first, rest
       | _ -> raise (Parse_error (pos_of toks, "expected ',' or ')' in pattern")))
    | (pos, T_ident name) :: rest when starts_with_upper name ->
      let arity = match lookup_constr name with Some a -> a | None -> 0 in
      if arity = 0 then
        mkp pos (Ast.P_constr (name, None)), rest
      else begin
        match rest with
        | (_, (T_int _ | T_string _ | T_true | T_false | T_underscore
              | T_lparen | T_ident _)) :: _ ->
          let sub, rest = pattern rest in
          mkp pos (Ast.P_constr (name, Some sub)), rest
        | _ ->
          mkp pos (Ast.P_constr (name, None)), rest
      end
    | (pos, T_ident name) :: rest -> mkp pos (Ast.P_var name), rest
    | _ -> raise (Parse_error (pos_of toks, "expected pattern"))
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
    | (pos, T_lparen) :: (_, T_rparen) :: rest -> mk pos Ast.Unit_lit, rest
    | (pos, T_lparen) :: rest ->
      let first, toks = expr rest in
      (match toks with
       | (_, T_comma) :: _ ->
         let rec collect acc toks =
           match toks with
           | (_, T_comma) :: rest ->
             let next, toks = expr rest in
             collect (next :: acc) toks
           | _ -> List.rev acc, toks
         in
         let elements, toks = collect [first] toks in
         (match toks with
          | (_, T_rparen) :: rest -> mk pos (Ast.Tuple elements), rest
          | _ -> raise (Parse_error (pos_of toks, "expected ')' in tuple")))
       | (_, T_rparen) :: rest -> first, rest
       | _ -> raise (Parse_error (pos_of toks, "expected ',' or ')' after expression")))
    | (pos, T_ident name) :: rest when starts_with_upper name ->
      let arity = match lookup_constr name with Some a -> a | None -> 0 in
      if arity = 0 then
        mk pos (Ast.Constr (name, None)), rest
      else begin
        match rest with
        | (_, (T_int _ | T_string _ | T_ident _ | T_lparen
              | T_true | T_false)) :: _ ->
          let arg, rest = atom rest in
          mk pos (Ast.Constr (name, Some arg)), rest
        | _ ->
          mk pos (Ast.Constr (name, None)), rest
      end
    | (pos, T_ident name) :: rest -> mk pos (Ast.Var name), rest
    | (pos, _) :: _ ->
      raise (Parse_error (pos, "expected literal, identifier, or '('"))
    | [] ->
      raise (Parse_error (Loc.dummy, "unexpected end of input"))
  in
  let finish decls main toks =
    match toks with
    | [(_, T_eof)] -> { Ast.decls = List.rev decls; main }
    | (pos, _) :: _ -> raise (Parse_error (pos, "trailing input"))
    | [] -> raise (Parse_error (Loc.dummy, "expected EOF"))
  in
  (* Parse type params: optional `'a` before the type name. *)
  let parse_type_params toks =
    match toks with
    | (_, T_tyvar name) :: rest -> [name], rest
    | _ -> [], toks
  in
  let rec parse_decls decls toks =
    match toks with
    | (_, T_type) :: rest ->
      let params, rest = parse_type_params rest in
      (match rest with
       | (_, T_ident type_name) :: (_, T_eq) :: rest ->
         let variants, toks = parse_variants rest in
         List.iter (fun (cname, payload) ->
           Hashtbl.replace constructors cname (match payload with None -> 0 | _ -> 1)
         ) variants;
         (match toks with
          | (_, T_semi) :: rest ->
            parse_decls (Ast.Top_type (type_name, params, variants) :: decls) rest
          | _ ->
            raise (Parse_error (pos_of toks, "expected ';' after type declaration")))
       | _ ->
         raise (Parse_error (pos_of rest, "expected 'ident = ...' after 'type'")))
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
      raise (Parse_error (pos, "expected 'ident = expr' after 'let'"))
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
