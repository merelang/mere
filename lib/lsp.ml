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
  (* Other files this document's diagnostics were published against — an
     `import` with a syntax error in it. They have to be remembered so they can
     be cleared: a diagnostic an editor was told about stays on screen until the
     server says otherwise, and "the import is fixed now" is exactly the message
     nobody would think to send. *)
  extra : string list;
  (* This document's own diagnostics, as data rather than as the notification
     they were sent in. A code action is an answer to one of them, and the
     editor asks for actions in a separate request: re-checking the file to
     answer it would be the same work a second time, and — on a buffer the
     editor has since changed — about a different file. *)
  diags : Pipeline.diagnostic list;
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

(* --- columns: bytes on one side, UTF-16 units on the other ----------------

   `Loc` counts BYTES from the start of a line, because bytes are what the lexer
   advances over. The protocol counts UTF-16 code units. The two agree on ASCII
   and on nothing else, so one kanji before the cursor puts the two counts two
   apart and three put them six apart — far enough to land a hover on a
   different token, which the server then answers about, correctly and about
   the wrong thing.

   Found by using this server from an editor rather than by reading the
   specification: every test here was ASCII, where the bug does not exist.

   Both directions are computed against the buffer the server is holding, which
   is the same text the Loc came from. When there is no buffer to measure —
   diagnostics about an imported file the editor never opened — the conversion
   is the identity, which is exactly right for ASCII and no worse than what
   there was before. *)

let utf8_seq_len (c : char) =
  let b = Char.code c in
  if b < 0x80 then 1
  (* A stray continuation byte is its own character rather than a reason to
     loop forever: this runs on half-typed buffers. *)
  else if b < 0xC0 then 1
  else if b < 0xE0 then 2
  else if b < 0xF0 then 3
  else 4

(* Everything outside the BMP is a surrogate PAIR in UTF-16, and that is exactly
   the 4-byte UTF-8 sequences. *)
let utf16_units (c : char) = if Char.code c >= 0xF0 then 2 else 1

(* Byte offsets [start, stop) of a zero-based line, not counting its newline. *)
let line_bounds (text : string) (line0 : int) : int * int =
  let n = String.length text in
  let rec start i l =
    if l >= line0 then i
    else if i >= n then n
    else start (i + 1) (if text.[i] = '\n' then l + 1 else l)
  in
  let s = if line0 <= 0 then 0 else start 0 0 in
  let rec fin j = if j >= n || text.[j] = '\n' then j else fin (j + 1) in
  (s, fin s)

