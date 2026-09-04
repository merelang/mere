(* `mere --suggest-regions file.mere` -- where a `region R { }` would bound the
   footprint (v0.1.415).

   Mere does not reclaim by default: a value that is not allocated inside a
   `region` block lives until the process exits. The construct that bounds a
   footprint therefore has to be WRITTEN, and the language's principles keep it
   that way -- the compiler does not infer regions, because a reclamation point
   the source does not show is the implicit memory management the design
   excludes. What the compiler can do is say WHERE the construct would pay:
   the `binarytrees` benchmark went from 169 MiB to 5.8 MiB by wrapping one
   expression, and the person who knew which one had to read the allocator to
   find it.

   This pass names two shapes, both of which are safe to wrap by construction
   because the result that crosses the boundary is a scalar and copies out for
   nothing:

   1. A call (or comparison, or match) whose own value is scalar and one of
      whose operands is a freshly built heap value -- `check (build d)`,
      `substring s i j == kw`, `match str_split line " " with ...`. The heap
      value has no consumer after the call, so it is garbage the moment the
      call returns; `(region R { ... })` around the call reclaims it every
      time, and the tail position of any enclosing recursive call is
      preserved because the region wraps the ARGUMENT, not the call.

   2. A non-recursive function whose result is scalar and whose body
      allocates -- `fn (n) -> region R { body }` reclaims the body's scratch
      per call (patterns section 8.4). Recursive functions are not suggested
      this way: a region around a tail-recursive body would nest one open
      arena per iteration, and shape 1 already names the expression inside.

   The predicates are syntactic and conservative: a builtin that hands back
   what a container already holds (`fst`, `char_at`, `map_get`, ...) does
   not allocate; any other call with a heap-typed result is taken to build
   its result. Containers (`Vec`, `Map`, ...) are never "heap values" here --
   a region cannot copy a handle out, and the typer rejects it anyway.
   Nothing inside an existing `region` is reported, and nothing from the
   prelude or from straight-line top-level code is (it runs once).

   It is a report, not a warning, and it says "would reclaim", not "should":
   whether the garbage matters is the program's business, and a suggestion
   the program acts on becomes an explicit `region` in the source, which is
   where the language wants that decision to be visible. *)

open Ast

type hit = { loc : Loc.t; msg : string }

let scalar_ty t =
  match walk t with
  | TyInt | TyFloat | TyBool | TyUnit -> true
  | TyTuple ts ->
    List.for_all (fun t -> match walk t with
      | TyInt | TyFloat | TyBool | TyUnit -> true | _ -> false) ts
  | _ -> false

let container_ty t =
  match walk t with
  | TyCon (("Vec" | "OwnedVec" | "Map" | "StrBuf" | "ByteBuf" | "Channel"
            | "ThreadHandle" | "ListBuf"), _) -> true
  | TyRef _ -> true
  | _ -> false

let rec mentions name t =
  match walk t with
  | TyCon (n, args) -> n = name || List.exists (mentions name) args
  | TyTuple ts -> List.exists (mentions name) ts
  | TyArrow (a, b) -> mentions name a || mentions name b
  | TyRef (_, _, i) -> mentions name i
  | _ -> false

(* A variant whose nodes are boxed: `list`, and any type one of whose
   constructors carries the type itself. Non-recursive variants (`option`,
   `result`) are value structs on the compiled backends and allocate nothing
   of their own. *)
let recursive_memo : (string, bool) Hashtbl.t = Hashtbl.create 16
let boxed_variant name =
  if name = "list" then true
  else match Hashtbl.find_opt recursive_memo name with
    | Some b -> b
    | None ->
      let b = Hashtbl.fold (fun _ (ci : Typer.constr_info) acc ->
        acc || (ci.Typer.type_name = name
                && (match ci.Typer.arg with
                    | Some a -> mentions name a | None -> false)))
        Typer.constructors false in
      Hashtbl.replace recursive_memo name b; b

(* A value whose bytes live in the arena, wholly or in part. *)
let rec heap_ty ?(seen = []) t =
  match walk t with
  | TyStr | TyBytes | TyArrow _ -> true
  | TyCon (name, args) as c ->
    if container_ty c then false
    else if boxed_variant name then true
    else if List.mem name seen then false
    else
      (match Hashtbl.find_opt Typer.records name with
       | Some ri ->
         List.exists (fun (_, ft) -> heap_ty ~seen:(name :: seen) ft) ri.Typer.r_fields
       | None -> List.exists (heap_ty ~seen:(name :: seen)) args)
  | TyTuple ts -> List.exists (heap_ty ~seen) ts
  | _ -> false

