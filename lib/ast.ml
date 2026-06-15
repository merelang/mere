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
  | TyParam of string             (* source-level type parameter, e.g. 'a *)
  | TyCon of string * ty list     (* name + type args (postfix application) *)
  | TyTuple of ty list

type expr = { loc : Loc.t; node : expr_node }

and expr_node =
  | Int_lit of int
  | Bool_lit of bool
  | Str_lit of string
  | Unit_lit
  | Var of string
  | Bin of binop * expr * expr
  | Cmp of cmpop * expr * expr
  | Logic of logicop * expr * expr     (* && / ||、short-circuit eval *)
  | Neg of expr
  | Let of pattern * expr * expr   (* left side is a pattern — supports `let (a, b) = ...` etc. *)
  | Let_rec of (string * expr) list * expr   (* list >= 1; multi for `let rec X = e1 and Y = e2 in body` *)
  | With of string * expr * expr
  | If of expr * expr * expr
  | Fun of string * ty option * expr   (* fn x -> body  or  fn (x : t) -> body *)
  | App of expr * expr
  | Annot of expr * ty
  | Constr of string * expr option
  | Match of expr * (pattern * expr option * expr) list
    (* arm: pattern * optional guard * body.  guard is bool expr — if false,
       fall through to next arm. *)
  | Tuple of expr list
  | Record_lit of string * (string * expr) list
    (* nominal record literal:  TypeName { f1 = e1, f2 = e2 } *)
  | Field_get of expr * string
    (* p.field *)
  | Record_update of expr * (string * expr) list
    (* { base | f1 = e1, f2 = e2 }: new record with selected fields updated *)

and binop = Add | Sub | Mul | Div | Mod | Concat
and cmpop = Eq | Ne | Lt | Le | Gt | Ge
and logicop = And | Or

and pattern = { ploc : Loc.t; pnode : pattern_node }
and pattern_node =
  | P_wild
  | P_var of string
  | P_int of int
  | P_bool of bool
  | P_str of string
  | P_unit
  | P_constr of string * pattern option
  | P_tuple of pattern list
  | P_record of string * (string * pattern) list
    (* nominal record pattern:  TypeName { f1 = pat, f2 = pat } *)

type top_decl =
  | Top_let of pattern * expr   (* left-side can be P_var (typical) or P_wild/P_tuple etc. *)
  | Top_let_rec of (string * expr) list   (* multi for `let rec X = e1 and Y = e2 ;` *)
  | Top_type of string * string list * (string * ty option) list
    (* type name * type params (param names) * variants *)
  | Top_signature of string * (string * ty) list
    (* signature name * param list (all type-annotated) *)
  | Top_record of string * string list * (string * ty) list
    (* record type name * type params * field list (name, type) *)
  | Top_type_alias of string * string list * ty
    (* alias name * type params * aliased type — parse-time substitution *)

type program = {
  decls : top_decl list;
  main : expr;
}

let binop_to_string = function
  | Add -> "+" | Sub -> "-" | Mul -> "*" | Div -> "/" | Mod -> "%" | Concat -> "++"

let cmpop_to_string = function
  | Eq -> "==" | Ne -> "!=" | Lt -> "<" | Le -> "<=" | Gt -> ">" | Ge -> ">="

let logicop_to_string = function And -> "&&" | Or -> "||"

let rec walk = function
  | TyVar { link = Some t; _ } -> walk t
  | t -> t

let pp_ty t =
  let counter = ref 0 in
  let names = Hashtbl.create 4 in
  let name_of_var id =
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
    | TyVar v -> name_of_var v.id
    | TyParam p -> "'" ^ p
    | TyCon (name, []) -> name
    | TyCon (name, [a]) -> aux a ^ " " ^ name
    | TyCon (name, args) ->
      "(" ^ String.concat ", " (List.map aux args) ^ ") " ^ name
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
  | P_record (name, fields) ->
    let parts = List.map (fun (f, p) -> f ^ " = " ^ pp_pattern p) fields in
    name ^ " { " ^ String.concat ", " parts ^ " }"

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
  | Logic (op, a, b) ->
    "(" ^ pp a ^ " " ^ logicop_to_string op ^ " " ^ pp b ^ ")"
  | Let (pat, value, body) ->
    "(let " ^ pp_pattern pat ^ " = " ^ pp value ^ " in " ^ pp body ^ ")"
  | Let_rec (bindings, body) ->
    let parts = List.map (fun (n, v) -> n ^ " = " ^ pp v) bindings in
    "(let rec " ^ String.concat " and " parts ^ " in " ^ pp body ^ ")"
  | With (name, value, body) ->
    "(with " ^ name ^ " = " ^ pp value ^ " in " ^ pp body ^ ")"
  | If (cond, then_, else_) ->
    "(if " ^ pp cond ^ " then " ^ pp then_ ^ " else " ^ pp else_ ^ ")"
  | Fun (param, None, body) ->
    "(fn " ^ param ^ " -> " ^ pp body ^ ")"
  | Fun (param, Some t, body) ->
    "(fn (" ^ param ^ " : " ^ pp_ty t ^ ") -> " ^ pp body ^ ")"
  | App (f, arg) ->
    "(" ^ pp f ^ " " ^ pp arg ^ ")"
  | Annot (inner, t) ->
    "(" ^ pp inner ^ " : " ^ pp_ty t ^ ")"
  | Constr (c, None) -> c
  | Constr (c, Some arg) -> "(" ^ c ^ " " ^ pp arg ^ ")"
  | Match (scrut, arms) ->
    let arms_s =
      arms
      |> List.map (fun (p, guard, body) ->
        let g_s = match guard with
          | None -> ""
          | Some g -> " when " ^ pp g
        in
        "| " ^ pp_pattern p ^ g_s ^ " -> " ^ pp body)
      |> String.concat " "
    in
    "(match " ^ pp scrut ^ " with " ^ arms_s ^ ")"
  | Tuple es ->
    "(" ^ String.concat ", " (List.map pp es) ^ ")"
  | Record_lit (name, fields) ->
    let parts = List.map (fun (f, e) -> f ^ " = " ^ pp e) fields in
    name ^ " { " ^ String.concat ", " parts ^ " }"
  | Field_get (e, f) ->
    pp e ^ "." ^ f
  | Record_update (base, updates) ->
    let parts = List.map (fun (f, e) -> f ^ " = " ^ pp e) updates in
    "{ " ^ pp base ^ " | " ^ String.concat ", " parts ^ " }"

let desugar_program (prog : program) : expr =
  List.fold_right (fun decl body ->
    let loc = body.loc in
    match decl with
    | Top_let (pat, value) ->
      { loc; node = Let (pat, value, body) }
    | Top_let_rec bindings ->
      { loc; node = Let_rec (bindings, body) }
    | Top_type _ -> body
    | Top_signature _ -> body
    | Top_record _ -> body
    | Top_type_alias _ -> body
  ) prog.decls prog.main
