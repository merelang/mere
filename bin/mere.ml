let usage () =
  Printf.printf "mere v%s\n" Mere.Version.v;
  print_endline "";
  print_endline "Usage:";
  print_endline "  mere <file.mere>      evaluate a Mere source file";
  print_endline "  mere -e <expr>        evaluate an inline expression";
  print_endline "  mere -t <file.mere>   print the inferred type";
  print_endline "  mere -te <expr>       print the inferred type of an inline expression";
  print_endline "        -t and -te ANSWER A TYPE QUESTION, they do not accept the";
  print_endline "        program: the borrow and thread-capture checks do not run,";
  print_endline "        so a type here is not a promise that `mere -c` will build it";
  print_endline "  mere -c <file.mere>   emit C source (compile with clang)";
  print_endline "  mere -ce <expr>       emit C source for an inline expression";
  print_endline "        -c and -ll take `-g`: debug information back to the .mere";
  print_endline "        source, so a debugger shows the program you wrote";
  print_endline "  mere -ll <file.mere>  emit LLVM IR (compile with clang)";
  print_endline "  mere -lle <expr>      emit LLVM IR for an inline expression";
  print_endline "  mere -w <file.mere>   emit Wasm (WAT, use wat2wasm + Node.js)";
  print_endline "  mere -we <expr>       emit Wasm (WAT) for an inline expression";
  print_endline "  mere -wg <file.mere>  print the table a Wasm source map is built";
  print_endline "                        from (see scripts/wasm_sourcemap.js)";
  print_endline "  mere -w --component <file.mere>";
  print_endline "                        emit Wasm in Component Model shape (exports";
  print_endline "                        run + cabi_realloc; feed to wasm-tools component)";
  print_endline "  mere -c --lib <file.mere>";
  print_endline "                        emit C for a shared library instead of a program:";
  print_endline "                        no main; exports mere_<stem>_<fn> wrappers plus";
  print_endline "                        mere_lib_init / mere_lib_shutdown / mere_lib_free";
  print_endline "  mere --header <file.mere>";
  print_endline "                        print the C header for that boundary";
  print_endline "  mere -rv <file.mere>  emit a flat RV32IM binary (runs on the Mere RISC-V";
  print_endline "                        emulator; integer subset — see codegen_riscv.ml)";
  print_endline "  mere -rve <expr>      emit an RV32IM binary for an inline expression";
  print_endline "  mere -rvs <file.mere> print an RV32IM assembly listing (disassembled)";
  print_endline "  mere -rvd <file.bin>  disassemble a flat RV32IM binary";
  print_endline "  mere -rvg <file.mere> print the debug map (symbols, frames, line table)";
  print_endline "        -rv/-rvs/-rvg accept these in any order:";
  print_endline "        `--ram <MB>` (default 8): the RAM the binary expects —";
  print_endline "        the stack starts at the top of it";
  print_endline "        `--load-base <addr>`: load somewhere other than 0";
  print_endline "        (QEMU virt wants 0x80000000 — see docs/bare-metal.md)";
  print_endline "        `--bare`: no host syscalls; the program's top-level";
  print_endline "        `main` is handed the machine as a `Raw` capability";
  print_endline "  mere -r               start interactive REPL";
  print_endline "  mere lsp              run the language server (JSON-RPC on stdin/stdout)";
  print_endline "  mere fmt <file.mere>          format source (writes to stdout)";
  print_endline "  mere fmt -i <files...>        format in place (one or more)";
  print_endline "  mere fmt --check <files...>   exit 1 if any file needs formatting";
  print_endline "  mere install [dir]            fetch mere.toml deps into .mere_modules/";
  print_endline "  mere serve <file.wasm>        run a .wasm on the vendored Node host (.mere_host/)";
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
  print_endline "Examples: examples/ (280 .mere files; see examples/README.md for category index)"

let version () =
  Printf.printf "mere v%s\n" Mere.Version.v

let read_file path =
  In_channel.with_open_text path In_channel.input_all

