(* Source string -> ... convenience functions.
   Handles top-level decls (let, let rec, type) in order. *)

(* Phase 19.4: parses the auto-imported prelude and returns its decls.
   When the user's parse starts, these decls are inserted at the front of
   the user decls. Disabled by `?prelude:false` (for tests / debug). *)
let parse_prelude () : Ast.top_decl list =
  let tokens = Lexer.tokenize Prelude_stdlib.contents in
  let prog = Parser.parse_program tokens in
  prog.Ast.decls

let parse_program ?(prelude = true) ?base_dir ?(search_paths = []) s =
  (* Phase 19.4: parse the prelude FIRST so parser.constructors etc.
     have the prelude's types/ctors registered before the user's source
     is tokenized + parsed. Otherwise `Cons` in user code lookups arity
     0 and produces a payload-less ctor. *)
  let prelude_decls =
    if prelude then parse_prelude () else []
  in
  let tokens = Lexer.tokenize s in
  let user_prog =
    match base_dir with
    | Some d -> Parser.parse_program ~base_dir:d ~search_paths tokens
    | None -> Parser.parse_program ~search_paths tokens
  in
  { user_prog with Ast.decls = prelude_decls @ user_prog.Ast.decls }

let parse_only s =
  (* Phase 21.2: parse_only is used by pretty-print / AST-shape tests
     where the prelude noise (let-rec helpers wrapping the user's expr)
     would obscure the AST under test. Disable prelude here. Type decls
     (list / option / result) still aren't needed for these shape
     tests since the input rarely uses them. *)
  let prog = parse_program ~prelude:false s in
  Ast.desugar_program prog

(* Process top-decls in order, updating envs and the typer's constructor table. *)
(* Phase 38.A3: a top-level fn name that collides with libc / libm / C
   keywords causes a C codegen compile error. typer / eval are unaffected,
   but we emit a warning at the parser stage to help the user. See
   docs/patterns.md §5 for details. *)
let reserved_c_names =
  [
    (* C keywords *)
    "short"; "long"; "int"; "char"; "float"; "double";
    "signed"; "unsigned"; "register"; "static"; "auto"; "extern";
    "const"; "volatile"; "restrict"; "inline";
    "goto"; "return"; "break"; "continue"; "switch"; "case"; "default";
    "do"; "while"; "for"; "if"; "else";
    "sizeof"; "typedef"; "struct"; "union"; "enum"; "void";
    (* libc stdlib.h *)
    "div"; "ldiv"; "exit"; "abort"; "atexit"; "atof"; "atoi"; "atol";
    "free"; "malloc"; "calloc"; "realloc"; "system";
    "getenv"; "setenv"; "putenv"; "unsetenv";
    "rand"; "srand"; "abs"; "labs";
    "qsort"; "bsearch"; "mergesort";
    (* libm math.h *)
    "pow"; "sqrt"; "sin"; "cos"; "tan"; "asin"; "acos"; "atan"; "atan2";
    "exp"; "log"; "log10"; "log2"; "ceil"; "floor"; "round"; "trunc";
    "fabs"; "fmod"; "hypot"; "sinh"; "cosh"; "tanh";
    (* libc time.h *)
    "time"; "clock"; "ctime"; "asctime"; "gmtime"; "localtime"; "mktime";
    "difftime"; "strftime";
    (* POSIX I/O *)
    "read"; "write"; "open"; "close"; "lseek"; "stat"; "fstat";
    "fopen"; "fclose"; "fread"; "fwrite"; "fseek"; "ftell"; "rewind";
    "printf"; "scanf"; "fprintf"; "fscanf"; "sprintf"; "sscanf";
    "puts"; "gets"; "fputs"; "fgets"; "putchar"; "getchar";
    (* misc libc *)
    "strlen"; "strcpy"; "strncpy"; "strcat"; "strncat"; "strcmp"; "strncmp";
    "strchr"; "strrchr"; "strstr"; "strdup"; "strerror";
    "memcpy"; "memmove"; "memset"; "memcmp"; "memchr";
    "main";
  ]

let warn_reserved_name loc name =
  if List.mem name reserved_c_names then
    Printf.eprintf
      "%s: warning: top-level name `%s` collides with a C keyword or libc/libm \
       symbol — this will be a compile error at codegen. Renaming is \
       recommended (e.g. `%s_` / `m_%s` / `%s_v`) (see docs/patterns.md §5)\n%!"
      (Loc.to_string loc) name name name name

let rec warn_reserved_in_pattern (p : Ast.pattern) : unit =
  match p.Ast.pnode with
  | Ast.P_var n -> warn_reserved_name p.Ast.ploc n
  | Ast.P_tuple ps -> List.iter warn_reserved_in_pattern ps
  | Ast.P_record (_, fs) -> List.iter (fun (_, sp) -> warn_reserved_in_pattern sp) fs
  | Ast.P_as (inner, n) ->
    warn_reserved_name p.Ast.ploc n;
    warn_reserved_in_pattern inner
  | Ast.P_or (a, b) ->
    warn_reserved_in_pattern a;
    warn_reserved_in_pattern b
  | _ -> ()

let process_decls eval_env type_env decls =
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (pat, value) ->
      warn_reserved_in_pattern pat;
      let outer_env = !type_env in
      let t = Typer.infer outer_env value in
      let bindings = Typer.check_pattern pat t in
      let v = Eval.eval_in !eval_env value in
      (match Eval.match_pattern pat v with
       | None ->
         raise (Eval.Eval_error (pat.Ast.ploc,
           "top-level let pattern did not match"))
       | Some val_bindings ->
         eval_env := List.fold_left (fun acc (n, v) -> (n, ref v) :: acc)
                       !eval_env val_bindings);
      type_env := List.fold_left (fun acc (n, ty) ->
        let sch = Typer.generalize outer_env ty in
        (n, sch) :: acc) outer_env bindings
    | Ast.Top_let_rec bindings ->
      List.iter (fun (n, value) ->
        warn_reserved_name value.Ast.loc n) bindings;
      let outer_env = !type_env in
      let alphas = List.map (fun _ -> Typer.fresh_var ()) bindings in
      let env_rec = List.fold_left2 (fun acc (n, _) a ->
        (n, Typer.mono a) :: acc
      ) outer_env bindings alphas in
      List.iter2 (fun (_, value) alpha ->
        let t = Typer.infer env_rec value in
        Typer.unify value.Ast.loc alpha t
      ) bindings alphas;
      let placeholders = List.map (fun (n, _) -> (n, ref Eval.V_unit)) bindings in
      let env_eval = List.fold_left (fun acc (n, r) -> (n, r) :: acc) !eval_env placeholders in
      List.iter (fun (n, value) ->
        let v = Eval.eval_in env_eval value in
        let r = List.assoc n placeholders in
        r := v
      ) bindings;
      eval_env := env_eval;
      type_env := List.fold_left2 (fun acc (n, _) a ->
        let sch = Typer.generalize outer_env a in
        (n, sch) :: acc
      ) outer_env bindings alphas
    | Ast.Top_type (name, params, variants) ->
      Typer.register_type name params variants
    | Ast.Top_signature _ ->
      (* Pure parse-time expansion; nothing to do at type/eval level. *)
      ()
    | Ast.Top_record (name, params, fields) ->
      Typer.register_record name params fields
    | Ast.Top_type_alias _ ->
      (* Parse-time expansion only; nothing to do at type/eval level. *)
      ()
    | Ast.Top_view (name, region, fields) ->
      (* Phase 2.3: register as a view (construction requires active region)
         and also as a record (for field access / record update). *)
      Typer.register_view name region fields
    | Ast.Top_drop name ->
      Typer.register_drop_type name
    | Ast.Top_extern (name, ty) ->
      (* Phase 32.1 (FFI): register extern fn in both the type env and the eval env.
         The typer side just adds the type. The eval side references the
         hardcoded OCaml impl in extern_mocks via Eval.lookup_extern, and
         unsupported names become a clear eval-time error. *)
      type_env := (name, Typer.mono ty) :: !type_env;
      eval_env := (name, ref (Eval.lookup_extern name ty)) :: !eval_env
    | Ast.Top_extern_type type_name ->
      (* Phase 48.1 (C2): register opaque type so subsequent `ty`
         references resolve. Zero variants, zero params; no value-side
         construction is possible from Mere source. *)
      Typer.register_type type_name [] []
    | Ast.Top_ctor_alias (alias, target) ->
      Typer.alias_ctor alias target
    | Ast.Top_record_alias (alias, target) ->
      Typer.alias_record alias target
  ) decls

let process ?base_dir s =
  Exhaustive.reset ();
  let prog = parse_program ?base_dir s in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  (* Phase 11.4: borrow checker — reject conflicting borrows on the
     same (region, var) within a single program. Runs on the desugared
     program (decls folded into nested Let chains) so cross-decl
     borrows are tracked too. *)
  Typer.check_borrows [] (Ast.desugar_program prog);
  List.iter prerr_endline (Exhaustive.take ());
  let v = Eval.eval_in !eval_env prog.main in
  Eval.to_string v

(* Test-friendly entry point: returns the exhaustiveness warnings as a list
   (no side-effects), for unit tests to assert against. *)
let exhaustiveness_warnings s =
  Exhaustive.reset ();
  let prog = parse_program s in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  Exhaustive.take ()

let type_of s =
  Exhaustive.reset ();
  let prog = parse_program s in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  (* Type-check decls but skip eval to avoid side effects. *)
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (pat, value) ->
      warn_reserved_in_pattern pat;
      let outer_env = !type_env in
      let t = Typer.infer outer_env value in
      let bindings = Typer.check_pattern pat t in
      type_env := List.fold_left (fun acc (n, ty) ->
        let sch = Typer.generalize outer_env ty in
        (n, sch) :: acc) outer_env bindings;
      eval_env := !eval_env  (* unused *)
    | Ast.Top_let_rec bindings ->
      List.iter (fun (n, value) ->
        warn_reserved_name value.Ast.loc n) bindings;
      let outer_env = !type_env in
      let alphas = List.map (fun _ -> Typer.fresh_var ()) bindings in
      let env_rec = List.fold_left2 (fun acc (n, _) a ->
        (n, Typer.mono a) :: acc
      ) outer_env bindings alphas in
      List.iter2 (fun (_, value) alpha ->
        let t = Typer.infer env_rec value in
        Typer.unify value.Ast.loc alpha t
      ) bindings alphas;
      type_env := List.fold_left2 (fun acc (n, _) a ->
        let sch = Typer.generalize outer_env a in
        (n, sch) :: acc
      ) outer_env bindings alphas
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
    | Ast.Top_extern_type type_name ->
      Typer.register_type type_name [] []
    | Ast.Top_ctor_alias (alias, target) ->
      Typer.alias_ctor alias target
    | Ast.Top_record_alias (alias, target) ->
      Typer.alias_record alias target
  ) prog.decls;
  Ast.pp_ty (Typer.infer !type_env prog.main)

let process_typed s =
  Exhaustive.reset ();
  let prog = parse_program s in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  Eval.to_string (Eval.eval_in !eval_env prog.main)
