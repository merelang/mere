(* Abstract syntax tree for Lang. *)

type expr = { loc : Loc.t; node : expr_node }

and expr_node =
  | Int_lit of int
  | Var of string
  | Bin of binop * expr * expr
  | Neg of expr
  | Let of string * expr * expr  (* let name = value in body *)

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
  | Var name -> name
  | Neg a -> "-" ^ pp a
  | Bin (op, a, b) ->
    "(" ^ pp a ^ " " ^ binop_to_string op ^ " " ^ pp b ^ ")"
  | Let (name, value, body) ->
    "(let " ^ name ^ " = " ^ pp value ^ " in " ^ pp body ^ ")"
