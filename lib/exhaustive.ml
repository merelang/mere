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

(* A declared type's PARAMETER NAMES, which the registry above never carried.
   Without them a payload of `TyParam "a"` cannot be turned into the type it
   actually has at a use site — `Some` of an `int opt` is `int`, and this file
   could not say so, which is why it could not look inside a constructor at
   all. `register_variants` is called with them now; the optional argument is
   for the callers that only have the variant list. *)
let type_params : (string, string list) Hashtbl.t = Hashtbl.create 16

let register_variants ?(params = []) name variants =
  Hashtbl.replace type_params name params;
  Hashtbl.replace type_variants name variants

(* Records, for the same reason: a record pattern's sub-patterns are typed by
   the DECLARED field list, and a record pattern may name its fields in any
   order and leave some out (both are legal — `Pt { y = b, x = a }` and
   `Pt { x = a }` compile), so the declaration is the only thing that says how
   many columns a record position has and what they are. *)
let record_decls : (string, string list * (string * Ast.ty) list) Hashtbl.t =
  Hashtbl.create 16

let register_record_decl name params fields =
  Hashtbl.replace record_decls name (params, fields)

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

(* ===========================================================================
   The missing case, computed rather than approximated.

   Until v0.1.472 this file compared the TOP-LEVEL constructors of a match's
   arms against the scrutinee type's constructor list. That answers the common
   question and is blind to a whole class: `Cons (TId nm, r)` and
   `Cons (TP lp, r)` between them "cover" `Cons`, so a `TStr` token in that
   position was never reported.

   HOW BIG THAT CLASS TURNED OUT TO BE. A syntactic sweep before this landed
   put 269 matches in this repository in the shape that COULD hide a hole --
   no total arm, every constructor named, a refutable payload somewhere. That
   is a necessary condition and not a sufficient one, and running the actual
   algorithm over the same 838 files finds exactly FOUR, all of them the same
   hole: a `match` on an argument list with an arm for two elements and an arm
   for none, and nothing for one. Every other downstream repository is clean.
   The two sites read by hand while sizing this up were one real hole
   (`benchmarks/churn/bench.mere`) and one misreading -- `contrib/db/
   redis_cluster.mere` has a third arm, `| Cons (_, rest) ->`, that the first
   pass did not read, and the match is exhaustive. Which is the argument for
   computing the answer rather than eyeballing the shape.

   What replaces it is the standard usefulness algorithm (Maranget, "Warnings
   for pattern matching"), which this pattern language fits without ceremony:
   no ranges, no array patterns, no lazy patterns, and a constructor carries at
   most one sub-pattern. Exhaustiveness is usefulness of an all-wildcard row
   against the matrix of arms, and running it that way produces a WITNESS -- an
   actual value the match does not handle -- rather than a name. The witness is
   what the message prints and what the `help:` arm is built from, so the arm
   is derived from the same computation that found the problem instead of being
   assembled next to it.

   Guarded arms are excluded from the matrix, as before: a guard can be false
   at runtime, so an arm carrying one covers nothing for this purpose.
   =========================================================================== *)

(* Substitute a type's declared parameters. `Some` of an `int opt` has payload
   `TyParam "a"` in the registry and `int` at the use site; without this the
   algorithm cannot descend into a polymorphic constructor at all. *)
let rec subst_params (env : (string * Ast.ty) list) (t : Ast.ty) : Ast.ty =
  match t with
  | Ast.TyParam n -> (match List.assoc_opt n env with Some u -> u | None -> t)
  | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map (subst_params env) args)
  | Ast.TyTuple ts -> Ast.TyTuple (List.map (subst_params env) ts)
  | Ast.TyArrow (a, b) -> Ast.TyArrow (subst_params env a, subst_params env b)
  | Ast.TyRef (m, r, u) -> Ast.TyRef (m, r, subst_params env u)
  | Ast.TyVar { Ast.link = Some u; _ } -> subst_params env u
  | other -> other

(* One constructor of a column's type, carrying the types of the sub-patterns
   it opens. A variant constructor opens 0 or 1 (its payload, which may itself
   be a tuple); a tuple opens its components; a record opens its DECLARED
   fields, in declaration order. *)
type con =
  | Cvariant of string * Ast.ty list
  | Cbool of bool
  | Cunit
  | Ctuple of Ast.ty list
  | Crecord of string * (string * Ast.ty) list

