let usage () =
  Printf.printf "lang-ml v%s\n" Lang_ml.Version.v;
  print_endline "";
  print_endline "Usage:";
  print_endline "  lang-ml <file.lang>     evaluate a Lang source file";
  print_endline "  lang-ml -e <expr>       evaluate an inline expression";
  print_endline "  lang-ml -t <file.lang>  print the inferred type";
  print_endline "  lang-ml -te <expr>      print the inferred type of an inline expression";
  print_endline "  lang-ml -c <file.lang>  emit C source for the program (Phase 4 prep, int subset)";
  print_endline "  lang-ml -ce <expr>      emit C source for an inline expression";
  print_endline "  lang-ml -r              start interactive REPL";
  print_endline "  lang-ml -h | --help     show this help"

let read_file path =
  In_channel.with_open_text path In_channel.input_all

let report_and_exit ~source ~filename loc kind msg =
  prerr_endline (Lang_ml.Diagnostic.format ~source ~filename loc kind msg);
  exit 1

let run_action action label source =
  try
    let result = action source in
    print_endline result
  with
  | Lang_ml.Lexer.Lex_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "lex error" msg
  | Lang_ml.Parser.Parse_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "parse error" msg
  | Lang_ml.Eval.Eval_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "eval error" msg
  | Lang_ml.Typer.Type_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "type error" msg
  | Lang_ml.Codegen_c.Codegen_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "codegen error" msg
  | Sys_error msg ->
    Printf.eprintf "io error: %s\n" msg;
    exit 1

let compile_to_c source =
  let prog = Lang_ml.Pipeline.parse_program source in
  (* Type-check first so we surface type errors before codegen, and
     capture the main expression's inferred type so codegen can pick
     the right printf format (int → %d, str → %s, unit → skip). *)
  let main_ty =
    Lang_ml.Typer.infer Lang_ml.Typer.initial_env
      (Lang_ml.Ast.desugar_program prog)
  in
  Lang_ml.Codegen_c.emit_program ~main_ty prog

let () =
  match Array.to_list Sys.argv with
  | [_] -> usage ()
  | [_; "-h"] | [_; "--help"] -> usage ()
  | [_; "-r"] -> Lang_ml.Repl.run ()
  | [_; "-e"; expr] ->
    run_action Lang_ml.Pipeline.process "<inline>" expr
  | [_; "-te"; expr] ->
    run_action Lang_ml.Pipeline.type_of "<inline>" expr
  | [_; "-ce"; expr] ->
    run_action compile_to_c "<inline>" expr
  | [_; "-c"; path] ->
    let source = read_file path in
    run_action compile_to_c path source
  | [_; "-t"; path] ->
    let source = read_file path in
    run_action Lang_ml.Pipeline.type_of path source
  | [_; path] ->
    let source = read_file path in
    run_action Lang_ml.Pipeline.process path source
  | _ ->
    usage ();
    exit 1
