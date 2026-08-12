(* A language server: the protocol, and what to answer.

   Everything here is a function from a message and a state to the messages that
   go back, so the whole server can be tested without a socket, a subprocess or
   an editor. The driver in the CLI does the reading and writing and nothing
   else.

   Diagnostics — the file's errors, republished on every keystroke — plus hover,
   which is the first of the questions that are really "what is under the
   cursor?" (`Query` answers that; completion and go-to-definition ask it too).

   The check it runs is `Pipeline.check`, which is the check the compiler runs. A language server that agrees with the compiler on good days is worse
   than none: it teaches you to distrust the underline. *)

(* What the server remembers about an open file: the buffer's text, and the
   typed tree from the last check that produced one. The tree may be older than
   the text — it is whatever last type-checked — which is the right trade for a
   hover: an answer from a moment ago beats no answer while a line is half
   typed. *)
type doc = {
  text : string;
  tree : Ast.program option;
}

type state = {
  (* uri -> the buffer. The editor owns the file while it is open; what is on
     disk may be older, and is not consulted. *)
  docs : (string * doc) list;
  shutting_down : bool;
}

let initial = { docs = []; shutting_down = false }

(* --- framing --------------------------------------------------------------

   Messages are `Content-Length: N\r\n\r\n` followed by exactly N bytes. The
   header block may carry other fields, which are ignored. *)

let frame (v : Json.t) : string =
  let body = Json.to_string v in
  Printf.sprintf "Content-Length: %d\r\n\r\n%s" (String.length body) body

let content_length (header : string) : int option =
  let lower = String.lowercase_ascii header in
  let key = "content-length:" in
  let kl = String.length key in
  let n = String.length lower in
  let rec find i =
    if i + kl > n then None
    else if String.sub lower i kl = key then
      let rest = String.sub header (i + kl) (n - i - kl) in
      let stop =
        match String.index_opt rest '\r', String.index_opt rest '\n' with
        | Some a, Some b -> min a b
        | Some a, None -> a
        | None, Some b -> b
        | None, None -> String.length rest
      in
      int_of_string_opt (String.trim (String.sub rest 0 stop))
    else find (i + 1)
  in
  find 0

(* Read one message, or None at end of input. Blocking, and the only IO in this
   module. *)
let read_message (ic : in_channel) : Json.t option =
  let buf = Buffer.create 256 in
  let rec headers () =
    match In_channel.input_line ic with
    | None -> None
    | Some line ->
      let line = String.trim line in
      if line = "" then Some (Buffer.contents buf)
      else (Buffer.add_string buf line; Buffer.add_char buf '\n'; headers ())
  in
  match headers () with
  | None -> None
  | Some header ->
    (match content_length header with
     | None -> None
     | Some len ->
       let body = really_input_string ic len in
       (try Some (Json.parse body) with Json.Json_error _ -> None))

(* --- positions ------------------------------------------------------------

   Mere counts lines and columns from 1; the protocol counts both from 0. The
   width a diagnostic carries is how many characters the offending thing covers,
   which is what turns an underline into something that points at the right
   token rather than at one character of it. *)

let position line col =
  Json.Obj [ ("line", Json.Num (float_of_int (max 0 (line - 1))));
             ("character", Json.Num (float_of_int (max 0 (col - 1)))) ]

let range_of_loc (loc : Loc.t) =
  let width = max 1 loc.Loc.width in
  Json.Obj [ ("start", position loc.Loc.line loc.Loc.col);
             ("end", position loc.Loc.line (loc.Loc.col + width)) ]

let severity_number = function
  | Pipeline.Error -> 1
  | Pipeline.Warning -> 2

let diagnostic_json (d : Pipeline.diagnostic) =
  Json.Obj [
    ("range", range_of_loc d.Pipeline.d_loc);
    ("severity", Json.Num (float_of_int (severity_number d.Pipeline.d_severity)));
    ("source", Json.Str "mere");
    ("message", Json.Str (d.Pipeline.d_kind ^ ": " ^ d.Pipeline.d_msg));
  ]

(* --- document URIs --------------------------------------------------------

   `file:///path/to/app.mere`. The path matters for one reason: an `import` in
   the buffer resolves relative to the file's own directory, so a server that
   ignores the URI reports imports as missing on every keystroke. *)