let con_subtys = function
  | Cvariant (_, ts) -> ts
  | Cbool _ | Cunit -> []
  | Ctuple ts -> ts
  | Crecord (_, fs) -> List.map snd fs

let con_arity c = List.length (con_subtys c)

let con_eq a b =
  match a, b with
  | Cvariant (x, _), Cvariant (y, _) -> x = y
  | Cbool x, Cbool y -> x = y
  | Cunit, Cunit -> true
  | Ctuple x, Ctuple y -> List.length x = List.length y
  | Crecord (x, _), Crecord (y, _) -> x = y
  | _ -> false

(* The constructors of a type, when they can be enumerated.
   `None` means the set is OPEN -- int, str, float, bytes, a function, a type
   this file has no declaration for -- and a column of an open type is covered
   only by a wildcard. That is the same judgment the old "no wildcard arm for
   int" branch made, arrived at as a property of the type rather than as a
   fallback case. *)
let signature_of (t : Ast.ty) : con list option =
  let inst params args t =
    if List.length params = List.length args
    then subst_params (List.combine params args) t
    else t   (* arity disagreement: leave the params, which read as open below *)
  in
  match Ast.walk t with
  | Ast.TyBool -> Some [Cbool true; Cbool false]
  | Ast.TyUnit -> Some [Cunit]
  | Ast.TyTuple ts -> Some [Ctuple ts]
  | Ast.TyCon (n, args) when Hashtbl.mem type_variants n ->
    let params = match Hashtbl.find_opt type_params n with Some p -> p | None -> [] in
    Some (List.map (fun (c, payload) ->
      Cvariant (c, match payload with None -> [] | Some p -> [inst params args p]))
      (Hashtbl.find type_variants n))
  | Ast.TyCon (n, args) when Hashtbl.mem record_decls n ->
    let (params, fields) = Hashtbl.find record_decls n in
    Some [Crecord (n, List.map (fun (f, ft) -> (f, inst params args ft)) fields)]
  | _ -> None

let wild_at loc = { Ast.ploc = loc; Ast.pnode = Ast.P_wild }
let dummy_wild = wild_at Loc.dummy

(* An "anything" of this type, keeping the shape the type has. A constructor
   whose payload is a tuple gets a tuple of wildcards rather than one, so the
   witness reads `Triangle (_, _)` and the arm built from it binds both
   components -- `| Triangle a1 -> ...` compiles and then cannot reach either
   float, which is a hint that does not do its job. *)
let rec wild_of_ty (t : Ast.ty) : Ast.pattern =
  match Ast.walk t with
  | Ast.TyTuple ts ->
    { Ast.ploc = Loc.dummy; Ast.pnode = Ast.P_tuple (List.map wild_of_ty ts) }
  | _ -> dummy_wild

(* A row's first column, with as-patterns stripped and or-patterns split into
   separate rows. Done one column at a time rather than over the whole matrix:
   a nested or-pattern is reached when its column is, and expanding everything
   up front is how this kind of code acquires an exponential. *)
let expand_head (row : Ast.pattern list) : Ast.pattern list list =
  match row with
  | [] -> [[]]
  | p :: rest ->
    let rec heads q =
      match q.Ast.pnode with
      | Ast.P_as (inner, _) -> heads inner
      | Ast.P_or (a, b) -> heads a @ heads b
      | _ -> [q]
    in
    List.map (fun h -> h :: rest) (heads p)

(* Which constructor this pattern's head IS, if any. A literal (`0`, `"x"`)
   belongs to an open signature and answers None: it covers one value out of
   infinitely many, so it neither completes a signature nor survives into the
   default matrix. *)
let con_of_head (p : Ast.pattern) : con option =
  match p.Ast.pnode with
  | Ast.P_constr (n, _) -> Some (Cvariant (bare_ctor n, []))
  | Ast.P_bool b -> Some (Cbool b)
  | Ast.P_unit -> Some Cunit
  | Ast.P_tuple ps -> Some (Ctuple (List.map (fun _ -> Ast.TyUnit) ps))
  | Ast.P_record (n, _) -> Some (Crecord (n, []))
  | _ -> None

(* S(c, P): the rows that can match a value whose head is `c`, with that
   head's sub-patterns spliced in where the column was. A wildcard row
   contributes wildcards for every sub-position. *)
