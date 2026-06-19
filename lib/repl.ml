(* Interactive Read-Eval-Print Loop.

   Maintains a persistent eval-env and type-env across inputs. Each input
   can be either a top-level program fragment (decls + main expr) or an
   expression alone.

   Multi-line input: when a line ends with the parser hitting EOF while
   still expecting more, the REPL accumulates input across additional
   lines (continuation prompt `..>`) until the parser succeeds or the
   user clears it with a blank line.

   Errors use Diagnostic.format so the REPL shares the same Rust-style
   code frame as the file-mode CLI.

   Commands:
     :quit | :q       exit REPL
     :type EXPR       print the inferred type of EXPR
     :env             list current bindings with their types
     :load FILE       load decls from FILE into the REPL env
     :help | :h       show help
*)

let help_text =
  "Commands:\n\
  \  :quit | :q       exit\n\
  \  :type EXPR       show inferred type of EXPR\n\
  \  :env             list current bindings with their types\n\
  \  :load FILE       load decls from FILE into the REPL env\n\
  \  :help | :h       this help\n\
   Multi-line: if input is incomplete, you'll get a `..>` continuation\n\
   prompt. Press Enter on a blank `..>` line to abort the buffer.\n\
   Otherwise: enter a Lang program. Top-level decls use `let NAME = EXPR;`\n\
   followed by a main expression (or `let NAME = EXPR;` alone to just bind)."

(* Format an error from any of the pipeline stages using the same
   Diagnostic code frame as the file-mode CLI. `source` is the entire
   accumulated input, so the caret + context align with what the user
   actually typed. *)
let format_diag ~source = function
  | Lexer.Lex_error (loc, msg) ->
    Diagnostic.format ~source ~filename:"<repl>" loc "lex error" msg
  | Parser.Parse_error (loc, msg) ->
    Diagnostic.format ~source ~filename:"<repl>" loc "parse error" msg
  | Typer.Type_error (loc, msg) ->
    Diagnostic.format ~source ~filename:"<repl>" loc "type error" msg
  | Eval.Eval_error (loc, msg) ->
    Diagnostic.format ~source ~filename:"<repl>" loc "eval error" msg
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

(* Position of the synthetic T_eof token in a tokenised input — used to
   tell "the parser failed at the very end of the input" (= unfinished)
   from "the parser failed mid-input" (= genuine error). *)
let eof_loc tokens =
  match List.rev tokens with
  | (loc, Lexer.T_eof) :: _ -> Some loc
  | _ -> None

let loc_eq (a : Loc.t) (b : Loc.t) = a.line = b.line && a.col = b.col

(* Heuristic for "input is unfinished, ask for more". `source` is what
   the user has typed so far; we re-tokenise it and check whether the
   error position matches T_eof. The lexer's mid-string-literal failure
   is also treated as unfinished so multi-line `"..."` could in theory
   continue (but the lexer currently rejects newlines in literals — we
   still keep the case here as a hook for future). *)
let is_unfinished ~source = function
  | Parser.Parse_error (loc, _) ->
    (match eof_loc (try Lexer.tokenize source with _ -> []) with
     | Some eofl -> loc_eq loc eofl
     | None -> false)
  | Lexer.Lex_error (_, msg) ->
    msg = "unterminated string literal"
  | _ -> false

(* List current bindings (name + generalised type) skipping the initial
   builtin env. Returns user-added bindings in entry order. *)
let user_bindings type_env =
  let initial_names =
    List.fold_left (fun acc (n, _) -> n :: acc) [] Typer.initial_env
  in
  let seen = Hashtbl.create 16 in
  List.iter (fun n -> Hashtbl.replace seen n ()) initial_names;
  let added = List.filter (fun (n, _) -> not (Hashtbl.mem seen n)) type_env in
  (* Most recent bindings come first in the env; reverse for entry order. *)
  List.rev added

let print_env type_env =
  let bs = user_bindings type_env in
  if bs = [] then print_endline "(no user bindings)"
  else List.iter (fun (n, sch) ->
    Printf.printf "val %s : %s\n" n (Ast.pp_ty sch.Typer.body)
  ) bs

