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

(* Q-154 slice 2: comments that are NOT in column 1 but are alone on their line.
   Column-1 ones are placed by `format_program`, above the declaration they were
   written above. These belong INSIDE a declaration -- 516 of the 654 in the
   examples corpus sit directly above a `let` -- and the tree has no field for
   them, so they are carried here and emitted where the layout passes their
   line: a run of `let`s is the one place the formatter emits its own indent and
   therefore the one place a comment can be put back without guessing.

   A watermark rather than a plain drain: a comment is only placed when the line
   it was written on lies BETWEEN the last thing emitted and the next one.
   Draining "everything before this line" would pull a comment written above the
   whole block down to the second binding, which is worse than the fallback of
   putting it above the declaration -- there it reads as describing the wrong
   binding rather than as being early. *)
let inline_pending : (int * string) list ref = ref []
let inline_mark = ref 0

(* Comments strictly between the watermark and `line`, in order, drained. *)
let take_inline_before (line : int) =
  let (before, rest) =
    List.partition (fun (l, _) -> l > !inline_mark && l < line) !inline_pending in
  inline_pending := rest;
  if before <> [] then inline_mark := line;
  List.map snd before

(* Q-154 slice 3: a comment with CODE in front of it. It has no node to hang
   from -- placing one in general needs the end of the thing it follows, which
   no `Loc.t` records -- but it does have a LINE, and the one construct this
   formatter emits line-for-line is a binding whose value fits on one line.
   375 of the 636 in the examples corpus sit on a line that starts with `let`.
   Those go back; the rest are still dropped, and the gate counts them so the
   number stays visible. *)
let trailing_pending : (int * string) list ref = ref []

(* The comment written at the end of `line`, if the layout emitted that line in
   one piece. `chunk` is what is about to be written: a newline in it means the
   line the comment was on is not the line being closed. *)
let take_trailing_on ?(same_file = true) (line : int) (chunk : string) =
  if not same_file then ""
  else if String.contains chunk '\n' then ""
  else
    match List.assoc_opt line !trailing_pending with
    | None -> ""
    | Some t ->
      trailing_pending := List.remove_assoc line !trailing_pending;
      "  " ^ t

(* Q-172: the module whose members are being printed, if any. A constructor
   declared inside `module M { }` is registered as `M.C`, and NEITHER an
   expression nor a pattern can spell that -- `M.C` is `unbound variable` in one
   and a parse error in the other, because the module injects an unqualified
   alias and that is the only way to write it. So the prefix comes off at the
   printing site, which is smaller and safer than rewriting the tree: only the
   two places that print a constructor name need to know. *)
let printing_module : string option ref = ref None

(* Every module name in the program. A constructor keeps its module prefix in
   the tree wherever it is USED, not just inside the block -- a top-level
   function matching on `Json.JStr` is how a file that imports one reads -- and
   the prefix is unspellable in both positions. The parser injects an
   unqualified alias for each module constructor, which is why the bare name
   works anywhere and why the source must have been written with it. *)
let known_modules : string list ref = ref []

(* Q-172 の残り: `dyn Trait e` はパーサが `Trait__pack e` に脱糖する。
   The parser desugars `dyn Trait e` into `App (Var "Trait__pack", e)` and does
   it unconditionally -- `keep_sugar` is a pipeline flag and the parser has never
   heard of it, which is why the `echo` fix (a pipeline pass) could be guarded
   and this one could not. The formatter recognises the shape instead.

   ⚠ Guarded by the TRAIT NAMES in the program, not by the suffix alone: a
   person may write a function called `X__pack`, and printing `dyn X` for it
   would be a different program. *)
let known_traits : string list ref = ref []