(* The protocol's `character` -> a zero-based BYTE column on that line. *)
let byte_col_of_char (text : string) (line0 : int) (ch : int) : int =
  if ch <= 0 || text = "" then max 0 ch
  else
    let (s, e) = line_bounds text line0 in
    let rec go i units =
      if i >= e || units >= ch then i - s
      else go (i + utf8_seq_len text.[i]) (units + utf16_units text.[i])
    in
    go s 0

(* A zero-based BYTE column -> the protocol's `character`. *)
let char_of_byte_col (text : string) (line0 : int) (bcol : int) : int =
  if bcol <= 0 || text = "" then max 0 bcol
  else
    let (s, e) = line_bounds text line0 in
    let target = min (s + bcol) e in
    let rec go i units =
      if i >= target then units
      else go (i + utf8_seq_len text.[i]) (units + utf16_units text.[i])
    in
    go s 0

(* `line` and `col` are Loc's 1-based numbers; the protocol's are 0-based. *)
let position ?(text = "") line col =
  let line0 = max 0 (line - 1) in
  Json.Obj [ ("line", Json.Num (float_of_int line0));
             ("character",
              Json.Num (float_of_int (char_of_byte_col text line0 (max 0 (col - 1))))) ]

let range_of_loc ?(text = "") (loc : Loc.t) =
  let width = max 1 loc.Loc.width in
  Json.Obj [ ("start", position ~text loc.Loc.line loc.Loc.col);
             ("end", position ~text loc.Loc.line (loc.Loc.col + width)) ]

let severity_number = function
  | Pipeline.Error -> 1
  | Pipeline.Warning -> 2

let diagnostic_json ?(text = "") (d : Pipeline.diagnostic) =
  Json.Obj [
    ("range", range_of_loc ~text d.Pipeline.d_loc);
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

let publish ?(text = "") uri (diags : Pipeline.diagnostic list) =
  notification "textDocument/publishDiagnostics"
    (Json.Obj [ ("uri", Json.Str uri);
                ("diagnostics",
                 Json.List (List.map (diagnostic_json ~text) diags)) ])

(* Check one document: the notifications to send, the typed tree if it
   type-checked, and the other files that were published about.

   Every failure mode of the compiler that is not a diagnostic — a stack overflow
   on a pathological input, an IO error from an import — becomes a single
   diagnostic at the top of the file rather than a dead server: an editor cannot
   be left with no answer. *)
let check_document ?search_paths (previous : string list) uri text =
  let (tree, diags) =
    try Pipeline.check ?base_dir:(base_dir_of_uri uri) ?search_paths text
    with e ->
      (None,
       [ { Pipeline.d_loc = Loc.mk ~line:1 ~col:1 ();
           d_kind = "internal error";
           d_msg = Printexc.to_string e;
           d_severity = Pipeline.Error;
           d_file = None;
           d_fix = None } ])
  in
  (* A diagnostic about another file is published against *that* file's URI,
     where its line numbers mean something. *)
  let others =
    List.sort_uniq compare
      (List.filter_map (fun (d : Pipeline.diagnostic) ->
         Option.map (fun p -> "file://" ^ p) d.Pipeline.d_file) diags)
  in
  let mine = List.filter (fun (d : Pipeline.diagnostic) -> d.Pipeline.d_file = None) diags in
  let for_other u =
    (* The other file's ranges are in ITS columns, so they need its bytes. It
       is not open in the editor, so it is read from disk; if that fails the
       conversion falls back to the identity rather than the notification
       being dropped. *)
    let other_text =
      let path = String.sub u 7 (String.length u - 7) in
      try
        let ic = open_in_bin path in
        let n = in_channel_length ic in
        let b = really_input_string ic n in
        close_in ic; b
      with _ -> ""
    in
    publish ~text:other_text u
      (List.filter (fun (d : Pipeline.diagnostic) ->
         Option.map (fun p -> "file://" ^ p) d.Pipeline.d_file = Some u) diags)
  in
  (* Clear whatever we said about files that are no longer implicated. *)
  let cleared = List.filter (fun u -> not (List.mem u others)) previous in
  (publish ~text uri mine :: List.map for_other others @ List.map (fun u -> publish u []) cleared,
   tree, others, mine)

(* The vocabulary of semantic tokens, in the order the legend declares them —
   a token names its type by index into this list. *)
let token_legend =
  [ Query.Tk_function; Query.Tk_variable; Query.Tk_parameter; Query.Tk_constructor;
    Query.Tk_keyword; Query.Tk_string; Query.Tk_number; Query.Tk_comment ]

let token_index kind =
  let rec go i = function
    | [] -> 0
    | k :: rest -> if k = kind then i else go (i + 1) rest
  in
  go 0 token_legend

let server_capabilities =
  Json.Obj [
    (* 1 = full text on every change. Incremental sync is a real optimisation
       for large files and a real source of desynchronisation bugs; the check
       re-reads the whole buffer anyway, so there is nothing to gain here yet. *)
    ("textDocumentSync", Json.Num 1.0);
    ("hoverProvider", Json.Bool true);
    ("definitionProvider", Json.Bool true);
    (* No trigger characters: this language has no `.` member access to complete
       after, so the editor asks when the user asks. *)
    ("completionProvider", Json.Obj [ ("resolveProvider", Json.Bool false) ]);
    ("documentSymbolProvider", Json.Bool true);
    ("referencesProvider", Json.Bool true);
    (* The same answer as references, drawn in the file. Advertised separately
       because the editor asks for it on every cursor move and would not think
       to call the panel's request for that. *)
    ("documentHighlightProvider", Json.Bool true);
    ("typeDefinitionProvider", Json.Bool true);
    (* A space is when an editor asks for the next parameter; an open paren is
       when it asks for the first. *)
    ("signatureHelpProvider",
     Json.Obj [ ("triggerCharacters", Json.List [ Json.Str " "; Json.Str "(" ]) ]);
    (* `prepareSupport` lets the editor ask, before showing its rename box,
       whether this thing can be renamed at all — which is how a refusal becomes
       a message instead of a failed edit. *)
    ("renameProvider", Json.Obj [ ("prepareProvider", Json.Bool true) ]);
    ("documentFormattingProvider", Json.Bool true);
    (* Actions are computed on request from the document's own diagnostics and
       tree, so there is nothing to resolve later and no kind filter to honour:
       the server answers with everything that applies at the range it was
       given. *)
    ("codeActionProvider", Json.Bool true);
    (* The legend is the agreement about what the numbers in the token stream
       mean: the server picks the vocabulary, and every token is an index into
       it. *)
    ("semanticTokensProvider",
     Json.Obj [
       ("legend",
        Json.Obj [
          ("tokenTypes", Json.List (List.map (fun k -> Json.Str (Query.token_kind_name k))
                                      token_legend));
          ("tokenModifiers", Json.List []) ]);
       ("full", Json.Bool true) ]);
  ]

let extra_of state uri =
  match List.assoc_opt uri state.docs with Some d -> d.extra | None -> []

let set_doc state uri text tree extra diags =
  let previous = List.assoc_opt uri state.docs in
  let tree =
    match tree with
    | Some _ -> tree
    (* Keep the last tree that type-checked: while a line is half typed the file
       does not check, and a hover from a moment ago is better than none. *)
    | None -> (match previous with Some d -> d.tree | None -> None)
  in
  (* The diagnostics are NOT kept the way the tree is. They describe the text
     that was just checked, and an action offered against a stale one would
     edit a line that has moved. *)
  { state with
    docs = (uri, { text; tree; extra; diags }) :: List.remove_assoc uri state.docs }

(* The position a request asks about, translated into Mere's 1-based counting,
   together with the tree to ask. *)
let ask state uri (params : Json.t) =
  let position = Json.member "position" params in
  let line = Option.value ~default:(-1) (Json.to_int_opt (Json.member "line" position)) in
  let col = Option.value ~default:(-1) (Json.to_int_opt (Json.member "character" position)) in
  match List.assoc_opt uri state.docs with
  | Some { tree = Some prog; text; _ } ->
    (* The request counts UTF-16 units; every Loc in the tree counts bytes. *)
    let bcol = if col < 0 then col else byte_col_of_char text line col in
    Some (prog, line + 1, bcol + 1)
  | _ -> None

(* The buffer a document's Locs were measured against, for turning them back
   into the protocol's columns. Empty when the document is not open, which makes
   the conversion the identity. *)
let doc_text state uri =
  match List.assoc_opt uri state.docs with Some d -> d.text | None -> ""

(* The comment block directly above a definition, as its documentation.

   Contiguous `//` lines ending on the line before the definition, with the
   marker and one space removed. No new syntax: Gleam distinguishes `///` (a
   doc, which its generator publishes) from `//` (a note to the next reader),
   and that distinction earns its keep there because there is a generator.
   Mere has none, so requiring a third slash would mean every comment already
   written shows nothing.

   A blank line ends the block, which is how a person already separates "about
   this definition" from "about the section". *)
let doc_above (text : string) (line : int) : string option =
  let lines = String.split_on_char '\n' text in
  let arr = Array.of_list lines in
  let strip (s : string) =
    let t = String.trim s in
    if String.length t >= 2 && String.sub t 0 2 = "//" then
      let rest = String.sub t 2 (String.length t - 2) in
      Some (if String.length rest > 0 && rest.[0] = ' ' then
              String.sub rest 1 (String.length rest - 1)
            else rest)
    else None
  in
  let rec up i acc =
    if i < 0 then acc
    else
      match strip arr.(i) with
      | Some c -> up (i - 1) (c :: acc)
      | None -> acc
  in
  (* `line` is 1-based and is the definition's own line; the block is what sits
     immediately above it. *)
  let start = line - 2 in
  if start < 0 || start >= Array.length arr then None
  else match up start [] with
    | [] -> None
    | cs -> Some (String.concat "\n" cs)

(* Hover: `Query.node_at` finds the narrowest node whose token contains the
   cursor, and the typer has already written that node's type onto it.

   Two things it did not do until v0.1.504:

   - IT ANSWERED NOTHING ON A DEFINITION. `node_at` looks for an expression, and
     the `inc` in `let inc = ...` is a pattern, so hovering the very place a
     name is introduced returned nothing at all. `Query.references_at` resolves
     both — its walker emits the binder as an occurrence — so it is the
     fallback, and the answer is the binding's own name and type.
   - IT SHOWED NO DOCUMENTATION. The comment above the definition is what a
     person wrote to be read at exactly this moment. Found from the binding's
     position, so hovering a USE shows what was written at the DEFINITION. *)
let hover state uri (params : Json.t) =
  match ask state uri params with
  | None -> Json.Null
  | Some (prog, line, col) ->
    let text = doc_text state uri in
    let binding =
      Option.map fst
        (Query.references_at ~prelude_decls:(Pipeline.prelude_decl_count ())
           prog line col)
    in
    let node = Query.node_at prog line col in
    let signature =
      match Option.bind node Query.describe with
      | Some s -> Some s
      | None ->
        Option.map (fun (b : Query.binding) ->
          match b.Query.b_ty with
          | Some t -> b.Query.b_name ^ " : " ^ Ast.pp_ty t
          | None -> b.Query.b_name) binding
    in
    (match signature with
     | None -> Json.Null
     | Some sig_text ->
       let doc =
         match binding with
         | Some b when b.Query.b_loc.Loc.file = None && not b.Query.b_prelude ->
           doc_above text b.Query.b_loc.Loc.line
         | _ -> None
       in
       let value =
         "```mere\n" ^ sig_text ^ "\n```"
         ^ (match doc with Some d -> "\n\n" ^ d | None -> "")
       in
       let range =
         match node with
         | Some n -> range_of_loc ~text n.Ast.loc
         | None ->
           (match binding with
            | Some b -> range_of_loc ~text b.Query.b_loc
            | None -> range_of_loc ~text Loc.dummy)
       in
       Json.Obj [
         ("contents",
          Json.Obj [ ("kind", Json.Str "markdown"); ("value", Json.Str value) ]);
         ("range", range);
       ])

(* Completion: every name visible at the position. The kind is what an editor
   draws the icon from — 3 is Function, 6 is Variable — and a name whose type is
   an arrow is a function as far as anybody looking at the list is concerned.
   The type goes in `detail`, which is the line an editor shows beside the name. *)
let completion state uri (params : Json.t) =
  match ask state uri params with
  | None -> Json.List []
  | Some (prog, line, col) ->
    let items =
      List.map (fun (c : Query.completion) ->
        let ty = Option.map Ast.pp_ty c.Query.c_ty in
        let is_fn =
          match c.Query.c_ty with
          | Some t -> (match Ast.walk t with Ast.TyArrow _ -> true | _ -> false)
          | None -> false
        in
        Json.Obj ([
          ("label", Json.Str c.Query.c_name);
          ("kind", Json.Num (if is_fn then 3.0 else 6.0));
        ] @ (match ty with Some t -> [ ("detail", Json.Str t) ] | None -> [])
          @ (if c.Query.c_prelude then [ ("sortText", Json.Str ("z" ^ c.Query.c_name)) ]
             else [])))
        (Query.completions_at ~prelude_decls:(Pipeline.prelude_decl_count ())
           prog line col)
    in
    (* `isIncomplete: false` — this is the whole scope, so the editor may filter
       it as the user keeps typing instead of asking again. *)
    Json.Obj [ ("isIncomplete", Json.Bool false); ("items", Json.List items) ]

(* Semantic highlighting: the compiler saying which names are parameters, which
   are functions, which are constructors — the distinctions a regular expression
   cannot make.

   The encoding is five integers per token, and every one of them is *relative*:
   the line is a delta from the previous token's line, and the character is a
   delta from the previous token's character when they share a line. It is a
   compact format for a stream that arrives in order, and getting the deltas
   wrong paints the file at an offset, which is why the order is fixed in
   `Query.semantic_tokens` rather than here. *)
let semantic_tokens state uri =
  match List.assoc_opt uri state.docs with
  | Some { tree = Some prog; text; _ } ->
    (* Two sources, one stream. The tree says which NAMES are parameters and
       which are functions; the lexer says which words are keywords and where
       the strings and comments are. They are merged and sorted because the
       encoding below is a delta from the previous token, which is only a
       delta if the stream is in order.
       The tree may be older than the text -- it is whatever last type-checked
       -- while the lexical half is always current. Mixed, and better than
       either alone: the file keeps its shape while a line is half typed. *)
    let toks =
      List.stable_sort (fun (a : Query.token) (b : Query.token) ->
        compare (a.Query.t_loc.Loc.line, a.Query.t_loc.Loc.col)
                (b.Query.t_loc.Loc.line, b.Query.t_loc.Loc.col))
        (Query.semantic_tokens ~prelude_decls:(Pipeline.prelude_decl_count ()) prog
         @ Query.lexical_tokens text)
    in
    let data = ref [] in
    let prev_line = ref 0 and prev_col = ref 0 in
    List.iter (fun (t : Query.token) ->
      let line = t.Query.t_loc.Loc.line - 1 in
      (* Deltas are in the protocol's columns, so each one is converted before
         it is subtracted: converting the difference would be converting a
         number that is not a position. *)
      let col = char_of_byte_col text line (t.Query.t_loc.Loc.col - 1) in
      let dline = line - !prev_line in
      let dcol = if dline = 0 then col - !prev_col else col in
      (* The length is in the protocol's units too, and a kanji is three bytes
         and one unit: a byte width paints three columns of highlight for one
         character. *)
      let len =
        max 1 (char_of_byte_col text line
                 (t.Query.t_loc.Loc.col - 1 + max 1 t.Query.t_loc.Loc.width) - col) in
      data := [ dline; dcol; len; token_index t.Query.t_kind; 0 ] :: !data;
      prev_line := line;
      prev_col := col) toks;
    Json.Obj [ ("data",
                Json.List (List.map (fun n -> Json.Num (float_of_int n))
                             (List.concat (List.rev !data)))) ]
  | _ -> Json.Obj [ ("data", Json.List []) ]

(* Document highlight: the same answer as find-references, drawn in the file
   instead of listed in a panel. The editor asks for it on every cursor move, so
   it is the one place where "same question, different request" is worth saying
   out loud — this handler must not start computing something else.

   Every occurrence is kind 1 (Text). LSP also has Read and Write, and Mere has
   no assignment: a name is bound once and read after that, so claiming to
   distinguish them would be inventing a difference the language does not have. *)
let document_highlight state uri (params : Json.t) =
  match ask state uri params with
  | None -> Json.List []
  | Some (prog, line, col) ->
    (match Query.references_at ~prelude_decls:(Pipeline.prelude_decl_count ())
             prog line col with
     | None -> Json.List []
     | Some (_, locs) ->
       Json.List (List.map (fun loc ->
         Json.Obj [ ("range", range_of_loc ~text:(doc_text state uri) loc);
                    ("kind", Json.Num 1.0) ]) locs))

(* Go to type definition: not where this name was bound, but where the TYPE it
   has was declared.

   The type is on the node (inference wrote it there); the declaration's
   position is in `Parser.declared_types`, which the parser fills as it reads
   each `type` / record declaration. `Top_type` itself carries no position,
   which is why that table exists at all.

   Prelude types are excluded: `list` and `option` are declared in a text that
   is prepended to every program, and sending an editor there is sending it to a
   file the person cannot open. *)
let type_definition state uri (params : Json.t) =
  match ask state uri params with
  | None -> Json.Null
  | Some (prog, line, col) ->
    (match Query.node_at prog line col with
     | None -> Json.Null
     | Some node ->
       (match node.Ast.ty with
        | None -> Json.Null
        | Some t ->
          (* The head of the type, through any alias chain the typer resolved:
             `int list` goes to `list`, which is what a person asking "what is
             this" means. A type with no name (a function, a tuple) has no
             declaration to go to. *)
          (match Ast.walk t with
           | Ast.TyCon (name, _) ->
             (match List.assoc_opt name !Parser.declared_types with
              | Some (loc : Loc.t) when loc.Loc.file = None && loc.Loc.line > 0 ->
                Json.Obj [ ("uri", Json.Str uri);
                           ("range", range_of_loc ~text:(doc_text state uri) loc) ]
              | _ -> Json.Null)
           | _ -> Json.Null)))

(* Signature help: what is being called here, and which argument is being typed.

   In a curried language this is a smaller question than it looks. `f a b` is
   `App (App (f, a), b)`, so `Ast.rv_spine` — which the range-check pass already
   uses — answers both halves at once: the head is what is being called, and the
   number of arguments already in the spine is which parameter comes next.

   FINDING THE CALL is the part with a guess in it. A `Loc.t` is a start and a
   width, so no node knows where it ends and "the call the cursor is inside" is
   not a question the tree can answer. What it can answer is "the nearest call
   head at or before the cursor, on this line", which is where the cursor is
   when an editor asks — right after typing a name and a space. A call that
   spans lines gets no help rather than the wrong help. *)
let signature_help state uri (params : Json.t) =
  match ask state uri params with
  | None -> Json.Null
  | Some (prog, line, col) ->
    let best = ref None in
    let consider (e : Ast.expr) =
      match e.Ast.node with
      | Ast.App _ ->
        let (head, args) = Ast.rv_spine e in
        (match head.Ast.node, head.Ast.ty with
         | Ast.Var name, Some ty
           when head.Ast.loc.Loc.line = line && head.Ast.loc.Loc.col <= col ->
           (* Arguments BEFORE THE CURSOR, not arguments in the call. The tree
              is the finished parse of the whole buffer, so the call always has
              all of them; what the editor is asking is how many the person has
              typed so far, and that is a question about positions. *)
           let n =
             List.length
               (List.filter (fun (a : Ast.expr) ->
                  a.Ast.loc.Loc.line < line
                  || (a.Ast.loc.Loc.line = line && a.Ast.loc.Loc.col < col)) args)
           in
           (* How many parameters this head has, to tell a call that is still
              being written from one that is finished. Without extents, that is
              the only way to stop answering about `pick` when the cursor has
              moved past `(pick Red)` and is filling in the call around it. *)
           let rec arity (t : Ast.ty) =
             match Ast.walk t with Ast.TyArrow (_, r) -> 1 + arity r | _ -> 0
           in
           let open_call = n < arity ty in
           let better =
             match !best with
             | None -> true
             | Some (c, k, o, _, _) ->
               (* An unfinished call beats a finished one wherever it is; among
                  equals, the nearest head, and then the longest spine (the
                  outermost App, which is the whole call). *)
               if open_call <> o then open_call
               else head.Ast.loc.Loc.col > c
                    || (head.Ast.loc.Loc.col = c && n > k)
           in
           if better then
             best := Some (head.Ast.loc.Loc.col, n, open_call, name, ty)
         | _ -> ())
      | _ -> ()
    in
    let rec walk (e : Ast.expr) = consider e; List.iter walk (Ast.children e) in
    List.iter (fun d -> List.iter walk (Ast.decl_exprs d)) prog.Ast.decls;
    walk prog.Ast.main;
    (match !best with
     | None -> Json.Null
     | Some (_, applied, _, name, ty) ->
       (* The parameters, left to right, off the arrow chain. `int -> str -> bool`
          has two; everything after them is the result. *)
       let rec params_of (t : Ast.ty) =
         match Ast.walk t with
         | Ast.TyArrow (p, r) -> Ast.pp_ty p :: params_of r
         | _ -> []
       in
       let ps = params_of ty in
       let label = name ^ " : " ^ Ast.pp_ty ty in
       Json.Obj [
         ("signatures",
          Json.List [
            Json.Obj [
              ("label", Json.Str label);
              ("parameters",
               Json.List (List.map (fun p -> Json.Obj [ ("label", Json.Str p) ]) ps));
            ] ]);
         ("activeSignature", Json.Num 0.0);
         (* Applied arguments are behind the cursor; the one being typed is the
            next. Clamped, because a fully applied call is still something an
            editor will ask about. *)
         ("activeParameter",
          Json.Num (float_of_int (min applied (max 0 (List.length ps - 1)))));
       ])

(* Find references, and rename, which are the same question: where else is *this*
   binding — not every name spelled the same. Shadowing is the difficulty, and it
   is answered by resolving each occurrence to the binding it refers to. *)
let references state uri (params : Json.t) =
  match ask state uri params with
  | None -> Json.List []
  | Some (prog, line, col) ->
    (match Query.references_at ~prelude_decls:(Pipeline.prelude_decl_count ())
             prog line col with
     | None -> Json.List []
     | Some (_, locs) ->
       Json.List (List.map (fun loc ->
         Json.Obj [ ("uri", Json.Str uri);
                    ("range", range_of_loc ~text:(doc_text state uri) loc) ]) locs))

(* What can be renamed: a binding this file owns. A prelude name or a builtin
   cannot be — the edit would rename the uses and leave the definition, which is
   worse than refusing. Answering the prepare request with an error is how the
   editor says so before offering a box to type in. *)
let renameable state uri params =
  match ask state uri params with
  | None -> None
  | Some (prog, line, col) ->
    (match Query.references_at ~prelude_decls:(Pipeline.prelude_decl_count ())
             prog line col with
     | Some (b, locs) when not b.Query.b_prelude && b.Query.b_loc.Loc.file = None ->
       Some (b, locs)
     | _ -> None)

let prepare_rename state uri params =
  match renameable state uri params with
  | None -> Json.Null
  | Some (b, _) ->
    Json.Obj [ ("range", range_of_loc ~text:(doc_text state uri) b.Query.b_loc);
               ("placeholder", Json.Str b.Query.b_name) ]

let rename state uri (params : Json.t) =
  match Json.to_string_opt (Json.member "newName" params) with
  | None -> Json.Null
  | Some new_name ->
    (match renameable state uri params with
     | None -> Json.Null
     | Some (_, locs) ->
       Json.Obj [
         ("changes",
          Json.Obj [
            (uri,
             Json.List (List.map (fun loc ->
               Json.Obj [ ("range", range_of_loc ~text:(doc_text state uri) loc);
                          ("newText", Json.Str new_name) ]) locs)) ]) ])

(* The outline. Kinds are the protocol's numbers: 12 is Function, 13 is Variable.
   The selection range is the name itself, which is what an editor highlights when
   you pick the entry; the full range is the same here, because a declaration's
   extent is not something the tree records. *)
let document_symbols state uri =
  match List.assoc_opt uri state.docs with
  | Some { tree = Some prog; _ } ->
    Json.List
      (List.map (fun (s : Query.symbol) ->
         let r = range_of_loc ~text:(doc_text state uri) s.Query.s_loc in
         Json.Obj [
           ("name", Json.Str s.Query.s_name);
           ("kind", Json.Num (if s.Query.s_is_fn then 12.0 else 13.0));
           ("range", r);
           ("selectionRange", r);
         ])
         (Query.symbols ~prelude_decls:(Pipeline.prelude_decl_count ()) prog))
  | _ -> Json.List []

(* Formatting: the whole document, replaced. `mere fmt` and this are the same
   function, so format-on-save and the command line cannot come to different
   conclusions about what formatted means.

   A file that does not parse is left alone. An editor asking to format a file
   mid-edit is normal, and replacing a buffer with the best guess of a parser
   that failed is how somebody loses work. *)
let formatting state uri =
  match List.assoc_opt uri state.docs with
  | None -> Json.List []
  | Some doc ->
    (match
       (try Some (Pipeline.format_source ?base_dir:(base_dir_of_uri uri) doc.text)
        with _ -> None)
     with
     | None -> Json.List []
     | Some formatted ->
       (* The formatter returns the program, and the CLI is what adds the final
          newline (`print_endline`). Without doing the same here, format-on-save
          would strip the trailing newline from every file, every time. *)
       let formatted =
         if formatted = "" || formatted.[String.length formatted - 1] = '\n'
         then formatted else formatted ^ "\n"
       in
       if formatted = doc.text then Json.List [] else
       (* The end of the document, counted the way the protocol does: one past
          the last line, character zero, which covers the final newline whether
          or not there is one. *)
       let lines = List.length (String.split_on_char '\n' doc.text) in
       Json.List [
         Json.Obj [
           ("range",
            Json.Obj [ ("start", position 1 1);
                       ("end", Json.Obj [ ("line", Json.Num (float_of_int lines));
                                          ("character", Json.Num 0.0) ]) ]);
           ("newText", Json.Str formatted);
         ]
       ])

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
       Json.Obj [ ("uri", Json.Str uri);
                  ("range", range_of_loc ~text:(doc_text state uri) loc) ])

(* --- code actions ---------------------------------------------------------

   An action is an answer the compiler already has, in the shape an editor can
   apply. Nothing here computes a new fact about the program: the missing arm
   was written by `Exhaustive` before the diagnostic was published, and the type
   in `let fn` is the one inference wrote on the value. What this adds is the
   edit — a position and the characters to put there — which is the part a
   sentence on a terminal cannot carry.

   Every action is built from the CURRENT document's own state, and the request
   names the range the cursor is in, so an action only appears where its subject
   is. *)

(* A zero-width range: an insertion point rather than a selection. `range_of_loc`
   widens to at least one character, which is right for an underline and wrong
   for this — it would make the edit REPLACE the character it starts at. *)
let range_at ?(text = "") (loc : Loc.t) =
  let p = position ~text loc.Loc.line loc.Loc.col in
  Json.Obj [ ("start", p); ("end", p) ]

(* `width` characters from `loc` are replaced; 0 of them is an insertion. *)
let text_edit ~text ?(width = 0) (loc : Loc.t) (s : string) =
  let range =
    if width <= 0 then range_at ~text loc
    else
      Json.Obj [ ("start", position ~text loc.Loc.line loc.Loc.col);
                 ("end", position ~text loc.Loc.line (loc.Loc.col + width)) ]
  in
  Json.Obj [ ("range", range); ("newText", Json.Str s) ]

let code_action ?(kind = "quickfix") ~uri ~edits title =
  Json.Obj [
    ("title", Json.Str title);
    ("kind", Json.Str kind);
    ("edit", Json.Obj [ ("changes", Json.Obj [ (uri, Json.List edits) ]) ]);
  ]

(* The lines the request is asking about, in Mere's 1-based counting. An action
   is offered when the thing it edits is on one of them. *)
let range_lines (params : Json.t) =
  let r = Json.member "range" params in
  let line_of side =
    Option.value ~default:(-1)
      (Json.to_int_opt (Json.member "line" (Json.member side r)))
  in
  (line_of "start" + 1, line_of "end" + 1)

(* Quickfixes: one per diagnostic that arrived with a fix attached. *)
let fix_actions state uri (params : Json.t) =
  let (lo, hi) = range_lines params in
  let text = doc_text state uri in
  match List.assoc_opt uri state.docs with
  | None -> []
  | Some d ->
    List.filter_map (fun (dg : Pipeline.diagnostic) ->
      match dg.Pipeline.d_fix with
      | None -> None
      (* The diagnostic's own line, not the fix's: the underline is what the
         person's cursor is on when they ask. *)
      | Some f when dg.Pipeline.d_loc.Loc.line >= lo && dg.Pipeline.d_loc.Loc.line <= hi ->
        Some (code_action ~uri
                ~edits:[ text_edit ~text ~width:f.Exhaustive.fx_width
                           f.Exhaustive.fx_at f.Exhaustive.fx_text ]
                f.Exhaustive.fx_title)
      | Some _ -> None)
      d.diags

(* `let fn NAME: TY;` above a top-level binding that has no such declaration.

   Mere has no annotation syntax on a `let` itself — the way to state a
   top-level name's type is the forward declaration — so this action writes
   that, on the line above. The type comes from inference, so accepting it can
   never change what the program means; what it can do is make the next change
   to that definition fail HERE, against a promise, instead of somewhere the
   inferred type leaked to. *)
let annotate_actions state uri (params : Json.t) =
  let (lo, hi) = range_lines params in
  let text = doc_text state uri in
  match List.assoc_opt uri state.docs with
  | Some { tree = Some prog; _ } ->
    let declared =
      List.filter_map (function
        | Ast.Top_forward (n, _, _) -> Some n
        | _ -> None) prog.Ast.decls
    in
    let n_prelude = Pipeline.prelude_decl_count () in
    List.concat (List.mapi (fun i decl ->
      if i < n_prelude then []
      else
        match decl with
        | Ast.Top_let ({ Ast.pnode = Ast.P_var name; ploc; _ }, (v : Ast.expr)) ->
          (match v.Ast.ty with
           | Some ty
             when ploc.Loc.file = None && ploc.Loc.line >= lo && ploc.Loc.line <= hi
                  && not (List.mem name declared) ->
             (* `let ` is four characters; the name's column is the only
                position the tree records for this declaration. *)
             let at = { ploc with Loc.col = max 1 (ploc.Loc.col - 4) } in
             let indent = String.make (at.Loc.col - 1) ' ' in
             [ code_action ~kind:"refactor.rewrite" ~uri
                 ~edits:[ text_edit ~text at
                            (Printf.sprintf "let fn %s: %s;\n%s" name (Ast.pp_ty ty) indent) ]
                 (Printf.sprintf "Declare `%s : %s`" name (Ast.pp_ty ty)) ]
           | _ -> [])
        | _ -> []) prog.Ast.decls)
  | _ -> []

let code_actions state uri (params : Json.t) =
  Json.List (fix_actions state uri params @ annotate_actions state uri params)

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
  | Some "textDocument/completion" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (completion state uri params) ], false)
     | None -> (state, [ response id (Json.List []) ], false))
  | Some "textDocument/signatureHelp" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (signature_help state uri params) ], false)
     | None -> (state, [ response id Json.Null ], false))
  | Some "textDocument/documentHighlight" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (document_highlight state uri params) ], false)
     | None -> (state, [ response id (Json.List []) ], false))
  | Some "textDocument/typeDefinition" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (type_definition state uri params) ], false)
     | None -> (state, [ response id Json.Null ], false))
  | Some "textDocument/references" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (references state uri params) ], false)
     | None -> (state, [ response id (Json.List []) ], false))
  | Some "textDocument/prepareRename" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (prepare_rename state uri params) ], false)
     | None -> (state, [ response id Json.Null ], false))
  | Some "textDocument/rename" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (rename state uri params) ], false)
     | None -> (state, [ response id Json.Null ], false))
  | Some "textDocument/documentSymbol" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (document_symbols state uri) ], false)
     | None -> (state, [ response id (Json.List []) ], false))
  | Some "textDocument/formatting" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (formatting state uri) ], false)
     | None -> (state, [ response id (Json.List []) ], false))
  | Some "textDocument/codeAction" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (code_actions state uri params) ], false)
     | None -> (state, [ response id (Json.List []) ], false))
  | Some "textDocument/semanticTokens/full" ->
    (match uri_of doc with
     | Some uri -> (state, [ response id (semantic_tokens state uri) ], false)
     | None -> (state, [ response id Json.Null ], false))
  | Some "textDocument/didOpen" ->
    (match uri_of doc, Json.to_string_opt (Json.member "text" doc) with
     | Some uri, Some text ->
       let (notes, tree, extra, diags) =
         check_document ?search_paths (extra_of state uri) uri text in
       (set_doc state uri text tree extra diags, notes, false)
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
             let (notes, tree, extra, diags) =
               check_document ?search_paths (extra_of state uri) uri text in
             (set_doc state uri text tree extra diags, notes, false)
           | None -> (state, [], false))
        | [] -> (state, [], false)))
  | Some "textDocument/didSave" ->
    (match uri_of doc with
     | Some uri ->
       (match List.assoc_opt uri state.docs with
        | Some d ->
          let (notes, tree, extra, diags) =
            check_document ?search_paths d.extra uri d.text in
          (set_doc state uri d.text tree extra diags, notes, false)
        | None -> (state, [], false))
     | None -> (state, [], false))
  | Some "textDocument/didClose" ->
    (match uri_of doc with
     | Some uri ->
       (* Clear the underlines — this file's and any it implicated: the file is
          no longer the editor's problem. *)
       let cleared = List.map (fun u -> publish u []) (extra_of state uri) in
       ({ state with docs = List.remove_assoc uri state.docs },
        publish uri [] :: cleared, false)
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
