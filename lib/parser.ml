(* Recursive-descent parser with stateful constructor registry. *)

exception Parse_error of Loc.t * string

let starts_with_upper s =
  String.length s > 0 &&
  let c = s.[0] in
  c >= 'A' && c <= 'Z'

let constructors : (string, int) Hashtbl.t = Hashtbl.create 16

(* signature alias registry: name -> typed param list.
   Populated by `signature name = (p1: T1, ...);` and consumed by
   `...name` spread inside fn parameter lists. *)
let signatures : (string, (string * Ast.ty) list) Hashtbl.t = Hashtbl.create 8

(* Record registry: type name -> ordered (field, ty) list.
   Used by the parser to distinguish `Point { ... }` (record literal)
   from `Some 5` (constructor application). *)
let records : (string, (string * Ast.ty) list) Hashtbl.t = Hashtbl.create 8

(* Module registry: name -> ().  Populated when `module M { ... }` is
   parsed; consumed in `field_chain` to decide whether `M.x` is a
   qualified name (Var "M.x") rather than a field access on M. *)
let module_names : (string, unit) Hashtbl.t = Hashtbl.create 4

(* Import registry: file path -> ().  Populated when `import "path";` is
   processed; consumed to skip subsequent imports of the same file
   (cycle guard). Paths are stored as given by the source (no
   canonicalisation in slice 1 — symlinks / different relative forms
   of the same file would each re-import). *)
let imported_files : (string, unit) Hashtbl.t = Hashtbl.create 4

(* Region name stack — pushed when entering a `region NAME { ... }` body
   and popped on exit. Used to recognize `R.alloc(expr)` as sugar for
   `&R expr` only when R is a lexically-enclosing region (so existing
   `obj.alloc(...)` field access on regular records stays untouched). *)
let region_stack : string list ref = ref []

(* Counter for fresh variable names synthesized by `<<` / `>>` desugaring. *)
let compose_var_counter = ref 0
let fresh_compose_var () =
  let n = !compose_var_counter in
  incr compose_var_counter;
  Printf.sprintf "__cx_%d" n

(* Type alias registry: name -> (params, body).
   Populated by `type Name = T;` (non-record, non-variant body).
   Consumed at type-expression sites to substitute aliases inline
   (parse-time expansion). *)
let aliases : (string, string list * Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Substitute alias params in body with args.  Used when a TyCon (name, args)
   references a known alias. *)
let substitute_params params args body =
  let mapping = List.combine params args in
  let rec subst t =
    match t with
    | Ast.TyParam p ->
      (try List.assoc p mapping with Not_found -> t)
    | (Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyUnit | Ast.TyVar _) -> t
    | Ast.TyArrow (a, b) -> Ast.TyArrow (subst a, subst b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map subst ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map subst args)
    | Ast.TyRef (r, inner) -> Ast.TyRef (r, subst inner)
  in
  subst body

let expand_alias_or_tycon name args =
  match Hashtbl.find_opt aliases name with
  | Some (params, body) when List.length params = List.length args ->
    substitute_params params args body
  | _ -> Ast.TyCon (name, args)

let is_primitive_type_name = function
  | "int" | "float" | "bool" | "str" | "unit" -> true
  | _ -> false

