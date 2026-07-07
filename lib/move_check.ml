(* Q-012 (OPEN i): move / use-after-move analysis for `spawn`.

   A capability captured by a `spawn` closure crosses a thread boundary. Per
   the concurrency narrowing §B the capture is classified by the captured
   value's type:

     Sync            -> shared   (parent keeps using it)
     Send && !Sync   -> moved    (consumed; parent may not touch it again)
     !Send           -> rejected (cannot cross the boundary at all)

   This pass runs after type inference (so it reads resolved `expr.ty`) and
   enforces the "moved once, then gone" discipline. It deliberately tracks
   only moves — borrows are already governed by regions / Trivial / the
   borrow checker — so it is far lighter than a full Rust-style borrow
   checker: no loans, no lifetimes, just a consumed-set flow.

   Design decisions (see internal design notes, step 3b-2):
   - Binding identity: each Let / With / Fun-param / Match binder gets a fresh
     id; the consumed set is a set of ids, so shadowing is handled naturally
     (a rebind is a new id; the old, shadowed binding is simply out of scope).
   - Branch merge (If / Match): a binding must be moved in ALL branches or in
     none. A move in only some branches is rejected — this keeps Drop static
     (consistent with the LIFO `with` Drop model) instead of needing runtime
     drop flags.
   - Multi-run closures: moving an outer-scope binding from inside any closure
     that may run more than once (a non-spawn `fn` body, or a `let rec` body)
     is rejected — otherwise the move would run repeatedly (double free). The
     spawn closure itself runs exactly once, so a move directly in it is fine.
   - Unknown / polymorphic captures: if a captured binding's type is not
     resolved to a concrete Send/Sync verdict, the capture is rejected rather
     than assumed shareable (closing a soundness hole that an optimistic
     assumption would open). *)

module SS = Set.Make (String)
module IS = Set.Make (Int)

let counter = ref 0
let fresh_id () = incr counter; !counter

(* A binding: its identity + the type it was bound at (None if the typer
   never annotated it, treated as unknown). *)
type binfo = { id : int; ty : Ast.ty option }
type venv = (string * binfo) list

(* --- pattern / free-variable helpers --- *)

let rec pattern_vars (p : Ast.pattern) : string list =
  match p.Ast.pnode with
  | Ast.P_var n -> [ n ]
  | Ast.P_wild | Ast.P_int _ | Ast.P_bool _ | Ast.P_str _ | Ast.P_unit -> []
  | Ast.P_constr (_, Some inner) -> pattern_vars inner
  | Ast.P_constr (_, None) -> []
  | Ast.P_tuple ps -> List.concat_map pattern_vars ps
  | Ast.P_record (_, fields) -> List.concat_map (fun (_, sp) -> pattern_vars sp) fields
  | Ast.P_as (inner, n) -> n :: pattern_vars inner
  | Ast.P_or (a, _) -> pattern_vars a  (* both sides bind the same names *)

let rec free_vars (e : Ast.expr) : SS.t =
  match e.Ast.node with
  | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _
  | Ast.Str_lit _ | Ast.Unit_lit -> SS.empty
  | Ast.Var x -> SS.singleton x
  | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
  | Ast.App (a, b) -> SS.union (free_vars a) (free_vars b)
  | Ast.Neg a | Ast.Annot (a, _) | Ast.Field_get (a, _)
  | Ast.Ref (_, _, a) | Ast.Region_block (_, a) -> free_vars a
  | Ast.Fun (param, _, body) -> SS.remove param (free_vars body)
  | Ast.Let (pat, value, body) ->
    let bound = SS.of_list (pattern_vars pat) in
    SS.union (free_vars value) (SS.diff (free_vars body) bound)
  | Ast.Let_rec (bindings, body) ->
    let names = SS.of_list (List.map fst bindings) in
    let bodies = List.fold_left (fun acc (_, v) -> SS.union acc (free_vars v))
                   (free_vars body) bindings in
    SS.diff bodies names
  | Ast.With (name, value, body) ->
    SS.union (free_vars value) (SS.remove name (free_vars body))
  | Ast.If (c, t, e) ->
    SS.union (free_vars c) (SS.union (free_vars t) (free_vars e))
  | Ast.Constr (_, Some a) -> free_vars a
  | Ast.Constr (_, None) -> SS.empty
  | Ast.Tuple es -> List.fold_left (fun acc e -> SS.union acc (free_vars e)) SS.empty es
  | Ast.Record_lit (_, fields) ->
    List.fold_left (fun acc (_, e) -> SS.union acc (free_vars e)) SS.empty fields
  | Ast.Record_update (base, fields) ->
    List.fold_left (fun acc (_, e) -> SS.union acc (free_vars e)) (free_vars base) fields
  | Ast.Match (scrut, arms) ->
    List.fold_left (fun acc (pat, guard, body) ->
      let bound = SS.of_list (pattern_vars pat) in
      let g = match guard with Some ge -> free_vars ge | None -> SS.empty in
      SS.union acc (SS.diff (SS.union g (free_vars body)) bound)
    ) (free_vars scrut) arms