let handle_load eval_env type_env path =
  let source =
    try In_channel.with_open_text path In_channel.input_all
    with Sys_error msg -> raise (Sys_error msg)
  in
  let tokens = Lexer.tokenize source in
  let prog = Parser.parse_program tokens in
  let added = List.concat_map (process_decl eval_env type_env) prog.decls in
  List.iter (fun (name, sch) ->
    Printf.printf "val %s : %s\n" name (Ast.pp_ty sch.Typer.body)
  ) added;
  Printf.printf "(loaded %s)\n" path

(* Read one logical input from stdin: keep appending lines while the
   parser reports "unfinished". A blank continuation line aborts the
   buffer (returns None so the outer loop can re-prompt fresh). *)
let read_logical_input () =
  let rec loop buf first =
    print_string (if first then "> " else "..> ");
    match read_line () with
    | exception End_of_file ->
      if first then None
      else Some (Buffer.contents buf)
    | line ->
      let line_trim = String.trim line in
      if (not first) && line_trim = "" then begin
        print_endline "(input aborted)";
        None
      end
      else if (not first) && starts_with ":" line_trim then begin
        (* Commands break out of the multi-line buffer rather than
           getting appended to it; the user is signaling intent to
           cancel the pending input. *)
        print_endline "(input aborted)";
        Some line_trim
      end
      else begin
        if not first then Buffer.add_char buf '\n';
        Buffer.add_string buf line;
        let so_far = Buffer.contents buf in
        let trimmed = String.trim so_far in
        if first && trimmed = "" then None
        else
          (* Probe: only commands and colon-prefixed inputs short-circuit;
             everything else is fed to the lexer/parser to decide. *)
          if first && starts_with ":" trimmed then Some trimmed
          else begin
            match
              let prepared = prepare_input so_far in
              let toks = Lexer.tokenize prepared in
              ignore (Parser.parse_program toks);
              `Done
            with
            | `Done -> Some so_far
            | exception e when is_unfinished ~source:(prepare_input so_far) e ->
              loop buf false
            | exception _ -> Some so_far  (* genuine error; let caller report *)
          end
      end
  in
  loop (Buffer.create 64) true

let run () =
  print_endline "lang-ml REPL. Type :help for commands, :quit to exit.";
  let eval_env = ref Eval.initial_env in
  let type_env = ref Typer.initial_env in
  let rec loop () =
    match read_logical_input () with
    | None when not (Unix.isatty Unix.stdin) -> ()  (* piped EOF *)
    | None -> print_newline ()
    | Some input ->
      let trimmed = String.trim input in
      if trimmed = "" then loop ()
      else if trimmed = ":quit" || trimmed = ":q" then ()
      else if trimmed = ":help" || trimmed = ":h" then begin
        print_endline help_text;
        loop ()
      end
      else if trimmed = ":env" then begin
        print_env !type_env;
        loop ()
      end
      else if starts_with ":type " trimmed then begin
        let expr_text = String.sub trimmed 6 (String.length trimmed - 6) in
        (try handle_type eval_env type_env expr_text
         with e -> print_endline (format_diag ~source:expr_text e));
        loop ()
      end
      else if starts_with ":load " trimmed then begin
        let path = String.trim (String.sub trimmed 6 (String.length trimmed - 6)) in
        (try handle_load eval_env type_env path
         with
         | Sys_error msg -> Printf.printf "io error: %s\n" msg
         | e ->
           let source = try In_channel.with_open_text path In_channel.input_all
                        with _ -> "" in
           print_endline (format_diag ~source e));
        loop ()
      end
      else if starts_with ":" trimmed then begin
        Printf.printf "unknown command: %s (try :help)\n" trimmed;
        loop ()
      end
      else begin
        (try handle_input eval_env type_env input
         with e -> print_endline (format_diag ~source:input e));
        loop ()
      end
  in
  loop ()
