(* Phase 47: mere-fmt — pretty-printer for the Mere AST.

   The format is intentionally simple and predictable:
   - 2-space indent
   - operator precedence drives paren insertion (so `1 + 2 * 3` stays
     `1 + 2 * 3`, not `(1 + (2 * 3))`)
   - long `let` / `if` / `match` chains break onto their own lines
   - top-level decls separated by a blank line

   Known limitations (MVP, documented at the user-facing CLI):
   - Comments are not preserved (the lexer strips them).
   - Some Phase 36 sugars are emitted in their desugared form
     (e.g. operator sections, string interpolation). `range a b` is
     re-rendered as `a..b`, and Cons/Nil chains as list literals,
     because those forms are the most common visual disruption. *)

open Ast

(* ── Precedence ──────────────────────────────────────────────────────── *)

(* Higher = binds tighter. A child whose precedence is strictly LESS than
   the parent's needs parens. *)
let prec_top      = 0   (* let / if / fn / match / with / region / etc. *)
let prec_pipe     = 1   (* |>  <|  @@ *)
let prec_compose  = 2   (* <<  >> *)
let prec_or       = 3   (* || *)
let prec_and      = 4   (* && *)
let prec_cmp      = 5   (* == != < <= > >= *)
let prec_range    = 6   (* ..  :: *)
let prec_sum      = 7   (* +  -  ++ *)
let prec_term     = 8   (* *  /  % *)
let prec_unary    = 9   (* -e *)
let prec_app      = 10  (* f a *)
let prec_atom     = 11  (* literal, Var, paren, tuple, record, .field *)

(* ── String helpers ─────────────────────────────────────────────────── *)

let parens s = "(" ^ s ^ ")"

let wrap need_paren s = if need_paren then parens s else s

let indent n = String.make (n * 2) ' '

(* String escaping for re-emission. We extend the standard escape with
   `{` -> `\{` so that any literal brace round-trips through the Phase 36
   string-interpolation lexer (which would otherwise treat `{` as the
   start of an interpolated expression). *)
let escape_string_for_fmt s =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\t' -> Buffer.add_string buf "\\t"
    | '{' -> Buffer.add_string buf "\\{"
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.add_char buf '"';
  Buffer.contents buf

let binop_str = function
  | Add -> "+" | Sub -> "-" | Mul -> "*" | Div -> "/" | Mod -> "%"
  | Concat -> "++"

let cmpop_str = function
  | Eq -> "==" | Ne -> "!=" | Lt -> "<" | Le -> "<=" | Gt -> ">" | Ge -> ">="

let logicop_str = function
  | And -> "&&" | Or -> "||"

let binop_prec = function
  | Add | Sub | Concat -> prec_sum
  | Mul | Div | Mod -> prec_term

(* ── Sugar reversal (selective) ─────────────────────────────────────── *)

(* `App (App (Var "range", a), b)` → Some (a, b). Lets us print `a..b`
   instead of `range a b` when the user originally wrote `..`. We can't
   distinguish those cases for sure, but the `..` form is far more readable
   so we always prefer it for binary range calls. *)
let try_match_range e =
  match e.node with
  | App ({ node = App ({ node = Var "range"; _ }, a); _ }, b) -> Some (a, b)
  | _ -> None

(* A Cons/Nil chain we can flatten to `[a, b, c]`. Returns the element
   list if the chain terminates in Nil; None otherwise (we keep `h :: tail`
   form in that case). *)
let try_match_list_literal e =
  let rec walk acc e =
    match e.node with
    | Constr ("Nil", None) -> Some (List.rev acc)
    | Constr ("Cons", Some { node = Tuple [h; t]; _ }) -> walk (h :: acc) t
    | _ -> None
  in
  walk [] e

(* `Constr ("Cons", Some (Tuple [h; t]))` whose tail is NOT itself a
   list-literal Cons chain: render as `h :: t`. Caller chooses between
   list-literal and cons form based on this. *)
let is_cons_pair e =
  match e.node with
  | Constr ("Cons", Some { node = Tuple [_; _]; _ }) -> true
  | _ -> false

let cons_parts e =
  match e.node with
  | Constr ("Cons", Some { node = Tuple [h; t]; _ }) -> Some (h, t)
  | _ -> None

(* ── Type printing (consistent with `pp_ty` but without forced parens
      around arrows that don't need them) ─────────────────────────────── *)

(* Type-level precedence:
   0 = top (Arrow chain)
   1 = tuple element
   2 = atom (TyCon, TyVar, etc.) *)
let rec fmt_ty ?(prec = 0) t =
  let t = walk t in
  match t with
  | TyInt -> "int" | TyFloat -> "float" | TyBool -> "bool"
  | TyStr -> "str" | TyUnit -> "unit"
  | TyVar v -> Printf.sprintf "'_t%d" v.id
  | TyParam p -> "'" ^ p
  | TyArrow (a, b) ->
    let s = fmt_ty ~prec:1 a ^ " -> " ^ fmt_ty ~prec:0 b in
    wrap (prec > 0) s
  | TyTuple ts ->
    let s = String.concat " * " (List.map (fmt_ty ~prec:2) ts) in
    wrap (prec > 1) s
  | TyRef (mode, region, inner) ->
    let kw = match mode with
      | BorrowedRead -> "&"
      | SharedWrite -> "&shared write "
      | ExclusiveRead -> "&exclusive "
      | ExclusiveWrite -> "&mut "
    in
    let s = kw ^ region ^ " " ^ fmt_ty ~prec:2 inner in
    wrap (prec > 1) s
  | TyCon (name, []) -> name
  | TyCon (name, [TyRef (_, r, TyUnit)]) -> name ^ "[" ^ r ^ "]"
  | TyCon (name, [TyRef (_, r, TyUnit); t]) ->
    name ^ "[" ^ r ^ ", " ^ fmt_ty t ^ "]"
  | TyCon (name, [TyRef (_, r, TyUnit); k; v]) ->
    name ^ "[" ^ r ^ ", " ^ fmt_ty k ^ ", " ^ fmt_ty v ^ "]"
  | TyCon ("Vec", [region_tv; t]) ->
    "Vec[" ^ fmt_ty region_tv ^ ", " ^ fmt_ty t ^ "]"
  | TyCon ("StrBuf", [region_tv]) ->
    "StrBuf[" ^ fmt_ty region_tv ^ "]"
  | TyCon ("Map", [region_tv; k; v]) ->
    "Map[" ^ fmt_ty region_tv ^ ", " ^ fmt_ty k ^ ", " ^ fmt_ty v ^ "]"
  | TyCon (name, [a]) -> fmt_ty ~prec:2 a ^ " " ^ name
  | TyCon (name, args) ->
    "(" ^ String.concat ", " (List.map fmt_ty args) ^ ") " ^ name

(* ── Patterns ───────────────────────────────────────────────────────── *)

let rec fmt_pat p =
  match p.pnode with
  | P_wild -> "_"
  | P_var n -> n
  | P_int n -> string_of_int n
  | P_bool true -> "true" | P_bool false -> "false"
  | P_str s -> escape_string_for_fmt s
  | P_unit -> "()"
  | P_constr (c, None) -> c
  | P_constr (c, Some sub) -> c ^ " " ^ fmt_pat_atom sub
  | P_tuple ps ->
    "(" ^ String.concat ", " (List.map fmt_pat ps) ^ ")"
  | P_record (name, fields) ->
    let parts = List.map (fun (f, p) -> f ^ " = " ^ fmt_pat p) fields in
    name ^ " { " ^ String.concat ", " parts ^ " }"
  | P_as (inner, name) ->
    fmt_pat inner ^ " as " ^ name
  | P_or (a, b) ->
    fmt_pat a ^ " | " ^ fmt_pat b

(* Parenthesise around a pattern when it would otherwise read as
   adjacent tokens (e.g. inside a ctor payload). *)
and fmt_pat_atom p =
  match p.pnode with
  | P_or _ | P_as _ | P_constr (_, Some _) -> "(" ^ fmt_pat p ^ ")"
  | _ -> fmt_pat p

(* ── Expressions ────────────────────────────────────────────────────── *)

(* Should this expression be emitted on its own line (i.e. it's a
   "block" form like let / if / match / with)? *)
let is_block e =
  match e.node with
  | Let _ | Let_rec _ | If _ | Match _ | With _ | Region_block _ -> true
  | _ -> false

(* Does this expression end in a `Match` (possibly through Let / With /
   Region_block / If chains)? Used to decide whether we must wrap an
   arm body in parens to avoid the outer `match` stealing arms. *)
let rec trailing_match e =
  match e.node with
  | Match _ -> true
  | Let (_, _, body) | Let_rec (_, body) | With (_, _, body)
  | Region_block (_, body) -> trailing_match body
  | If (_, t, el) -> trailing_match t || trailing_match el
  | _ -> false

let rec fmt_expr ~prec:p ~ind e =
  match e.node with
  (* ── literals & names ── *)
  | Int_lit n -> string_of_int n
  | Float_lit f ->
    (* OCaml's `string_of_float 3.0` returns `"3."`, but the Mere lexer
       requires `<digit>+.<digit>+` (so `3.` is lexed as `Int 3` followed
       by `.`). Always emit at least one fractional digit. *)
    let s = string_of_float f in
    if String.length s > 0 && s.[String.length s - 1] = '.' then s ^ "0"
    else s
  | Bool_lit true -> "true" | Bool_lit false -> "false"
  | Str_lit s -> escape_string_for_fmt s
  | Unit_lit -> "()"
  | Var n -> n
  | Constr ("Nil", None) -> "[]"
  | Constr (c, None) -> c
  | Constr ("Cons", Some _) when (try_match_list_literal e) <> None ->
    let xs = Option.get (try_match_list_literal e) in
    "[" ^ String.concat ", " (List.map (fmt_expr ~prec:prec_top ~ind) xs) ^ "]"
  | Constr ("Cons", Some _) when is_cons_pair e ->
    (* Right-associative `::`. As the parent prec we use prec_range,
       and request the left arg at one higher level (so nested cons on
       the LEFT need parens, but on the right don't). *)
    let h, t = Option.get (cons_parts e) in
    let s =
      fmt_expr ~prec:(prec_range + 1) ~ind h
      ^ " :: "
      ^ fmt_expr ~prec:prec_range ~ind t
    in
    wrap (p > prec_range) s
  | Constr (c, Some arg) ->
    let s = c ^ " " ^ fmt_expr ~prec:(prec_app + 1) ~ind arg in
    wrap (p > prec_app) s
  (* ── operators ── *)
  | Neg a ->
    let s = "-" ^ fmt_expr ~prec:prec_unary ~ind a in
    wrap (p > prec_unary) s
  | Bin (op, a, b) ->
    let bp = binop_prec op in
    (* left-associative *)
    let s =
      fmt_expr ~prec:bp ~ind a
      ^ " " ^ binop_str op ^ " "
      ^ fmt_expr ~prec:(bp + 1) ~ind b
    in
    wrap (p > bp) s
  | Cmp (op, a, b) ->
    let s =
      fmt_expr ~prec:(prec_cmp + 1) ~ind a
      ^ " " ^ cmpop_str op ^ " "
      ^ fmt_expr ~prec:(prec_cmp + 1) ~ind b
    in
    wrap (p > prec_cmp) s
  | Logic (op, a, b) ->
    let bp = match op with And -> prec_and | Or -> prec_or in
    let s =
      fmt_expr ~prec:bp ~ind a
      ^ " " ^ logicop_str op ^ " "
      ^ fmt_expr ~prec:(bp + 1) ~ind b
    in
    wrap (p > bp) s
  (* ── range sugar reversal ── *)
  | App _ when (try_match_range e) <> None ->
    let a, b = Option.get (try_match_range e) in
    let s =
      fmt_expr ~prec:(prec_range + 1) ~ind a
      ^ ".." ^ fmt_expr ~prec:(prec_range + 1) ~ind b
    in
    wrap (p > prec_range) s
  (* ── application ── *)
  | App (f, arg) ->
    let s =
      fmt_expr ~prec:prec_app ~ind f
      ^ " " ^ fmt_expr ~prec:(prec_app + 1) ~ind arg
    in
    wrap (p > prec_app) s
  | Annot (inner, t) ->
    (* The parser binds `: T` to the immediately preceding expression
       at the current precedence layer (lowest). To ensure the annotation
       wraps `inner` as written (and not just its tail), we force a tight
       atom-level emission, which inserts parens if `inner` is anything
       looser than a single atom. *)
    "(" ^ fmt_expr ~prec:prec_atom ~ind inner ^ " : " ^ fmt_ty t ^ ")"
  (* ── tuple / record / view ── *)
  | Tuple es ->
    "(" ^ String.concat ", " (List.map (fmt_expr ~prec:prec_top ~ind) es) ^ ")"
  | Record_lit (name, fields) ->
    let parts =
      List.map (fun (f, e) -> f ^ " = " ^ fmt_expr ~prec:prec_top ~ind e) fields
    in
    name ^ " { " ^ String.concat ", " parts ^ " }"
  | Field_get (e, f) ->
    fmt_expr ~prec:prec_atom ~ind e ^ "." ^ f
  | Record_update (base, updates) ->
    let parts =
      List.map (fun (f, e) -> f ^ " = " ^ fmt_expr ~prec:prec_top ~ind e) updates
    in
    "{ " ^ fmt_expr ~prec:prec_top ~ind base
    ^ " | " ^ String.concat ", " parts ^ " }"
  (* ── functions ── *)
  | Fun _ ->
    let s = fmt_fun_chain ~ind e in
    wrap (p > prec_top) s
  (* ── refs ── *)
  | Ref (mode, r, inner) ->
    let kw = match mode with
      | BorrowedRead -> "&"
      | SharedWrite -> "&shared write "
      | ExclusiveRead -> "&exclusive "
      | ExclusiveWrite -> "&mut "
    in
    let s = kw ^ r ^ " " ^ fmt_expr ~prec:(prec_app + 1) ~ind inner in
    wrap (p > prec_app) s
  (* ── block forms ── *)
  | Let _ | Let_rec _ | With _ | If _ | Match _ | Region_block _ ->
    let s = fmt_block ~ind e in
    wrap (p > prec_top) s

(* The parser only accepts `fn x -> body` (single ident) and
   `fn (x: T, y: U) -> body` (parenthesized multi-arg with types).
   Phase 36 lambda shorthand `\x y z -> body` is the only way to
   write multi-ident `fn` without types — we use it to collapse
   chains of un-annotated `fn`s for readability, falling back to
   nested `fn`s the moment any inner Fun carries a type. *)
and fmt_fun_chain ~ind e =
  match e.node with
  | Fun (x, Some t, body) ->
    "fn (" ^ x ^ ": " ^ fmt_ty t ^ ") -> "
    ^ fmt_expr ~prec:prec_top ~ind body
  | Fun (x, None, body) ->
    let rec collect params e =
      match e.node with
      | Fun (n, None, b) -> collect (n :: params) b
      | _ -> List.rev params, e
    in
    let params, inner = collect [x] body in
    (match params with
     | [n] ->
       (* No collapse — single param keeps the canonical `fn x -> body` form. *)
       "fn " ^ n ^ " -> " ^ fmt_expr ~prec:prec_top ~ind inner
     | _ ->
       (* Multi-param: use Phase 36 lambda shorthand `\x y -> body`. *)
       "\\" ^ String.concat " " params ^ " -> "
       ^ fmt_expr ~prec:prec_top ~ind inner)
  | _ -> fmt_expr ~prec:prec_top ~ind e

(* Block-form layout. Multi-line for nested let / if / match. *)
and fmt_block ~ind e =
  match e.node with
  | Let (pat, value, body) ->
    let value_s =
      if is_block value then
        "\n" ^ indent (ind + 1) ^ fmt_expr ~prec:prec_top ~ind:(ind + 1) value
      else
        " " ^ fmt_expr ~prec:prec_top ~ind value
    in
    "let " ^ fmt_pat pat ^ " =" ^ value_s ^ " in\n"
    ^ indent ind ^ fmt_expr ~prec:prec_top ~ind body
  | Let_rec (bindings, body) ->
    let parts =
      List.mapi (fun i (n, v) ->
        let kw = if i = 0 then "let rec " else indent ind ^ "and " in
        let v_s =
          if is_block v then
            "\n" ^ indent (ind + 1) ^ fmt_expr ~prec:prec_top ~ind:(ind + 1) v
          else
            " " ^ fmt_expr ~prec:prec_top ~ind v
        in
        kw ^ n ^ " =" ^ v_s) bindings
    in
    String.concat "\n" parts ^ " in\n"
    ^ indent ind ^ fmt_expr ~prec:prec_top ~ind body
  | With (name, value, body) ->
    "with " ^ name ^ " = " ^ fmt_expr ~prec:prec_top ~ind value ^ " in\n"
    ^ indent ind ^ fmt_expr ~prec:prec_top ~ind body
  | If (cond, then_, else_) ->
    (* Inline form when both arms are non-block AND the whole thing
       fits in a reasonable single line. Otherwise multi-line. *)
    let cond_s = fmt_expr ~prec:prec_top ~ind cond in
    if not (is_block then_) && not (is_block else_) then
      let then_s = fmt_expr ~prec:prec_top ~ind then_ in
      let else_s = fmt_expr ~prec:prec_top ~ind else_ in
      let single = "if " ^ cond_s ^ " then " ^ then_s ^ " else " ^ else_s in
      if String.length single + (ind * 2) <= 80 then single
      else fmt_if_multiline ~ind cond_s then_ else_
    else
      fmt_if_multiline ~ind cond_s then_ else_
  | Match (scrut, arms) ->
    (* Mere's `match` is greedy: an arm's body keeps consuming `| pat ->`
       as long as the parser sees them, regardless of indentation. So a
       trailing `Match` (or `Let-in-...-Match`) inside an arm body would
       steal the outer match's later arms when re-parsed. Wrap such
       bodies in `( ... )` to terminate them explicitly. *)
    let arm_s (p, guard, body) =
      let g_s = match guard with
        | None -> ""
        | Some g -> " when " ^ fmt_expr ~prec:prec_top ~ind:(ind + 1) g
      in
      let needs_paren = trailing_match body in
      let body_s = fmt_expr ~prec:prec_top ~ind:(ind + 1) body in
      let body_s = if needs_paren then "(" ^ body_s ^ ")" else body_s in
      indent ind ^ "| " ^ fmt_pat p ^ g_s ^ " -> " ^ body_s
    in
    "match " ^ fmt_expr ~prec:prec_top ~ind scrut ^ " with\n"
    ^ String.concat "\n" (List.map arm_s arms)
  | Region_block (name, body) ->
    "region " ^ name ^ " {\n"
    ^ indent (ind + 1) ^ fmt_expr ~prec:prec_top ~ind:(ind + 1) body ^ "\n"
    ^ indent ind ^ "}"
  | _ ->
    fmt_expr ~prec:prec_top ~ind e

(* Multi-line `if` layout with else-if chain flattening:
     if c1 then
       T1
     else if c2 then
       T2
     else
       E
   Triggered both when arms contain blocks and when an inline rendering
   would overflow the column budget. *)
and fmt_if_multiline ~ind cond_s then_ else_ =
  let then_body = fmt_expr ~prec:prec_top ~ind:(ind + 1) then_ in
  let head = "if " ^ cond_s ^ " then\n" ^ indent (ind + 1) ^ then_body in
  let tail = fmt_else_chain ~ind else_ in
  head ^ "\n" ^ tail

and fmt_else_chain ~ind else_ =
  match else_.node with
  | If (cond, then_, else_inner) ->
    let cond_s = fmt_expr ~prec:prec_top ~ind cond in
    let then_body = fmt_expr ~prec:prec_top ~ind:(ind + 1) then_ in
    let head =
      indent ind ^ "else if " ^ cond_s ^ " then\n"
      ^ indent (ind + 1) ^ then_body
    in
    head ^ "\n" ^ fmt_else_chain ~ind else_inner
  | _ ->
    let body = fmt_expr ~prec:prec_top ~ind:(ind + 1) else_ in
    indent ind ^ "else\n" ^ indent (ind + 1) ^ body

(* ── Top-level decls ────────────────────────────────────────────────── *)

let fmt_top_let pat value =
  match value.node with
  | Fun _ when (match pat.pnode with P_var _ -> true | _ -> false) ->
    "let " ^ fmt_pat pat ^ " = " ^ fmt_fun_chain ~ind:0 value ^ ";"
  | _ when is_block value ->
    "let " ^ fmt_pat pat ^ " =\n"
    ^ indent 1 ^ fmt_expr ~prec:prec_top ~ind:1 value ^ ";"
  | _ ->
    "let " ^ fmt_pat pat ^ " = " ^ fmt_expr ~prec:prec_top ~ind:0 value ^ ";"

let fmt_top_let_rec bindings =
  let parts =
    List.mapi (fun i (n, v) ->
      let kw = if i = 0 then "let rec " else "and " in
      let body_s =
        match v.node with
        | Fun _ -> fmt_fun_chain ~ind:0 v
        | _ when is_block v ->
          "\n" ^ indent 1 ^ fmt_expr ~prec:prec_top ~ind:1 v
        | _ -> fmt_expr ~prec:prec_top ~ind:0 v
      in
      let sep = if String.length body_s > 0 && body_s.[0] = '\n' then "=" else "= " in
      kw ^ n ^ " " ^ sep ^ body_s) bindings
  in
  String.concat "\n" parts ^ ";"

let fmt_type_params params =
  match params with
  | [] -> ""
  | [p] -> "'" ^ p ^ " "
  | _ -> "(" ^ String.concat ", " (List.map (fun p -> "'" ^ p) params) ^ ") "

let fmt_top_type name params variants =
  let var_s =
    variants
    |> List.map (fun (c, payload) ->
      match payload with
      | None -> c
      | Some t -> c ^ " of " ^ fmt_ty t)
    |> String.concat " | "
  in
  "type " ^ fmt_type_params params ^ name ^ " = " ^ var_s ^ ";"

let fmt_top_record name params fields =
  let field_s =
    fields
    |> List.map (fun (f, t) -> f ^ ": " ^ fmt_ty t)
    |> String.concat ", "
  in
  "type " ^ fmt_type_params params ^ name ^ " = { " ^ field_s ^ " };"

let fmt_top_type_alias name params aliased =
  "type " ^ fmt_type_params params ^ name ^ " = " ^ fmt_ty aliased ^ ";"

let fmt_top_signature name params =
  let parts =
    params |> List.map (fun (p, t) -> p ^ ": " ^ fmt_ty t)
  in
  "signature " ^ name ^ " = (" ^ String.concat ", " parts ^ ");"

let fmt_top_view name region fields =
  let field_s =
    fields
    |> List.map (fun (f, t) -> f ^ ": " ^ fmt_ty t)
    |> String.concat ", "
  in
  "view " ^ name ^ "[" ^ region ^ "] { " ^ field_s ^ " };"

let fmt_top_extern name t =
  "extern fn " ^ name ^ ": " ^ fmt_ty t ^ ";"

let fmt_top_extern_type type_name =
  "extern type " ^ type_name ^ ";"

let fmt_top_drop name = "drop type " ^ name ^ ";"

(* Q-012: `sync`/`local` type markers format exactly like `drop` (same
   look-ahead split by the parser). See fuse_marker_decls below. *)
let marker_kw : top_decl -> string option = function
  | Top_drop _ -> Some "drop"
  | Top_sync _ -> Some "sync"
  | Top_local _ -> Some "local"
  | _ -> None

let fmt_top_decl d =
  match d with
  | Top_let (pat, value) -> Some (fmt_top_let pat value)
  | Top_let_rec bindings -> Some (fmt_top_let_rec bindings)
  | Top_type (name, params, variants) ->
    Some (fmt_top_type name params variants)
  | Top_record (name, params, fields) ->
    Some (fmt_top_record name params fields)
  | Top_type_alias (name, params, aliased) ->
    Some (fmt_top_type_alias name params aliased)
  | Top_signature (name, params) -> Some (fmt_top_signature name params)
  | Top_view (name, region, fields) ->
    Some (fmt_top_view name region fields)
  | Top_extern (name, t) -> Some (fmt_top_extern name t)
  | Top_extern_type type_name -> Some (fmt_top_extern_type type_name)
  | Top_drop name -> Some (fmt_top_drop name)
  | Top_sync name -> Some ("sync type " ^ name ^ ";")
  | Top_local name -> Some ("local type " ^ name ^ ";")
  (* These aliases are injected by the parser for `module M { ... }`
     blocks. They have no surface syntax of their own — skip them so the
     formatter doesn't emit invisible-to-the-user declarations. *)
  | Top_ctor_alias _ | Top_record_alias _ -> None

(* Phase 47: the parser splits `drop type Foo = { ... };` into two
   adjacent decls — `Top_drop "Foo"` then the type/record definition.
   We rebuild the combined `drop type Foo = ...;` here, so the emitted
   source is parseable (`drop type Foo;` alone is rejected by the
   parser, which requires `... = ...` after `type`). *)
let marker_combined kw marker_name nxt =
  match nxt with
  | Top_type (name, params, variants) when name = marker_name ->
    let var_s =
      variants
      |> List.map (fun (c, payload) ->
        match payload with
        | None -> c
        | Some t -> c ^ " of " ^ fmt_ty t)
      |> String.concat " | "
    in
    Some (kw ^ " type " ^ fmt_type_params params ^ name ^ " = " ^ var_s ^ ";")
  | Top_record (name, params, fields) when name = marker_name ->
    let field_s =
      fields
      |> List.map (fun (f, t) -> f ^ ": " ^ fmt_ty t)
      |> String.concat ", "
    in
    Some (kw ^ " type " ^ fmt_type_params params ^ name ^ " = { " ^ field_s ^ " };")
  | Top_type_alias (name, params, aliased) when name = marker_name ->
    Some (kw ^ " type " ^ fmt_type_params params ^ name ^ " = " ^ fmt_ty aliased ^ ";")
  | _ -> None

(* Walk decls and fuse `<marker> name :: Top_type/Top_record name :: ...`
   pairs into a single `<marker> type ...` line, for each of the drop / sync
   / local markers. Non-pairs pass through. *)
let marker_of_decl = function
  | Top_drop n | Top_sync n | Top_local n -> Some n
  | _ -> None

let rec fuse_drop_decls decls =
  match decls with
  | d :: nxt :: rest
    when (match marker_kw d, marker_of_decl d with
          | Some _, Some _ -> true | _ -> false) ->
    let kw = Option.get (marker_kw d) in
    let name = Option.get (marker_of_decl d) in
    (match marker_combined kw name nxt with
     | Some combined -> `Combined combined :: fuse_drop_decls rest
     | None -> `Decl d :: fuse_drop_decls (nxt :: rest))
  | d :: rest -> `Decl d :: fuse_drop_decls rest
  | [] -> []

(* ── Entry points ───────────────────────────────────────────────────── *)

let format_expr e = fmt_expr ~prec:prec_top ~ind:0 e

let format_program (prog : program) =
  let decls_s =
    prog.decls
    |> fuse_drop_decls
    |> List.filter_map (function
      | `Combined s -> Some s
      | `Decl d -> fmt_top_decl d)
    |> String.concat "\n\n"
  in
  let main_s =
    match prog.main.node with
    | Unit_lit -> ""   (* decls-only file *)
    | _ -> fmt_expr ~prec:prec_top ~ind:0 prog.main
  in
  match decls_s, main_s with
  | "", "" -> "()\n"
  | "", m -> m ^ "\n"
  | d, "" -> d ^ "\n"
  | d, m -> d ^ "\n\n" ^ m ^ "\n"