(* --- binding-env construction --- *)

(* Bind a pattern's variables with fresh ids. For P_var the type is exactly
   the bound value's type; for a tuple pattern over a tuple type we split
   component-wise; anything else binds with an unknown type (None), which
   makes those bindings rejected if captured — sound but conservative. *)
let rec bind_pattern (env : venv) (p : Ast.pattern) (ty : Ast.ty option) : venv =
  match p.Ast.pnode, Option.map Ast.walk ty with
  | Ast.P_var n, _ -> (n, { id = fresh_id (); ty }) :: env
  | Ast.P_as (inner, n), _ ->
    let env = (n, { id = fresh_id (); ty }) :: env in
    bind_pattern env inner ty
  | Ast.P_tuple ps, Some (Ast.TyTuple ts) when List.length ps = List.length ts ->
    List.fold_left2 (fun env p t -> bind_pattern env p (Some t)) env ps ts
  | _ ->
    List.fold_left (fun env n -> (n, { id = fresh_id (); ty = None }) :: env)
      env (pattern_vars p)

let bind_name (env : venv) (n : string) (ty : Ast.ty option) : venv =
  (n, { id = fresh_id (); ty }) :: env

(* --- capture classification (§B) --- *)

type capture = Share | Move of int | Reject of string

let classify (name : string) (b : binfo) : capture =
  match b.ty with
  | None -> Reject (Printf.sprintf
      "cannot capture `%s` of unknown type across a thread boundary" name)
  | Some t ->
    match Ast.walk t with
    | Ast.TyVar _ | Ast.TyParam _ -> Reject (Printf.sprintf
        "cannot capture `%s` of polymorphic type across a thread boundary \
         (its type is not known to be Send or Sync — annotate it)" name)
    | wt ->
      if Typer.is_sync wt then Share
      else if Typer.is_send wt then Move b.id
      else Reject (Printf.sprintf
        "cannot capture `%s` : %s across a thread boundary (it is neither \
         Send nor Sync)" name (Ast.pp_ty wt))

(* --- the flow traversal ---
   `go env consumed multi e` returns the consumed set after `e`.
   `multi` is true inside a closure / let rec body that may run more than
   once (relative to the moves it contains). *)
