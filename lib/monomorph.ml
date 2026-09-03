(* Monomorphization: the AST->AST pass that turns a polymorphic function used
   at several concrete types into one specialized function per type.

   This lived inside codegen_c until v0.1.407 and was the C backend's alone.
   The RISC-V backend has no type information at emit time -- its values are
   untagged words -- so a `==` inside a polymorphic function compiled to a word
   comparison there, exact for ints and a POINTER comparison for strings and
   compound values. The fix is not a runtime one: it is to hand that backend
   monomorphic functions in the first place, which is what this module does.

   Two properties made "just call codegen_c's pass" the wrong move, and shaped
   this module instead:
     - the pass MUTATES: it unifies type variables in place (they are
       union-find refs) and it used to publish its instantiation table into a
       codegen_c module global. A second backend calling it would have written
       into the C backend's table -- invisible in a one-backend process, and a
       real cross-contamination in one that runs several (the LSP). So the
       table is now RETURNED, and each backend holds its own.
     - the two backends diverge at the entry: codegen_c works from typed
       `fn_skel`s, codegen_riscv from a name -> body map. What they can share
       is the AST-level answer -- specialized functions under mangled names,
       plus the (source name, use-site arrow) -> mangled name mapping -- which
       is exactly what `run` returns.

   The mangled name is the SAME string on both backends, because it is
   computed here and nowhere else: two spellings of one instance is the shape
   of bug this whole area keeps producing. *)

(* Raised for a program this pass cannot monomorphize. The two flavours exist
   because the C backend words them differently (`unsupported` prefixes "in C
   codegen subset:", a plain error does not), and the caller -- not this
   module -- knows which backend is speaking. *)
exception Unsupported of Loc.t * string
exception Error of Loc.t * string

let unsupported loc what = raise (Unsupported (loc, what))

(* module-qualified `M.foo` -> `M__foo` (`.` is illegal in C identifiers);
   nested `A.B.foo` -> `A__B__foo`. Shared by the value and type manglers. *)
let flatten_module_dots (n : string) : string =
  if String.contains n '.' then begin
    let b = Buffer.create (String.length n) in
    String.iter (fun c ->
      if c = '.' then Buffer.add_string b "__"
      else Buffer.add_char b c) n;
    Buffer.contents b
  end else n

(* Probe: is every element of this type resolved enough to name in C?
   Used by tuple shape collector to skip polymorphic-shaped tuples that
   appear in the typer's recorded annotations of generalized fn bodies
   (those shapes are not part of the program's actual run-time types). *)
let rec ty_is_concrete (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyBytes | Ast.TyUnit -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, _, inner) -> ty_is_concrete inner
  | Ast.TyFloat -> true   (* Phase 43.1 fix: TyFloat is fully concrete; the previous
                              `false` was a typo that prevented a fn taking a `float` arg
                              from being emitted via the fn_decl path, so only the call
                              site was emitted and compilation failed *)
  | Ast.TyVar _ | Ast.TyParam _ -> false

(* Deep-rewrite residual type variables to int — the representation the
   emission layer's erasure (ty_tag / c_type_of) already names. Used when a
   referenced-but-never-concretized fn is recovered: its decl types become
   fully concrete, so the downstream type-instance collectors register the
   same instances the erased emission will reference. *)
let rec deep_erase_tyvars (t : Ast.ty) : Ast.ty =
  match Ast.walk t with
  | Ast.TyVar _ | Ast.TyParam _ -> Ast.TyInt
  | Ast.TyTuple ts -> Ast.TyTuple (List.map deep_erase_tyvars ts)
  | Ast.TyArrow (a, b) -> Ast.TyArrow (deep_erase_tyvars a, deep_erase_tyvars b)
  | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map deep_erase_tyvars args)
  | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, deep_erase_tyvars inner)
  | t -> t

(* v0.1.293: the type that `ty_tag` NAMES, which is not always the type handed to it.
   `ty_tag` erases an unresolved tyvar to `int` -- and a region-parameterised
   container's unresolved region slot to `__heap` -- so a type `ty_is_concrete`
   REJECTS can still have its copier named in the emitted C. Registration has to go
   through this, or the emitted call has no definition. That is what happened to
   `__mcopy_list_tuple_str_int` (a closure capturing a `list (str, 'a)` whose element
   type never resolved) and, by the same mechanism, to a trait dictionary's closure
   field. Erasing with `deep_erase_tyvars` instead is NOT the same thing: it turns the
   region slot into `int` and would register `Vec_int_int` for what `ty_tag` calls
   `Vec___heap_int` -- the mpng P5 shape, one type under two names. *)
let rec ty_as_tagged (t : Ast.ty) : Ast.ty =
  match Ast.walk t with
  | Ast.TyVar _ | Ast.TyParam _ -> Ast.TyInt
  | Ast.TyTuple ts -> Ast.TyTuple (List.map ty_as_tagged ts)
  | Ast.TyArrow (a, b) -> Ast.TyArrow (ty_as_tagged a, ty_as_tagged b)
  | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, ty_as_tagged inner)
  | Ast.TyCon ((("Vec" | "Map" | "StrBuf" | "ByteBuf") as name), (first :: rest)) ->
    (* Slot 0 is the region. Keep ty_tag's answer for an unresolved one. *)
    let first =
      match Ast.walk first with
      | Ast.TyVar _ | Ast.TyParam _ -> Ast.TyRef (Ast.BorrowedRead, "__heap", Ast.TyUnit)
      | other -> ty_as_tagged other
    in
    Ast.TyCon (name, first :: List.map ty_as_tagged rest)
  | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map ty_as_tagged args)
  | t -> t

