(* What to say when the spelling belongs to another language.

   The compiler's semantic errors carry `help:` lines — 26 of them across the
   typer, the exhaustiveness checker and the pipeline — and its SYNTACTIC ones
   carried none, in either the lexer (10 kinds) or the parser (149 places that
   raise). That is the wrong way round: the syntax layer is the first one a
   newcomer hits, and some of its messages were not merely unhelpful but
   misleading — `var x = 1;` and `def f(n):` both came back as
   `trailing input`, and Python's `a and b` as
   `expected ';' or 'in' after let binding`, because `and` is Mere's keyword
   for a mutual-recursion group.

   WHY THIS IS A TABLE AND NOT 149 EDITS. A hint rides on the message, which is
   machinery that already exists; what was missing is the answer to "what is
   actually there?". The token at the failure position answers it, and the
   token list is in hand at the two entry points that parse. One table read
   from two places beats the same rule written at 149 raise sites, which is how
   one rule becomes 149 different rules.

   ⚠ EVERY ENTRY HAS A CORRECT USE TO PROTECT. `!=` is a comparison and `and`
   introduces a `let rec ... and` group; the table answers only for the
   position it was asked about, and never for those. The gate poisons both. *)

(* --- lexical: the character the lexer refused ---------------------------- *)

let for_char (c : char) : string option =
  match c with
  | '#' ->
    Some "help: comments are `//` — `#` starts nothing in Mere"
  (* `!=` never reaches here: the lexer takes it as one token, so a bare `!`
     is the one that was meant as negation. *)
  | '!' ->
    Some "help: negation is `not x`; `!=` is the comparison"
  | '$' ->
    Some "help: string interpolation is `\"x = {expr}\"` — no `$` before the brace"
  (* NOT ';': the lexer accepts it — it is a real token — so a `;` in the
     wrong place is a PARSE error, and its entry lives in the table below.
     Measured: `; let y = 2;` reaches `expected literal, identifier, or '('`. *)
  | '@' ->
    Some "help: Mere has no attributes; `@@` is low-precedence application"
  | _ -> None

(* --- syntactic: the token that was found, and its line ------------------- *)

(* A word that is a keyword in another language.

   ⚠ NOT `of`: `of` is Mere's own keyword (`type t = A | B of int`) and is
   measured 943 times across the four Mere repositories (989 .mere files). It
   reaches the parser as `T_of`, never as an identifier, so `case x of ...` is
   answered by `case`.

   The words that ARE spelled as identifiers here — `mut` `var` `val` `case` —
   are also real identifiers in that same corpus: `&mut R v`,
   `let var = list_sum ...`, `fn val ->`, `fn (case: int) -> case * 2`, and as
   TUPLE PATTERN binders, `let (val, j) = scan_octal ...` and
   `let (classes, var, prefix, r2) = parse_rescue_head r`. That is why the
   caller passes `bound`: a name this file binds is an identifier, and the
   table stays silent about it. *)
let foreign (n : string) : string option =
  match n with
  | "mut" | "var" | "val" ->
    Some "a binding is `let name = value;`, and it does not change"
  | "def" | "func" | "fun" | "function" ->
    Some "a function is `let name = fn (x: int) -> body;`"
  | "case" | "switch" ->
    Some "matching is `match x with | pat -> e | pat -> e`"
  | "elif" | "elsif" -> Some "chain with `else if`"
  | "return" -> Some "the last expression is the value; there is no `return`"
  | _ -> None

(* For the TYPER, which sees the same words as unbound variables once they get
   past the parser: `def f(n):` and `return n` both type-check as far as
   `unbound variable: def` / `unbound variable: return`. Same table, third
   reader. No `bound` argument is needed: an unbound name is by definition one
   this file does not bind. *)
let for_name (n : string) : string option = foreign n

(* The window around the failure.

   A spelling from another language is rarely one token: `x += 1` fails at `=`
   with `+` behind it, `=>` fails at `=` with `>` ahead, `var x = 1;` fails at
   `=` two tokens along, and `if true then 1 elif x < 0 then 2` fails at the
   SECOND `then`, four tokens past the `elif` that explains it. So `before` is
   the rest of the failing line, nearest first, and `after` the next tokens.

   `bound` answers "does this file bind this name?" — see `foreign`.

   The order of the rules is the design: the specific spellings answer first,
   and the generic "`=` is not `==`" is last, or it would swallow them. *)
let for_window ~(before : Lexer.token list) ~(cur : Lexer.token option)
    ~(after : Lexer.token list) ~(bound : string -> bool) : string option =
  let help what text = Some (Printf.sprintf "help: `%s` — %s" what text) in
  let compound op =
    help (op ^ "=")
      (Printf.sprintf
         "Mere has no compound assignment. Bindings do not change: \
          write `let y = x %s ...;`" op)
  in
  let window = (match cur with Some t -> [ t ] | None -> []) @ before in
  let first_foreign =
    List.find_map
      (function
        | Lexer.T_ident n when not (bound n) ->
          (match foreign n with Some text -> help n text | None -> None)
        | _ -> None)
      window
  in
  (* A brace is not by itself evidence: Mere writes `module M { ... }`,
     `region R { ... }` and record types with braces. What makes it evidence is
     a brace standing where `if` or `match` puts its arms. *)
  let block_word =
    List.exists
      (function
        | Lexer.T_if | Lexer.T_match | Lexer.T_then | Lexer.T_else -> true
        | _ -> false)
      window
  in
  let brace_in_window = List.exists (fun t -> t = Lexer.T_lbrace) window in
  let braces t =
    help t
      "Mere has no braces for blocks: `if c then a else b`, \
       `match x with | pat -> e`; a sequence is `let _ = a; b`"
  in
  match cur, before, after with
  (* `=>`: two tokens, and the parser stops at whichever it reaches first. *)
  | Some Lexer.T_eq, _, Lexer.T_gt :: _ | Some Lexer.T_gt, Lexer.T_eq :: _, _ ->
    help "=>" "the arrow is `->`"
  (* A compound assignment: the operator lexed on its own, then `=`. *)
  | Some Lexer.T_eq, Lexer.T_plus :: _, _ -> compound "+"
  | Some Lexer.T_eq, Lexer.T_minus :: _, _ -> compound "-"
  | Some Lexer.T_eq, Lexer.T_star :: _, _ -> compound "*"
  | Some Lexer.T_eq, Lexer.T_slash :: _, _ -> compound "/"
  (* A keyword from another language, wherever on the line it sits. *)
  | _ when first_foreign <> None -> first_foreign
  (* Failing AT an opening brace, or on a line where one stands in an arm. *)
  | Some Lexer.T_lbrace, _, _ -> braces "{"
  | _ when brace_in_window && block_word -> braces "{"
  | _, Lexer.T_rbrace :: _, _ when block_word -> braces "}"
  (* Python's `and` reaches the parser as Mere's rec-group keyword, and the
     message that came out named neither. *)
  | Some Lexer.T_and, _, _ ->
    help "and"
      "boolean `and` is `&&`; the keyword `and` joins a `let rec ... and ...` \
       group"
  | Some Lexer.T_semi, _, _ ->
    help ";" "a `;` ends a `let` or a declaration; it cannot begin one"
  (* Last, so that every spelling above answers first. *)
  | Some Lexer.T_eq, _, _ ->
    help "=" "comparison is `==`; a single `=` binds in a `let`"
  | _ -> None