let specialize (c : con) (rows : Ast.pattern list list) : Ast.pattern list list =
  let ar = con_arity c in
  List.concat_map (fun row0 ->
    List.filter_map (fun row ->
      match row with
      | [] -> None
      | p :: rest ->
        let wilds () = List.init ar (fun _ -> wild_at p.Ast.ploc) in
        (match p.Ast.pnode, c with
         | (Ast.P_wild | Ast.P_var _), _ -> Some (wilds () @ rest)
         | Ast.P_constr (n, sub), Cvariant (cn, ts) when bare_ctor n = cn ->
           (* Arity mismatches are possible in a program the typer accepted --
              a nullary constructor written for one that has a payload, say --
              and are padded rather than dropped, because dropping a row would
              claim a case is missing that the arm does handle. *)
           (match sub, ts with
            | Some sp, [_] -> Some (sp :: rest)
            | None, [] -> Some rest
            | _ -> Some (wilds () @ rest))
         | Ast.P_bool b, Cbool b' when b = b' -> Some rest
         | Ast.P_unit, Cunit -> Some rest
         | Ast.P_tuple ps, Ctuple ts when List.length ps = List.length ts ->
           Some (ps @ rest)
         | Ast.P_record (_, fs), Crecord (_, decl) ->
           (* Declaration order, and a field the pattern leaves out is a
              wildcard -- both forms are legal source. *)
           Some (List.map (fun (fname, _) ->
             match List.assoc_opt fname fs with
             | Some q -> q
             | None -> wild_at p.Ast.ploc) decl
                 @ rest)
         | _ -> None)
    ) (expand_head row0)
  ) rows

(* D(P): the rows that match a value whose head is a constructor NOT in the
   column -- only the rows whose head covers everything. *)
let default_matrix (rows : Ast.pattern list list) : Ast.pattern list list =
  List.concat_map (fun row0 ->
    List.filter_map (fun row ->
      match row with
      | [] -> None
      | p :: rest ->
        (match p.Ast.pnode with
         | Ast.P_wild | Ast.P_var _ -> Some rest
         | _ -> None)
    ) (expand_head row0)
  ) rows

(* Bound on the search, for the same reason the old product check had one: a
   deeply nested match over a wide variant can enumerate a lot, and a checker
   that hangs is worse than one that declines. Counted in constructor
   specializations, not in depth, because that is what actually grows. *)
let max_steps = 20000

exception Search_exhausted

(* Set when a column's registry entry turns out to be about a different type
   (see the same-named-type guard below). The whole match is then declined
   rather than answered from the wrong declaration -- v0.1.468 chose silence
   here and it is still the right answer: the program in front of the checker
   is complete, and the only finding available would name a constructor that
   does not belong to its scrutinee. *)
let declined = ref false

let steps = ref 0

let tick () =
  incr steps;
  if !steps > max_steps then raise Search_exhausted

(* A value of type `tys` that no row matches, if one exists.
   `None` means the match is exhaustive over those columns. *)
