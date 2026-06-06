(* Tree-walking interpreter. *)

exception Eval_error of Loc.t * string

type value =
  | V_int of int

type env = (string * value) list

let to_string = function
  | V_int n -> string_of_int n

let eval expr =
  let rec aux (env : env) e =
    match e.Ast.node with
    | Ast.Int_lit n -> V_int n
    | Ast.Var name ->
      (try List.assoc name env
       with Not_found ->
         raise (Eval_error (e.Ast.loc, "unbound variable: " ^ name)))
    | Ast.Neg a ->
      (match aux env a with
       | V_int x -> V_int (- x))
    | Ast.Bin (op, a, b) ->
      (match aux env a, aux env b with
       | V_int x, V_int y ->
         (match op with
          | Ast.Add -> V_int (x + y)
          | Ast.Sub -> V_int (x - y)
          | Ast.Mul -> V_int (x * y)))
    | Ast.Let (name, value, body) ->
      let v = aux env value in
      aux ((name, v) :: env) body
  in
  aux [] expr
