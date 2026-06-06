let usage () =
  Printf.printf "lang-ml v%s\n" Lang_ml.Version.v;
  print_endline "usage: lang-ml <expression>";
  print_endline "example: lang-ml '1 + 2 * 3'"

let () =
  if Array.length Sys.argv < 2 then begin
    usage ();
    exit 0
  end;
  let input = Sys.argv.(1) in
  try
    let result = Lang_ml.Pipeline.process input in
    print_endline result
  with
  | Lang_ml.Lexer.Lex_error (loc, msg) ->
    Printf.eprintf "lex error at %s: %s\n" (Lang_ml.Loc.to_string loc) msg;
    exit 1
  | Lang_ml.Parser.Parse_error (loc, msg) ->
    Printf.eprintf "parse error at %s: %s\n" (Lang_ml.Loc.to_string loc) msg;
    exit 1
  | Lang_ml.Eval.Eval_error (loc, msg) ->
    Printf.eprintf "eval error at %s: %s\n" (Lang_ml.Loc.to_string loc) msg;
    exit 1