let rec parse_program_internal tokens =
  let open Lexer in
  (* Reset transient parser state so failed earlier parses don't leak.
     `imported_files` is NOT reset here — the outer `parse_program`
     wrapper resets it once per top-level parse so the cycle guard
     accumulates across recursive imports within a single program. *)
  region_stack := [];
  let mk loc node = Ast.{ loc; ty = None; node } in
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
        loop (expand_alias_or_tycon name [t]) rest
      | _ -> t, toks
    in
    loop base toks
  and simple_ty toks =
    match toks with
    | (_, T_amp) :: (_, T_ident region) :: rest ->
      (* `&R T` — region-tagged reference type *)
      let inner, rest = simple_ty rest in
      Ast.TyRef (region, inner), rest
    | (_, T_ident "int") :: rest -> Ast.TyInt, rest
    | (_, T_ident "float") :: rest -> Ast.TyFloat, rest
    | (_, T_ident "bool") :: rest -> Ast.TyBool, rest
    | (_, T_ident "str") :: rest -> Ast.TyStr, rest
    | (_, T_ident "unit") :: rest -> Ast.TyUnit, rest
    | (_, T_ident name) :: rest -> expand_alias_or_tycon name [], rest
    | (_, T_tyvar name) :: rest -> Ast.TyParam name, rest
    | (_, T_lparen) :: rest ->
      let first, toks = ty rest in
      (match toks with
       | (_, T_rparen) :: rest -> first, rest
       | (_, T_comma) :: _ ->
         (* Multi-arg TyCon application: `(T1, T2, ...) name` *)
         let rec collect acc toks =
           match toks with
           | (_, T_comma) :: rest ->
             let next, toks = ty rest in
             collect (next :: acc) toks
           | _ -> List.rev acc, toks
         in
         let args, toks = collect [first] toks in
         (match toks with
          | (_, T_rparen) :: (_, T_ident name) :: rest
            when not (is_primitive_type_name name) ->
            expand_alias_or_tycon name args, rest
          | _ ->
            raise (Parse_error (pos_of toks,
              "expected ') NAME' for multi-arg type constructor")))
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
  (* `using [c1, c2: T, ...]` clause on a fn — returns list of cap params
     (name + optional type), to be prepended to the fn's regular params so
     they become the outer-most curried args. If no `using` clause is
     present, returns ([], toks) unchanged. *)
  let parse_using_caps toks =
    match toks with
    | (pos, T_using) :: (_, T_lbracket) :: rest ->
      let rec loop acc toks =
        match toks with
        | (_, T_rbracket) :: rest -> List.rev acc, rest
        | (_, T_ident name) :: (_, T_colon) :: rest ->
          let t, rest = ty rest in
          let acc = (name, Some t) :: acc in
          (match rest with
           | (_, T_comma) :: rest -> loop acc rest
           | (_, T_rbracket) :: rest -> List.rev acc, rest
           | _ ->
             raise (Parse_error (pos_of rest,
               "expected ',' or ']' in using cap list")))
        | (_, T_ident name) :: rest ->
          let acc = (name, None) :: acc in
          (match rest with
           | (_, T_comma) :: rest -> loop acc rest
           | (_, T_rbracket) :: rest -> List.rev acc, rest
           | _ ->
             raise (Parse_error (pos_of rest,
               "expected ',' or ']' in using cap list")))
        | _ ->
          raise (Parse_error (pos_of toks,
            "expected cap name in using list"))
      in
      let caps, rest = loop [] rest in
      if caps = [] then
        raise (Parse_error (pos, "using clause must list at least one cap"));
      caps, rest
    | _ -> [], toks
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
          | _ ->
            (* Else-less form: `if cond then body` for unit-typed body.
               Synthesize `else ()`. The typer will unify then with unit. *)
            let else_branch = mk pos Ast.Unit_lit in
            mk pos (Ast.If (cond, then_branch, else_branch)), toks)
       | _ -> raise (Parse_error (pos_of toks, "expected 'then'")))
    | (pos, T_let) :: (_, T_rec) :: (_, T_ident name) :: (_, T_eq) :: rest ->
      let value, toks = expr rest in
      (* `and NAME = expr` chain for mutual recursion. *)
      let rec parse_more acc toks =
        match toks with
        | (_, T_and) :: (_, T_ident n) :: (_, T_eq) :: rest ->
          let v, toks = expr rest in
          parse_more ((n, v) :: acc) toks
        | _ -> List.rev acc, toks
      in
      let more, toks = parse_more [] toks in
      let bindings = (name, value) :: more in
      (match toks with
       | (_, T_in) :: rest ->
         let body, toks = expr rest in
         mk pos (Ast.Let_rec (bindings, body)), toks
       | _ ->
         raise (Parse_error (pos_of toks, "expected 'in' after let rec binding")))
    | (pos, T_let) :: (_, T_rec) :: _ ->
      raise (Parse_error (pos, "expected 'ident = expr' after 'let rec'"))
    | (pos, T_let) :: rest_after_let ->
      (* Parse the pattern (P_var for the typical `let x = ...` case,
         or P_tuple / P_wild / P_unit for destructuring). *)
      let pat, rest = pattern rest_after_let in
      (match rest with
       | (_, T_eq) :: rest ->
         let value, rest = expr rest in
         (match rest with
          | (_, T_in) :: rest ->
            let body, rest = expr rest in
            mk pos (Ast.Let (pat, value, body)), rest
          | _ ->
            raise (Parse_error (pos_of rest, "expected 'in' after let binding")))
       | _ ->
         raise (Parse_error (pos_of rest, "expected '=' after let pattern")))
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
    | (pos, T_fn) :: (_, T_lparen) :: rest ->
      (* Multi-arg with optional type annotations:
           fn (x: int, y: str) -> body
           fn (x: int) -> body
           fn (x, y) -> body                 (* no types, multi-arg *)
           fn () -> body                     (* single unit param *)
         Desugars to nested Fun (param, ty_opt, ...).  *)
      let rec parse_params toks =
        (* end of params? *)
        match toks with
        | (_, T_rparen) :: rest -> [], rest
        | (sp_pos, T_ellipsis) :: (_, T_ident sig_name) :: rest ->
          (* `...sig_name` expands to the signature's parameter list. *)
          let expanded =
            match Hashtbl.find_opt signatures sig_name with
            | Some params ->
              List.map (fun (n, t) -> (n, Some t)) params
            | None ->
              raise (Parse_error (sp_pos,
                Printf.sprintf "unknown signature: %s" sig_name))
          in
          (match rest with
           | (_, T_comma) :: rest ->
             let rest_ps, rest = parse_params rest in
             (expanded @ rest_ps), rest
           | (_, T_rparen) :: rest -> expanded, rest
           | _ -> raise (Parse_error (pos_of rest, "expected ',' or ')' after spread")))
        | _ ->
          let (n, t_opt), rest = parse_one toks in
          (match rest with
           | (_, T_comma) :: rest ->
             let rest_ps, rest = parse_params rest in
             ((n, t_opt) :: rest_ps), rest
           | (_, T_rparen) :: rest -> [(n, t_opt)], rest
           | _ -> raise (Parse_error (pos_of rest, "expected ',' or ')' in param list")))
      and parse_one toks =
        match toks with
        | (_, T_ident name) :: (_, T_colon) :: rest ->
          let t, rest = ty rest in
          (name, Some t), rest
        | (_, T_ident name) :: rest ->
          (name, None), rest
        | _ -> raise (Parse_error (pos_of toks, "expected parameter name"))
      in
      let params, toks = parse_params rest in
      let caps, toks = parse_using_caps toks in
      (match toks with
       | (_, T_arrow) :: rest ->
         let body, toks = expr rest in
         (* Special case: empty param list `fn () -> body` means a single
            unit-typed param with a fresh name. *)
         let params = if params = [] && caps = [] then [("_u", Some Ast.TyUnit)] else params in
         (* `using [c1, c2] params` desugars to `fn c1 -> fn c2 -> fn params -> body`
            — caps are outer params so partial application captures them first. *)
         let all_params = caps @ params in
         let f =
           List.fold_right
             (fun (n, t) acc -> mk pos (Ast.Fun (n, t, acc)))
             all_params body
         in
         f, toks
       | _ -> raise (Parse_error (pos_of toks, "expected '->' after parameter list")))
    | (pos, T_fn) :: (_, T_ident param) :: (param_rest) ->
      (* Single-ident form: `fn x -> body` or `fn x using [caps] -> body`. *)
      let caps, after_caps = parse_using_caps param_rest in
      (match after_caps with
       | (_, T_arrow) :: rest ->
         let body, toks = expr rest in
         let all_params = caps @ [(param, None)] in
         let f =
           List.fold_right
             (fun (n, t) acc -> mk pos (Ast.Fun (n, t, acc)))
             all_params body
         in
         f, toks
       | _ -> raise (Parse_error (pos_of after_caps, "expected '->' after parameter")))
    | (pos, T_fn) :: _ ->
      raise (Parse_error (pos, "expected 'ident -> expr' or '(params) -> expr' after 'fn'"))
    | (pos, T_match) :: rest ->
      let scrut, toks = expr rest in
      (match toks with
       | (_, T_with) :: rest ->
         let arms, toks = parse_arms rest in
         mk pos (Ast.Match (scrut, arms)), toks
       | _ -> raise (Parse_error (pos_of toks, "expected 'with' after match")))
    | (pos, T_region) :: (_, T_ident name) :: (_, T_lbrace) :: rest ->
      region_stack := name :: !region_stack;
      let body, toks =
        try expr rest
        with ex -> region_stack := List.tl !region_stack; raise ex
      in
      region_stack := List.tl !region_stack;
      (match toks with
       | (_, T_rbrace) :: rest ->
         mk pos (Ast.Region_block (name, body)), rest
       | _ -> raise (Parse_error (pos_of toks, "expected '}' to close region block")))
    | (pos, T_region) :: _ ->
      raise (Parse_error (pos, "expected 'NAME { body }' after 'region'"))
    | _ -> pipe toks
  and pipe toks =
    (* Lowest-precedence operator below let/if/fn/match.
       `a |> f` desugars to `f a`. Left-associative: `a |> b |> c` = `c (b a)`. *)
    let lhs, toks = compose toks in
    let rec loop lhs toks =
      match toks with
      | (pos, T_pipe_gt) :: rest ->
        let rhs, toks = compose rest in
        loop (mk pos (Ast.App (rhs, lhs))) toks
      | _ -> lhs, toks
    in
    loop lhs toks
  and compose toks =
    (* Function composition `<<` and `>>` — right-associative, binds
       tighter than `|>` but looser than logic_or.
       `f << g` = `fn __cx -> f (g __cx)`   (apply g first, then f)
       `f >> g` = `fn __cx -> g (f __cx)`   (apply f first, then g)
       `a << b << c` = `a << (b << c)` (right-assoc) *)
    let lhs, toks = logic_or toks in
    match toks with
    | (pos, T_lt_lt) :: rest ->
      let rhs, toks = compose rest in
      let x = fresh_compose_var () in
      let var = mk pos (Ast.Var x) in
      let body = mk pos (Ast.App (lhs, mk pos (Ast.App (rhs, var)))) in
      mk pos (Ast.Fun (x, None, body)), toks
    | (pos, T_gt_gt) :: rest ->
      let rhs, toks = compose rest in
      let x = fresh_compose_var () in
      let var = mk pos (Ast.Var x) in
      let body = mk pos (Ast.App (rhs, mk pos (Ast.App (lhs, var)))) in
      mk pos (Ast.Fun (x, None, body)), toks
    | _ -> lhs, toks
  and parse_arms toks =
    let toks = match toks with (_, T_pipe) :: rest -> rest | _ -> toks in
    let rec loop acc toks =
      let p, toks = pattern toks in
      (* Or-pattern continuation: `pat1 | pat2 | pat3 -> body`.
         A `|` here (before `->`/`when`) groups patterns into a single arm.
         Left-associative. *)
      let p, toks =
        let rec collect_or lhs toks =
          match toks with
          | (pos, T_pipe) :: rest ->
            let rhs, toks = pattern rest in
            collect_or (mkp pos (Ast.P_or (lhs, rhs))) toks
          | _ -> lhs, toks
        in
        collect_or p toks
      in
      let guard, toks =
        match toks with
        | (_, T_when) :: rest ->
          let g, toks = expr rest in
          Some g, toks
        | _ -> None, toks
      in
      let toks =
        match toks with
        | (_, T_arrow) :: rest -> rest
        | _ -> raise (Parse_error (pos_of toks, "expected '->' in match arm"))
      in
      let body, toks = expr toks in
      let acc = (p, guard, body) :: acc in
      match toks with
      | (_, T_pipe) :: rest -> loop acc rest
      | _ -> List.rev acc, toks
    in
    loop [] toks
  and pattern toks =
    (* Wrap pattern_base with optional trailing `as IDENT`. *)
    let p, toks = pattern_base toks in
    match toks with
    | (pos, T_as) :: (_, T_ident name) :: rest ->
      mkp pos (Ast.P_as (p, name)), rest
    | _ -> p, toks
  and pattern_base toks =
    match toks with
    | (pos, T_lbracket) :: (_, T_rbracket) :: rest ->
      (* `[]` pattern -> P_constr ("Nil", None) *)
      mkp pos (Ast.P_constr ("Nil", None)), rest
    | (pos, T_lbracket) :: rest ->
      (* List pattern: `[a, b, c]` or `[a, b, ...rest]`
         desugars to Cons(a, Cons(b, Cons(c, Nil))) or
         Cons(a, Cons(b, rest)) respectively. *)
      let rec parse_elems acc toks =
        (* Check for `...rest` tail first *)
        match toks with
        | (_, T_ellipsis) :: (_, T_ident name) :: (_, T_rbracket) :: rest ->
          let tail = mkp pos (Ast.P_var name) in
          List.rev acc, tail, rest
        | (_, T_ellipsis) :: (_, T_underscore) :: (_, T_rbracket) :: rest ->
          let tail = mkp pos Ast.P_wild in
          List.rev acc, tail, rest
        | _ ->
          let p, toks = pattern toks in
          let acc = p :: acc in
          (match toks with
           | (_, T_comma) :: rest -> parse_elems acc rest
           | (_, T_rbracket) :: rest ->
             let nil = mkp pos (Ast.P_constr ("Nil", None)) in
             List.rev acc, nil, rest
           | _ ->
             raise (Parse_error (pos_of toks,
               "expected ',' or ']' in list pattern")))
      in
      let elems, tail, rest = parse_elems [] rest in
      let result = List.fold_right (fun p acc ->
        mkp pos (Ast.P_constr ("Cons", Some (mkp pos (Ast.P_tuple [p; acc]))))
      ) elems tail in
      result, rest
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
      (* Record pattern:  Name { f1 = pat, f2 = pat, ... } *)
      if Hashtbl.mem records name then begin
        match rest with
        | (_, T_lbrace) :: body_rest ->
          let rec parse_fpats acc toks =
            match toks with
            | (_, T_rbrace) :: rest -> List.rev acc, rest
            | (_, T_ident fname) :: (_, T_eq) :: rest ->
              let p, rest = pattern rest in
              let acc = (fname, p) :: acc in
              (match rest with
               | (_, T_comma) :: rest -> parse_fpats acc rest
               | (_, T_rbrace) :: rest -> List.rev acc, rest
               | _ ->
                 raise (Parse_error (pos_of rest,
                   "expected ',' or '}' in record pattern")))
            | _ ->
              raise (Parse_error (pos_of toks,
                "expected 'field = pat' in record pattern"))
          in
          let fpats, rest = parse_fpats [] body_rest in
          mkp pos (Ast.P_record (name, fpats)), rest
        | _ ->
          raise (Parse_error (pos, "expected '{' for record pattern"))
      end else
      let arity = match lookup_constr name with Some a -> a | None -> 0 in
      if arity = 0 then
        mkp pos (Ast.P_constr (name, None)), rest
      else begin
        match rest with
        | (_, (T_int _ | T_float _ | T_string _ | T_true | T_false
              | T_underscore | T_lparen | T_ident _)) :: _ ->
          let sub, rest = pattern rest in
          mkp pos (Ast.P_constr (name, Some sub)), rest
        | _ ->
          mkp pos (Ast.P_constr (name, None)), rest
      end
    | (pos, T_ident name) :: rest -> mkp pos (Ast.P_var name), rest
    | _ -> raise (Parse_error (pos_of toks, "expected pattern"))
  and logic_or toks =
    (* || is left-associative *)
    let lhs, toks = logic_and toks in
    let rec loop lhs toks =
      match toks with
      | (pos, T_pipe_pipe) :: rest ->
        let rhs, toks = logic_and rest in
        loop (mk pos (Ast.Logic (Ast.Or, lhs, rhs))) toks
      | _ -> lhs, toks
    in
    loop lhs toks
  and logic_and toks =
    let lhs, toks = cmp toks in
    let rec loop lhs toks =
      match toks with
      | (pos, T_amp_amp) :: rest ->
        let rhs, toks = cmp rest in
        loop (mk pos (Ast.Logic (Ast.And, lhs, rhs))) toks
      | _ -> lhs, toks
    in
    loop lhs toks
  and cmp toks =
    let lhs, toks = sum toks in
    let cmp_op = function
      | T_eq_eq -> Some Ast.Eq
      | T_bang_eq -> Some Ast.Ne
      | T_lt -> Some Ast.Lt
      | T_lt_eq -> Some Ast.Le
      | T_gt -> Some Ast.Gt
      | T_gt_eq -> Some Ast.Ge
      | _ -> None
    in
    match toks with
    | (pos, tk) :: rest ->
      (match cmp_op tk with
       | Some op ->
         let rhs, toks = sum rest in
         mk pos (Ast.Cmp (op, lhs, rhs)), toks
       | None -> lhs, toks)
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
    | (pos, T_slash) :: rest ->
      let rhs, toks = factor rest in
      term_tail (mk pos (Ast.Bin (Ast.Div, lhs, rhs))) toks
    | (pos, T_percent) :: rest ->
      let rhs, toks = factor rest in
      term_tail (mk pos (Ast.Bin (Ast.Mod, lhs, rhs))) toks
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
    | (_, (T_int _ | T_float _ | T_string _ | T_ident _ | T_lparen
          | T_true | T_false | T_lbracket | T_lbrace)) :: _ ->
      let arg, toks = atom toks in
      apply_tail (mk f.Ast.loc (Ast.App (f, arg))) toks
    | _ -> f, toks
  and atom toks =
    let v, rest = atom_base toks in
    (* Postfix `.field` chain — left-associative.  p.x.y = Field_get(Field_get(p, x), y).
       Special case: `R.alloc(expr)` where R is a lexically-enclosing region
       desugars to `&R expr`. *)
    let rec field_chain v toks =
      (* Region names are uppercase identifiers and the parser turns them
         into nullary Constr nodes; some toolings (or future relaxations)
         may yield Var instead. Accept both shapes. *)
      let region_name_of_atom =
        match v.Ast.node with
        | Ast.Var n | Ast.Constr (n, None)
          when List.mem n !region_stack -> Some n
        | _ -> None
      in
      match toks with
      | (pos, T_dot) :: (_, T_ident "alloc") :: (_, T_lparen) :: rest
        when region_name_of_atom <> None ->
        let region_name = match region_name_of_atom with Some n -> n | None -> assert false in
        let inner, rest = expr rest in
        (match rest with
         | (_, T_rparen) :: rest2 ->
           field_chain (mk pos (Ast.Ref (region_name, inner))) rest2
         | _ ->
           raise (Parse_error (pos_of rest,
             "expected ')' after region.alloc argument")))
      | (pos, T_dot) :: (_, T_ident f) :: rest ->
        (* Module-qualified name? If the lhs is a bare `Var "M"` and `M`
           is in `module_names`, treat `M.f` as a single qualified Var
           (and absorb the chain start so subsequent `.` continue as
           field access on the resolved value). *)
        let qualified =
          match v.Ast.node with
          | Ast.Var n when Hashtbl.mem module_names n ->
            Some n
          | _ -> None
        in
        (match qualified with
         | Some m ->
           field_chain (mk pos (Ast.Var (m ^ "." ^ f))) rest
         | None ->
           field_chain (mk pos (Ast.Field_get (v, f))) rest)
      | _ -> v, toks
    in
    field_chain v rest
  and atom_base toks =
    match toks with
    | (pos, T_amp) :: (_, T_ident region) :: rest ->
      (* `&R v` — value-level reference: tag v with region R *)
      let inner, rest = atom rest in
      mk pos (Ast.Ref (region, inner)), rest
    | (pos, T_lbrace) :: (_, T_rbrace) :: rest ->
      (* `{}` is the empty block — evaluates to unit. *)
      mk pos Ast.Unit_lit, rest
    | (pos, T_lbrace) :: rest ->
      (* Two forms share `{ expr ...`:
         - Block: `{ e1; e2; ...; eN }`  -> Let(P_wild) chain
         - Record update: `{ base | f1 = e1, f2 = e2 }`  -> Record_update *)
      let first, toks = expr rest in
      (match toks with
       | (_, T_pipe) :: rest ->
         (* Record update *)
         let rec parse_updates acc toks =
           match toks with
           | (_, T_ident fname) :: (_, T_eq) :: rest ->
             let e, rest = expr rest in
             let acc = (fname, e) :: acc in
             (match rest with
              | (_, T_comma) :: rest -> parse_updates acc rest
              | (_, T_rbrace) :: rest -> List.rev acc, rest
              | _ ->
                raise (Parse_error (pos_of rest,
                  "expected ',' or '}' in record update")))
           | _ ->
             raise (Parse_error (pos_of toks,
               "expected 'field = expr' in record update"))
         in
         let updates, rest = parse_updates [] rest in
         mk pos (Ast.Record_update (first, updates)), rest
       | _ ->
         (* Block expression *)
         let rec parse_rest acc toks =
           match toks with
           | (_, T_semi) :: (_, T_rbrace) :: rest ->
             List.rev acc, rest
           | (_, T_semi) :: rest ->
             let e, toks = expr rest in
             parse_rest (e :: acc) toks
           | (_, T_rbrace) :: rest ->
             List.rev acc, rest
           | _ ->
             raise (Parse_error (pos_of toks,
               "expected ';' or '}' in block"))
         in
         let exprs, rest = parse_rest [first] toks in
         let result =
           match List.rev exprs with
           | [] -> mk pos Ast.Unit_lit
           | last :: prev_rev ->
             let wild = mkp pos Ast.P_wild in
             List.fold_left (fun acc e ->
               mk pos (Ast.Let (wild, e, acc))
             ) last prev_rev
         in
         result, rest)
    | (pos, T_lbracket) :: (_, T_rbracket) :: rest ->
      (* `[]` desugars to Nil *)
      mk pos (Ast.Constr ("Nil", None)), rest
    | (pos, T_lbracket) :: rest ->
      (* `[e1, e2, ...]` desugars to Cons (e1, Cons (e2, ... Nil)) *)
      let rec parse_elems acc toks =
        let e, toks = expr toks in
        let acc = e :: acc in
        match toks with
        | (_, T_comma) :: rest -> parse_elems acc rest
        | (_, T_rbracket) :: rest -> List.rev acc, rest
        | _ -> raise (Parse_error (pos_of toks, "expected ',' or ']' in list literal"))
      in
      let elems, rest = parse_elems [] rest in
      let nil = mk pos (Ast.Constr ("Nil", None)) in
      let result = List.fold_right (fun e acc ->
        mk pos (Ast.Constr ("Cons", Some (mk pos (Ast.Tuple [e; acc]))))
      ) elems nil in
      result, rest
    | (pos, T_int n) :: rest -> mk pos (Ast.Int_lit n), rest
    | (pos, T_float f) :: rest -> mk pos (Ast.Float_lit f), rest
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
      (* Module-qualified access:  `M.foo` — return Var so field_chain
         picks up the `.` and forms a single qualified name. *)
      if Hashtbl.mem module_names name then
        mk pos (Ast.Var name), rest
      (* Record literal:  Name { f1 = e1, f2 = e2, ... } *)
      else if Hashtbl.mem records name then begin
        match rest with
        | (_, T_lbrace) :: body_rest ->
          let rec parse_fields acc toks =
            match toks with
            | (_, T_rbrace) :: rest -> List.rev acc, rest
            | (_, T_ident fname) :: (_, T_eq) :: rest ->
              let e, rest = expr rest in
              let acc = (fname, e) :: acc in
              (match rest with
               | (_, T_comma) :: rest -> parse_fields acc rest
               | (_, T_rbrace) :: rest -> List.rev acc, rest
               | _ ->
                 raise (Parse_error (pos_of rest,
                   "expected ',' or '}' in record literal")))
            | _ ->
              raise (Parse_error (pos_of toks,
                "expected 'field = expr' in record literal"))
          in
          let fields, rest = parse_fields [] body_rest in
          mk pos (Ast.Record_lit (name, fields)), rest
        | _ ->
          raise (Parse_error (pos, "expected '{' for record literal"))
      end else
        let arity = match lookup_constr name with Some a -> a | None -> 0 in
        if arity = 0 then
          mk pos (Ast.Constr (name, None)), rest
        else begin
          match rest with
          | (_, (T_int _ | T_float _ | T_string _ | T_ident _ | T_lparen
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
  (* Parse type params: optional `'a` or `('a, 'b, ...)` before the type name. *)
  let parse_type_params toks =
    match toks with
    | (_, T_lparen) :: (_, T_tyvar n1) :: rest ->
      let rec collect acc toks =
        match toks with
        | (_, T_comma) :: (_, T_tyvar n) :: rest -> collect (n :: acc) rest
        | (_, T_rparen) :: rest -> List.rev acc, rest
        | _ ->
          raise (Parse_error (pos_of toks,
            "expected ',' or ')' in type parameter list"))
      in
      collect [n1] rest
    | (_, T_tyvar name) :: rest -> [name], rest
    | _ -> [], toks
  in
  let parse_signature_params toks =
    (* (name: ty, name: ty, ...)   all annotations required *)
    match toks with
    | (_, T_lparen) :: rest ->
      let rec loop acc toks =
        match toks with
        | (_, T_rparen) :: rest -> List.rev acc, rest
        | (_, T_ident name) :: (_, T_colon) :: rest ->
          let t, rest = ty rest in
          let acc = (name, t) :: acc in
          (match rest with
           | (_, T_comma) :: rest -> loop acc rest
           | (_, T_rparen) :: rest -> List.rev acc, rest
           | _ ->
             raise (Parse_error (pos_of rest,
               "expected ',' or ')' in signature param list")))
        | _ ->
          raise (Parse_error (pos_of toks,
            "expected typed parameter (name: type) in signature"))
      in
      loop [] rest
    | _ ->
      raise (Parse_error (pos_of toks, "expected '(' after signature name"))
  in
  (* Parse a `module M { ... }` body. Only `let` / `let rec` decls are
     accepted in slice 1 — type/record/etc. at module scope is a
     future enhancement. Terminates at the matching `T_rbrace`. *)
  let rec parse_module_body decls toks =
    match toks with
    | (_, T_rbrace) :: rest -> List.rev decls, rest
    | (pos, T_let) :: (_, T_rec) :: (_, T_ident name) :: (_, T_eq) :: rest ->
      let value, toks = expr rest in
      let rec parse_more acc toks =
        match toks with
        | (_, T_and) :: (_, T_ident n) :: (_, T_eq) :: rest ->
          let v, toks = expr rest in
          parse_more ((n, v) :: acc) toks
        | _ -> List.rev acc, toks
      in
      let more, toks = parse_more [] toks in
      let bindings = (name, value) :: more in
      let _ = pos in
      (match toks with
       | (_, T_semi) :: rest ->
         parse_module_body (Ast.Top_let_rec bindings :: decls) rest
       | _ ->
         raise (Parse_error (pos_of toks,
           "expected ';' after let rec in module body")))
    | (pos, T_let) :: rest_after_let ->
      let _ = pos in
      let pat, rest = pattern rest_after_let in
      (match rest with
       | (_, T_eq) :: rest ->
         let value, rest = expr rest in
         (match rest with
          | (_, T_semi) :: rest ->
            parse_module_body (Ast.Top_let (pat, value) :: decls) rest
          | _ ->
            raise (Parse_error (pos_of rest,
              "expected ';' after let in module body")))
       | _ ->
         raise (Parse_error (pos_of rest, "expected '=' after let pattern")))
    | (pos, _) :: _ ->
      raise (Parse_error (pos,
        "only `let` / `let rec` allowed in module body (slice 1)"))
    | [] ->
      raise (Parse_error (Loc.dummy, "unterminated module body"))
  in
  (* Collect bound names from a module's decls — used to compute the
     rename map for prefixing. *)
  let collect_module_names decls =
    List.concat_map (function
      | Ast.Top_let ({ pnode = Ast.P_var n; _ }, _) -> [n]
      | Ast.Top_let_rec bindings -> List.map fst bindings
      | _ -> []
    ) decls
  in
  (* Apply `M.` prefix to every bound name in the module's decls, AND
     rewrite free Var references that match those names so internal
     short-name refs (`foo` inside `M`) resolve to the exported form. *)
  let prefix_module_decls m_name decls =
    let names = collect_module_names decls in
    let rename = List.map (fun n -> (n, m_name ^ "." ^ n)) names in
    let lookup n = List.assoc_opt n rename in
    List.map (function
      | Ast.Top_let ({ pnode = Ast.P_var n; ploc }, value) ->
        let new_pat = { Ast.ploc; pnode = Ast.P_var (m_name ^ "." ^ n) } in
        let new_value = Ast.rename_free_vars lookup value in
        Ast.Top_let (new_pat, new_value)
      | Ast.Top_let_rec bindings ->
        let new_bindings = List.map (fun (n, v) ->
          (m_name ^ "." ^ n, Ast.rename_free_vars lookup v)
        ) bindings in
        Ast.Top_let_rec new_bindings
      | d -> d
    ) decls
  in
  let rec parse_decls decls toks =
    match toks with
    | (pos, T_import) :: (_, T_string path) :: (_, T_semi) :: rest ->
      (* `import "path";` — read the file, recursively parse its decls,
         and splice them into the current decl stream. Skip if the
         same path has been imported already (cycle guard). Parser
         registries (constructors, records, module_names, aliases) are
         shared across the recursive call, so imported types are
         visible to the importer. *)
      let _ = pos in
      if Hashtbl.mem imported_files path then
        parse_decls decls rest
      else begin
        Hashtbl.replace imported_files path ();
        let source =
          try In_channel.with_open_text path In_channel.input_all
          with Sys_error msg ->
            raise (Parse_error (pos, "import: " ^ msg))
        in
        let toks_imp = Lexer.tokenize source in
        let prog_imp = parse_program_internal toks_imp in
        (* Imported file's main expression is discarded (decls-only is
           the recommended form). We prepend its decls newest-first so
           the final List.rev yields the correct source order. *)
        let decls' = List.rev_append prog_imp.Ast.decls decls in
        parse_decls decls' rest
      end
    | (pos, T_import) :: _ ->
      raise (Parse_error (pos, "expected `import \"path\";`"))
    | (pos, T_module) :: (_, T_ident m_name) :: (_, T_lbrace) :: rest ->
      (* Register the module name BEFORE parsing the body so qualified
         self-references like `M.foo` inside the module resolve
         correctly via `field_chain`. *)
      Hashtbl.replace module_names m_name ();
      let body, rest = parse_module_body [] rest in
      let prefixed = prefix_module_decls m_name body in
      (* `decls` accumulates newest-first; `prefixed` is in source order.
         Prepend each prefixed decl so the final List.rev yields the
         correct source order. *)
      let decls' = List.rev_append prefixed decls in
      (* Optional trailing `;` for visual consistency with other decls. *)
      let rest =
        match rest with
        | (_, T_semi) :: r -> r
        | _ -> rest
      in
      let _ = pos in
      parse_decls decls' rest
    | (pos, T_module) :: _ ->
      raise (Parse_error (pos, "expected `NAME { decls }` after `module`"))
    | (pos, T_drop) :: ((_, T_type) :: rest_after_type as after_drop) ->
      (* `drop type Name = ...` marks Name as having Drop semantics.
         We extract the name via look-ahead and prepend `Top_drop name`
         to the decl list, then let the existing `type` parser produce
         the actual declaration. *)
      let _, after_params = parse_type_params rest_after_type in
      let name =
        match after_params with
        | (_, T_ident n) :: _ -> n
        | _ ->
          raise (Parse_error (pos,
            "expected type name after `drop type`"))
      in
      parse_decls (Ast.Top_drop name :: decls) after_drop
    | (pos, T_drop) :: _ ->
      raise (Parse_error (pos,
        "expected `type` after `drop`"))
    | (_, T_signature) :: (_, T_ident name) :: (_, T_eq) :: rest ->
      let params, toks = parse_signature_params rest in
      Hashtbl.replace signatures name params;
      (match toks with
       | (_, T_semi) :: rest ->
         parse_decls (Ast.Top_signature (name, params) :: decls) rest
       | _ ->
         raise (Parse_error (pos_of toks,
           "expected ';' after signature declaration")))
    | (pos, T_signature) :: _ ->
      raise (Parse_error (pos, "expected 'name = (params)' after 'signature'"))
    | (pos, T_view) :: (_, T_ident view_name) :: (_, T_lbracket)
      :: (_, T_ident region_param) :: (_, T_rbracket) :: rest ->
      (* `view V[R] of T { fields };` or `view V[R] { fields };` (no `of T`) *)
      let rest =
        match rest with
        | (_, T_of) :: rest ->
          (* Parse and discard `of T` — Phase 2.2 doesn't enforce this yet. *)
          let _, rest = ty rest in
          rest
        | _ -> rest
      in
      (match rest with
       | (_, T_lbrace) :: body_rest ->
         let rec parse_fields acc toks =
           match toks with
           | (_, T_rbrace) :: rest -> List.rev acc, rest
           | (_, T_ident fname) :: (_, T_colon) :: rest ->
             let t, rest = ty rest in
             let acc = (fname, t) :: acc in
             (match rest with
              | (_, T_comma) :: rest -> parse_fields acc rest
              | (_, T_rbrace) :: rest -> List.rev acc, rest
              | _ ->
                raise (Parse_error (pos_of rest,
                  "expected ',' or '}' in view fields")))
           | _ ->
             raise (Parse_error (pos_of toks,
               "expected 'field: type' in view body"))
         in
         let fields, toks = parse_fields [] body_rest in
         Hashtbl.replace records view_name fields;
         (match toks with
          | (_, T_semi) :: rest ->
            parse_decls
              (Ast.Top_view (view_name, region_param, fields) :: decls)
              rest
          | _ ->
            raise (Parse_error (pos_of toks,
              "expected ';' after view declaration")))
       | _ -> raise (Parse_error (pos, "expected '{' to start view body")))
    | (pos, T_view) :: _ ->
      raise (Parse_error (pos,
        "expected 'NAME [R] (of T)? { fields }' after 'view'"))
    | (_, T_type) :: rest ->
      let params, rest = parse_type_params rest in
      (match rest with
       | (_, T_ident type_name) :: (_, T_eq) :: (_, T_lbrace) :: body_rest ->
         (* Record type: type Name = { f1: T1, f2: T2, ... }; *)
         let rec parse_fields acc toks =
           match toks with
           | (_, T_rbrace) :: rest -> List.rev acc, rest
           | (_, T_ident fname) :: (_, T_colon) :: rest ->
             let t, rest = ty rest in
             let acc = (fname, t) :: acc in
             (match rest with
              | (_, T_comma) :: rest -> parse_fields acc rest
              | (_, T_rbrace) :: rest -> List.rev acc, rest
              | _ ->
                raise (Parse_error (pos_of rest,
                  "expected ',' or '}' in record fields")))
           | _ ->
             raise (Parse_error (pos_of toks,
               "expected 'field: type' in record body"))
         in
         let fields, toks = parse_fields [] body_rest in
         Hashtbl.replace records type_name fields;
         (match toks with
          | (_, T_semi) :: rest ->
            parse_decls (Ast.Top_record (type_name, params, fields) :: decls) rest
          | _ ->
            raise (Parse_error (pos_of toks, "expected ';' after record declaration")))
       | (_, T_ident type_name) :: (_, T_eq) :: body_rest ->
         (* Disambiguate: variant body starts with capitalized ident or `|`;
            anything else is a type alias. *)
         (* Variant body markers:
            - leading `|` (`type X = | A | B`)
            - capitalized ident followed by `|` (`type X = A | B`)
            - capitalized ident followed by `of` (`type X = A of int`)
            Otherwise treat as type alias (capitalized refs to records or
            multi-arg-applied types still resolve via aliases / TyCon). *)
         let is_variant_body =
           match body_rest with
           | (_, T_pipe) :: _ -> true
           | (_, T_ident n) :: (_, (T_pipe | T_of)) :: _ when starts_with_upper n -> true
           | _ -> false
         in
         if is_variant_body then
           let variants, toks = parse_variants body_rest in
           List.iter (fun (cname, payload) ->
             Hashtbl.replace constructors cname (match payload with None -> 0 | _ -> 1)
           ) variants;
           (match toks with
            | (_, T_semi) :: rest ->
              parse_decls (Ast.Top_type (type_name, params, variants) :: decls) rest
            | _ ->
              raise (Parse_error (pos_of toks, "expected ';' after type declaration")))
         else
           (* Type alias: `type Name = T;` *)
           let body, toks = ty body_rest in
           Hashtbl.replace aliases type_name (params, body);
           (match toks with
            | (_, T_semi) :: rest ->
              parse_decls (Ast.Top_type_alias (type_name, params, body) :: decls) rest
            | _ ->
              raise (Parse_error (pos_of toks, "expected ';' after type alias")))
       | _ ->
         raise (Parse_error (pos_of rest, "expected 'ident = ...' after 'type'")))
    | (pos, T_let) :: (_, T_rec) :: (_, T_ident name) :: (_, T_eq) :: rest ->
      let value, toks = expr rest in
      let rec parse_more acc toks =
        match toks with
        | (_, T_and) :: (_, T_ident n) :: (_, T_eq) :: rest ->
          let v, toks = expr rest in
          parse_more ((n, v) :: acc) toks
        | _ -> List.rev acc, toks
      in
      let more, toks = parse_more [] toks in
      let bindings = (name, value) :: more in
      (match toks with
       | (_, T_semi) :: rest ->
         parse_decls (Ast.Top_let_rec bindings :: decls) rest
       | (_, T_in) :: rest ->
         let body, toks = expr rest in
         let main = mk pos (Ast.Let_rec (bindings, body)) in
         finish decls main toks
       | _ ->
         raise (Parse_error (pos_of toks, "expected ';' or 'in' after let rec binding")))
    | (pos, T_let) :: (_, T_rec) :: _ ->
      raise (Parse_error (pos, "expected 'ident = expr' after 'let rec'"))
    | (pos, T_let) :: rest_after_let ->
      (* Parse the pattern (P_var, P_wild, P_tuple, P_unit, P_record, ...). *)
      let pat, rest = pattern rest_after_let in
      (match rest with
       | (_, T_eq) :: rest ->
         let value, rest = expr rest in
         (match rest with
          | (_, T_semi) :: rest ->
            parse_decls (Ast.Top_let (pat, value) :: decls) rest
          | (_, T_in) :: rest ->
            let body, rest = expr rest in
            let main = mk pos (Ast.Let (pat, value, body)) in
            finish decls main rest
          | _ ->
            raise (Parse_error (pos_of rest, "expected ';' or 'in' after let binding")))
       | _ ->
         raise (Parse_error (pos_of rest, "expected '=' after let pattern")))
    | [(pos, T_eof)] ->
      (* Decls-only program (no trailing main expression). Synthesize
         `()` as the main so the typer / eval pipeline still has
         something to chew on. *)
      finish decls (mk pos Ast.Unit_lit) toks
    | _ ->
      let main, toks = expr toks in
      finish decls main toks
  in
  parse_decls [] tokens

(* Public entry-point: clear the per-program import accumulator, then
   delegate to the recursive worker. Inside the worker, `import` calls
   `parse_program_internal` directly so the cycle guard survives the
   recursion. *)
let parse_program tokens =
  Hashtbl.reset imported_files;
  parse_program_internal tokens

let parse tokens =
  let prog = parse_program tokens in
  match prog.decls with
  | [] -> prog.main
  | _ ->
    raise (Parse_error (Loc.dummy,
      "this parser entry-point does not accept top-level decls; use parse_program"))
