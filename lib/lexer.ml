(* Tokenizer. *)

exception Lex_error of Loc.t * string

type token =
  | T_int of int
  | T_ident of string
  | T_let
  | T_in
  | T_if
  | T_then
  | T_else
  | T_true
  | T_false
  | T_fn
  | T_arrow
  | T_eq
  | T_eq_eq
  | T_lt
  | T_colon
  | T_plus
  | T_minus
  | T_star
  | T_lparen
  | T_rparen
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
      | '+' -> advance 1; aux (i + 1) ((pos, T_plus) :: acc)
      | '-' when i + 1 < len && s.[i + 1] = '>' ->
        advance 2; aux (i + 2) ((pos, T_arrow) :: acc)
      | '-' -> advance 1; aux (i + 1) ((pos, T_minus) :: acc)
      | '*' -> advance 1; aux (i + 1) ((pos, T_star) :: acc)
      | '(' -> advance 1; aux (i + 1) ((pos, T_lparen) :: acc)
      | ')' -> advance 1; aux (i + 1) ((pos, T_rparen) :: acc)
      | '=' when i + 1 < len && s.[i + 1] = '=' ->
        advance 2; aux (i + 2) ((pos, T_eq_eq) :: acc)
      | '=' -> advance 1; aux (i + 1) ((pos, T_eq) :: acc)
      | '<' -> advance 1; aux (i + 1) ((pos, T_lt) :: acc)
      | ':' -> advance 1; aux (i + 1) ((pos, T_colon) :: acc)
      | c when is_digit c ->
        let rec read j =
          if j < len && is_digit s.[j] then read (j + 1) else j
        in
        let j = read i in
        let n = int_of_string (String.sub s i (j - i)) in
        advance (j - i);
        aux j ((pos, T_int n) :: acc)
      | c when is_alpha c ->
        let rec read j =
          if j < len && is_ident_cont s.[j] then read (j + 1) else j
        in
        let j = read i in
        let word = String.sub s i (j - i) in
        let tok = match word with
          | "let" -> T_let
          | "in" -> T_in
          | "if" -> T_if
          | "then" -> T_then
          | "else" -> T_else
          | "true" -> T_true
          | "false" -> T_false
          | "fn" -> T_fn
          | _ -> T_ident word
        in
        advance (j - i);
        aux j ((pos, tok) :: acc)
      | _ ->
        raise (Lex_error (pos, Printf.sprintf "unexpected '%c'" c))
  in
  aux 0 []
