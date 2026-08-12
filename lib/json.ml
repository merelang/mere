(* A JSON value, a parser and a writer — enough for the language server's wire
   format and nothing more.

   Written here rather than taken from a library because this project has two
   dependencies (unix, str) and adding a third to read a protocol this small
   would be a poor trade. The subset is complete for LSP traffic: objects,
   arrays, strings, numbers, booleans, null. Numbers come back as floats, since
   JSON has one numeric type and the protocol's integers all fit.

   The parser is deliberately strict about structure and forgiving about
   whitespace, and it reports a position on failure so a malformed message can be
   complained about rather than silently mishandled. *)

type t =
  | Null
  | Bool of bool
  | Num of float
  | Str of string
  | List of t list
  | Obj of (string * t) list

exception Json_error of string

(* --- reading ------------------------------------------------------------- *)

let parse (s : string) : t =
  let n = String.length s in
  let pos = ref 0 in
  let fail msg = raise (Json_error (Printf.sprintf "%s at byte %d" msg !pos)) in
  let peek () = if !pos < n then Some s.[!pos] else None in
  let skip_ws () =
    while !pos < n && (match s.[!pos] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false) do
      incr pos
    done
  in
  let expect c =
    if !pos < n && s.[!pos] = c then incr pos
    else fail (Printf.sprintf "expected `%c`" c)
  in
  let literal word value =
    let l = String.length word in
    if !pos + l <= n && String.sub s !pos l = word then (pos := !pos + l; value)
    else fail ("expected `" ^ word ^ "`")
  in
  (* \uXXXX is decoded to UTF-8. An editor sends non-ASCII in strings — a path
     with a non-Latin directory name, a string literal in the buffer — and
     passing the escape through unchanged would corrupt it. *)
  let utf8_of_code buf c =
    if c < 0x80 then Buffer.add_char buf (Char.chr c)
    else if c < 0x800 then begin
      Buffer.add_char buf (Char.chr (0xC0 lor (c lsr 6)));
      Buffer.add_char buf (Char.chr (0x80 lor (c land 0x3F)))
    end else if c < 0x10000 then begin
      Buffer.add_char buf (Char.chr (0xE0 lor (c lsr 12)));
      Buffer.add_char buf (Char.chr (0x80 lor ((c lsr 6) land 0x3F)));
      Buffer.add_char buf (Char.chr (0x80 lor (c land 0x3F)))
    end else begin
      Buffer.add_char buf (Char.chr (0xF0 lor (c lsr 18)));
      Buffer.add_char buf (Char.chr (0x80 lor ((c lsr 12) land 0x3F)));
      Buffer.add_char buf (Char.chr (0x80 lor ((c lsr 6) land 0x3F)));
      Buffer.add_char buf (Char.chr (0x80 lor (c land 0x3F)))
    end
  in
  let hex4 () =
    if !pos + 4 > n then fail "truncated \\u escape";
    let v = ref 0 in
    for _ = 1 to 4 do
      let c = s.[!pos] in
      let d =
        match c with
        | '0' .. '9' -> Char.code c - 48
        | 'a' .. 'f' -> Char.code c - 87
        | 'A' .. 'F' -> Char.code c - 55
        | _ -> fail "bad hex digit in \\u escape"
      in
      v := (!v * 16) + d;
      incr pos
    done;
    !v
  in
  let string_body () =
    expect '"';
    let buf = Buffer.create 16 in
    let rec go () =
      if !pos >= n then fail "unterminated string";
      match s.[!pos] with
      | '"' -> incr pos; Buffer.contents buf
      | '\\' ->
        incr pos;
        if !pos >= n then fail "unterminated escape";
        let c = s.[!pos] in
        incr pos;
        (match c with
         | '"' -> Buffer.add_char buf '"'
         | '\\' -> Buffer.add_char buf '\\'
         | '/' -> Buffer.add_char buf '/'
         | 'b' -> Buffer.add_char buf '\b'
         | 'f' -> Buffer.add_char buf '\012'
         | 'n' -> Buffer.add_char buf '\n'
         | 'r' -> Buffer.add_char buf '\r'
         | 't' -> Buffer.add_char buf '\t'
         | 'u' ->
           let c1 = hex4 () in
           (* A surrogate pair is two escapes describing one character. *)
           if c1 >= 0xD800 && c1 <= 0xDBFF && !pos + 1 < n
              && s.[!pos] = '\\' && s.[!pos + 1] = 'u'
           then begin
             pos := !pos + 2;
             let c2 = hex4 () in
             if c2 >= 0xDC00 && c2 <= 0xDFFF then
               utf8_of_code buf
                 (0x10000 + ((c1 - 0xD800) lsl 10) + (c2 - 0xDC00))
             else (utf8_of_code buf c1; utf8_of_code buf c2)
           end
           else utf8_of_code buf c1
         | _ -> fail "unknown escape");
        go ()
      | c -> incr pos; Buffer.add_char buf c; go ()
    in
    go ()
  in
  let number () =
    let start = !pos in
    if peek () = Some '-' then incr pos;
    while !pos < n && (match s.[!pos] with
                       | '0' .. '9' | '.' | 'e' | 'E' | '+' | '-' -> true
                       | _ -> false) do
      incr pos
    done;
    match float_of_string_opt (String.sub s start (!pos - start)) with
    | Some f -> f
    | None -> fail "bad number"
  in
  let rec value () =
    skip_ws ();
    match peek () with
    | None -> fail "unexpected end of input"
    | Some '{' ->
      incr pos;
      skip_ws ();
      if peek () = Some '}' then (incr pos; Obj [])
      else begin
        let rec members acc =
          skip_ws ();
          let k = string_body () in
          skip_ws ();
          expect ':';
          let v = value () in
          skip_ws ();
          match peek () with
          | Some ',' -> incr pos; members ((k, v) :: acc)
          | Some '}' -> incr pos; List.rev ((k, v) :: acc)
          | _ -> fail "expected `,` or `}`"
        in
        Obj (members [])
      end
    | Some '[' ->
      incr pos;
      skip_ws ();
      if peek () = Some ']' then (incr pos; List [])
      else begin
        let rec elements acc =
          let v = value () in
          skip_ws ();
          match peek () with
          | Some ',' -> incr pos; elements (v :: acc)
          | Some ']' -> incr pos; List.rev (v :: acc)
          | _ -> fail "expected `,` or `]`"
        in
        List (elements [])
      end
    | Some '"' -> Str (string_body ())
    | Some 't' -> literal "true" (Bool true)
    | Some 'f' -> literal "false" (Bool false)
    | Some 'n' -> literal "null" Null
    | Some _ -> Num (number ())
  in
  let v = value () in
  skip_ws ();
  if !pos <> n then fail "trailing input";
  v

