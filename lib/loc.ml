(* Source position. `width` is the number of source characters covered
   by the entity this location refers to (e.g. an identifier's length,
   a string literal including its quotes). Defaults to 1 for tokens
   the lexer hasn't measured; defaults to 0 for `dummy`. *)

type t = {
  line  : int;
  col   : int;
  width : int;
}

let mk ?(width = 1) ~line ~col () = { line; col; width }

let dummy = { line = 0; col = 0; width = 0 }

let to_string { line; col; _ } = Printf.sprintf "line %d, col %d" line col
