(* Pretty error formatting with source snippet and caret.
   Rust-style multi-line code frame with line numbers + caret.

   Example output:

     type error: type mismatch: `str` vs `int`
       --> example.lang:2:13
        |
      1 | let x = 5 in
      2 | let y = x + "hello" in
        |             ^ type mismatch: `str` vs `int`
      3 | y *)

let split_lines (s : string) : string array =
  String.split_on_char '\n' s |> Array.of_list

(* Number of lines of context to show before / after the error line. *)
let context_lines_before = 2
let context_lines_after = 1

(* Split a Type_error's msg into (headline, extra_lines). Anything past
   the first newline is treated as supplementary `help:` / `note:` text
   to render below the code frame. *)
let split_msg (msg : string) : string * string list =
  match String.split_on_char '\n' msg with
  | [] -> (msg, [])
  | head :: rest -> (head, rest)

let format ~source ~filename loc kind msg =
  let { Loc.line; col } = loc in
  let headline, extras = split_msg msg in
  if line = 0 then
    let extra_block =
      if extras = [] then ""
      else "\n" ^ String.concat "\n" extras
    in
    Printf.sprintf "%s: %s: %s%s" filename kind headline extra_block
  else begin
    let lines = split_lines source in
    let last_idx = Array.length lines - 1 in
    let lo = max 0 (line - 1 - context_lines_before) in
    let hi = min last_idx (line - 1 + context_lines_after) in
    let gutter_w = String.length (string_of_int (hi + 1)) in
    let pad_num n =
      let s = string_of_int n in
      String.make (gutter_w - String.length s) ' ' ^ s
    in
    let blank_gutter = String.make gutter_w ' ' in
    let buf = Buffer.create 256 in
    Buffer.add_string buf (Printf.sprintf "%s: %s\n" kind headline);
    Buffer.add_string buf
      (Printf.sprintf "%s --> %s:%d:%d\n" blank_gutter filename line col);
    Buffer.add_string buf (Printf.sprintf "%s |\n" blank_gutter);
    for i = lo to hi do
      let line_no = i + 1 in
      Buffer.add_string buf
        (Printf.sprintf "%s | %s\n" (pad_num line_no) lines.(i));
      if line_no = line then begin
        let caret_pad = String.make (max 0 (col - 1)) ' ' in
        Buffer.add_string buf
          (Printf.sprintf "%s | %s^ %s\n" blank_gutter caret_pad headline)
      end
    done;
    if extras <> [] then begin
      Buffer.add_string buf (Printf.sprintf "%s |\n" blank_gutter);
      List.iter (fun line ->
        Buffer.add_string buf
          (Printf.sprintf "%s = %s\n" blank_gutter line)
      ) extras
    end;
    let s = Buffer.contents buf in
    if String.length s > 0 && s.[String.length s - 1] = '\n' then
      String.sub s 0 (String.length s - 1)
    else s
  end
