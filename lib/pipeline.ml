(* Source string -> ... convenience functions.
   Handles top-level decls (let, let rec, type) in order. *)

(* Phase 19.4: parses the auto-imported prelude and returns its decls.
   When the user's parse starts, these decls are inserted at the front of
   the user decls. Disabled by `?prelude:false` (for tests / debug). *)
(* How many of a parsed program's declarations came from the auto-imported
   prelude, which is prepended to every user program. It matters to anything that
   turns a name into a *place*: a prelude binding's position is a line in the
   prelude's own text, and reporting it against the user's file would send an
   editor somewhere arbitrary. The number is a constant of the build (the prelude
   does not change), so recording it as parse_program runs is exact. *)
let prelude_count = ref 0
let prelude_decl_count () = !prelude_count

let parse_prelude () : Ast.top_decl list =
  let tokens = Lexer.tokenize Prelude_stdlib.contents in
  let prog = Parser.parse_program tokens in
  prog.Ast.decls

let parse_program ?(prelude = true) ?base_dir ?(search_paths = []) s =
  (* Clear the parser's per-program declaration tables so a `type` / `module`
     from a previously-parsed program in this process cannot leak into this one
     (see Parser.reset_decl_state). Done BEFORE the prelude parse, which then
     re-registers the prelude's own types / constructors. *)
  Parser.reset_decl_state ();
  (* Phase 19.4: parse the prelude FIRST so parser.constructors etc.
     have the prelude's types/ctors registered before the user's source
     is tokenized + parsed. Otherwise `Cons` in user code lookups arity
     0 and produces a payload-less ctor. *)
  let prelude_decls =
    if prelude then parse_prelude () else []
  in
  prelude_count := List.length prelude_decls;
  let tokens = Lexer.tokenize s in
  let user_prog =
    match base_dir with
    | Some d -> Parser.parse_program ~base_dir:d ~search_paths tokens
    | None -> Parser.parse_program ~search_paths tokens
  in
  (* Q-012 Phase 32: lower saturated `par_map f xs` to spawn + channel +
     list_map so it works on every backend, not just the interpreter.
     2048-dogfood P3: then α-rename nested fn bindings to unique names so
     same-named inner fns (e.g. a `let rec go` per if-branch) don't collide
     in the backends' name-keyed inner-fn lift resolution. *)
  Ast.uniquify_toplevel_shadows
    (Ast.reserve_toplevel_main
      (Ast.uniquify_inner_fns_program
        (Ast.lower_par_map_program
          { user_prog with Ast.decls = prelude_decls @ user_prog.Ast.decls })))

(* Every syntax error in a source string, not just the first: lex, then parse
   with declaration-level recovery. Used by the CLI to report a whole file's
   worth at once, and the shape an editor wants.

   The prelude is parsed first for the same reason `parse_program` does it —
   constructors have to be registered before the user's source is parsed, or
   `Cons` in user code looks up arity 0. *)
let syntax_errors ?base_dir ?(search_paths = []) s
  : (string option * Loc.t * string) list =
  Parser.reset_decl_state ();
  ignore (parse_prelude ());
  let tokens = Lexer.tokenize s in
  let (_, errors) =
    Parser.parse_program_recover ?base_dir ~search_paths tokens
  in
  errors

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

(* Warnings the compiler produces while checking, collected rather than printed.
   They used to go straight to stderr, which is fine for a terminal and useless to
   anything else: an editor cannot underline a line that was written to a stream it
   is not reading. The CLI prints them now, which is the only place that should
   decide how a warning looks. *)
let warnings : (Loc.t * string) list ref = ref []
let reset_warnings () = warnings := []
let take_warnings () = let ws = List.rev !warnings in warnings := []; ws
let warn loc msg = warnings := (loc, msg) :: !warnings

let warn_reserved_name loc name =
  if name = "main" then
    (* Mere has no `main`-function convention: the entry point IS the file's
       trailing expression. A user binding named `main` no longer collides
       with the synthesized entry — the C backend mangles it (`mu_main`) and
       the Wasm entry is emitted as `$__mere_main` (exported as "main"), both
       distinct from a user `$main` — but the name is still misleading, since
       defining `main` does not make it the entry point. *)
    warn loc
      "`main` is not special in Mere — the entry point is the file's trailing \
       expression, not a `main` function. A top-level binding named `main` \
       compiles fine now, but reads as if it were the entry; consider renaming \
       it (e.g. `run`)." 
  else if List.mem name reserved_c_names then
    warn loc
      (Printf.sprintf
         "top-level name `%s` collides with a C keyword or libc/libm symbol — \
          this will be a compile error at codegen. Renaming is recommended \
          (e.g. `%s_` / `m_%s` / `%s_v`) (see docs/patterns.md §5)"
         name name name name)

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
    | Ast.Top_sync name ->
      Typer.register_sync_type name
    | Ast.Top_local name ->
      Typer.register_local_type name
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
    | Ast.Top_trait _ | Ast.Top_impl _ ->
      (* Lowered to plain decls by Trait_elab.elaborate before this loop
         runs; never reached in practice. *)
      ()
  ) decls

let process ?base_dir ?(search_paths = []) s =
  Exhaustive.reset ();
  Typer.reset_send_constraints ();
  let prog = Trait_elab.elaborate (parse_program ?base_dir ~search_paths s) in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  (* Q-012 (OPEN ii): discharge deferred channel-element Send obligations
     now that the whole program is typed and element tyvars are resolved. *)
  Typer.discharge_send_constraints ();
  (* Phase 11.4: borrow checker — reject conflicting borrows on the
     same (region, var) within a single program. Runs on the desugared
     program (decls folded into nested Let chains) so cross-decl
     borrows are tracked too. *)
  Typer.check_borrows [] (Ast.desugar_program prog);
  (* Q-012 (OPEN i): move / use-after-move analysis for spawn captures.
     Runs on the desugared program (same shape as check_borrows) so it
     sees resolved node types and full lexical scope. *)
  Move_check.check (Ast.desugar_program prog);
  List.iter prerr_endline (Exhaustive.take ());
  let v = Eval.eval_in !eval_env prog.main in
  Eval.to_string v

(* Test-friendly entry point: returns the exhaustiveness warnings as a list
   (no side-effects), for unit tests to assert against. *)
let exhaustiveness_warnings s =
  Exhaustive.reset ();
  Typer.reset_send_constraints ();
  let prog = Trait_elab.elaborate (parse_program s) in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  Exhaustive.take ()

let type_of s =
  Exhaustive.reset ();
  Typer.reset_send_constraints ();
  let prog = Trait_elab.elaborate (parse_program s) in
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
    | Ast.Top_trait _ | Ast.Top_impl _ -> ()
  ) prog.decls;
  Ast.pp_ty (Typer.infer !type_env prog.main)