let rec find_missing (tys : Ast.ty list) (rows : Ast.pattern list list)
      : Ast.pattern list option =
  match tys with
  | [] -> if rows = [] then Some [] else None
  | ty :: rest_tys ->
    let heads =
      List.concat_map (fun row0 ->
        List.filter_map (fun row ->
          match row with p :: _ -> con_of_head p | [] -> None)
          (expand_head row0)) rows
    in
    let present c = List.exists (con_eq c) heads in
    (* THE SAME-NAMED TYPE GUARD, generalised to any column (v0.1.468 had it at
       the top level only). Two modules that each declare `type t` share one
       entry in the variant registry, because it keys on the bare name, so a
       match over the FIRST type is judged against the SECOND's constructors —
       and told to add one that does not belong to it. An arm naming a
       constructor the entry does not have is the evidence that the entry is
       about a different type, and this column is then treated as OPEN: a case
       named out of the wrong declaration is worse than no case at all. *)
    let entry_describes_column =
      match signature_of ty with
      | Some full ->
        List.for_all (fun h ->
          match h with
          | Cvariant _ -> List.exists (con_eq h) full
          | _ -> true) heads
      | None -> true
    in
    if not entry_describes_column then (declined := true; None)
    else
    (match signature_of ty with
     | Some full when List.for_all present full ->
       (* Every constructor appears: whatever is missing is inside one of
          them, so descend. The first one with a witness wins. *)
       let rec try_each = function
         | [] -> None
         | c :: more ->
           tick ();
           (match find_missing (con_subtys c @ rest_tys) (specialize c rows) with
            | Some w ->
              let n = con_arity c in
              let subs = List.filteri (fun i _ -> i < n) w in
              let rest = List.filteri (fun i _ -> i >= n) w in
              Some (rebuild c subs :: rest)
            | None -> try_each more)
       in
       try_each full
     | Some full ->
       (* A constructor nobody named: any value of it is missing, and the rest
          of the witness comes from the rows that cover this column
          regardless. *)
       (match List.find_opt (fun c -> not (present c)) full with
        | None -> None
        | Some c ->
          (match find_missing rest_tys (default_matrix rows) with
           | Some w_rest ->
             Some (rebuild c (List.map wild_of_ty (con_subtys c)) :: w_rest)
           | None -> None))
     | None ->
       (* Open signature -- int, str, float, a type with no declaration here --
          so only a wildcard row covers this column.

          The witness names a value the column does NOT hold, when the column
          holds literals: `match (1, 2) with | (0, b) -> b` is missing `(1, _)`
          and not `(_, _)`, which reads as "any pair" and would be wrong about
          the pair the arm does handle. Picked rather than invented: one past
          the largest int present, and one character longer than the longest
          str. Where the column holds no literals at all a bare `_` is exactly
          right, and `witness_finding` prints that as the sentence this branch
          has always printed. *)
       let lits =
         List.concat_map (fun row0 ->
           List.filter_map (fun row ->
             match row with p :: _ -> Some p.Ast.pnode | [] -> None)
             (expand_head row0)) rows
       in
       let ints = List.filter_map (function Ast.P_int n -> Some n | _ -> None) lits in
       let strs = List.filter_map (function Ast.P_str x -> Some x | _ -> None) lits in
       let here =
         if ints <> [] then
           { Ast.ploc = Loc.dummy;
             Ast.pnode = Ast.P_int (List.fold_left max min_int ints + 1) }
         else if strs <> [] then
           { Ast.ploc = Loc.dummy;
             Ast.pnode = Ast.P_str
               (List.fold_left (fun acc x ->
                  if String.length x > String.length acc then x else acc) "" strs ^ "x") }
         else dummy_wild
       in
       (match find_missing rest_tys (default_matrix rows) with
        | Some w_rest -> Some (here :: w_rest)
        | None -> None))

(* The witness pattern for `c` with the given sub-patterns. *)
and rebuild (c : con) (subs : Ast.pattern list) : Ast.pattern =
  let node =
    match c, subs with
    | Cvariant (n, _), [] -> Ast.P_constr (n, None)
    | Cvariant (n, _), [s] -> Ast.P_constr (n, Some s)
    | Cvariant (n, _), ss -> Ast.P_constr (n, Some { Ast.ploc = Loc.dummy; pnode = Ast.P_tuple ss })
    | Cbool b, _ -> Ast.P_bool b
    | Cunit, _ -> Ast.P_unit
    | Ctuple _, ss -> Ast.P_tuple ss
    | Crecord (n, fs), ss when List.length fs = List.length ss ->
      Ast.P_record (n, List.map2 (fun (f, _) s -> (f, s)) fs ss)
    | Crecord (n, _), _ -> Ast.P_constr (n, None)
  in
  { Ast.ploc = Loc.dummy; pnode = node }

(* The witness as Mere source.

   NOT `Ast.pp_pattern`, which does not parenthesise a constructor inside a
   constructor: it renders `Some (Cons (a, b))` as `Some Cons (a, b)`, which is
   not the pattern it was given. The arm this produces is pasted back into a
   program and run by `scripts/exhaustive_check.sh`, so a printer that is
   almost right is a hint that does not compile. *)
