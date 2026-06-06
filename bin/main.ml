let usage () =
  Printf.printf "lang-ml v%s\n" Lang_ml.Version.v;
  print_endline "";
  print_endline "Usage:";
  print_endline "  lang-ml <file.lang>     evaluate a Lang source file";
  print_endline "  lang-ml -e <expr>       evaluate an inline expression";
  print_endline "  lang-ml -t <file.lang>  print the inferred type";
  print_endline "  lang-ml -te <expr>      print the inferred type of an inline expression";
  print_endline "  lang-ml -h | --help     show this help"

let read_file path =
  In_channel.with_open_text path In_channel.input_all

let run_action action label source =
  try
    let result = action source in
    print_endline result
  with
  | Lang_ml.Lexer.Lex_error (loc, msg) ->
    Printf.eprintf "%s: lex error at %s: %s\n" label (Lang_ml.Loc.to_string loc) msg;
    exit 1
  | Lang_ml.Parser.Parse_error (loc, msg) ->
    Printf.eprintf "%s: parse error at %s: %s\n" label (Lang_ml.Loc.to_string loc) msg;
    exit 1
  | Lang_ml.Eval.Eval_error (loc, msg) ->
    Printf.eprintf "%s: eval error at %s: %s\n" label (Lang_ml.Loc.to_string loc) msg;
    exit 1
  | Lang_ml.Typer.Type_error (loc, msg) ->
    Printf.eprintf "%s: type error at %s: %s\n" label (Lang_ml.Loc.to_string loc) msg;
    exit 1
  | Sys_error msg ->
    Printf.eprintf "io error: %s\n" msg;
    exit 1

let () =
  match Array.to_list Sys.argv with
  | [_] -> usage ()
  | [_; "-h"] | [_; "--help"] -> usage ()
  | [_; "-e"; expr] ->
    run_action Lang_ml.Pipeline.process "<inline>" expr
  | [_; "-te"; expr] ->
    run_action Lang_ml.Pipeline.type_of "<inline>" expr
  | [_; "-t"; path] ->
    let source = read_file path in
    run_action Lang_ml.Pipeline.type_of path source
  | [_; path] ->
    let source = read_file path in
    run_action Lang_ml.Pipeline.process path source
  | _ ->
    usage ();
    exit 1