let rec ty_tag (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt -> "int"
  | Ast.TyBool -> "bool"
  | Ast.TyStr -> "str"
  | Ast.TyBytes -> "bytes"
  | Ast.TyUnit -> "unit"
  | Ast.TyFloat -> "float"   (* Phase 43.1: allow float to be used in fn signature tags *)
  | Ast.TyTuple ts -> "tuple_" ^ String.concat "_" (List.map ty_tag ts)
  | Ast.TyArrow (p, r) ->
    (* Recursive arrow → use the same naming used by closure_struct_name. *)
    "closure_" ^ ty_tag p ^ "_" ^ ty_tag r
  | Ast.TyCon (name, []) -> name
  (* StrBuf[R] and ByteBuf[R] lower to one C type each — `mere_strbuf*`,
     `mere_bytebuf*` — which does not depend on the region: the region is a
     pointer inside the struct. So the region does not belong in the tag either,
     and leaving it out removes the whole class of mismatch where one spelling
     resolved the marker and the other did not. *)
  | Ast.TyCon (("StrBuf" | "ByteBuf") as name, _) -> name
  | Ast.TyCon (name, args) ->
    (* Polymorphic instantiation (e.g., `int list` → `list_int`).
       Phase 15.1: for Vec[R, T]'s region marker (TyRef _ R TyUnit),
       use only the region name as the tag.

       An *unresolved* region marker — a type variable still sitting in that
       slot — tags as the default region rather than falling through to the
       TyVar case below, which erases to `int`. The typedef for the same type is
       emitted from a copy where the region did resolve to `__heap`, so erasing
       produced two names for one type: `Vec_int_int` in a forward declaration
       and `Vec___heap_int` in the typedef, and a prototype for a type that does
       not exist. Found by the mpng dogfood (PAIN.md P5). *)
    let region_parameterised =
      match name with "Vec" | "Map" | "StrBuf" | "ByteBuf" -> true | _ -> false
    in
    let tag_arg i a =
      match i, Ast.walk a with
      | 0, (Ast.TyVar _ | Ast.TyParam _) when region_parameterised -> "__heap"
      | _ -> ty_tag a
    in
    name ^ "_" ^ String.concat "_" (List.mapi tag_arg args)
  | Ast.TyRef (_, r, Ast.TyUnit) ->
    (* Region marker — use the region name itself as the tag. *)
    r
  | Ast.TyRef (_, _, inner) ->
    (* Phase 19.x: for borrow type `&[mode] R T`, the tag uses the inner T's
       tag as-is. mode / region are purely static info. The typer's auto-deref
       makes field access transparent, so not distinguishing from T at the tag
       level is convenient — downstream lookups (closure_struct_name, etc.)
       then match cleanly. *)
    ty_tag inner
  | Ast.TyVar _ | Ast.TyParam _ ->
    (* A type variable that survives to codegen is either dead (the bottom
       result of a function that never returns, e.g. an endless generator
       loop) or unconstrained; no operation ever inspects such a value, so
       any representation works. Erase to int — the representation the
       resolver's use-site defaulting already names — instead of rejecting
       the program. *)
    "int"

(* Phase 23.3: mangle a fn name with its concrete arrow type tag, e.g.
   `rev_aux` with `list_json -> list_json -> list_json` becomes
   `rev_aux__list_json__list_json__list_json`. Used for per-instantiation
   specialization. Must be defined before emit_expr (which dispatches via
   this) and before resolve_fn_types (which creates fn_decls with these
   names). *)
let mangled_inst_name (base : string) (arrow : Ast.ty) : string =
  let rec collect_tys t acc =
    match Ast.walk t with
    | Ast.TyArrow (a, b) -> collect_tys b (a :: acc)
    | _ -> List.rev (t :: acc)
  in
  let tys = collect_tys arrow [] in
  (* Phase 41: if base is module-qualified (`Json.rev_aux`), flatten it to a
     C identifier first, then append the mono suffix
     (`Json__rev_aux__list_json__...`). v0.1.56: the base is left UN-prefixed
     here — every emission and call site routes the whole mangled name through
     c_safe_name once (a single `mu_`), so prefixing here would double it. *)
  flatten_module_dots base ^ "__" ^ String.concat "__" (List.map ty_tag tys)

let pattern_vars (p : Ast.pattern) : string list =
  let rec go p =
    match p.Ast.pnode with
    | Ast.P_var n -> [n]
    | Ast.P_constr (_, Some sub) -> go sub
    | Ast.P_tuple ps -> List.concat_map go ps
    | Ast.P_record (_, fs) -> List.concat_map (fun (_, p) -> go p) fs
    | Ast.P_as (inner, n) -> n :: go inner
    | Ast.P_or (a, _) -> go a  (* both branches must bind same names *)
    | Ast.P_wild | Ast.P_int _ | Ast.P_bool _ | Ast.P_str _ | Ast.P_unit
    | Ast.P_constr (_, None) -> []
  in
  go p

type fn_decl = {
  name      : string;
  param     : string;
  body      : Ast.expr;
  param_ty  : Ast.ty;
  return_ty : Ast.ty;
}

(* Skeleton info collected while walking the AST. We keep the Fun
   expression around so we can read its inferred `.ty` (set by the
   typer in the compile_to_c phase) instead of re-inferring — re-
   inference would overwrite the .ty fields with fresh tyvars that
   never see the call sites. *)
type fn_skel = {
  sname : string;
  sparam : string;
  sbody : Ast.expr;
  sfun : Ast.expr;  (* the original Fun expression, with its typer .ty *)
}

(* Walk the desugared main expression, extracting top-level fn bindings.
   Returns (fn skeletons in declaration order, residual main body). *)
(* `subset` is the backend's name for its own accepted subset, used in the one
   refusal here that names one ("... in C subset" / "... in Wasm subset"). The
   pass has no backend, so it cannot know the word; passing it in is what let
   three identical copies of this function become one without any of them
   changing what a user reads. *)
let lift_fn_skels ?(subset = "C subset") (e : Ast.expr) : fn_skel list * Ast.expr =
  let rec go (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, rest) ->
      (* Phase 24.4: walk through ALL top-level Let chains so a non-Fun
         Let (e.g., `let path = "/tmp/x"`) doesn't break the chain and
         block subsequent `let rec` from being lifted. Fun-valued Lets
         with P_var → extract as skel + drop from body. Other Lets →
         keep in body + walk rest.
         Phase 37.A: `let _ = while ... ;` at top-level desugars to
         `Let (P_wild, Let_rec (bs, call_loop), rest)`. Recognize that
         shape and lift the inner Let_rec bindings as top-level skels,
         replacing the value with the inner Let_rec body. *)
      (match pat.Ast.pnode, value.Ast.node with
       | Ast.P_var name, Ast.Fun (param, _, fn_body) ->
         let more, rest' = go rest in
         { sname = name; sparam = param; sbody = fn_body; sfun = value }
         :: more, rest'
       | _, Ast.Let_rec (bindings, lr_body) ->
         let lr_skels =
           List.map (fun (n, v) ->
             match v.Ast.node with
             | Ast.Fun (p, _, fb) ->
               { sname = n; sparam = p; sbody = fb; sfun = v }
             | _ ->
               raise (Error (v.Ast.loc,
                 "let rec inside top-level let value must bind a single-arg function")))
             bindings
         in
         let more, rest' = go { e with Ast.node = Ast.Let (pat, lr_body, rest) } in
         lr_skels @ more, rest'
       | _ ->
         let more, rest' = go rest in
         more, { e with Ast.node = Ast.Let (pat, value, rest') })
    | Ast.Let_rec (bindings, rest) ->
      let skels =
        List.map (fun (n, v) ->
          match v.Ast.node with
          | Ast.Fun (p, _, fb) ->
            { sname = n; sparam = p; sbody = fb; sfun = v }
          | _ ->
            raise (Error (v.Ast.loc,
              ("let rec binding must be a single-arg function in " ^ subset))))
          bindings
      in
      let more, rest' = go rest in
      skels @ more, rest'
    | _ -> [], e
  in
  go e

(* Find the first Var node with the given name in `e` whose recorded
   `.ty` walks to a concrete arrow type. Used to recover a monomorphic
   instantiation when the binding-site Fun.ty is left polymorphic by
   let-poly generalization. *)
let find_concrete_arrow (name : string) (e : Ast.expr) : Ast.ty option =
  let found = ref None in
  let rec go (e : Ast.expr) =
    (if !found = None then
       match e.Ast.node with
       | Ast.Var n when n = name ->
         (match e.Ast.ty with
          | Some t when ty_is_concrete (Ast.walk t) ->
            (match Ast.walk t with
             | Ast.TyArrow _ as ar -> found := Some ar
             | _ -> ())
          | _ -> ())
       | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a; go b
    | Ast.Neg a | Ast.Annot (a, _) -> go a
    | Ast.Let (_, v, b) -> go v; go b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
    | Ast.With (_, v, b) -> go v; go b
    | Ast.If (c, t, e_) -> go c; go t; go e_
    (* A fn parameter named `name` shadows an outer `name` in the body, so a
       prelude helper whose parameter is named like a user's top-level fn (e.g.
       list_fold's `f`) must not attribute its param's arrow type to that fn —
       which would force a bogus monomorphization and a C miscompile. Only the
       Fun binder is handled: a let / let-rec that binds `name` may itself be
       the definition of the poly fn whose use sites live in its body, so that
       body must still be scanned. *)
    | Ast.Fun (p, _, b) -> if p = name then () else go b
    | Ast.Constr (_, Some a) -> go a
    | Ast.Constr (_, None) -> ()
    (* A match-arm PATTERN that binds `name` shadows it for that arm's guard
       and body exactly as a Fun parameter does -- and unlike a let, an arm
       can never be the poly fn's own definition, so skipping it hides no
       use site. Without this, contrib/http/mount's
       `| Cons (MExact (m, p, _, h), rest) -> route m p h` attributed the
       pattern-bound `h`'s arrow to a user's top-level `h`, and the two arms'
       different arrows (`str -> str` / `str list -> str -> str`) made the
       C, LLVM and Wasm backends refuse a program they had always compiled. *)
    | Ast.Match (s, arms) ->
      go s;
      List.iter (fun (p, g, b) ->
        if List.mem name (pattern_vars p) then ()
        else ((match g with Some ge -> go ge | None -> ()); go b)) arms
    | Ast.Tuple es -> List.iter go es
    | Ast.Region_block (_, b) | Ast.Region_loop (_, _, b) -> go b
    | Ast.Ref (_, _, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  go e;
  !found

(* Recovery scan for a referenced-but-unresolved poly fn (its arrow kept a
   residual tyvar at every use, so the concrete-arrow discovery never saw
   it). Walks the expr but SKIPS the bound values of known top-level fns —
   those are the fn definitions themselves, emitted only if resolved — so a
   hit means the reference sits in code that will actually be emitted (the
   main spine or another emitted body). Accepts arrows with tyvars; the
   caller erases them. *)
let find_live_arrow (name : string) (skel_names : (string, unit) Hashtbl.t)
    (e : Ast.expr) : Ast.ty option =
  let found = ref None in
  let rec go (e : Ast.expr) =
    if !found <> None then () else begin
      (match e.Ast.node with
       | Ast.Var n when n = name ->
         (match e.Ast.ty with
          | Some t ->
            (match Ast.walk t with Ast.TyArrow _ as ar -> found := Some ar | _ -> ())
          | None -> ())
       | _ -> ());
      match e.Ast.node with
      | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
      | Ast.Unit_lit | Ast.Var _ -> ()
      | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
      | Ast.App (a, b) -> go a; go b
      | Ast.Neg a | Ast.Annot (a, _) -> go a
      | Ast.Let (pat, v, b) ->
        let skip =
          (match pat.Ast.pnode with
           | Ast.P_var n -> Hashtbl.mem skel_names n
           | _ -> false) in
        (if skip then () else go v); go b
      | Ast.Let_rec (bs, b) ->
        List.iter (fun (n, v) -> if Hashtbl.mem skel_names n then () else go v) bs;
        go b
      | Ast.With (_, v, b) -> go v; go b
      | Ast.If (c, t, e_) -> go c; go t; go e_
      | Ast.Fun (_, _, b) -> go b
      | Ast.Constr (_, Some a) -> go a
      | Ast.Constr (_, None) -> ()
      | Ast.Match (sc, arms) ->
        go sc;
        List.iter (fun (_, g, b) ->
          (match g with Some ge -> go ge | None -> ()); go b) arms
      | Ast.Tuple es -> List.iter go es
      | Ast.Region_block (_, b) | Ast.Region_loop (_, _, b) -> go b
      | Ast.Ref (_, _, a) -> go a
      | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
      | Ast.Field_get (a, _) -> go a
      | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
    end
  in
  go e;
  !found

(* Phase 23.1 (DEFERRED §1.7 multi-instantiation): collect ALL distinct
   concrete arrow types at use sites of `name`. Used to detect when a
   single-specialization emit would silently miscompile.

   Phase 23.3: takes a list of exprs to scan, so chained-poly multi-inst
   can include cloned bodies of already-specialized parent fns (e.g.,
   to detect rev_aux's multi-inst from rev's cloned bodies). *)
let find_all_concrete_arrows_in (name : string) (exprs : Ast.expr list) : Ast.ty list =
  let seen : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4 in
  let rec go (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.Var n when n = name ->
       (match e.Ast.ty with
        | Some t when ty_is_concrete (Ast.walk t) ->
          let walked = Ast.walk t in
          (match walked with
           | Ast.TyArrow _ ->
             let key = Ast.pp_ty walked in
             if not (Hashtbl.mem seen key) then Hashtbl.add seen key walked
           | _ -> ())
        | _ -> ())
     | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a; go b
    | Ast.Neg a | Ast.Annot (a, _) -> go a
    | Ast.Let (_, v, b) -> go v; go b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
    | Ast.With (_, v, b) -> go v; go b
    | Ast.If (c, t, e_) -> go c; go t; go e_
    (* A fn parameter named `name` shadows an outer `name` (see
       find_concrete_arrow); only the Fun binder is handled. *)
    | Ast.Fun (p, _, b) -> if p = name then () else go b
    | Ast.Constr (_, Some a) -> go a
    | Ast.Constr (_, None) -> ()
    (* A match-arm PATTERN that binds `name` shadows it for that arm's guard
       and body exactly as a Fun parameter does -- and unlike a let, an arm
       can never be the poly fn's own definition, so skipping it hides no
       use site. Without this, contrib/http/mount's
       `| Cons (MExact (m, p, _, h), rest) -> route m p h` attributed the
       pattern-bound `h`'s arrow to a user's top-level `h`, and the two arms'
       different arrows (`str -> str` / `str list -> str -> str`) made the
       C, LLVM and Wasm backends refuse a program they had always compiled. *)
    | Ast.Match (s, arms) ->
      go s;
      List.iter (fun (p, g, b) ->
        if List.mem name (pattern_vars p) then ()
        else ((match g with Some ge -> go ge | None -> ()); go b)) arms
    | Ast.Tuple es -> List.iter go es
    | Ast.Region_block (_, b) | Ast.Region_loop (_, _, b) -> go b
    | Ast.Ref (_, _, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  List.iter go exprs;
  Hashtbl.fold (fun _ v acc -> v :: acc) seen []

(* v0.1.99: specialize a let-generalized (polymorphic) *local* fn to its
   single concrete use type, as a pre-pass over the whole program before
   fn-type resolution and inner-fn lifting.

   A local `let f = fn ... in ...` is generalized by the typer, so its
   binding node keeps an unresolved scheme (residual TyVar) while each use
   site instantiates a fresh concrete copy. The C / LLVM backends lift such a
   local fn to a single top-level fn and `c_type_of` (resp. the LLVM type
   mapper) defaults the residual TyVar to int — so a local fn whose sole use
   is at, say, float is emitted as an int-typed C fn and the float call site
   mismatches. (The interpreter and Wasm handle the general case; this is the
   long-standing "local polymorphic fn not multi-instantiated" limitation the
   trait local-let support ran into — reproducible without traits.)

   When such a fn is used at exactly ONE concrete type, unifying the binding
   type with that use arrow propagates into the shared body (TyVars are
   mutable union-find refs), so the lifted fn and any generic callees inside
   its body (e.g. `list_fold`) resolve at the right type. Running this BEFORE
   resolve_fn_types is essential: the top-level multi-instantiator scans fn
   bodies for concrete arrows, and a generic callee used inside the local fn
   only becomes visible once the local fn's body is concrete (cf. the v0.1.28
   B-P2b poly-through-poly issue).

   Multiple distinct use types are left alone here (a single unify can't
   serve two types on one shared body); that is a separate, larger
   multi-instantiation increment. Zero concrete uses (fn only escapes as a
   value) is also left to the existing defaulting. *)
(* v0.1.182: does this name have a use whose arrow is not concrete yet?
   `find_all_concrete_arrows_in` only reports uses it can already read, and
   the single-use specialization below treated "exactly one concrete arrow"
   as "used at exactly one type". A use sitting inside a polymorphic fn is
   not concrete yet and is still a use — it resolves later, once that fn is
   instantiated, and it may resolve to a different type. Specializing on
   the strength of the one readable arrow fixed the definition at that type
   and the other instantiation was then emitted with the wrong body. *)
let has_unresolved_use_of (name : string) (exprs : Ast.expr list) : bool =
  let found = ref false in
  let rec go (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.Var n when n = name ->
       (match e.Ast.ty with
        | Some t when not (ty_is_concrete (Ast.walk t)) -> found := true
        | None -> found := true
        | _ -> ())
     | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a; go b
    | Ast.Neg a | Ast.Annot (a, _) -> go a
    | Ast.Let (_, v, b) -> go v; go b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
    | Ast.With (_, v, b) -> go v; go b
    | Ast.If (c, t, e_) -> go c; go t; go e_
    | Ast.Fun (p, _, b) -> if p <> name then go b
    | Ast.Constr (_, a) -> (match a with Some x -> go x | None -> ())
    | Ast.Match (s, arms) ->
      go s; List.iter (fun (_, g, b) ->
        (match g with Some ge -> go ge | None -> ()); go b) arms
    | Ast.Tuple es -> List.iter go es
    | Ast.Region_block (_, b) | Ast.Region_loop (_, _, b) -> go b
    | Ast.Ref (_, _, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, v) -> go v) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, v) -> go v) fs
  in
  List.iter go exprs; !found

let specialize_single_use_local_fns (root : Ast.expr) : unit =
  let rec go (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.Let ({ Ast.pnode = Ast.P_var n; _ },
                ({ Ast.node = Ast.Fun _; ty = Some vty; _ } as value), body)
       when not (ty_is_concrete (Ast.walk vty)) ->
       (match find_all_concrete_arrows_in n [body] with
        | [arrow] when not (has_unresolved_use_of n [body]) ->
          (try Typer.unify Loc.dummy vty arrow with _ -> ())
        | _ -> ());
       let _ = value in ()
     | Ast.Let_rec (bindings, body) ->
       (* Single-use specialization for a local `let rec` group, RESTRICTED to
          trait-constrained members (a dictionary-taking fn produced by
          trait_elab, whose first parameter is a `<Trait>__dict` record). This
          is exactly the local constrained recursive functions this targets;
          restricting to them avoids mis-specializing a genuinely polymorphic
          recursive function that is used at several types but whose float use
          is still hidden inside a caller's own polymorphism at this point
          (e.g. the prelude's `list_fold`, used at int in one prelude helper
          and at float through `reduce`) — committing such a fn to a single
          type would break its later multi-instantiation. A member's EXTERNAL
          uses live in the continuation and in siblings' bodies (mutual
          recursion); its own body is excluded so a self-call cannot stand in
          for an external use. *)
       let is_dict_taking t =
         match Ast.walk t with
         | Ast.TyArrow (a, _) ->
           (match Ast.walk a with
            | Ast.TyCon (nm, _) ->
              String.length nm >= 6
              && String.sub nm (String.length nm - 6) 6 = "__dict"
            | _ -> false)
         | _ -> false
       in
       List.iter (fun (n, value) ->
         match value.Ast.ty with
         | Some vty
           when not (ty_is_concrete (Ast.walk vty)) && is_dict_taking vty ->
           let scan_roots =
             body :: List.filter_map (fun (_, v) ->
               if v == value then None else Some v) bindings
           in
           (match find_all_concrete_arrows_in n scan_roots with
            | [arrow] -> (try Typer.unify Loc.dummy vty arrow with _ -> ())
            | _ -> ())
         | _ -> ()) bindings
     | _ -> ());
    (* Recurse into every sub-expression so nested local fns are handled. *)
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a; go b
    | Ast.Neg a | Ast.Annot (a, _) -> go a
    | Ast.Let (_, v, b) -> go v; go b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
    | Ast.With (_, v, b) -> go v; go b
    | Ast.If (c, t, e_) -> go c; go t; go e_
    | Ast.Fun (_, _, b) -> go b
    | Ast.Constr (_, Some a) -> go a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      go s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> go ge | None -> ()); go b) arms
    | Ast.Tuple es -> List.iter go es
    | Ast.Region_block (_, b) | Ast.Region_loop (_, _, b) -> go b
    | Ast.Ref (_, _, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  go root

(* Phase 23.3: deep-clone an expression with fresh tyvars.
   For multi-instantiation specialization of poly fns: the original
   body's tyvars are shared (mutable refs) so we can't independently
   unify them to different concrete types. Cloning produces a body
   tree where every TyVar.id is fresh and link=None. Tyvar identity
   within the clone is preserved via a per-clone id→fresh map.

   Concrete types (TyInt, TyArrow with no vars, etc.) are recreated
   structurally — cheap and correct. TyParam (source-level 'a) is
   preserved as-is. *)
let clone_with_fresh_tyvars (e : Ast.expr) : Ast.expr =
  let map : (int, Ast.ty) Hashtbl.t = Hashtbl.create 16 in
  let rec clone_ty t =
    match Ast.walk t with
    | Ast.TyVar v ->
      (match Hashtbl.find_opt map v.id with
       | Some fresh -> fresh
       | None ->
         let fresh = Typer.fresh_var () in
         Hashtbl.add map v.id fresh;
         fresh)
    | Ast.TyParam _ as t -> t
    | (Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyBytes | Ast.TyUnit) as t -> t
    | Ast.TyArrow (a, b) -> Ast.TyArrow (clone_ty a, clone_ty b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map clone_ty ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map clone_ty args)
    | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, clone_ty inner)
  in
  let clone_ty_opt = function None -> None | Some t -> Some (clone_ty t) in
  let rec clone_expr (e : Ast.expr) : Ast.expr =
    { Ast.loc = e.Ast.loc;
      ty = clone_ty_opt e.Ast.ty;
      node = clone_node e.Ast.node }
  and clone_node = function
    | (Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _
       | Ast.Str_lit _ | Ast.Unit_lit | Ast.Var _) as n -> n
    | Ast.Bin (op, a, b) -> Ast.Bin (op, clone_expr a, clone_expr b)
    | Ast.Cmp (op, a, b) -> Ast.Cmp (op, clone_expr a, clone_expr b)
    | Ast.Logic (op, a, b) -> Ast.Logic (op, clone_expr a, clone_expr b)
    | Ast.Neg a -> Ast.Neg (clone_expr a)
    | Ast.Let (p, v, b) -> Ast.Let (clone_pattern p, clone_expr v, clone_expr b)
    | Ast.Let_rec (bs, b) ->
      Ast.Let_rec (List.map (fun (n, e) -> (n, clone_expr e)) bs, clone_expr b)
    | Ast.With (n, v, b) -> Ast.With (n, clone_expr v, clone_expr b)
    | Ast.If (c, t, e_) -> Ast.If (clone_expr c, clone_expr t, clone_expr e_)
    | Ast.Fun (n, t_opt, b) ->
      Ast.Fun (n, (match t_opt with None -> None | Some t -> Some (clone_ty t)),
        clone_expr b)
    | Ast.App (a, b) -> Ast.App (clone_expr a, clone_expr b)
    | Ast.Annot (a, t) -> Ast.Annot (clone_expr a, clone_ty t)
    | Ast.Constr (n, Some a) -> Ast.Constr (n, Some (clone_expr a))
    | Ast.Constr (n, None) -> Ast.Constr (n, None)
    | Ast.Match (s, arms) ->
      Ast.Match (clone_expr s,
        List.map (fun (p, g, b) ->
          (clone_pattern p,
           (match g with None -> None | Some e -> Some (clone_expr e)),
           clone_expr b)) arms)
    | Ast.Tuple es -> Ast.Tuple (List.map clone_expr es)
    | Ast.Region_block (n, b) -> Ast.Region_block (n, clone_expr b)
    | Ast.Region_loop (n, x, b) -> Ast.Region_loop (n, x, clone_expr b)
    | Ast.Ref (m, r, a) -> Ast.Ref (m, r, clone_expr a)
    | Ast.Record_lit (n, fs) ->
      Ast.Record_lit (n, List.map (fun (k, v) -> (k, clone_expr v)) fs)
    | Ast.Field_get (a, f) -> Ast.Field_get (clone_expr a, f)
    | Ast.Record_update (a, fs) ->
      Ast.Record_update (clone_expr a,
        List.map (fun (k, v) -> (k, clone_expr v)) fs)
  and clone_pattern p =
    { Ast.ploc = p.Ast.ploc; pnode = clone_pattern_node p.Ast.pnode }
  and clone_pattern_node = function
    | (Ast.P_wild | Ast.P_var _ | Ast.P_int _ | Ast.P_bool _
       | Ast.P_str _ | Ast.P_unit) as n -> n
    | Ast.P_constr (c, Some sub) -> Ast.P_constr (c, Some (clone_pattern sub))
    | Ast.P_constr (c, None) -> Ast.P_constr (c, None)
    | Ast.P_tuple ps -> Ast.P_tuple (List.map clone_pattern ps)
    | Ast.P_record (n, fs) ->
      Ast.P_record (n, List.map (fun (k, v) -> (k, clone_pattern v)) fs)
    | Ast.P_as (p, n) -> Ast.P_as (clone_pattern p, n)
    | Ast.P_or (a, b) -> Ast.P_or (clone_pattern a, clone_pattern b)
  in
  clone_expr e

(* v0.1.105 (① increment 2): duplicate a local `let f = fn ... in body` whose
   fn is used at SEVERAL distinct concrete types into one monomorphic copy per
   type, rewriting each use to its copy. This turns the unsolved
   "multi-instantiate a lifted local fn" problem into the already-solved
   "monomorphic lifted fn" case, so every backend that can lift a monomorphic
   local fn now handles the multi-type case too (`let id = fn x -> x in
   (id 1, id 1.5)` and friends). The interpreter and Wasm already handled this;
   the C backend defaulted such a fn to a single type and miscompiled.

   Conservative on purpose: fires ONLY when the fn is non-recursive, is not
   shadowed anywhere in its body, and EVERY use of it in the body is at a
   concrete type (so removing the original binding leaves no dangling
   polymorphic reference). Otherwise the binding is left untouched — no worse
   than before. Runs before specialize_single_use_local_fns and fn lifting. *)
let dup_local_counter = ref 0

let duplicate_multi_use_local_fns (root : Ast.expr) : Ast.expr =
  dup_local_counter := 0;
  let mk node = { Ast.loc = Loc.dummy; ty = None; node } in
  (* Walk `e`, collecting the distinct concrete arrow types at which `Var f` is
     used, and flagging (a) any non-concrete use of f and (b) any binder that
     shadows f. Stops descending into a scope that rebinds f. *)
  let analyze f e0 =
    let arrows : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4 in
    let nonconcrete = ref false in
    let shadowed = ref false in
    let rec go e =
      match e.Ast.node with
      | Ast.Var n when n = f ->
        (match e.Ast.ty with
         | Some t when ty_is_concrete (Ast.walk t) ->
           let w = Ast.walk t in
           (match w with
            | Ast.TyArrow _ ->
              let k = Ast.pp_ty w in
              if not (Hashtbl.mem arrows k) then Hashtbl.add arrows k w
            | _ -> nonconcrete := true)
         | _ -> nonconcrete := true)
      | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
      | Ast.Unit_lit | Ast.Var _ -> ()
      | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
      | Ast.App (a, b) -> go a; go b
      | Ast.Neg a | Ast.Annot (a, _) -> go a
      | Ast.Let (p, v, b) ->
        go v; if List.mem f (pattern_vars p) then shadowed := true else go b
      | Ast.Let_rec (bs, b) ->
        if List.exists (fun (n, _) -> n = f) bs then shadowed := true
        else (List.iter (fun (_, v) -> go v) bs; go b)
      | Ast.With (n, v, b) -> go v; if n = f then shadowed := true else go b
      | Ast.If (c, t, el) -> go c; go t; go el
      | Ast.Fun (p, _, b) -> if p = f then shadowed := true else go b
      | Ast.Constr (_, Some a) -> go a
      | Ast.Constr (_, None) -> ()
      | Ast.Match (s, arms) ->
        go s;
        List.iter (fun (p, g, b) ->
          if List.mem f (pattern_vars p) then shadowed := true
          else ((match g with Some ge -> go ge | None -> ()); go b)) arms
      | Ast.Tuple es -> List.iter go es
      | Ast.Region_block (_, b) | Ast.Region_loop (_, _, b) -> go b
      | Ast.Ref (_, _, a) -> go a
      | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
      | Ast.Field_get (a, _) -> go a
      | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
    in
    go e0;
    (Hashtbl.fold (fun _ v acc -> v :: acc) arrows [], !nonconcrete, !shadowed)
  in
  (* Replace each `Var f : Ti` with `Var (name_of Ti)`. No shadowing (checked). *)
  let rewrite_uses f name_of e0 =
    let rec rw e =
      let node = match e.Ast.node with
        | Ast.Var n when n = f ->
          (match e.Ast.ty with
           | Some t -> (match name_of (Ast.pp_ty (Ast.walk t)) with
                        | Some nm -> Ast.Var nm | None -> e.Ast.node)
           | None -> e.Ast.node)
        | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
        | Ast.Unit_lit | Ast.Var _ -> e.Ast.node
        | Ast.Bin (op, a, b) -> Ast.Bin (op, rw a, rw b)
        | Ast.Cmp (op, a, b) -> Ast.Cmp (op, rw a, rw b)
        | Ast.Logic (op, a, b) -> Ast.Logic (op, rw a, rw b)
        | Ast.App (a, b) -> Ast.App (rw a, rw b)
        | Ast.Neg a -> Ast.Neg (rw a)
        | Ast.Annot (a, t) -> Ast.Annot (rw a, t)
        | Ast.Let (p, v, b) -> Ast.Let (p, rw v, rw b)
        | Ast.Let_rec (bs, b) ->
          Ast.Let_rec (List.map (fun (n, v) -> (n, rw v)) bs, rw b)
        | Ast.With (n, v, b) -> Ast.With (n, rw v, rw b)
        | Ast.If (c, t, el) -> Ast.If (rw c, rw t, rw el)
        | Ast.Fun (p, t, b) -> Ast.Fun (p, t, rw b)
        | Ast.Constr (c, a) -> Ast.Constr (c, Option.map rw a)
        | Ast.Match (s, arms) ->
          Ast.Match (rw s,
            List.map (fun (p, g, b) -> (p, Option.map rw g, rw b)) arms)
        | Ast.Tuple es -> Ast.Tuple (List.map rw es)
        | Ast.Region_block (r, b) -> Ast.Region_block (r, rw b)
        | Ast.Region_loop (r, x, b) -> Ast.Region_loop (r, x, rw b)
        | Ast.Ref (m, r, a) -> Ast.Ref (m, r, rw a)
        | Ast.Record_lit (n, fs) ->
          Ast.Record_lit (n, List.map (fun (fn, v) -> (fn, rw v)) fs)
        | Ast.Field_get (a, fn) -> Ast.Field_get (rw a, fn)
        | Ast.Record_update (a, fs) ->
          Ast.Record_update (rw a, List.map (fun (fn, v) -> (fn, rw v)) fs)
      in { e with Ast.node }
    in rw e0
  in
  (* `in_fn` is true once we are inside some function body. Only fns nested in
     a function body are LOCAL; the outermost `let` chain of the desugared
     program is the top-level fns, which the ordinary multi-instantiation
     machinery already handles — transforming those would preempt it and rename
     their instances. *)
  let rec go2 (in_fn : bool) (e : Ast.expr) : Ast.expr =
    let go = go2 in_fn in
    match e.Ast.node with
    | Ast.Let ({ Ast.pnode = Ast.P_var f; _ } as pat,
               ({ Ast.node = Ast.Fun _; ty = Some vty; _ } as value), body)
      when in_fn && not (ty_is_concrete (Ast.walk vty)) ->
      let arrows, nonconcrete, shadowed = analyze f body in
      if List.length arrows >= 2 && not nonconcrete && not shadowed then begin
        (* One monomorphic copy per distinct concrete use type. *)
        let named =
          List.map (fun arr ->
            let k = !dup_local_counter in
            incr dup_local_counter;
            (Printf.sprintf "%s__mi%d" f k, arr)) arrows
        in
        let name_of key =
          let rec find = function
            | (nm, arr) :: rest ->
              if Ast.pp_ty (Ast.walk arr) = key then Some nm else find rest
            | [] -> None
          in find named
        in
        let body' = go (rewrite_uses f name_of body) in
        List.fold_right (fun (nm, arr) acc ->
          let cl = clone_with_fresh_tyvars value in
          (match cl.Ast.ty with
           | Some t -> (try Typer.unify Loc.dummy t arr with _ -> ())
           | None -> ());
          mk (Ast.Let ({ Ast.ploc = Loc.dummy; pnode = Ast.P_var nm },
                       go cl, acc))) named body'
      end else
        { e with Ast.node = Ast.Let (pat, go value, go body) }
    | Ast.Let_rec ([(f, ({ Ast.node = Ast.Fun _; ty = Some vty; _ } as value))],
                   body)
      when in_fn && not (ty_is_concrete (Ast.walk vty)) ->
      (* Single self-recursive local `let rec f = fn ... in body` used at
         several concrete types: one monomorphic copy per type, with the
         recursive self-call inside each copy redirected to that copy. Mutual
         (multi-binding) groups at several types are left alone (rarer; still a
         backend limitation). Requires the value not to shadow `f` internally,
         so the unconditional self-rename below is safe. *)
      let arrows, nonconcrete, body_shadow = analyze f body in
      let _, _, val_shadow = analyze f value in
      if List.length arrows >= 2 && not nonconcrete
         && not body_shadow && not val_shadow then begin
        let named =
          List.map (fun arr ->
            let k = !dup_local_counter in
            incr dup_local_counter;
            (Printf.sprintf "%s__mi%d" f k, arr)) arrows
        in
        let name_of key =
          let rec find = function
            | (nm, arr) :: rest ->
              if Ast.pp_ty (Ast.walk arr) = key then Some nm else find rest
            | [] -> None
          in find named
        in
        let body' = go (rewrite_uses f name_of body) in
        List.fold_right (fun (nm, arr) acc ->
          let cl = clone_with_fresh_tyvars value in
          (match cl.Ast.ty with
           | Some t -> (try Typer.unify Loc.dummy t arr with _ -> ())
           | None -> ());
          (* Redirect the recursive self-call f -> nm inside the copy. *)
          let cl = rewrite_uses f (fun _ -> Some nm) cl in
          mk (Ast.Let_rec ([(nm, go cl)], acc))) named body'
      end else
        { e with Ast.node =
            Ast.Let_rec ([(f, go value)], go body) }
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> e
    | Ast.Bin (op, a, b) -> { e with Ast.node = Ast.Bin (op, go a, go b) }
    | Ast.Cmp (op, a, b) -> { e with Ast.node = Ast.Cmp (op, go a, go b) }
    | Ast.Logic (op, a, b) -> { e with Ast.node = Ast.Logic (op, go a, go b) }
    | Ast.App (a, b) -> { e with Ast.node = Ast.App (go a, go b) }
    | Ast.Neg a -> { e with Ast.node = Ast.Neg (go a) }
    | Ast.Annot (a, t) -> { e with Ast.node = Ast.Annot (go a, t) }
    | Ast.Let (p, v, b) -> { e with Ast.node = Ast.Let (p, go v, go b) }
    | Ast.Let_rec (bs, b) ->
      { e with Ast.node =
          Ast.Let_rec (List.map (fun (n, v) -> (n, go v)) bs, go b) }
    | Ast.With (n, v, b) -> { e with Ast.node = Ast.With (n, go v, go b) }
    | Ast.If (c, t, el) -> { e with Ast.node = Ast.If (go c, go t, go el) }
    | Ast.Fun (p, t, b) ->
      (* Entering a function body: everything below is now local. *)
      { e with Ast.node = Ast.Fun (p, t, go2 true b) }
    | Ast.Constr (c, a) -> { e with Ast.node = Ast.Constr (c, Option.map go a) }
    | Ast.Match (s, arms) ->
      { e with Ast.node =
          Ast.Match (go s,
            List.map (fun (p, g, b) -> (p, Option.map go g, go b)) arms) }
    | Ast.Tuple es -> { e with Ast.node = Ast.Tuple (List.map go es) }
    | Ast.Region_block (r, b) -> { e with Ast.node = Ast.Region_block (r, go b) }
    | Ast.Region_loop (r, x, b) -> { e with Ast.node = Ast.Region_loop (r, x, go b) }
    | Ast.Ref (m, r, a) -> { e with Ast.node = Ast.Ref (m, r, go a) }
    | Ast.Record_lit (n, fs) ->
      { e with Ast.node =
          Ast.Record_lit (n, List.map (fun (fn, v) -> (fn, go v)) fs) }
    | Ast.Field_get (a, fn) -> { e with Ast.node = Ast.Field_get (go a, fn) }
    | Ast.Record_update (a, fs) ->
      { e with Ast.node =
          Ast.Record_update (go a, List.map (fun (fn, v) -> (fn, go v)) fs) }
  in
  go2 false root

(* Build fn_decls from the typer-annotated AST. For each skeleton, prefer
   the Fun's own .ty if it's already concrete; otherwise (let-poly
   generalized it) recover a concrete arrow type by scanning the main
   expression for a use-site Var with the same name. *)
(* Which names are multi-instantiated and at which arrows -- AND the namer that
   produced the specializations. The two travel together on purpose.
   `mangle` is per-backend: the C tagger erases a residual type variable to
   `int` and defaults a container's unresolved region slot to `__heap`, LLVM's
   raises on both, and Wasm's spells Map differently. Any of those is a fine
   name for a symbol inside one backend; what is not fine is the pass naming a
   specialization one way while a call site names it another, which is an
   undefined symbol at best. Handing the table the namer that built it makes
   that disagreement unrepresentable rather than merely unlikely.

   Returned rather than published into a module global -- see the header: a
   global is how one backend's run would land in another's table. *)
type inst_table = {
  arrows : (string, Ast.ty list) Hashtbl.t;
  mangle : string -> Ast.ty -> string;
}

let empty_inst_table ?(mangle = mangled_inst_name) () =
  { arrows = Hashtbl.create 4; mangle }

(* Is this name multi-instantiated? (So there is no single function to hand out
   as a value, and a direct call has to pick an instance.) *)
let is_multi (tbl : inst_table) (n : string) : bool = Hashtbl.mem tbl.arrows n

let multi_names (tbl : inst_table) : string list =
  Hashtbl.fold (fun k _ acc -> k :: acc) tbl.arrows []

(* The emitted name for a reference to `n` whose use site has type `use_ty`.
   `None` means `n` IS multi-instantiated but this use site's type has not
   resolved to a concrete arrow, so no instance can be named for it -- the
   callers differ on what to do about that (fall back to the source name, or
   decline the direct-call path), which is why this reports rather than
   decides.

   Every backend picks its instance HERE. The rule used to be written out at
   each dispatch site of each backend; copies of one rule is how the copies
   stop agreeing. *)
let instance_of (tbl : inst_table) (n : string) (use_ty : Ast.ty option)
  : string option =
  if not (Hashtbl.mem tbl.arrows n) then Some n
  else
    match use_ty with
    | Some t ->
      (match Ast.walk t with
       | Ast.TyArrow _ as arrow -> Some (tbl.mangle n arrow)
       | _ -> None)
    | None -> None

let resolve_fn_types ?(mangle = mangled_inst_name)
    (skels : fn_skel list) (root : Ast.expr)
  : fn_decl list * inst_table =
  (* Phase 21.1 (DEFERRED §1.7) + 21.2 multi-pass:
     - Each pass tries to resolve each yet-unresolved fn by either (a)
       observing its Fun.ty has become concrete via prior unify, or (b)
       calling find_concrete_arrow to locate an external use site, then
       unifying.
     - Repeat until no progress. This handles chained poly helpers
       (e.g., list_rev calls list_rev_into; once list_rev is unified
       via its top-level use, list_rev_into's Var inside list_rev's
       body has concrete .ty and find_concrete_arrow picks it up next
       pass).
     - Unused poly fns (stdlib helpers user didn't reference) stay
       unresolved and are silently filtered out. *)
  let resolved : (string, Ast.ty) Hashtbl.t = Hashtbl.create 16 in
  let progress = ref true in
  let multi_inst_fns : (string, Ast.ty list) Hashtbl.t = Hashtbl.create 4 in
  let multi_specs : (string, (Ast.ty * Ast.expr) list) Hashtbl.t =
    Hashtbl.create 4
  in
  (* v0.1.28 (generic-PQ dogfood B-P2b): keep a PRISTINE clone of every
     skel before any unification. Single-resolution unifies the original
     fn's tyvars in place, which destroys the polymorphic skeleton — so a
     fn first seen at one type could never be promoted to multi-inst when
     a second type shows up later (see the promotion branch below).
     Cloning specs from the pristine copy keeps every instantiation
     possible at any point in the fixpoint loop. *)
  let pristine : (string, Ast.expr) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun s ->
    Hashtbl.replace pristine s.sname (clone_with_fresh_tyvars s.sfun)) skels;
  (* Phase 43 (DEFERRED §1.7 fix): the clone helper for multi-inst, reused
     in 2 paths (initial scan + re-scan of existing multi_specs entries
     when new instantiations are discovered). *)
  let make_spec arrow s =
    let cloned_fun = clone_with_fresh_tyvars (Hashtbl.find pristine s.sname) in
    let clone_fun_ty =
      match cloned_fun.Ast.ty with
      | Some t -> Ast.walk t
      | None -> Ast.TyUnit
    in
    (* v0.1.179: this used to swallow the failure, and a spec whose clone
       will not take the target arrow is a spec whose body belongs to a
       different type. It was emitted anyway — the declaration got the right
       signature and the body kept the operations of whatever type the
       skeleton was already fixed at. Refusing is not the fix; it is the
       difference between a wrong program and a named one. See
       test/parity/poly_helper_fixed_and_free.mere. *)
    (try Typer.unify Loc.dummy clone_fun_ty arrow
     with _ ->
       unsupported s.sfun.Ast.loc (Printf.sprintf
         "unsupported: cannot instantiate `%s` at %s — its skeleton is \
          already fixed at %s, so this instance would be emitted with the \
          other one's body. A polymorphic helper called at both a fixed type \
          and a parameter-derived type, inside a fn used at two types, hits \
          this."
         s.sname (Ast.pp_ty (Ast.walk arrow))
         (Ast.pp_ty (Ast.walk clone_fun_ty))));
    let cloned_body =
      match cloned_fun.Ast.node with
      | Ast.Fun (_, _, b) -> b
      | _ ->
        raise (Error (s.sfun.Ast.loc,
          "multi-inst clone: expected Fun at root"))
    in
    (arrow, cloned_body)
  in
  while !progress do
    progress := false;
    List.iter (fun s ->
      let extra_exprs () =
        Hashtbl.fold (fun _ specs acc ->
          List.fold_left (fun acc (_, body) -> body :: acc) acc specs
        ) multi_specs []
        (* v0.1.28 (B-P2b): also scan the bodies of single-resolved poly
           fns. A usage of poly fn B inside poly fn A's body only becomes
           concrete once A resolves — before this, B's arrow-discovery
           scan never saw it, so B stayed single-instantiated at some
           OTHER type and the emitted C called B's body with mismatched
           struct types (found: a generic heap's `drain` calling `hp_pop`
           at int while hp_pop resolved at tuple). *)
        @ List.filter_map (fun s2 ->
            if Hashtbl.mem resolved s2.sname then Some s2.sbody else None)
            skels
      in
      if Hashtbl.mem resolved s.sname then begin
        (* v0.1.28 (B-P2b): a fn resolved to a single instance may be
           discovered at a second type later (its other usage sites live
           in poly-fn bodies that resolve in later passes). Promote it to
           multi-inst: drop the single resolution and clone one spec per
           arrow from the pristine skeleton. *)
        let all = find_all_concrete_arrows_in s.sname (root :: extra_exprs ()) in
        let cur = Hashtbl.find resolved s.sname in
        let cur_str = Ast.pp_ty (Ast.walk cur) in
        let extra = List.filter (fun a ->
          Ast.pp_ty (Ast.walk a) <> cur_str) all in
        (* Dedup the extras among themselves. *)
        let extra =
          let seen = Hashtbl.create 4 in
          List.filter (fun a ->
            let k = Ast.pp_ty (Ast.walk a) in
            if Hashtbl.mem seen k then false
            else (Hashtbl.add seen k (); true)) extra
        in
        if extra <> [] then begin
          Hashtbl.remove resolved s.sname;
          let arrows = cur :: extra in
          Hashtbl.replace multi_inst_fns s.sname arrows;
          Hashtbl.replace multi_specs s.sname
            (List.map (fun a -> make_spec a s) arrows);
          progress := true
        end
      end
      else if Hashtbl.mem multi_specs s.sname then begin
        (* Phase 43 fix (DEFERRED §1.7): re-scan multi-inst fns each pass.
           When a chained poly call site becomes concrete in a later pass
           (e.g., `let bool_eq = fn b -> poly_eq true b` resolves bool ->
           int → bool_eq's body's `poly_eq true b` adds bool arrow to
           poly_eq specs), grow the spec list. *)
        let all = find_all_concrete_arrows_in s.sname (root :: extra_exprs ()) in
        let existing = Hashtbl.find multi_specs s.sname in
        let existing_arrows = List.map fst existing in
        (* Type equality via pp_ty string compare (simple but sufficient — same
           pattern used by ty_tag for naming) *)
        let new_arrows = List.filter (fun a ->
          let a_str = Ast.pp_ty (Ast.walk a) in
          not (List.exists (fun e -> Ast.pp_ty (Ast.walk e) = a_str) existing_arrows)) all
        in
        if new_arrows <> [] then begin
          let new_specs = List.map (fun a -> make_spec a s) new_arrows in
          Hashtbl.replace multi_specs s.sname (existing @ new_specs);
          (* multi_inst_fns is used by emit_expr to pick mangled name;
             keep the arrow list in sync. *)
          Hashtbl.replace multi_inst_fns s.sname (existing_arrows @ new_arrows);
          progress := true
        end
      end
      else begin
        let fun_ty =
          match s.sfun.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
        in
        if ty_is_concrete fun_ty then begin
          Hashtbl.add resolved s.sname fun_ty;
          progress := true
        end else
          let all = find_all_concrete_arrows_in s.sname (root :: extra_exprs ()) in
          match all with
          | _ :: _ ->
            if List.length all > 1 then begin
              Hashtbl.add multi_inst_fns s.sname all;
              let specs = List.map (fun arrow -> make_spec arrow s) all in
              Hashtbl.add multi_specs s.sname specs;
              progress := true
            end else begin
              (try Typer.unify Loc.dummy fun_ty (List.hd all) with _ -> ());
              Hashtbl.add resolved s.sname (List.hd all);
              progress := true
            end
          | [] -> ()
      end
    ) skels
  done;
  let base = List.concat_map (fun s ->
    match Hashtbl.find_opt multi_specs s.sname with
    | Some specs ->
      (* v0.1.66 (mere-ruby dogfood): dedup specs by their emitted C symbol
         before producing fn_decls. The spec list is grown across resolution
         passes from per-use-site arrows, so a fn called from many sites can
         accumulate several specs that mangle to the SAME name (identical
         concrete type, or types differing only in a region variable that
         ty_tag erases). Emitting one fn_decl per spec then produces
         duplicate C definitions → "redefinition" build failure. Keying on
         mangled_inst_name collapses same-symbol specs; distinct
         instantiations (distinct symbols) are preserved. *)
      let specs =
        let seen = Hashtbl.create 4 in
        List.filter (fun (arrow, _) ->
          let k = mangle s.sname arrow in
          if Hashtbl.mem seen k then false
          else (Hashtbl.add seen k (); true)) specs
      in
      (* Emit one fn_decl per instantiation, mangled name + cloned body. *)
      List.map (fun (arrow, cloned_body) ->
        match Ast.walk arrow with
        | Ast.TyArrow (p, r) ->
          { name = mangle s.sname arrow;
            param = s.sparam;
            body = cloned_body;
            param_ty = Ast.walk p;
            return_ty = Ast.walk r }
        | other ->
          raise (Error (s.sfun.Ast.loc,
            Printf.sprintf "function `%s` has non-arrow inferred type `%s`"
              s.sname (Ast.pp_ty other)))
      ) specs
    | None ->
      (match Hashtbl.find_opt resolved s.sname with
       | None -> []  (* unused poly fn — skip *)
       | Some (Ast.TyArrow (p, r)) ->
         [{ name = s.sname; param = s.sparam; body = s.sbody;
            param_ty = Ast.walk p; return_ty = Ast.walk r }]
       | Some other ->
         raise (Error (s.sfun.Ast.loc,
           Printf.sprintf "function `%s` has non-arrow inferred type `%s`"
             s.sname (Ast.pp_ty other))))
  ) skels
  in
  (* Recovery pass: a poly fn that never concretized is normally dead code
     (an unused helper) and is dropped. But if EMITTED code still references
     it — its arrow kept a residual tyvar at every use site, e.g. a producer
     argument whose result is the bottom type of an endless loop — the call
     site would emit a direct call to an undefined symbol. Scan the emitted
     spine (root minus skel definitions, plus emitted bodies) for such live
     references and emit the fn with its tyvars erased to int (matching the
     emission layer's erasure). Fixpoint: a recovered body may itself
     reference another unresolved fn. *)
  let skel_names : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun s -> Hashtbl.replace skel_names s.sname ()) skels;
  let emitted_bodies =
    ref (root :: List.map (fun (f : fn_decl) -> f.body) base) in
  let recovered_names : (string, unit) Hashtbl.t = Hashtbl.create 4 in
  let recovered = ref [] in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter (fun s ->
      if not (Hashtbl.mem resolved s.sname)
         && not (Hashtbl.mem multi_specs s.sname)
         && not (Hashtbl.mem recovered_names s.sname) then begin
        let hit =
          List.fold_left (fun acc e ->
            match acc with
            | Some _ -> acc
            | None -> find_live_arrow s.sname skel_names e) None !emitted_bodies
        in
        match hit with
        | Some ar ->
          (match deep_erase_tyvars ar with
           | Ast.TyArrow (p, r) ->
             Hashtbl.replace recovered_names s.sname ();
             recovered := { name = s.sname; param = s.sparam; body = s.sbody;
                            param_ty = p; return_ty = r } :: !recovered;
             emitted_bodies := s.sbody :: !emitted_bodies;
             changed := true
           | _ -> ())
        | None -> ()
      end) skels
  done;
  base @ List.rev !recovered, { arrows = multi_inst_fns; mangle }

(* --- Q-102: the same answer, as an AST -> AST rewrite ---------------------
   A backend that carries types to emit time picks the instance THERE, from the
   use site's recorded type (that is what `instance_of` is for, and what the C
   backend does at its three dispatch sites). The RISC-V backend cannot: its
   values are untagged machine words and its emitter reads `.ty` only to choose
   an instruction sequence. So it needs the answer in the tree instead --
   specialized functions bound under their mangled names, and every reference
   that names one already saying so.

   That is all this does: it adds bindings and renames references. The original
   polymorphic binding stays. A reference this pass could not resolve (its arrow
   still holds a type variable at the use site) still has to name something, and
   leaving the original means such a program compiles exactly as it did before
   instead of failing to find a label. An original that nothing references is
   dropped by the backend's own reachability, not by this. *)

module StrSet = Set.Make (String)

(* Rewrite every reference that names an instance, honouring shadowing: a local
   binding of the same name is a DIFFERENT `f`, and renaming its references to a
   top-level instance is a miscompile. The C backend makes this check at emit
   time against its own scope tracking; as a tree rewrite the bound set has to
   be carried. The prelude's `list_fold` parameter `f` against a user's
   top-level `let f` is the case that made the C backend grow that check, so it
   is not hypothetical.

   The TOP-LEVEL let chain is deliberately not a binder here. The desugared
   program IS a chain of `Let`s, so counting them as shadowing would mark every
   top-level function as shadowed by its own definition and rewrite nothing --
   green, and doing nothing. `rw_spine` walks that chain; `rw` walks everything
   under it, where a binder really is one. *)
let rewrite_instance_refs (tbl : inst_table) (root : Ast.expr) : Ast.expr =
  let rec rw (bound : StrSet.t) (e : Ast.expr) : Ast.expr =
    let node =
      match e.Ast.node with
      | Ast.Var n when not (StrSet.mem n bound) ->
        (match instance_of tbl n e.Ast.ty with
         | Some m -> Ast.Var m
         | None -> e.Ast.node)
      | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
      | Ast.Unit_lit | Ast.Var _ -> e.Ast.node
      | Ast.Bin (op, a, b) -> Ast.Bin (op, rw bound a, rw bound b)
      | Ast.Cmp (op, a, b) -> Ast.Cmp (op, rw bound a, rw bound b)
      | Ast.Logic (op, a, b) -> Ast.Logic (op, rw bound a, rw bound b)
      | Ast.Neg a -> Ast.Neg (rw bound a)
      | Ast.Annot (a, t) -> Ast.Annot (rw bound a, t)
      | Ast.App (a, b) -> Ast.App (rw bound a, rw bound b)
      | Ast.Let (p, v, b) ->
        Ast.Let (p, rw bound v, rw (bind_pattern bound p) b)
      | Ast.Let_rec (bs, b) ->
        let bound' =
          List.fold_left (fun s (n, _) -> StrSet.add n s) bound bs in
        Ast.Let_rec (List.map (fun (n, v) -> (n, rw bound' v)) bs, rw bound' b)
      | Ast.With (n, v, b) -> Ast.With (n, rw bound v, rw (StrSet.add n bound) b)
      | Ast.If (c, t, el) -> Ast.If (rw bound c, rw bound t, rw bound el)
      | Ast.Fun (p, t, b) -> Ast.Fun (p, t, rw (StrSet.add p bound) b)
      | Ast.Constr (c, a) -> Ast.Constr (c, Option.map (rw bound) a)
      | Ast.Match (s, arms) ->
        Ast.Match (rw bound s,
          List.map (fun (p, g, b) ->
            let b' = bind_pattern bound p in
            (p, Option.map (rw b') g, rw b' b)) arms)
      | Ast.Tuple es -> Ast.Tuple (List.map (rw bound) es)
      | Ast.Region_block (r, b) -> Ast.Region_block (r, rw bound b)
      | Ast.Region_loop (r, x, b) ->
        Ast.Region_loop (r, x, rw (StrSet.add x bound) b)
      | Ast.Ref (m, r, a) -> Ast.Ref (m, r, rw bound a)
      | Ast.Record_lit (n, fs) ->
        Ast.Record_lit (n, List.map (fun (k, v) -> (k, rw bound v)) fs)
      | Ast.Field_get (a, f) -> Ast.Field_get (rw bound a, f)
      | Ast.Record_update (a, fs) ->
        Ast.Record_update (rw bound a, List.map (fun (k, v) -> (k, rw bound v)) fs)
    in
    { e with Ast.node = node }
  and bind_pattern bound p =
    List.fold_left (fun s n -> StrSet.add n s) bound (pattern_vars p)
  in
  let rec rw_spine (e : Ast.expr) : Ast.expr =
    match e.Ast.node with
    | Ast.Let (p, v, b) ->
      { e with Ast.node = Ast.Let (p, rw StrSet.empty v, rw_spine b) }
    | Ast.Let_rec (bs, b) ->
      { e with Ast.node =
          Ast.Let_rec (List.map (fun (n, v) -> (n, rw StrSet.empty v)) bs,
                       rw_spine b) }
    | _ -> rw StrSet.empty e
  in
  rw_spine root

(* Run the whole pass and hand back a program whose polymorphic top-level
   functions have been replaced, at every use site that names a type, by
   monomorphic ones. The local-function pre-passes run in the same order the C
   backend runs them: `specialize_single_use_local_fns` in particular has to
   come before the fixpoint, because a generic callee used inside a local
   polymorphic fn only becomes visible to arrow discovery once that local fn's
   body is concrete. *)
let specialize_toplevel (root : Ast.expr) : Ast.expr =
  let root = duplicate_multi_use_local_fns root in
  specialize_single_use_local_fns root;
  let skels, _residual = lift_fn_skels root in
  let decls, insts = resolve_fn_types skels root in
  if Hashtbl.length insts.arrows = 0 then root
  else begin
    let skel_names : (string, unit) Hashtbl.t = Hashtbl.create 16 in
    List.iter (fun s -> Hashtbl.replace skel_names s.sname ()) skels;
    (* A decl whose name is not a source name IS an instance: the fixpoint
       names those with `mangled_inst_name` and everything else with the
       function's own name. *)
    let instances =
      List.filter (fun (d : fn_decl) -> not (Hashtbl.mem skel_names d.name))
        decls in
    let root = rewrite_instance_refs insts root in
    List.fold_right (fun (d : fn_decl) acc ->
      let fn =
        { Ast.loc = Loc.dummy;
          ty = Some (Ast.TyArrow (d.param_ty, d.return_ty));
          node = Ast.Fun (d.param, None,
                          rewrite_instance_refs insts d.body) } in
      { Ast.loc = Loc.dummy; ty = acc.Ast.ty;
        node = Ast.Let ({ Ast.ploc = Loc.dummy; pnode = Ast.P_var d.name },
                        fn, acc) }) instances root
  end
