(* Source position. *)

type t = { line : int; col : int }

let dummy = { line = 0; col = 0 }

let to_string { line; col } = Printf.sprintf "line %d, col %d" line col