let rec show_witness ?(nested = false) (p : Ast.pattern) : string =
  let paren s = if nested then "(" ^ s ^ ")" else s in
  match p.Ast.pnode with
  | Ast.P_wild -> "_"
  | Ast.P_var n -> n
  | Ast.P_int n -> string_of_int n
  | Ast.P_bool b -> if b then "true" else "false"
  | Ast.P_str s -> "\"" ^ String.concat "" (List.map (fun c ->
      match c with '"' -> "\\\"" | '\\' -> "\\\\" | c -> String.make 1 c)
      (List.init (String.length s) (String.get s))) ^ "\""
  | Ast.P_unit -> "()"
  | Ast.P_constr (c, None) -> c
  | Ast.P_constr (c, Some sub) ->
    paren (c ^ " " ^ show_witness ~nested:true sub)
  | Ast.P_tuple ps ->
    "(" ^ String.concat ", " (List.map (show_witness ~nested:false) ps) ^ ")"
  | Ast.P_record (n, fs) ->
    n ^ " { "
    ^ String.concat ", "
        (List.map (fun (f, q) -> f ^ " = " ^ show_witness ~nested:false q) fs)
    ^ " }"
  | Ast.P_as (inner, _) -> show_witness ~nested inner
  | Ast.P_or (a, _) -> show_witness ~nested a

(* The witness as an ARM, which is not the same string as the witness itself:
   a wildcard in the witness is a position the arm should BIND, so the headline
   reads `Triangle (_, _)` and the arm reads `| Triangle (a1, a2) -> ...`. An
   arm that prints `_` compiles and then cannot name what it was handed, which
   `scripts/exhaustive_check.sh` catches by pasting the arm back into the
   program and using every name it introduced. *)
let show_arm (p : Ast.pattern) : string =
  let n = ref 0 in
  let rec go ?(nested = false) q =
    match q.Ast.pnode with
    (* A literal in a witness only ever came from the open-signature branch,
       where it names ONE value out of infinitely many. As an arm it would be
       a hint that does not do what it is for: writing `| 1 -> ...` for
       "missing 1" leaves everything except 1 still uncovered. It binds
       instead, which covers the column. *)
    | Ast.P_wild | Ast.P_int _ | Ast.P_str _ ->
      incr n; Printf.sprintf "a%d" !n
    | Ast.P_constr (c, Some sub) ->
      let body = c ^ " " ^ go ~nested:true sub in
      if nested then "(" ^ body ^ ")" else body
    | Ast.P_tuple ps ->
      "(" ^ String.concat ", " (List.map (go ~nested:false) ps) ^ ")"
    | Ast.P_record (nm, fs) ->
      nm ^ " { "
      ^ String.concat ", " (List.map (fun (f, q) -> f ^ " = " ^ go ~nested:false q) fs)
      ^ " }"
    | _ -> show_witness ~nested q
  in
  go p

(* Which findings stop a build.

   v0.1.472 introduced this as a migration switch -- "what the old checker could
   have expressed" -- and measuring made a better line available. The whole
   ecosystem had four nested holes and they are fixed, so the question is no
   longer how many sites a promotion would cost. It is which findings are worth
   refusing a program over, and the two classes differ in kind:

     - A witness built only from constructors of FINITE signatures -- variants,
       bool, unit, tuples, records -- names a SHAPE. `Cons (_, Nil)` says a
       one-element list falls between the arms, and the fix is that arm. The
       finding carries information the person did not have.

     - A witness containing an int / str / float literal, or that is a bare
       wildcard, has its decisive position in an INFINITE domain. `missing 2`
       for `| 0 -> … | 1 -> …` is true and the only arm that closes it is
       `| _ -> …`, which the language reference already asks for at every match
       over a scalar. Refusing the program adds nothing to what the warning
       said; it only changes the severity.

   So the first is an error and the second is a warning, and that is a property
   of the witness rather than a phase of a migration. It also keeps
   `test/parity/nonexhaustive_caught.mere` and its fail/ twin compiling: they
   hold the RUNTIME behaviour of a fallthrough, and a complete checker with no
   permission would make that behaviour unreachable from any compiling program. *)
let rec witness_has_open_literal (p : Ast.pattern) =
  match p.Ast.pnode with
  | Ast.P_int _ | Ast.P_str _ -> true
  | Ast.P_constr (_, Some sub) -> witness_has_open_literal sub
  | Ast.P_tuple ps -> List.exists witness_has_open_literal ps
  | Ast.P_record (_, fs) -> List.exists (fun (_, q) -> witness_has_open_literal q) fs
  | _ -> false

let witness_is_error (p : Ast.pattern) =
  match p.Ast.pnode with
  | Ast.P_wild -> false            (* nothing named: the sentence, not a refusal *)
  | _ -> not (witness_has_open_literal p)

