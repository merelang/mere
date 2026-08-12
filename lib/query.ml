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
