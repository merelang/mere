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

(* How many entries of Parser.declared_types belong to the prelude rather than to the
   program being checked. *)
let prelude_type_count = ref 0

(* The name prelude positions carry. It is not a path and no file exists at it:
   that is the point — a position from the prelude is Mere code, but not *this*
   program's, and anything that turns a position into a place has to be able to
   tell. *)
let prelude_file = "<prelude>"

let parse_prelude () : Ast.top_decl list =
  let tokens = Lexer.tokenize ~file:prelude_file Prelude_stdlib.contents in
  let prog = Parser.parse_program tokens in
  prog.Ast.decls

(* The declarations that say what types exist. Kept next to `parse_program` because
   that is where they are now applied; `process_decls` and `Trait_elab` still make the
   same calls on their own walks, which is harmless (each registrar replaces). *)
let register_declared_types (decls : Ast.top_decl list) : unit =
  List.iter (fun decl ->
    match decl with
    | Ast.Top_type (name, params, variants) -> Typer.register_type name params variants
    | Ast.Top_extern_type name -> Typer.register_type name [] []
    | Ast.Top_record (name, params, fields) -> Typer.register_record name params fields
    | Ast.Top_view (name, region, fields) -> Typer.register_view name region fields
    | Ast.Top_drop name -> Typer.register_drop_type name
    | Ast.Top_sync name -> Typer.register_sync_type name
    | Ast.Top_local name -> Typer.register_local_type name
    | Ast.Top_ctor_alias (alias, target) -> Typer.alias_ctor alias target
    | Ast.Top_record_alias (alias, target) -> Typer.alias_record alias target
    | _ -> ()) decls

