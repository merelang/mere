(* Abstract syntax tree for Lang. *)

type expr = { loc : Loc.t; node : expr_node }

and expr_node =
  | Int_lit of int
  | Bool_lit of bool
  | Var of string
  | Bin of binop * expr * expr        (* arithmetic *)
  | Cmp of cmpop * expr * expr        (* comparison, returns bool *)
  | Neg of expr
  | Let of string * expr * expr
  | If of expr * expr * expr          (* if cond then e1 else e2 *)

and binop =
  | Add
  | Sub
  | Mul

and cmpop =
  | Eq
  | Lt

let binop_to_string = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"

let cmpop_to_string = function
  | Eq -> "=="
  | Lt -> "<"

let rec pp e =
  match e.node with
  | Int_lit n -> string_of_int n
  | Bool_lit b -> if b then "true" else "false"
  | Var name -> name
  | Neg a -> "-" ^ pp a
  | Bin (op, a, b) ->
    "(" ^ pp a ^ " " ^ binop_to_string op ^ " " ^ pp b ^ ")"
  | Cmp (op, a, b) ->
    "(" ^ pp a ^ " " ^ cmpop_to_string op ^ " " ^ pp b ^ ")"
  | Let (name, value, body) ->
    "(let " ^ name ^ " = " ^ pp value ^ " in " ^ pp body ^ ")"
  | If (cond, then_, else_) ->
    "(if " ^ pp cond ^ " then " ^ pp then_ ^ " else " ^ pp else_ ^ ")"