let percent_decode (s : string) : string =
  let n = String.length s in
  let buf = Buffer.create n in
  let hex c =
    match c with
    | '0' .. '9' -> Some (Char.code c - 48)
    | 'a' .. 'f' -> Some (Char.code c - 87)
    | 'A' .. 'F' -> Some (Char.code c - 55)
    | _ -> None
  in
  let i = ref 0 in
  while !i < n do
    (if s.[!i] = '%' && !i + 2 < n then
       match hex s.[!i + 1], hex s.[!i + 2] with
       | Some a, Some b -> Buffer.add_char buf (Char.chr ((a * 16) + b)); i := !i + 3
       | _ -> Buffer.add_char buf s.[!i]; incr i
     else (Buffer.add_char buf s.[!i]; incr i))
  done;
  Buffer.contents buf

let path_of_uri (uri : string) : string option =
  let prefix = "file://" in
  let pl = String.length prefix in
  if String.length uri > pl && String.sub uri 0 pl = prefix then
    Some (percent_decode (String.sub uri pl (String.length uri - pl)))
  else None

let base_dir_of_uri uri =
  match path_of_uri uri with
  | Some p -> Some (Filename.dirname p)
  | None -> None

(* --- messages -------------------------------------------------------------- *)

let response id result =
  Json.Obj [ ("jsonrpc", Json.Str "2.0"); ("id", id); ("result", result) ]

let error_response id code msg =
  Json.Obj [ ("jsonrpc", Json.Str "2.0"); ("id", id);
             ("error", Json.Obj [ ("code", Json.Num (float_of_int code));
                                  ("message", Json.Str msg) ]) ]

let notification meth params =
  Json.Obj [ ("jsonrpc", Json.Str "2.0"); ("method", Json.Str meth);
             ("params", params) ]

let publish uri (diags : Pipeline.diagnostic list) =
  notification "textDocument/publishDiagnostics"
    (Json.Obj [ ("uri", Json.Str uri);
                ("diagnostics", Json.List (List.map diagnostic_json diags)) ])

(* Check one document: the notification to send, and the typed tree if it
   type-checked. Every failure mode of the compiler that is not a diagnostic — a
   stack overflow on a pathological input, an IO error from an import — becomes a
   single diagnostic at the top of the file rather than a dead server: an editor
   cannot be left with no answer. *)
let check_document ?search_paths uri text =
  try
    let (tree, diags) =
      Pipeline.check ?base_dir:(base_dir_of_uri uri) ?search_paths text
    in
    (publish uri diags, tree)
  with e ->
    (publish uri
       [ { Pipeline.d_loc = Loc.mk ~line:1 ~col:1 ();
           d_kind = "internal error";
           d_msg = Printexc.to_string e;
           d_severity = Pipeline.Error } ],
     None)

let server_capabilities =
  Json.Obj [
    (* 1 = full text on every change. Incremental sync is a real optimisation
       for large files and a real source of desynchronisation bugs; the check
       re-reads the whole buffer anyway, so there is nothing to gain here yet. *)
    ("textDocumentSync", Json.Num 1.0);
    ("hoverProvider", Json.Bool true);
    ("definitionProvider", Json.Bool true);
  ]

let set_doc state uri text tree =
  let previous = List.assoc_opt uri state.docs in
  let tree =
    match tree with
    | Some _ -> tree
    (* Keep the last tree that type-checked: while a line is half typed the file
       does not check, and a hover from a moment ago is better than none. *)
    | None -> (match previous with Some d -> d.tree | None -> None)
  in
  { state with docs = (uri, { text; tree }) :: List.remove_assoc uri state.docs }

(* The position a request asks about, translated into Mere's 1-based counting,
   together with the tree to ask. *)
let ask state uri (params : Json.t) =
  let position = Json.member "position" params in
  let line = Option.value ~default:(-1) (Json.to_int_opt (Json.member "line" position)) in
  let col = Option.value ~default:(-1) (Json.to_int_opt (Json.member "character" position)) in
  match List.assoc_opt uri state.docs with
  | Some { tree = Some prog; _ } -> Some (prog, line + 1, col + 1)
  | _ -> None

