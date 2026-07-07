(* Abstract syntax tree for Lang. *)

type tyvar = {
  id : int;
  mutable link : ty option;
}

and ty =
  | TyInt
  | TyFloat
  | TyBool
  | TyStr
  | TyUnit
  | TyArrow of ty * ty
  | TyVar of tyvar
  | TyParam of string             (* source-level type parameter, e.g. 'a *)
  | TyCon of string * ty list     (* name + type args (postfix application) *)
  | TyTuple of ty list
  | TyRef of borrow_mode * string * ty (* `&[m] R T` — region-tagged ref *)

and borrow_mode =
  | BorrowedRead    (* default; shared, read-only — written `&R T` *)
  | SharedWrite     (* `&shared write R T` — shared, write OK (cap-internal lock) *)
  | ExclusiveRead   (* `&exclusive R T` — exclusive, read-only (rare) *)
  | ExclusiveWrite  (* `&mut R T` — exclusive, write OK (equivalent to Rust's `&mut`) *)

type expr = {
  loc : Loc.t;
  mutable ty : ty option;
  (* Set by Typer.infer to the node's inferred type. Codegen reads this
     to know e.g. the element types of a Tuple literal, or the param /
     return types of a Fun. None means the typer hasn't visited this
     node (or the program failed earlier). *)
  node : expr_node;
}

and expr_node =
  | Int_lit of int
  | Float_lit of float
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
  | Region_block of string * expr   (* `region R { body }` — introduces region name R *)
  | Ref of borrow_mode * string * expr (* `&[m] R e` — value-level ref, mode m *)
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
  | P_as of pattern * string
    (* `pat as name` — match the inner pattern and bind the whole value to `name`. *)
  | P_or of pattern * pattern
    (* `pat1 | pat2` — match either pattern (only valid in match arms).
       Both branches must bind the same set of names with compatible types. *)

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
  | Top_view of string * string * (string * ty) list
    (* view name * region param * fields (can reference the region via &R T) *)
  | Top_extern of string * ty
    (* Phase 32 (C1 FFI): `extern fn <name>: <ty>;` declares an external C function.
       The MVP only supports arrow types built from int / bool / str / unit.
       interp provides hardcoded mocks via extern_mocks in eval.ml, and
       codegen emits a forward decl / declare / import in each of the 3 backends. *)
  | Top_extern_type of string
    (* Phase 48.1 (C2 frontend FFI): `extern type <Name>;` declares an opaque
       handle type. At codegen time it lowers to a host-side handle (i32 in
       Wasm, void* in C, ptr in LLVM). On the typer side it's a distinct
       0-arity TyCon that won't unify with `int` etc., so user code can't
       fabricate a handle from a plain integer. The only producers are
       `extern fn` declarations whose result type names the opaque type. *)
  | Top_drop of string
    (* Marks an existing type/record name as having Drop semantics.
       Emitted by the parser when it sees `drop type ...` or `drop type =
       { ... }` form. The typer uses this to enforce the Trivial[R]
       constraint on region-tagged values. *)
  | Top_sync of string
    (* Q-012: marks a type as Sync (shareable across threads — it carries
       an internal lock, e.g. `sync type SharedLogger = ...`). Send + Sync.
       Emitted by the parser for the `sync type Name = ...` form, same
       look-ahead trick as `drop type`. *)
  | Top_local of string
    (* Q-012: marks a type as thread-local / !Send (a single-owner handle
       over a raw resource such as a fd, e.g. `local type TcpConn = ...`).
       Cannot cross a thread boundary by move or share. *)
  | Top_ctor_alias of string * string
    (* Phase 18.1 / DEFERRED §4.1 remaining: typer-side aliasing of constructor
       names. Emitted by parser's `prefix_module_decls` for each ctor in
       a module: `Top_ctor_alias ("M.Red", "Red")` registers `M.Red` as
       another name pointing to the same variant info as `Red`. Allows
       qualified access `M.Red` while keeping unqualified `Red` working
       (backward compat). *)
  | Top_record_alias of string * string
    (* Same as Top_ctor_alias but for records. `Top_record_alias
       ("M.Pt", "Pt")` registers `M.Pt` as alias for `Pt`. *)

type program = {
  decls : top_decl list;
  main : expr;
}

(* Phase 18.1 / DEFERRED §4.1 remaining: Global alias maps for ctor / record
   names. Populated by Pipeline / Typer.alias_ctor / Typer.alias_record
   via Top_ctor_alias / Top_record_alias decls.

   Read by eval (to canonicalize V_constr / Record_lit names at
   construction time, so pattern matches work regardless of whether
   the user wrote the bare or qualified name) and by codegen
   (similar canonicalization for emitted ctor tags). *)
let ctor_aliases : (string, string) Hashtbl.t = Hashtbl.create 8
let record_aliases : (string, string) Hashtbl.t = Hashtbl.create 8

let canonical_ctor name =
  match Hashtbl.find_opt ctor_aliases name with
  | Some canonical -> canonical
  | None -> name

let canonical_record name =
  match Hashtbl.find_opt record_aliases name with
  | Some canonical -> canonical
  | None -> name

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
    | TyFloat -> "float"
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
    (* Heuristic: a TyCon whose sole arg is a region-tagged unit is a view
       value (typer encodes the construction-time region this way). Print
       as `Name[R]` instead of the literal `&R () Name`. *)
    | TyCon (name, [TyRef (_, r, TyUnit)]) -> name ^ "[" ^ r ^ "]"
    (* `Vec[R, T]` and similar — first arg is a region marker
       (TyRef-of-unit) or a polymorphic region var; print in bracket
       form to match user-facing syntax. *)
    | TyCon (name, [TyRef (_, r, TyUnit); t]) ->
      name ^ "[" ^ r ^ ", " ^ aux t ^ "]"
    | TyCon (name, [TyRef (_, r, TyUnit); k; v]) ->
      name ^ "[" ^ r ^ ", " ^ aux k ^ ", " ^ aux v ^ "]"
    | TyCon (name, [region_tv; t]) when name = "Vec" ->
      name ^ "[" ^ aux region_tv ^ ", " ^ aux t ^ "]"
    | TyCon (name, [region_tv]) when name = "StrBuf" ->
      name ^ "[" ^ aux region_tv ^ "]"
    | TyCon (name, [region_tv; k; v]) when name = "Map" ->
      name ^ "[" ^ aux region_tv ^ ", " ^ aux k ^ ", " ^ aux v ^ "]"
    | TyCon (name, [a]) -> aux a ^ " " ^ name
    | TyCon (name, args) ->
      "(" ^ String.concat ", " (List.map aux args) ^ ") " ^ name
    | TyTuple ts ->
      let parts = List.map aux ts in
      "(" ^ String.concat " * " parts ^ ")"
    | TyRef (mode, region, inner) ->
      let prefix = match mode with
        | BorrowedRead -> "&"
        | SharedWrite -> "&shared write "
        | ExclusiveRead -> "&exclusive "
        | ExclusiveWrite -> "&mut "
      in
      prefix ^ region ^ " " ^ aux inner
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
  | P_as (inner, name) ->
    "(" ^ pp_pattern inner ^ " as " ^ name ^ ")"
  | P_or (p1, p2) ->
    "(" ^ pp_pattern p1 ^ " | " ^ pp_pattern p2 ^ ")"

let rec pp e =
  match e.node with
  | Int_lit n -> string_of_int n
  | Float_lit f -> string_of_float f
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
  | Region_block (name, body) ->
    "(region " ^ name ^ " { " ^ pp body ^ " })"
  | Ref (mode, r, inner) ->
    let prefix = match mode with
      | BorrowedRead -> "&"
      | SharedWrite -> "&shared write "
      | ExclusiveRead -> "&exclusive "
      | ExclusiveWrite -> "&mut "
    in
    prefix ^ r ^ " " ^ pp inner
  | Record_lit (name, fields) ->
    let parts = List.map (fun (f, e) -> f ^ " = " ^ pp e) fields in
    name ^ " { " ^ String.concat ", " parts ^ " }"
  | Field_get (e, f) ->
    pp e ^ "." ^ f
  | Record_update (base, updates) ->
    let parts = List.map (fun (f, e) -> f ^ " = " ^ pp e) updates in
    "{ " ^ pp base ^ " | " ^ String.concat ", " parts ^ " }"

(* Pattern-bound names — used by `rename_free_vars` to know what's
   shadowed inside a match arm or `let pat = ... in` body. *)
let rec pattern_vars p =
  match p.pnode with
  | P_wild | P_int _ | P_bool _ | P_str _ | P_unit -> []
  | P_var n -> [n]
  | P_constr (_, None) -> []
  | P_constr (_, Some sub) -> pattern_vars sub
  | P_tuple ps -> List.concat_map pattern_vars ps
  | P_record (_, fields) ->
    List.concat_map (fun (_, p) -> pattern_vars p) fields
  | P_as (inner, n) -> n :: pattern_vars inner
  | P_or (a, _) -> pattern_vars a  (* P_or arms bind the same names *)

(* Walk an expr and rewrite every FREE variable reference matching
   `lookup name` to a new name. `lookup` returns `Some new_name` to
   rewrite or `None` to leave the Var alone. Shadowing scopes (Fun,
   Let body, Let_rec, Match arm body, With body) hide names from the
   rewrite. *)
let rename_free_vars (lookup : string -> string option) (e : expr) : expr =
  (* Rename a free name (Var, Constr, Record_lit, P_constr, P_record). For
     Var the name is shadowable by let-bound names; for Constr / Record /
     pattern names, shadowing doesn't apply (they're constants of the
     type system, not value bindings).  *)
  let lookup_simple n = match lookup n with Some n' -> n' | None -> n in
  let rec go_pat (p : pattern) : pattern =
    match p.pnode with
    | P_constr (c, sub) ->
      { p with pnode = P_constr (lookup_simple c, Option.map go_pat sub) }
    | P_record (rn, fields) ->
      let fields' = List.map (fun (f, sub) -> (f, go_pat sub)) fields in
      { p with pnode = P_record (lookup_simple rn, fields') }
    | P_tuple ps -> { p with pnode = P_tuple (List.map go_pat ps) }
    | P_as (inner, n) -> { p with pnode = P_as (go_pat inner, n) }
    | P_or (a, b) -> { p with pnode = P_or (go_pat a, go_pat b) }
    | P_var _ | P_wild | P_int _ | P_bool _ | P_str _ | P_unit -> p
  in
  let rec go shadowed e =
    let n_or_e n =
      if List.mem n shadowed then e
      else match lookup n with
        | Some n' -> { e with node = Var n' }
        | None -> e
    in
    let with_shadow xs e' = go (xs @ shadowed) e' in
    match e.node with
    | Int_lit _ | Float_lit _ | Bool_lit _ | Str_lit _ | Unit_lit -> e
    | Var n -> n_or_e n
    | Neg a -> { e with node = Neg (go shadowed a) }
    | Bin (op, a, b) ->
      { e with node = Bin (op, go shadowed a, go shadowed b) }
    | Cmp (op, a, b) ->
      { e with node = Cmp (op, go shadowed a, go shadowed b) }
    | Logic (op, a, b) ->
      { e with node = Logic (op, go shadowed a, go shadowed b) }
    | Let (pat, value, body) ->
      let value' = go shadowed value in
      let body' = with_shadow (pattern_vars pat) body in
      { e with node = Let (go_pat pat, value', body') }
    | Let_rec (bindings, body) ->
      let names = List.map fst bindings in
      let bindings' =
        List.map (fun (n, v) -> (n, with_shadow names v)) bindings
      in
      let body' = with_shadow names body in
      { e with node = Let_rec (bindings', body') }
    | With (name, value, body) ->
      let value' = go shadowed value in
      let body' = with_shadow [name] body in
      { e with node = With (name, value', body') }
    | If (c, t, el) ->
      { e with node = If (go shadowed c, go shadowed t, go shadowed el) }
    | Fun (param, ty_opt, body) ->
      let body' = with_shadow [param] body in
      { e with node = Fun (param, ty_opt, body') }
    | App (f, a) ->
      { e with node = App (go shadowed f, go shadowed a) }
    | Annot (inner, t) ->
      { e with node = Annot (go shadowed inner, t) }
    | Constr (c, None) ->
      { e with node = Constr (lookup_simple c, None) }
    | Constr (c, Some a) ->
      { e with node = Constr (lookup_simple c, Some (go shadowed a)) }
    | Match (scrut, arms) ->
      let scrut' = go shadowed scrut in
      let arms' = List.map (fun (p, guard, body) ->
        let pv = pattern_vars p in
        let guard' = Option.map (with_shadow pv) guard in
        let body' = with_shadow pv body in
        (go_pat p, guard', body')
      ) arms in
      { e with node = Match (scrut', arms') }
    | Tuple es ->
      { e with node = Tuple (List.map (go shadowed) es) }
    | Region_block (r, body) ->
      { e with node = Region_block (r, go shadowed body) }
    | Ref (mode, r, inner) ->
      { e with node = Ref (mode, r, go shadowed inner) }
    | Record_lit (name, fields) ->
      let fields' = List.map (fun (f, ex) -> (f, go shadowed ex)) fields in
      { e with node = Record_lit (lookup_simple name, fields') }
    | Field_get (inner, f) ->
      { e with node = Field_get (go shadowed inner, f) }
    | Record_update (base, updates) ->
      let base' = go shadowed base in
      let updates' = List.map (fun (f, ex) -> (f, go shadowed ex)) updates in
      { e with node = Record_update (base', updates') }
  in
  go [] e

let desugar_program (prog : program) : expr =
  List.fold_right (fun decl body ->
    let loc = body.loc in
    match decl with
    | Top_let (pat, value) ->
      { loc; ty = None; node = Let (pat, value, body) }
    | Top_let_rec bindings ->
      { loc; ty = None; node = Let_rec (bindings, body) }
    | Top_type _ -> body
    | Top_signature _ -> body
    | Top_record _ -> body
    | Top_type_alias _ -> body
    | Top_view _ -> body
    | Top_drop _ -> body
    | Top_sync _ -> body
    | Top_local _ -> body
    | Top_extern _ -> body
    | Top_extern_type _ -> body
    | Top_ctor_alias _ -> body
    | Top_record_alias _ -> body
  ) prog.decls prog.main
