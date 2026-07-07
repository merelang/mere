let usage () =
  Printf.printf "mere v%s\n" Mere.Version.v;
  print_endline "";
  print_endline "Usage:";
  print_endline "  mere <file.mere>      evaluate a Mere source file";
  print_endline "  mere -e <expr>        evaluate an inline expression";
  print_endline "  mere -t <file.mere>   print the inferred type";
  print_endline "  mere -te <expr>       print the inferred type of an inline expression";
  print_endline "  mere -c <file.mere>   emit C source (compile with clang)";
  print_endline "  mere -ce <expr>       emit C source for an inline expression";
  print_endline "  mere -ll <file.mere>  emit LLVM IR (compile with clang)";
  print_endline "  mere -lle <expr>      emit LLVM IR for an inline expression";
  print_endline "  mere -w <file.mere>   emit Wasm (WAT, use wat2wasm + Node.js)";
  print_endline "  mere -we <expr>       emit Wasm (WAT) for an inline expression";
  print_endline "  mere -r               start interactive REPL";
  print_endline "  mere fmt <file.mere>          format source (writes to stdout)";
  print_endline "  mere fmt -i <files...>        format in place (one or more)";
  print_endline "  mere fmt --check <files...>   exit 1 if any file needs formatting";
  print_endline "  mere -v | --version   print version";
  print_endline "  mere -h | --help      show this help";
  print_endline "";
  print_endline "Import search paths (Level 1 package system):";
  print_endline "  -I <dir>              add <dir> to the import search list";
  print_endline "                        (may be repeated). Used when a demo's";
  print_endline "                        `import \"contrib/foo.mere\"` isn't found";
  print_endline "                        relative to the source file.";
  print_endline "  MERE_PATH             colon-separated env var, same effect";
  print_endline "                        (evaluated after any -I flags).";
  print_endline "";
  print_endline "Docs: docs/tutorial.md / docs/language-reference.md / docs/stdlib-reference.md";
  print_endline "Examples: examples/ (118 .mere files; see examples/README.md for category index)"

let version () =
  Printf.printf "mere v%s\n" Mere.Version.v

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

(* Import search paths accumulated from `-I <dir>` flags and the
   `MERE_PATH` env var. Populated before the arg-parse match runs (see
   `preprocess_argv` at `main`), read here for every parse_program
   call. Level 1 package system: lets a Mere program in an unrelated
   repo `import "contrib/http/router.mere"` as long as the compiler
   was invoked with `-I /path/to/mere/checkout`. *)
let search_paths : string list ref = ref []

let infer_program ?base_dir source =
  let open Mere in
  let prog = Pipeline.parse_program ?base_dir ~search_paths:!search_paths source in
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
    | Ast.Top_sync name ->
      Typer.register_sync_type name
    | Ast.Top_local name ->
      Typer.register_local_type name
    | Ast.Top_extern (name, ty) ->
      type_env := (name, Typer.mono ty) :: !type_env
    | Ast.Top_extern_type type_name ->
      Typer.register_type type_name [] []
    | Ast.Top_ctor_alias (alias, target) ->
      Typer.alias_ctor alias target
    | Ast.Top_record_alias (alias, target) ->
      Typer.alias_record alias target
  ) prog.decls;
  let main_ty =
    Typer.infer !type_env (Ast.desugar_program prog)
  in
  (prog, main_ty)

let compile_to_c ?base_dir source =
  let open Mere in
  let (prog, main_ty) = infer_program ?base_dir source in
  Codegen_c.emit_program ~main_ty prog

let compile_to_llvm ?base_dir source =
  let open Mere in
  let (prog, main_ty) = infer_program ?base_dir source in
  Codegen_llvm.emit_program ~main_ty prog

let compile_to_wasm ?base_dir source =
  let open Mere in
  let (prog, main_ty) = infer_program ?base_dir source in
  Codegen_wasm.emit_program ~main_ty prog

