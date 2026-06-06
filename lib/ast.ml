(* Abstract syntax tree for Lang. *)

type expr = { loc : Loc.t; node : expr_node }

and expr_node =
  | Int_lit of int
  | Bin of binop * expr * expr
  | Neg of expr

and binop =
  | Add
  | Sub
  | Mul

let binop_to_string = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"

let rec pp e =
  match e.node with
  | Int_lit n -> string_of_int n
  | Neg a -> "-" ^ pp a
  | Bin (op, a, b) ->
    "(" ^ pp a ^ " " ^ binop_to_string op ^ " " ^ pp b ^ ")"
