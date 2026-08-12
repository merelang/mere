(* Source position. `width` is the number of source characters covered
   by the entity this location refers to (e.g. an identifier's length,
   a string literal including its quotes). Defaults to 1 for tokens
   the lexer hasn't measured; defaults to 0 for `dummy`. *)

type t = {
  line  : int;
  col   : int;
  width : int;
  (* The file the position is in, when it is not the one being compiled — set for
     tokens that came from an `import`. Everything downstream inherits it for
     free, because the lexer is the only thing that builds a position: an error
     deep in the typer, about a node from an imported file, knows which file it
     is about without anybody having threaded that through. `None` means "the
     source you handed the compiler". *)
  file  : string option;
}

let mk ?(width = 1) ?file ~line ~col () = { line; col; width; file }

let dummy = { line = 0; col = 0; width = 0; file = None }

let to_string { line; col; _ } = Printf.sprintf "line %d, col %d" line col