let process_typed s =
  Exhaustive.reset ();
  Typer.reset_send_constraints ();
  let prog = Trait_elab.elaborate (parse_program s) in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  Typer.discharge_send_constraints ();
  Eval.to_string (Eval.eval_in !eval_env prog.main)

(* Parse, elaborate and type-check a source string, returning the program and the
   type of its main expression.

   This lived in the CLI, which was fine while the CLI was the only thing that
   compiled anything. A language server needs the *same* check — not a second
   implementation that agrees with it on good days — so it lives here, and the
   CLI calls it. Everything downstream (the four backends, the RV32I one) starts
   from what this returns. *)
let rec infer_program ?base_dir ?(search_paths = []) ?on_error source =
  match on_error with
  | Some _ ->
    (* However this ends, the sink goes away with it: one left installed would
       make the compiler itself collect errors instead of stopping at the first. *)
    Fun.protect ~finally:(fun () -> Typer.error_sink := None)
      (fun () -> infer_program_inner ?base_dir ~search_paths ?on_error source)
  | None -> infer_program_inner ?base_dir ~search_paths ?on_error source

and infer_program_inner ?base_dir ?(search_paths = []) ?on_error source =
  Typer.reset_send_constraints ();
  let prog =
    Trait_elab.elaborate
      (parse_program ?base_dir ~search_paths source)
  in
  let type_env = ref Typer.initial_env in
  (* With `on_error`, a declaration that does not type-check is *reported* and the
     walk continues, so a file with three broken functions says so three times
     instead of once. Without it — the compiler's path — the first error is raised
     and nothing changes, because a compiler that carries on past a type error has
     nothing useful to emit.

     The typer itself still raises at the first problem *within* a declaration.
     Making it collect means teaching every `raise` in it to produce a value and
     carry on, which is a different and much larger change; the declaration is the
     boundary the language already draws, and it is the one the parser recovers at
     too. *)
  let recovering = on_error <> None in
  let report loc msg = match on_error with Some f -> f (loc, msg) | None -> () in
  (* The typer collects too, for the two kinds of error that account for nearly
     all of them: a mismatch and an unknown name. So a single declaration can
     report more than one problem, and the per-declaration guard below is what
     catches the rest — the errors the typer still raises at. *)
  Typer.error_sink := (match on_error with
    | None -> None
    | Some f ->
      (* A pathological input can produce errors without end once inference is
         allowed to continue past them. Past a hundred, nobody is reading. *)
      let count = ref 0 in
      Some (fun (loc, msg) ->
        incr count;
        if !count <= 100 then f (loc, msg)));
  (* A declaration that failed still binds its names — to a fresh variable, which
     unifies with anything. Otherwise every later use of the name is a second
     error about the same mistake, and the real errors are buried. *)
  let bind_unknown pat =
    try
      let bindings = Typer.check_pattern pat (Typer.fresh_var ()) in
      type_env := List.fold_left (fun acc (n, ty) ->
        (n, Typer.mono ty) :: acc) !type_env bindings
    with _ -> ()
  in
  let guard_decl pat_opt names f =
    if not recovering then f ()
    else
      try f () with
      | Typer.Type_error (loc, msg) | Trait_elab.Trait_error (loc, msg) ->
        report loc msg;
        (match pat_opt with Some pat -> bind_unknown pat | None -> ());
        List.iter (fun n ->
          type_env := (n, Typer.mono (Typer.fresh_var ())) :: !type_env) names
  in
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (pat, value) ->
      (* Warn on reserved top-level names (incl. `main`, the entry point)
         on the compile paths too — not just the interp path — so the
         collision is caught here instead of surfacing as a cryptic
         downstream error (e.g. wat2wasm "redefinition of $main"). *)
      warn_reserved_in_pattern pat;
      guard_decl (Some pat) [] (fun () ->
        let outer_env = !type_env in
        let t = Typer.infer outer_env value in
        let bindings = Typer.check_pattern pat t in
        type_env := List.fold_left (fun acc (n, ty) ->
          let sch = Typer.generalize outer_env ty in
          (n, sch) :: acc) outer_env bindings)
    | Ast.Top_let_rec bindings ->
      List.iter (fun (n, value) ->
        warn_reserved_name value.Ast.loc n) bindings;
      guard_decl None (List.map fst bindings) (fun () ->
        let outer_env = !type_env in
        let alphas = List.map (fun _ -> Typer.fresh_var ()) bindings in
        let env_rec = List.fold_left2 (fun acc (n, _) a ->
          (n, Typer.mono a) :: acc) outer_env bindings alphas in
        List.iter2 (fun (_, value) alpha ->
          let t = Typer.infer env_rec value in
          Typer.unify value.Ast.loc alpha t) bindings alphas;
        type_env := List.fold_left2 (fun acc (n, _) a ->
          let sch = Typer.generalize outer_env a in
          (n, sch) :: acc) outer_env bindings alphas)
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
    | Ast.Top_trait _ | Ast.Top_impl _ -> ()
  ) prog.decls;
  let desugared = Ast.desugar_program prog in
  (* The desugared program re-visits every declaration's body, so when recovering
     this pass usually re-raises the first error the loop above already reported.
     `check` de-duplicates, which is what makes that harmless. *)
  let main_ty =
    if not recovering then Typer.infer !type_env desugared
    else
      try Typer.infer !type_env desugared with
      | Typer.Type_error (loc, msg) | Trait_elab.Trait_error (loc, msg) ->
        report loc msg; Ast.TyUnit
  in
  (* v0.1.29 (mkv dogfood P2): the compile path ran type inference only —
     the interp path's safety analyses (channel-element Send obligations,
     borrow conflicts, spawn-capture move/Send/Sync classification) were
     silently skipped under -c / -l / -w. A shared mutable Map captured by
     spawned threads was rejected by `mere file.mere` but compiled fine by
     `mere -c file.mere` — and raced at runtime. Run the same checks the
     run path runs (run_program lines up with this order). *)
  let post () =
    Typer.discharge_send_constraints ();
    Typer.check_borrows [] desugared;
    Move_check.check desugared
  in
  (if not recovering then post ()
   else
     try post () with
     | Typer.Type_error (loc, msg) | Trait_elab.Trait_error (loc, msg) ->
       report loc msg);
  (prog, main_ty)