(* Hover: `Query.node_at` finds the narrowest node whose token contains the
   cursor, and the typer has already written that node's type onto it. *)
let hover state uri (params : Json.t) =
  match ask state uri params with
  | None -> Json.Null
  | Some (prog, line, col) ->
    (match Query.node_at prog line col with
     | None -> Json.Null
     | Some node ->
       (match Query.describe node with
        | None -> Json.Null
        | Some text ->
          Json.Obj [
            ("contents",
             Json.Obj [ ("kind", Json.Str "markdown");
                        ("value", Json.Str ("```mere\n" ^ text ^ "\n```")) ]);
            ("range", range_of_loc node.Ast.loc);
          ]))

(* Go to definition: the same node search, plus the scope around it. Answers only
   for a name bound in this file — a builtin or a prelude name has no position
   here to jump to, and sending an editor to an arbitrary line of another text
   would be worse than saying nothing. *)
let definition state uri (params : Json.t) =
  match ask state uri params with
  | None -> Json.Null
  | Some (prog, line, col) ->
    (match Query.definition_at ~prelude_decls:(Pipeline.prelude_decl_count ())
             prog line col with
     | None -> Json.Null
     | Some loc ->
       Json.Obj [ ("uri", Json.Str uri); ("range", range_of_loc loc) ])

(* One message in, the messages to send back out. `exit` is signalled by the
   third component so the driver can stop without this module knowing what a
   process is. *)
let handle ?search_paths (state : state) (msg : Json.t) : state * Json.t list * bool =
  let meth = Json.to_string_opt (Json.member "method" msg) in
  let params = Json.member "params" msg in
  let id = Json.member "id" msg in
  let is_request = id <> Json.Null in
  let doc = Json.member "textDocument" params in
  let uri_of v = Json.to_string_opt (Json.member "uri" v) in
  match meth with
  | Some "initialize" ->
    (state,
     [ response id
         (Json.Obj [ ("capabilities", server_capabilities);
                     ("serverInfo",
                      Json.Obj [ ("name", Json.Str "mere");
                                 ("version", Json.Str Version.v) ]) ]) ],
     false)
  | Some "initialized" -> (state, [], false)
  | Some "shutdown" -> ({ state with shutting_down = true }, [ response id Json.Null ], false)
  | Some "exit" -> (state, [], true)
  | Some "textDocument/hover" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (hover state uri params) ], false)
     | None -> (state, [ response id Json.Null ], false))
  | Some "textDocument/definition" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (definition state uri params) ], false)
     | None -> (state, [ response id Json.Null ], false))
  | Some "textDocument/didOpen" ->
    (match uri_of doc, Json.to_string_opt (Json.member "text" doc) with
     | Some uri, Some text ->
       let (note, tree) = check_document ?search_paths uri text in
       (set_doc state uri text tree, [ note ], false)
     | _ -> (state, [], false))
  | Some "textDocument/didChange" ->
    (* Full sync: the last content change is the whole document. *)
    (match uri_of doc with
     | None -> (state, [], false)
     | Some uri ->
       let changes = Json.to_list (Json.member "contentChanges" params) in
       (match List.rev changes with
        | last :: _ ->
          (match Json.to_string_opt (Json.member "text" last) with
           | Some text ->
             let (note, tree) = check_document ?search_paths uri text in
             (set_doc state uri text tree, [ note ], false)
           | None -> (state, [], false))
        | [] -> (state, [], false)))
  | Some "textDocument/didSave" ->
    (match uri_of doc with
     | Some uri ->
       (match List.assoc_opt uri state.docs with
        | Some d ->
          let (note, tree) = check_document ?search_paths uri d.text in
          (set_doc state uri d.text tree, [ note ], false)
        | None -> (state, [], false))
     | None -> (state, [], false))
  | Some "textDocument/didClose" ->
    (match uri_of doc with
     | Some uri ->
       (* Clear the underlines: the file is no longer the editor's problem. *)
       ({ state with docs = List.remove_assoc uri state.docs },
        [ publish uri [] ], false)
     | None -> (state, [], false))
  | Some m when is_request ->
    (state, [ error_response id (-32601) ("method not found: " ^ m) ], false)
  | Some _ -> (state, [], false)          (* an unknown notification is ignored *)
  | None -> (state, [], false)

(* The read/handle/write loop. Kept here so the CLI's `lsp` arm is one call, and
   so the only untested part is three lines of IO. *)
let serve ?search_paths ?(ic = stdin) ?(oc = stdout) () =
  set_binary_mode_in ic true;
  set_binary_mode_out oc true;
  let rec loop state =
    match read_message ic with
    | None -> ()
    | Some msg ->
      let (state, out, stop) = handle ?search_paths state msg in
      List.iter (fun m -> output_string oc (frame m)) out;
      flush oc;
      if not stop then loop state
  in
  loop initial
