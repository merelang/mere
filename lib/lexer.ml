(* Tokenizer. *)

exception Lex_error of Loc.t * string

type token =
  | T_int of int
  | T_float of float
  | T_string of string
  | T_ident of string
  | T_tyvar of string         (* 'a, 'b, ... *)
  | T_let
  | T_rec
  | T_and             (* and — for mutual recursion *)
  | T_in
  | T_if
  | T_then
  | T_else
  | T_true
  | T_false
  | T_fn
  | T_type
  | T_signature       (* signature keyword *)
  | T_region          (* region keyword *)
  | T_view            (* view keyword (for view-type declarations) *)
  | T_drop            (* drop keyword (Drop type marker for Trivial[R] check) *)
  | T_using           (* using keyword (capability list sugar for fn params) *)
  | T_module          (* module keyword (top-level module declarations) *)
  | T_import          (* import keyword (load decls from another file) *)
  | T_open            (* open keyword (bring module bindings into scope) *)
  | T_extern          (* extern keyword (FFI declaration: `extern fn name: ty;`、Phase 32) *)
  | T_amp             (* &  reference type prefix: `&R T` *)
  | T_match
  | T_with
  | T_when            (* when — match guard *)
  | T_of
  | T_as              (* as — as-pattern: `| pat as name -> body` *)
  | T_underscore
  | T_ellipsis        (* ... — for spreading signature params *)
  | T_dotdot          (* .. — range literal (Phase 36) *)
  | T_colon_colon     (* :: — list cons (Phase 36) *)
  | T_lt_pipe         (* <| — reverse function application (Phase 36) *)
  | T_backslash       (* \  — lambda shorthand `\x -> body` (Phase 36) *)
  | T_at_at           (* @@ — low-precedence application (Phase 36) *)
  | T_question        (* ?  — Option early-return (`let x = e? in body`) (Phase 36) *)
  | T_question_bang   (* ?! — Result early-return (`let x = e?! in body`) (Phase 36) *)
  | T_lt_minus        (* <- — list comprehension generator `[e | x <- xs]` (Phase 36) *)
  | T_for             (* for — `for x in xs do body` (Phase 36) *)
  | T_do              (* do  — same *)
  | T_while           (* while — `while cond do body` (Phase 36) *)
  | T_arrow
  | T_eq
  | T_eq_eq
  | T_bang_eq          (* != *)
  | T_lt
  | T_lt_eq            (* <= *)
  | T_gt               (* > *)
  | T_gt_eq            (* >= *)
  | T_colon
  | T_semi
  | T_comma
  | T_pipe
  | T_pipe_pipe        (* || *)
  | T_pipe_gt          (* |>  pipe operator *)
  | T_lt_lt            (* <<  function composition (compose-right-to-left) *)
  | T_gt_gt            (* >>  function composition (compose-left-to-right) *)
  | T_amp_amp          (* && *)
  | T_plus
  | T_plus_plus
  | T_minus
  | T_star
  | T_slash            (* / *)
  | T_percent          (* % *)
  | T_lparen
  | T_rparen
  | T_lbrace            (* { *)
  | T_rbrace            (* } *)
  | T_lbracket          (* [ *)
  | T_rbracket          (* ] *)
  | T_dot               (* . — field access *)
  | T_eof

let is_digit c = c >= '0' && c <= '9'
let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
let is_ident_cont c = is_alpha c || is_digit c

