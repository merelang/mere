(* Source string -> ... convenience functions.
   Handles top-level decls (let, let rec, type) in order. *)

let parse_program ?base_dir s =
  let tokens = Lexer.tokenize s in
  match base_dir with
  | Some d -> Parser.parse_program ~base_dir:d tokens
  | None -> Parser.parse_program tokens

let parse_only s =
  let prog = parse_program s in
  Ast.desugar_program prog

(* Process top-decls in order, updating envs and the typer's constructor table. *)
let process_decls eval_env type_env decls =
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (pat, value) ->
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
      let outer_env = !type_env in
      let t = Typer.infer outer_env value in
      let bindings = Typer.check_pattern pat t in
      type_env := List.fold_left (fun acc (n, ty) ->
        let sch = Typer.generalize outer_env ty in
        (n, sch) :: acc) outer_env bindings;
      eval_env := !eval_env  (* unused *)
    | Ast.Top_let_rec bindings ->
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