(* --- writing ------------------------------------------------------------- *)

let escape_into buf s =
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | '\b' -> Buffer.add_string buf "\\b"
    | '\012' -> Buffer.add_string buf "\\f"
    (* Other control characters must be escaped; bytes above 0x7F are passed
       through, since the source they came from is already UTF-8. *)
    | c when Char.code c < 0x20 ->
      Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buf c) s

(* Integers print without a decimal point: the protocol's line and character
   numbers are integers, and an editor that reads them strictly is entitled to
   object to `3.0`. *)
let number_to_string f =
  if Float.is_integer f && Float.abs f < 1e15 then Printf.sprintf "%.0f" f
  else Printf.sprintf "%.17g" f

let rec to_string (v : t) : string =
  let buf = Buffer.create 256 in
  write buf v;
  Buffer.contents buf

and write buf = function
  | Null -> Buffer.add_string buf "null"
  | Bool true -> Buffer.add_string buf "true"
  | Bool false -> Buffer.add_string buf "false"
  | Num f -> Buffer.add_string buf (number_to_string f)
  | Str s -> Buffer.add_char buf '"'; escape_into buf s; Buffer.add_char buf '"'
  | List items ->
    Buffer.add_char buf '[';
    List.iteri (fun i v ->
      if i > 0 then Buffer.add_char buf ',';
      write buf v) items;
    Buffer.add_char buf ']'
  | Obj fields ->
    Buffer.add_char buf '{';
    List.iteri (fun i (k, v) ->
      if i > 0 then Buffer.add_char buf ',';
      Buffer.add_char buf '"';
      escape_into buf k;
      Buffer.add_string buf "\":";
      write buf v) fields;
    Buffer.add_char buf '}'

(* --- reading fields out, without raising on the shape being wrong --------- *)

let member (name : string) (v : t) : t =
  match v with
  | Obj fields -> (try List.assoc name fields with Not_found -> Null)
  | _ -> Null

let to_string_opt = function Str s -> Some s | _ -> None
let to_int_opt = function Num f -> Some (int_of_float f) | _ -> None
let to_list = function List l -> l | _ -> []
