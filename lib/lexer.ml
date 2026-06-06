(* Tokenizer with source position tracking.
   Supports: integer literals, `+ - *`, parens, `//` line comments,
   whitespace and newlines. *)

exception Lex_error of Loc.t * string

type token =
  | T_int of int
  | T_plus
  | T_minus
  | T_star
  | T_lparen
  | T_rparen
  | T_eof

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
  let is_digit c = c >= '0' && c <= '9' in
  let rec aux i acc =
    if i >= len then List.rev ((here (), T_eof) :: acc)
    else
      let pos = here () in
      let c = s.[i] in
      match c with
      | ' ' | '\t' -> advance 1; aux (i + 1) acc
      | '\n' -> newline (); aux (i + 1) acc
      | '/' when i + 1 < len && s.[i + 1] = '/' ->
        (* line comment: skip until newline or EOF *)
        let rec skip j =
          if j >= len || s.[j] = '\n' then j else skip (j + 1)
        in
        let j = skip (i + 2) in
        advance (j - i);
        aux j acc
      | '+' -> advance 1; aux (i + 1) ((pos, T_plus) :: acc)
      | '-' -> advance 1; aux (i + 1) ((pos, T_minus) :: acc)
      | '*' -> advance 1; aux (i + 1) ((pos, T_star) :: acc)
      | '(' -> advance 1; aux (i + 1) ((pos, T_lparen) :: acc)
      | ')' -> advance 1; aux (i + 1) ((pos, T_rparen) :: acc)
      | c when is_digit c ->
        let rec read j =
          if j < len && is_digit s.[j] then read (j + 1) else j
        in
        let j = read i in
        let n = int_of_string (String.sub s i (j - i)) in
        advance (j - i);
        aux j ((pos, T_int n) :: acc)
      | _ ->
        raise (Lex_error (pos, Printf.sprintf "unexpected '%c'" c))
  in
  aux 0 []