let unqualify_ctor (c : string) : string =
  let strip m =
    let p = m ^ "." in
    let lp = String.length p in
    if String.length c > lp && String.sub c 0 lp = p
    then Some (String.sub c lp (String.length c - lp)) else None
  in
  (* INSIDE the module only. Outside it, `M.Red` is valid in both an expression
     and a pattern, and is the ONLY way to tell two modules' `Red` apart -- the
     language reference says so and `examples/module_scoping.mere` is the demo.
     Stripping it everywhere made that file type-check against the wrong type. *)
  match !printing_module with Some m -> (match strip m with Some r -> r | None -> c) | None -> c

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
    (* Q-173: and the two the lexer can write that this could not. A carriage
       return went out as a RAW CR, which the lexer reads as a line break --
       `newline in string literal` on the way back in, and 69 of the 315
       example files could not be formatted twice because of it. Worse than
       that: formatting the output again DROPPED the byte, so `mere fmt -i` on
       a file with CRLF in it -- every Redis and HTTP string in contrib --
       silently changed what the program sends. A formatter that rewrites in
       place may not lose a byte.

       The set here has to be a subset of the lexer's escapes: n, t, r, 0,
       backslash, quote, and the two interpolation braces. Anything else stays
       a raw byte, which round-trips because the lexer copies unknown bytes
       through -- only these two are read as something else. *)
    | '\r' -> Buffer.add_string buf "\\r"
    | '\000' -> Buffer.add_string buf "\\0"
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
  | TyStr -> "str" | TyBytes -> "bytes" | TySimd F64x2 -> "f64x2" | TySimd U8x16 -> "u8x16" | TySimd F32x4 -> "f32x4" | TyUnit -> "unit"
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
  (* The sugar, printed back as the sugar. This is why it is an AST node and
     not a rewrite in the parser: the formatter runs on a tree that still has
     it (`Pipeline.parse_program ~keep_sugar:true`). *)
  | P_str_prefix (lit, name) -> escape_string_for_fmt lit ^ " <> " ^ name
  | P_unit -> "()"
  | P_constr (c, None) -> unqualify_ctor c
  | P_constr (c, Some sub) -> unqualify_ctor c ^ " " ^ fmt_pat_atom sub
  | P_tuple ps ->
    "(" ^ String.concat ", " (List.map fmt_pat ps) ^ ")"
  | P_record (name, fields) ->
    let parts = List.map (fun (f, p) -> f ^ " = " ^ fmt_pat p) fields in
    (* A record type declared inside a module is `M.Rect` in the tree, and the
       literal syntax cannot spell that either -- the parser injects an
       unqualified alias for the same reason it does for constructors. *)
    unqualify_ctor name ^ " { " ^ String.concat ", " parts ^ " }"
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
  | Let _ | Let_rec _ | If _ | Match _ | With _ | Region_block _ | Region_loop _ -> true
  | _ -> false

(* Does this expression end in a `Match` (possibly through Let / With /
   Region_block / If chains)? Used to decide whether we must wrap an
   arm body in parens to avoid the outer `match` stealing arms. *)
let rec trailing_match e =
  match e.node with
  | Match _ -> true
  | Let (_, _, body) | Let_rec (_, body) | With (_, _, body)
  | Region_block (_, body) | Region_loop (_, _, body) -> trailing_match body
  | If (_, t, el) -> trailing_match t || trailing_match el
  | _ -> false