let parse_program ?(prelude = true) ?base_dir ?(search_paths = []) s =
  (* Clear the parser's per-program declaration tables so a `type` / `module`
     from a previously-parsed program in this process cannot leak into this one
     (see Parser.reset_decl_state). Done BEFORE the prelude parse, which then
     re-registers the prelude's own types / constructors. *)
  Parser.reset_decl_state ();
  (* And the typer's registries, which are the same kind of per-program state and
     were never cleared: one process checking two programs had the first one's
     constructors, records and views still registered for the second. A compiler
     never noticed; the language server checks one document per keystroke. *)
  Typer.reset_type_registries ();
  (* Phase 19.4: parse the prelude FIRST so parser.constructors etc.
     have the prelude's types/ctors registered before the user's source
     is tokenized + parsed. Otherwise `Cons` in user code lookups arity
     0 and produces a payload-less ctor. *)
  let prelude_decls =
    if prelude then parse_prelude () else []
  in
  prelude_count := List.length prelude_decls;
  (* The parser's type-name table now holds the prelude's; anything the user declares
     lands in front of it (the list is consed). See warn_declared_types. *)
  prelude_type_count := List.length !Parser.declared_types;
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
  (* The builtin names a USER binding may shadow (Q-045). The prelude deliberately
     shadows ten builtins of its own (`pow`, `divmod`, …) and those must keep the
     names they have always had, so the prelude's own top-level names are subtracted:
     what is left is the set where a user binding is the FIRST shadow and has to be
     renamed. *)
  let prelude_bound =
    List.concat_map (fun d ->
      match d with
      | Ast.Top_let ({ Ast.pnode = Ast.P_var n; _ }, _) -> [n]
      | Ast.Top_let_rec bs -> List.map fst bs
      | _ -> []) prelude_decls
  in
  let shadowable =
    List.filter (fun n -> not (List.mem n prelude_bound))
      (List.map fst Typer.initial_env)
  in
  (* Q-108: the builtins whose arguments include a function are the ones that can
     run code the range-check versioning pass cannot see (a closure that pushes to
     the very Vec the loop reads). Derived from the typer's environment, not
     listed by hand: a table of names goes stale, the environment does not. *)
  let higher_order_builtins =
    let rec has_fn_param (t : Ast.ty) =
      match Ast.walk t with
      | Ast.TyArrow (p, r) ->
        (match Ast.walk p with Ast.TyArrow _ -> true | _ -> false) || has_fn_param r
      | _ -> false
    in
    List.filter_map (fun (n, (sch : Typer.scheme)) -> if has_fn_param sch.Typer.body then Some n else None)
      Typer.initial_env
  in
  let prog =
    Ast.uniquify_toplevel_shadows ~shadowable
      (Ast.reserve_toplevel_main
        (Ast.uniquify_inner_fns_program
          (Ast.range_version_program ~unsafe_builtins:higher_order_builtins
            (Ast.lower_par_map_program
              { user_prog with Ast.decls = prelude_decls @ user_prog.Ast.decls }))))
  in
  (* Tell the typer what this program declares, here rather than only when the
     declarations are later walked. What types exist is a fact about the program, and
     making it one keeps every entry point consistent: `Typer.infer` on a desugared
     program never registered anything, so a caller that skipped `process_decls`
     type-checked against whatever the *previous* program in this process had
     declared. That worked only because nothing was ever cleared. Registering is
     idempotent, so the later walk is unaffected. *)
  register_declared_types prog.Ast.decls;
  prog

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

(* Drain the exhaustiveness findings on a path that is about to run or emit the
   program, and stop it if any of them names a case.

   This is called from `process` and from `infer_program_inner`'s `post`, which
   is to say from both sides of the same fork the compile path already had to be
   taught about once (see the note on `post`). Before this, a non-exhaustive
   match was a line on the interpreter's stderr and *nothing at all* under
   `-c` / `-ll` / `-w` / `-rv`: the four backends that produce the artifact were
   the four that did not mention it.

   v0.1.470 corrects what this note said about the consequence. It said each
   backend "invented" a value and the answer came back wrong. MEASURED, on a
   program that actually reaches the missing arm: the interpreter raises
   `no matching arm in match` and points at the line, C and LLVM ran a bare
   `abort()` (exit 134, no output), Wasm executed `unreachable` (exit 1, no
   output), and only RV32IM really did carry on with a value — the saved stack
   pointer. So the failure was LATE AND MUTE on three of the four rather than
   wrong, which is a smaller claim than the one written here and still reason
   enough to move it to compile time. The runtime half is now one answer on all
   five paths; see the note in `Codegen_c`'s fallthrough. *)
(* Raised on the paths that would otherwise run or emit the program: a type
   declared twice with different constructors leaves the compiler holding one
   model for two types, and everything downstream -- exhaustiveness, `==`,
   codegen's variant tags -- answers from whichever declaration came last. See
   the note on `Typer.type_redecls` for what was measured before making this an
   error rather than a warning (zero sites in 945 files).

   No position: `Ast.Top_type` carries none, so there is no line to point at.
   The message names the type and both constructor sets instead, which is what
   a reader needs to find the two declarations. *)
exception Type_redeclared of (string * string * string) list

let redecl_message (name, a, b) =
  String.concat "\n"
    [ Printf.sprintf
        "type `%s` is declared twice with different constructors (`%s` and `%s`)"
        name a b;
      "help: a type may be restated identically — twelve files here restate `'a list`";
      "help: — but two different types cannot share a name. The second wins for the";
      "help: name while the first's constructors stay usable, so a `match` over one";
      "help: is checked against the other. Rename one of them." ]

(* So that an uncaught one, and `Printexc.to_string` generally, say what it is
   rather than `Type_redeclared(_)`. The host runtime's words are not the
   language's -- the same reason the CLI translates Out_of_memory and
   Stack_overflow. *)
let () =
  Printexc.register_printer (function
    | Type_redeclared rs ->
      Some (String.concat "; " (List.map (fun (n, a, b) ->
        Printf.sprintf "type `%s` is declared twice with different constructors (`%s` and `%s`)"
          n a b) rs))
    | _ -> None)

let enforce_type_redecls () =
  match Typer.take_type_redecls () with
  | [] -> ()
  | rs -> raise (Type_redeclared rs)

let enforce_exhaustive () =
  enforce_type_redecls ();
  let (ws, es) = Exhaustive.classify () in
  List.iter (fun (loc, msg) -> warn loc msg) ws;
  if es <> [] then
    if !Exhaustive.allow then List.iter (fun (loc, msg) -> warn loc msg) es
    else raise (Exhaustive.Non_exhaustive es)

let warn_reserved_name (loc : Loc.t) name =
  (* Not for the prelude's own declarations. They are prepended to every program,
     so a warning about one fires on every compile, and the user cannot rename a
     name they did not write. The prelude is tokenized with `~file:prelude_file`,
     which is what makes it tellable.

     Worth knowing if this list is ever revisited: the "this will be a compile
     error at codegen" claim is at least partly stale. `pow` is in
     `reserved_c_names`, and a prelude `let pow` compiles and runs on the C backend
     (`pow 2 10` gives 1024) because the backend mangles top-level names — the same
     thing the `main` case below already documents.

     One measured consequence of skipping the prelude here: a name the prelude
     binds is a rebind when the user binds it too, and the walk warns once, so a
     user top-level `let pow` no longer gets nagged. `pow` is the only one of the
     ten helpers added to the prelude that is in this list, and a user `let pow`
     compiles and runs correctly on the C backend, so what was lost is a nag that
     was wrong for that name anyway. *)
  if loc.Loc.file = Some prelude_file then ()
  else if name = "main" then
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

(* C struct tags and typedefs from the headers the C backend emits. A Mere `type`
   lowers to `typedef struct <name> <name>;`, which claims both the tag namespace and
   the ordinary one — so it collides with `union wait` in <sys/wait.h> and with the
   `wait()` declaration next to it. The mraft dogfood named a type `wait` and got the
   failure from clang, because this check only ever looked at `let` names.

   Function and keyword collisions are covered by `reserved_c_names` above, which
   applies to type names too for the same reason (a typedef is an ordinary
   identifier). This list is only the struct tags, which a function-name list has no
   reason to contain. *)
let reserved_c_type_names =
  [
    (* <sys/wait.h>, <sys/resource.h> *)
    "wait"; "rusage";
    (* <time.h>, <sys/time.h> *)
    "tm"; "timespec"; "timeval"; "timezone"; "itimerval";
    (* <sys/stat.h>, <dirent.h> *)
    "stat"; "dirent";
    (* <sys/socket.h>, <netinet/in.h>, <netdb.h> *)
    "sockaddr"; "sockaddr_in"; "sockaddr_in6"; "msghdr"; "cmsghdr"; "iovec";
    "linger"; "in_addr"; "in6_addr"; "ip_mreq"; "ipv6_mreq";
    "addrinfo"; "hostent"; "servent"; "protoent"; "netent";
    (* <termios.h>, <sys/select.h>, <signal.h> *)
    "termios"; "winsize"; "fd_set"; "sigaction"; "sigevent"; "sigaltstack";
    (* <stdio.h>, <stdlib.h> *)
    "div_t"; "ldiv_t"; "lldiv_t"; "lconv";
    (* <pthread.h> — emitted whenever a program spawns *)
    "sched_param";
  ]

let warn_reserved_type_name loc name =
  if List.mem name reserved_c_names || List.mem name reserved_c_type_names then
    warn loc
      (Printf.sprintf
         "type name `%s` collides with a C type, keyword or libc symbol — this will \
          be a compile error at codegen, from the C compiler rather than from here. \
          Renaming is recommended (e.g. `%s_` / `m_%s`) (see docs/patterns.md \194\1675)"
         name name name)

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

(* Warn about type names C cannot take. Done from the parser's table rather than from
   the decls, because a `Top_type` carries no position and a warning an editor cannot
   place is a warning nobody sees. *)
let warn_declared_types () =
  let all = !Parser.declared_types in
  let mine = List.length all - !prelude_type_count in
  List.iteri
    (fun i (name, loc) -> if i < mine then warn_reserved_type_name loc name)
    all

(* A TOP-LEVEL `let`, TYPED ONCE. There are two callers -- `process_decls`, which the
   interpreter walks, and `infer_program_inner`, which every backend starts from -- and
   they had the same eight lines written out twice. They had also drifted: neither
   applied the value restriction that `Typer`'s inner `let` has had since Phase 36, and
   fixing one would have left the other. *)
let infer_top_let outer_env (value : Ast.expr) : Ast.ty =
  (* Q-127: IN `--lib` MODE AN EXPORTED CALL *IS* A REGION. The boundary opens one per
     call and releases it at return -- that is what makes a call a transaction, and what
     v0.1.311 measured. Typing the body inside it is what lets the escape check see the
     store v0.1.452 pinned as a gap: a container the call builds lives in the call's
     arena, and putting one into module state keeps a pointer into memory the next call
     reuses. It read back garbage; it is a type error now, with the message a `region`
     block gets.

     Only a FUNCTION body. A top-level `let x = <expr>` runs during module init, where
     the current region is the default one, so wrapping it would claim a lifetime it
     does not have. *)
  let wrap =
    !Typer.lib_boundary
    && (match value.Ast.node with Ast.Fun _ -> true | _ -> false)
  in
  if not wrap then Typer.infer outer_env value
  else begin
    Typer.active_regions := Typer.call_region_name :: !Typer.active_regions;
    let restore () = Typer.active_regions := List.tl !Typer.active_regions in
    let t =
      match Typer.infer outer_env value with
      | t -> restore (); t
      | exception ex -> restore (); raise ex
    in
    (* The block's own check, run by hand: there is no `Region_block` node here to hang
       it on, and without it the boundary would be the one place the escape rule does
       not reach. *)
    (match Typer.region_leaked_into_env Typer.call_region_name outer_env with
     | Some bind ->
       raise (Typer.Type_error (value.Ast.loc,
         Printf.sprintf
           "region escape across the library boundary: `%s` now holds a value built \
            during a call, which is freed when that call returns (its type became \
            `%s`). Each exported call runs in its own region -- build it at module \
            init, or copy its contents out"
           bind (Ast.pp_ty (Ast.walk (List.assoc bind outer_env).Typer.body))))
     | None -> ());
    t
  end

(* THE VALUE RESTRICTION, WHICH ONLY THE INNER `let` HAD. `Typer`'s Let case has had the
   narrow rule since Phase 36 -- a binding whose value is not syntactically a value and
   whose type mentions a MUTABLE CONTAINER stays monomorphic, because generalising one
   container into `forall`-many is unsound: each use instantiates its own element type
   and they stop agreeing. Top level never had it, and while every region settled on
   `__heap` the difference did not show. Q-127 made it show: `let store = vec_new ()`
   was generalised over its REGION, so each use instantiated a different one for a
   container there is only one of. *)
let top_let_scheme outer_env (value : Ast.expr) (ty : Ast.ty) : Typer.scheme =
  if Typer.is_value value || not (Typer.ty_mentions_mutable_container ty)
  then Typer.generalize outer_env ty
  else begin
    Typer.adjust_level !Typer.cur_level ty;
    (* Nothing here is quantified, so no region in it is a call site's to decide: this
       binding is made ONCE and outlives every call. `generalize` does the same for the
       bindings it handles. At the top level there is no enclosing binding to quantify
       it later, which is why this is right here and wrong at an inner `let`. *)
    Typer.unmark_non_quantified_regions [] ty;
    Typer.mono ty
  end

let process_decls eval_env type_env decls =
  warn_declared_types ();
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (pat, value) ->
      warn_reserved_in_pattern pat;
      let outer_env = !type_env in
      (* Pattern variables belong to this binding — see Typer's Let case. *)
      let bindings =
        Typer.enter_level (fun () ->
          let t = infer_top_let outer_env value in
          Typer.check_pattern pat t) in
      let v = Eval.eval_in !eval_env value in
      (match Eval.match_pattern pat v with
       | None ->
         raise (Eval.Eval_error (pat.Ast.ploc,
           "top-level let pattern did not match"))
       | Some val_bindings ->
         eval_env := List.fold_left (fun acc (n, v) -> (n, ref v) :: acc)
                       !eval_env val_bindings);
      type_env := List.fold_left (fun acc (n, ty) ->
        let sch = top_let_scheme outer_env value ty in
        (* Q-127: the backends cannot read a region out of a fn_decl's types -- Monomorph
           erases it. They read it out of the scheme, by source name. *)
        Typer.record_top_scheme n sch;
        (n, sch) :: acc) outer_env bindings
    | Ast.Top_let_rec bindings ->
      List.iter (fun (n, value) ->
        warn_reserved_name value.Ast.loc n) bindings;
      let outer_env = !type_env in
      let alphas =
        Typer.enter_level (fun () -> List.map (fun _ -> Typer.fresh_var ()) bindings) in
      let env_rec = List.fold_left2 (fun acc (n, _) a ->
        (n, Typer.mono a) :: acc
      ) outer_env bindings alphas in
      List.iter2 (fun (_, value) alpha ->
        let t = Typer.enter_level (fun () -> Typer.infer env_rec value) in
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
        Typer.record_top_scheme n sch;
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
  Typer.reset_region_params ();
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
  (* Before the eval, not after it: the findings used to be printed here and the
     program run anyway, so the one message about the missing arm arrived above
     the wrong answer it was explaining. *)
  enforce_exhaustive ();
  let v = Eval.eval_in !eval_env prog.main in
  Eval.to_string v

(* Test-friendly entry point: returns the exhaustiveness warnings as a list
   (no side-effects), for unit tests to assert against. *)
let exhaustiveness_warnings s =
  Exhaustive.reset ();
  Typer.reset_send_constraints ();
  Typer.reset_region_params ();
  let prog = Trait_elab.elaborate (parse_program s) in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  Exhaustive.take ()

let type_of s =
  Exhaustive.reset ();
  Typer.reset_send_constraints ();
  Typer.reset_region_params ();
  let prog = Trait_elab.elaborate (parse_program s) in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  (* Type-check decls but skip eval to avoid side effects. *)
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (pat, value) ->
      warn_reserved_in_pattern pat;
      let outer_env = !type_env in
      (* Pattern variables belong to this binding — see Typer's Let case. *)
      let bindings =
        Typer.enter_level (fun () ->
          let t = infer_top_let outer_env value in
          Typer.check_pattern pat t) in
      type_env := List.fold_left (fun acc (n, ty) ->
        let sch = top_let_scheme outer_env value ty in
        (* Q-127: the backends cannot read a region out of a fn_decl's types -- Monomorph
           erases it. They read it out of the scheme, by source name. *)
        Typer.record_top_scheme n sch;
        (n, sch) :: acc) outer_env bindings;
      eval_env := !eval_env  (* unused *)
    | Ast.Top_let_rec bindings ->
      List.iter (fun (n, value) ->
        warn_reserved_name value.Ast.loc n) bindings;
      let outer_env = !type_env in
      let alphas =
        Typer.enter_level (fun () -> List.map (fun _ -> Typer.fresh_var ()) bindings) in
      let env_rec = List.fold_left2 (fun acc (n, _) a ->
        (n, Typer.mono a) :: acc
      ) outer_env bindings alphas in
      List.iter2 (fun (_, value) alpha ->
        let t = Typer.enter_level (fun () -> Typer.infer env_rec value) in
        Typer.unify value.Ast.loc alpha t
      ) bindings alphas;
      type_env := List.fold_left2 (fun acc (n, _) a ->
        let sch = Typer.generalize outer_env a in
        Typer.record_top_scheme n sch;
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

(* Q-127 STAGE 1, THE MEASUREMENT. Nothing here changes what is compiled.

   The open half of Q-127 is closed by passing a function's allocation region IN as a
   hidden leading argument, so that the body allocates where the call site decided
   instead of guessing (which is what v0.1.453 did, and what m3d's second frame
   disproved). Before writing that, this reports how many functions it would touch and
   how many are disqualified, on real programs -- because "how big is this change"
   answered from the code is a guess and answered from the corpus is a number.

   A function is DISQUALIFIED when a hidden argument has nowhere to go:

     value-used   the name appears somewhere other than the head of an application,
                  so it becomes a closure value, and a closure's ABI has no room for
                  a region without changing every closure in the language.
     partial      every occurrence is a call, but at least one passes fewer arguments
                  than the type takes. The region belongs to the SATURATED call, and
                  the partial one has already built a value by then.

   Disqualified is not an error: those keep today's behaviour, which is the default
   region -- over-strict, never unsound. *)
let region_param_report ?base_dir ?(search_paths = []) s =
  Exhaustive.reset ();
  Typer.reset_send_constraints ();
  Typer.reset_region_params ();
  let prog = Trait_elab.elaborate (parse_program ?base_dir ~search_paths s) in
  let type_env = ref Typer.initial_env in
  let base_names = List.map fst Typer.initial_env in
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (pat, value) ->
      warn_reserved_in_pattern pat;
      let outer_env = !type_env in
      let bindings =
        Typer.enter_level (fun () ->
          let t = infer_top_let outer_env value in
          Typer.check_pattern pat t) in
      type_env := List.fold_left (fun acc (n, ty) ->
        let sch = top_let_scheme outer_env value ty in
        (* Q-127: the backends cannot read a region out of a fn_decl's types -- Monomorph
           erases it. They read it out of the scheme, by source name. *)
        Typer.record_top_scheme n sch;
        (n, sch) :: acc) outer_env bindings
    | Ast.Top_let_rec bindings ->
      let outer_env = !type_env in
      let alphas =
        Typer.enter_level (fun () -> List.map (fun _ -> Typer.fresh_var ()) bindings) in
      let env_rec = List.fold_left2 (fun acc (n, _) a ->
        (n, Typer.mono a) :: acc) outer_env bindings alphas in
      List.iter2 (fun (_, value) alpha ->
        let t = Typer.enter_level (fun () -> Typer.infer env_rec value) in
        Typer.unify value.Ast.loc alpha t) bindings alphas;
      type_env := List.fold_left2 (fun acc (n, _) a ->
        let sch = Typer.generalize outer_env a in
        Typer.record_top_scheme n sch;
        (n, sch) :: acc) outer_env bindings alphas
    | Ast.Top_type (name, params, variants) -> Typer.register_type name params variants
    | Ast.Top_record (name, params, fields) -> Typer.register_record name params fields
    | Ast.Top_view (name, region, fields) -> Typer.register_view name region fields
    | Ast.Top_drop name -> Typer.register_drop_type name
    | Ast.Top_sync name -> Typer.register_sync_type name
    | Ast.Top_local name -> Typer.register_local_type name
    | Ast.Top_extern (name, ty) -> type_env := (name, Typer.mono ty) :: !type_env
    | Ast.Top_extern_type type_name -> Typer.register_type type_name [] []
    | Ast.Top_ctor_alias (alias, target) -> Typer.alias_ctor alias target
    | Ast.Top_record_alias (alias, target) -> Typer.alias_record alias target
    | Ast.Top_signature _ | Ast.Top_type_alias _
    | Ast.Top_trait _ | Ast.Top_impl _ -> ()) prog.decls;
  let _ = Typer.infer !type_env prog.main in

  (* How each name is USED, over the whole program including every decl's body.
     `head` is the spine head of an application; everything else is a value use. *)
  let value_used : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let applied_with : (string, int) Hashtbl.t = Hashtbl.create 64 in
  let note_app n k =
    let cur = match Hashtbl.find_opt applied_with n with Some c -> c | None -> max_int in
    Hashtbl.replace applied_with n (min cur k)
  in
  let rec spine (e : Ast.expr) (k : int) : unit =
    match e.Ast.node with
    | Ast.App (f, a) -> value a; spine f (k + 1)
    | Ast.Var n when k > 0 -> note_app n k
    | _ -> value e
  and value (e : Ast.expr) : unit =
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit -> ()
    | Ast.Var n -> Hashtbl.replace value_used n ()
    | Ast.App _ -> spine e 0
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b) -> value a; value b
    | Ast.Neg a | Ast.Annot (a, _) | Ast.Field_get (a, _) | Ast.Ref (_, _, a)
    | Ast.Region_block (_, a) | Ast.Region_loop (_, _, a) | Ast.Fun (_, _, a) -> value a
    | Ast.Let (_, v, b) | Ast.With (_, v, b) -> value v; value b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> value v) bs; value b
    | Ast.If (c, t, f) -> value c; value t; value f
    | Ast.Constr (_, Some a) -> value a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (sc, arms) ->
      value sc;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> value ge | None -> ()); value b) arms
    | Ast.Tuple es -> List.iter value es
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, x) -> value x) fs
    | Ast.Record_update (a, fs) -> value a; List.iter (fun (_, x) -> value x) fs
  in
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (_, v) -> value v
    | Ast.Top_let_rec bs -> List.iter (fun (_, v) -> value v) bs
    | _ -> ()) prog.decls;
  value prog.main;

  (* WHAT EACH CALL SITE WOULD PASS. The report above says which functions would take a
     hidden region argument; this says whether the value to pass is actually recoverable
     at every call, which is the mechanism the change turns on. Three answers:
       R          a `region R { }` the call is inside -- pass `__region_R`
       ?          nobody decided -- pass the default region, which is today's behaviour
       ^<caller>  the ENCLOSING function's own region parameter: pass it straight down.
                  This is how a chain propagates, and nothing here implements chains --
                  unification did it, because the inner call instantiated the callee at
                  the caller's own variable. *)
  let sites = Buffer.create 256 in
  let n_named = ref 0 and n_undecided = ref 0 and n_forwarded = ref 0 in
  let render caller_params t =
    match Ast.walk t with
    (* `__heap` IS A `TyRef` AND IS NOT A BLOCK. Counting it as one is what the first
       version of this did, and it reported m3d as having eight call sites inside a
       `region` block. m3d has one region block in the whole program, in the window
       path, and the bench that measures its per-frame growth does not go through it.
       A count that cannot tell "the default region" from "a region" answers the
       question this report exists to ask with the wrong number, and the emitted C is
       what disagreed with it. *)
    | Ast.TyRef (_, "__heap", Ast.TyUnit) -> incr n_undecided; "__heap"
    | Ast.TyRef (_, r, Ast.TyUnit) -> incr n_named; r
    | Ast.TyVar v when List.mem v.Ast.id caller_params -> incr n_forwarded; "^" ^ "param"
    | Ast.TyVar _ -> incr n_undecided; "?"
    | other -> incr n_undecided; Ast.pp_ty other
  in
  let rec walk_calls caller caller_params (e : Ast.expr) : unit =
    (match e.Ast.node with
     | Ast.App _ ->
       let rec head ex acc =
         match ex.Ast.node with
         | Ast.App (f, a) -> head f (a :: acc)
         | Ast.Var n -> Some (n, ex, acc)
         | _ -> None
       in
       (match head e [] with
        | Some (n, vnode, _) ->
          (match List.assoc_opt n !type_env, vnode.Ast.ty with
           | Some sch, Some inst when Typer.scheme_region_params sch <> [] ->
             let got = Typer.region_args_at sch inst in
             if got <> [] then
               Buffer.add_string sites
                 (Printf.sprintf "@%s -> %s : %s\n" caller n
                    (String.concat " " (List.map (fun (_, t) -> render caller_params t) got)))
           | _ -> ())
        | None -> ())
     | _ -> ());
    List.iter (walk_calls caller caller_params) (Ast.children e)
  in
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (pat, v) ->
      let caller =
        match pat.Ast.pnode with Ast.P_var n -> n | _ -> "<pattern>" in
      let ps =
        match List.assoc_opt caller !type_env with
        | Some sch -> Typer.scheme_region_params sch
        | None -> [] in
      walk_calls caller ps v
    | Ast.Top_let_rec bs ->
      List.iter (fun (n, v) ->
        let ps = match List.assoc_opt n !type_env with
          | Some sch -> Typer.scheme_region_params sch | None -> [] in
        walk_calls n ps v) bs
    | _ -> ()) prog.decls;
  walk_calls "<main>" [] prog.main;

  let buf = Buffer.create 1024 in
  let total = ref 0 and ok = ref 0 and vused = ref 0 and partial = ref 0 in
  List.iter (fun (name, (sch : Typer.scheme)) ->
    if not (List.mem name base_names) then begin
      let rps = Typer.scheme_region_params sch in
      if rps <> [] then begin
        incr total;
        let arity = Typer.ty_arity sch.body in
        let status =
          if Hashtbl.mem value_used name then (incr vused; "value-used")
          else match Hashtbl.find_opt applied_with name with
            | Some k when k < arity -> incr partial; "partial"
            | _ -> incr ok; "ok"
        in
        Buffer.add_string buf
          (Printf.sprintf "%s\t%d\t%d\t%s\n" name (List.length rps) arity status)
      end
    end) (List.rev !type_env);
  Buffer.add_string buf (Buffer.contents sites);
  Buffer.add_string buf
    (Printf.sprintf "#sites %d named, %d forwarded, %d undecided\n"
       !n_named !n_forwarded !n_undecided);
  (* Run the pass the backends run, and say how many variables it actually named.
     "The pass ran" and "the pass did anything" are different claims; a gate that
     cannot tell them apart passes on a binding that binds nothing. This is last
     because it LINKS variables -- nothing above may run after it. *)
  Buffer.add_string buf (Printf.sprintf "#bound %d\n" (Typer.bind_region_params ()));
  (* And the same question asked the way the BACKENDS will ask it: by source name, out of
     the scheme, because a fn_decl's types have had their regions erased by then. If these
     two disagree the backends are reading a different answer from the one measured here. *)
  Buffer.add_string buf
    (Printf.sprintf "#byname %d\n"
       (List.length
          (List.filter (fun (n, _) ->
               not (List.mem n base_names) && Typer.region_params_for n <> [])
             (List.rev !type_env))));
  Buffer.add_string buf
    (Printf.sprintf "# %d region-parameterised, %d ok, %d value-used, %d partial\n"
       !total !ok !vused !partial);
  Buffer.contents buf

