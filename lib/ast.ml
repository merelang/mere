(* Abstract syntax tree for Lang. *)

type ty =
  | TyInt
  | TyBool
  | TyArrow of ty * ty

type expr = { loc : Loc.t; node : expr_node }

and expr_node =
  | Int_lit of int
  | Bool_lit of bool
  | Var of string
  | Bin of binop * expr * expr
  | Cmp of cmpop * expr * expr
  | Neg of expr
  | Let of string * expr * expr
  | Let_rec of string * expr * expr
  | If of expr * expr * expr
  | Fun of string * expr
  | App of expr * expr
  | Annot of expr * ty

and binop = Add | Sub | Mul
and cmpop = Eq | Lt

(* Top-level declarations.
   A program is a sequence of declarations followed by a main expression. *)
type top_decl =
  | Top_let of string * expr
  | Top_let_rec of string * expr

type program = {
  decls : top_decl list;
  main : expr;
}

let binop_to_string = function Add -> "+" | Sub -> "-" | Mul -> "*"
let cmpop_to_string = function Eq -> "==" | Lt -> "<"

let rec pp_ty = function
  | TyInt -> "int"
  | TyBool -> "bool"
  | TyArrow (a, b) -> "(" ^ pp_ty a ^ " -> " ^ pp_ty b ^ ")"

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
  | Let_rec (name, value, body) ->
    "(let rec " ^ name ^ " = " ^ pp value ^ " in " ^ pp body ^ ")"
  | If (cond, then_, else_) ->
    "(if " ^ pp cond ^ " then " ^ pp then_ ^ " else " ^ pp else_ ^ ")"
  | Fun (param, body) ->
    "(fn " ^ param ^ " -> " ^ pp body ^ ")"
  | App (f, arg) ->
    "(" ^ pp f ^ " " ^ pp arg ^ ")"
  | Annot (inner, t) ->
    "(" ^ pp inner ^ " : " ^ pp_ty t ^ ")"

(* Desugar a program into a single expression by wrapping top decls
   as let/let-rec around the main expression. *)
let desugar_program (prog : program) : expr =
  List.fold_right (fun decl body ->
    let loc = body.loc in
    match decl with
    | Top_let (name, value) ->
      { loc; node = Let (name, value, body) }
    | Top_let_rec (name, value) ->
      { loc; node = Let_rec (name, value, body) }
  ) prog.decls prog.main
