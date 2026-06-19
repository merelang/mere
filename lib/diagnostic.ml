(* Pretty error formatting with source snippet and caret.
   Rust-style multi-line code frame with line numbers + caret + optional
   `help:` lines.

   ANSI color is opt-in via the `use_color` flag, set by the CLI when
   stderr is a TTY (and NO_COLOR is not set). Tests run with colors off
   so substring assertions stay stable. *)

(* Toggle by CLI; tests / piped output leave this off. *)
let use_color = ref false

let ansi code s =
  if !use_color then "\027[" ^ code ^ "m" ^ s ^ "\027[0m"
  else s

let red s = ansi "31" s
let blue s = ansi "34" s
let cyan s = ansi "36" s
let bold s = ansi "1" s
let bold_red s = if !use_color then "\027[1;31m" ^ s ^ "\027[0m" else s
let bold_cyan s = if !use_color then "\027[1;36m" ^ s ^ "\027[0m" else s

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

(* Render a `help: …` / `note: …` extra line with the keyword in cyan. *)
let render_extra (line : string) : string =
  let try_strip prefix =
    let pl = String.length prefix in
    if String.length line >= pl
       && String.sub line 0 pl = prefix
    then
      Some (prefix, String.sub line pl (String.length line - pl))
    else None
  in
  match try_strip "help: ", try_strip "note: " with
  | Some (kw, rest), _ -> bold_cyan kw ^ rest
  | _, Some (kw, rest) -> bold_cyan kw ^ rest
  | _ -> line

let format ~source ~filename loc kind msg =
  let { Loc.line; col } = loc in
  let headline, extras = split_msg msg in
  if line = 0 then
    let extra_block =
      if extras = [] then ""
      else "\n" ^ String.concat "\n" (List.map render_extra extras)
    in
    Printf.sprintf "%s: %s: %s%s"
      filename (bold_red kind) headline extra_block
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
    let bar = blue "|" in
    let arrow = blue "-->" in
    let buf = Buffer.create 256 in
    Buffer.add_string buf
      (Printf.sprintf "%s: %s\n" (bold_red kind) headline);
    Buffer.add_string buf
      (Printf.sprintf "%s %s %s:%d:%d\n" blank_gutter arrow filename line col);
    Buffer.add_string buf (Printf.sprintf "%s %s\n" blank_gutter bar);
    for i = lo to hi do
      let line_no = i + 1 in
      Buffer.add_string buf
        (Printf.sprintf "%s %s %s\n"
           (blue (pad_num line_no)) bar lines.(i));
      if line_no = line then begin
        let caret_pad = String.make (max 0 (col - 1)) ' ' in
        Buffer.add_string buf
          (Printf.sprintf "%s %s %s%s %s\n"
             blank_gutter bar caret_pad (bold_red "^") headline)
      end
    done;
    if extras <> [] then begin
      Buffer.add_string buf (Printf.sprintf "%s %s\n" blank_gutter bar);
      List.iter (fun line ->
        Buffer.add_string buf
          (Printf.sprintf "%s %s %s\n" blank_gutter (blue "=") (render_extra line))
      ) extras
    end;
    let s = Buffer.contents buf in
    if String.length s > 0 && s.[String.length s - 1] = '\n' then
      String.sub s 0 (String.length s - 1)
    else s
  end