let rec tokenize s =
  let len = String.length s in
  let line = ref 1 in
  let col = ref 1 in
  let here () = Loc.mk ~line:(!line) ~col:(!col) () in
  let with_width (pos : Loc.t) (w : int) : Loc.t = { pos with width = w } in
  let advance n = col := !col + n in
  let newline () =
    incr line;
    col := 1
  in
  let rec aux i acc =
    if i >= len then List.rev ((here (), T_eof) :: acc)
    else
      let pos = here () in
      let c = s.[i] in
      match c with
      | ' ' | '\t' -> advance 1; aux (i + 1) acc
      | '\n' -> newline (); aux (i + 1) acc
      | '/' when i + 1 < len && s.[i + 1] = '/' ->
        let rec skip j =
          if j >= len || s.[j] = '\n' then j else skip (j + 1)
        in
        let j = skip (i + 2) in
        advance (j - i);
        aux j acc
      | '.' when i + 2 < len && s.[i + 1] = '.' && s.[i + 2] = '.' ->
        advance 3; aux (i + 3) ((pos, T_ellipsis) :: acc)
      | '.' when i + 1 < len && s.[i + 1] = '.' ->
        (* Phase 36: `..` for range literals (e.g. `1..10`). *)
        advance 2; aux (i + 2) ((pos, T_dotdot) :: acc)
      | '/' -> advance 1; aux (i + 1) ((pos, T_slash) :: acc)
      | '%' -> advance 1; aux (i + 1) ((pos, T_percent) :: acc)
      | '+' when i + 1 < len && s.[i + 1] = '+' ->
        advance 2; aux (i + 2) ((pos, T_plus_plus) :: acc)
      | '+' -> advance 1; aux (i + 1) ((pos, T_plus) :: acc)
      | '-' when i + 1 < len && s.[i + 1] = '>' ->
        advance 2; aux (i + 2) ((pos, T_arrow) :: acc)
      | '-' -> advance 1; aux (i + 1) ((pos, T_minus) :: acc)
      | '*' -> advance 1; aux (i + 1) ((pos, T_star) :: acc)
      | '(' -> advance 1; aux (i + 1) ((pos, T_lparen) :: acc)
      | ')' -> advance 1; aux (i + 1) ((pos, T_rparen) :: acc)
      | '{' -> advance 1; aux (i + 1) ((pos, T_lbrace) :: acc)
      | '}' -> advance 1; aux (i + 1) ((pos, T_rbrace) :: acc)
      | '[' -> advance 1; aux (i + 1) ((pos, T_lbracket) :: acc)
      | ']' -> advance 1; aux (i + 1) ((pos, T_rbracket) :: acc)
      (* Phase 36: lambda shorthand `\x -> body` (Haskell-style). *)
      | '\\' -> advance 1; aux (i + 1) ((pos, T_backslash) :: acc)
      (* Phase 36: `@@` low-precedence application (OCaml-style, alias of `<|`). *)
      | '@' when i + 1 < len && s.[i + 1] = '@' ->
        advance 2; aux (i + 2) ((pos, T_at_at) :: acc)
      (* Phase 36: `?` for Option early-return (`let x = expr? in body`).
         `?!` for Result early-return. *)
      | '?' when i + 1 < len && s.[i + 1] = '!' ->
        advance 2; aux (i + 2) ((pos, T_question_bang) :: acc)
      | '?' -> advance 1; aux (i + 1) ((pos, T_question) :: acc)
      | '.' -> advance 1; aux (i + 1) ((pos, T_dot) :: acc)
      | '=' when i + 1 < len && s.[i + 1] = '=' ->
        advance 2; aux (i + 2) ((pos, T_eq_eq) :: acc)
      | '=' -> advance 1; aux (i + 1) ((pos, T_eq) :: acc)
      | '!' when i + 1 < len && s.[i + 1] = '=' ->
        advance 2; aux (i + 2) ((pos, T_bang_eq) :: acc)
      | '<' when i + 1 < len && s.[i + 1] = '=' ->
        advance 2; aux (i + 2) ((pos, T_lt_eq) :: acc)
      | '<' when i + 1 < len && s.[i + 1] = '<' ->
        advance 2; aux (i + 2) ((pos, T_lt_lt) :: acc)
      | '<' when i + 1 < len && s.[i + 1] = '|' ->
        (* Phase 36: `<|` reverse function application. *)
        advance 2; aux (i + 2) ((pos, T_lt_pipe) :: acc)
      | '<' when i + 1 < len && s.[i + 1] = '-' ->
        (* Phase 36: `<-` generator arrow for list comprehension. *)
        advance 2; aux (i + 2) ((pos, T_lt_minus) :: acc)
      | '<' -> advance 1; aux (i + 1) ((pos, T_lt) :: acc)
      | '>' when i + 1 < len && s.[i + 1] = '=' ->
        advance 2; aux (i + 2) ((pos, T_gt_eq) :: acc)
      | '>' when i + 1 < len && s.[i + 1] = '>' ->
        advance 2; aux (i + 2) ((pos, T_gt_gt) :: acc)
      | '>' -> advance 1; aux (i + 1) ((pos, T_gt) :: acc)
      | ':' when i + 1 < len && s.[i + 1] = ':' ->
        (* Phase 36: `::` cons operator for list construction. *)
        advance 2; aux (i + 2) ((pos, T_colon_colon) :: acc)
      | ':' -> advance 1; aux (i + 1) ((pos, T_colon) :: acc)
      | ';' -> advance 1; aux (i + 1) ((pos, T_semi) :: acc)
      | ',' -> advance 1; aux (i + 1) ((pos, T_comma) :: acc)
      | '|' when i + 1 < len && s.[i + 1] = '|' ->
        advance 2; aux (i + 2) ((pos, T_pipe_pipe) :: acc)
      | '|' when i + 1 < len && s.[i + 1] = '>' ->
        advance 2; aux (i + 2) ((pos, T_pipe_gt) :: acc)
      | '|' -> advance 1; aux (i + 1) ((pos, T_pipe) :: acc)
      | '&' when i + 1 < len && s.[i + 1] = '&' ->
        advance 2; aux (i + 2) ((pos, T_amp_amp) :: acc)
      | '&' -> advance 1; aux (i + 1) ((pos, T_amp) :: acc)
      | '\'' ->
        (* Disambiguate single-quote between two forms:
           - char literal: 'X' (3 chars) or '\X' (4 chars, escape)
             -> emit T_string of length 1 (Lang has no separate char type)
           - tyvar: 'name (letter-start identifier, no closing quote)
             -> emit T_tyvar
           The char form requires the closing `'` at a specific offset. *)
        if i + 3 < len && s.[i + 1] = '\\' && s.[i + 3] = '\'' then begin
          let actual = match s.[i + 2] with
            | 'n' -> '\n' | 't' -> '\t' | 'r' -> '\r' | '0' -> '\000'
            | '\\' -> '\\' | '\'' -> '\'' | '"' -> '"'
            | c -> raise (Lex_error (pos,
                Printf.sprintf "unknown escape in char literal: '\\%c'" c))
          in
          advance 4;
          aux (i + 4) ((with_width pos 4, T_string (String.make 1 actual)) :: acc)
        end
        else if i + 2 < len && s.[i + 1] <> '\\' && s.[i + 2] = '\'' then begin
          let c = s.[i + 1] in
          advance 3;
          aux (i + 3) ((with_width pos 3, T_string (String.make 1 c)) :: acc)
        end
        else if i + 1 < len && is_alpha s.[i + 1] then begin
          let rec read j =
            if j < len && is_ident_cont s.[j] then read (j + 1) else j
          in
          let j = read (i + 1) in
          let name = String.sub s (i + 1) (j - i - 1) in
          let w = j - i in
          advance w;
          aux j ((with_width pos w, T_tyvar name) :: acc)
        end
        else
          raise (Lex_error (pos, "unexpected '"))
      | '"' ->
        (* Phase 36: string interpolation. `{expr}` inside a string literal
           splits it into multiple tokens forming a `prefix ++ (expr) ++ suffix`
           chain. Nested braces inside the expr are tracked by a depth
           counter. `\{` escapes the literal brace. *)
        let buf = Buffer.create 16 in
        let parts = ref [] in
        (* parts is in reverse order: finally pushed as T_string, or sandwiched
           with T_plus_plus for interpolation. *)
        let flush_lit () =
          let s_part = Buffer.contents buf in
          Buffer.clear buf;
          parts := `Lit s_part :: !parts
        in
        let rec read j =
          if j >= len then
            raise (Lex_error (pos, "unterminated string literal"))
          else
            let c = s.[j] in
            match c with
            | '"' -> j + 1
            | '\\' when j + 1 < len ->
              let esc = s.[j + 1] in
              (match esc with
                | '\n' ->
                  (* Line continuation: `\<newline>` eats the newline
                     itself plus any leading whitespace on the next
                     line, so a long string literal can break across
                     source lines without smuggling in newline / indent
                     characters. Matches the Python / Rust convention. *)
                  let rec skip_ws k =
                    if k >= len then k
                    else match s.[k] with
                      | ' ' | '\t' -> skip_ws (k + 1)
                      | _ -> k
                  in
                  read (skip_ws (j + 2))
                | _ ->
                  let actual = match esc with
                    | 'n' -> '\n'
                    | 't' -> '\t'
                    | 'r' -> '\r'
                    | '0' -> '\000'
                    | '\\' -> '\\'
                    | '"' -> '"'
                    | '{' -> '{'        (* escape interpolation *)
                    | _ ->
                      raise (Lex_error (pos,
                        Printf.sprintf "unknown escape: \\%c" esc))
                  in
                  Buffer.add_char buf actual;
                  read (j + 2))
            | '{' ->
              (* start interpolation: flush prefix, then find matching `}`
                 (skipping `{...}` nested groups). *)
              flush_lit ();
              let rec find_end k depth =
                if k >= len then
                  raise (Lex_error (pos, "unterminated `{...}` in string"))
                else if s.[k] = '{' then find_end (k + 1) (depth + 1)
                else if s.[k] = '}' then
                  if depth = 0 then k else find_end (k + 1) (depth - 1)
                else if s.[k] = '"' then
                  raise (Lex_error (pos,
                    "unexpected `\"` inside `{...}` string interpolation. \
                     If you intended a literal `{` (e.g. JSON / HTML / \
                     template syntax), escape it as `\\{` instead. \
                     If you intended interpolation with a nested string, \
                     bind it to a `let` first (Phase 36 MVP doesn't support \
                     nested string literals)."))
                else find_end (k + 1) depth
              in
              let end_brace = find_end (j + 1) 0 in
              let expr_src = String.sub s (j + 1) (end_brace - j - 1) in
              parts := `Expr expr_src :: !parts;
              read (end_brace + 1)
            | '\n' ->
              raise (Lex_error (pos, "newline in string literal"))
            | c ->
              Buffer.add_char buf c;
              read (j + 1)
        in
        let j = read (i + 1) in
        flush_lit ();
        let part_list = List.rev !parts in
        let w = j - i in
        advance w;
        let has_interp = List.exists (function `Expr _ -> true | _ -> false) part_list in
        if not has_interp then begin
          (* fast path: ordinary string literal *)
          let str = match part_list with [`Lit s] -> s | _ -> "" in
          aux j ((with_width pos w, T_string str) :: acc)
        end else begin
          (* Emit alternating T_string / (T_plus_plus T_lparen <tokens> T_rparen)
             chain. Skip empty leading/trailing lits. The whole chain becomes
             one expression at parse time. *)
          let lit_tokens s_lit = [(with_width pos w, T_string s_lit)] in
          let plus_plus_tok = (with_width pos w, T_plus_plus) in
          let lparen_tok = (with_width pos w, T_lparen) in
          let rparen_tok = (with_width pos w, T_rparen) in
          let strip_eof toks =
            (* The trailing T_eof from tokenize is dropped because it gets in the way of the outer stream. *)
            List.filter (fun (_, t) -> t <> T_eof) toks
          in
          let rec emit = function
            | [] -> []
            | [last] ->
              (match last with
               | `Lit s -> lit_tokens s
               | `Expr src ->
                 let inner = strip_eof (tokenize src) in
                 lparen_tok :: inner @ [rparen_tok])
            | first :: more ->
              let first_toks = match first with
                | `Lit s -> lit_tokens s
                | `Expr src ->
                  let inner = strip_eof (tokenize src) in
                  lparen_tok :: inner @ [rparen_tok]
              in
              first_toks @ (plus_plus_tok :: emit more)
          in
          (* Ensure we always start with a string literal so the chain is
             well-formed at the parser level (prefix can be ""). *)
          let part_list =
            match part_list with
            | `Expr _ :: _ -> `Lit "" :: part_list
            | _ -> part_list
          in
          let all_toks = emit part_list in
          (* Wrap whole interp result in parens so e.g. `"x" ++ "y"` doesn't
             eat into our concat chain. *)
          let wrapped = lparen_tok :: all_toks @ [rparen_tok] in
          let acc' = List.rev_append wrapped acc in
          aux j acc'
        end
      | c when is_digit c ->
        let rec read j =
          if j < len && is_digit s.[j] then read (j + 1) else j
        in
        let j = read i in
        if j + 1 < len && s.[j] = '.' && is_digit s.[j + 1] then begin
          let k = read (j + 1) in
          let text = String.sub s i (k - i) in
          let w = k - i in
          advance w;
          aux k ((with_width pos w, T_float (float_of_string text)) :: acc)
        end else begin
          let n = int_of_string (String.sub s i (j - i)) in
          let w = j - i in
          advance w;
          aux j ((with_width pos w, T_int n) :: acc)
        end
      | c when is_alpha c ->
        (* Allow ML-style primed identifiers (`arg'`, `x''`) — `'` is a
           continuation character only once the identifier has started
           with an alpha, so bare `'x'` / `'name` still lex as char /
           tyvar respectively. *)
        let rec read j =
          if j < len && (is_ident_cont s.[j] || s.[j] = '\'') then read (j + 1)
          else j
        in
        let j = read i in
        let word = String.sub s i (j - i) in
        let tok = match word with
          | "let" -> T_let
          | "rec" -> T_rec
          | "and" -> T_and
          | "in" -> T_in
          | "if" -> T_if
          | "then" -> T_then
          | "else" -> T_else
          | "for" -> T_for       (* Phase 36: `for x in xs do body` *)
          | "do" -> T_do
          | "while" -> T_while   (* Phase 36: `while cond do body` *)
          | "true" -> T_true
          | "false" -> T_false
          | "fn" -> T_fn
          | "type" -> T_type
          | "signature" -> T_signature
          | "region" -> T_region
          | "view" -> T_view
          | "drop" -> T_drop
          | "using" -> T_using
          | "module" -> T_module
          | "import" -> T_import
          | "open" -> T_open
          | "extern" -> T_extern
          | "match" -> T_match
          | "with" -> T_with
          | "when" -> T_when
          | "of" -> T_of
          | "as" -> T_as
          | "_" -> T_underscore
          | _ -> T_ident word
        in
        let w = j - i in
        advance w;
        aux j ((with_width pos w, tok) :: acc)
      | _ ->
        raise (Lex_error (pos, Printf.sprintf "unexpected '%c'" c))
  in
  aux 0 []
