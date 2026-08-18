(* Abstract syntax tree for Lang. *)

type tyvar = {
  id : int;
  mutable link : ty option;
  (* How far inside nested `let`s this variable was created (Remy's ranks).
     A variable belongs to the binding being generalized exactly when its level
     is deeper than the level that binding sits at, which is what lets
     generalization skip looking at the environment at all — see Typer.generalize
     for why that mattered enough to put a field here. Lowered by unification,
     never raised. *)
  mutable level : int;
}

and ty =
  | TyInt
  | TyFloat
  | TyBool
  | TyStr
  | TyBytes                         (* immutable raw byte sequence (a first-class binary type).
                                       Like TyStr but length-prefixed, not NUL-
                                       terminated: binary-safe on every backend. *)
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
  | Top_trait of
      string * string * (string * ty) list * (string * expr) list * string list
    (* trait declaration: `trait Num a { add : a -> a -> a; zero : a; }`, or
       with super-traits `trait Ord a : Eq a { le : a -> a -> bool; }`.
       Fields: trait name, the single type-parameter name (`a`), the method
       signatures (name, type — the type mentions the param `a` as a TyParam),
       the default method bodies (name, expr) for methods written as
       `m : ty = expr`, and the super-trait names (`Eq` above). An impl that
       omits a defaulted method inherits the default; a default body may
       reference sibling methods, which trait_elab inlines per instance before
       type-checking. A super-trait constrains impls: `impl Ord T` requires
       `impl Eq T` (checked transitively). A user-defined interface for ad-hoc
       polymorphism. The trait_elab pass lowers this to a dictionary record
       type and threads dictionaries through constrained generic functions, so
       no backend (interp / C / LLVM / Wasm) needs trait-specific support. *)
  | Top_impl of string * ty * (string * expr) list
    (* implementation: `impl Num int { add = fn x -> fn y -> x + y; zero = 0; }`.
       Fields: trait name, the concrete instance type, and the per-method
       definitions. Lowered by trait_elab to a dictionary value binding. *)

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
    | TyBytes -> "bytes"
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
    | '\r' -> Buffer.add_string buf "\\r"
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

(* Rename BOUND variables in a pattern. `pattern_vars` answers which names a pattern
   binds; this rewrites them. Used by the shadow-uniquifier below, which has to move a
   binder out of the way rather than a reference to one. *)
let rec rename_pat_vars (subst : (string * string) list) (p : pattern) : pattern =
  let sub n = match List.assoc_opt n subst with Some n' -> n' | None -> n in
  match p.pnode with
  | P_wild | P_int _ | P_bool _ | P_str _ | P_unit -> p
  | P_var n -> { p with pnode = P_var (sub n) }
  | P_constr (c, None) -> { p with pnode = P_constr (c, None) }
  | P_constr (c, Some inner) ->
    { p with pnode = P_constr (c, Some (rename_pat_vars subst inner)) }
  | P_tuple ps -> { p with pnode = P_tuple (List.map (rename_pat_vars subst) ps) }
  | P_record (rn, fields) ->
    { p with pnode =
        P_record (rn, List.map (fun (f, q) -> (f, rename_pat_vars subst q)) fields) }
  | P_as (inner, n) -> { p with pnode = P_as (rename_pat_vars subst inner, sub n) }
  | P_or (a, b) ->
    { p with pnode = P_or (rename_pat_vars subst a, rename_pat_vars subst b) }

(* Walk an expr and rewrite every FREE variable reference matching
   `lookup name` to a new name. `lookup` returns `Some new_name` to
   rewrite or `None` to leave the Var alone. Shadowing scopes (Fun,
   Let body, Let_rec, Match arm body, With body) hide names from the
   rewrite. *)
module StringSet = Set.Make (String)

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
  (* `shadowed` is a set rather than a list. It used to be a list, and
     `with_shadow` prepended with `@` — which copies the whole thing at every
     binding, while each `Var` scanned it linearly. A function that is one long
     `let ... in` chain therefore cost O(depth^2) in a pass that only renames
     names: 16 000 nested lets took 1.3s to format and 2.6s to check, most of it
     here rather than in the formatter or the typer. A set shares its structure,
     so extending it is O(log n) and copies nothing. *)
  let rec go shadowed e =
    let n_or_e n =
      if StringSet.mem n shadowed then e
      else match lookup n with
        | Some n' -> { e with node = Var n' }
        | None -> e
    in
    let with_shadow xs e' =
      go (List.fold_left (fun acc x -> StringSet.add x acc) shadowed xs) e'
    in
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
  go StringSet.empty e

