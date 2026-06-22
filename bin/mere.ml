let usage () =
  Printf.printf "mere v%s\n" Mere.Version.v;
  print_endline "";
  print_endline "Usage:";
  print_endline "  mere <file.mere>     evaluate a Mere source file";
  print_endline "  mere -e <expr>       evaluate an inline expression";
  print_endline "  mere -t <file.mere>  print the inferred type";
  print_endline "  mere -te <expr>      print the inferred type of an inline expression";
  print_endline "  mere -c <file.mere>  emit C source for the program (Phase 4 prep, int subset)";
  print_endline "  mere -ce <expr>      emit C source for an inline expression";
  print_endline "  mere -ll <file.mere> emit LLVM IR for the program (Phase 5 prep, int subset)";
  print_endline "  mere -lle <expr>     emit LLVM IR for an inline expression";
  print_endline "  mere -w <file.mere>  emit Wasm (WAT) for the program (Phase 6 prep, int subset)";
  print_endline "  mere -we <expr>      emit Wasm (WAT) for an inline expression";
  print_endline "  mere -r              start interactive REPL";
  print_endline "  mere -h | --help     show this help"

let read_file path =
  In_channel.with_open_text path In_channel.input_all

let report_and_exit ~source ~filename loc kind msg =
  prerr_endline (Mere.Diagnostic.format ~source ~filename loc kind msg);
  exit 1

let run_action action label source =
  try
    let result = action source in
    print_endline result
  with
  | Mere.Lexer.Lex_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "lex error" msg
  | Mere.Parser.Parse_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "parse error" msg
  | Mere.Eval.Eval_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "eval error" msg
  | Mere.Typer.Type_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "type error" msg
  | Mere.Codegen_c.Codegen_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "codegen error" msg
  | Mere.Codegen_llvm.Codegen_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "codegen error" msg
  | Mere.Codegen_wasm.Codegen_error (loc, msg) ->
    report_and_exit ~source ~filename:label loc "codegen error" msg
  | Sys_error msg ->
    Printf.eprintf "io error: %s\n" msg;
    exit 1

let infer_program source =
  let open Mere in
  let prog = Pipeline.parse_program source in
  let type_env = ref Typer.initial_env in
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (pat, value) ->
      let outer_env = !type_env in
      let t = Typer.infer outer_env value in
      let bindings = Typer.check_pattern pat t in
      type_env := List.fold_left (fun acc (n, ty) ->
        let sch = Typer.generalize outer_env ty in
        (n, sch) :: acc) outer_env bindings
    | Ast.Top_let_rec bindings ->
      let outer_env = !type_env in
      let alphas = List.map (fun _ -> Typer.fresh_var ()) bindings in
      let env_rec = List.fold_left2 (fun acc (n, _) a ->
        (n, Typer.mono a) :: acc) outer_env bindings alphas in
      List.iter2 (fun (_, value) alpha ->
        let t = Typer.infer env_rec value in
        Typer.unify value.Ast.loc alpha t) bindings alphas;
      type_env := List.fold_left2 (fun acc (n, _) a ->
        let sch = Typer.generalize outer_env a in
        (n, sch) :: acc) outer_env bindings alphas
    | Ast.Top_type (name, params, variants) ->
      Typer.register_type name params variants
    | Ast.Top_signature _ -> ()
    | Ast.Top_record (name, params, fields) ->
      Typer.register_record name params fields
    | Ast.Top_type_alias _ -> ()
    | Ast.Top_view (name, region, fields) ->
      Typer.register_view name region fields
    | Ast.Top_drop name ->
      Typer.register_drop_type name
    | Ast.Top_extern (name, ty) ->
      type_env := (name, Typer.mono ty) :: !type_env
    | Ast.Top_ctor_alias (alias, target) ->
      Typer.alias_ctor alias target
    | Ast.Top_record_alias (alias, target) ->
      Typer.alias_record alias target
  ) prog.decls;
  let main_ty =
    Typer.infer !type_env (Ast.desugar_program prog)
  in
  (prog, main_ty)

let compile_to_c source =
  let open Mere in
  let (prog, main_ty) = infer_program source in
  Codegen_c.emit_program ~main_ty prog

let compile_to_llvm source =
  let open Mere in
  let (prog, main_ty) = infer_program source in
  Codegen_llvm.emit_program ~main_ty prog

let compile_to_wasm source =
  let open Mere in
  let (prog, main_ty) = infer_program source in
  Codegen_wasm.emit_program ~main_ty prog

(* Enable ANSI color in diagnostics when stderr is a TTY and the
   environment hasn't opted out via NO_COLOR (https://no-color.org/). *)
let () =
  let no_color =
    match Sys.getenv_opt "NO_COLOR" with
    | Some "" | None -> false
    | Some _ -> true
  in
  if not no_color && Unix.isatty Unix.stderr then
    Mere.Diagnostic.use_color := true

let () =
  match Array.to_list Sys.argv with
  | [_] -> usage ()
  | [_; "-h"] | [_; "--help"] -> usage ()
  | [_; "-r"] -> Mere.Repl.run ()
  | [_; "-e"; expr] ->
    run_action Mere.Pipeline.process "<inline>" expr
  | [_; "-te"; expr] ->
    run_action Mere.Pipeline.type_of "<inline>" expr
  | [_; "-ce"; expr] ->
    run_action compile_to_c "<inline>" expr
  | [_; "-c"; path] ->
    let source = read_file path in
    run_action compile_to_c path source
  | [_; "-lle"; expr] ->
    run_action compile_to_llvm "<inline>" expr
  | [_; "-ll"; path] ->
    let source = read_file path in
    run_action compile_to_llvm path source
  | [_; "-we"; expr] ->
    run_action compile_to_wasm "<inline>" expr
  | [_; "-w"; path] ->
    let source = read_file path in
    run_action compile_to_wasm path source
  | [_; "-t"; path] ->
    let source = read_file path in
    run_action Mere.Pipeline.type_of path source
  | [_; path] ->
    let source = read_file path in
    (* Phase 9.5: importer-relative path resolution — pre-set Parser's
       base_dir to this file's dir so `import "./foo.lang"` inside
       resolves relative to the running file. *)
    let base = Filename.dirname path in
    run_action (Mere.Pipeline.process ~base_dir:base) path source
  | _ ->
    usage ();
    exit 1
