(* Source string -> ... convenience functions.
   Handles top-level decls (let, let rec, type) in order. *)

let parse_program s =
  let tokens = Lexer.tokenize s in
  Parser.parse_program tokens

let parse_only s =
  let prog = parse_program s in
  Ast.desugar_program prog

(* Process top-decls in order, updating envs and the typer's constructor table. *)
let process_decls eval_env type_env decls =
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (name, value) ->
      let t = Typer.infer !type_env value in
      let sch = Typer.generalize !type_env t in
      let v = Eval.eval_in !eval_env value in
      eval_env := (name, ref v) :: !eval_env;
      type_env := (name, sch) :: !type_env
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
  ) decls

let process s =
  let prog = parse_program s in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  let v = Eval.eval_in !eval_env prog.main in
  Eval.to_string v

let type_of s =
  let prog = parse_program s in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  (* Type-check decls but skip eval to avoid side effects. *)
  List.iter (fun decl ->
    match decl with
    | Ast.Top_let (name, value) ->
      let t = Typer.infer !type_env value in
      let sch = Typer.generalize !type_env t in
      type_env := (name, sch) :: !type_env;
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
  ) prog.decls;
  Ast.pp_ty (Typer.infer !type_env prog.main)

let process_typed s =
  let prog = parse_program s in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  Eval.to_string (Eval.eval_in !eval_env prog.main)
