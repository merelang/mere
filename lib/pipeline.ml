(* Source string -> ... convenience functions.
   Handles top-level decls (let, let rec, type) in order. *)

(* Names promised by `let fn <name>: <ty>;`. The interpreter binds each to a
   placeholder ref when the promise is made, so a caller written before the
   definition captures the ref the definition will fill in -- the same
   back-patching a `let rec ... and ...` group already does for its members.
   Prepending a NEW binding at the definition would shadow instead, and every
   caller above it would go on calling the placeholder. *)
let forward_promised : (string, Ast.ty * Loc.t) Hashtbl.t = Hashtbl.create 16
(* the promises this program has kept, so the end-of-program check can name
   the ones it did not *)
let forward_kept : (string, unit) Hashtbl.t = Hashtbl.create 16
let forward_reset () = Hashtbl.reset forward_promised; Hashtbl.reset forward_kept

(* ⚠ THE DEFINITION HAS TO MEAN WHAT THE DECLARATION PROMISED. Without this the
   declared type is what callers ABOVE the definition see and the inferred one
   is what callers below see, and the two can disagree -- `let fn f : int -> int;`
   followed by `let f = fn (s: str) -> s;` type-checked, and the program had two
   incompatible ideas of f. *)
let forward_check_def name loc (t : Ast.ty) =
  match Hashtbl.find_opt forward_promised name with
  | None -> ()
  | Some (declared, dloc) ->
    Hashtbl.replace forward_kept name ();
    (* SUBSUMPTION, NOT INSTANTIATION. The first version instantiated the
       declaration and unified the definition against the instance -- the wrong
       direction, and it cost two things at once:
         - a definition could be MORE SPECIFIC than its declaration. `let fn idl:
           'a list -> 'a list;` with `let idl = fn (xs: int list) -> xs;` was
           accepted, and a caller written ABOVE the definition -- the only reason
           to declare a name -- could then call it on a `str list`. It type-checked,
           and the C backend failed with a codegen error on a program the typer
           had passed.
         - the fresh variables the instantiation made were created at the OUTER
           level, so unifying them with the definition's own variables pulled those
           down and `generalize` could no longer quantify them. A declared
           `'a -> 'a` was monomorphic from its first call site -- `ident 7` then
           `ident "s"` was a type error -- while the same definition WITHOUT a
           declaration was polymorphic. Declaring a type made a name less general
           than not declaring it.
       Unifying against the declaration AS WRITTEN fixes both: the parser makes
       `'a` a `TyParam`, and a TyParam unifies only with itself or an unbound
       variable, which is exactly a skolem. `fn x -> x` (`?1 -> ?1`) unifies; `fn
       (xs: int list) -> xs` does not, and is refused here rather than in a
       backend. *)
    (try Typer.unify loc declared t
     with _ ->
       raise (Typer.Type_error (loc,
         Printf.sprintf
           "`%s` was declared `%s` at line %d, and this definition is not that general"
           name (Ast.pp_ty declared) dloc.Loc.line)))

(* THE DECLARED TYPE IS WHAT THE NAME MEANS, above the definition and below it.
   Publishing the definition's INFERRED scheme instead gave the name two meanings:
   callers above got the declaration's, callers below the definition's, and a
   declaration exists precisely so that those are one thing. `forward_check_def`
   has already refused any definition less general than its promise, so the
   declared scheme is the sound one to publish. *)
let forward_scheme name (inferred : Typer.scheme) : Typer.scheme =
  match Hashtbl.find_opt forward_promised name with
  | Some (declared, _) -> Typer.scheme_of_written declared
  | None -> inferred

(* every promise must be kept: a name declared and never defined is a name
   nothing can call. *)
let forward_check_all_kept () =
  Hashtbl.iter (fun name (ty, loc) ->
    if not (Hashtbl.mem forward_kept name) then
      raise (Typer.Type_error (loc,
        Printf.sprintf
          "`let fn %s: %s;` promises a definition that this program never gives"
          name (Ast.pp_ty ty)))) forward_promised

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
let prelude_file = Prelude_stdlib.file_name

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

(* `pub` inside a module: what the module did not mark, nobody outside it calls.

   The parser records the private QUALIFIED names while it prefixes a module's
   declarations (`Parser.private_module_names`); this is the pass that enforces
   them. Declarations are flat by the time anyone sees them — `module M { let
   f }` is a top-level `M.f` — so "inside the module" is a question about the
   name of the declaration a reference sits in, and nothing deeper is needed.

   Reported as a type error because that is what it is: a name that does not
   resolve from where it was written. The message says which module, because
   "unbound variable: Store.secret" would send the reader looking for a typo. *)
let check_module_privacy (prog : Ast.program) =
  if Hashtbl.length Parser.private_module_names > 0 then begin
    let module_of (n : string) =
      match String.rindex_opt n '.' with
      | Some i -> String.sub n 0 i
      | None -> ""
    in
    let check_in (owner : string) (e : Ast.expr) =
      let rec go (x : Ast.expr) =
        (match x.Ast.node with
         | Ast.Var n when Hashtbl.mem Parser.private_module_names n ->
           let home = module_of n in
           (* Inside its own module, or inside one nested within it. *)
           let inside =
             owner = home
             || (String.length owner > String.length home
                 && String.sub owner 0 (String.length home) = home
                 && owner.[String.length home] = '.')
           in
           if not inside then
             raise (Typer.Type_error (x.Ast.loc,
               Printf.sprintf
                 "`%s` is internal to module `%s` (the module marks its exports with `pub`)"
                 n home))
         | _ -> ());
        List.iter go (Ast.children x)
      in
      go e
    in
    List.iter (fun d ->
      let owner =
        match d with
        | Ast.Top_let ({ Ast.pnode = Ast.P_var n; _ }, _) -> module_of n
        | Ast.Top_let_rec ((n, _) :: _) -> module_of n
        | _ -> ""
      in
      List.iter (check_in owner) (Ast.decl_exprs d)) prog.Ast.decls;
    check_in "" prog.Ast.main
  end

