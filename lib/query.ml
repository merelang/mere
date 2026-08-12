(* Questions about a position in a file.

   An editor's questions — what is this, where does it come from, what could I
   type here — are all the same question underneath: which part of the tree is
   the cursor in? This module answers that, and the language server turns the
   answer into whatever the protocol wants.

   It works on the tree *after* type inference, because that is the only tree
   worth asking: the typer writes the inferred type onto every node it visits
   (`e.ty <- Some t`), so a node found here already knows what it is.

   One thing to know about positions here. A `Loc.t` is not a span — it is a
   line, a column and a width, which covers the token the node was built from
   rather than everything underneath it. So "the node at this position" means
   the node whose own token the cursor is inside, and the innermost such node is
   the narrowest one. That is exactly right for identifiers and literals, which
   is what a cursor is usually on, and it is why hovering over the middle of a
   long application gives you the piece under the cursor rather than the whole
   call. *)

(* Does this node's own token contain the position? Columns are 1-based and the
   width is inclusive of the first character, so a 3-wide token at column 5
   covers columns 5, 6 and 7. *)
let covers (loc : Loc.t) (line : int) (col : int) =
  loc.Loc.line = line
  && loc.Loc.line > 0
  && col >= loc.Loc.col
  && col < loc.Loc.col + max 1 loc.Loc.width

(* The narrowest node whose token contains the position, searching the whole
   program. Ties — a node and a child built from the same token, which happens
   where the parser reuses a position — go to the deeper one, since it is the
   more specific answer. *)
let node_at (prog : Ast.program) (line : int) (col : int) : Ast.expr option =
  let best = ref None in
  let better (e : Ast.expr) =
    match !best with
    | None -> true
    | Some (b : Ast.expr) ->
      max 1 e.Ast.loc.Loc.width <= max 1 b.Ast.loc.Loc.width
  in
  let rec go (e : Ast.expr) =
    if covers e.Ast.loc line col && better e then best := Some e;
    List.iter go (Ast.children e)
  in
  List.iter (fun d -> List.iter go (Ast.decl_exprs d)) prog.Ast.decls;
  go prog.Ast.main;
  !best

(* What to show for a node. The type is the useful part; the name in front of it
   is what makes a hover readable when the cursor is on an identifier. *)
let describe (e : Ast.expr) : string option =
  match e.Ast.ty with
  | None -> None
  | Some t ->
    let ty = Ast.pp_ty t in
    (match e.Ast.node with
     | Ast.Var name -> Some (name ^ " : " ^ ty)
     | _ -> Some ty)