let rec fmt_expr ~prec:p ~ind e =
  match e.node with
  (* ── literals & names ── *)
  | Int_lit n -> string_of_int n
  | Float_lit f ->
    (* OCaml's `string_of_float 3.0` returns `"3."`, but the Mere lexer
       requires `<digit>+.<digit>+` (so `3.` is lexed as `Int 3` followed
       by `.`). Always emit at least one fractional digit.

       v0.1.260: and it has to ROUND-TRIP. string_of_float keeps 12
       significant digits, which is enough for what could be written before
       exponent notation existed and not enough afterwards: formatting
       `1.7976931348623157e308` would quietly write a different number back.
       Take the shortest form that reads back as the same double. *)
    let round_trips s = try float_of_string s = f with _ -> false in
    let s =
      let d12 = string_of_float f in
      if round_trips d12 then d12
      else
        let p15 = Printf.sprintf "%.15g" f in
        if round_trips p15 then p15
        else
          let p16 = Printf.sprintf "%.16g" f in
          if round_trips p16 then p16 else Printf.sprintf "%.17g" f
    in
    (* `1e+308` / `3` need the fractional digit as much as `3.` does *)
    let has c = String.contains s c in
    if String.length s > 0 && s.[String.length s - 1] = '.' then s ^ "0"
    else if has '.' || has 'e' || has 'E' || has 'n' (* nan/inf *) then s
    else s ^ ".0"
  | Bool_lit true -> "true" | Bool_lit false -> "false"
  | Str_lit s -> escape_string_for_fmt s
  | Unit_lit -> "()"
  | Var n -> n
  (* `dyn Trait e`, back from the packer call the parser lowered it to. *)
  | App ({ node = Var n; _ }, arg)
    when (match String.index_opt n '_' with
          | _ ->
            let suf = "__pack" in
            let ls = String.length suf and ln = String.length n in
            ln > ls && String.sub n (ln - ls) ls = suf
            && List.mem (String.sub n 0 (ln - ls)) !known_traits) ->
    let t = String.sub n 0 (String.length n - String.length "__pack") in
    let s = "dyn " ^ t ^ " " ^ fmt_expr ~prec:(prec_app + 1) ~ind arg in
    wrap (p > prec_app) s
  | Constr ("Nil", None) -> "[]"
  | Constr (c, None) -> unqualify_ctor c
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
    (* ⚠ A list literal is fine as a FUNCTION argument (`sum [1, 2, 3]` runs)
       and not as a CONSTRUCTOR's: `A [1, 2]` and `A []` both come back as
       `constructor A requires an argument`, while `A ([])` and `A Nil` are
       fine. 24 example files came out of `mere fmt` as something the type
       checker then refused, because the formatter wrote the bare form a person
       would write. Parenthesised HERE and not in the literal itself -- doing it
       everywhere also parenthesised the function case, where the self-host
       formatter (which agrees with this one byte for byte) does not. *)
    let is_list_literal =
      match arg.node with
      | Constr ("Nil", None) -> true
      | Constr ("Cons", Some _) -> (try_match_list_literal arg) <> None
      | _ -> false
    in
    let arg_s = fmt_expr ~prec:(prec_app + 1) ~ind arg in
    let arg_s = if is_list_literal then parens arg_s else arg_s in
    let s = unqualify_ctor c ^ " " ^ arg_s in
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
unqualify_ctor name ^ " { " ^ String.concat ", " parts ^ " }"
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
  | Let _ | Let_rec _ | With _ | If _ | Match _ | Region_block _ | Region_loop _ ->
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
  | Let (_, _, _) ->
    (* A run of `let ... in` is written out as a run, rather than by recursing into
       the body and concatenating what comes back. Every level of the old version
       copied the whole remainder of the function into a new string, so formatting
       cost O(depth x size): 22 810 lines took 1.23s with 87 of 87 profile samples
       inside `Stdlib.(^)`. Each binding sits at the same indent as the one before,
       which is why the run can be flattened at all. *)
    let buf = Buffer.create 4096 in
    let rec run e =
      match e.node with
      | Let (pat, value, body) ->
        (* The buffer ends with this run's indent, which is what makes the
           comment land in the right column without computing one -- EXCEPT at
           indent 0, where this formatter writes function bodies flat. A comment
           emitted there would start in column 1, and column 1 is how the reader
           on the next pass tells "above a declaration" from "inside a body": the
           comment would be read back as the first kind and lifted out of the
           body it was written in. Formatting would not be idempotent, which is
           the property that keeps a comment from walking a line per run. Two
           spaces is the smallest thing that keeps the distinction. *)
        (* ...and only from the SECOND binding on. The buffer is created empty by
           `fmt_block`, so at the first `let` this code cannot know what column
           the caller left the cursor in -- after `-> ` in a match arm, after
           `fn (x: int) -> `, or at the start of a fresh line. Writing a comment
           there puts it after code, where the next pass reads it as a trailing
           comment and drops it: the run walked one binding down every time it
           was formatted. A non-empty buffer means this run wrote the indent
           itself and the cursor is at the start of a line. Comments the first
           binding would have taken fall through to `migrate_inline`, which puts
           them above the declaration -- moved, which this formatter has always
           preferred to lost. *)
        (* ⚠ Only a binding from the file being formatted. `Loc.line` counts
           within its OWN file, and `import` splices other files' declarations
           into this tree -- so a `let` at line 400 of a contrib file was
           consuming a comment written at line 152 of the entry file, and the
           comment landed in another function entirely. It looked like drift
           because formatting the OUTPUT (one file, all lines comparable) put it
           back in the right place. *)
        if Buffer.length buf > 0 && e.loc.Loc.file = None then begin
          let cind = if ind = 0 then "  " else indent ind in
          List.iter (fun t -> Buffer.add_string buf (cind ^ t ^ "\n" ^ indent ind))
            (take_inline_before e.loc.Loc.line)
        end;
        let value_s =
          if is_block value then
            "\n" ^ indent (ind + 1) ^ fmt_expr ~prec:prec_top ~ind:(ind + 1) value
          else
            " " ^ fmt_expr ~prec:prec_top ~ind value
        in
        let one_line = "let " ^ fmt_pat pat ^ " =" ^ value_s ^ " in" in
        Buffer.add_string buf
          (one_line
           ^ take_trailing_on ~same_file:(e.loc.Loc.file = None) e.loc.Loc.line one_line
           ^ "\n");
        Buffer.add_string buf (indent ind);
        run body
      | _ -> Buffer.add_string buf (fmt_expr ~prec:prec_top ~ind e)
    in
    run e;
    Buffer.contents buf
  | Let_rec (bindings, body) ->
    let parts =
      List.mapi (fun i (n, _, v) ->
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
      else fmt_if_multiline ~ind ~cond_loc:cond.loc cond_s then_ else_
    else
      fmt_if_multiline ~ind ~cond_loc:cond.loc cond_s then_ else_
  | Match (scrut, arms) ->
    (* Mere's `match` is greedy: an arm's body keeps consuming `| pat ->`
       as long as the parser sees them, regardless of indentation. So a
       trailing `Match` (or `Let-in-...-Match`) inside an arm body would
       steal the outer match's later arms when re-parsed. Wrap such
       bodies in `( ... )` to terminate them explicitly. *)
    let n_arms = List.length arms in
    let arm_s i (p, guard, body) =
      let g_s = match guard with
        | None -> ""
        | Some g -> " when " ^ fmt_expr ~prec:prec_top ~ind:(ind + 1) g
      in
      let needs_paren = trailing_match body in
      let body_s = fmt_expr ~prec:prec_top ~ind:(ind + 1) body in
      let body_s = if needs_paren then "(" ^ body_s ^ ")" else body_s in
      (* Q-154: the comment written at the end of this arm's line -- but ONLY
         where this formatter emits the newline itself, which is between arms.
         The LAST arm is followed by whatever encloses the match, and the `;`
         that ends the declaration is appended by the caller: attaching there
         put the terminator inside the comment and 13 example files stopped
         parsing. Emitting a comment is only safe where the line is known to
         end. *)
      let line = indent ind ^ "| " ^ fmt_pat p ^ g_s ^ " -> " ^ body_s in
      if i = n_arms - 1 then line
      else line ^ take_trailing_on ~same_file:(p.ploc.Loc.file = None) p.ploc.Loc.line line
    in
    "match " ^ fmt_expr ~prec:prec_top ~ind scrut ^ " with\n"
    ^ String.concat "\n" (List.mapi arm_s arms)
  | Region_block (name, body) ->
    "region " ^ name ^ " {\n"
    ^ indent (ind + 1) ^ fmt_expr ~prec:prec_top ~ind:(ind + 1) body ^ "\n"
    ^ indent ind ^ "}"
  | Region_loop (name, x, body) ->
    "region " ^ name ^ " loop " ^ x ^ " {\n"
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
and fmt_if_multiline ~ind ~cond_loc cond_s then_ else_ =
  let then_body = fmt_expr ~prec:prec_top ~ind:(ind + 1) then_ in
  (* Q-154. The comment on `if c then  // why` is keyed on the CONDITION's line:
     the body goes on the NEXT line, so asking for the body's line found nothing
     and 42 of these were dropped. Attaching here is safe by the same rule as
     everywhere else -- the newline after `then` is one THIS function emits, so
     nothing a caller appends can end up inside the comment.

     ⚠ When the body starts on the same line as `then`, the source wrote the
     comment AFTER the body, and the body's own site (below, and in
     `fmt_else_chain`) is the one that should claim it. *)
  let on_then =
    if cond_loc.Loc.line = then_.loc.Loc.line then ""
    else take_trailing_on ~same_file:(cond_loc.Loc.file = None)
           cond_loc.Loc.line cond_s
  in
  let head =
    "if " ^ cond_s ^ " then" ^ on_then ^ "\n" ^ indent (ind + 1) ^ then_body
  in
  let tail = fmt_else_chain ~ind else_ in
  head ^ "\n" ^ tail

