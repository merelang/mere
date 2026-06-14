(* Interactive Read-Eval-Print Loop.

   Maintains a persistent eval-env and type-env across inputs. Each input
   can be either a top-level program fragment (decls + main expr) or an
   expression alone.

   Commands:
     :quit | :q      exit REPL
     :type EXPR      print the inferred type of EXPR
     :help | :h      show help
*)

let help_text =
  "Commands:\n\
  \  :quit | :q      exit\n\
  \  :type EXPR      show inferred type of EXPR\n\
  \  :help | :h      this help\n\
   Otherwise: enter a Lang program. Top-level decls use `let NAME = EXPR;`\n\
   followed by a main expression (or `let NAME = EXPR;` alone to just bind)."

(* Format an error from any of the pipeline stages. *)
let format_exn = function
  | Lexer.Lex_error (loc, msg) ->
    Printf.sprintf "lex error at %s: %s" (Loc.to_string loc) msg
  | Parser.Parse_error (loc, msg) ->
    Printf.sprintf "parse error at %s: %s" (Loc.to_string loc) msg
  | Typer.Type_error (loc, msg) ->
    Printf.sprintf "type error at %s: %s" (Loc.to_string loc) msg
  | Eval.Eval_error (loc, msg) ->
    Printf.sprintf "eval error at %s: %s" (Loc.to_string loc) msg
  | e -> "internal error: " ^ Printexc.to_string e

(* Process one top decl, updating both envs.
   Returns Some (name, scheme) for binding decls, None for type decls. *)
let process_decl eval_env type_env decl =
  match decl with
  | Ast.Top_let (name, value) ->
    let t = Typer.infer !type_env value in
    let sch = Typer.generalize !type_env t in
    let v = Eval.eval_in !eval_env value in
    eval_env := (name, ref v) :: !eval_env;
    type_env := (name, sch) :: !type_env;
    Some (name, sch)
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
    type_env := (name, sch) :: !type_env;
    Some (name, sch)
  | Ast.Top_type (name, params, variants) ->
    Typer.register_type name params variants;
    let param_str = match params with
      | [] -> ""
      | [p] -> "'" ^ p ^ " "
      | _ -> "(" ^ String.concat ", " (List.map (fun p -> "'" ^ p) params) ^ ") "
    in
    Printf.printf "type %s%s defined (%d variants)\n" param_str name (List.length variants);
    None
  | Ast.Top_signature (name, params) ->
    Printf.printf "signature %s defined (%d params)\n" name (List.length params);
    None
  | Ast.Top_record (name, params, fields) ->
    Typer.register_record name params fields;
    let param_str = match params with
      | [] -> ""
      | [p] -> "'" ^ p ^ " "
      | _ -> "(" ^ String.concat ", " (List.map (fun p -> "'" ^ p) params) ^ ") "
    in
    Printf.printf "record %s%s defined (%d fields)\n" param_str name (List.length fields);
    None

(* Synthesize a trailing `; ()` so inputs that only declare bind correctly. *)
let prepare_input s =
  let trimmed = String.trim s in
  let len = String.length trimmed in
  if len > 0 && trimmed.[len - 1] = ';' then trimmed ^ " ()"
  else trimmed

let starts_with prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let handle_input eval_env type_env input =
  let prepared = prepare_input input in
  let tokens = Lexer.tokenize prepared in
  let prog = Parser.parse_program tokens in
  let added = List.filter_map (process_decl eval_env type_env) prog.decls in
  let main_t = Typer.infer !type_env prog.main in
  let main_v = Eval.eval_in !eval_env prog.main in
  List.iter (fun (name, sch) ->
    Printf.printf "val %s : %s\n" name (Ast.pp_ty sch.Typer.body)
  ) added;
  (* Suppress lone unit results (e.g., when only decls were entered or
     a side-effecting call like `print` ran). *)
  (match main_v with
   | Eval.V_unit when prog.main.Ast.node = Ast.Unit_lit -> ()
   | _ ->
     Printf.printf "- : %s = %s\n"
       (Ast.pp_ty main_t) (Eval.to_string main_v))

let handle_type eval_env type_env expr_text =
  let _ = eval_env in
  let tokens = Lexer.tokenize expr_text in
  let prog = Parser.parse_program tokens in
  let expr = Ast.desugar_program prog in
  let t = Typer.infer !type_env expr in
  Printf.printf "%s\n" (Ast.pp_ty t)

let run () =
  print_endline "lang-ml REPL. Type :help for commands, :quit to exit.";
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  let rec loop () =
    print_string "> ";
    (match read_line () with
     | exception End_of_file -> print_newline ()
     | line ->
       let trimmed = String.trim line in
       if trimmed = "" then loop ()
       else if trimmed = ":quit" || trimmed = ":q" then ()
       else if trimmed = ":help" || trimmed = ":h" then begin
         print_endline help_text;
         loop ()
       end
       else if starts_with ":type " trimmed then begin
         let expr_text = String.sub trimmed 6 (String.length trimmed - 6) in
         (try handle_type eval_env type_env expr_text
          with e -> print_endline (format_exn e));
         loop ()
       end
       else if starts_with ":" trimmed then begin
         Printf.printf "unknown command: %s (try :help)\n" trimmed;
         loop ()
       end
       else begin
         (try handle_input eval_env type_env line
          with e -> print_endline (format_exn e));
         loop ()
       end)
  in
  loop ()
