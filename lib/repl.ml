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
   Returns a list of (name, scheme) for binding decls, [] for type decls. *)
let process_decl eval_env type_env decl =
  match decl with
  | Ast.Top_let (pat, value) ->
    let outer_env = !type_env in
    let t = Typer.infer outer_env value in
    let bindings = Typer.check_pattern pat t in
    let v = Eval.eval_in !eval_env value in
    let val_bindings =
      match Eval.match_pattern pat v with
      | Some bs -> bs
      | None ->
        raise (Eval.Eval_error (pat.Ast.ploc,
          "top-level let pattern did not match"))
    in
    eval_env := List.fold_left (fun acc (n, v) -> (n, ref v) :: acc)
                  !eval_env val_bindings;
    let added = List.map (fun (n, ty) ->
      let sch = Typer.generalize outer_env ty in
      (n, sch)
    ) bindings in
    type_env := List.fold_left (fun acc (n, s) -> (n, s) :: acc) outer_env added;
    added
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
    let added = List.map2 (fun (n, _) a ->
      let sch = Typer.generalize outer_env a in
      (n, sch)
    ) bindings alphas in
    type_env := List.fold_left (fun acc (n, s) -> (n, s) :: acc) outer_env added;
    added
  | Ast.Top_type (name, params, variants) ->
    Typer.register_type name params variants;
    let param_str = match params with
      | [] -> ""
      | [p] -> "'" ^ p ^ " "
      | _ -> "(" ^ String.concat ", " (List.map (fun p -> "'" ^ p) params) ^ ") "
    in
    Printf.printf "type %s%s defined (%d variants)\n" param_str name (List.length variants);
    []
  | Ast.Top_signature (name, params) ->
    Printf.printf "signature %s defined (%d params)\n" name (List.length params);
    []
  | Ast.Top_record (name, params, fields) ->
    Typer.register_record name params fields;
    let param_str = match params with
      | [] -> ""
      | [p] -> "'" ^ p ^ " "
      | _ -> "(" ^ String.concat ", " (List.map (fun p -> "'" ^ p) params) ^ ") "
    in
    Printf.printf "record %s%s defined (%d fields)\n" param_str name (List.length fields);
    []
  | Ast.Top_type_alias (name, params, body) ->
    let param_str = match params with
      | [] -> ""
      | [p] -> "'" ^ p ^ " "
      | _ -> "(" ^ String.concat ", " (List.map (fun p -> "'" ^ p) params) ^ ") "
    in
    Printf.printf "type alias %s%s = %s\n" param_str name (Ast.pp_ty body);
    []
  | Ast.Top_view (name, region, fields) ->
    Typer.register_view name region fields;
    Printf.printf "view %s[%s] defined (%d fields)\n"
      name region (List.length fields);
    []
  | Ast.Top_drop name ->
    Typer.register_drop_type name;
    Printf.printf "drop type %s registered\n" name;
    []

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
  let added = List.concat_map (process_decl eval_env type_env) prog.decls in
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
