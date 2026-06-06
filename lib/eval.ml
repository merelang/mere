(* Tree-walking interpreter. *)

exception Eval_error of Loc.t * string

type value =
  | V_int of int
  | V_bool of bool
  | V_str of string
  | V_unit
  | V_closure of string * Ast.expr * env
  | V_builtin of string * (value -> value)

and env = (string * value ref) list

let to_string = function
  | V_int n -> string_of_int n
  | V_bool b -> if b then "true" else "false"
  | V_str s -> Ast.escape_string s
  | V_unit -> "()"
  | V_closure (param, _, _) -> "<closure:" ^ param ^ ">"
  | V_builtin (name, _) -> "<builtin:" ^ name ^ ">"

let type_error loc msg = raise (Eval_error (loc, msg))

(* Built-ins pre-bound in the initial env. *)
let builtin_print =
  V_builtin ("print", fun v ->
    (match v with
     | V_str s -> print_endline s
     | _ -> failwith "print: expected str (type check should have caught this)");
    V_unit)

let initial_env : env =
  [ ("print", ref builtin_print) ]

let rec eval_in (env : env) (e : Ast.expr) =
  match e.Ast.node with
  | Ast.Int_lit n -> V_int n
  | Ast.Bool_lit b -> V_bool b
  | Ast.Str_lit s -> V_str s
  | Ast.Unit_lit -> V_unit
  | Ast.Var name ->
    (try !(List.assoc name env)
     with Not_found ->
       type_error e.Ast.loc ("unbound variable: " ^ name))
  | Ast.Neg a ->
    (match eval_in env a with
     | V_int x -> V_int (- x)
     | _ -> type_error e.Ast.loc "unary - requires int")
  | Ast.Bin (op, a, b) ->
    let va = eval_in env a in
    let vb = eval_in env b in
    (match op, va, vb with
     | Ast.Add, V_int x, V_int y -> V_int (x + y)
     | Ast.Sub, V_int x, V_int y -> V_int (x - y)
     | Ast.Mul, V_int x, V_int y -> V_int (x * y)
     | Ast.Concat, V_str x, V_str y -> V_str (x ^ y)
     | (Ast.Add | Ast.Sub | Ast.Mul), _, _ ->
       type_error e.Ast.loc "arithmetic requires int operands"
     | Ast.Concat, _, _ ->
       type_error e.Ast.loc "++ requires str operands")
  | Ast.Cmp (op, a, b) ->
    (match eval_in env a, eval_in env b with
     | V_int x, V_int y ->
       (match op with
        | Ast.Eq -> V_bool (x = y)
        | Ast.Lt -> V_bool (x < y))
     | V_bool x, V_bool y when op = Ast.Eq ->
       V_bool (x = y)
     | V_str x, V_str y when op = Ast.Eq ->
       V_bool (x = y)
     | _ -> type_error e.Ast.loc "comparison type mismatch")
  | Ast.Let (name, value, body) ->
    let v = eval_in env value in
    eval_in ((name, ref v) :: env) body
  | Ast.Let_rec (name, value, body) ->
    let placeholder = ref V_unit in
    let env' = (name, placeholder) :: env in
    let v = eval_in env' value in
    placeholder := v;
    eval_in env' body
  | Ast.If (cond, then_, else_) ->
    (match eval_in env cond with
     | V_bool true -> eval_in env then_
     | V_bool false -> eval_in env else_
     | _ -> type_error e.Ast.loc "if condition must be bool")
  | Ast.Fun (param, body) ->
    V_closure (param, body, env)
  | Ast.App (f, arg) ->
    (match eval_in env f with
     | V_closure (param, body, captured) ->
       let v = eval_in env arg in
       eval_in ((param, ref v) :: captured) body
     | V_builtin (_, fn) ->
       let v = eval_in env arg in
       fn v
     | _ -> type_error e.Ast.loc "applying non-function")
  | Ast.Annot (inner, _) -> eval_in env inner

let eval expr = eval_in initial_env expr
