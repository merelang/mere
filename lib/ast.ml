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
  | TyCon of string
  | TyTuple of ty list      (* length >= 2 *)

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
  | Constr of string * expr option
  | Match of expr * (pattern * expr) list
  | Tuple of expr list      (* length >= 2 *)

and binop = Add | Sub | Mul | Concat
and cmpop = Eq | Lt

and pattern = { ploc : Loc.t; pnode : pattern_node }
and pattern_node =
  | P_wild
  | P_var of string
  | P_int of int
  | P_bool of bool
  | P_str of string
  | P_unit
  | P_constr of string * pattern option
  | P_tuple of pattern list   (* length >= 2 *)

type top_decl =
  | Top_let of string * expr
  | Top_let_rec of string * expr
  | Top_type of string * (string * ty option) list

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
    | TyCon name -> name
    | TyTuple ts ->
      let parts = List.map aux ts in
      "(" ^ String.concat " * " parts ^ ")"
  in
  aux t

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

let rec pp_pattern p =
  match p.pnode with
  | P_wild -> "_"
  | P_var n -> n
  | P_int n -> string_of_int n
  | P_bool b -> if b then "true" else "false"
  | P_str s -> escape_string s
  | P_unit -> "()"
  | P_constr (c, None) -> c
  | P_constr (c, Some sub) -> c ^ " " ^ pp_pattern sub
  | P_tuple ps ->
    "(" ^ String.concat ", " (List.map pp_pattern ps) ^ ")"

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
  | Constr (c, None) -> c
  | Constr (c, Some arg) -> "(" ^ c ^ " " ^ pp arg ^ ")"
  | Match (scrut, arms) ->
    let arms_s =
      arms
      |> List.map (fun (p, body) -> "| " ^ pp_pattern p ^ " -> " ^ pp body)
      |> String.concat " "
    in
    "(match " ^ pp scrut ^ " with " ^ arms_s ^ ")"
  | Tuple es ->
    "(" ^ String.concat ", " (List.map pp es) ^ ")"

let desugar_program (prog : program) : expr =
  List.fold_right (fun decl body ->
    let loc = body.loc in
    match decl with
    | Top_let (name, value) ->
      { loc; node = Let (name, value, body) }
    | Top_let_rec (name, value) ->
      { loc; node = Let_rec (name, value, body) }
    | Top_type _ -> body
  ) prog.decls prog.main
