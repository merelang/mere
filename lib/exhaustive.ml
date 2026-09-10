(* Exhaustiveness check for `match` expressions.

   Phase 1 scope: report missing variants for sum-type scrutinees, and
   missing true/false for bool scrutinees.  Other types (int, str, float,
   tuple, record) are not checked yet — they require a wildcard or var arm
   to be safe in any case.

   Findings are returned as data (`finding`), and `classify` splits them into
   the ones that stop a build and the ones that do not. A finding carries the
   arm to add, because the edit that provokes this check is almost always the
   same one — a case added to a type, and a `match` on it left as it was — and
   the next thing anyone does with the message is write the arm it names. *)

(* A missing case, and what to write for it.

   `f_error` is the difference between a finding that names a case and one that
   only suspects there is one. Naming `Triangle _` is a fact the checker can
   prove from the type declaration, so it stops the build; "no wildcard arm for
   int" is this file's own approximation (see `check_match`'s last arm) and
   stays a warning, because turning it into an error would demand a `_` arm
   everywhere rather than name anything. *)
type finding = {
  f_loc : Loc.t;
  f_msg : string;         (* the headline, without the position in it *)
  f_hint : string list;   (* `help:` / `note:` lines, rendered under the frame *)
  f_error : bool;
}

(* Variant registry: variant-type name -> full list of (cname, payload).
   Populated by Typer.register_type (one-way dependency: Typer -> Exhaustive). *)
let type_variants : (string, (string * Ast.ty option) list) Hashtbl.t =
  Hashtbl.create 16

let register_variants name variants =
  Hashtbl.replace type_variants name variants

(* A pattern is "total" if it covers all values of any type at the top level —
   wildcards, variable patterns, unit literals, and as-patterns / or-patterns
   built from totals.

   Phase 2 extension (2026-06-22): tuple / record patterns are total when
   all sub-patterns are total (`(a, b)` covers every pair; `{ x = a, y = b }`
   covers every record).  This eliminates false-positive "no wildcard arm"
   warnings for the common destructure form. *)
let rec is_total_pattern (p : Ast.pattern) =
  match p.pnode with
  | Ast.P_wild | Ast.P_var _ -> true
  | Ast.P_unit -> true   (* unit has only one value *)
  | Ast.P_as (inner, _) -> is_total_pattern inner
  | Ast.P_or (p1, p2) -> is_total_pattern p1 || is_total_pattern p2
  | Ast.P_tuple ps -> List.for_all is_total_pattern ps
  | Ast.P_record (_, fields) ->
    List.for_all (fun (_, p) -> is_total_pattern p) fields
  | _ -> false

