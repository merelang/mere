(* Pretty error formatting with source snippet and caret. *)

let extract_line source line_num =
  let lines = String.split_on_char '\n' source in
  match List.nth_opt lines (line_num - 1) with
  | Some s -> s
  | None -> ""

(* `format ~source ~filename loc kind msg` produces something like:

    example.lang:3:7: type error: ...
      let x = 5 + true
              ^
*)
let format ~source ~filename loc kind msg =
  let { Loc.line; col } = loc in
  if line = 0 then
    Printf.sprintf "%s: %s: %s" filename kind msg
  else
    let line_text = extract_line source line in
    let caret_padding = String.make (max 0 (col - 1)) ' ' in
    Printf.sprintf "%s:%d:%d: %s: %s\n  %s\n  %s^"
      filename line col kind msg
      line_text caret_padding
