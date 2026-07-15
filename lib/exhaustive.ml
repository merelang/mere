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
         [Printf.sprintf
            "%s: warning: non-exhaustive match (missing (%s))"
            (Loc.to_string loc)
            (String.concat ", " (List.map show_comp_case combo))])
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