(* `| "lit" <> rest ->` : the arm becomes a guard and a binding.

   The rewrite, once, so that no backend has to learn a pattern:

     match s with | "http://" <> rest -> body
   =>
     match s with | __pfxN when str_starts_with __pfxN "http://" ->
                    let rest = utf8_sub __pfxN 7 (utf8_len __pfxN - 7) in body

   Every piece of that is a function the programs doing this by hand already
   call (`str_starts_with` and a slice, 13 times in `contrib/` alone). The arm
   binds the scrutinee rather than naming it, so the subject is evaluated once
   by `match` and the guard and the binding both read the same value.

   A GUARDED ARM CLOSES NOTHING, which is what exhaustiveness should already
   say about a prefix test: `| "a" <> r -> ...` covers some strings and the
   checker has no way to know which, so a `_` arm is still required. That falls
   out of the existing rule rather than being added to it.

   The literal's length is counted in CODE POINTS, because `utf8_sub` is
   codepoint-indexed. "http://" is 7 either way; "日本" is 2 here and 6 bytes.

   ⚠ `utf8_sub` walks the string. That is the right first implementation and the
   wrong one for a hot loop; a byte-indexed slice would be a builtin, which is
   five backends, and is worth adding when something measured asks for it. *)
let prefix_desugar (prog : Ast.program) : Ast.program =
  let counter = ref 0 in
  let codepoints (s : string) =
    let n = ref 0 in
    String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
    !n
  in
  let rec go (e : Ast.expr) : Ast.expr =
    Ast.rv_map_scoped ~shadow:[] (fun _ (x : Ast.expr) ->
      match x.Ast.node with
      | Ast.Match (scrut, arms)
        when List.exists (fun ((p : Ast.pattern), _, _) ->
               match p.Ast.pnode with Ast.P_str_prefix _ -> true | _ -> false) arms ->
        let arms' =
          List.map (fun ((p : Ast.pattern), guard, body) ->
            let guard = Option.map go guard and body = go body in
            match p.Ast.pnode with
            | Ast.P_str_prefix (lit, name) ->
              incr counter;
              let fresh = Printf.sprintf "__pfx%d" !counter in
              let loc = p.Ast.ploc in
              let mk node = { Ast.loc; ty = None; node } in
              let var n = mk (Ast.Var n) in
              let app f a = mk (Ast.App (f, a)) in
              let k = codepoints lit in
              let test =
                app (app (var "str_starts_with") (var fresh)) (mk (Ast.Str_lit lit))
              in
              let slice () =
                app (app (app (var "utf8_sub") (var fresh)) (mk (Ast.Int_lit k)))
                  (mk (Ast.Bin (Ast.Sub,
                                app (var "utf8_len") (var fresh),
                                mk (Ast.Int_lit k))))
              in
              let bind_rest e =
                if name = "_" then e
                else
                  { e with Ast.node =
                      Ast.Let ({ Ast.ploc = loc; pnode = Ast.P_var name }, slice (), e) }
              in
              let guard' =
                match guard with
                | None -> Some test
                (* THE USER'S GUARD CAN NAME THE BINDER — `| "ab" <> r when
                   str_len r > 1` — so `r` has to be bound for the guard too,
                   not only for the body. `&&` short-circuits, so the slice is
                   only computed once the prefix has matched. *)
                | Some g -> Some (mk (Ast.Logic (Ast.And, test, bind_rest g)))
              in
              let body' = bind_rest body in
              ({ Ast.ploc = loc; pnode = Ast.P_var fresh }, guard', body')
            | _ -> (p, guard, body)) arms
        in
        Some { x with Ast.node = Ast.Match (go scrut, arms') }
      | _ -> None) e
  in
  let decl d =
    match d with
    | Ast.Top_let (p, e) -> Ast.Top_let (p, go e)
    | Ast.Top_let_rec bs -> Ast.Top_let_rec (List.map (fun (n, e) -> (n, go e)) bs)
    | other -> other
  in
  { Ast.decls = List.map decl prog.Ast.decls; Ast.main = go prog.Ast.main }

(* `echo` -> `echo_at "<where>"`: the debug print gets its position.

   WHY A PASS AND NOT A PARSER CASE. The first version of this rewrote the
   token, which is simpler and wrong: `test/parity/graphql_stack_portable.mere`
   binds `echo` as a name of its own, and rewriting every occurrence turned its
   value into a partially applied function and the program into a type error.
   A debug helper that breaks a program which never asked for it is not worth
   having, so the rewrite runs over the parsed tree with scope tracked
   (`Ast.rv_map_scoped`), and a `echo` the user bound -- at top level or in any
   scope around the use -- is left alone and means what they said.

   The prelude's own `echo` does NOT shadow it: the prelude is prepended to
   every program, so counting its top-level names as user bindings would
   disable the rewrite everywhere. Top-level names are collected from
   declarations the user wrote, which are the ones whose positions carry no
   `<prelude>` file. *)
let echo_rewrite (prog : Ast.program) : Ast.program =
  let user_top =
    List.concat_map (fun d ->
      match d with
      | Ast.Top_let (p, _) ->
        List.filter_map (fun (n, (l : Loc.t)) ->
          if l.Loc.file = Some prelude_file then None else Some n)
          (Query.pattern_bindings p)
      | Ast.Top_let_rec bs ->
        List.filter_map (fun (n, (v : Ast.expr)) ->
          if v.Ast.loc.Loc.file = Some prelude_file then None else Some n) bs
      | Ast.Top_forward (n, _, (l : Loc.t)) ->
        if l.Loc.file = Some prelude_file then [] else [ n ]
      | _ -> []) prog.Ast.decls
  in
  if List.mem "echo" user_top then prog
  else
    let go (e : Ast.expr) =
      Ast.rv_map_scoped ~shadow:[] (fun sh (x : Ast.expr) ->
        match x.Ast.node with
        | Ast.Var "echo" when not (List.mem "echo" sh) ->
          let where =
            match x.Ast.loc.Loc.file with
            | Some f when f <> prelude_file ->
              Printf.sprintf "%s:%d" f x.Ast.loc.Loc.line
            | _ ->
              (* Minus whatever a driver glued in front of the file: on `-rv`
                 the prelude is prepended as TEXT, and an `echo` on line 2 was
                 reporting line 1925. A position inside the glue would go
                 non-positive, so it is clamped. *)
              Printf.sprintf "line %d"
                (max 1 (x.Ast.loc.Loc.line - !Loc.glued_lines))
          in
          Some { x with Ast.node =
                   Ast.App ({ x with Ast.node = Ast.Var "echo_at"; ty = None },
                            { x with Ast.node = Ast.Str_lit where; ty = None }) }
        | _ -> None) e
    in
    let decl d =
      match d with
      | Ast.Top_let (p, e) -> Ast.Top_let (p, go e)
      | Ast.Top_let_rec bs -> Ast.Top_let_rec (List.map (fun (n, e) -> (n, go e)) bs)
      | other -> other
    in
    { Ast.decls = List.map decl prog.Ast.decls; Ast.main = go prog.Ast.main }

(* A syntax error, with what was actually there added to it.

   The hint is a `help:` line on the message, which is the same shape every
   semantic error already uses — so nothing renders differently, and the 149
   places in the parser that raise stay untouched. What they could not know is
   what token the reader wrote; that is here, where the token list is.

   The failure position identifies the token by line and column. The one before
   it is what makes a compound operator legible (`x += 1` fails at `=` with `+`
   behind it), so both are looked up. *)
(* The names this file BINDS are identifiers, not attempts at another
   language's keyword. `&mut R v`, `let var = ...`, `fn val ->` and
   `fn (case: int) -> case * 2` are all real Mere in the repositories, and all
   four words are also in the hint table — so the table is told which names are
   spoken for here, and says nothing about those.

   A binding is recognised by SHAPE, not by scope: `let`/`and`/`rec` then a
   name then `=` or `:`, a parameter with an annotation, `fn name ->`, or a
   name after `&` (Mere's own borrow modes). `let mut x = 1;` does NOT match —
   `mut` is followed by a name, not by `=` — which is the case that has to keep
   its hint. *)
let bound_names (tokens : (Loc.t * Lexer.token) list) : string list =
  let rec go acc = function
    | a :: (Lexer.T_ident n as b) :: (c :: _ as rest) ->
      let is_binding =
        match a, c with
        | (Lexer.T_let | Lexer.T_and | Lexer.T_rec), (Lexer.T_eq | Lexer.T_colon) -> true
        | Lexer.T_fn, Lexer.T_arrow -> true
        | (Lexer.T_lparen | Lexer.T_comma | Lexer.T_fn), Lexer.T_colon -> true
        | Lexer.T_amp, _ -> true
        | _ -> false
      in
      go (if is_binding then n :: acc else acc) (b :: rest)
    | _ :: rest -> go acc rest
    | [] -> acc
  in
  go [] (List.map snd tokens)

(* Where the hint is attached. The parser raises in 149 places and all 149
   places in the parser stay untouched. What they could not know is what the
   reader wrote; that is here, where the token list is.

   The failure position identifies the token by line and column. The REST OF
   THAT LINE, nearest first, is what makes the spelling legible: `x += 1` fails
   at `=` with `+` behind it, and `if c then 1 elif x < 0 then 2` fails at the
   second `then`, four tokens past the `elif` that explains it. The line is the
   unit because a syntax error is explained by the line it is on. *)
let with_syntax_hint (tokens : (Loc.t * Lexer.token) list) (loc : Loc.t) (msg : string) : string =
  let rec find before = function
    | [] -> (before, None, [])
    | ((l : Loc.t), t) :: rest ->
      if l.Loc.line = loc.Loc.line && l.Loc.col = loc.Loc.col then
        (before, Some t, List.filteri (fun i _ -> i < 2) (List.map snd rest))
      else find ((l, t) :: before) rest
  in
  let (before, cur, after) = find [] tokens in
  let before =
    List.filter_map
      (fun ((l : Loc.t), t) -> if l.Loc.line = loc.Loc.line then Some t else None)
      before
  in
  let bound = bound_names tokens in
  let bound n = List.mem n bound in
  match Syntax_hint.for_window ~before ~cur ~after ~bound with
  | Some hint -> msg ^ "\n" ^ hint
  | None -> msg

(* The same for the lexer, where the offending thing is a character rather than
   a token: the position names it in the source. *)
let with_lex_hint (source : string) (loc : Loc.t) (msg : string) : string =
  let lines = String.split_on_char '\n' source in
  let line =
    match List.nth_opt lines (loc.Loc.line - 1) with Some l -> l | None -> ""
  in
  if loc.Loc.col < 1 || loc.Loc.col > String.length line then msg
  else
    match Syntax_hint.for_char line.[loc.Loc.col - 1] with
    | Some hint -> msg ^ "\n" ^ hint
    | None -> msg

(* Tokenize, and say what the character was when it refuses. *)
let tokenize_hinted ?file (source : string) =
  try Lexer.tokenize ?file source with
  | Lexer.Lex_error (loc, msg) when loc.Loc.file = None ->
    raise (Lexer.Lex_error (loc, with_lex_hint source loc msg))

(* `keep_sugar` is for the FORMATTER, and only for it.

   Sugar that is lowered while parsing (`echo` -> `echo_at "<where>"`) is
   invisible to everything downstream, which is the point — and the formatter
   is downstream. `mere fmt` on a file containing `echo x` printed
   `echo_at "line 2" x`: correct, equivalent, and not what the person wrote.
   A formatter that rewrites the source it is formatting is a tool people stop
   running.

   So the lowering is skipped on that one path. It is a parameter rather than a
   global because the formatter and the compiler run in the same process (the
   language server does both on every keystroke). *)
let parse_program ?(prelude = true) ?(keep_sugar = false) ?base_dir ?(search_paths = []) s =
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
  let tokens = tokenize_hinted s in
  let user_prog =
    try
      match base_dir with
      | Some d -> Parser.parse_program ~base_dir:d ~search_paths tokens
      | None -> Parser.parse_program ~search_paths tokens
    with
    (* Only for THIS file: an error from inside an `import` carries that
       file's position, and its tokens are not the ones in hand here. *)
    | Parser.Parse_error (loc, msg) when loc.Loc.file = None ->
      raise (Parser.Parse_error (loc, with_syntax_hint tokens loc msg))
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
              ((if keep_sugar then fun p -> p
                else (fun p ->
                  (* The privacy check rides with the sugar lowering for one
                     reason: both are skipped when formatting. A formatter that
                     refuses to format a program because of a name it cannot
                     call is a formatter people stop running on broken files,
                     which is when they need it. *)
                  check_module_privacy p; prefix_desugar (echo_rewrite p)))
                { user_prog with Ast.decls = prelude_decls @ user_prog.Ast.decls })))))
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
  let tokens = tokenize_hinted s in
  let (_, errors) =
    Parser.parse_program_recover ?base_dir ~search_paths tokens
  in
  (* The recovering path returns its errors rather than raising them, so the
     hint is added to each. A position from an imported file is left alone for
     the same reason as above. *)
  List.map (fun (file, (loc : Loc.t), msg) ->
    if file = None && loc.Loc.file = None then (file, loc, with_syntax_hint tokens loc msg)
    else (file, loc, msg))
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
   decide how a warning looks.

   A warning may carry a fix: the edit that answers it, with the position it
   goes at (`Exhaustive.fix`). Nothing on the terminal path reads it — the CLI
   renders the message and the `help:` lines exactly as before — but a warning
   that knows how to be answered should not have to be re-derived by whoever
   wants to answer it. *)
let warnings : (Loc.t * string * Exhaustive.fix option) list ref = ref []
let reset_warnings () = warnings := []
let take_warnings () = let ws = List.rev !warnings in warnings := []; ws
let warn loc msg = warnings := (loc, msg, None) :: !warnings
let warn_fix loc msg fix = warnings := (loc, msg, fix) :: !warnings

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

(* Where a type name was declared, newest first. The parser conses an entry per
   declaration, so a name declared twice has two entries -- which is exactly the
   pair this error is about and could not point at until v0.1.506. Prelude
   positions are dropped: they are in a text nobody can open. *)
let declaration_sites (name : string) : Loc.t list =
  List.filter_map (fun (n, (l : Loc.t)) ->
    if n = name && l.Loc.file = None && l.Loc.line > 0 then Some l else None)
    !Parser.declared_types

let redecl_message (name, a, b) =
  let first_line =
    match List.rev (declaration_sites name) with
    | (first : Loc.t) :: _ :: _ -> Printf.sprintf " (first declared on line %d)" first.Loc.line
    | _ -> ""
  in
  String.concat "\n"
    [ Printf.sprintf
        "type `%s` is declared twice with different constructors (`%s` and `%s`)%s"
        name a b first_line;
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

(* Just the `let` findings, drained and raised. Used by the interpreter before
   it evaluates a declaration; `enforce_exhaustive` drains everything else at
   the end, and both go through the same `Non_exhaustive` exception so the CLI
   renders them identically. *)
let enforce_refutable_lets () =
  match Exhaustive.let_findings () with
  | [] -> ()
  | fs ->
    let rendered = List.map (fun f -> (f.Exhaustive.f_loc, Exhaustive.text f)) fs in
    if !Exhaustive.allow then
      List.iter (fun (loc, msg) -> warn loc msg) rendered
    else raise (Exhaustive.Non_exhaustive rendered)

let enforce_exhaustive () =
  enforce_type_redecls ();
  let (ws, es) = Exhaustive.classify () in
  List.iter (fun (loc, msg, fix) -> warn_fix loc msg fix) ws;
  if es <> [] then
    if !Exhaustive.allow then List.iter (fun (loc, msg, fix) -> warn_fix loc msg fix) es
    (* The exception carries what the CLI prints, which is the pair it always
       carried: this path ends in a terminal, and a terminal cannot apply an
       edit. *)
    else raise (Exhaustive.Non_exhaustive (List.map (fun (l, m, _) -> (l, m)) es))

(* Bindings nothing reads, as warnings.

   Raised only from paths that have a program that type-checked: a binding that
   looks unread in a half-inferred tree is usually a name whose use is inside
   the expression that failed, and a warning about it is noise about code the
   person is in the middle of writing. (Gleam draws the same line and says why:
   it checks a scope for unused entities only if the scope was processed
   successfully.)

   The fix writes the `_`, which is the answer in the overwhelming majority of
   cases where the report is not a mistake — deleting the binding needs its
   extent, and a `Loc.t` is a start and a width. *)
let warn_unused (prog : Ast.program) =
  List.iter (fun (u : Query.unused) ->
    let fix =
      { Exhaustive.fx_title = Printf.sprintf "Prefix `%s` with `_`" u.Query.u_name;
        fx_at = u.Query.u_loc;
        fx_width = 0;
        fx_text = "_" }
    in
    warn_fix u.Query.u_loc
      (Printf.sprintf
         "unused binding `%s` -- nothing in this file reads it\n\
          help: prefix it with `_` (`_%s`) if that is deliberate, or remove it"
         u.Query.u_name u.Query.u_name)
      (Some fix))
    (Query.unused_bindings ~prelude_decls:(prelude_decl_count ()) prog)

(* Uses of a deprecated name, as warnings with the rename attached.

   Drained on the same paths and under the same rule as the unused check: only
   from a program that type-checked, because the name has to have RESOLVED for
   "this is the builtin" to mean anything. *)
let warn_deprecated () =
  List.iter (fun ((r : Deprecated.row), (loc : Loc.t)) ->
    (* Not the prelude's own uses. It is prepended to every program, it is
       where the compiler's own code lives, and a person cannot edit it: a
       warning there fires on every compile and names a line nobody wrote.
       (The reserved-name linter above learned this first.) *)
    if loc.Loc.file = Some prelude_file then () else
    let fix =
      { Exhaustive.fx_title =
          Printf.sprintf "Replace `%s` with `%s`" r.Deprecated.dp_name
            r.Deprecated.dp_replacement;
        fx_at = loc;
        fx_width = String.length r.Deprecated.dp_name;
        fx_text = r.Deprecated.dp_replacement }
    in
    warn_fix loc
      (Printf.sprintf
         "`%s` is deprecated since v%s, %s\n\
          help: use `%s` instead"
         r.Deprecated.dp_name r.Deprecated.dp_since r.Deprecated.dp_why
         r.Deprecated.dp_replacement)
      (Some fix))
    (Deprecated.take ())

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

(* v0.1.476: an `extern fn` for a name THIS COMPILER implements has to agree
   with it about how many arguments there are.
   
   Before this, it did not have to: the declaration was taken at face value, the
   call was emitted with that many arguments, and clang reported
   `too few arguments to function call, expected 3, have 2` about a line of
   generated C. The user's mistake, named somewhere the user did not write.
   
   Only the arity. Comparing types needs a compatibility notion that does not
   exist: `tcp_close : int -> unit` is what every contrib declares and the
   runtime returns `int`, so demanding an exact match would flag correct code.
   
   A warning rather than an error, because the same emission already fails at
   the C compiler with a concrete message -- this one arrives first and points
   at the declaration, which is the part that was missing. *)
let warn_extern_arity () =
  let rec arity t =
    match Ast.walk t with
    | Ast.TyArrow (p, r) ->
      (* `unit` in argument position is the no-argument spelling, not an
         argument -- `tty_raw : unit -> unit` takes none. *)
      (match Ast.walk p with Ast.TyUnit -> arity r | _ -> 1 + arity r)
    | _ -> 0
  in
  List.iter
    (fun (name, ty, loc) ->
       match Codegen_c.native_ffi_declared_arity name with
       | None -> ()
       | Some want ->
         let got = arity ty in
         if got <> want then
           warn loc
             (Printf.sprintf
                "`extern fn %s` declares %d argument%s, but this compiler \
                 implements `%s` with %d. The declaration is what the call is \
                 emitted from, so the mismatch surfaces as a C compiler error \
                 about generated code rather than about this line."
                name got (if got = 1 then "" else "s") name want))
    !Parser.declared_externs

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
  warn_extern_arity ();
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (pat, value) ->
      warn_reserved_in_pattern pat;
      let outer_env = !type_env in
      (* Pattern variables belong to this binding — see Typer's Let case. *)
      let bindings =
        Typer.enter_level (fun () ->
          let t = infer_top_let outer_env value in
          Exhaustive.record_let pat.Ast.ploc t pat;
          Typer.check_pattern pat t) in
      (* BEFORE evaluating it. The interpreter walks declarations and runs each
         one as it goes, so a refutable `let` reached its own runtime failure
         before anything drained the findings -- the run path answered "eval
         error: top-level let pattern did not match" while `mere check` and
         every emit path answered "missing None" at compile time. One question
         had two answers again, one layer further in. *)
      enforce_refutable_lets ();
      let v = Eval.eval_in !eval_env value in
      (match Eval.match_pattern pat v with
       | None ->
         raise (Eval.Eval_error (pat.Ast.ploc,
           "top-level let pattern did not match"))
       | Some val_bindings ->
         eval_env := List.fold_left (fun acc (n, v) ->
           (* a promised name is FILLED, not rebound: callers written above
              hold the very ref this assigns into. *)
           if Hashtbl.mem forward_promised n then
             (match List.assoc_opt n acc with
              | Some r -> r := v; acc
              | None -> (n, ref v) :: acc)
           else (n, ref v) :: acc) !eval_env val_bindings);
      List.iter (fun (n, ty) -> forward_check_def n value.Ast.loc ty) bindings;
      type_env := List.fold_left (fun acc (n, ty) ->
        let sch = forward_scheme n (top_let_scheme outer_env value ty) in
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
      List.iter2 (fun (n, value) alpha -> forward_check_def n value.Ast.loc alpha) bindings alphas;
      (* a member that KEEPS A PROMISE reuses the ref the promise made, so a
         caller written above the group -- the only reason to declare it --
         ends up holding the finished function and not the placeholder. *)
      let placeholders = List.map (fun (n, _) ->
        if Hashtbl.mem forward_promised n then
          (match List.assoc_opt n !eval_env with
           | Some r -> (n, r)
           | None -> (n, ref Eval.V_unit))
        else (n, ref Eval.V_unit)) bindings in
      let env_eval = List.fold_left (fun acc (n, r) -> (n, r) :: acc) !eval_env placeholders in
      List.iter (fun (n, value) ->
        let v = Eval.eval_in env_eval value in
        let r = List.assoc n placeholders in
        r := v
      ) bindings;
      eval_env := env_eval;
      type_env := List.fold_left2 (fun acc (n, _) a ->
        let sch = forward_scheme n (Typer.generalize outer_env a) in
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
    (* A FORWARD DECLARATION binds the name to its written type from here on.
       Unlike extern there is no foreign implementation behind it: the
       definition is a later `let` in this same program, and the eval side gets a placeholder that the definition overwrites. *)
    | Ast.Top_forward (name, ty, floc) ->
      Hashtbl.replace forward_promised name (ty, floc);
      type_env := (name, Typer.scheme_of_written ty) :: !type_env;
      eval_env := (name, ref Eval.V_unit) :: !eval_env
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
  ) decls;
  forward_check_all_kept ()

(* What a program prints when it ends: `None` when it has nothing to say.
   `process` below is the same thing as a string, for the hundreds of callers
   that want one -- one rule, two spellings of the answer, rather than two
   places that decide. *)
let process_opt ?base_dir ?(search_paths = []) s =
  forward_reset ();
  Exhaustive.reset ();
  Deprecated.reset ();
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
  match v with
  (* Q-136: a program whose value is unit has nothing to say, and said `()`.
     `Eval.to_string` is NOT the place to change that -- `show ()` goes through
     it and has to keep answering `()`. The decision belongs to "what does a
     program print when it ends", which is here. The compiled backends make the
     same one in their own `main_format_of`, so the interp/compiled parity the
     old behaviour was built for still holds; it now holds at silence. *)
  | Eval.V_unit -> None
  | _ -> Some (Eval.to_string v)

(* Test-friendly entry point: returns the exhaustiveness warnings as a list
   (no side-effects), for unit tests to assert against. *)
let process ?base_dir ?(search_paths = []) s =
  match process_opt ?base_dir ~search_paths s with
  | Some r -> r
  | None -> ""

let exhaustiveness_warnings s =
  Exhaustive.reset ();
  Deprecated.reset ();
  Typer.reset_send_constraints ();
  Typer.reset_region_params ();
  let prog = Trait_elab.elaborate (parse_program s) in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  Exhaustive.take ()

(* `?base_dir` / `?search_paths` so a program with `import`s can be asked too --
   without them every imported name is unbound and the answer is an error rather
   than a type. `decls_report` is the caller that needs it. *)
let type_of ?base_dir ?(search_paths = []) s =
  Exhaustive.reset ();
  Deprecated.reset ();
  Typer.reset_send_constraints ();
  Typer.reset_region_params ();
  let prog = Trait_elab.elaborate (parse_program ?base_dir ~search_paths s) in
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
      List.iter2 (fun (n, value) alpha -> forward_check_def n value.Ast.loc alpha) bindings alphas;
      type_env := List.fold_left2 (fun acc (n, _) a ->
        let sch = forward_scheme n (Typer.generalize outer_env a) in
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
    | Ast.Top_forward (name, ty, _) ->
      type_env := (name, Typer.scheme_of_written ty) :: !type_env
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
(* `mere --decls <file>`: the forward declaration for every top-level function
   the file defines, in definition order. Splitting a `let rec ... and ...`
   chain means writing one `let fn <name>: <ty>;` per name the halves share,
   and a chain worth splitting has hundreds -- mere-ruby's evaluator needs 161
   for one cut. Typing them by hand is transcription, and the compiler already
   knows every answer. Q-137.

   The types come from the inference that just ran, so a name whose type the
   program does not pin (an unused polymorphic helper) prints with the type
   variables inference gave it; a declaration is monomorphic, so such a line
   has to be looked at rather than pasted. *)
(* One declaration of the user's, as data.

   `decls_report` used to build its text inline, which was fine while text was
   the only reader. It is not any more: `--decls --json` answers the same
   question for a machine, and two functions walking the same declarations
   would be two answers about one program the first time either is edited. So
   the walk happens once, here, and the two outputs are two renderings of this
   list. The text is unchanged, byte for byte, and
   `scripts/decls_json_check.sh` rebuilds it FROM the JSON to say so. *)
type decl_entry = {
  de_name : string;     (* the name as the source spells it *)
  de_type : string;     (* the inferred type, printed *)
  (* "ok" | "duplicate" | "shadows-builtin" — why a line is commented out.
     Both non-ok kinds are declarations that would change the program if pasted
     back, which is the whole reason the text comments them rather than
     dropping them. *)
  de_status : string;
  de_note : string;     (* the sentence the text puts after the line; "" when ok *)
}

let decls_entries ?base_dir ?(search_paths = []) s : decl_entry list =
  Exhaustive.reset ();
  Deprecated.reset ();
  Typer.reset_send_constraints ();
  Typer.reset_region_params ();
  forward_reset ();
  let prog = Trait_elab.elaborate (parse_program ?base_dir ~search_paths s) in
  (* ⚠ TYPE-CHECK WITHOUT RUNNING. This used `process_decls`, which EVALUATES
     every top-level `let` -- so asking a program for its declarations ran the
     program, and its output came out interleaved with them. `type_of` walks the
     same declarations for their types alone; the main expression it returns is
     not wanted here, only the schemes it records on the way. *)
  ignore (type_of ?base_dir ~search_paths s);
  let out = Buffer.create 4096 in
  (* ⚠ ONLY THE USER'S OWN DECLARATIONS, AND UNDER THE NAMES THE SOURCE USES.
     `parse_program` returns the prelude spliced in front and every top-level
     name run through `uniquify_toplevel_shadows`, and the first version of this
     report walked all of it: it printed ~70 declarations of prelude functions
     before the program's own, under renamed spellings like `decr__v2`. Pasting
     that back -- the only thing this output is for -- produced a program that
     promises names it never defines. Round-tripping every one of the 178 parity
     programs through it failed on all 178, which is also how this was found:
     printing something plausible is not the same as printing something that
     goes back in. *)
  let user_decls =
    let n = prelude_decl_count () in
    let rec drop k l = if k <= 0 then l else match l with [] -> [] | _ :: t -> drop (k - 1) t in
    drop n prog.Ast.decls
  in
  let names_of decl = match decl with
    | Ast.Top_let ({ Ast.pnode = Ast.P_var n; _ }, _) -> [n]
    | Ast.Top_let_rec bs -> List.map fst bs
    | _ -> [] in
  (* ⚠ TWO KINDS OF NAME MUST NOT BE DECLARED SILENTLY, and both are exactly the
     names `uniquify_toplevel_shadows` had to rename:

       a name bound TWICE at top level (`let x = 1; let x = x + 40;`) cannot be
       described by two declarations of one name at all; and

       a name that SHADOWS A BUILTIN changes the program's meaning if a
       declaration is pasted above it. Top-level bindings are sequential, so a
       caller written above `let show = ...` uses the BUILTIN show -- test/parity/
       shadow_builtin.mere exists to hold exactly that -- and a declaration puts
       the user's `show` in scope from the declaration down. That is the feature
       working, not a fault, which is why the line is still printed: silently
       dropping it would leave a chain uncuttable with no explanation. It is
       commented, with the reason, so the person pasting it decides.

     Found by round-tripping the parity corpus: `--decls`, output pasted back,
     must give byte-identical output. shadow_builtin printed `SHOWN MY SHOW`
     where the original prints `SHOWN 7`. *)
  let src_count = Hashtbl.create 64 in
  List.iter (fun d -> List.iter (fun n ->
    let s = Ast.toplevel_source_name n in
    Hashtbl.replace src_count s (1 + (try Hashtbl.find src_count s with Not_found -> 0)))
    (names_of d)) user_decls;
  ignore out;
  let entries = ref [] in
  List.iter (fun decl ->
    List.iter (fun n ->
      match Hashtbl.find_opt Typer.top_schemes n with
      | Some sch ->
        let src = Ast.toplevel_source_name n in
        let dup = (try Hashtbl.find src_count src with Not_found -> 1) > 1 in
        let (status, note) =
          if dup then
            ("duplicate",
             Printf.sprintf "`%s` is bound %d times at top level; one declaration cannot name them all"
               src (Hashtbl.find src_count src))
          else if src <> n then
            ("shadows-builtin",
             Printf.sprintf "`%s` shadows a builtin: declaring it here puts YOUR `%s` in scope from this line, so callers written above the definition would stop seeing the builtin"
               src src)
          else ("ok", "")
        in
        entries :=
          { de_name = src; de_type = Ast.pp_ty sch.Typer.body;
            de_status = status; de_note = note } :: !entries
      | None -> ()) (names_of decl))
    user_decls;
  List.rev !entries

(* The text, from the entries. This is the output `--decls` has always had, and
   the one `decls_roundtrip.sh` pastes back into a program. *)
let render_decl_entry (e : decl_entry) : string =
  let line = Printf.sprintf "let fn %s: %s;" e.de_name e.de_type in
  if e.de_status = "ok" then line ^ "\n"
  else Printf.sprintf "// %s   // %s\n" line e.de_note

let decls_report ?base_dir ?(search_paths = []) s =
  String.concat "" (List.map render_decl_entry (decls_entries ?base_dir ~search_paths s))

(* The same declarations, for a machine.

   WHAT IT IS FOR: the difference between two versions of a package. `mere fix`
   writes a floor into `mere.toml` from the features a file uses; what it cannot
   say is whether the API a downstream repository depends on has changed. That
   question is a diff of this document.

   Gleam's `gleam export package-interface` is the same idea, and its JSON
   carries the version constraint alongside the interface
   (`package_interface.rs`) — which is why `requires` is here rather than in a
   second file: the promise and the surface are one answer.

   `requires` is passed in rather than read here: it is a fact about the
   PACKAGE (the nearest `mere.toml`), and this module compiles a file. The CLI
   is what knows which package a path is in. *)
let decls_json ?base_dir ?(search_paths = []) ?(requires : string option) s : string =
  let entries = decls_entries ?base_dir ~search_paths s in
  (* The type declarations the user wrote. Positions come from the parser's
     table because `Top_type` carries none; the prelude's are excluded by their
     file, the way every other reader of that table excludes them. *)
  let prog = parse_program ?base_dir ~search_paths s in
  let user_decls =
    let n = prelude_decl_count () in
    let rec drop k l = if k <= 0 then l else match l with [] -> [] | _ :: t -> drop (k - 1) t in
    drop n prog.Ast.decls
  in
  let line_of name =
    match List.assoc_opt name !Parser.declared_types with
    | Some (l : Loc.t) when l.Loc.file = None -> l.Loc.line
    | _ -> 0
  in
  let types =
    List.filter_map (fun d ->
      match d with
      | Ast.Top_type (name, params, variants) ->
        Some (Json.Obj [
          ("name", Json.Str name);
          ("kind", Json.Str "variant");
          ("params", Json.List (List.map (fun p -> Json.Str p) params));
          ("line", Json.Num (float_of_int (line_of name)));
          ("constructors",
           Json.List (List.map (fun (cn, payload) ->
             Json.Obj [ ("name", Json.Str cn);
                        ("payload",
                         match payload with
                         | Some t -> Json.Str (Ast.pp_ty t)
                         | None -> Json.Null) ]) variants)) ])
      | Ast.Top_record (name, params, fields) ->
        Some (Json.Obj [
          ("name", Json.Str name);
          ("kind", Json.Str "record");
          ("params", Json.List (List.map (fun p -> Json.Str p) params));
          ("line", Json.Num (float_of_int (line_of name)));
          ("fields",
           Json.List (List.map (fun (fn, ft) ->
             Json.Obj [ ("name", Json.Str fn); ("type", Json.Str (Ast.pp_ty ft)) ])
             fields)) ])
      | _ -> None) user_decls
  in
  Json.to_string (Json.Obj [
    ("mere", Json.Str Version.v);
    ("requires", (match requires with Some r -> Json.Str r | None -> Json.Null));
    ("values",
     Json.List (List.map (fun e ->
       Json.Obj [ ("name", Json.Str e.de_name);
                  ("type", Json.Str e.de_type);
                  ("status", Json.Str e.de_status);
                  ("note", Json.Str e.de_note) ]) entries));
    ("types", Json.List types);
  ])

let region_param_report ?base_dir ?(search_paths = []) s =
  Exhaustive.reset ();
  Deprecated.reset ();
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
        List.iter2 (fun (n, value) alpha -> forward_check_def n value.Ast.loc alpha) bindings alphas;
      type_env := List.fold_left2 (fun acc (n, _) a ->
        let sch = forward_scheme n (Typer.generalize outer_env a) in
        Typer.record_top_scheme n sch;
        (n, sch) :: acc) outer_env bindings alphas
    | Ast.Top_type (name, params, variants) -> Typer.register_type name params variants
    | Ast.Top_record (name, params, fields) -> Typer.register_record name params fields
    | Ast.Top_view (name, region, fields) -> Typer.register_view name region fields
    | Ast.Top_drop name -> Typer.register_drop_type name
    | Ast.Top_sync name -> Typer.register_sync_type name
    | Ast.Top_local name -> Typer.register_local_type name
    | Ast.Top_forward (name, ty, _) -> type_env := (name, Typer.scheme_of_written ty) :: !type_env
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
  Deprecated.reset ();
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
  forward_reset ();
  Typer.reset_send_constraints ();
  Typer.reset_region_params ();
  (* The compile path never reset this — it worked only because nothing drained
     it either, and a second `infer_program` in one process would have been
     judged against the first one's matches. *)
  Exhaustive.reset ();
  Deprecated.reset ();
  let prog =
    Trait_elab.elaborate
      (parse_program ?base_dir ~search_paths source)
  in
  (* The same warnings process_decls raises. This is the path an editor takes, and a
     warning it cannot see is one nobody sees. *)
  warn_declared_types ();
  warn_extern_arity ();
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
        List.iter (fun (n, ty) -> forward_check_def n value.Ast.loc ty) bindings;
        type_env := List.fold_left (fun acc (n, ty) ->
          (n, forward_scheme n (top_let_scheme outer_env value ty)) :: acc) outer_env bindings)
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
          List.iter2 (fun (n, value) alpha -> forward_check_def n value.Ast.loc alpha) bindings alphas;
        type_env := List.fold_left2 (fun acc (n, _) a ->
          let sch = forward_scheme n (Typer.generalize outer_env a) in
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
    | Ast.Top_forward (name, ty, floc) ->
      Hashtbl.replace forward_promised name (ty, floc);
      (* Into BOTH, for the same reason as extern below. *)
      type_env := (name, Typer.scheme_of_written ty) :: !type_env;
      base_env := (name, Typer.scheme_of_written ty) :: !base_env
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
  forward_check_all_kept ();
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
        scrutinee whose type never resolved. The same is true of "nothing reads
        this": a file mid-edit has plenty of names whose reader is the line
        being written. *)
     warn_unused prog;
     warn_deprecated ();
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
  (* The edit that answers this diagnostic, when the checker that raised it
     knows one. `mere lsp` turns it into a code action; the terminal renderer
     ignores it, because the `help:` line inside `d_msg` already says the same
     thing to a reader who is going to type it themselves. *)
  d_fix : Exhaustive.fix option;
}

let check ?base_dir ?(search_paths = []) (source : string)
  : Ast.program option * diagnostic list =
  (* A position knows which file it came from (the lexer stamps imported ones),
     so a diagnostic does too — including a type error, which is raised long after
     the parse and could not otherwise say. *)
  let err ?file kind (loc, msg) =
    let file = match file with Some f -> Some f | None -> loc.Loc.file in
    { d_loc = loc; d_kind = kind; d_msg = msg; d_severity = Error; d_file = file;
      d_fix = None }
  in
  let warning (loc, msg, fix) =
    { d_loc = loc; d_kind = "warning"; d_msg = msg;
      d_severity = Warning; d_file = None; d_fix = fix }
  in
  reset_warnings ();
  Exhaustive.reset ();
  Deprecated.reset ();
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
          not show it is describing a program the compiler will refuse.

          `Top_type` carries no position, which is why this had NONE at all --
          the message was good and pointed at nothing. The parser's table knows
          where every type name was declared, so the caret goes on the SECOND
          declaration (the one that introduced the conflict) and the message
          names the first. *)
       let redecls =
         List.map (fun ((name, _, _) as r) ->
           let loc =
             match declaration_sites name with
             | latest :: _ :: _ -> latest   (* two or more: the newest is the conflict *)
             | _ -> Loc.dummy
           in
           { d_loc = loc; d_kind = "type error"; d_msg = redecl_message r;
             d_severity = Error; d_file = None; d_fix = None })
           (Typer.take_type_redecls ())
       in
       let (ex_ws, ex_es) = Exhaustive.classify () in
       let ws =
         List.map warning (take_warnings ())
         @ List.map warning ex_ws
         (* A named missing case is an error, and it is the one error in this
            list that arrives with its own answer attached. *)
         @ List.map (fun (loc, msg, fix) ->
             { d_loc = loc; d_kind = "error"; d_msg = msg;
               d_severity = Error; d_file = None; d_fix = fix }) ex_es
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
          only worth handing back when nothing went wrong.

          The unused check runs here rather than inside inference, because this
          path is the recovering one: it is reached with errors in hand, and the
          answer is only worth asking for when there are none. *)
       let ws =
         if errs = [] then begin
           reset_warnings ();
           warn_unused prog;
           warn_deprecated ();
           ws @ List.map warning (take_warnings ())
         end else ws
       in
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
(* The comments the formatter is allowed to place: the ones that start in
   column 1, as (line, text).

   The lexer has been able to collect comments since semantic tokens needed
   them; it records a position and a width, so the text is a slice of the line
   it is on. Nothing else had asked, which is why `mere fmt` deleted every
   comment in a file until v0.1.505. *)
let column_one_comments (source : string) : (int * string) list =
  let lines = Array.of_list (String.split_on_char '\n' source) in
  let acc = ref [] in
  ignore (try Lexer.tokenize ~comments:acc source with _ -> []);
  List.filter_map (fun (loc : Loc.t) ->
    if loc.Loc.col <> 1 || loc.Loc.line < 1 || loc.Loc.line > Array.length lines then None
    else
      let line = lines.(loc.Loc.line - 1) in
      let w = min loc.Loc.width (String.length line) in
      if w <= 0 then None else Some (loc.Loc.line, String.sub line 0 w))
    (List.sort (fun (a : Loc.t) b -> compare a.Loc.line b.Loc.line) !acc)

let format_source ?(base_dir = Sys.getcwd ()) ?(search_paths = []) source =
  let prelude_decls = parse_prelude () in
  let n_prelude = List.length prelude_decls in
  let prog = parse_program ~prelude:true ~keep_sugar:true ~base_dir ~search_paths source in
  let rec drop n xs =
    if n <= 0 then xs else match xs with [] -> [] | _ :: rest -> drop (n - 1) rest
  in
  (* A declaration the AST cannot place may still be placeable by name: the
     parser records where each `type` / record declaration's name was. *)
  let decl_line (d : Ast.top_decl) =
    match Formatter.default_decl_line d with
    | Some l -> Some l
    | None ->
      let named =
        match d with
        | Ast.Top_type (n, _, _) | Ast.Top_record (n, _, _)
        | Ast.Top_type_alias (n, _, _) -> Some n
        | _ -> None
      in
      (match named with
       | None -> None
       | Some n ->
         (match List.assoc_opt n !Parser.declared_types with
          | Some (l : Loc.t) when l.Loc.file = None && l.Loc.line > 0 -> Some l.Loc.line
          | _ -> None))
  in
  Formatter.format_program
    ~comments:(column_one_comments source)
    ~decl_line
    { prog with Ast.decls = drop n_prelude prog.Ast.decls }
