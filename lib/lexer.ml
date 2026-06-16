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
  | T_match
  | T_with
  | T_when            (* when — match guard *)
  | T_of
  | T_as              (* as — as-pattern: `| pat as name -> body` *)
  | T_underscore
  | T_ellipsis        (* ... — for spreading signature params *)
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

let tokenize s =
  let len = String.length s in
  let line = ref 1 in
  let col = ref 1 in
  let here () = Loc.{ line = !line; col = !col } in
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
      | '<' -> advance 1; aux (i + 1) ((pos, T_lt) :: acc)
      | '>' when i + 1 < len && s.[i + 1] = '=' ->
        advance 2; aux (i + 2) ((pos, T_gt_eq) :: acc)
      | '>' when i + 1 < len && s.[i + 1] = '>' ->
        advance 2; aux (i + 2) ((pos, T_gt_gt) :: acc)
      | '>' -> advance 1; aux (i + 1) ((pos, T_gt) :: acc)
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
      | '\'' ->
        (* Disambiguate single-quote between two forms:
           - char literal: 'X' (3 chars) or '\X' (4 chars, escape)
             -> emit T_string of length 1 (Lang has no separate char type)
           - tyvar: 'name (letter-start identifier, no closing quote)
             -> emit T_tyvar
           The char form requires the closing `'` at a specific offset. *)
        if i + 3 < len && s.[i + 1] = '\\' && s.[i + 3] = '\'' then begin
          let actual = match s.[i + 2] with
            | 'n' -> '\n' | 't' -> '\t' | '\\' -> '\\'
            | '\'' -> '\'' | '"' -> '"'
            | c -> raise (Lex_error (pos,
                Printf.sprintf "unknown escape in char literal: '\\%c'" c))
          in
          advance 4;
          aux (i + 4) ((pos, T_string (String.make 1 actual)) :: acc)
        end
        else if i + 2 < len && s.[i + 1] <> '\\' && s.[i + 2] = '\'' then begin
          (* `'X'` where X is any single char other than `\` (escapes handled
             above) and `'` (we don't allow an empty literal). *)
          let c = s.[i + 1] in
          advance 3;
          aux (i + 3) ((pos, T_string (String.make 1 c)) :: acc)
        end
        else if i + 1 < len && is_alpha s.[i + 1] then begin
          let rec read j =
            if j < len && is_ident_cont s.[j] then read (j + 1) else j
          in
          let j = read (i + 1) in
          let name = String.sub s (i + 1) (j - i - 1) in
          advance (j - i);
          aux j ((pos, T_tyvar name) :: acc)
        end
        else
          raise (Lex_error (pos, "unexpected '"))
      | '"' ->
        let buf = Buffer.create 16 in
        let rec read j =
          if j >= len then
            raise (Lex_error (pos, "unterminated string literal"))
          else
            let c = s.[j] in
            match c with
            | '"' -> j + 1
            | '\\' when j + 1 < len ->
              let esc = s.[j + 1] in
              let actual = match esc with
                | 'n' -> '\n'
                | 't' -> '\t'
                | '\\' -> '\\'
                | '"' -> '"'
                | _ ->
                  raise (Lex_error (pos,
                    Printf.sprintf "unknown escape: \\%c" esc))
              in
              Buffer.add_char buf actual;
              read (j + 2)
            | '\n' ->
              raise (Lex_error (pos, "newline in string literal"))
            | c ->
              Buffer.add_char buf c;
              read (j + 1)
        in
        let j = read (i + 1) in
        let str = Buffer.contents buf in
        advance (j - i);
        aux j ((pos, T_string str) :: acc)
      | c when is_digit c ->
        let rec read j =
          if j < len && is_digit s.[j] then read (j + 1) else j
        in
        let j = read i in
        (* Float literal: `digits.digits`.  Bare `1.` is NOT a float
           (would conflict with `.field` access on a future int).  *)
        if j + 1 < len && s.[j] = '.' && is_digit s.[j + 1] then begin
          let k = read (j + 1) in
          let text = String.sub s i (k - i) in
          advance (k - i);
          aux k ((pos, T_float (float_of_string text)) :: acc)
        end else begin
          let n = int_of_string (String.sub s i (j - i)) in
          advance (j - i);
          aux j ((pos, T_int n) :: acc)
        end
      | c when is_alpha c ->
        let rec read j =
          if j < len && is_ident_cont s.[j] then read (j + 1) else j
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
          | "true" -> T_true
          | "false" -> T_false
          | "fn" -> T_fn
          | "type" -> T_type
          | "signature" -> T_signature
          | "match" -> T_match
          | "with" -> T_with
          | "when" -> T_when
          | "of" -> T_of
          | "as" -> T_as
          | "_" -> T_underscore
          | _ -> T_ident word
        in
        advance (j - i);
        aux j ((pos, tok) :: acc)
      | _ ->
        raise (Lex_error (pos, Printf.sprintf "unexpected '%c'" c))
  in
  aux 0 []
