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

(* Lines a driver glued in front of the source before the parser saw it.

   The RV backend prepends its prelude as TEXT (`bin/mere.ml`'s `rv_source`),
   so every position in the user's file is off by that many lines. Diagnostics
   are corrected on the way out (`Rv_prelude.origin_of`), which is enough for
   anything the compiler PRINTS — and not enough for a position the compiler
   puts INTO the program, which is what `echo` does. Zero on every other path,
   and set by the one driver that glues. *)
let glued_lines = ref 0