(* --- what is bound where -------------------------------------------------

   Go-to-definition and completion both need the same thing hover did not: not
   just the node under the cursor, but what names are visible there and where
   each one came from.

   Scope is recomputed by walking down to the position rather than kept in an
   index. The walk is cheap (it descends one path, not the whole tree), it cannot
   go stale, and it has no invalidation to get wrong — the same reason hover reads
   the typer's annotations instead of building its own table. *)

type binding = {
  b_name : string;
  b_loc : Loc.t;          (* where the name was introduced *)
  b_ty : Ast.ty option;   (* what it was inferred to be, when that is known *)
  (* From the auto-imported prelude rather than from this file. Such a binding is
     a real name in scope — completion should offer it — but its position is a
     line in the prelude's own text, so nothing may send an editor there. *)
  b_prelude : bool;
}

(* Names a pattern introduces, each with the position it introduced them at. *)
let rec pattern_bindings (p : Ast.pattern) : (string * Loc.t) list =
  match p.Ast.pnode with
  | Ast.P_var name -> [ (name, p.Ast.ploc) ]
  | Ast.P_as (inner, name) -> (name, p.Ast.ploc) :: pattern_bindings inner
  | Ast.P_constr (_, Some sub) -> pattern_bindings sub
  | Ast.P_tuple ps -> List.concat_map pattern_bindings ps
  | Ast.P_record (_, fields) -> List.concat_map (fun (_, p) -> pattern_bindings p) fields
  (* An or-pattern binds the same names on both sides, so one side is enough. *)
  | Ast.P_or (a, _) -> pattern_bindings a
  | Ast.P_wild | Ast.P_int _ | Ast.P_bool _ | Ast.P_str _ | Ast.P_unit
  | Ast.P_constr (_, None) -> []

let binding_of ?(prelude = false) (name, loc) ty =
  { b_name = name; b_loc = loc; b_ty = ty; b_prelude = prelude }

(* Everything visible at a position, innermost first, so the first match for a
   name is the one that shadows the others.

   A binder contributes to the scope of the parts of itself where it is actually
   visible: a `let` binds its body but not its own value expression, a `fn` binds
   its body, a `let rec` binds both. Getting that wrong is how a language server
   ends up sending you to the wrong `x`. *)
let scope_at ?(prelude_decls = 0) (prog : Ast.program) (line : int) (col : int)
  : binding list =
  let acc = ref [] in
  let found = ref false in
  let rec walk (env : binding list) (e : Ast.expr) =
    (* Once the position is inside this node's own token, the scope around it is
       the answer — but keep walking, since a child may be narrower. *)
    if covers e.Ast.loc line col then (acc := env; found := true);
    match e.Ast.node with
    | Ast.Let (pat, value, body) ->
      walk env value;
      let env' =
        List.map (fun b -> binding_of b (Option.map (fun t -> t) value.Ast.ty)) (pattern_bindings pat)
        @ env
      in
      walk env' body
    | Ast.Let_rec (bindings, body) ->
      let env' =
        List.map (fun (n, (v : Ast.expr)) -> binding_of (n, v.Ast.loc) v.Ast.ty) bindings @ env
      in
      List.iter (fun (_, v) -> walk env' v) bindings;
      walk env' body
    | Ast.Fun (param, ty, body) ->
      walk (binding_of (param, e.Ast.loc) ty :: env) body
    | Ast.With (name, value, body) ->
      walk env value;
      walk (binding_of (name, e.Ast.loc) value.Ast.ty :: env) body
    | Ast.Match (scrutinee, arms) ->
      walk env scrutinee;
      List.iter (fun (pat, guard, body) ->
        let env' =
          List.map (fun b -> binding_of b None) (pattern_bindings pat) @ env
        in
        (match guard with Some g -> walk env' g | None -> ());
        walk env' body) arms
    | _ -> List.iter (walk env) (Ast.children e)
  in
  (* Top-level declarations are visible to each other regardless of order, which
     is what the pipeline does when it hoists them. The first `prelude_decls` of
     them are the prelude's, and are marked rather than dropped. *)
  let top =
    List.concat (List.mapi (fun i d ->
      let prelude = i < prelude_decls in
      match d with
      | Ast.Top_let (pat, (v : Ast.expr)) ->
        List.map (fun b -> binding_of ~prelude b v.Ast.ty) (pattern_bindings pat)
      | Ast.Top_let_rec bindings ->
        List.map (fun (n, (v : Ast.expr)) ->
          binding_of ~prelude (n, v.Ast.loc) v.Ast.ty) bindings
      | _ -> []) prog.Ast.decls)
  in
  List.iter (fun d -> List.iter (walk top) (Ast.decl_exprs d)) prog.Ast.decls;
  walk top prog.Ast.main;
  if !found then !acc else top

(* Where the name under the cursor was introduced. `None` when the cursor is not
   on a name, or the name is a builtin — a builtin has no source position to go
   to, and inventing one would be worse than saying nothing. *)
let definition_at ?prelude_decls (prog : Ast.program) (line : int) (col : int)
  : Loc.t option =
  match node_at prog line col with
  | Some { Ast.node = Ast.Var name; _ } ->
    (match List.find_opt (fun b -> b.b_name = name)
             (scope_at ?prelude_decls prog line col) with
     | Some b when b.b_loc.Loc.line > 0 && not b.b_prelude -> Some b.b_loc
     | _ -> None)
  | _ -> None

(* --- what could go here ---------------------------------------------------

   Completion is the same two questions again — what is under the cursor, what is
   in scope there — plus one decision: what to offer. The answer here is "every
   name that is visible at this position", which is small, correct, and does not
   pretend to rank. An editor filters by what has been typed already, so offering
   the whole scope is not the same as showing it.

   Prelude names are included and marked, because `str_len` is exactly what
   somebody wants offered even though there is nowhere in their file to jump
   to. *)

type completion = {
  c_name : string;
  c_ty : Ast.ty option;
  c_prelude : bool;
}

(* Innermost first, and one entry per name: an inner binding shadows an outer one
   of the same name, and offering both would be offering a name that cannot be
   reached. *)
let completions_at ?prelude_decls (prog : Ast.program) (line : int) (col : int)
  : completion list =
  let seen = Hashtbl.create 64 in
  List.filter_map (fun b ->
    if Hashtbl.mem seen b.b_name then None
    else begin
      Hashtbl.add seen b.b_name ();
      (* `_` is what the language calls a binding it means to ignore, and a
         leading underscore in the prelude marks a helper the prelude wrote for
         itself. Neither is something to offer back. *)
      if b.b_name = "_"
         || (b.b_prelude && String.length b.b_name > 0 && b.b_name.[0] = '_')
      then None
      else Some { c_name = b.b_name; c_ty = b.b_ty; c_prelude = b.b_prelude }
    end)
    (scope_at ?prelude_decls prog line col)