let ty_of (e : expr) = match e.ty with Some t -> Some (walk t) | None -> None
let is_scalar e = match ty_of e with Some t -> scalar_ty t | None -> false
let is_heap e = match ty_of e with Some t -> heap_ty t | None -> false

let is_builtin name = List.mem_assoc name Typer.initial_env

(* Builtins whose heap-typed result is something a container or string
   already held: no allocation happens. *)
let projections = [ "fst"; "snd"; "char_at"; "map_get"; "vec_get"; "owned_vec_get"; "args" ]

let rec spine e args =
  match e.node with
  | App (f, a) -> spine f (a :: args)
  | _ -> (e, args)

(* Does evaluating `e` allocate in the current region? Syntactic, and it
   errs toward yes for calls: a user function whose result is a heap value
   is taken to build it. Function bodies are not entered -- a `fn` value
   runs later, not here. *)
let rec allocates (e : expr) : bool =
  match e.node with
  | Int_lit _ | Float_lit _ | Bool_lit _ | Str_lit _ | Unit_lit | Var _ -> false
  | Bin (Concat, _, _) -> true
  | Bin (_, a, b) | Cmp (_, a, b) | Logic (_, a, b) -> allocates a || allocates b
  | Neg a | Annot (a, _) | Field_get (a, _) -> allocates a
  | Constr (_, None) -> false
  | Constr (_, Some p) -> is_heap e || allocates p
  | Tuple es -> List.exists allocates es
  | Record_lit (_, fs) -> List.exists (fun (_, x) -> allocates x) fs
  | Record_update (b, fs) -> allocates b || List.exists (fun (_, x) -> allocates x) fs
  | App _ ->
    let (f, args) = spine e [] in
    (match f.node with
     | Var "fail" -> false   (* the message of a failure is not the program's garbage *)
     | _ ->
       let by_callee =
         match f.node with
         | Var name when is_builtin name -> is_heap e && not (List.mem name projections)
         | Var _ -> is_heap e
         | _ -> is_heap e || allocates f
       in
       by_callee || List.exists allocates args)
  | Let (_, v, b) -> allocates v || allocates b
  | Let_rec (bs, b) -> List.exists (fun (_, v) -> allocates v) bs || allocates b
  | Fun _ -> false
  | If (c, a, b) -> allocates c || allocates a || allocates b
  | Match (s, arms) ->
    allocates s
    || List.exists (fun (_, g, b) ->
         (match g with Some g -> allocates g | None -> false) || allocates b) arms
  | With (_, v, b) -> allocates v || allocates b
  | Region_block _ | Region_loop _ -> false
  | Ref _ -> true

let hits : hit list ref = ref []
let add loc msg = hits := { loc; msg } :: !hits

let callee_name e =
  let (f, _) = spine e [] in
  match f.node with Var n -> Some n | _ -> None

let pp t = Ast.pp_ty (walk t)

let fresh_operand args =
  List.find_opt (fun a -> is_heap a && allocates a) args

(* Walk only into the `fn` bodies nested inside `e` -- used under a reported
   expression, whose own operands are already covered by the report. *)
let rec funs_only ~visit (e : expr) : unit =
  let go = funs_only ~visit in
  match e.node with
  | Fun (_, _, b) -> visit ~in_fn:true ~in_region:false b
  | Int_lit _ | Float_lit _ | Bool_lit _ | Str_lit _ | Unit_lit | Var _ -> ()
  | Bin (_, a, b) | Cmp (_, a, b) | Logic (_, a, b) | App (a, b) -> go a; go b
  | Neg a | Annot (a, _) | Field_get (a, _) | Ref (_, _, a)
  | Region_block (_, a) | Region_loop (_, _, a) -> go a
  | Constr (_, Some p) -> go p
  | Constr (_, None) -> ()
  | Tuple es -> List.iter go es
  | Record_lit (_, fs) -> List.iter (fun (_, x) -> go x) fs
  | Record_update (b, fs) -> go b; List.iter (fun (_, x) -> go x) fs
  | Let (_, v, b) | With (_, v, b) -> go v; go b
  | Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
  | If (c, a, b) -> go c; go a; go b
  | Match (s, arms) ->
    go s; List.iter (fun (_, g, b) -> Option.iter go g; go b) arms

let rec peel_fun e =
  match e.node with Fun (_, _, b) -> peel_fun b | _ -> e

(* Shape 2: a non-recursive function binding whose body allocates and yields a scalar. *)
let check_fn_binding name (f : expr) =
  match f.node with
  | Fun _ ->
    let body = peel_fun f in
    (match body.node with
     | Region_block _ | Region_loop _ -> ()
     | _ ->
       if is_scalar body && allocates body then
         add f.loc
           (Printf.sprintf
              "fn `%s` returns %s and its body allocates; `fn ... -> region R { ... }` \
               around the body would reclaim that scratch on every call"
              name (match ty_of body with Some t -> pp t | None -> "a scalar")))
  | _ -> ()

let rec visit ~in_fn ~in_region (e : expr) : unit =
  let go = visit ~in_fn ~in_region in
  let candidate = in_fn && not in_region in
  match e.node with
  | Int_lit _ | Float_lit _ | Bool_lit _ | Str_lit _ | Unit_lit | Var _ -> ()
  | Region_block (_, b) | Region_loop (_, _, b) -> visit ~in_fn ~in_region:true b
  | Fun (_, _, b) -> visit ~in_fn:true ~in_region b
  | App _ when candidate && is_scalar e && callee_name e <> Some "fail" ->
    let (_, args) = spine e [] in
    (match fresh_operand args with
     | Some a ->
       let who = match callee_name e with Some n -> "`" ^ n ^ "`" | None -> "this call" in
       add e.loc
         (Printf.sprintf
            "%s returns %s and consumes a freshly built %s; `(region R { ... })` around \
             the call would reclaim it every time it runs"
            who (match ty_of e with Some t -> pp t | None -> "a scalar")
            (match ty_of a with Some t -> pp t | None -> "value"));
       funs_only ~visit e
     | None ->
       let (f, args) = spine e [] in
       go f; List.iter go args)
  | Cmp (_, a, b) when candidate
                       && ((is_heap a && allocates a) || (is_heap b && allocates b)) ->
    let side = if is_heap a && allocates a then a else b in
    add e.loc
      (Printf.sprintf
         "this comparison consumes a freshly built %s; `(region R { ... })` around it \
          would reclaim the operand every time it runs"
         (match ty_of side with Some t -> pp t | None -> "value"));
    funs_only ~visit e
  | Match (s, arms) when candidate && is_scalar e && is_heap s && allocates s ->
    add e.loc
      (Printf.sprintf
         "this match yields %s and scrutinises a freshly built %s; `region R { ... }` \
          around the match would reclaim it (the arms' bindings do not escape)"
         (match ty_of e with Some t -> pp t | None -> "a scalar")
         (match ty_of s with Some t -> pp t | None -> "value"));
    List.iter (fun (_, g, b) -> Option.iter go g; go b) arms
  | App (f, a) -> go f; go a
  | Bin (_, a, b) | Cmp (_, a, b) | Logic (_, a, b) -> go a; go b
  | Neg a | Annot (a, _) | Field_get (a, _) | Ref (_, _, a) -> go a
  | Constr (_, Some p) -> go p
  | Constr (_, None) -> ()
  | Tuple es -> List.iter go es
  | Record_lit (_, fs) -> List.iter (fun (_, x) -> go x) fs
  | Record_update (b, fs) -> go b; List.iter (fun (_, x) -> go x) fs
  | Let (p, v, b) ->
    (match p.pnode, v.node with
     | P_var name, Fun _ -> check_fn_binding name v
     | _ -> ());
    go v; go b
  | Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
  | If (c, a, b) -> go c; go a; go b
  | Match (s, arms) ->
    go s; List.iter (fun (_, g, b) -> Option.iter go g; go b) arms
  | With (_, v, b) -> go v; go b

let from_prelude (loc : Loc.t) = loc.Loc.file = Some Pipeline.prelude_file

let report ~path (prog : Ast.program) : string list =
  hits := [];
  Hashtbl.reset recursive_memo;
  List.iter (function
    | Top_let (p, e) when not (from_prelude e.loc) ->
      (match p.pnode, e.node with
       | P_var name, Fun _ -> check_fn_binding name e
       | _ -> ());
      visit ~in_fn:false ~in_region:false e
    | Top_let_rec bs ->
      List.iter (fun ((_, e) : string * expr) ->
        if not (from_prelude e.loc) then visit ~in_fn:false ~in_region:false e) bs
    | _ -> ()) prog.decls;
  visit ~in_fn:false ~in_region:false prog.main;
  let file_of (l : Loc.t) = match l.Loc.file with Some f -> f | None -> path in
  let sorted =
    List.sort (fun a b ->
      compare (file_of a.loc, a.loc.Loc.line, a.loc.Loc.col)
              (file_of b.loc, b.loc.Loc.line, b.loc.Loc.col)) !hits
  in
  List.map (fun h ->
    Printf.sprintf "%s:%d:%d: region candidate: %s"
      (file_of h.loc) h.loc.Loc.line h.loc.Loc.col h.msg) sorted