let rec go (env : venv) (consumed : IS.t) (multi : bool) (e : Ast.expr) : IS.t =
  match e.Ast.node with
  | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _
  | Ast.Str_lit _ | Ast.Unit_lit -> consumed
  | Ast.Var x ->
    (match List.assoc_opt x env with
     | Some b when IS.mem b.id consumed ->
       raise (Typer.Type_error (e.Ast.loc,
         Printf.sprintf
           "use after move: `%s` was moved into a spawned thread and can no \
            longer be used here" x))
     | _ -> consumed)
  | Ast.Neg a | Ast.Annot (a, _) | Ast.Field_get (a, _)
  | Ast.Ref (_, _, a) | Ast.Region_block (_, a) -> go env consumed multi a
  | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b) ->
    go env (go env consumed multi a) multi b
  | Ast.Constr (_, Some a) -> go env consumed multi a
  | Ast.Constr (_, None) -> consumed
  | Ast.Tuple es ->
    List.fold_left (fun c e -> go env c multi e) consumed es
  | Ast.Record_lit (_, fields) ->
    List.fold_left (fun c (_, e) -> go env c multi e) consumed fields
  | Ast.Record_update (base, fields) ->
    List.fold_left (fun c (_, e) -> go env c multi e) (go env consumed multi base) fields
  | Ast.Fun (param, _, body) ->
    (* A closure that is NOT a spawn argument: it may run any number of
       times, so check its body under multi=true. Moves it performs are
       rejected there; it does not consume anything for the outer flow. *)
    let env' = bind_name env param (param_ty e) in
    ignore (go env' consumed true body);
    consumed
  | Ast.Let (pat, value, body) ->
    let consumed = go env consumed multi value in
    let env' = bind_pattern env pat value.Ast.ty in
    go env' consumed multi body
  | Ast.With (name, value, body) ->
    let consumed = go env consumed multi value in
    let env' = bind_name env name value.Ast.ty in
    go env' consumed multi body
  | Ast.Let_rec (bindings, body) ->
    let env' = List.fold_left (fun env (n, v) -> bind_name env n v.Ast.ty)
                 env bindings in
    (* Recursive bindings may run many times: check under multi=true. *)
    List.iter (fun (_, v) -> ignore (go env' consumed true v)) bindings;
    go env' consumed multi body
  | Ast.If (cond, t, e_) ->
    let c1 = go env consumed multi cond in
    let ct = go env c1 multi t in
    let ce = go env c1 multi e_ in
    merge_branches e.Ast.loc env c1 [ ct; ce ]
  | Ast.Match (scrut, arms) ->
    let c1 = go env consumed multi scrut in
    let arm_results = List.map (fun (pat, guard, body) ->
      let env' = bind_pattern env pat scrut.Ast.ty in
      let cg = match guard with Some g -> go env' c1 multi g | None -> c1 in
      go env' cg multi body
    ) arms in
    (match arm_results with
     | [] -> c1
     | _ -> merge_branches e.Ast.loc env c1 arm_results)
  (* spawn (fn () -> ...) : capture analysis (§B). *)
  | Ast.App ({ Ast.node = Ast.Var "spawn"; _ }, ({ Ast.node = Ast.Fun _; _ } as clos)) ->
    spawn_capture env consumed multi clos
  | Ast.App (f, arg) ->
    go env (go env consumed multi f) multi arg

and param_ty (fn : Ast.expr) : Ast.ty option =
  match fn.Ast.ty with
  | Some t -> (match Ast.walk t with Ast.TyArrow (a, _) -> Some a | _ -> None)
  | None -> None

(* A move is legal only if the two (or more) branches agree on the set of
   ids they moved relative to the incoming set; anything moved in some but
   not all branches is a path-dependent move, which we reject. *)
and merge_branches loc _env incoming (results : IS.t list) : IS.t =
  let moved_of c = IS.diff c incoming in
  match results with
  | [] -> incoming
  | first :: rest ->
    let m0 = moved_of first in
    List.iter (fun c ->
      if not (IS.equal (moved_of c) m0) then
        raise (Typer.Type_error (loc,
          "a value is moved into a spawned thread in only some branches; \
           move it in every branch or none (a path-dependent move would \
           make cleanup ambiguous)"))
    ) rest;
    IS.union incoming m0

and spawn_capture (env : venv) (consumed : IS.t) (multi : bool) (clos : Ast.expr) : IS.t =
  let body = match clos.Ast.node with Ast.Fun (_, _, b) -> b | _ -> clos in
  let captured = free_vars clos in
  (* Classify each captured binding that is actually in scope (globals /
     builtins are not tracked). Collect the ids that get moved. *)
  let moves =
    SS.fold (fun name acc ->
      match List.assoc_opt name env with
      | None -> acc
      | Some b ->
        match classify name b with
        | Share -> acc
        | Reject msg -> raise (Typer.Type_error (clos.Ast.loc, msg))
        | Move id ->
          if multi then
            raise (Typer.Type_error (clos.Ast.loc,
              Printf.sprintf
                "cannot move `%s` into a thread spawned inside a closure or \
                 `let rec` that may run more than once (the move would repeat)"
                name))
          else IS.add id acc
    ) captured IS.empty
  in
  (* The child owns the moved values, so they are available inside the
     closure body (checked from the pre-move consumed set, run-once). *)
  ignore (go env consumed false body);
  IS.union consumed moves

let check (e : Ast.expr) : unit =
  counter := 0;
  ignore (go [] IS.empty false e)