(* 2048-dogfood P3: α-rename nested (inner) fn bindings to globally-unique
   names, so no two inner fns ever share a source name. Inner-fn lifting
   (in each backend's codegen) keys its name -> lifted-fn resolution map by
   the source name, so two same-named inner fns within one host function —
   e.g. a `let rec go` in each branch of an `if` — collided: the second
   overwrote the first, and both call sites resolved to the wrong one
   (interp was correct; C and Wasm both mis-executed). Uniquifying here, in
   one shared pre-pass, fixes every backend at once.

   Only NESTED bindings are renamed — top-level decl names live in
   `Top_let` / `Top_let_rec` and are never walked here, so cross-decl
   references and `main` are untouched. Uses `rename_free_vars` (which is
   shadowing-aware) to rewrite references within each binding's scope. *)
let uq_counter = ref 0
(* Rename ONLY on collision: within one host (top-level decl value), the
   FIRST inner fn to use a name keeps it; a later inner fn reusing that name
   is α-renamed to a fresh one. This is the minimum that disambiguates the
   lift map — single-use inner names (the common case, and what most tests
   assert on) are left untouched, and nothing leaks into pretty-printing of
   collision-free code. `seen` is a per-host set of already-taken names. *)
let uniquify_inner_fns_expr (seen : (string, unit) Hashtbl.t) (e0 : expr) : expr =
  let is_fun ex = match ex.node with Fun _ -> true | _ -> false in
  (* claim a name for an inner fn: keep it if free, else return a fresh one *)
  let claim n =
    if Hashtbl.mem seen n then begin
      incr uq_counter; Some (n ^ "_uq" ^ string_of_int !uq_counter)
    end else begin Hashtbl.add seen n (); None end
  in
  (* A binder that COLLIDES with a name already taken, without claiming the name it
     moves to. `claim` is for inner fns, which become symbols of their own and so must
     reserve their name; a parameter does not become a symbol, it just must not be
     mistaken for one.
     Q-046: a parameter named the same as a top-level binding made the backends'
     inner-fn lift resolve the CAPTURE to the top-level symbol. The lifted loop took no
     parameter for it at all and its body referred to the global. That was invisible
     while both had the same type — the wrong binding happened to fit — and surfaced
     as bad C only when their types diverged. *)
  let claim_shadow n =
    if Hashtbl.mem seen n then begin
      incr uq_counter; Some (n ^ "_uq" ^ string_of_int !uq_counter)
    end else None
  in
  let rec uq (e : expr) : expr =
    match e.node with
    | Int_lit _ | Float_lit _ | Bool_lit _ | Str_lit _ | Unit_lit | Var _ -> e
    | Neg a -> { e with node = Neg (uq a) }
    | Bin (op, a, b) -> { e with node = Bin (op, uq a, uq b) }
    | Cmp (op, a, b) -> { e with node = Cmp (op, uq a, uq b) }
    | Logic (op, a, b) -> { e with node = Logic (op, uq a, uq b) }
    | If (c, t, el) -> { e with node = If (uq c, uq t, uq el) }
    | App (f, a) -> { e with node = App (uq f, uq a) }
    | Annot (i, t) -> { e with node = Annot (uq i, t) }
    | Tuple es -> { e with node = Tuple (List.map uq es) }
    | Fun (pname, t, body) ->
      (match claim_shadow pname with
       | None -> { e with node = Fun (pname, t, uq body) }
       | Some pname' ->
         let lookup n = if n = pname then Some pname' else None in
         { e with node = Fun (pname', t, uq (rename_free_vars lookup body)) })
    | Match (s, arms) ->
      let arms' = List.map (fun (p, g, b) -> (p, Option.map uq g, uq b)) arms in
      { e with node = Match (uq s, arms') }
    | With (n, v, b) -> { e with node = With (n, uq v, uq b) }
    | Region_block (r, b) -> { e with node = Region_block (r, uq b) }
    | Ref (m, r, a) -> { e with node = Ref (m, r, uq a) }
    | Constr (c, ao) -> { e with node = Constr (c, Option.map uq ao) }
    | Record_lit (n, fs) ->
      { e with node = Record_lit (n, List.map (fun (f, x) -> (f, uq x)) fs) }
    | Field_get (i, f) -> { e with node = Field_get (uq i, f) }
    | Record_update (b, us) ->
      { e with node = Record_update (uq b, List.map (fun (f, x) -> (f, uq x)) us) }
    (* nested fn-valued let (non-recursive: name not in scope in value) *)
    | Let ({ pnode = P_var name; _ } as pat, v, body) when is_fun v ->
      let v' = uq v in
      (match claim name with
       | None -> { e with node = Let (pat, v', uq body) }
       | Some name' ->
         let body' =
           uq (rename_free_vars (fun n -> if n = name then Some name' else None) body) in
         { e with node = Let ({ pat with pnode = P_var name' }, v', body') })
    | Let (pat, v, body) -> { e with node = Let (pat, uq v, uq body) }
    (* nested recursive fn group: names are in scope in the values + body *)
    | Let_rec (bindings, body) ->
      let renames =
        List.filter_map (fun (n, _) ->
          match claim n with Some n' -> Some (n, n') | None -> None) bindings in
      if renames = [] then
        { e with node = Let_rec (List.map (fun (n, v) -> (n, uq v)) bindings, uq body) }
      else
        let lookup n = List.assoc_opt n renames in
        let bindings' =
          List.map (fun (n, v) ->
            let n' = match List.assoc_opt n renames with Some x -> x | None -> n in
            (n', uq (rename_free_vars lookup v))) bindings in
        let body' = uq (rename_free_vars lookup body) in
        { e with node = Let_rec (bindings', body') }
  in
  uq e0

let uniquify_inner_fns_program (prog : program) : program =
  (* Share one `seen` table across all top-level decls + main so an inner fn
     name reused in two different top-level scopes (e.g. a `go` loop helper in
     two places) lifts to two distinct symbols. Per-decl tables let the names
     collide, which the LLVM backend miscompiled — one lifted body ended up
     referencing the other's captured variable ("use of undefined value"). *)
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  (* Seed with every top-level binding name. A lifted inner fn must not collide
     with a real top-level symbol of the same name: an inner `go` in one helper
     and a top-level `go` both lift/emit as `go`, and the LLVM backend then
     resolved a call to the top-level `go` against the lifted inner one (calling
     it with the inner one's captures — "use of undefined value"). Seeding forces
     the colliding inner fn to be renamed. *)
  List.iter (function
    | Top_let (p, _) -> List.iter (fun n -> Hashtbl.replace seen n ()) (pattern_vars p)
    | Top_let_rec bs -> List.iter (fun (n, _) -> Hashtbl.replace seen n ()) bs
    | _ -> ()) prog.decls;
  let decls =
    List.map (function
      | Top_let (p, e) -> Top_let (p, uniquify_inner_fns_expr seen e)
      | Top_let_rec bs -> Top_let_rec (List.map (fun (n, e) -> (n, uniquify_inner_fns_expr seen e)) bs)
      | d -> d)
      prog.decls
  in
  { decls; main = uniquify_inner_fns_expr seen prog.main }

(* A user top-level binding named `main` collides with the synthesized program
   entry (C emits `main`, Wasm exports `$main`). Mere has no main convention —
   the entry point IS the file's trailing expression — so a `main` binding is
   only ever an ordinary value that happens to share the entry's name. The C
   backend already mangles it (`mu_main`), but the LLVM and Wasm backends emit
   the raw name and produced a duplicate-`main` link/assemble error. Alpha-
   rename a top-level `main` to a reserved name here, once, so every backend is
   consistent. Scope-aware via rename_free_vars: an inner `main` (a local let or
   a parameter) shadows and is left untouched. *)
let reserve_toplevel_main (prog : program) : program =
  let binds_main =
    List.exists (function
      | Top_let (p, _) -> List.mem "main" (pattern_vars p)
      | Top_let_rec bs -> List.exists (fun (n, _) -> n = "main") bs
      | _ -> false) prog.decls
  in
  if not binds_main then prog
  else
    let fresh = "__mere_user_main" in
    let lk n = if n = "main" then Some fresh else None in
    let rn_pat p =
      match p.pnode with
      | P_var "main" -> { p with pnode = P_var fresh }
      | _ -> p
    in
    let rn_decl = function
      | Top_let (p, v) -> Top_let (rn_pat p, rename_free_vars lk v)
      | Top_let_rec bs ->
        Top_let_rec
          (List.map (fun (n, v) ->
             ((if n = "main" then fresh else n), rename_free_vars lk v)) bs)
      | other -> other
    in
    { decls = List.map rn_decl prog.decls;
      main = rename_free_vars lk prog.main }

(* Two `module Greet { ... }` at different import paths (SIV: a lib and its
   `/v2` both name their module `Greet`) desugar to identically-qualified
   top-level names — `Greet.hello` defined twice, of different types. They
   shadow by declaration order, and the interpreter honours that (a closure
   captures the env at its definition, and the env prepends, so a reference
   binds to the most-recent prior definition). The native backends resolve a
   top-level name globally, without that scope, and mis-assign one version's
   body to the other. Resolve the shadow into distinct names here — walk the
   decls in order, and when a *dotted* (module-qualified) name is redefined,
   rename the redefinition (`Greet.hello` -> `Greet.hello__v2`) and rewrite
   every later reference to it, so all four backends see distinct symbols.
   Only dotted redefinitions are touched, so ordinary programs are unaffected. *)
(* `shadowable` names are treated as ALREADY BOUND, so the first top-level binding
   of one of them counts as a shadow and gets renamed.

   It carries the builtin names (Q-045). A builtin is not a top-level declaration, so
   this pass could not see `let show = fn (x: int) -> x + 1` as shadowing anything —
   it kept the name `show`, and the backends, which resolve a top-level name globally,
   then resolved the PRELUDE's call to the `show` BUILTIN to the user's function. The
   symptom was a type error at `<prelude>:485` for a program that never mentions the
   prelude, and after the typer half was fixed, a refusal from the monomorphiser
   because one name had two skeletons.

   Renaming the user's binding is the whole fix: references BEFORE it (the prelude)
   still mean the builtin, references after it resolve through `cur` to the renamed
   one, and `rename_free_vars` is scope-aware so inner binders are untouched.

   The caller passes only the builtins the PRELUDE does not itself define — the
   prelude deliberately shadows ten of them (`pow`, `divmod`, …), and those must keep
   the names they have always had. *)
let uniquify_toplevel_shadows ?(shadowable = []) (prog : program) : program =
  let cur : (string, string) Hashtbl.t = Hashtbl.create 16 in
  let count : (string, int) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun n -> Hashtbl.replace count n 1) shadowable;
  let lk n = Hashtbl.find_opt cur n in
  (* Register a binding occurrence of `n`; return the (possibly fresh) name it
     should be bound under, updating `cur` for later free references. The first
     binding of a name keeps it; a later top-level binding that shadows it is
     renamed to `n__vC` and subsequent references resolve to the new name.
     Applies to every top-level name (module-dotted or plain). The interpreter
     resolves shadowing through its lexical environment, but the C / LLVM / Wasm
     backends flatten top-level fns by name — without this pass two same-named
     top-level lets collapse into one, miscompiling the earlier one's call sites
     (e.g. `let load = ...` used by a function defined before a later
     `let rec load = ...`). `rename_free_vars` is scope-aware, so inner binders
     that reuse a shadowed name are left untouched. *)
  let bind_name n =
    let c = (match Hashtbl.find_opt count n with Some c -> c | None -> 0) + 1 in
    Hashtbl.replace count n c;
    if c = 1 then n
    else begin
      let n' = n ^ "__v" ^ string_of_int c in
      Hashtbl.replace cur n n';
      n'
    end
  in
  let rn_decl = function
    | Top_let ({ pnode = P_var n; _ } as p, v) ->
      (* non-recursive: the value is in the scope BEFORE this binding *)
      let v' = rename_free_vars lk v in
      let n' = bind_name n in
      Top_let ({ p with pnode = P_var n' }, v')
    | Top_let (p, v) -> Top_let (p, rename_free_vars lk v)
    | Top_let_rec bs ->
      (* recursive: names are in scope within their own values *)
      let names' = List.map (fun (n, _) -> bind_name n) bs in
      Top_let_rec (List.map2 (fun n' (_, v) -> (n', rename_free_vars lk v)) names' bs)
    | other -> other
  in
  let decls = List.map rn_decl prog.decls in
  { decls; main = rename_free_vars lk prog.main }

(* Q-012 Phase 32: lower a saturated `par_map f xs` into spawn + channel +
   list_map, so it works on every backend (spawn / channel / list_map all
   codegen already) without a par_map-specific runtime. Expansion:

     let __f = f in let __xs = xs in
     list_map
       (list_map __xs
          (fn x -> let ch = channel_new () in
                   let _ = spawn (fn u -> channel_send ch (__f x)) in ch))
       (fn c -> channel_recv c)

   The two list_maps run in sequence: the first fans out (one worker + one
   channel per element, order preserved in the channel list), the second
   fans in (recv in the same order). Because each call site is lowered with
   its own concrete element types, this avoids the polymorphic-channel
   monomorphization that a shared prelude par_map would hit. The Send bounds
   still hold: the output element is checked by channel_send, the input by
   the spawn-capture analysis. An unsaturated `par_map` (used as a value) is
   left alone and falls back to the interpreter builtin. *)
let pm_counter = ref 0
let lower_par_map_expr (e : expr) : expr =
  let mk node = { loc = Loc.dummy; ty = None; node } in
  let pvar n = { ploc = Loc.dummy; pnode = P_var n } in
  let pwild = { ploc = Loc.dummy; pnode = P_wild } in
  let var n = mk (Var n) in
  let app a b = mk (App (a, b)) in
  let fresh p = incr pm_counter; p ^ string_of_int !pm_counter in
  let rec lo (e : expr) : expr =
    match e.node with
    | Int_lit _ | Float_lit _ | Bool_lit _ | Str_lit _ | Unit_lit | Var _ -> e
    | Bin (op, a, b) -> { e with node = Bin (op, lo a, lo b) }
    | Cmp (op, a, b) -> { e with node = Cmp (op, lo a, lo b) }
    | Logic (op, a, b) -> { e with node = Logic (op, lo a, lo b) }
    | Neg a -> { e with node = Neg (lo a) }
    | Let (p, v, b) -> { e with node = Let (p, lo v, lo b) }
    | Let_rec (bs, b) ->
      { e with node = Let_rec (List.map (fun (n, v) -> (n, lo v)) bs, lo b) }
    | With (n, v, b) -> { e with node = With (n, lo v, lo b) }
    | If (c, t, el) -> { e with node = If (lo c, lo t, lo el) }
    | Fun (p, t, b) -> { e with node = Fun (p, t, lo b) }
    | Annot (a, t) -> { e with node = Annot (lo a, t) }
    | Constr (n, Some a) -> { e with node = Constr (n, Some (lo a)) }
    | Constr (_, None) -> e
    | Match (s, arms) ->
      { e with node = Match (lo s,
        List.map (fun (p, g, b) -> (p, Option.map lo g, lo b)) arms) }
    | Tuple es -> { e with node = Tuple (List.map lo es) }
    | Region_block (n, b) -> { e with node = Region_block (n, lo b) }
    | Ref (m, r, a) -> { e with node = Ref (m, r, lo a) }
    | Record_lit (n, fs) ->
      { e with node = Record_lit (n, List.map (fun (f, x) -> (f, lo x)) fs) }
    | Field_get (a, f) -> { e with node = Field_get (lo a, f) }
    | Record_update (a, fs) ->
      { e with node = Record_update (lo a, List.map (fun (f, x) -> (f, lo x)) fs) }
    | App ({ node = App ({ node = Var "par_map"; _ }, pf); _ }, pxs) ->
      let pf = lo pf and pxs = lo pxs in
      let fn = fresh "__pm_f" and xsn = fresh "__pm_xs" and xn = fresh "__pm_x"
      and chn = fresh "__pm_ch" and cn = fresh "__pm_c" and un = fresh "__pm_u" in
      let spawn_lambda =
        mk (Fun (un, None,
          app (app (var "channel_send") (var chn)) (app (var fn) (var xn)))) in
      let inner_lambda =
        mk (Fun (xn, None,
          mk (Let (pvar chn, app (var "channel_new") (mk Unit_lit),
            mk (Let (pwild, app (var "spawn") spawn_lambda, var chn)))))) in
      let recv_lambda = mk (Fun (cn, None, app (var "channel_recv") (var cn))) in
      let inner_map = app (app (var "list_map") (var xsn)) inner_lambda in
      let outer_map = app (app (var "list_map") inner_map) recv_lambda in
      mk (Let (pvar fn, pf, mk (Let (pvar xsn, pxs, outer_map))))
    | App (f, arg) -> { e with node = App (lo f, lo arg) }
  in
  lo e

let lower_par_map_program (prog : program) : program =
  let lower_decl = function
    | Top_let (p, e) -> Top_let (p, lower_par_map_expr e)
    | Top_let_rec bs -> Top_let_rec (List.map (fun (n, e) -> (n, lower_par_map_expr e)) bs)
    | d -> d
  in
  { decls = List.map lower_decl prog.decls; main = lower_par_map_expr prog.main }

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
    | Top_trait _ -> body
    | Top_impl _ -> body
  ) prog.decls prog.main

(* The sub-expressions of a node, in source order.

   Written once, here, because everything that answers a question about a
   position in a file needs it — what is the type here, where was this defined,
   what is in scope — and each of those writing its own 26-case match is how the
   cases drift apart. Patterns and types are not expressions and are not
   included; a caller that wants them looks at the node itself. *)
let children (e : expr) : expr list =
  match e.node with
  | Int_lit _ | Float_lit _ | Bool_lit _ | Str_lit _ | Unit_lit | Var _ -> []
  | Neg a | Annot (a, _) | Field_get (a, _) | Region_block (_, a) | Ref (_, _, a) -> [a]
  | Bin (_, a, b) | Cmp (_, a, b) | Logic (_, a, b) | App (a, b) -> [a; b]
  | Let (_, a, b) -> [a; b]
  | With (_, a, b) -> [a; b]
  | If (a, b, c) -> [a; b; c]
  | Fun (_, _, body) -> [body]
  | Let_rec (bindings, body) -> List.map snd bindings @ [body]
  | Constr (_, arg) -> (match arg with Some a -> [a] | None -> [])
  | Match (scrutinee, arms) ->
    scrutinee
    :: List.concat_map (fun (_, guard, body) ->
         (match guard with Some g -> [g] | None -> []) @ [body]) arms
  | Tuple items -> items
  | Record_lit (_, fields) -> List.map snd fields
  | Record_update (base, fields) -> base :: List.map snd fields

(* The expressions a top-level declaration contains. *)
let decl_exprs (d : top_decl) : expr list =
  match d with
  | Top_let (_, e) -> [e]
  | Top_let_rec bindings -> List.map snd bindings
  | Top_type _ | Top_signature _ | Top_record _ | Top_type_alias _
  | Top_view _ | Top_extern _ | Top_extern_type _ | Top_drop _
  | Top_sync _ | Top_local _ | Top_ctor_alias _ | Top_record_alias _
  | Top_trait _ | Top_impl _ -> []
