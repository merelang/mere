(* Tree-walking interpreter. *)

exception Eval_error of Loc.t * string

type value =
  | V_int of int

let to_string = function
  | V_int n -> string_of_int n

let rec eval e =
  match e.Ast.node with
  | Ast.Int_lit n -> V_int n
  | Ast.Neg a ->
    (match eval a with
     | V_int x -> V_int (- x))
  | Ast.Bin (op, a, b) ->
    (match eval a, eval b with
     | V_int x, V_int y ->
       (match op with
        | Ast.Add -> V_int (x + y)
        | Ast.Sub -> V_int (x - y)
        | Ast.Mul -> V_int (x * y)))