(* Everything wrong with a source string, as data rather than as an exception.

   Syntax first, and all of it (see `syntax_errors`): a file that does not parse
   cannot be type-checked, and reporting one error while four are visible is what
   this exists to stop. Only when it parses does the type-checker run — and that
   one stops at its first complaint, because the typer raises. So a clean parse
   yields at most one type error, which is honest but not yet good; making the
   typer collect is its own slice.

   Positions are the ones in the string handed in. Errors from an imported file
   are reported with the position they have *there*, which is misleading in an
   editor and is why they carry the file they came from once that exists. *)
type severity = Error | Warning

type diagnostic = {
  d_loc : Loc.t;
  d_kind : string;
  d_msg : string;
  d_severity : severity;
  (* The file the position belongs to, when it is not the text being checked —
     an error inside an `import`, whose line numbers mean nothing in the
     importing file. `None` means "the text you handed me". *)
  d_file : string option;
}

let check ?base_dir ?(search_paths = []) (source : string)
  : Ast.program option * diagnostic list =
  (* A position knows which file it came from (the lexer stamps imported ones),
     so a diagnostic does too — including a type error, which is raised long after
     the parse and could not otherwise say. *)
  let err ?file kind (loc, msg) =
    let file = match file with Some f -> Some f | None -> loc.Loc.file in
    { d_loc = loc; d_kind = kind; d_msg = msg; d_severity = Error; d_file = file }
  in
  let warning (loc, msg) =
    { d_loc = loc; d_kind = "warning"; d_msg = msg;
      d_severity = Warning; d_file = None }
  in
  reset_warnings ();
  Exhaustive.reset ();
  match syntax_errors ?base_dir ~search_paths source with
  | (_ :: _) as errs ->
    (None, List.map (fun (file, loc, msg) -> err ?file "parse error" (loc, msg)) errs)
  | [] ->
    let type_errors = ref [] in
    let on_error (loc, msg) = type_errors := (loc, msg) :: !type_errors in
    (try
       let (prog, _) = infer_program ?base_dir ~search_paths ~on_error source in
       (* Type inference writes the type it found onto every node it visited, so
          the program that comes back is the answer to every later question about
          a position in this text. Warnings are only worth reporting once the
          file checks: while it does not, they are noise about code the person is
          in the middle of writing. *)
       let ws =
         List.map warning (take_warnings ())
         @ List.map (fun (loc, msg) -> warning (loc, msg)) (Exhaustive.take_located ())
       in
       (* One entry per distinct complaint: the declaration loop and the pass over
          the desugared program see the same nodes, so the same error arrives
          twice. Errors first — an editor sorts by position, but a person reading
          a terminal wants what is broken before what is merely suspect. *)
       let seen = Hashtbl.create 16 in
       let errs =
         List.filter (fun (loc, msg) ->
           if Hashtbl.mem seen (loc, msg) then false
           else (Hashtbl.add seen (loc, msg) (); true))
           (List.rev !type_errors)
       in
       let errs = List.map (err "type error") errs in
       (* A file that did not type-check has a tree, but one full of holes: it is
          only worth handing back when nothing went wrong. *)
       ((if errs = [] then Some prog else None), errs @ ws)
     with
     | Lexer.Lex_error (loc, msg) -> (None, [err "lex error" (loc, msg)])
     | Parser.Parse_error_in_file (file, loc, msg) ->
       (None, [err ~file "parse error" (loc, msg)])
     | Parser.Parse_error (loc, msg) -> (None, [err "parse error" (loc, msg)])
     | Typer.Type_error (loc, msg) -> (None, [err "type error" (loc, msg)])
     | Trait_elab.Trait_error (loc, msg) -> (None, [err "trait error" (loc, msg)])
     | Eval.Eval_error (loc, msg) -> (None, [err "eval error" (loc, msg)]))

let diagnostics ?base_dir ?search_paths (source : string) : diagnostic list =
  snd (check ?base_dir ?search_paths source)

(* Format a source string the way `mere fmt` does — the same function, so the
   editor's format-on-save and the command line cannot disagree about what
   formatted means.

   The prelude is parsed along with the source (constructors have to be
   registered before the user's code is parsed) and then dropped: what comes back
   is the person's own file, reformatted. *)
let format_source ?(base_dir = Sys.getcwd ()) ?(search_paths = []) source =
  let prelude_decls = parse_prelude () in
  let n_prelude = List.length prelude_decls in
  let prog = parse_program ~prelude:true ~base_dir ~search_paths source in
  let rec drop n xs =
    if n <= 0 then xs else match xs with [] -> [] | _ :: rest -> drop (n - 1) rest
  in
  Formatter.format_program { prog with Ast.decls = drop n_prelude prog.Ast.decls }
