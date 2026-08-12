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

(* --- what is in this file -------------------------------------------------

   The outline an editor shows in its breadcrumbs and its symbol search. Only
   what has a position: a value declaration is located by the pattern that names
   it, and a `let rec` by the expression it binds. A `type` declaration has no
   position in the tree at all — `Top_type` carries a name and its variants and
   nothing else — so it cannot honestly be pointed at, and is left out rather
   than pointed at the wrong line. *)

type symbol = {
  s_name : string;
  s_loc : Loc.t;
  s_is_fn : bool;
}

let symbols ?(prelude_decls = 0) (prog : Ast.program) : symbol list =
  let is_fn (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Fun _ -> true
    | _ ->
      (match e.Ast.ty with
       | Some t -> (match Ast.walk t with Ast.TyArrow _ -> true | _ -> false)
       | None -> false)
  in
  List.concat (List.mapi (fun i d ->
    if i < prelude_decls then []
    else
      match d with
      | Ast.Top_let (pat, (v : Ast.expr)) ->
        List.map (fun (name, loc) ->
          { s_name = name; s_loc = loc; s_is_fn = is_fn v })
          (pattern_bindings pat)
      | Ast.Top_let_rec bindings ->
        List.map (fun (name, (v : Ast.expr)) ->
          { s_name = name; s_loc = v.Ast.loc; s_is_fn = is_fn v }) bindings
      | _ -> []) prog.Ast.decls)

(* --- colour, from what the compiler knows --------------------------------

   Syntax highlighting is normally a pile of regular expressions guessing at a
   language. The compiler does not have to guess: it knows that this name is a
   parameter and that one is a top-level function, that this is a constructor and
   that this is a type. Semantic tokens are how that reaches the editor.

   Only what the tree can say for certain is emitted. Keywords, strings and
   numbers are left to the grammar, which is perfectly good at them; what it
   cannot do is tell a parameter from a global, and that is exactly what is
   returned here. *)

type token_kind =
  | Tk_function     (* a name bound to something arrow-typed *)
  | Tk_variable     (* any other bound name *)
  | Tk_parameter    (* a function's own parameter *)
  | Tk_constructor  (* Some, Cons, ... *)

let token_kind_name = function
  | Tk_function -> "function"
  | Tk_variable -> "variable"
  | Tk_parameter -> "parameter"
  | Tk_constructor -> "enumMember"

type token = {
  t_loc : Loc.t;
  t_kind : token_kind;
}

(* Every occurrence of a name in the file, classified. Walks the whole tree,
   carrying the parameters in scope so a use of one can be told from a use of a
   global — the distinction a grammar cannot make and the one worth having. *)
let semantic_tokens ?(prelude_decls = 0) (prog : Ast.program) : token list =
  let out = ref [] in
  let emit loc kind =
    (* A position from an imported file is not in this file's text; colouring by
       its line and column would paint an unrelated line. *)
    if loc.Loc.line > 0 && loc.Loc.file = None then
      out := { t_loc = loc; t_kind = kind } :: !out
  in
  let arrow (e : Ast.expr) =
    match e.Ast.ty with
    | Some t -> (match Ast.walk t with Ast.TyArrow _ -> true | _ -> false)
    | None -> (match e.Ast.node with Ast.Fun _ -> true | _ -> false)
  in
  let rec walk params (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.Var name ->
       if String.length name > 0 && name.[0] >= 'A' && name.[0] <= 'Z' then
         emit e.Ast.loc Tk_constructor
       else if List.mem name params then emit e.Ast.loc Tk_parameter
       else emit e.Ast.loc (if arrow e then Tk_function else Tk_variable)
     | Ast.Constr (_, _) -> emit e.Ast.loc Tk_constructor
     | _ -> ());
    match e.Ast.node with
    | Ast.Fun (param, _, body) -> walk (param :: params) body
    | _ -> List.iter (walk params) (Ast.children e)
  in
  List.iteri (fun i d ->
    if i >= prelude_decls then List.iter (walk []) (Ast.decl_exprs d)) prog.Ast.decls;
  walk [] prog.Ast.main;
  (* The protocol wants them in order, and encodes each one relative to the one
     before it. *)
  List.sort (fun a b ->
    match compare a.t_loc.Loc.line b.t_loc.Loc.line with
    | 0 -> compare a.t_loc.Loc.col b.t_loc.Loc.col
    | c -> c) (List.rev !out)

(* --- every occurrence of one binding --------------------------------------

   Find references and rename are the same question — where else is *this* name,
   meaning this binding rather than every name spelled the same. Shadowing is the
   whole difficulty: two `x`es in one file may be two different things, and a
   rename that treats them as one is a rename that breaks the program.

   So the walk resolves each occurrence to the binding it actually refers to,
   and the answer is the occurrences that resolved to the same one. Binder sites
   are included, which is what lets the cursor be on the definition. *)

let occurrences ?(prelude_decls = 0) (prog : Ast.program)
  : (Loc.t * binding) list =
  let out = ref [] in
  let emit loc b = if loc.Loc.line > 0 then out := (loc, b) :: !out in
  (* A name resolves to the innermost binding of that name in scope. *)
  let resolve env name = List.find_opt (fun b -> b.b_name = name) env in
  let bind_pattern env pat =
    List.map (fun (n, l) -> binding_of (n, l) None) (pattern_bindings pat) @ env
  in
  let rec walk env (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.Var name ->
       (match resolve env name with Some b -> emit e.Ast.loc b | None -> ())
     | _ -> ());
    match e.Ast.node with
    | Ast.Let (pat, value, body) ->
      walk env value;
      let env' = bind_pattern env pat in
      (* The binder itself is an occurrence: a cursor on the definition should
         find the uses, not nothing. *)
      List.iter (fun (n, l) ->
        match resolve env' n with Some b -> emit l b | None -> ())
        (pattern_bindings pat);
      walk env' body
    | Ast.Let_rec (bindings, body) ->
      let env' =
        List.map (fun (n, (v : Ast.expr)) -> binding_of (n, v.Ast.loc) v.Ast.ty)
          bindings @ env
      in
      List.iter (fun (_, v) -> walk env' v) bindings;
      walk env' body
    | Ast.Fun (param, ty, body) -> walk (binding_of (param, e.Ast.loc) ty :: env) body
    | Ast.With (name, value, body) ->
      walk env value;
      walk (binding_of (name, e.Ast.loc) value.Ast.ty :: env) body
    | Ast.Match (scrutinee, arms) ->
      walk env scrutinee;
      List.iter (fun (pat, guard, body) ->
        let env' = bind_pattern env pat in
        List.iter (fun (n, l) ->
          match resolve env' n with Some b -> emit l b | None -> ())
          (pattern_bindings pat);
        (match guard with Some g -> walk env' g | None -> ());
        walk env' body) arms
    | _ -> List.iter (walk env) (Ast.children e)
  in
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
  List.iteri (fun i d ->
    if i >= prelude_decls then begin
      (* A top-level declaration's own name is an occurrence too. *)
      (match d with
       | Ast.Top_let (pat, _) ->
         List.iter (fun (n, l) ->
           match resolve top n with Some b -> emit l b | None -> ())
           (pattern_bindings pat)
       | _ -> ());
      List.iter (walk top) (Ast.decl_exprs d)
    end) prog.Ast.decls;
  walk top prog.Ast.main;
  List.rev !out

(* Two occurrences are of the same binding when they resolved to the same one —
   same name, introduced at the same place. *)
let same_binding (a : binding) (b : binding) =
  a.b_name = b.b_name
  && a.b_loc.Loc.line = b.b_loc.Loc.line
  && a.b_loc.Loc.col = b.b_loc.Loc.col
  && a.b_loc.Loc.file = b.b_loc.Loc.file

(* Every place the binding under the cursor appears, and the binding itself.
   `None` when the cursor is not on a name. *)
let references_at ?prelude_decls (prog : Ast.program) (line : int) (col : int)
  : (binding * Loc.t list) option =
  let all = occurrences ?prelude_decls prog in
  match List.find_opt (fun (loc, _) -> covers loc line col) all with
  | None -> None
  | Some (_, target) ->
    Some (target,
          List.filter_map (fun (loc, b) ->
            if same_binding b target then Some loc else None) all)