(* Every constructor of the scrutinee's own type that no arm names.

   The algorithm returns ONE witness, which is the right answer to "is this
   exhaustive" and the wrong shape for the edit that provokes it: a case added
   to a type leaves several `match`es missing several constructors each, and
   being told about one of them per compile is three compiles to learn one
   thing. So when the finding is an error, the whole absent set of the
   scrutinee's own type is listed beside the witness -- which is what the top-level column
   already knows, and what this file did before the algorithm replaced it. *)
let absent_top_level (scrut_ty : Ast.ty)
                     (rows : Ast.pattern list list) : Ast.pattern list =
  let heads =
    List.concat_map (fun row0 ->
      List.filter_map (fun row ->
        match row with p :: _ -> con_of_head p | [] -> None)
        (expand_head row0)) rows
  in
  match signature_of scrut_ty with
  | Some full when List.for_all (fun h ->
      match h with Cvariant _ -> List.exists (con_eq h) full | _ -> true) heads ->
    List.filter_map (fun c ->
      if List.exists (con_eq c) heads then None
      else Some (rebuild c (List.map wild_of_ty (con_subtys c)))) full
  | _ -> []

let witness_finding loc (scrut_ty : Ast.ty) (w : Ast.pattern) (is_error : bool)
                    (also : Ast.pattern list) =
  match w.Ast.pnode with
  | Ast.P_wild ->
    (* The whole column is uncovered and the type cannot be enumerated: an int,
       a str, a float. Reported the way it always was, naming the type, because
       "missing _" says less than the sentence it would replace. *)
    let ty_hint =
      match Ast.walk scrut_ty with
      | Ast.TyInt -> " for int"
      | Ast.TyStr -> " for str"
      | Ast.TyFloat -> " for float"
      | Ast.TyBytes -> " for bytes"
      | Ast.TyTuple _ -> " for tuple"
      | Ast.TyCon (n, _) -> " for " ^ n
      | _ -> ""
    in
    { f_loc = loc;
      f_msg = Printf.sprintf "non-exhaustive match (no wildcard arm%s)" ty_hint;
      f_hint = [ "help: | _ -> ..." ];
      f_error = false }
  | _ ->
    (* `also` is the rest of the absent set when there is one, with the witness
       itself kept first so the two agree on where they start. *)
    let cases =
      match also with
      | [] -> [w]
      | _ ->
        w :: List.filter (fun q -> show_witness q <> show_witness w) also
    in
    { f_loc = loc;
      f_msg =
        Printf.sprintf "non-exhaustive match (missing %s)"
          (String.concat ", " (List.map show_witness cases));
      (* An arm that is a single binder is written `_`: it covers the same
         values and it is what a person writes. Reached when the witness is
         itself an open-signature value -- `missing 1` asks for a catch-all,
         not for the number. *)
      f_hint =
        List.map (fun q ->
          let arm = show_arm q in
          let is_bare_binder =
            String.length arm > 1 && arm.[0] = 'a'
            && (let rest = String.sub arm 1 (String.length arm - 1) in
                String.for_all (fun c -> c >= '0' && c <= '9') rest)
          in
          Printf.sprintf "help: | %s -> ..." (if is_bare_binder then "_" else arm))
          cases
        @ (if is_error
           then [ "note: or `| _ -> fail \"todo\"` to compile before writing them" ]
           else []);
      f_error = is_error }

(* Check a Match expression. Returns the findings for it (empty when the match
   is exhaustive). `loc` is the location of the match expression. *)
let check_match (loc : Loc.t)
                (scrut_ty : Ast.ty)
                (arms : (Ast.pattern * Ast.expr option * Ast.expr) list)
              : finding list =
  let unguarded =
    List.filter_map (fun (p, g, _) -> if g = None then Some [p] else None) arms
  in
  steps := 0;
  declined := false;
  match (try find_missing [scrut_ty] unguarded with Search_exhausted -> None) with
  | _ when !declined -> []
  | None -> []
  | Some [w] ->
    let is_error = witness_is_error w in
    (* `absent_top_level` is self-limiting: it answers with the constructors of
       the scrutinee's own type that no arm names, so a nested witness like
       `Cons (_, Nil)` -- whose top-level constructors are all present -- adds
       nothing and the finding stays about the one shape. *)
    let also = if is_error then absent_top_level scrut_ty unguarded else [] in
    [ witness_finding loc scrut_ty w is_error also ]
  | Some _ -> []

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