(* Import search paths accumulated from `-I <dir>` flags and the
   `MERE_PATH` env var. Populated before the arg-parse match runs (see
   `preprocess_argv` at `main`), read here for every parse_program
   call. Level 1 package system: lets a Mere program in an unrelated
   repo `import "contrib/http/router.mere"` as long as the compiler
   was invoked with `-I /path/to/mere/checkout`. *)
let search_paths : string list ref = ref []

(* `~rv` marks the RV32I paths, which compile a *concatenation* — the Mere-source
   prelude, then the user's file. Every position a diagnostic carries is counted
   from the top of that text, so without this a type error in a three-line file
   was reported at "line 133", against a snippet from the wrong line or none at
   all. The debug map (`-rvg`) already subtracted the prelude; the diagnostics
   did not.

   A position inside the prelude is not remapped into the user's file, because
   there is no honest line there to point at: it is shown against the prelude's
   own text instead, which also makes a prelude bug legible as one. *)
let run_action ?(rv = false) ?base_dir action label source =
  let render ~source ~filename loc kind msg =
    Mere.Diagnostic.format ~source ~filename loc kind msg
  in
  let locate (loc : Mere.Loc.t) =
    (* A position that names a file came from an `import`: it is about that file's
       line 12, not this one's, so it is rendered against that file. *)
    match loc.Mere.Loc.file with
    | Some f -> ((try read_file f with _ -> ""), f, loc)
    | None ->
      (* On the -rv paths a position is counted from the top of the prelude the
         driver glued in front of the source; see Rv_prelude.origin_of. *)
      if not rv then (source, label, loc)
      else
        match Mere.Rv_prelude.origin_of loc with
        | Mere.Rv_prelude.User loc -> (source, label, loc)
        | Mere.Rv_prelude.Prelude loc ->
          (Mere.Rv_prelude.contents, "<rv-prelude>", loc)
  in
  let report loc kind msg =
    let (src, name, loc) = locate loc in
    prerr_endline (render ~source:src ~filename:name loc kind msg);
    exit 1
  in
  (* A syntax error is never the only one worth knowing about: the parse stopped
     at the first, but the file may have five. Re-parse with declaration-level
     recovery and report all of them, in source order. Only reached when the
     compile already failed, so the second pass costs nothing on a good file. *)
  let report_syntax loc msg =
    let all =
      try Mere.Pipeline.syntax_errors ?base_dir ~search_paths:!search_paths source
      with _ -> []
    in
    match all with
    (* Nothing more to say than the parse already did — including the case where
       the user's file is fine and the error is in a prelude glued in front of
       it, which the re-parse of that file alone cannot see. *)
    | [] | [_] -> report loc "parse error" msg
    | _ ->
      (* These positions came from parsing the user's source on its own, so they
         are already the lines they wrote — no prelude to subtract. *)
      let blocks =
        List.map (fun (file, l, m) ->
          (* An error from an imported file is rendered against that file, whose
             lines its position actually refers to. *)
          match file with
          | Some f ->
            render ~source:(try read_file f with _ -> "") ~filename:f l
              "parse error" m
          | None ->
            let (src, name, l) = locate l in
            render ~source:src ~filename:name l "parse error" m) all
      in
      prerr_endline (String.concat "\n\n" blocks);
      Printf.eprintf "\n%d syntax errors\n" (List.length all);
      exit 1
  in
  (* Warnings the check collected. They used to be printed from inside the
     pipeline, which meant nothing but a terminal could ever see them; now the
     pipeline hands them over and the CLI decides how they look. *)
  let print_warnings () =
    List.iter (fun (loc, msg) ->
      Printf.eprintf "%s: warning: %s\n%!" (Mere.Loc.to_string loc) msg)
      (Mere.Pipeline.take_warnings ())
  in
  (* The same courtesy for type errors that `report_syntax` does for syntax ones:
     the compile stopped at the first, but the file may have four. Re-check with
     the recovering path and print all of them. Only reached once something has
     already failed, so a good file pays nothing. *)
  let report_type loc msg =
    let all =
      try
        List.filter (fun (d : Mere.Pipeline.diagnostic) ->
          d.Mere.Pipeline.d_severity = Mere.Pipeline.Error)
          (Mere.Pipeline.diagnostics ?base_dir ~search_paths:!search_paths source)
      with _ -> []
    in
    match all with
    | [] | [_] -> report loc "type error" msg
    | _ ->
      let blocks =
        List.map (fun (d : Mere.Pipeline.diagnostic) ->
          let (src, name, loc) = locate d.Mere.Pipeline.d_loc in
          render ~source:src ~filename:name loc
            d.Mere.Pipeline.d_kind d.Mere.Pipeline.d_msg) all
      in
      prerr_endline (String.concat "\n\n" blocks);
      Printf.eprintf "\n%d errors\n" (List.length all);
      exit 1
  in
  try
    let result = action source in
    print_warnings ();
    print_endline result
  with
  | Mere.Lexer.Lex_error (loc, msg) -> print_warnings (); report loc "lex error" msg
  | Mere.Parser.Parse_error_in_file (file, loc, msg) ->
    (* The position is a line in the imported file, so it is reported against
       that file rather than against the one being compiled. *)
    print_warnings ();
    prerr_endline
      (Mere.Diagnostic.format ~source:(try read_file file with _ -> "")
         ~filename:file loc "parse error" msg);
    exit 1
  | Mere.Parser.Parse_error (loc, msg) -> report_syntax loc msg
  | Mere.Eval.Eval_error (loc, msg) -> report loc "eval error" msg
  | Mere.Typer.Type_error (loc, msg) -> print_warnings (); report_type loc msg
  | Mere.Trait_elab.Trait_error (loc, msg) -> report loc "trait error" msg
  | Mere.Codegen_c.Codegen_error (loc, msg) -> report loc "codegen error" msg
  | Mere.Codegen_llvm.Codegen_error (loc, msg) -> report loc "codegen error" msg
  | Mere.Codegen_wasm.Codegen_error (loc, msg) -> report loc "codegen error" msg
  | Mere.Codegen_riscv.Codegen_error (loc, msg) -> report loc "codegen error" msg
  | Failure msg ->
    (* An assembler-level failure -- an undefined label, or a jump past the reach
       of the instruction that has to carry it. OCaml's default for this is
       "Fatal error: exception Failure(...)" and exit 2, which reads as a crash
       when the honest answer is that this backend cannot assemble that program.
       Caught for the reason Out_of_memory and Stack_overflow are, just below:
       the host runtime's words are not the language's. *)
    prerr_endline msg;
    exit 1
  | Out_of_memory ->
    (* v0.1.274: OCaml's default is "Fatal error: exception Out of memory" and
       exit 2 -- the host runtime's words again, and a different exit code than
       the compiled backends give the same program. *)
    prerr_endline "out of memory";
    exit 1
  | Stack_overflow ->
    (* v0.1.271: OCaml's default for this is "Fatal error: exception Stack
       overflow" and exit 2 -- the host runtime's words, not the language's, and
       a different exit code than the same program gets on the other three
       backends. The failure is one a Mere program can cause on purpose, so it
       is named the way the compiled backends name it. *)
    prerr_endline "stack overflow (recursion too deep)";
    exit 1
  | Sys_error msg ->
    Printf.eprintf "io error: %s\n" msg;
    exit 1

(* --component: emit the Wasm backend in WebAssembly Component Model shape
   (exports `run` + `cabi_realloc`, no ambient env imports). Opt-in; the
   default core-module output is unchanged. Extracted from argv in
   preprocess_argv, like -I. *)
let component_flag : bool ref = ref false

let infer_program ?base_dir source =
  Mere.Pipeline.infer_program ?base_dir ~search_paths:!search_paths source

(* `-c -g <file>`: the emitted C carries `#line` directives back to the Mere
   source, so a debugger on the compiled program shows the program that was
   written rather than the one that was generated. *)
let set_c_debug path = Mere.Codegen_c.debug_file := Some path

(* --lib: the wrapper prefix is `mere_<stem>_`, where <stem> is the source
   filename made into a C identifier. Set whenever a `-c` invocation has a
   real path; the inline `-ce` form keeps the default ("lib"). *)
let set_lib_stem path =
  if !Mere.Codegen_c.lib_mode then begin
    let base = Filename.remove_extension (Filename.basename path) in
    let b = Bytes.of_string base in
    Bytes.iteri (fun i c ->
      let ok =
        (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c = '_'
      in
      if not ok then Bytes.set b i '_') b;
    let stem = Bytes.to_string b in
    let stem = if stem = "" then "lib"
      else if stem.[0] >= '0' && stem.[0] <= '9' then "_" ^ stem
      else stem in
    Mere.Codegen_c.lib_stem := stem
  end

let compile_to_c ?base_dir source =
  let open Mere in
  let (prog, main_ty) = infer_program ?base_dir source in
  Codegen_c.emit_program ~main_ty prog

let compile_to_llvm ?base_dir source =
  let open Mere in
  let (prog, main_ty) = infer_program ?base_dir source in
  Codegen_llvm.emit_program ~main_ty prog

(* `-wg`: the table that a source map is built from. See scripts/wasm_sourcemap.js,
   which matches it against the assembled binary. *)
let wasm_debug_map ~path ?base_dir source =
  let open Mere in
  let (prog, main_ty) = infer_program ?base_dir source in
  Codegen_wasm.emit_debug_map ~main_ty ~component:!component_flag ~source:path prog

let compile_to_wasm ?base_dir source =
  let open Mere in
  let (prog, main_ty) = infer_program ?base_dir source in
  Codegen_wasm.emit_program ~main_ty ~component:!component_flag prog

(* The RV32I backend prepends a Mere-source runtime prelude (string / Map /
   char-class helpers written on top of the primitives codegen_riscv emits).
   It carries no imports, so gluing it ahead of the user source is safe;
   line-number shifts in diagnostics are the only cost. *)
let rv_source source = Mere.Rv_prelude.contents ^ "\n" ^ source

(* `--ram <MB>` sets the RAM the emitted binary expects: the stack starts at
   the top of it and the heap grows up from 2MB, so this is the knob for a
   program whose live heap outgrows the 8MB default. The emulator running the
   binary has to be sized to match. *)
let set_riscv_ram mb =
  let n = try int_of_string mb with _ -> 0 in
  (* the ceiling keeps RAM below the device MMIO region, so a device address
     never moves when the RAM size does *)
  let max_mb = Mere.Codegen_riscv.mmio_base / (1024 * 1024) in
  if n < 4 || n > max_mb then begin
    Printf.eprintf
      "error: --ram takes a size in MB, from 4 to %d (got `%s`)\n" max_mb mb;
    exit 1
  end;
  Mere.Codegen_riscv.ram_bytes := n * 1024 * 1024

let compile_to_riscv ?base_dir source =
  let open Mere in
  let (prog, main_ty) = infer_program ?base_dir (rv_source source) in
  Codegen_riscv.emit_program ~main_ty prog

let listing_riscv ?base_dir source =
  let open Mere in
  let (prog, main_ty) = infer_program ?base_dir (rv_source source) in
  Codegen_riscv.emit_listing ~main_ty prog

(* `--load-base <hex or dec>` puts the program somewhere other than address 0.
   A kernel loading a user process decides where it goes; everything absolute in
   the emitted binary (globals, stack, string literals) shifts with it. *)
let set_riscv_load_base v =
  let n = try int_of_string v with _ -> -1 in
  if n < 0 || n land 0xFFF <> 0 then begin
    Printf.eprintf
      "error: --load-base takes a 4KB-aligned address (got `%s`)\n" v;
    exit 1
  end;
  Mere.Codegen_riscv.load_base := n

let debug_map_riscv ?base_dir source =
  let open Mere in
  Codegen_riscv.dbg_line_base := Rv_prelude.lines ();
  let (prog, main_ty) = infer_program ?base_dir (rv_source source) in
  Codegen_riscv.emit_debug_map ~main_ty prog

(* The RV32I family takes three independent switches — `--bare`, `--ram <MB>`,
   `--load-base <addr>` — and matching them as literal argument lists means one
   arm per combination, so the arms that existed were the combinations somebody
   had needed so far. Booting QEMU's `virt` machine wants all three at once
   (bare, at 0x80000000, with a RAM size), which had no arm. Parse them in any
   order instead, once, for every mode that accepts them. *)
let rv_flags mode args =
  let rec go = function
    | "--bare" :: rest -> Mere.Codegen_riscv.bare := true; go rest
    | "--ram" :: mb :: rest -> set_riscv_ram mb; go rest
    | "--load-base" :: b :: rest -> set_riscv_load_base b; go rest
    | [path] when String.length path > 0 && path.[0] <> '-' -> Some path
    | _ -> None
  in
  match go args with
  | None -> None
  | Some path ->
    let base_dir = Filename.dirname path in
    let action =
      match mode with
      | "-rv" -> compile_to_riscv ~base_dir
      | "-rvs" -> listing_riscv ~base_dir
      | _ -> debug_map_riscv ~base_dir
    in
    Some (fun () -> run_action ~rv:true ~base_dir action path (read_file path))

(* Phase 47: mere fmt — re-emit the source through the parser + formatter.
   Comments are not preserved (the lexer discards them); we document this
   limitation in the usage text. We parse WITH the prelude (so prelude
   constructors like Cons / Nil are registered in the parser's table for
   pattern-arity lookup) and then skip the prelude decls when emitting,
   so the formatted output is just the user's own source. *)
let format_source ~base_dir source =
  Mere.Pipeline.format_source ~base_dir ~search_paths:!search_paths source

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
  run_action ~base_dir:base (format_source ~base_dir:base) path source

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
    | "--component" :: rest -> component_flag := true; walk kept dirs rest
    | "--lib" :: rest -> Mere.Codegen_c.lib_mode := true; walk kept dirs rest
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
  (* One line per name in the typer's initial environment, `name<TAB>type`.
     scripts/host_matrix.sh used to carry a hand-written list of builtins to probe,
     which is how fifteen names that no compiled backend implements went unnoticed:
     the harness whose job is to ask which backend has which builtin was asking
     about a set somebody remembered. Now it asks for the set too. *)
  | [_; "--dump-builtins"] ->
    List.iter
      (fun (name, (sch : Mere.Typer.scheme)) ->
        Printf.printf "%s\t%s\n" name (Mere.Ast.pp_ty sch.body))
      Mere.Typer.initial_env
  | [_; "-r"] -> Mere.Repl.run ()
  | [_; "install"] | [_; "install"; _] ->
    let root =
      match Array.to_list (preprocess_argv ()) with
      | [_; "install"; dir] -> dir
      | _ -> "."
    in
    (try Mere.Pkg_install.install ~root
     with Mere.Pkg_install.Install_error msg ->
       Printf.eprintf "install error: %s\n" msg; exit 1)
  | [_; "serve"; wasm] ->
    (* Run a compiled .wasm on the vendored Node host (.mere_host/,
       populated by `mere install` from a [host] entry). *)
    let host = Filename.concat ".mere_host" "run_http_server.js" in
    if not (Sys.file_exists host) then begin
      Printf.eprintf
        "error: %s not found — run `mere install` first \
         (needs a [host] section in mere.toml)\n" host;
      exit 1
    end;
    exit (Sys.command
            (Printf.sprintf "node %s %s" (Filename.quote host) (Filename.quote wasm)))
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
  | [_; "-ll"; "-g"; path] | [_; "-ll"; path; "-g"] ->
    Mere.Codegen_llvm.debug_file := Some path;
    let source = read_file path in
    let base = Filename.dirname path in
    run_action ~base_dir:base (compile_to_llvm ~base_dir:base) path source
  | [_; "-c"; "-g"; path] | [_; "-c"; path; "-g"] ->
    let source = read_file path in
    let base = Filename.dirname path in
    set_c_debug path;
    set_lib_stem path;
    run_action ~base_dir:base (compile_to_c ~base_dir:base) path source
  | [_; "-c"; path] ->
    let source = read_file path in
    let base = Filename.dirname path in
    set_lib_stem path;
    run_action ~base_dir:base (compile_to_c ~base_dir:base) path source
  | [_; "--header"; path] ->
    (* the boundary's C header. A lib-mode emission computes the export list;
       the header falls out of the same computation (Codegen_c.lib_header). *)
    Mere.Codegen_c.lib_mode := true;
    set_lib_stem path;
    let source = read_file path in
    let base = Filename.dirname path in
    run_action ~base_dir:base
      (fun src ->
         let _ = compile_to_c ~base_dir:base src in
         !Mere.Codegen_c.lib_header)
      path source
  | [_; "-lle"; expr] ->
    run_action compile_to_llvm "<inline>" expr
  | [_; "-ll"; path] ->
    let source = read_file path in
    let base = Filename.dirname path in
    run_action ~base_dir:base (compile_to_llvm ~base_dir:base) path source
  | [_; "-we"; expr] ->
    run_action compile_to_wasm "<inline>" expr
  | [_; "-w"; path] ->
    let source = read_file path in
    let base = Filename.dirname path in
    run_action ~base_dir:base (compile_to_wasm ~base_dir:base) path source
  | [_; "-rve"; expr] ->
    run_action ~rv:true compile_to_riscv "<inline>" expr
  | [_; "lsp"] ->
    (* The editor speaks on stdin and listens on stdout, so nothing else may be
       written there — every diagnostic goes back as a protocol message. *)
    Mere.Lsp.serve ~search_paths:!search_paths ()
  | [_; "-wg"; path] ->
    let source = read_file path in
    let base = Filename.dirname path in
    run_action ~base_dir:base (wasm_debug_map ~path ~base_dir:base) path source
  | [_; "-rvse"; expr] ->
    run_action ~rv:true listing_riscv "<inline>" expr
  (* -rv (binary) / -rvs (listing) / -rvg (debug map), each with `--bare`,
     `--ram <MB>` and `--load-base <addr>` in any order. `--bare` means no host
     syscalls beyond the emulator's exit, and the program's top-level `main` is
     handed the machine capability it does its I/O through. *)
  | _ :: (("-rv" | "-rvs" | "-rvg"
          | "-rv64" | "-rv64s" | "-rv64g") as mode) :: (_ :: _ as rest) ->
    (* -rv64* is the same backend at xlen 64: LD/SD instead of LW/SW, 8-byte
       cells, pc-relative addresses (RV64's lui sign-extends, so an absolute
       0x80000000 built with lui+addi lands at 0xFFFFFFFF80000000). *)
    if String.length mode > 4 && String.sub mode 0 5 = "-rv64" then
      Mere.Codegen_riscv.xlen := 64;
    let mode = if String.length mode > 4 && String.sub mode 0 5 = "-rv64"
               then "-rv" ^ String.sub mode 5 (String.length mode - 5) else mode in
    (match rv_flags mode rest with
     | Some run -> run ()
     | None -> usage (); exit 1)
  | [_; "-rvd"; path] ->
    (* disassemble a flat RV32I binary (e.g. one emitted by `mere -rv`) *)
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let bytes = really_input_string ic n in
    close_in ic;
    print_string (Mere.Riscv_disasm.disasm_binary bytes)
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
    Mere.Eval.program_argv := [];
    run_action ~base_dir:base
      (Mere.Pipeline.process ~base_dir:base ~search_paths:!search_paths)
      path source
  | _ :: path :: rest_args when String.length path > 0 && path.[0] <> '-' ->
    (* Phase 44: `mere <path> arg1 arg2 ...` — pass extra args to the program.
       v0.1.12 (N3): hand the args AFTER the script path to eval's `args ()`
       builtin, so interp matches native (which sees only the user args, not
       its own binary/script name). *)
    let source = read_file path in
    let base = Filename.dirname path in
    Mere.Eval.program_argv := rest_args;
    run_action ~base_dir:base
      (Mere.Pipeline.process ~base_dir:base ~search_paths:!search_paths)
      path source
  | _ ->
    usage ();
    exit 1
