(* Exhaustiveness check for `match` expressions.

   Phase 1 scope: report missing variants for sum-type scrutinees, and
   missing true/false for bool scrutinees.  Other types (int, str, float,
   tuple, record) are not checked yet — they require a wildcard or var arm
   to be safe in any case.

   Warnings are returned as strings; the caller (Pipeline) prints them. *)

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
let rec top_level_constructors (p : Ast.pattern) : string list =
  match p.pnode with
  | Ast.P_constr (name, _) -> [name]
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

(* Check a Match expression.  Returns a list of warning strings (empty if
   the match is judged exhaustive).  `loc` is the location of the match
   expression for error reporting. *)
let check_match (loc : Loc.t)
                (scrut_ty : Ast.ty)
                (arms : (Ast.pattern * Ast.expr option * Ast.expr) list)
              : string list =
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
      List.map (fun b ->
        Printf.sprintf
          "%s: warning: non-exhaustive match (missing %s)"
          (Loc.to_string loc)
          (if b then "true" else "false")
      ) missing
    | Ast.TyCon (type_name, _)
      when Hashtbl.mem type_variants type_name ->
      let variants = Hashtbl.find type_variants type_name in
      let seen = List.concat_map top_level_constructors unguarded_arms in
      let missing =
        List.filter (fun (vname, _) -> not (List.mem vname seen)) variants
      in
      List.map (fun (vname, payload) ->
        let p_str = match payload with
          | None -> ""
          | Some _ -> " _"
        in
        Printf.sprintf
          "%s: warning: non-exhaustive match (missing %s%s)"
          (Loc.to_string loc) vname p_str
      ) missing
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
      [Printf.sprintf
         "%s: warning: non-exhaustive match (no wildcard arm%s)"
         (Loc.to_string loc) ty_hint]

(* Global mutable accumulator: Typer's infer pass appends warnings here
   as it visits Match nodes (it already has the scrutinee type at that point,
   so checking is essentially free).  Pipeline resets at start, reads at end.

   Using a ref is pragmatic — threading a warnings argument through every
   Typer entry point would be invasive. *)
let warnings : string list ref = ref []

(* Phase 21.2: deferred matches.  Storing the triple lets us re-walk the
   scrutinee type AFTER all typer unification has completed, so a Match
   whose scrut_ty is initially a fresh tyvar (e.g., the param `xs` of a
   poly let-rec, only later unified to `'a list` by the patterns) is
   judged against its final concrete type rather than an unresolved one. *)
let deferred : (Loc.t * Ast.ty * (Ast.pattern * Ast.expr option * Ast.expr) list) list ref =
  ref []

let reset () =
  warnings := [];
  deferred := []

let take () =
  (* Run deferred checks now that typing is done — scrut tys have walked. *)
  let ws_def =
    List.concat_map (fun (loc, scrut_ty, arms) ->
      check_match loc scrut_ty arms
    ) (List.rev !deferred)
  in
  let ws = List.rev !warnings @ ws_def in
  warnings := [];
  deferred := [];
  ws

let record_match loc scrut_ty arms =
  deferred := (loc, scrut_ty, arms) :: !deferred