(* For variant types: collect which constructor names appear at the top of
   each arm's pattern.  As-patterns are stripped; or-patterns are flattened. *)
(* A constructor written inside a `module M { ... }` is parsed as the
   module-qualified `M.Ctor` (aliased to the bare `Ctor`), but the variant
   registry keys on the bare name. Normalize to the last dotted segment so a
   match inside a module isn't wrongly reported non-exhaustive. Constructor
   names never contain a `.` except this module qualification. *)
let bare_ctor (name : string) : string =
  match String.rindex_opt name '.' with
  | Some i -> String.sub name (i + 1) (String.length name - i - 1)
  | None -> name

let rec top_level_constructors (p : Ast.pattern) : string list =
  match p.pnode with
  | Ast.P_constr (name, _) -> [bare_ctor name]
  | Ast.P_as (inner, _) -> top_level_constructors inner
  | Ast.P_or (p1, p2) ->
    top_level_constructors p1 @ top_level_constructors p2
  | _ -> []

(* For bool scrutinees: which bool literals are at the top of each pattern? *)
let rec top_level_bools (p : Ast.pattern) : bool list =
  match p.pnode with
  | Ast.P_bool b -> [b]
  | Ast.P_as (inner, _) -> top_level_bools inner
  | Ast.P_or (p1, p2) -> top_level_bools p1 @ top_level_bools p2
  | _ -> []

(* --- v0.1.32 (Phase 3): product-space check for tuple scrutinees ---

   `match (h1, h2) with (HEmpty, _) | (_, HEmpty) | (HNode _, HNode _)` is
   exhaustive, but no single arm is total, so the old checker warned
   "no wildcard arm for tuple" (found by the generic pairing heap's merge).
   When every tuple component ranges over a FINITE space (bool / unit /
   registered variant type) and the product is small, enumerate the
   constructor combinations and check each is covered by some arm. *)

let rec flatten_or (p : Ast.pattern) : Ast.pattern list =
  match p.pnode with
  | Ast.P_or (a, b) -> flatten_or a @ flatten_or b
  | Ast.P_as (inner, _) -> flatten_or inner
  | _ -> [p]

(* One point of a component's finite space. `bool` on CCtor = has payload
   (for printing the missing example as `HNode _`). *)
type comp_case = CBool of bool | CCtor of string * bool | CUnit

let comp_space (t : Ast.ty) : comp_case list option =
  match Ast.walk t with
  | Ast.TyBool -> Some [CBool true; CBool false]
  | Ast.TyUnit -> Some [CUnit]
  | Ast.TyCon (n, _) when Hashtbl.mem type_variants n ->
    Some (List.map (fun (c, payload) -> CCtor (c, payload <> None))
            (Hashtbl.find type_variants n))
  | _ -> None

(* Does sub-pattern `p` cover every value belonging to case `c`?
   A constructor pattern covers its case only when the payload pattern is
   irrefutable — a nested refutable payload is judged conservatively. *)
let rec comp_covers (p : Ast.pattern) (c : comp_case) : bool =
  match p.pnode with
  | Ast.P_as (inner, _) -> comp_covers inner c
  | Ast.P_or (a, b) -> comp_covers a c || comp_covers b c
  | _ when is_total_pattern p -> true
  | Ast.P_bool b -> (match c with CBool v -> b = v | _ -> false)
  | Ast.P_constr (name, sub) ->
    (match c with
     | CCtor (cname, _) ->
       name = cname
       && (match sub with None -> true | Some sp -> is_total_pattern sp)
     | _ -> false)
  | _ -> false

let show_comp_case = function
  | CBool b -> string_of_bool b
  | CCtor (c, true) -> c ^ " _"
  | CCtor (c, false) -> c
  | CUnit -> "()"

let max_product_combos = 1024

(* How a missing constructor is named in the headline: `Some _` rather than
   `Some`, so the payload is visible without going to the declaration. *)
let show_ctor (cname, payload) =
  match payload with None -> cname | Some _ -> cname ^ " _"

(* The arm to write for a missing constructor, as Mere source. A tuple payload
   is destructured positionally (`Triangle of float * float` takes
   `| Triangle (a1, a2) ->`), which is the form the language reference uses and
   the only one that binds every component. *)
let arm_of_ctor (cname, payload) =
  match payload with
  | None -> Printf.sprintf "| %s -> ..." cname
  | Some t ->
    (match Ast.walk t with
     | Ast.TyTuple ts ->
       let names = List.mapi (fun i _ -> Printf.sprintf "a%d" (i + 1)) ts in
       Printf.sprintf "| %s (%s) -> ..." cname (String.concat ", " names)
     | _ -> Printf.sprintf "| %s a -> ..." cname)

(* One finding per match, listing every case it is missing.

   Not one per case: the fix is a single edit to a single `match`, and a match
   missing seven constructors used to be seven separate lines that had to be
   read together to find out that. The headline names them all; the hint spells
   out an arm for each, and then the hole — `fail` is typed `'a`, so an arm
   returning it satisfies any match — that lets the rest of the file keep
   compiling while they are written. *)
let missing_finding loc (shown : string list) (arms : string list) =
  { f_loc = loc;
    f_msg =
      Printf.sprintf "non-exhaustive match (missing %s)"
        (String.concat ", " shown);
    f_hint =
      List.map (fun a -> "help: " ^ a) arms
      @ [ "note: or `| _ -> fail \"todo\"` to compile before writing them" ];
    f_error = true }

(* Check a Match expression.  Returns the findings for it (empty if the match
   is judged exhaustive).  `loc` is the location of the match expression for
   error reporting. *)
let check_match (loc : Loc.t)
                (scrut_ty : Ast.ty)
                (arms : (Ast.pattern * Ast.expr option * Ast.expr) list)
              : finding list =
  (* An arm with a guard cannot be relied upon to cover its pattern fully —
     the guard might be false at runtime.  So for coverage purposes we only
     consider arms with `guard = None`. *)
  let unguarded_arms =
    List.filter_map (fun (p, g, _) ->
      if g = None then Some p else None
    ) arms
  in
  let has_total = List.exists is_total_pattern unguarded_arms in
  if has_total then []
  else
    match Ast.walk scrut_ty with
    | Ast.TyBool ->
      let seen = List.concat_map top_level_bools unguarded_arms in
      let missing = List.filter (fun b -> not (List.mem b seen)) [true; false] in
      if missing = [] then []
      else
        [ missing_finding loc
            (List.map string_of_bool missing)
            (List.map (fun b ->
               Printf.sprintf "| %s -> ..." (string_of_bool b)) missing) ]
    | Ast.TyCon (type_name, _)
      when Hashtbl.mem type_variants type_name ->
      let variants = Hashtbl.find type_variants type_name in
      let seen = List.concat_map top_level_constructors unguarded_arms in
      let missing =
        List.filter (fun (vname, _) -> not (List.mem vname seen)) variants
      in
      (* The registry keys on the BARE type name, so two modules that each
         declare `type t` share one entry and the second declaration overwrites
         the first. A match over the first type was then judged against the
         second's constructors, and reported `Z` missing from a match covering
         `X | Y` completely — harmless while this was a warning nobody read,
         and a rejected correct program once it stopped being one.

         An arm naming a constructor the entry does not have is the evidence
         that the entry is about a different type, so nothing is reported: a
         case named out of the wrong declaration is worse than no case at all.

         What this does NOT catch is the collision where one type's
         constructors are a subset of the other's (`X | Y` against
         `X | Y | Z`) — every arm is then found in the entry and the extra
         constructor is reported as missing. Telling those apart needs the
         registry keyed on the qualified name, which is a change to what the
         typer calls a type rather than to this file. `test_basic.ml` holds
         both cases, so the day that lands, the second one starts failing. *)
      let entry_describes_scrutinee =
        List.for_all (fun c -> List.mem_assoc c variants) seen
      in
      if missing = [] || not entry_describes_scrutinee then []
      else
        [ missing_finding loc
            (List.map show_ctor missing)
            (List.map arm_of_ctor missing) ]
    | Ast.TyTuple ts
      when (let spaces = List.map comp_space ts in
            List.for_all (fun s -> s <> None) spaces
            && List.fold_left
                 (fun acc s -> acc * List.length (Option.get s)) 1 spaces
               <= max_product_combos
            && List.exists (fun p ->
                 List.exists (fun p' ->
                   match p'.Ast.pnode with
                   | Ast.P_tuple ps -> List.length ps = List.length ts
                   | _ -> false) (flatten_or p))
                 unguarded_arms) ->
      (* Every component ranges over a small finite space: enumerate the
         product and check each combination against the tuple arms. *)
      let spaces = List.map (fun t -> Option.get (comp_space t)) ts in
      let tuple_arms =
        List.concat_map flatten_or unguarded_arms
        |> List.filter_map (fun p ->
             match p.Ast.pnode with
             | Ast.P_tuple ps when List.length ps = List.length ts -> Some ps
             | _ -> None)
      in
      let rec combos = function
        | [] -> [[]]
        | s :: rest ->
          List.concat_map (fun c ->
            List.map (fun r -> c :: r) (combos rest)) s
      in
      let missing =
        List.filter (fun combo ->
          not (List.exists (fun ps -> List.for_all2 comp_covers ps combo)
                 tuple_arms))
          (combos spaces)
      in
      (match missing with
       | [] -> []
       | combo :: _ ->
         (* One combination, by example: the product can be large, and a
            person who writes the arm for this one is told about the next. *)
         let shown =
           Printf.sprintf "(%s)"
             (String.concat ", " (List.map show_comp_case combo))
         in
         [ missing_finding loc [shown] [Printf.sprintf "| %s -> ..." shown] ])
    | other_ty ->
      (* Phase 2: for other types (int, str, float, tuple, record, etc.),
         patterns are typically exhaustive only with a wildcard arm.  When
         the scrutinee type is identifiable, mention it in the warning so
         the user knows what kind of value might be uncovered. *)
      let ty_hint =
        match other_ty with
        | Ast.TyInt -> " for int"
        | Ast.TyStr -> " for str"
        | Ast.TyFloat -> " for float"
        | Ast.TyTuple _ -> " for tuple"
        | Ast.TyCon (n, _) -> " for " ^ n
        | _ -> ""
      in
      [ { f_loc = loc;
          f_msg =
            Printf.sprintf "non-exhaustive match (no wildcard arm%s)" ty_hint;
          f_hint = [ "help: | _ -> ..." ];
          (* Not an error: this arm is reached because the checker does not
             know the scrutinee's cases, so it cannot tell a match that is
             missing one from a match over a type it has no model of. *)
          f_error = false } ]

(* Phase 21.2: deferred matches.  Storing the triple lets us re-walk the
   scrutinee type AFTER all typer unification has completed, so a Match
   whose scrut_ty is initially a fresh tyvar (e.g., the param `xs` of a
   poly let-rec, only later unified to `'a list` by the patterns) is
   judged against its final concrete type rather than an unresolved one.

   Using a ref is pragmatic — threading an accumulator through every Typer
   entry point would be invasive. *)
let deferred : (Loc.t * Ast.ty * (Ast.pattern * Ast.expr option * Ast.expr) list) list ref =
  ref []

let reset () = deferred := []

let record_match loc scrut_ty arms =
  deferred := (loc, scrut_ty, arms) :: !deferred

(* Every finding, in source order, drained.

   The checks run here rather than where the match was visited because only now
   have the scrutinee types walked. The list is de-duplicated: type inference
   visits a declaration's body once as a declaration and again as part of the
   desugared program, so a match inside one is recorded twice, and the same
   complaint shown twice is a bug report waiting to happen. *)
let all_findings () : finding list =
  let fs =
    List.concat_map (fun (loc, scrut_ty, arms) -> check_match loc scrut_ty arms)
      (List.rev !deferred)
  in
  deferred := [];
  let seen = Hashtbl.create 16 in
  List.filter (fun f ->
    let key = (f.f_loc, f.f_msg) in
    if Hashtbl.mem seen key then false
    else (Hashtbl.add seen key (); true)) fs

(* Headline and hints as one string, which is the shape `Diagnostic.format`
   takes: the first line goes beside the caret, and every line after it is
   rendered under the code frame. A language server wants the position as data
   to draw its underline, so the position is never inside the text. *)
let text (f : finding) : string = String.concat "\n" (f.f_msg :: f.f_hint)

(* Drained and split: (warnings, errors). *)
let classify () : (Loc.t * string) list * (Loc.t * string) list =
  let (ws, es) = List.partition (fun f -> not f.f_error) (all_findings ()) in
  let render = List.map (fun f -> (f.f_loc, text f)) in
  (render ws, render es)

(* Raised by the paths that would otherwise run or emit the program. Carries
   every error-severity finding, not the first: a file whose type gained a case
   usually has more than one match over it, and reporting one while three are
   visible is how the second one gets found by a wrong answer instead. *)
exception Non_exhaustive of (Loc.t * string) list

(* `--allow-nonexhaustive`: report them as warnings and carry on. For a tree
   mid-port, where the arms are known to be missing and the point of the run is
   to see how far it gets. Not the default, because the fallthrough it permits
   has no value to produce and every backend invents a different one. *)
let allow = ref false

(* Both severities as formatted lines, each labelled with the verdict it
   carries. The one caller is `Pipeline.exhaustiveness_warnings`, which is how
   the unit tests read a finding; everything that acts on one goes through
   `classify`, so that the severity is a value and not a word to be parsed back
   out of a string. *)
let take () =
  List.map (fun f ->
    let kind = if f.f_error then "error" else "warning" in
    if f.f_loc.Loc.line = 0 then text f
    else Printf.sprintf "%s: %s: %s" (Loc.to_string f.f_loc) kind (text f))
    (all_findings ())
