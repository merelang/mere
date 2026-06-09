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
    | Ast.Top_let_rec (name, value) ->
      let alpha = Typer.fresh_var () in
      let env_rec = (name, Typer.mono alpha) :: !type_env in
      let t = Typer.infer env_rec value in
      Typer.unify value.Ast.loc alpha t;
      let sch = Typer.generalize !type_env t in
      let placeholder = ref Eval.V_unit in
      let env_eval = (name, placeholder) :: !eval_env in
      let v = Eval.eval_in env_eval value in
      placeholder := v;
      eval_env := env_eval;
      type_env := (name, sch) :: !type_env
    | Ast.Top_type (name, variants) ->
      Typer.register_type name variants
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
    | Ast.Top_let_rec (name, value) ->
      let alpha = Typer.fresh_var () in
      let env_rec = (name, Typer.mono alpha) :: !type_env in
      let t = Typer.infer env_rec value in
      Typer.unify value.Ast.loc alpha t;
      let sch = Typer.generalize !type_env t in
      type_env := (name, sch) :: !type_env
    | Ast.Top_type (name, variants) ->
      Typer.register_type name variants
  ) prog.decls;
  Ast.pp_ty (Typer.infer !type_env prog.main)

let process_typed s =
  let prog = parse_program s in
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  process_decls eval_env type_env prog.decls;
  let _ = Typer.infer !type_env prog.main in
  Eval.to_string (Eval.eval_in !eval_env prog.main)