(* Phase 47: mere fmt — re-emit the source through the parser + formatter.
   Comments are not preserved (the lexer discards them); we document this
   limitation in the usage text. We parse WITH the prelude (so prelude
   constructors like Cons / Nil are registered in the parser's table for
   pattern-arity lookup) and then skip the prelude decls when emitting,
   so the formatted output is just the user's own source. *)
let format_source ~base_dir source =
  let prelude_decls = Mere.Pipeline.parse_prelude () in
  let n_prelude = List.length prelude_decls in
  let prog = Mere.Pipeline.parse_program ~prelude:true ~base_dir
               ~search_paths:!search_paths source in
  let user_decls =
    let rec drop n xs = if n <= 0 then xs else match xs with
      | [] -> []
      | _ :: rest -> drop (n - 1) rest
    in
    drop n_prelude prog.decls
  in
  Mere.Formatter.format_program { prog with decls = user_decls }

(* Apply [f] to each file path; collect any lex/parse failures and
   report them with a code frame, then exit 1. Continues past
   individual file errors so the user sees all problems at once. *)
let fmt_each_file paths f =
  let had_error = ref false in
  List.iter (fun path ->
    try f path with
    | Mere.Lexer.Lex_error (loc, msg) ->
      had_error := true;
      let source = try read_file path with _ -> "" in
      prerr_endline (Mere.Diagnostic.format ~source ~filename:path loc "lex error" msg)
    | Mere.Parser.Parse_error (loc, msg) ->
      had_error := true;
      let source = try read_file path with _ -> "" in
      prerr_endline (Mere.Diagnostic.format ~source ~filename:path loc "parse error" msg)
    | Sys_error msg ->
      had_error := true;
      Printf.eprintf "io error: %s\n" msg
  ) paths;
  if !had_error then exit 1

(* --check: print each file that would be reformatted and exit 1 if any
   differ. Mirrors `gofmt -l` / `rustfmt --check`. *)
let fmt_check_files paths =
  let any_differs = ref false in
  fmt_each_file paths (fun path ->
    let source = read_file path in
    let base = Filename.dirname path in
    let formatted = format_source ~base_dir:base source in
    if formatted <> source then begin
      any_differs := true;
      print_endline path
    end);
  if !any_differs then exit 1

(* -i: rewrite each file in place. *)
let fmt_inplace_files paths =
  fmt_each_file paths (fun path ->
    let source = read_file path in
    let base = Filename.dirname path in
    let formatted = format_source ~base_dir:base source in
    if formatted <> source then
      Out_channel.with_open_text path (fun oc ->
        Out_channel.output_string oc formatted))

(* Default mode: write to stdout. Only one path allowed (multi-file
   stdout would just concatenate, which is rarely what users want). *)
let fmt_to_stdout path =
  let source = read_file path in
  let base = Filename.dirname path in
  run_action (format_source ~base_dir:base) path source

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

(* Sift `-I <dir>` pairs out of argv (Level 1 package system: extra
   import search paths). Also read `MERE_PATH` — colon-separated dir
   list, same convention as `PATH`. `-I` flags come first in
   `search_paths`, then env vars, so an explicit `-I` on the command
   line wins over the ambient env. *)
let preprocess_argv () : string array =
  let argv = Array.to_list Sys.argv in
  let path_from_env =
    match Sys.getenv_opt "MERE_PATH" with
    | None | Some "" -> []
    | Some s -> String.split_on_char ':' s |> List.filter (fun x -> x <> "")
  in
  let rec walk kept dirs = function
    | [] -> (List.rev kept, List.rev dirs)
    | "-I" :: d :: rest -> walk kept (d :: dirs) rest
    | tok :: rest -> walk (tok :: kept) dirs rest
  in
  let (kept, dashI_dirs) = walk [] [] argv in
  search_paths := dashI_dirs @ path_from_env;
  Array.of_list kept

let () =
  match Array.to_list (preprocess_argv ()) with
  | [_] -> usage ()
  | [_; "-h"] | [_; "--help"] -> usage ()
  | [_; "-v"] | [_; "--version"] -> version ()
  | [_; "-r"] -> Mere.Repl.run ()
  | _ :: "fmt" :: "-i" :: (_ :: _ as paths) ->
    fmt_inplace_files paths
  | _ :: "fmt" :: "--check" :: (_ :: _ as paths) ->
    fmt_check_files paths
  | [_; "fmt"; path] ->
    fmt_to_stdout path
  | _ :: "fmt" :: (_ :: _ :: _ as paths) ->
    Printf.eprintf
      "error: `mere fmt` writes to stdout and only accepts one file.\n\
       Use `mere fmt -i <files...>` to format in place, or\n\
       `mere fmt --check <files...>` to check without rewriting.\n";
    let _ = paths in
    exit 1
  | [_; "fmt"] ->
    prerr_endline "error: `mere fmt` requires a file path";
    exit 1
  | [_; "-e"; expr] ->
    run_action Mere.Pipeline.process "<inline>" expr
  | [_; "-te"; expr] ->
    run_action Mere.Pipeline.type_of "<inline>" expr
  | [_; "-ce"; expr] ->
    run_action compile_to_c "<inline>" expr
  | [_; "-c"; path] ->
    let source = read_file path in
    let base = Filename.dirname path in
    run_action (compile_to_c ~base_dir:base) path source
  | [_; "-lle"; expr] ->
    run_action compile_to_llvm "<inline>" expr
  | [_; "-ll"; path] ->
    let source = read_file path in
    let base = Filename.dirname path in
    run_action (compile_to_llvm ~base_dir:base) path source
  | [_; "-we"; expr] ->
    run_action compile_to_wasm "<inline>" expr
  | [_; "-w"; path] ->
    let source = read_file path in
    let base = Filename.dirname path in
    run_action (compile_to_wasm ~base_dir:base) path source
  | [_; "-t"; path] ->
    let source = read_file path in
    run_action Mere.Pipeline.type_of path source
  | [_; path] when String.length path > 0 && path.[0] = '-' ->
    Printf.eprintf "error: unknown flag `%s`\n\n" path;
    usage ();
    exit 1
  | [_; path] ->
    let source = read_file path in
    (* Phase 9.5: importer-relative path resolution — pre-set Parser's
       base_dir to this file's dir so `import "./foo.lang"` inside
       resolves relative to the running file. *)
    let base = Filename.dirname path in
    run_action (Mere.Pipeline.process ~base_dir:base) path source
  | _ :: path :: _rest_args when String.length path > 0 && path.[0] <> '-' ->
    (* Phase 44: `mere <path> arg1 arg2 ...` — pass extra args to the program.
       Since Sys.argv is retained by the OCaml runtime, eval's `args ()`
       builtin can see rest_args. Only file execution is handled here. *)
    let source = read_file path in
    let base = Filename.dirname path in
    run_action (Mere.Pipeline.process ~base_dir:base) path source
  | _ ->
    usage ();
    exit 1
