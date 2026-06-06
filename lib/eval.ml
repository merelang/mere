(* Tree-walking interpreter. *)

exception Eval_error of Loc.t * string

type value =
  | V_int of int
  | V_bool of bool
  | V_closure of string * Ast.expr * env

and env = (string * value) list

let to_string = function
  | V_int n -> string_of_int n
  | V_bool b -> if b then "true" else "false"
  | V_closure (param, _, _) -> "<closure:" ^ param ^ ">"

let type_error loc msg = raise (Eval_error (loc, msg))

let eval expr =
  let rec aux (env : env) e =
    match e.Ast.node with
    | Ast.Int_lit n -> V_int n
    | Ast.Bool_lit b -> V_bool b
    | Ast.Var name ->
      (try List.assoc name env
       with Not_found ->
         type_error e.Ast.loc ("unbound variable: " ^ name))
    | Ast.Neg a ->
      (match aux env a with
       | V_int x -> V_int (- x)
       | _ -> type_error e.Ast.loc "unary - requires int")
    | Ast.Bin (op, a, b) ->
      (match aux env a, aux env b with
       | V_int x, V_int y ->
         (match op with
          | Ast.Add -> V_int (x + y)
          | Ast.Sub -> V_int (x - y)
          | Ast.Mul -> V_int (x * y))
       | _ -> type_error e.Ast.loc "arithmetic requires int operands")
    | Ast.Cmp (op, a, b) ->
      (match aux env a, aux env b with
       | V_int x, V_int y ->
         (match op with
          | Ast.Eq -> V_bool (x = y)
          | Ast.Lt -> V_bool (x < y))
       | V_bool x, V_bool y when op = Ast.Eq ->
         V_bool (x = y)
       | _ -> type_error e.Ast.loc "comparison type mismatch")
    | Ast.Let (name, value, body) ->
      let v = aux env value in
      aux ((name, v) :: env) body
    | Ast.If (cond, then_, else_) ->
      (match aux env cond with
       | V_bool true -> aux env then_
       | V_bool false -> aux env else_
       | _ -> type_error e.Ast.loc "if condition must be bool")
    | Ast.Fun (param, body) ->
      V_closure (param, body, env)
    | Ast.App (f, arg) ->
      (match aux env f with
       | V_closure (param, body, captured) ->
         let v = aux env arg in
         aux ((param, v) :: captured) body
       | _ -> type_error e.Ast.loc "applying non-function")
    | Ast.Annot (inner, _) -> aux env inner
  in
  aux [] expr