and fmt_else_chain ~ind else_ =
  match else_.node with
  | If (cond, then_, else_inner) ->
    let cond_s = fmt_expr ~prec:prec_top ~ind cond in
    let then_body = fmt_expr ~prec:prec_top ~ind:(ind + 1) then_ in
    (* Same as `fmt_if_multiline`: the comment sits on the `else if ... then`
       line, which is the CONDITION's line, not the body's. *)
    let on_then =
      if cond.loc.Loc.line = then_.loc.Loc.line then ""
      else take_trailing_on ~same_file:(cond.loc.Loc.file = None)
             cond.loc.Loc.line cond_s
    in
    let head =
      indent ind ^ "else if " ^ cond_s ^ " then" ^ on_then ^ "\n"
      ^ indent (ind + 1) ^ then_body
    in
    (* This one IS safe: the chain emits the newline after it. *)
    let head = head ^ take_trailing_on ~same_file:(then_.loc.Loc.file = None)
                        then_.loc.Loc.line then_body in
    head ^ "\n" ^ fmt_else_chain ~ind else_inner
  | _ ->
    let body = fmt_expr ~prec:prec_top ~ind:(ind + 1) else_ in
    (* ⚠ Nothing is attached here. The final `else` body is the end of the whole
       `if`, and what follows it on the line -- the `;` that ends a declaration,
       a closing paren -- is appended by the caller. See the note in the match
       arm above. *)
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
    List.mapi (fun i (n, _, v) ->
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

(* the same shape for a name defined LATER in Mere rather than outside it *)
let fmt_top_forward name t =
  "let fn " ^ name ^ ": " ^ fmt_ty t ^ ";"

let fmt_top_extern_type type_name =
  "extern type " ^ type_name ^ ";"

let fmt_top_trait name param methods defaults supers =
  let super_s =
    match supers with
    | [] -> ""
    | _ ->
      " : "
      ^ String.concat ", "
          (List.map (fun s -> s ^ " '" ^ param) supers)
  in
  let m_s =
    methods
    |> List.map (fun (m, t) ->
      match List.assoc_opt m defaults with
      | Some body ->
        indent 1 ^ m ^ " : " ^ fmt_ty t ^ " = "
        ^ fmt_expr ~prec:prec_top ~ind:1 body ^ ";"
      | None -> indent 1 ^ m ^ " : " ^ fmt_ty t ^ ";")
    |> String.concat "\n"
  in
  "trait " ^ name ^ " '" ^ param ^ super_s ^ " {\n" ^ m_s ^ "\n}"

let fmt_top_impl name target methods =
  let m_s =
    methods
    |> List.map (fun (m, v) ->
         indent 1 ^ m ^ " = " ^ fmt_expr ~prec:prec_top ~ind:1 v ^ ";")
    |> String.concat "\n"
  in
  "impl " ^ name ^ " " ^ fmt_ty target ^ " {\n" ^ m_s ^ "\n}"

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
  | Top_forward (name, t, _) -> Some (fmt_top_forward name t)
  | Top_extern_type type_name -> Some (fmt_top_extern_type type_name)
  | Top_drop name -> Some (fmt_top_drop name)
  | Top_sync name -> Some ("sync type " ^ name ^ ";")
  | Top_local name -> Some ("local type " ^ name ^ ";")
  (* These aliases are injected by the parser for `module M { ... }`
     blocks. They have no surface syntax of their own — skip them so the
     formatter doesn't emit invisible-to-the-user declarations. *)
  | Top_ctor_alias _ | Top_record_alias _ -> None
  | Top_trait (name, param, methods, defaults, supers) ->
    Some (fmt_top_trait name param methods defaults supers)
  | Top_impl (name, target, methods) -> Some (fmt_top_impl name target methods)

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

(* Q-172: put `module M { ... }` back together.

   The parser FLATTENS a module: its members become top-level bindings called
   `M.foo`, and that is what this formatter printed -- `let Bignum.base = ...`,
   which is not syntax. 21 of the 315 example files came out of `mere fmt` as
   something the compiler could not read back, and `mere fmt -i` writes in
   place.

   Only the BINDING NAME has to lose the prefix. A qualified self-reference is
   valid inside the module it names (the parser registers the module before
   parsing its body for exactly that reason), so the bodies can be printed
   unchanged and `M.bar` inside `module M` still resolves. That is what makes
   this a grouping pass rather than a tree rewrite.

   Types declared inside a module are not grouped: the parser registers them
   globally and unqualified on purpose (see the language reference), so the
   declaration carries no trace of the block it was written in and printing it
   outside is the same program. *)
let module_of_name (modules : string list) (n : string) : string option =
  List.fold_left (fun best m ->
    let p = m ^ "." in
    let lp = String.length p in
    if String.length n > lp && String.sub n 0 lp = p then
      match best with
      | Some b when String.length b >= String.length m -> best
      | _ -> Some m
    else best) None modules

let decl_member_name (d : top_decl) : string option =
  match d with
  | Top_let ({ pnode = P_var n; _ }, _) -> Some n
  | Top_let_rec ((n, _, _) :: _) -> Some n
  | _ -> None

let strip_prefix (m : string) (n : string) : string =
  let lp = String.length m + 1 in
  if String.length n > lp then String.sub n lp (String.length n - lp) else n

let unqualify_decl (m : string) (d : top_decl) : top_decl =
  match d with
  | Top_let ({ pnode = P_var n; _ } as pat, v) ->
    Top_let ({ pat with pnode = P_var (strip_prefix m n) }, v)
  | Top_let_rec bs -> Top_let_rec (List.map (fun (n, l, v) -> (strip_prefix m n, l, v)) bs)
  | other -> other

(* ── Entry points ───────────────────────────────────────────────────── *)

let format_expr e = fmt_expr ~prec:prec_top ~ind:0 e

(* Where a declaration starts, for placing the comments written above it.

   Only three top-level forms carry a position at all -- a `top_decl` is mostly
   a name and a shape, and `Top_type` has nowhere to put one. `decl_line` is
   supplied by the caller (`Pipeline.format_source`), which can also consult the
   parser's type table; a declaration it cannot place simply does not collect
   the comments above it, and they go to the next one that can be placed.
   Losing a comment is not an option; moving one down is the fallback. *)
let default_decl_line (d : top_decl) : int option =
  let ok (l : Loc.t) = if l.Loc.line > 0 && l.Loc.file = None then Some l.Loc.line else None in
  match d with
  | Top_let (pat, _) -> ok pat.ploc
  | Top_let_rec ((_, _, (v : expr)) :: _) -> ok v.loc
  | Top_forward (_, _, l) -> ok l
  | _ -> None

(* `comments` is (line, text) for the comment blocks that start in column 1,
   in source order. Everything before the next placeable declaration is
   printed above it, keeping the blank line the joiner already puts between
   declarations.

   `inline` is the same for comments that are alone on their line but indented:
   they belong inside a declaration, and `fmt_block`'s run of `let`s puts them
   back. `trailing` is for the ones with code in front of them, which go back
   only where the layout emits their line in one piece.

   WHAT IS STILL DROPPED, and why it is not an oversight: a trailing comment on
   a line this formatter does not emit whole -- a binding whose value goes
   multi-line, a line that ends in the `;` a CALLER appends, an expression this
   formatter re-breaks so that the line it was written on does not exist in the
   output. Putting one back needs the end of the node it follows, and a `Loc.t`
   records where a token STARTS. 53 lines in the examples corpus;
   `scripts/fmt_comments_check.sh` counts them and holds the ceiling. *)
let format_program ?(comments : (int * string) list = [])
    ?(inline : (int * string) list = [])
    ?(trailing : (int * string) list = [])
    ?(modules : string list = [])
    ?(private_members : string list = [])
    ?(pub_members : string list = [])
    (* Q-174: (index, path as written, declarations spliced, source line) for
       every `import` the entry file had. Empty means "print what is here",
       which is what every caller other than `mere fmt` wants. *)
    ?(imports : (int * string * int * int) list = [])
    ?(decl_line : (top_decl -> int option) = default_decl_line) (prog : program) =
  let pending = ref comments in
  known_modules := modules;
  known_traits :=
    List.filter_map (function Top_trait (n, _, _, _, _) -> Some n | _ -> None) prog.decls;
  inline_pending := List.sort (fun (a, _) (b, _) -> compare a b) inline;
  inline_mark := 0;
  trailing_pending := trailing;
  (* Everything written above `line`, in order, drained. *)
  let take_before (line : int) =
    let (before, rest) = List.partition (fun (l, _) -> l < line) !pending in
    pending := rest;
    List.map snd before
  in
  (* An indented comment written ABOVE a declaration cannot be placed inside it,
     because the run that would place it starts later. It joins the column-1
     stream instead and is printed above the declaration -- the fallback this
     formatter has always taken: moved, never dropped. *)
  let migrate_inline (l : int) =
    let (before, rest) = List.partition (fun (cl, _) -> cl < l) !inline_pending in
    inline_pending := rest;
    if before <> [] then
      pending := List.sort (fun (a, _) (b, _) -> compare a b) (!pending @ before)
  in
  let with_comments (line : int option) (body : string) =
    match line with
    | None -> body
    | Some l ->
      migrate_inline l;
      inline_mark := l;
      (* A declaration that came out on one line can carry the comment written
         at the end of the line it started on. A multi-line one cannot: the line
         being closed is not the line the comment was on. *)
      let body = body ^ take_trailing_on l body in
      (match take_before l with
       | [] -> body
       | cs -> String.concat "\n" cs ^ "\n" ^ body)
  in
  (* Q-172: consecutive members of one module come back as one block. The run
     has to be CONSECUTIVE -- a declaration from outside the module in the
     middle of it means the source had two blocks, and printing two is right. *)
  (* Which module a declaration belongs to. For a binding it is the prefix on
     its own name; for a TYPE the name carries nothing, so the answer comes from
     the aliases the parser injects -- `Top_ctor_alias ("Traffic.Red", "Red")`
     says where `Red` was declared. Putting the type back inside its block is
     what makes two modules' `Red` distinguishable again: printed at top level
     they collide, and the file that demonstrates module scoping stopped
     type-checking. *)
  (* ⚠ A bare constructor name can belong to MORE THAN ONE module -- that is
     what module scoping is for, and `examples/module_scoping.mere` has `Red` in
     two of them. Keeping only the last owner put `type Light` inside `Mood`.
     So the owners are collected as a list and a type is placed by the first
     constructor that names exactly one module. *)
  let ctor_owner : (string, string list) Hashtbl.t = Hashtbl.create 32 in
  List.iter (fun d ->
    match d with
    | Top_ctor_alias (q, bare) | Top_record_alias (q, bare) ->
      (match module_of_name modules q with
       | Some m ->
         let prev = match Hashtbl.find_opt ctor_owner bare with Some l -> l | None -> [] in
         if not (List.mem m prev) then Hashtbl.replace ctor_owner bare (m :: prev)
       | None -> ())
    | _ -> ()) prog.decls;
  let sole_owner (c : string) : string option =
    match Hashtbl.find_opt ctor_owner c with Some [ m ] -> Some m | _ -> None
  in
  let type_owner (d : top_decl) : string option =
    match d with
    | Top_type (_, _, variants) ->
      List.fold_left (fun acc (c, _) ->
        match acc with Some _ -> acc | None -> sole_owner c) None variants
    | Top_record (name, _, _) -> sole_owner name
    | _ -> None
  in
  let group_modules (ds : top_decl list) : [ `One of top_decl | `Mod of string * top_decl list ] list =
    let rec go acc cur ds =
      let flush acc = match cur with
        | Some (m, rev) -> `Mod (m, List.rev rev) :: acc
        | None -> acc
      in
      match ds with
      | [] -> List.rev (flush acc)
      | d :: rest ->
        let owner =
          match decl_member_name d with
          | Some n -> module_of_name modules n
          | None -> type_owner d
        in
        (match owner, cur with
         | Some m, Some (m', rev) when m = m' -> go acc (Some (m, d :: rev)) rest
         | Some m, _ -> go (flush acc) (Some (m, [d])) rest
         | None, _ -> go (`One d :: flush acc) None rest)
    in
    go [] None ds
  in
  (* A module that marked nothing exports everything and its members carry no
     `pub`; one that marked anything has its unmarked members in the parser's
     private table, so the rest were marked. Recovering it this way means the
     formatter does not need the parser to keep a separate list. *)
  (* Marked at all, not merely "has something private": a module that marked
     every member has nothing in the private table, and printing it back
     unmarked would export the next member somebody adds. *)
  let module_marks_something m =
    List.exists (fun n -> module_of_name modules n = Some m) private_members
    || List.exists (fun n -> module_of_name modules n = Some m) pub_members
  in
  let fmt_module (m : string) (members : top_decl list) : string =
    let marks = module_marks_something m in
    printing_module := Some m;
    let restore () = printing_module := None in
    let body =
      List.filter_map (fun d ->
        match fmt_top_decl (unqualify_decl m d) with
        | None -> None
        | Some text ->
          let is_pub =
            marks && (match decl_member_name d with
                      | Some n -> not (List.mem n private_members)
                      | None -> false)
          in
          Some (if is_pub then "pub " ^ text else text))
        members
    in
    restore ();
    (* A nested module flattens to `A.B.foo`, and the longest prefix that names
       a module is `A.B` -- which is not a module NAME. `module A.B { }` does
       not parse, so the chain comes back as the nesting it was written as. *)
    let parts = String.split_on_char '.' m in
    let rec wrap ps inner =
      match ps with
      | [] -> inner
      | p :: rest ->
        let indented =
          String.concat "\n"
            (List.map (fun l -> if l = "" then l else "  " ^ l)
               (String.split_on_char '\n' (wrap rest inner)))
        in
        "module " ^ p ^ " {\n" ^ indented ^ "\n}"
    in
    wrap parts (String.concat "\n" body)
  in
  (* Q-174: put the `import` lines back and take the declarations they spliced
     OUT. Without this, `mere fmt` printed the imported file's declarations as
     if this file had written them -- and `mere fmt -i` saved that over the
     source, deleting the import and copying somebody else's code in.

     The run an import contributed is CONTIGUOUS and its length was recorded at
     splice time, so undoing it is exact: no guessing from positions, and a
     nested import (A imports B) is already inside A's count. *)
  let render_run (ds : top_decl list) : string list =
    ds
    |> group_modules
    (* ⚠ `fuse_drop_decls` pairs a marker declaration with the one after it, so
       it has to see a RUN and not one declaration at a time -- calling it per
       decl would silently stop fusing every `drop type` in the file. *)
    |> (fun items ->
         let rec go acc pending items =
           let flush acc = if pending = [] then acc
                           else List.rev_append (fuse_drop_decls (List.rev pending)) acc in
           match items with
           | [] -> List.rev (flush acc)
           | `Mod (m, members) :: rest ->
             go (`Combined (fmt_module m members) :: flush acc) [] rest
           | `One d :: rest -> go acc (d :: pending) rest
         in
         go [] [] items)
    |> List.filter_map (function
      (* A fused pair has no single declaration to ask, so it takes whatever is
         pending: the comments were written above it either way. *)
      | `Combined s -> Some (with_comments (Some max_int) s)
      | `Decl d ->
        (match fmt_top_decl d with
         | None -> None
         | Some body -> Some (with_comments (decl_line d) body)))
  in
  let decls_s =
    let imps = List.sort (fun (a, _, _, _) (b, _, _, _) -> compare a b) imports in
    let rec drop k l = if k <= 0 then l else match l with [] -> [] | _ :: t -> drop (k - 1) t in
    (* Walk the declaration list and the import list together. `i` is the index
       in the list the entry file produced, which is the index the parser
       recorded against. *)
    let out = ref [] and cur = ref [] in
    let flush () =
      if !cur <> [] then begin
        out := List.rev_append (render_run (List.rev !cur)) !out;
        cur := []
      end
    in
    let rec go i decls imps =
      match imps with
      | (idx, path, cnt, line) :: rest when idx <= i ->
        flush ();
        (* Comments written above the `import` belong above it, which is why the
           line is recorded too -- otherwise they migrate down to whatever
           declaration follows. *)
        out := with_comments (Some line)
                 ("import " ^ escape_string_for_fmt path ^ ";") :: !out;
        go (i + cnt) (drop cnt decls) rest
      | _ ->
        (match decls with
         | [] -> flush ()
         | d :: t -> cur := d :: !cur; go (i + 1) t imps)
    in
    go 0 prog.decls imps;
    String.concat "\n\n" (List.rev !out)
  in
  let main_s =
    match prog.main.node with
    | Unit_lit ->
      (* A decls-only file still has comments after the last declaration. *)
      migrate_inline max_int;
      String.concat "\n" (take_before max_int)
    | _ ->
      migrate_inline (max 1 prog.main.loc.Loc.line);
      inline_mark := max 1 prog.main.loc.Loc.line;
      let above = take_before (max 1 prog.main.loc.Loc.line) in
      let body = fmt_expr ~prec:prec_top ~ind:0 prog.main in
      let trailing = take_before max_int in
      (* Anything the run never reached -- a comment inside a construct this
         slice does not place, an `if` arm or a match -- still has to come out
         somewhere. Last, in source order, rather than lost. *)
      let left = List.map snd (List.sort (fun (a, _) (b, _) -> compare a b) !inline_pending) in
      inline_pending := [];
      String.concat "\n"
        (above @ [ body ] @ trailing @ left)
  in
  match decls_s, main_s with
  | "", "" -> "()\n"
  | "", m -> m ^ "\n"
  | d, "" -> d ^ "\n"
  | d, m -> d ^ "\n\n" ^ m ^ "\n"