let process_typed s =
  Exhaustive.reset ();
  Typer.reset_send_constraints ();
  Typer.reset_region_params ();
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
  Typer.reset_region_params ();
  (* The compile path never reset this — it worked only because nothing drained
     it either, and a second `infer_program` in one process would have been
     judged against the first one's matches. *)
  Exhaustive.reset ();
  let prog =
    Trait_elab.elaborate
      (parse_program ?base_dir ~search_paths source)
  in
  (* The same warnings process_decls raises. This is the path an editor takes, and a
     warning it cannot see is one nobody sees. *)
  warn_declared_types ();
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
  (* The environment the DESUGARED program is typed against, which is not the same
     thing as the environment the declaration loop builds.

     `desugar_program` turns every `Top_let` into a nested `Let`, so the desugared
     expression rebinds all of them itself. Typing it against the accumulated
     environment therefore does not add anything — except one thing it must not add:
     a binding is visible to declarations that come BEFORE it.

     That was a real bug (Q-045). A user's `let show = fn (x: int) -> x + 1` made the
     PRELUDE fail to type, because the prelude's `pow` calls the `show` builtin and
     the accumulated environment had the user's `show` shadowing it — at a position
     textually earlier than the user's own line. The error named `<prelude>:485` for a
     program that never mentions the prelude, on all four compiled backends, while the
     interpreter was fine: the interpreter types each declaration against the
     environment as it stood, and only `main` against the full one.

     So this holds exactly what desugaring DROPS and the expression cannot rebind:
     externs. Everything else desugaring keeps. *)
  let base_env = ref Typer.initial_env in
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
        let t = Typer.enter_level (fun () -> infer_top_let outer_env value) in
        let bindings = Typer.check_pattern pat t in
        type_env := List.fold_left (fun acc (n, ty) ->
          (n, top_let_scheme outer_env value ty) :: acc) outer_env bindings)
    | Ast.Top_let_rec bindings ->
      List.iter (fun (n, value) ->
        warn_reserved_name value.Ast.loc n) bindings;
      guard_decl None (List.map fst bindings) (fun () ->
        let outer_env = !type_env in
        let alphas =
        Typer.enter_level (fun () -> List.map (fun _ -> Typer.fresh_var ()) bindings) in
        let env_rec = List.fold_left2 (fun acc (n, _) a ->
          (n, Typer.mono a) :: acc) outer_env bindings alphas in
        List.iter2 (fun (_, value) alpha ->
          let t = Typer.enter_level (fun () -> Typer.infer env_rec value) in
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
      (* Into BOTH: the declaration loop needs it, and so does the desugared
         program, which drops the declaration and so cannot rebind it. *)
      type_env := (name, Typer.mono ty) :: !type_env;
      base_env := (name, Typer.mono ty) :: !base_env
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
    if not recovering then Typer.infer !base_env desugared
    else
      try Typer.infer !base_env desugared with
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
  (if not recovering then begin
     post ();
     (* Last, and only here: a recovering caller wants the findings as data
        with the rest of the diagnostics (`check` drains them itself), and one
        judged against a program that did not type-check is guesswork about a
        scrutinee whose type never resolved. *)
     enforce_exhaustive ()
   end
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
       (* A named missing case is an error here too, and carries the severity
          that says so: an editor that draws it as a hint is describing a
          program the compiler will refuse. *)
       (* A conflicting redeclaration is an error here too: an editor that does
          not show it is describing a program the compiler will refuse. No
          position, because `Top_type` carries none. *)
       let redecls =
         List.map (fun r ->
           { d_loc = Loc.dummy; d_kind = "type error"; d_msg = redecl_message r;
             d_severity = Error; d_file = None })
           (Typer.take_type_redecls ())
       in
       let (ex_ws, ex_es) = Exhaustive.classify () in
       let ws =
         List.map warning (take_warnings ())
         @ List.map warning ex_ws
         @ List.map (fun (loc, msg) ->
             { d_loc = loc; d_kind = "error"; d_msg = msg;
               d_severity = Error; d_file = None }) ex_es
         @ redecls
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
