(* Abstract syntax tree for Lang. *)

type tyvar = {
  id : int;
  mutable link : ty option;
}

and ty =
  | TyInt
  | TyBool
  | TyStr
  | TyUnit
  | TyArrow of ty * ty
  | TyVar of tyvar

type expr = { loc : Loc.t; node : expr_node }

and expr_node =
  | Int_lit of int
  | Bool_lit of bool
  | Str_lit of string
  | Unit_lit
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

and binop = Add | Sub | Mul | Concat
and cmpop = Eq | Lt

type top_decl =
  | Top_let of string * expr
  | Top_let_rec of string * expr

type program = {
  decls : top_decl list;
  main : expr;
}

let binop_to_string = function
  | Add -> "+" | Sub -> "-" | Mul -> "*" | Concat -> "++"

let cmpop_to_string = function Eq -> "==" | Lt -> "<"

let rec walk = function
  | TyVar { link = Some t; _ } -> walk t
  | t -> t

let pp_ty t =
  let counter = ref 0 in
  let names = Hashtbl.create 4 in
  let name_of id =
    match Hashtbl.find_opt names id with
    | Some n -> n
    | None ->
      let n = !counter in
      incr counter;
      let s =
        if n < 26 then Printf.sprintf "'%c" (Char.chr (Char.code 'a' + n))
        else Printf.sprintf "'t%d" n
      in
      Hashtbl.add names id s;
      s
  in
  let rec aux t =
    match walk t with
    | TyInt -> "int"
    | TyBool -> "bool"
    | TyStr -> "str"
    | TyUnit -> "unit"
    | TyArrow (a, b) ->
      let sa = aux a in
      let sb = aux b in
      "(" ^ sa ^ " -> " ^ sb ^ ")"
    | TyVar v -> name_of v.id
  in
  aux t

(* Escape a string for display in pp (showing quotes and escapes). *)
let escape_string s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\t' -> Buffer.add_string buf "\\t"
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.add_char buf '"';
  Buffer.contents buf

let rec pp e =
  match e.node with
  | Int_lit n -> string_of_int n
  | Bool_lit b -> if b then "true" else "false"
  | Str_lit s -> escape_string s
  | Unit_lit -> "()"
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

let desugar_program (prog : program) : expr =
  List.fold_right (fun decl body ->
    let loc = body.loc in
    match decl with
    | Top_let (name, value) ->
      { loc; node = Let (name, value, body) }
    | Top_let_rec (name, value) ->
      { loc; node = Let_rec (name, value, body) }
  ) prog.decls prog.main
