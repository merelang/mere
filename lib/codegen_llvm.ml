(* LLVM IR codegen — Phase 5.1 MVP.
   Mirrors codegen_c.ml's first slice scope:
   int / bool / arithmetic / compare / logic / Neg / If / Let (P_var) / Var / Annot.
   Emits textual LLVM IR (modern opaque-pointer form) that `clang` accepts
   directly: `clang out.ll -o bin`.

   Scope intentionally narrow — future slices add functions, strings,
   tuples, records, variants, closures, region/view, in parallel with
   how Phase 4 grew. *)

exception Codegen_error of Loc.t * string

let unsupported loc what =
  raise (Codegen_error (loc, "unsupported (llvm codegen, Phase 5.1 MVP): " ^ what))

(* SSA register / basic-block label counter. Reset per emit_program. *)
let reg_counter = ref 0
let fresh_reg () =
  let n = !reg_counter in
  incr reg_counter;
  Printf.sprintf "%%t%d" n

let label_counter = ref 0
let fresh_label base =
  let n = !label_counter in
  incr label_counter;
  Printf.sprintf "%s%d" base n

(* Accumulated instruction lines (without leading indent / newline).
   Reset per emit_program, appended via emit_instr from emit_expr. *)
let instrs : string list ref = ref []
let emit_instr s = instrs := s :: !instrs
let emit_label s = instrs := (s ^ ":") :: !instrs

(* env: maps Lang variable name -> LLVM SSA value (e.g. "%t3" or "42").
   Pure functional; let-bindings extend it for the body. *)
type env = (string * string) list
let lookup (env : env) name loc =
  match List.assoc_opt name env with
  | Some v -> v
  | None -> unsupported loc ("unbound variable: " ^ name)

let llvm_binop_int = function
  | Ast.Add -> "add"
  | Ast.Sub -> "sub"
  | Ast.Mul -> "mul"
  | Ast.Div -> "sdiv"
  | Ast.Mod -> "srem"
  | Ast.Concat -> raise Exit  (* handled at caller *)

let llvm_cmp_int = function
  | Ast.Eq -> "eq"
  | Ast.Ne -> "ne"
  | Ast.Lt -> "slt"
  | Ast.Le -> "sle"
  | Ast.Gt -> "sgt"
  | Ast.Ge -> "sge"

(* Stable name fragment for a type — used to mint struct names. Mirrors
   codegen_c's ty_tag so a Lang `(int, str)` tuple maps to the same
   `tuple_int_str` shape across backends. *)
let rec ty_tag (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt -> "int"
  | Ast.TyBool -> "bool"
  | Ast.TyStr -> "str"
  | Ast.TyUnit -> "unit"
  | Ast.TyTuple ts -> "tuple_" ^ String.concat "_" (List.map ty_tag ts)
  | Ast.TyArrow (p, r) -> "closure_" ^ ty_tag p ^ "_" ^ ty_tag r
  | Ast.TyCon (name, []) -> name
  | Ast.TyCon (name, args) -> name ^ "_" ^ String.concat "_" (List.map ty_tag args)
  | other ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unsupported LLVM codegen type element: %s" (Ast.pp_ty other)))

let tuple_struct_name (elems : Ast.ty list) : string =
  "tuple_" ^ String.concat "_" (List.map ty_tag elems)

let closure_struct_name (p : Ast.ty) (r : Ast.ty) : string =
  "closure_" ^ ty_tag p ^ "_" ^ ty_tag r

(* Variant tags: each constructor → integer tag. Populated up front
   for both monomorphic and polymorphic variants. *)
let variant_tags : (string, int) Hashtbl.t = Hashtbl.create 16

(* Polymorphic variant declarations: name → (params, variants).
   Populated before emit_expr from Exhaustive's variant registry. *)
let polymorphic_variants
    : (string, string list * (string * Ast.ty option) list) Hashtbl.t =
  Hashtbl.create 4

(* Polymorphic record declarations: name → (params, fields). *)
let polymorphic_records
    : (string, string list * (string * Ast.ty) list) Hashtbl.t =
  Hashtbl.create 4

(* Concrete instantiations seen in the program. Key is the mono name
   (e.g. `opt_int`, `Box_str`); value is the source name + arg list. *)
let mono_variant_instances : (string, string * Ast.ty list) Hashtbl.t =
  Hashtbl.create 8
let mono_record_instances : (string, string * Ast.ty list) Hashtbl.t =
  Hashtbl.create 8

let rec subst_params (mapping : (string * Ast.ty) list) (t : Ast.ty) : Ast.ty =
  match Ast.walk t with
  | Ast.TyParam p ->
    (try List.assoc p mapping with Not_found -> t)
  | Ast.TyArrow (a, b) -> Ast.TyArrow (subst_params mapping a, subst_params mapping b)
  | Ast.TyTuple ts -> Ast.TyTuple (List.map (subst_params mapping) ts)
  | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map (subst_params mapping) args)
  | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, subst_params mapping inner)
  | t -> t

let subst_variants
    (params : string list) (args : Ast.ty list)
    (variants : (string * Ast.ty option) list) : (string * Ast.ty option) list =
  let mapping = List.combine params args in
  List.map (fun (cname, arg_opt) ->
    (cname, Option.map (subst_params mapping) arg_opt)) variants

let mono_variant_name (name : string) (args : Ast.ty list) : string =
  match args with
  | [] -> name
  | _ -> name ^ "_" ^ String.concat "_" (List.map ty_tag args)

let mono_record_name (name : string) (args : Ast.ty list) : string =
  match args with
  | [] -> name
  | _ -> name ^ "_" ^ String.concat "_" (List.map ty_tag args)

(* Names of variants whose value representation is a pointer to a heap
   node (because the variant's payload self-references). Mono and poly
   instantiations are tracked separately by their LLVM-side struct name. *)
let recursive_variants : (string, unit) Hashtbl.t = Hashtbl.create 4

(* Types that need a `show_<tag>` function emitted. Key is ty_tag of
   the type (used as the function name suffix); value is the type. *)
let show_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

let is_recursive_variant_name (name : string) : bool =
  Hashtbl.mem recursive_variants name

(* Direct self-reference in a variant's payload (the type's own name). *)
let variant_is_recursive
    (name : string) (variants : (string * Ast.ty option) list) : bool =
  let rec mentions t =
    match Ast.walk t with
    | Ast.TyCon (n, _) when n = name -> true
    | Ast.TyCon (_, args) -> List.exists mentions args
    | Ast.TyTuple ts -> List.exists mentions ts
    | Ast.TyArrow (a, b) -> mentions a || mentions b
    | Ast.TyRef (_, _, inner) -> mentions inner
    | _ -> false
  in
  List.exists (fun (_, arg_opt) ->
    match arg_opt with Some t -> mentions t | None -> false) variants

(* Whether a mono instance (name, args) is recursive — does any
   substituted payload mention the SAME (name, args)? *)
let mono_variant_is_recursive
    (vname : string) (args : Ast.ty list)
    (svariants : (string * Ast.ty option) list) : bool =
  let same_inst t =
    match Ast.walk t with
    | Ast.TyCon (n, ts) when n = vname && List.length ts = List.length args ->
      List.for_all2 (fun a b -> ty_tag (Ast.walk a) = ty_tag (Ast.walk b)) ts args
    | _ -> false
  in
  let rec ty_mentions t =
    same_inst t
    || (match Ast.walk t with
        | Ast.TyTuple ts -> List.exists ty_mentions ts
        | Ast.TyArrow (a, b) -> ty_mentions a || ty_mentions b
        | Ast.TyCon (_, targs) -> List.exists ty_mentions targs
        | Ast.TyRef (_, _, inner) -> ty_mentions inner
        | _ -> false)
  in
  List.exists (fun (_, arg_opt) ->
    match arg_opt with Some t -> ty_mentions t | None -> false) svariants

(* Walk a Lang type to its LLVM type. Tuples / monomorphic records /
   variants lower to named-struct references (`%tuple_int_int`,
   `%Point`, `%Status`); these are emitted as `type` definitions at the
   top of the module. *)
let llvm_ty_of (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyCon ("Vec", _) | Ast.TyCon ("OwnedVec", _)
  | Ast.TyCon ("StrBuf", _) | Ast.TyCon ("Map", _) ->
    raise (Codegen_error (Loc.dummy,
      "unsupported in LLVM codegen subset: Vec / OwnedVec / StrBuf / Map (interpreter-only)"))
  | Ast.TyInt -> "i32"
  | Ast.TyBool -> "i1"
  | Ast.TyStr -> "ptr"
  | Ast.TyUnit -> "i32"  (* unit becomes int 0 *)
  | Ast.TyTuple ts -> "%" ^ tuple_struct_name ts
  | Ast.TyRef _ -> "ptr"  (* `&R T` is a pointer into the region's buffer *)
  | Ast.TyCon (name, _) when Hashtbl.mem Typer.views name -> "ptr"
  | Ast.TyCon (name, args) when Hashtbl.mem polymorphic_records name ->
    "%" ^ mono_record_name name (List.map Ast.walk args)
  | Ast.TyCon (name, []) when Hashtbl.mem Typer.records name -> "%" ^ name
  | Ast.TyCon (name, args) when Hashtbl.mem polymorphic_variants name ->
    let mono = mono_variant_name name (List.map Ast.walk args) in
    if is_recursive_variant_name mono then "ptr" else "%" ^ mono
  | Ast.TyCon (name, []) when Hashtbl.mem Typer.types name ->
    if is_recursive_variant_name name then "ptr" else "%" ^ name
  | Ast.TyArrow (p, r) -> "%" ^ closure_struct_name p r
  | _ -> "i32"  (* best-effort fallback; typer should reject before this *)

(* View test: is this Lang type a view? Views are constructed via
   Record_lit with a name in Typer.views; values are ptr to the
   region-allocated struct. *)
let is_view_type (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyCon (n, _) -> Hashtbl.mem Typer.views n
  | _ -> false

(* Look up a record's ordered field list. Raises if name isn't in the
   typer registry — the typer should have caught that before codegen. *)
let record_fields (name : string) : (string * Ast.ty) list =
  match Hashtbl.find_opt Typer.records name with
  | Some info -> info.Typer.r_fields
  | None ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unknown record type `%s` at LLVM codegen" name))

let field_index (record_name : string) (field_name : string) : int =
  let fields = record_fields record_name in
  let rec idx i = function
    | [] ->
      raise (Codegen_error (Loc.dummy,
        Printf.sprintf "record `%s` has no field `%s`" record_name field_name))
    | (n, _) :: _ when n = field_name -> i
    | _ :: rest -> idx (i + 1) rest
  in
  idx 0 fields

(* Encode an OCaml string to LLVM's c"..." literal body (without the
   trailing \00). Printable ASCII goes through; everything else is \HH. *)
let llvm_string_escape (s : string) : string =
  let buf = Buffer.create (String.length s + 4) in
  String.iter (fun c ->
    let code = Char.code c in
    if code >= 32 && code <= 126 && c <> '"' && c <> '\\' then
      Buffer.add_char buf c
    else
      Buffer.add_string buf (Printf.sprintf "\\%02X" code)
  ) s;
  Buffer.contents buf

(* Accumulator for string-literal globals.
   Each entry: full LLVM declaration line. *)
let str_globals : string list ref = ref []
let str_counter = ref 0
let fresh_str_global (s : string) : string =
  let n = !str_counter in
  incr str_counter;
  let label = Printf.sprintf "@.str_%d" n in
  let escaped = llvm_string_escape s in
  let bytes_len = String.length s + 1 in
  let decl =
    Printf.sprintf "%s = private constant [%d x i8] c\"%s\\00\""
      label bytes_len escaped
  in
  str_globals := decl :: !str_globals;
  label

let rec ty_is_concrete (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, _, inner) -> ty_is_concrete inner
  | Ast.TyVar _ | Ast.TyParam _ | Ast.TyFloat -> false

(* Top-level fn binding extracted from main: `let name = fn param -> body in ...`.
   We keep the original Fun expr so we can read its typer-set `.ty`. *)
type fn_skel = {
  sname : string;
  sparam : string;
  sbody : Ast.expr;
  sfun : Ast.expr;
}

(* Fully type-resolved fn declaration. *)
type fn_decl = {
  name      : string;
  param     : string;
  body      : Ast.expr;
  param_ty  : Ast.ty;
  return_ty : Ast.ty;
}

(* Set of known top-level fn names (used by emit_expr to direct-call Var). *)
let toplevel_fn_names : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Concrete LLVM-side types of in-scope name bindings. Used to recover
   concrete arrow types when an inner App's head Var still has a
   polymorphic `.ty` from let-poly generalization. Saved/restored
   around each fn body emit. *)
let current_var_types : (string * Ast.ty) list ref = ref []

(* Type the parent context expects this expression to have. Set by
   emit_fn_def / emit_anon_adapter as the body's return type, so
   anonymous Funs in tail position can recover their concrete arrow
   type even when their .ty was generalized to polymorphic. *)
let current_expected_ty : Ast.ty option ref = ref None

(* Active user `region R { ... }` scopes — region name → SSA register
   holding the region's ptr. Pushed by Region_block entry, popped at
   exit so `&R v` / view literals can find the right region. *)
let current_regions : (string * string) list ref = ref []

(* For a pattern matched against a scrutinee of type `scrut_ty` and
   payload of type `payload_ty` (if any), produce the (name, concrete-ty)
   bindings introduced by the pattern. Used to update current_var_types
   so arm bodies can recover concrete types for pattern-bound names
   (otherwise the typer's AST .ty may carry polymorphic ty-vars). *)
let pattern_var_types
    (pat : Ast.pattern) (scrut_ty : Ast.ty) (payload_ty : Ast.ty option)
    : (string * Ast.ty) list =
  match pat.Ast.pnode with
  | Ast.P_var n -> [(n, scrut_ty)]
  | Ast.P_wild -> []
  | Ast.P_constr (_, None) -> []
  | Ast.P_constr (_, Some sub) ->
    (match sub.Ast.pnode, payload_ty with
     | Ast.P_var n, Some t -> [(n, t)]
     | Ast.P_wild, _ -> []
     | Ast.P_tuple pats, Some t ->
       let elem_tys =
         match Ast.walk t with
         | Ast.TyTuple ts -> ts
         | _ -> []
       in
       List.map2 (fun p ety ->
         match p.Ast.pnode with
         | Ast.P_var n -> [(n, ety)]
         | _ -> [])
         pats elem_tys
       |> List.concat
     | _ -> [])
  | _ -> []

(* Names of a pattern's bound variables (used by free_vars). *)
let pattern_vars (p : Ast.pattern) : string list =
  let rec go p =
    match p.Ast.pnode with
    | Ast.P_var n -> [n]
    | Ast.P_constr (_, Some sub) -> go sub
    | Ast.P_tuple ps -> List.concat_map go ps
    | Ast.P_record (_, fs) -> List.concat_map (fun (_, p) -> go p) fs
    | Ast.P_as (inner, n) -> n :: go inner
    | Ast.P_or (a, _) -> go a
    | _ -> []
  in
  go p

(* Free variables of `e` excluding `initially_bound` and names introduced
   by inner binders. Preserves left-to-right first-appearance order. *)
let free_vars (e : Ast.expr) (initially_bound : string list) : string list =
  let seen = Hashtbl.create 8 in
  let order = ref [] in
  let add n =
    if not (Hashtbl.mem seen n) then begin
      Hashtbl.add seen n ();
      order := n :: !order
    end
  in
  let rec go (e : Ast.expr) (bound : string list) =
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit -> ()
    | Ast.Var n -> if not (List.mem n bound) then add n
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a bound; go b bound
    | Ast.Neg a | Ast.Annot (a, _) -> go a bound
    | Ast.Let (pat, v, body) ->
      go v bound;
      go body (pattern_vars pat @ bound)
    | Ast.Let_rec (bindings, body) ->
      let names = List.map fst bindings in
      let bound' = names @ bound in
      List.iter (fun (_, v) -> go v bound') bindings;
      go body bound'
    | Ast.With (n, v, body) -> go v bound; go body (n :: bound)
    | Ast.If (c, t, e_) -> go c bound; go t bound; go e_ bound
    | Ast.Fun (param, _, body) -> go body (param :: bound)
    | Ast.Constr (_, Some a) -> go a bound
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      go s bound;
      List.iter (fun (pat, g, b) ->
        let bound' = pattern_vars pat @ bound in
        (match g with Some ge -> go ge bound' | None -> ()); go b bound') arms
    | Ast.Tuple es -> List.iter (fun e -> go e bound) es
    | Ast.Region_block (n, b) -> go b (n :: bound)
    | Ast.Ref (_, _, a) -> go a bound
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e bound) fs
    | Ast.Field_get (a, _) -> go a bound
    | Ast.Record_update (a, fs) ->
      go a bound; List.iter (fun (_, e) -> go e bound) fs
  in
  go e initially_bound;
  List.rev !order

(* Anonymous-closure emission state. Each `Fun` in expression position
   becomes one of these; the adapter body is emitted later by
   draining the queue in emit_program. *)
type closure_emission = {
  ce_adapter_name : string;
  ce_env_name     : string;
  ce_env_fields   : (string * Ast.ty) list;
  ce_param        : string;
  ce_param_ty     : Ast.ty;
  ce_return_ty    : Ast.ty;
  ce_body         : Ast.expr;
}
let pending_closures : closure_emission list ref = ref []
let anon_env_typedefs : string list ref = ref []
let anon_closure_counter = ref 0
let fresh_anon_names () =
  let n = !anon_closure_counter in
  incr anon_closure_counter;
  (Printf.sprintf "anon_%d_fn" n, Printf.sprintf "anon_%d_env" n)

(* Walk the desugared main expression, peeling top-level fn-binding lets
   (P_var of Fun) and let-recs whose bindings are all single-arg fns.
   Returns the skels and the residual main body. *)
let lift_fn_skels (e : Ast.expr) : fn_skel list * Ast.expr =
  let rec go (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, rest)
      when (match pat.Ast.pnode with Ast.P_var _ -> true | _ -> false) ->
      (match value.Ast.node with
       | Ast.Fun (param, _, fn_body) ->
         let name = match pat.Ast.pnode with Ast.P_var n -> n | _ -> assert false in
         let more, rest' = go rest in
         { sname = name; sparam = param; sbody = fn_body; sfun = value }
         :: more, rest'
       | _ -> [], e)
    | Ast.Let_rec (bindings, rest) ->
      let skels =
        List.map (fun (n, v) ->
          match v.Ast.node with
          | Ast.Fun (p, _, fb) ->
            { sname = n; sparam = p; sbody = fb; sfun = v }
          | _ ->
            raise (Codegen_error (v.Ast.loc,
              "let rec binding must be a single-arg function in LLVM subset")))
          bindings
      in
      let more, rest' = go rest in
      skels @ more, rest'
    | _ -> [], e
  in
  go e

(* Scan `root` for a Var of `name` whose ty walked to a concrete arrow.
   Used when the binding-site Fun.ty was generalized (let-poly) and we
   need a monomorphic instantiation. *)
let find_concrete_arrow (name : string) (root : Ast.expr) : Ast.ty option =
  let found = ref None in
  let rec go (e : Ast.expr) =
    (if !found = None then
       match e.Ast.node with
       | Ast.Var n when n = name ->
         (match e.Ast.ty with
          | Some t ->
            let t = Ast.walk t in
            (match t with
             | Ast.TyArrow _ when ty_is_concrete t -> found := Some t
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
    | Ast.Fun (_, _, b) -> go b
    | Ast.Constr (_, Some a) -> go a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      go s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> go ge | None -> ()); go b) arms
    | Ast.Tuple es -> List.iter go es
    | Ast.Region_block (_, b) -> go b
    | Ast.Ref (_, _, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  go root;
  !found

let resolve_fn_types (skels : fn_skel list) (root : Ast.expr) : fn_decl list =
  List.map (fun s ->
    let arrow =
      let fun_ty =
        match s.sfun.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
      in
      if ty_is_concrete fun_ty then fun_ty
      else
        match find_concrete_arrow s.sname root with
        | Some t -> t
        | None ->
          raise (Codegen_error (s.sfun.Ast.loc,
            Printf.sprintf
              "fn `%s` has polymorphic type with no concrete use site \
               — LLVM codegen needs a monomorphic instantiation" s.sname))
    in
    match arrow with
    | Ast.TyArrow (p, r) ->
      { name = s.sname; param = s.sparam; body = s.sbody;
        param_ty = Ast.walk p; return_ty = Ast.walk r }
    | _ ->
      raise (Codegen_error (s.sfun.Ast.loc,
        Printf.sprintf "function `%s` has non-arrow inferred type" s.sname))
  ) skels

(* Walk a typed AST + fn signatures to collect every concrete tuple shape
   so we can emit `%tuple_int_str = type { i32, ptr }` for each. *)
let collect_tuple_shapes (root : Ast.expr) (fns : fn_decl list) : Ast.ty list list =
  let seen = Hashtbl.create 8 in
  let add elems =
    let key = tuple_struct_name elems in
    if not (Hashtbl.mem seen key) then Hashtbl.add seen key elems
  in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyTuple ts ->
      if List.for_all ty_is_concrete ts then add ts;
      List.iter walk_ty ts
    | Ast.TyArrow (a, b) -> walk_ty a; walk_ty b
    | Ast.TyCon (_, args) -> List.iter walk_ty args
    | Ast.TyRef (_, _, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk_expr v) bs; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns;
  (* Also walk substituted payloads of mono instances — variant
     payloads (e.g. `(int, list int)` inside Cons) are referenced by
     the variant struct definition but may never appear as a direct
     AST node when the program only matches/shows the type. *)
  Hashtbl.iter (fun _ (vn, args) ->
    let (params, variants) = Hashtbl.find polymorphic_variants vn in
    let sv = subst_variants params args variants in
    List.iter (fun (_, arg_opt) ->
      match arg_opt with Some t -> walk_ty t | None -> ()) sv
  ) mono_variant_instances;
  Hashtbl.iter (fun _ (rn, args) ->
    let (params, fields) = Hashtbl.find polymorphic_records rn in
    let mapping = List.combine params args in
    List.iter (fun (_, ft) -> walk_ty (subst_params mapping ft)) fields
  ) mono_record_instances;
  Hashtbl.fold (fun _ v acc -> v :: acc) seen []

let emit_tuple_typedef (elems : Ast.ty list) : string =
  let name = tuple_struct_name elems in
  let fields = String.concat ", " (List.map llvm_ty_of elems) in
  Printf.sprintf "%%%s = type { %s }" name fields

(* Walk a typed AST + fn signatures to collect every monomorphic variant
   type name encountered. *)
let collect_variant_names (root : Ast.expr) (fns : fn_decl list) : string list =
  let seen = Hashtbl.create 8 in
  let add name =
    if Hashtbl.mem Typer.types name &&
       not (Hashtbl.mem Typer.records name) &&
       not (Hashtbl.mem seen name) &&
       Hashtbl.find Typer.types name = 0 (* arity 0 — monomorphic *)
    then Hashtbl.add seen name ()
  in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyCon (n, args) -> add n; List.iter walk_ty args
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyArrow (a, b) -> walk_ty a; walk_ty b
    | Ast.TyRef (_, _, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    (match e.Ast.node with
     | Ast.Constr (cname, _) ->
       (match Hashtbl.find_opt Typer.constructors cname with
        | Some info -> add info.Typer.type_name
        | None -> ())
     | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk_expr v) bs; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns;
  Hashtbl.fold (fun k () acc -> k :: acc) seen []

(* Walk a typed AST + fn signatures to collect every monomorphic record
   type name encountered. *)
let collect_record_names (root : Ast.expr) (fns : fn_decl list) : string list =
  let seen = Hashtbl.create 8 in
  let add name =
    if Hashtbl.mem Typer.records name &&
       not (Hashtbl.mem seen name) then
      let info = Hashtbl.find Typer.records name in
      if info.Typer.r_params = [] then
        Hashtbl.add seen name ()
  in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyCon (n, args) -> add n; List.iter walk_ty args
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyArrow (a, b) -> walk_ty a; walk_ty b
    | Ast.TyRef (_, _, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    (match e.Ast.node with
     | Ast.Record_lit (n, _) -> add n
     | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk_expr v) bs; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns;
  Hashtbl.fold (fun k () acc -> k :: acc) seen []

let emit_record_typedef (name : string) : string =
  let fields = record_fields name in
  let field_tys = String.concat ", " (List.map (fun (_, t) -> llvm_ty_of t) fields) in
  Printf.sprintf "%%%s = type { %s }" name field_tys

(* Variants and their concrete shape — populated from Exhaustive's
   registry. None means nullary-only; Some t means all payload-bearing
   constructors share payload type t (MVP restriction). *)
let variant_shape (name : string) : (string * Ast.ty option) list =
  match Hashtbl.find_opt Exhaustive.type_variants name with
  | Some vs -> vs
  | None ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unknown variant type `%s` at LLVM codegen" name))

(* Decide the single payload type for a variant (Phase 5.6 MVP only
   handles all-nullary or single-payload-type). Returns None if all
   constructors are nullary. *)
let variant_payload_ty (name : string) : Ast.ty option =
  let vs = variant_shape name in
  let payloads =
    List.filter_map (fun (_, p) -> p) vs
  in
  match payloads with
  | [] -> None
  | first :: rest ->
    let first_tag = ty_tag (Ast.walk first) in
    if List.for_all (fun p -> ty_tag (Ast.walk p) = first_tag) rest then
      Some first
    else
      raise (Codegen_error (Loc.dummy,
        Printf.sprintf
          "variant `%s` has constructors with different payload types — \
           Phase 5 MVP needs all payloads to be the same type" name))

let emit_variant_typedef (name : string) : string =
  let vs = variant_shape name in
  List.iteri (fun i (cname, _) ->
    Hashtbl.replace variant_tags cname i) vs;
  if is_recursive_variant_name name then begin
    (* Recursive: emit `%name_node = type { i32, T }` — the on-heap
       node. The "value" of the variant at this point is `ptr` (handled
       by llvm_ty_of). *)
    let payload =
      match variant_payload_ty name with
      | None -> ""
      | Some t -> Printf.sprintf ", %s" (llvm_ty_of t)
    in
    Printf.sprintf "%%%s_node = type { i32%s }" name payload
  end
  else
    match variant_payload_ty name with
    | None -> Printf.sprintf "%%%s = type { i32 }" name
    | Some t -> Printf.sprintf "%%%s = type { i32, %s }" name (llvm_ty_of t)

(* Variant payload type for an already-substituted variant list (used by
   mono-instance codegen, where we've already applied param→arg subst). *)
let variant_payload_ty_of (variants : (string * Ast.ty option) list)
    : Ast.ty option =
  let payloads = List.filter_map (fun (_, p) -> p) variants in
  match payloads with
  | [] -> None
  | first :: rest ->
    let first_tag = ty_tag (Ast.walk first) in
    if List.for_all (fun p -> ty_tag (Ast.walk p) = first_tag) rest then
      Some first
    else
      raise (Codegen_error (Loc.dummy,
        "variant has constructors with different payload types — \
         Phase 5 MVP needs all payloads to be the same type"))

(* Specialized typedef for a polymorphic variant instance. *)
let emit_mono_variant_typedef (variant_name : string) (args : Ast.ty list) : string =
  let mono_name = mono_variant_name variant_name args in
  let (params, variants) = Hashtbl.find polymorphic_variants variant_name in
  let svariants = subst_variants params args variants in
  if is_recursive_variant_name mono_name then begin
    let payload =
      match variant_payload_ty_of svariants with
      | None -> ""
      | Some t -> Printf.sprintf ", %s" (llvm_ty_of t)
    in
    Printf.sprintf "%%%s_node = type { i32%s }" mono_name payload
  end
  else
    match variant_payload_ty_of svariants with
    | None -> Printf.sprintf "%%%s = type { i32 }" mono_name
    | Some t -> Printf.sprintf "%%%s = type { i32, %s }" mono_name (llvm_ty_of t)

(* Specialized typedef for a polymorphic record instance. *)
let emit_mono_record_typedef (record_name : string) (args : Ast.ty list) : string =
  let mono_name = mono_record_name record_name args in
  let (params, fields) = Hashtbl.find polymorphic_records record_name in
  let mapping = List.combine params args in
  let field_tys =
    String.concat ", " (List.map (fun (_, ft) ->
      llvm_ty_of (subst_params mapping ft)) fields)
  in
  Printf.sprintf "%%%s = type { %s }" mono_name field_tys

(* Collect every distinct concrete arrow type (T1 -> T2) used in the
   program — these become `%closure_T1_T2 = type { ptr, ptr }` typedefs. *)
let collect_arrow_types (root : Ast.expr) (fns : fn_decl list) : (Ast.ty * Ast.ty) list =
  let seen = Hashtbl.create 8 in
  let add p r =
    let key = closure_struct_name p r in
    if not (Hashtbl.mem seen key) then Hashtbl.add seen key (p, r)
  in
  let rec walk_ty (t : Ast.ty) =
    match Ast.walk t with
    | Ast.TyArrow (p, r) ->
      let p' = Ast.walk p and r' = Ast.walk r in
      if ty_is_concrete p' && ty_is_concrete r' then add p' r';
      walk_ty p'; walk_ty r'
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyCon (_, args) -> List.iter walk_ty args
    | Ast.TyRef (_, _, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk_expr v) bs; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f ->
    add (Ast.walk f.param_ty) (Ast.walk f.return_ty);
    walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns;
  Hashtbl.fold (fun _ v acc -> v :: acc) seen []

(* Walk AST + fns to find every concrete instantiation of a polymorphic
   variant / record. Populates mono_variant_instances and
   mono_record_instances; later iteration emits one typedef per key. *)
let collect_mono_instances (root : Ast.expr) (fns : fn_decl list) : unit =
  let add name args =
    if List.for_all ty_is_concrete args then begin
      if Hashtbl.mem polymorphic_variants name
         && not (Hashtbl.mem mono_variant_instances
                   (mono_variant_name name args))
      then
        Hashtbl.add mono_variant_instances
          (mono_variant_name name args) (name, args);
      if Hashtbl.mem polymorphic_records name
         && not (Hashtbl.mem mono_record_instances
                   (mono_record_name name args))
      then
        Hashtbl.add mono_record_instances
          (mono_record_name name args) (name, args)
    end
  in
  let rec walk_ty t =
    match Ast.walk t with
    | Ast.TyCon (n, args) ->
      let args' = List.map Ast.walk args in
      List.iter walk_ty args';
      add n args'
    | Ast.TyTuple ts -> List.iter walk_ty ts
    | Ast.TyArrow (a, b) -> walk_ty a; walk_ty b
    | Ast.TyRef (_, _, inner) -> walk_ty inner
    | _ -> ()
  in
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.ty with Some t -> walk_ty t | None -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk_expr v) bs; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_ty f.param_ty; walk_ty f.return_ty; walk_expr f.body) fns

(* Walk AST to collect types passed to `show`. Pulls in dependent types
   (tuple elems, record fields, variant payloads) recursively. The
   Hashtbl guard prevents infinite recursion on self-referential
   variants (e.g. `'a list`). *)
let rec add_show_type (t : Ast.ty) : unit =
  let t = Ast.walk t in
  if not (ty_is_concrete t) then ()
  else
    let tag = ty_tag t in
    if Hashtbl.mem show_types tag then ()
    else begin
      Hashtbl.add show_types tag t;
      (* For polymorphic types, register the mono instance so typedef
         emission picks them up — needed when the program only uses
         this type via show (no constructor call to seed
         collect_mono_instances). *)
      (match t with
       | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
         let mono = mono_variant_name n args in
         if not (Hashtbl.mem mono_variant_instances mono) then
           Hashtbl.add mono_variant_instances mono (n, args)
       | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
         let mono = mono_record_name n args in
         if not (Hashtbl.mem mono_record_instances mono) then
           Hashtbl.add mono_record_instances mono (n, args)
       | _ -> ());
      (* Recurse into dependent types. *)
      match t with
      | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> ()
      | Ast.TyTuple ts -> List.iter add_show_type ts
      | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
        let (params, fields) = Hashtbl.find polymorphic_records n in
        let mapping = List.combine params args in
        List.iter (fun (_, ft) -> add_show_type (subst_params mapping ft)) fields
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
        let fields = record_fields n in
        List.iter (fun (_, ft) -> add_show_type ft) fields
      | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
        let (params, variants) = Hashtbl.find polymorphic_variants n in
        let sv = subst_variants params args variants in
        List.iter (fun (_, arg_opt) ->
          match arg_opt with Some t -> add_show_type t | None -> ()) sv
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.types n ->
        let vs = variant_shape n in
        List.iter (fun (_, arg_opt) ->
          match arg_opt with Some t -> add_show_type t | None -> ()) vs
      | _ -> ()
    end

let collect_show_types (root : Ast.expr) (fns : fn_decl list) : unit =
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
       (match arg.Ast.ty with
        | Some t -> add_show_type t
        | None -> ())
     | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk_expr v) bs; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_expr f.body) fns

(* Pre-defined string globals used by show fns. Emitted once per program. *)
let show_string_globals = ref []
let show_format_globals = ref []
(* String global for an arbitrary literal — adds a unique label.
   Different from fresh_str_global (which is per-call); these are
   shared / pre-registered at the start of show emission. *)
let mint_show_global name content =
  let bytes_len = String.length content + 1 in
  let escaped = llvm_string_escape content in
  show_string_globals :=
    Printf.sprintf "@.%s = private constant [%d x i8] c\"%s\\00\""
      name bytes_len escaped
    :: !show_string_globals

let mint_show_format name fmt =
  (* `fmt` is the OCaml string content (e.g. "%d") — emit it as the LLVM
     constant body and let LLVM count the bytes correctly. *)
  let bytes_len = String.length fmt + 1 in
  let escaped = llvm_string_escape fmt in
  show_format_globals :=
    Printf.sprintf "@.fmt_%s = private constant [%d x i8] c\"%s\\00\""
      name bytes_len escaped
    :: !show_format_globals

(* Emit a single show_<tag> function for the given type. *)
let emit_show_fn (tag : string) (t : Ast.ty) : string =
  let saved_instrs = !instrs in
  let saved_reg = !reg_counter and saved_lbl = !label_counter in
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
  let param_ty = llvm_ty_of t in
  let emit_asprintf fmt_name args =
    (* Allocate a local ptr to receive the asprintf result. *)
    let p = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = alloca ptr" p);
    let arg_str =
      if args = "" then "" else ", " ^ args
    in
    emit_instr (Printf.sprintf
                  "  call i32 (ptr, ptr, ...) @asprintf(ptr %s, ptr @.fmt_%s%s)"
                  p fmt_name arg_str);
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" r p);
    r
  in
  emit_instr "entry:";
  let result_reg =
    match Ast.walk t with
    | Ast.TyInt ->
      emit_asprintf "show_int" "i32 %x"
    | Ast.TyBool ->
      (* Select between "true" / "false" globals. *)
      let r = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = select i1 %%x, ptr @.s_true, ptr @.s_false" r);
      r
    | Ast.TyStr ->
      emit_asprintf "show_str" "ptr %x"
    | Ast.TyUnit ->
      "@.s_unit"
    | Ast.TyTuple ts ->
      (* Show each element, then asprintf "(%s, %s, ...)" with them. *)
      let tname = tuple_struct_name ts in
      let elem_strs =
        List.mapi (fun i ety ->
          let e = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, %d" e tname i);
          let s = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                        s (ty_tag ety) (llvm_ty_of ety) e);
          Printf.sprintf "ptr %s" s
        ) ts
      in
      emit_asprintf ("show_" ^ tag) (String.concat ", " elem_strs)
    | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
      let (params, fields) = Hashtbl.find polymorphic_records n in
      let mapping = List.combine params args in
      let sf = List.map (fun (fn, ft) -> (fn, subst_params mapping ft)) fields in
      let mono = mono_record_name n args in
      let field_strs =
        List.mapi (fun i (_, ft) ->
          let e = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, %d" e mono i);
          let s = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                        s (ty_tag ft) (llvm_ty_of ft) e);
          Printf.sprintf "ptr %s" s
        ) sf
      in
      emit_asprintf ("show_" ^ tag) (String.concat ", " field_strs)
    | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
      let fields = record_fields n in
      let field_strs =
        List.mapi (fun i (_, ft) ->
          let e = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, %d" e n i);
          let s = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                        s (ty_tag ft) (llvm_ty_of ft) e);
          Printf.sprintf "ptr %s" s
        ) fields
      in
      emit_asprintf ("show_" ^ tag) (String.concat ", " field_strs)
    | Ast.TyCon ("list", [elem_ty])
      when is_recursive_variant_name (mono_variant_name "list" [elem_ty]) ->
      (* `'a list` special-case: render as `[a, b, c]` instead of the
         generic `Cons (a, Cons (b, Cons (c, Nil)))` form. Walks the
         list with mutable iter / acc / first flag (via alloca/load/store
         for simplicity over phi chains). *)
      let mono = mono_variant_name "list" [elem_ty] in
      let node_ty = "%" ^ mono ^ "_node" in
      let payload_struct =
        "%" ^ tuple_struct_name [elem_ty; Ast.TyCon ("list", [elem_ty])]
      in
      let iter_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = alloca ptr" iter_p);
      let acc_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = alloca ptr" acc_p);
      let first_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = alloca i1" first_p);
      emit_instr (Printf.sprintf "  store ptr %%x, ptr %s" iter_p);
      emit_instr (Printf.sprintf "  store ptr @.s_lbracket, ptr %s" acc_p);
      emit_instr (Printf.sprintf "  store i1 1, ptr %s" first_p);
      let test_lbl = fresh_label "list_show_test_" in
      let body_lbl = fresh_label "list_show_body_" in
      let end_lbl = fresh_label "list_show_end_" in
      let first_lbl = fresh_label "list_show_first_" in
      let nfirst_lbl = fresh_label "list_show_nfirst_" in
      let iter_lbl = fresh_label "list_show_iter_" in
      emit_instr (Printf.sprintf "  br label %%%s" test_lbl);
      emit_label test_lbl;
      let cur = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" cur iter_p);
      let tag_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 0"
                    tag_p node_ty cur);
      let tag = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load i32, ptr %s" tag tag_p);
      let is_nil = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, 0" is_nil tag);
      emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                    is_nil end_lbl body_lbl);
      emit_label body_lbl;
      let pl_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 1"
                    pl_p node_ty cur);
      let pl = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load %s, ptr %s" pl payload_struct pl_p);
      let h = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = extractvalue %s %s, 0" h payload_struct pl);
      let t = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = extractvalue %s %s, 1" t payload_struct pl);
      let h_str = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                    h_str (ty_tag elem_ty) (llvm_ty_of elem_ty) h);
      let is_first = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load i1, ptr %s" is_first first_p);
      let acc_cur = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" acc_cur acc_p);
      emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                    is_first first_lbl nfirst_lbl);
      emit_label first_lbl;
      let new_acc_1 = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_str_concat(ptr %s, ptr %s)"
                    new_acc_1 acc_cur h_str);
      emit_instr (Printf.sprintf "  store ptr %s, ptr %s" new_acc_1 acc_p);
      emit_instr (Printf.sprintf "  store i1 0, ptr %s" first_p);
      emit_instr (Printf.sprintf "  br label %%%s" iter_lbl);
      emit_label nfirst_lbl;
      let tmp = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_str_concat(ptr %s, ptr @.s_comma_space)"
                    tmp acc_cur);
      let new_acc_2 = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_str_concat(ptr %s, ptr %s)"
                    new_acc_2 tmp h_str);
      emit_instr (Printf.sprintf "  store ptr %s, ptr %s" new_acc_2 acc_p);
      emit_instr (Printf.sprintf "  br label %%%s" iter_lbl);
      emit_label iter_lbl;
      emit_instr (Printf.sprintf "  store ptr %s, ptr %s" t iter_p);
      emit_instr (Printf.sprintf "  br label %%%s" test_lbl);
      emit_label end_lbl;
      let acc_final = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" acc_final acc_p);
      let r = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_str_concat(ptr %s, ptr @.s_rbracket)"
                    r acc_final);
      r
    | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
      let (params, variants) = Hashtbl.find polymorphic_variants n in
      let sv = subst_variants params args variants in
      let mono = mono_variant_name n args in
      let recursive = is_recursive_variant_name mono in
      let node_ty = "%" ^ mono ^ "_node" in
      (* Extract tag *)
      let tag_reg = fresh_reg () in
      if recursive then begin
        let p = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %%x, i32 0, i32 0"
                      p node_ty);
        emit_instr (Printf.sprintf "  %s = load i32, ptr %s" tag_reg p)
      end else
        emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, 0" tag_reg mono);
      (* Switch over tag: for each constructor, emit a branch that
         produces the string. *)
      let merge_label = fresh_label "show_join_" in
      let phi_entries = ref [] in
      List.iteri (fun ctor_tag (cname, arg_opt) ->
        let arm_label = fresh_label "show_arm_" in
        let next_label = fresh_label "show_next_" in
        let cmp = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, %d" cmp tag_reg ctor_tag);
        emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                      cmp arm_label next_label);
        emit_label arm_label;
        let s =
          match arg_opt with
          | None ->
            "@.s_ctor_" ^ cname
          | Some pty ->
            let p_reg = fresh_reg () in
            if recursive then begin
              let pp = fresh_reg () in
              emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %%x, i32 0, i32 1"
                            pp node_ty);
              emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                            p_reg (llvm_ty_of pty) pp)
            end else
              emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, 1" p_reg mono);
            let ps = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                          ps (ty_tag pty) (llvm_ty_of pty) p_reg);
            (* Build "Ctor payload_str" *)
            let p = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = alloca ptr" p);
            emit_instr (Printf.sprintf
                          "  call i32 (ptr, ptr, ...) @asprintf(ptr %s, ptr @.fmt_show_ctor_payload, ptr @.s_ctor_%s, ptr %s)"
                          p cname ps);
            let r = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" r p);
            r
        in
        let end_label = fresh_label "show_armend_" in
        emit_instr (Printf.sprintf "  br label %%%s" end_label);
        emit_label end_label;
        phi_entries := (s, end_label) :: !phi_entries;
        emit_instr (Printf.sprintf "  br label %%%s" merge_label);
        emit_label next_label
      ) sv;
      (* Final unreachable (typer should catch non-exhaustive) *)
      emit_instr "  call void @abort()";
      emit_instr "  unreachable";
      emit_label merge_label;
      let r = fresh_reg () in
      let phi_parts =
        String.concat ", " (List.rev_map (fun (v, lbl) ->
          Printf.sprintf "[%s, %%%s]" v lbl) !phi_entries)
      in
      emit_instr (Printf.sprintf "  %s = phi ptr %s" r phi_parts);
      r
    | Ast.TyCon (n, _) when Hashtbl.mem Typer.types n ->
      (* Mono variant. *)
      let vs = variant_shape n in
      let recursive = is_recursive_variant_name n in
      let node_ty = "%" ^ n ^ "_node" in
      let tag_reg = fresh_reg () in
      if recursive then begin
        let p = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %%x, i32 0, i32 0"
                      p node_ty);
        emit_instr (Printf.sprintf "  %s = load i32, ptr %s" tag_reg p)
      end else
        emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, 0" tag_reg n);
      let merge_label = fresh_label "show_join_" in
      let phi_entries = ref [] in
      List.iteri (fun ctor_tag (cname, arg_opt) ->
        let arm_label = fresh_label "show_arm_" in
        let next_label = fresh_label "show_next_" in
        let cmp = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, %d" cmp tag_reg ctor_tag);
        emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                      cmp arm_label next_label);
        emit_label arm_label;
        let s =
          match arg_opt with
          | None -> "@.s_ctor_" ^ cname
          | Some pty ->
            let p_reg = fresh_reg () in
            if recursive then begin
              let pp = fresh_reg () in
              emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %%x, i32 0, i32 1"
                            pp node_ty);
              emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                            p_reg (llvm_ty_of pty) pp)
            end else
              emit_instr (Printf.sprintf "  %s = extractvalue %%%s %%x, 1" p_reg n);
            let ps = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                          ps (ty_tag pty) (llvm_ty_of pty) p_reg);
            let p = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = alloca ptr" p);
            emit_instr (Printf.sprintf
                          "  call i32 (ptr, ptr, ...) @asprintf(ptr %s, ptr @.fmt_show_ctor_payload, ptr @.s_ctor_%s, ptr %s)"
                          p cname ps);
            let r = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = load ptr, ptr %s" r p);
            r
        in
        let end_label = fresh_label "show_armend_" in
        emit_instr (Printf.sprintf "  br label %%%s" end_label);
        emit_label end_label;
        phi_entries := (s, end_label) :: !phi_entries;
        emit_instr (Printf.sprintf "  br label %%%s" merge_label);
        emit_label next_label
      ) vs;
      emit_instr "  call void @abort()";
      emit_instr "  unreachable";
      emit_label merge_label;
      let r = fresh_reg () in
      let phi_parts =
        String.concat ", " (List.rev_map (fun (v, lbl) ->
          Printf.sprintf "[%s, %%%s]" v lbl) !phi_entries)
      in
      emit_instr (Printf.sprintf "  %s = phi ptr %s" r phi_parts);
      r
    | _ ->
      "@.s_unit"  (* unknown — fallback to "()" *)
  in
  emit_instr (Printf.sprintf "  ret ptr %s" result_reg);
  let body = String.concat "\n" (List.rev !instrs) in
  instrs := saved_instrs;
  reg_counter := saved_reg;
  label_counter := saved_lbl;
  Printf.sprintf "define ptr @show_%s(%s %%x) {\n%s\n}" tag param_ty body

(* Closure value layout: `{ ptr env, ptr fn }`. The fn pointer's
   concrete signature (T2 (ptr, T1)) is encoded via bitcast at call
   sites; LLVM's opaque pointers tolerate that without a typed cast. *)
let emit_closure_typedef ((p : Ast.ty), (r : Ast.ty)) : string =
  ignore p; ignore r;
  let name = closure_struct_name p r in
  Printf.sprintf "%%%s = type { ptr, ptr }" name

(* Emit `expr` as a sequence of SSA instructions; return the register (or
   literal) holding the result. Caller is expected to know the expected
   LLVM type from the AST's `.ty` annotation. *)
let rec emit_expr (env : env) (e : Ast.expr) : string =
  match e.Ast.node with
  | Ast.Int_lit n -> string_of_int n
  | Ast.Bool_lit b -> if b then "1" else "0"
  | Ast.Unit_lit -> "0"  (* unit represented as i32 0 *)
  | Ast.Str_lit s ->
    (* String literals lower to a private constant + return its symbol;
       since pointers are opaque, the global is directly usable as a ptr. *)
    fresh_str_global s
  | Ast.Var name ->
    if name = "vec_new" || name = "vec_push"
       || name = "vec_get" || name = "vec_len"
       || name = "vec_iter" || name = "vec_map"
       || name = "vec_fold" || name = "vec_set"
       || name = "vec_filter" || name = "vec_to_list"
       || name = "vec_to_owned"
       || name = "owned_vec_new" || name = "owned_vec_push"
       || name = "owned_vec_get" || name = "owned_vec_len"
       || name = "strbuf_new" || name = "strbuf_push"
       || name = "strbuf_to_str" || name = "strbuf_len"
       || name = "map_new" || name = "map_set" || name = "map_get"
       || name = "map_has" || name = "map_len"
       || name = "len" then
      unsupported e.Ast.loc
        (name ^ " (Vec / OwnedVec / StrBuf / Map / len are interpreter-only)");
    (* If a local binding shadows a top-level fn, prefer it. Otherwise,
       if the name resolves to a known top-level fn, materialize the
       closure value `{ ptr null, ptr @<name>_closure_fn }` inline. *)
    (match List.assoc_opt name env with
     | Some v -> v
     | None when Hashtbl.mem toplevel_fn_names name ->
       let arrow =
         match e.Ast.ty with
         | Some t -> Ast.walk t
         | None -> unsupported e.Ast.loc ("fn-as-value missing type: " ^ name)
       in
       let cname =
         match arrow with
         | Ast.TyArrow (p, r) -> closure_struct_name (Ast.walk p) (Ast.walk r)
         | _ -> unsupported e.Ast.loc "fn-as-value on non-arrow type"
       in
       let r0 = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = insertvalue %%%s undef, ptr null, 0" r0 cname);
       let r1 = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, ptr @%s_closure_fn, 1"
                     r1 cname r0 name);
       r1
     | None -> unsupported e.Ast.loc ("unbound variable: " ^ name))
  | Ast.Annot (inner, _) -> emit_expr env inner
  | Ast.Neg inner ->
    let v = emit_expr env inner in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = sub i32 0, %s" r v);
    r
  | Ast.Bin (Ast.Concat, a, b) ->
    let ra = emit_expr env a in
    let rb = emit_expr env b in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @__lang_str_concat(ptr %s, ptr %s)" r ra rb);
    r
  | Ast.Bin (op, a, b) ->
    let ra = emit_expr env a in
    let rb = emit_expr env b in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = %s i32 %s, %s" r (llvm_binop_int op) ra rb);
    r
  | Ast.Cmp (op, a, b) ->
    let ra = emit_expr env a in
    let rb = emit_expr env b in
    let r = fresh_reg () in
    (* Operand type: bool comparisons use i1, otherwise i32. *)
    let opnd_ty =
      match a.Ast.ty with
      | Some t when Ast.walk t = Ast.TyBool -> "i1"
      | _ -> "i32"
    in
    emit_instr (Printf.sprintf "  %s = icmp %s %s %s, %s" r (llvm_cmp_int op) opnd_ty ra rb);
    r
  | Ast.Logic (op, a, b) ->
    (* Short-circuit semantics matter for effects, but the MVP subset has
       no effects, so eager `and`/`or` on i1 is observationally equivalent. *)
    let ra = emit_expr env a in
    let rb = emit_expr env b in
    let r = fresh_reg () in
    let opc = match op with Ast.And -> "and" | Ast.Or -> "or" in
    emit_instr (Printf.sprintf "  %s = %s i1 %s, %s" r opc ra rb);
    r
  | Ast.If (cond, t, f) ->
    let result_ty =
      match e.Ast.ty with
      | Some ty -> llvm_ty_of ty
      | None -> "i32"
    in
    let cv = emit_expr env cond in
    let l_then = fresh_label "then_" in
    let l_else = fresh_label "else_" in
    let l_join = fresh_label "join_" in
    emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s" cv l_then l_else);
    emit_label l_then;
    let tv = emit_expr env t in
    (* The branch's last block might not be l_then if the branch nested
       another If — capture the actual current block via a marker reg. *)
    let l_then_end = fresh_label "then_end_" in
    emit_instr (Printf.sprintf "  br label %%%s" l_then_end);
    emit_label l_then_end;
    emit_instr (Printf.sprintf "  br label %%%s" l_join);
    emit_label l_else;
    let fv = emit_expr env f in
    let l_else_end = fresh_label "else_end_" in
    emit_instr (Printf.sprintf "  br label %%%s" l_else_end);
    emit_label l_else_end;
    emit_instr (Printf.sprintf "  br label %%%s" l_join);
    emit_label l_join;
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = phi %s [%s, %%%s], [%s, %%%s]"
                  r result_ty tv l_then_end fv l_else_end);
    r
  | Ast.Let (pat, value, body) ->
    (match pat.Ast.pnode with
     | Ast.P_var name ->
       let rv = emit_expr env value in
       let saved = !current_var_types in
       let value_ty =
         match value.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
       in
       current_var_types := (name, value_ty) :: saved;
       let r = emit_expr ((name, rv) :: env) body in
       current_var_types := saved;
       r
     | _ ->
       unsupported pat.Ast.ploc "non-P_var let pattern — Phase 5 later slice")
  | Ast.App ({ node = Ast.Var "fst"; _ }, arg) ->
    let av = emit_expr env arg in
    let tname =
      match arg.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyTuple ts -> tuple_struct_name ts
         | _ -> unsupported e.Ast.loc "fst on non-tuple")
      | None -> unsupported e.Ast.loc "fst: missing arg type"
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 0" r tname av);
    r
  | Ast.App ({ node = Ast.Var "snd"; _ }, arg) ->
    let av = emit_expr env arg in
    let tname =
      match arg.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyTuple ts -> tuple_struct_name ts
         | _ -> unsupported e.Ast.loc "snd on non-tuple")
      | None -> unsupported e.Ast.loc "snd: missing arg type"
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 1" r tname av);
    r
  | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "show: missing arg type"
    in
    let tag = ty_tag arg_ty in
    let av = emit_expr env arg in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call ptr @show_%s(%s %s)"
                  r tag (llvm_ty_of arg_ty) av);
    r
  | Ast.App ({ node = Ast.Var "print"; _ }, arg) ->
    let av = emit_expr env arg in
    emit_instr (Printf.sprintf "  call i32 @puts(ptr %s)" av);
    "0"  (* unit / int 0 *)
  | Ast.App ({ node = Ast.Var "str_len"; _ }, arg) ->
    let av = emit_expr env arg in
    let raw = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call i64 @strlen(ptr %s)" raw av);
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = trunc i64 %s to i32" r raw);
    r
  | Ast.App ({ node = Ast.Var name; _ }, arg)
    when Hashtbl.mem toplevel_fn_names name ->
    let av = emit_expr env arg in
    let ret_ty =
      match e.Ast.ty with
      | Some t -> llvm_ty_of t
      | None -> "i32"
    in
    let arg_ty =
      (* Prefer current_var_types for Var args (in case the AST .ty is
         still polymorphic from let-rec generalization). *)
      let from_var_types =
        match arg.Ast.node with
        | Ast.Var n ->
          (match List.assoc_opt n !current_var_types with
           | Some t when ty_is_concrete t -> Some (llvm_ty_of (Ast.walk t))
           | _ -> None)
        | _ -> None
      in
      match from_var_types with
      | Some s -> s
      | None ->
        (match arg.Ast.ty with
         | Some t -> llvm_ty_of t
         | None -> "i32")
    in
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call %s @%s(%s %s)" r ret_ty name arg_ty av);
    r
  | Ast.App (f, arg) ->
    (* Closure dispatch via the closure value's fn pointer. *)
    let arrow_ty =
      (* Prefer current_var_types if the head is a Var with a known
         concrete binding — fn body may carry polymorphic .ty. *)
      let from_var_types =
        match f.Ast.node with
        | Ast.Var n ->
          (match List.assoc_opt n !current_var_types with
           | Some t when ty_is_concrete t -> Some (Ast.walk t)
           | _ -> None)
        | _ -> None
      in
      match from_var_types with
      | Some t -> t
      | None ->
        (match f.Ast.ty with
         | Some t -> Ast.walk t
         | None -> unsupported f.Ast.loc "closure call: missing fn type")
    in
    let cname =
      match arrow_ty with
      | Ast.TyArrow (p, r) -> closure_struct_name (Ast.walk p) (Ast.walk r)
      | _ -> unsupported f.Ast.loc "closure call on non-arrow"
    in
    let ret_ty =
      match e.Ast.ty with
      | Some t -> llvm_ty_of t
      | None -> "i32"
    in
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> llvm_ty_of t
      | None -> "i32"
    in
    let cv = emit_expr env f in
    let av = emit_expr env arg in
    let env_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 0" env_reg cname cv);
    let fn_reg = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 1" fn_reg cname cv);
    let r = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = call %s %s(ptr %s, %s %s)"
                  r ret_ty fn_reg env_reg arg_ty av);
    r
  | Ast.Tuple elems ->
    let tname =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyTuple ts -> tuple_struct_name ts
         | _ -> unsupported e.Ast.loc "tuple literal has non-tuple type")
      | None -> unsupported e.Ast.loc "tuple literal: missing inferred type"
    in
    let elem_tys =
      match e.Ast.ty with
      | Some t -> (match Ast.walk t with Ast.TyTuple ts -> ts | _ -> [])
      | None -> []
    in
    (* Build the struct value via a chain of insertvalue, starting from
       `undef`. Each insertvalue produces a new SSA value of the same
       struct type. *)
    let rec build prev idx = function
      | [] -> prev
      | (elem, ty) :: rest ->
        let ev = emit_expr env elem in
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, %d"
                      r tname prev (llvm_ty_of ty) ev idx);
        build r (idx + 1) rest
    in
    build "undef" 0 (List.combine elems elem_tys)
  | Ast.Record_lit (name, fields) when Hashtbl.mem Typer.views name ->
    (* View literal: allocate the struct in the view's region (encoded as
       a [R] tyref in the inferred type), insertvalue chain to build the
       record value, store into the allocated buffer, return ptr. *)
    let region =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon (_, [Ast.TyRef (_, r, _)]) -> r
         | _ -> unsupported e.Ast.loc
                  "view literal missing region marker in inferred type")
      | None -> unsupported e.Ast.loc "view literal: missing type info"
    in
    let region_p =
      match List.assoc_opt region !current_regions with
      | Some r -> r
      | None -> unsupported e.Ast.loc
                  ("view literal: region not in scope: " ^ region)
    in
    let info = Hashtbl.find Typer.views name in
    let rec build prev idx = function
      | [] -> prev
      | (fname, fty) :: rest ->
        let ex =
          match List.assoc_opt fname fields with
          | Some e -> e
          | None ->
            unsupported e.Ast.loc
              (Printf.sprintf "view literal missing field `%s`" fname)
        in
        let ev = emit_expr env ex in
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, %d"
                      r name prev (llvm_ty_of fty) ev idx);
        build r (idx + 1) rest
    in
    let v = build "undef" 0 info.Typer.v_fields in
    let size_p = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = getelementptr %%%s, ptr null, i32 1"
                  size_p name);
    let size = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" size size_p);
    let p = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @__lang_region_alloc(ptr %s, i64 %s)"
                  p region_p size);
    emit_instr (Printf.sprintf "  store %%%s %s, ptr %s" name v p);
    p
  | Ast.Record_lit (name, fields) ->
    let () = ignore name in
    begin
      let info =
        match Hashtbl.find_opt Typer.records name with
        | Some i -> i
        | None ->
          unsupported e.Ast.loc ("unknown record type: " ^ name)
      in
      (* Mono vs poly: for polymorphic records, pick the mono instance
         from the Record_lit's inferred type and substitute fields. *)
      let struct_name, decl_fields =
        if info.Typer.r_params <> [] then
          let args =
            match e.Ast.ty with
            | Some t ->
              (match Ast.walk t with
               | Ast.TyCon (n, ts) when n = name -> List.map Ast.walk ts
               | _ -> unsupported e.Ast.loc
                        "Record_lit: type info missing concrete args")
            | None -> unsupported e.Ast.loc "Record_lit: missing inferred type"
          in
          let mapping = List.combine info.Typer.r_params args in
          let sf =
            List.map (fun (fn, ft) -> (fn, subst_params mapping ft))
              info.Typer.r_fields
          in
          (mono_record_name name args, sf)
        else
          (name, info.Typer.r_fields)
      in
      let rec build prev idx = function
        | [] -> prev
        | (fname, fty) :: rest ->
          let ex =
            match List.assoc_opt fname fields with
            | Some e -> e
            | None ->
              unsupported e.Ast.loc
                (Printf.sprintf "missing field `%s` in record literal" fname)
          in
          let ev = emit_expr env ex in
          let r = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, %d"
                        r struct_name prev (llvm_ty_of fty) ev idx);
          build r (idx + 1) rest
      in
      build "undef" 0 decl_fields
    end
  | Ast.Field_get (inner, fname) ->
    let iv = emit_expr env inner in
    let inner_ty =
      match inner.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "field access: missing inner type"
    in
    if is_view_type inner_ty then begin
      (* View value is a ptr to a region-allocated struct. GEP+load. *)
      let name =
        match inner_ty with
        | Ast.TyCon (n, _) -> n
        | _ -> assert false
      in
      let info = Hashtbl.find Typer.views name in
      let fields = info.Typer.v_fields in
      let rec find_idx i = function
        | [] ->
          unsupported e.Ast.loc
            (Printf.sprintf "view `%s` has no field `%s`" name fname)
        | (n, t) :: _ when n = fname -> (i, t)
        | _ :: rest -> find_idx (i + 1) rest
      in
      let (idx, ft) = find_idx 0 fields in
      let p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %%%s, ptr %s, i32 0, i32 %d"
                    p name iv idx);
      let r = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                    r (llvm_ty_of ft) p);
      r
    end
    else begin
      let struct_name, fields =
        match inner_ty with
        | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
          let args = List.map Ast.walk args in
          let (params, fs) = Hashtbl.find polymorphic_records n in
          let mapping = List.combine params args in
          let sf = List.map (fun (fn, ft) -> (fn, subst_params mapping ft)) fs in
          (mono_record_name n args, sf)
        | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
          (n, record_fields n)
        | _ -> unsupported e.Ast.loc "field access on non-record"
      in
      let idx =
        let rec find i = function
          | [] ->
            unsupported e.Ast.loc
              (Printf.sprintf "record `%s` has no field `%s`" struct_name fname)
          | (n, _) :: _ when n = fname -> i
          | _ :: rest -> find (i + 1) rest
        in find 0 fields
      in
      let r = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, %d"
                    r struct_name iv idx);
      r
    end
  | Ast.Record_update (base, updates) ->
    let bv = emit_expr env base in
    let struct_name, fields =
      match base.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
           let args = List.map Ast.walk args in
           let (params, fs) = Hashtbl.find polymorphic_records n in
           let mapping = List.combine params args in
           let sf = List.map (fun (fn, ft) -> (fn, subst_params mapping ft)) fs in
           (mono_record_name n args, sf)
         | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
           (n, record_fields n)
         | _ -> unsupported e.Ast.loc "record update on non-record")
      | None -> unsupported e.Ast.loc "record update: missing base type"
    in
    let field_index_local fname =
      let rec find i = function
        | [] ->
          unsupported e.Ast.loc
            (Printf.sprintf "record `%s` has no field `%s`" struct_name fname)
        | (n, _) :: _ when n = fname -> i
        | _ :: rest -> find (i + 1) rest
      in find 0 fields
    in
    let rec apply prev = function
      | [] -> prev
      | (fname, ex) :: rest ->
        let fty =
          try List.assoc fname fields
          with Not_found ->
            unsupported e.Ast.loc
              (Printf.sprintf "record `%s` has no field `%s`" struct_name fname)
        in
        let ev = emit_expr env ex in
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, %d"
                      r struct_name prev (llvm_ty_of fty) ev
                      (field_index_local fname));
        apply r rest
    in
    apply bv updates
  | Ast.Constr (cname, arg_opt) ->
    let info =
      match Hashtbl.find_opt Typer.constructors cname with
      | Some i -> i
      | None -> unsupported e.Ast.loc ("unknown constructor: " ^ cname)
    in
    let type_name = info.Typer.type_name in
    if not (Hashtbl.mem Typer.types type_name) then
      unsupported e.Ast.loc ("constructor's type not registered: " ^ type_name);
    let tag =
      match Hashtbl.find_opt variant_tags cname with
      | Some t -> t
      | None -> unsupported e.Ast.loc ("constructor without tag: " ^ cname)
    in
    let struct_name, payload_ty =
      if Hashtbl.mem polymorphic_variants type_name then begin
        let args =
          match e.Ast.ty with
          | Some t ->
            (match Ast.walk t with
             | Ast.TyCon (n, ts) when n = type_name -> List.map Ast.walk ts
             | _ -> unsupported e.Ast.loc
                      "Constr: type info missing concrete args")
          | None -> unsupported e.Ast.loc "Constr: missing inferred type"
        in
        let mono = mono_variant_name type_name args in
        let (params, variants) = Hashtbl.find polymorphic_variants type_name in
        let sv = subst_variants params args variants in
        (mono, variant_payload_ty_of sv)
      end else
        (type_name, variant_payload_ty type_name)
    in
    if is_recursive_variant_name struct_name then begin
      (* Recursive variant: allocate a node in the default region, write
         tag (+ optional payload) via getelementptr + store, return ptr. *)
      let node_ty = "%" ^ struct_name ^ "_node" in
      let size_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr null, i32 1"
                    size_p node_ty);
      let size = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" size size_p);
      let p = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %s)"
                    p size);
      let tag_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 0"
                    tag_p node_ty p);
      emit_instr (Printf.sprintf "  store i32 %d, ptr %s" tag tag_p);
      (match arg_opt, payload_ty with
       | None, _ -> ()
       | Some arg, Some pty ->
         let av = emit_expr env arg in
         let pl_p = fresh_reg () in
         emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 1"
                       pl_p node_ty p);
         emit_instr (Printf.sprintf "  store %s %s, ptr %s"
                       (llvm_ty_of pty) av pl_p)
       | Some _, None ->
         unsupported e.Ast.loc
           (Printf.sprintf
              "constructor `%s` has payload but variant lowered as nullary-only"
              cname));
      p
    end
    else begin
      let r0 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s undef, i32 %d, 0"
                    r0 struct_name tag);
      match arg_opt, payload_ty with
      | None, _ -> r0
      | Some arg, Some pty ->
        let av = emit_expr env arg in
        let r1 = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, %s %s, 1"
                      r1 struct_name r0 (llvm_ty_of pty) av);
        r1
      | Some _, None ->
        unsupported e.Ast.loc
          (Printf.sprintf
             "constructor `%s` has payload but variant lowered as nullary-only"
             cname)
    end
  | Ast.Match (scrut, arms) ->
    let scrut_ty =
      let from_var_types =
        match scrut.Ast.node with
        | Ast.Var n ->
          (match List.assoc_opt n !current_var_types with
           | Some t when ty_is_concrete t -> Some (Ast.walk t)
           | _ -> None)
        | _ -> None
      in
      match from_var_types with
      | Some t -> t
      | None ->
        (match scrut.Ast.ty with
         | Some t -> Ast.walk t
         | None -> unsupported e.Ast.loc "match: missing scrutinee type")
    in
    let scrut_v = emit_expr env scrut in
    let result_ty =
      match e.Ast.ty with
      | Some t -> llvm_ty_of t
      | None -> "i32"
    in
    let merge_label = fresh_label "match_join_" in
    let phi_entries = ref [] in
    (* Combine two i1 booleans with `and i1`. *)
    let and_cond a b =
      if a = "1" then b
      else if b = "1" then a
      else begin
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = and i1 %s, %s" r a b);
        r
      end
    in
    (* Fully recursive pattern compiler. Tests run via icmp / strcmp /
       extractvalue / load and AND together. Bindings accumulate as
       (name, register). For nested constructors / tuples / records,
       sub-patterns recurse on extracted sub-values. *)
    let rec compile_pat (pat : Ast.pattern) (v_reg : string) (v_ty : Ast.ty)
      : string * (string * string) list * (string * Ast.ty) list =
      match pat.Ast.pnode with
      | Ast.P_wild -> ("1", [], [])
      | Ast.P_var n -> ("1", [(n, v_reg)], [(n, v_ty)])
      | Ast.P_unit -> ("1", [], [])
      | Ast.P_int n ->
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, %d" r v_reg n);
        (r, [], [])
      | Ast.P_bool b ->
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i1 %s, %d" r v_reg (if b then 1 else 0));
        (r, [], [])
      | Ast.P_str s ->
        let label = fresh_str_global s in
        let cmp = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = call i32 @strcmp(ptr %s, ptr %s)" cmp v_reg label);
        let r = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, 0" r cmp);
        (r, [], [])
      | Ast.P_as (inner, n) ->
        let (c, bs, tys) = compile_pat inner v_reg v_ty in
        (c, (n, v_reg) :: bs, (n, v_ty) :: tys)
      | Ast.P_tuple pats ->
        let elem_tys =
          match Ast.walk v_ty with Ast.TyTuple ts -> ts | _ ->
            unsupported pat.Ast.ploc "P_tuple on non-tuple"
        in
        let tname = tuple_struct_name elem_tys in
        let rec go i acc_cond acc_bs acc_tys = function
          | [] -> (acc_cond, List.rev acc_bs, List.rev acc_tys)
          | p :: rest ->
            let ety = List.nth elem_tys i in
            let er = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, %d"
                          er tname v_reg i);
            let (c, bs, tys) = compile_pat p er ety in
            go (i + 1) (and_cond acc_cond c)
              (List.rev_append bs acc_bs) (List.rev_append tys acc_tys) rest
        in
        go 0 "1" [] [] pats
      | Ast.P_record (_, sub_fields) ->
        let struct_name, decl_fields =
          match Ast.walk v_ty with
          | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_records n ->
            let args = List.map Ast.walk args in
            let (params, fs) = Hashtbl.find polymorphic_records n in
            let mapping = List.combine params args in
            let sf = List.map (fun (fn, ft) -> (fn, subst_params mapping ft)) fs in
            (mono_record_name n args, sf)
          | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
            (n, record_fields n)
          | _ -> unsupported pat.Ast.ploc "P_record on non-record"
        in
        let idx_of fname =
          let rec find i = function
            | [] -> -1
            | (n, _) :: _ when n = fname -> i
            | _ :: rest -> find (i + 1) rest
          in find 0 decl_fields
        in
        let ty_of fname = List.assoc fname decl_fields in
        let rec go acc_cond acc_bs acc_tys = function
          | [] -> (acc_cond, List.rev acc_bs, List.rev acc_tys)
          | (fname, sub_p) :: rest ->
            let i = idx_of fname in
            let ft = ty_of fname in
            let fr = fresh_reg () in
            emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, %d"
                          fr struct_name v_reg i);
            let (c, bs, tys) = compile_pat sub_p fr ft in
            go (and_cond acc_cond c)
              (List.rev_append bs acc_bs) (List.rev_append tys acc_tys) rest
        in
        go "1" [] [] sub_fields
      | Ast.P_constr (cname, sub) ->
        let info =
          match Hashtbl.find_opt Typer.constructors cname with
          | Some i -> i
          | None -> unsupported pat.Ast.ploc ("unknown ctor: " ^ cname)
        in
        let type_name = info.Typer.type_name in
        let struct_name, payload_ty =
          match Ast.walk v_ty with
          | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
            let args = List.map Ast.walk args in
            let mono = mono_variant_name n args in
            let (params, variants) = Hashtbl.find polymorphic_variants n in
            let sv = subst_variants params args variants in
            (mono, variant_payload_ty_of sv)
          | _ -> (type_name, variant_payload_ty type_name)
        in
        let recursive = is_recursive_variant_name struct_name in
        let node_ty = "%" ^ struct_name ^ "_node" in
        let tag =
          match Hashtbl.find_opt variant_tags cname with
          | Some t -> t
          | None -> unsupported pat.Ast.ploc ("ctor without tag: " ^ cname)
        in
        let tag_reg = fresh_reg () in
        if recursive then begin
          let p = fresh_reg () in
          emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 0"
                        p node_ty v_reg);
          emit_instr (Printf.sprintf "  %s = load i32, ptr %s" tag_reg p)
        end else
          emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 0"
                        tag_reg struct_name v_reg);
        let tag_cond = fresh_reg () in
        emit_instr (Printf.sprintf "  %s = icmp eq i32 %s, %d" tag_cond tag_reg tag);
        (match sub, payload_ty with
         | None, _ -> (tag_cond, [], [])
         | Some sub_pat, Some pty ->
           let payload_reg = fresh_reg () in
           if recursive then begin
             let p = fresh_reg () in
             emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr %s, i32 0, i32 1"
                           p node_ty v_reg);
             emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                           payload_reg (llvm_ty_of pty) p)
           end else
             emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, 1"
                           payload_reg struct_name v_reg);
           let (c, bs, tys) = compile_pat sub_pat payload_reg pty in
           (and_cond tag_cond c, bs, tys)
         | Some _, None ->
           unsupported pat.Ast.ploc
             "pattern has payload but variant has no payload type")
      | Ast.P_or _ ->
        unsupported pat.Ast.ploc "P_or should have been flattened"
    in
    (* Pre-flatten or-patterns into multiple arms. The typer guarantees
       both branches bind the same names with compatible types. *)
    let rec expand_or (pat, guard, body) =
      match pat.Ast.pnode with
      | Ast.P_or (a, b) ->
        expand_or (a, guard, body) @ expand_or (b, guard, body)
      | _ -> [(pat, guard, body)]
    in
    let arms = List.concat_map expand_or arms in
    let rec emit_arms = function
      | [] ->
        emit_instr "  call void @abort()";
        emit_instr "  unreachable"
      | (pat, guard, body) :: rest ->
        let (cond, bindings, var_tys) = compile_pat pat scrut_v scrut_ty in
        let arm_label = fresh_label "arm_" in
        let next_label = fresh_label "next_" in
        emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                      cond arm_label next_label);
        emit_label arm_label;
        let env' = bindings @ env in
        let saved_vt = !current_var_types in
        current_var_types := var_tys @ saved_vt;
        (* Guard: evaluate within the arm's bindings scope. If false,
           branch to next_label (= same as failing the test). *)
        (match guard with
         | None -> ()
         | Some g ->
           let gv = emit_expr env' g in
           let pass_label = fresh_label "guard_pass_" in
           emit_instr (Printf.sprintf "  br i1 %s, label %%%s, label %%%s"
                         gv pass_label next_label);
           emit_label pass_label);
        let v = emit_expr env' body in
        current_var_types := saved_vt;
        let end_label = fresh_label "arm_end_" in
        emit_instr (Printf.sprintf "  br label %%%s" end_label);
        emit_label end_label;
        phi_entries := (v, end_label) :: !phi_entries;
        emit_instr (Printf.sprintf "  br label %%%s" merge_label);
        emit_label next_label;
        emit_arms rest
    in
    emit_arms arms;
    emit_label merge_label;
    let r = fresh_reg () in
    let phi_parts =
      String.concat ", " (List.rev_map (fun (v, lbl) ->
        Printf.sprintf "[%s, %%%s]" v lbl) !phi_entries)
    in
    emit_instr (Printf.sprintf "  %s = phi %s %s" r result_ty phi_parts);
    r
  | Ast.Fun (param, _, fn_body) ->
    (* Anonymous Fun in expression position → emit a closure value:
       env-struct alloc (default region) + adapter (deferred) + closure
       value built via insertvalue. *)
    let arrow_ty =
      let from_node =
        match e.Ast.ty with Some t -> Some (Ast.walk t) | None -> None
      in
      let from_ctx = !current_expected_ty in
      match from_node, from_ctx with
      | Some t, _ when ty_is_concrete t -> t
      | _, Some t when ty_is_concrete t -> t
      | Some t, _ -> t  (* best-effort; will likely raise in ty_tag *)
      | None, _ ->
        unsupported e.Ast.loc "anonymous fn missing inferred type (no context)"
    in
    let param_ty, return_ty =
      match arrow_ty with
      | Ast.TyArrow (p, r) -> (Ast.walk p, Ast.walk r)
      | _ -> unsupported e.Ast.loc "anonymous fn has non-arrow type"
    in
    let raw_fvs = free_vars fn_body [param] in
    let fvs =
      List.filter (fun n -> List.mem_assoc n !current_var_types) raw_fvs
    in
    let captures =
      List.map (fun fv ->
        let cty =
          match List.assoc_opt fv !current_var_types with
          | Some t when ty_is_concrete t -> Ast.walk t
          | _ ->
            unsupported e.Ast.loc
              (Printf.sprintf "capture `%s` has non-concrete type" fv)
        in
        (fv, cty)) fvs
    in
    let adapter_name, env_name = fresh_anon_names () in
    pending_closures := {
      ce_adapter_name = adapter_name;
      ce_env_name = env_name;
      ce_env_fields = captures;
      ce_param = param;
      ce_param_ty = param_ty;
      ce_return_ty = return_ty;
      ce_body = fn_body;
    } :: !pending_closures;
    (* Env struct typedef (even when empty — only emit if captures > 0). *)
    if captures <> [] then begin
      let fields =
        String.concat ", " (List.map (fun (_, t) -> llvm_ty_of t) captures)
      in
      anon_env_typedefs :=
        Printf.sprintf "%%%s = type { %s }" env_name fields
        :: !anon_env_typedefs
    end;
    let cstruct = closure_struct_name param_ty return_ty in
    if captures = [] then begin
      let r0 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s undef, ptr null, 0" r0 cstruct);
      let r1 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, ptr @%s, 1"
                    r1 cstruct r0 adapter_name);
      r1
    end else begin
      let size_p = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = getelementptr %%%s, ptr null, i32 1"
                    size_p env_name);
      let size = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" size size_p);
      let env_p = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %s)"
                    env_p size);
      List.iteri (fun i (cname, cty) ->
        let cv =
          match List.assoc_opt cname env with
          | Some v -> v
          | None -> unsupported e.Ast.loc ("capture not in scope: " ^ cname)
        in
        let p = fresh_reg () in
        emit_instr (Printf.sprintf
                      "  %s = getelementptr %%%s, ptr %s, i32 0, i32 %d"
                      p env_name env_p i);
        emit_instr (Printf.sprintf "  store %s %s, ptr %s"
                      (llvm_ty_of cty) cv p)
      ) captures;
      let r0 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s undef, ptr %s, 0"
                    r0 cstruct env_p);
      let r1 = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = insertvalue %%%s %s, ptr @%s, 1"
                    r1 cstruct r0 adapter_name);
      r1
    end
  | Ast.Region_block (name, body) ->
    (* Allocate a fresh region locally, run body within it, free at exit.
       The region's SSA ptr is pushed onto current_regions so Ref / view
       constructions inside body find it by name. *)
    let region_p = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = alloca %%__lang_region" region_p);
    emit_instr (Printf.sprintf
                  "  call void @__lang_region_init(ptr %s, i64 1048576)" region_p);
    let saved = !current_regions in
    current_regions := (name, region_p) :: saved;
    let v = emit_expr env body in
    current_regions := saved;
    emit_instr (Printf.sprintf "  call void @__lang_region_free(ptr %s)" region_p);
    v
  | Ast.Ref (_mode, region, inner) ->
    (* `&R v` — region-allocate a copy of `v` and return ptr. *)
    let v = emit_expr env inner in
    let v_ty =
      match inner.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "&R: missing inner type"
    in
    let region_p =
      match List.assoc_opt region !current_regions with
      | Some r -> r
      | None -> unsupported e.Ast.loc ("&R: region not in scope: " ^ region)
    in
    let size_p = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = getelementptr %s, ptr null, i32 1"
                  size_p (llvm_ty_of v_ty));
    let size = fresh_reg () in
    emit_instr (Printf.sprintf "  %s = ptrtoint ptr %s to i64" size size_p);
    let p = fresh_reg () in
    emit_instr (Printf.sprintf
                  "  %s = call ptr @__lang_region_alloc(ptr %s, i64 %s)"
                  p region_p size);
    emit_instr (Printf.sprintf "  store %s %s, ptr %s" (llvm_ty_of v_ty) v p);
    p
  | Ast.With (name, value, body) ->
    (* `with c = v in body` — bind v, run body, then auto-invoke
       c.close(unit) if v's record type has a `close: unit -> unit` field.
       Body's resulting value is returned. *)
    let vv = emit_expr env value in
    let value_ty =
      match value.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "with: missing value type"
    in
    (* Discover record type name + struct + close field index (if any). *)
    let close_info =
      match value_ty with
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
        let fields = record_fields n in
        let rec find_close i = function
          | [] -> None
          | (fname, fty) :: _ when fname = "close" -> Some (i, fty, n)
          | _ :: rest -> find_close (i + 1) rest
        in
        find_close 0 fields
      | _ -> None
    in
    let saved_vt = !current_var_types in
    current_var_types := (name, value_ty) :: saved_vt;
    let body_v = emit_expr ((name, vv) :: env) body in
    current_var_types := saved_vt;
    (* Auto-invoke close (after body is evaluated). *)
    (match close_info with
     | None -> ()
     | Some (idx, fty, struct_name) ->
       let close_cl = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = extractvalue %%%s %s, %d"
                     close_cl struct_name vv idx);
       let cname = llvm_ty_of fty in
       let env_r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = extractvalue %s %s, 0"
                     env_r cname close_cl);
       let fn_r = fresh_reg () in
       emit_instr (Printf.sprintf "  %s = extractvalue %s %s, 1"
                     fn_r cname close_cl);
       let _ = fresh_reg () in
       emit_instr (Printf.sprintf "  call i32 %s(ptr %s, i32 0)" fn_r env_r));
    body_v
  | Ast.Float_lit _
  | Ast.Let_rec _ ->
    unsupported e.Ast.loc "node kind not yet in Phase 5 MVP"

(* Emit the body of an anonymous-Fun adapter: gep + load each capture
   from `%env_self`, then evaluate the original Fun body with the
   captures bound. Returns the full `define ...` string. *)
let emit_anon_adapter (ce : closure_emission) : string =
  let saved_instrs = !instrs in
  let saved_reg = !reg_counter and saved_lbl = !label_counter in
  let saved_vt = !current_var_types in
  let saved_exp = !current_expected_ty in
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
  current_expected_ty := Some ce.ce_return_ty;
  emit_instr "entry:";
  (* Build env: load each capture from %env_self into a fresh register
     so the body can reference it by name. *)
  let cap_env =
    List.mapi (fun i (cname, cty) ->
      if ce.ce_env_fields = [] then assert false;
      let p = fresh_reg () in
      emit_instr (Printf.sprintf
                    "  %s = getelementptr %%%s, ptr %%env_self, i32 0, i32 %d"
                    p ce.ce_env_name i);
      let v = fresh_reg () in
      emit_instr (Printf.sprintf "  %s = load %s, ptr %s"
                    v (llvm_ty_of cty) p);
      (cname, v)) ce.ce_env_fields
  in
  let env = (ce.ce_param, "%" ^ ce.ce_param) :: cap_env in
  current_var_types :=
    (ce.ce_param, ce.ce_param_ty) ::
    List.map (fun (n, t) -> (n, t)) ce.ce_env_fields;
  let rv = emit_expr env ce.ce_body in
  emit_instr (Printf.sprintf "  ret %s %s" (llvm_ty_of ce.ce_return_ty) rv);
  let body = String.concat "\n" (List.rev !instrs) in
  instrs := saved_instrs;
  reg_counter := saved_reg;
  label_counter := saved_lbl;
  current_var_types := saved_vt;
  current_expected_ty := saved_exp;
  Printf.sprintf
    "define %s @%s(ptr %%env_self, %s %%%s) {\n%s\n}"
    (llvm_ty_of ce.ce_return_ty) ce.ce_adapter_name
    (llvm_ty_of ce.ce_param_ty) ce.ce_param body

(* Env-ignoring adapter so the top-level fn `f` can be used as a closure
   value: `T2 @f_closure_fn(ptr unused, T1 %x) { ret T2 @f(T1 %x); }`. *)
let emit_closure_adapter (f : fn_decl) : string =
  let pt = llvm_ty_of f.param_ty in
  let rt = llvm_ty_of f.return_ty in
  let inner_call =
    Printf.sprintf "  %%r = call %s @%s(%s %%x)" rt f.name pt
  in
  Printf.sprintf
    "define %s @%s_closure_fn(ptr %%env_unused, %s %%x) {\nentry:\n%s\n  ret %s %%r\n}"
    rt f.name pt inner_call rt

(* Emit a top-level fn definition. Each fn gets fresh register/label
   counters so the SSA names don't collide across functions. *)
let emit_fn_def (f : fn_decl) : string =
  reg_counter := 0;
  label_counter := 0;
  let saved = !instrs in
  let saved_types = !current_var_types in
  let saved_exp = !current_expected_ty in
  instrs := [];
  current_var_types := [(f.param, f.param_ty)];
  current_expected_ty := Some f.return_ty;
  emit_instr "entry:";
  let env = [(f.param, "%" ^ f.param)] in
  let rv = emit_expr env f.body in
  emit_instr (Printf.sprintf "  ret %s %s" (llvm_ty_of f.return_ty) rv);
  let body = String.concat "\n" (List.rev !instrs) in
  instrs := saved;
  current_var_types := saved_types;
  current_expected_ty := saved_exp;
  Printf.sprintf "define %s @%s(%s %%%s) {\n%s\n}"
    (llvm_ty_of f.return_ty) f.name (llvm_ty_of f.param_ty) f.param body

(* Convert the program's main result type to (LLVM type, printf format).
   `unit` skips printing entirely. `str` uses %s. *)
let main_format_of (t : Ast.ty) : (string * string) option =
  match Ast.walk t with
  | Ast.TyInt -> Some ("i32", "%d")
  | Ast.TyBool -> Some ("i32", "%d")  (* zext from i1 *)
  | Ast.TyStr -> Some ("ptr", "%s")
  | Ast.TyUnit -> None
  | _ -> Some ("i32", "%d")

(* Runtime helpers emitted as LLVM IR. Mirrors codegen_c's runtime
   helpers but inlined into the .ll module so the file is self-contained. *)
let runtime_decls =
  String.concat "\n"
    [ "declare ptr @malloc(i64)";
      "declare void @free(ptr)";
      "declare i64 @strlen(ptr)";
      "declare i32 @strcmp(ptr, ptr)";
      "declare ptr @memcpy(ptr, ptr, i64)";
      "declare i32 @puts(ptr)";
      "declare i32 @printf(ptr, ...)";
      "declare i32 @asprintf(ptr, ptr, ...)";
      "declare void @abort()" ]

(* Region runtime — mirrors codegen_c's region_runtime_helpers but
   expressed in LLVM IR. Uses an 8-byte aligned bump-pointer allocator.
   The default region is a file-scope global initialized in @main. *)
let region_runtime_helpers =
  String.concat "\n"
    [ "%__lang_region = type { ptr, ptr, i64 }";
      "@__lang_default_region = internal global %__lang_region zeroinitializer";
      "";
      "define void @__lang_region_init(ptr %r, i64 %cap) {";
      "entry:";
      "  %base = call ptr @malloc(i64 %cap)";
      "  %base_p = getelementptr %__lang_region, ptr %r, i32 0, i32 0";
      "  store ptr %base, ptr %base_p";
      "  %top_p = getelementptr %__lang_region, ptr %r, i32 0, i32 1";
      "  store ptr %base, ptr %top_p";
      "  %cap_p = getelementptr %__lang_region, ptr %r, i32 0, i32 2";
      "  store i64 %cap, ptr %cap_p";
      "  ret void";
      "}";
      "";
      "define ptr @__lang_region_alloc(ptr %r, i64 %n) {";
      "entry:";
      "  %n7 = add i64 %n, 7";
      "  %aligned = and i64 %n7, -8";
      "  %top_p = getelementptr %__lang_region, ptr %r, i32 0, i32 1";
      "  %top = load ptr, ptr %top_p";
      "  %new_top = getelementptr i8, ptr %top, i64 %aligned";
      "  store ptr %new_top, ptr %top_p";
      "  ret ptr %top";
      "}";
      "";
      "define void @__lang_region_free(ptr %r) {";
      "entry:";
      "  %base_p = getelementptr %__lang_region, ptr %r, i32 0, i32 0";
      "  %base = load ptr, ptr %base_p";
      "  call void @free(ptr %base)";
      "  ret void";
      "}" ]

let str_concat_helper =
  String.concat "\n"
    [ "define ptr @__lang_str_concat(ptr %a, ptr %b) {";
      "entry:";
      "  %la = call i64 @strlen(ptr %a)";
      "  %lb = call i64 @strlen(ptr %b)";
      "  %total = add i64 %la, %lb";
      "  %totalp1 = add i64 %total, 1";
      "  %r = call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %totalp1)";
      "  call ptr @memcpy(ptr %r, ptr %a, i64 %la)";
      "  %p1 = getelementptr i8, ptr %r, i64 %la";
      "  call ptr @memcpy(ptr %p1, ptr %b, i64 %lb)";
      "  %p2 = getelementptr i8, ptr %r, i64 %total";
      "  store i8 0, ptr %p2";
      "  ret ptr %r";
      "}" ]

let emit_program ?(main_ty = Ast.TyInt) (prog : Ast.program) : string =
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
  str_globals := [];
  str_counter := 0;
  pending_closures := [];
  anon_env_typedefs := [];
  anon_closure_counter := 0;
  current_var_types := [];
  Hashtbl.reset toplevel_fn_names;
  Hashtbl.reset polymorphic_variants;
  Hashtbl.reset polymorphic_records;
  Hashtbl.reset mono_variant_instances;
  Hashtbl.reset mono_record_instances;
  Hashtbl.reset recursive_variants;
  Hashtbl.reset show_types;
  show_string_globals := [];
  show_format_globals := [];
  (* Register variant tags + classify into mono / poly. Polymorphic
     variants and records are deferred to mono-instance emission. *)
  Hashtbl.iter (fun name vs ->
    List.iteri (fun i (cname, _) ->
      Hashtbl.replace variant_tags cname i) vs;
    let params =
      match vs with
      | (cname, _) :: _ ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some info -> info.Typer.params
         | None -> [])
      | [] -> []
    in
    if params <> [] then Hashtbl.replace polymorphic_variants name (params, vs);
    (* Mark source-level recursive variants. Mono instances of poly
       recursive variants will be marked below at instance-collection time. *)
    if variant_is_recursive name vs then
      Hashtbl.replace recursive_variants name ()
  ) Exhaustive.type_variants;
  Hashtbl.iter (fun name info ->
    if info.Typer.r_params <> [] then
      Hashtbl.replace polymorphic_records name (info.Typer.r_params, info.Typer.r_fields)
  ) Typer.records;
  let main_expr = Ast.desugar_program prog in
  (* Lift top-level fn bindings; the remainder is the actual main body. *)
  let skels, body_expr = lift_fn_skels main_expr in
  List.iter (fun s -> Hashtbl.replace toplevel_fn_names s.sname ()) skels;
  let fns = resolve_fn_types skels main_expr in
  (* Discover mono variant / record instances + mark recursive ones
     BEFORE any typedef emission. Also collect show types now (their
     instances need to flow into mono_variant_instances so emit picks
     up types only-used-via-show). *)
  collect_mono_instances main_expr fns;
  collect_show_types main_expr fns;
  Hashtbl.iter (fun _ (vn, args) ->
    let (params, variants) = Hashtbl.find polymorphic_variants vn in
    let sv = subst_variants params args variants in
    if mono_variant_is_recursive vn args sv then
      Hashtbl.replace recursive_variants (mono_variant_name vn args) ()
  ) mono_variant_instances;
  let tuple_shapes = collect_tuple_shapes main_expr fns in
  let tuple_typedefs = List.map emit_tuple_typedef tuple_shapes in
  let record_names = collect_record_names main_expr fns in
  let record_typedefs = List.map emit_record_typedef record_names in
  let variant_names = collect_variant_names main_expr fns in
  let variant_typedefs = List.map emit_variant_typedef variant_names in
  let mono_variant_typedefs =
    Hashtbl.fold (fun _ (vn, args) acc ->
      emit_mono_variant_typedef vn args :: acc) mono_variant_instances []
  in
  let mono_record_typedefs =
    Hashtbl.fold (fun _ (rn, args) acc ->
      emit_mono_record_typedef rn args :: acc) mono_record_instances []
  in
  let arrow_types = collect_arrow_types main_expr fns in
  let closure_typedefs = List.map emit_closure_typedef arrow_types in
  (* Pre-register show globals (constants + format strings). Show types
     are already collected (above), but the format strings depend on
     specific types that we register here. *)
  if Hashtbl.length show_types > 0 then begin
    mint_show_global "s_true" "true";
    mint_show_global "s_false" "false";
    mint_show_global "s_unit" "()";
    mint_show_global "s_lbracket" "[";
    mint_show_global "s_rbracket" "]";
    mint_show_global "s_comma_space" ", ";
    mint_show_format "show_int" "%d";
    mint_show_format "show_str" "\"%s\"";
    mint_show_format "show_ctor_payload" "%s %s";
    (* Per-type tuple / record / variant format strings + per-ctor
       name strings. *)
    let registered_ctors = Hashtbl.create 4 in
    Hashtbl.iter (fun tag t ->
      match Ast.walk t with
      | Ast.TyTuple ts ->
        let body =
          "(" ^ String.concat ", "
            (List.init (List.length ts) (fun _ -> "%s")) ^ ")"
        in
        mint_show_format ("show_" ^ tag) body
      | Ast.TyCon (n, _) when Hashtbl.mem polymorphic_records n
                           || Hashtbl.mem Typer.records n ->
        let fields_count =
          if Hashtbl.mem polymorphic_records n then
            let (_, fs) = Hashtbl.find polymorphic_records n in List.length fs
          else
            List.length (record_fields n)
        in
        let body =
          n ^ " { " ^
          String.concat ", "
            (List.mapi (fun i _ ->
              let fname =
                if Hashtbl.mem polymorphic_records n then
                  fst (List.nth (snd (Hashtbl.find polymorphic_records n)) i)
                else
                  fst (List.nth (record_fields n) i)
              in
              fname ^ " = %s") (List.init fields_count (fun _ -> 0)))
          ^ " }"
        in
        mint_show_format ("show_" ^ tag) body
      | Ast.TyCon (n, args) when Hashtbl.mem polymorphic_variants n ->
        let (params, variants) = Hashtbl.find polymorphic_variants n in
        let sv = subst_variants params args variants in
        List.iter (fun (cname, _) ->
          if not (Hashtbl.mem registered_ctors cname) then begin
            Hashtbl.add registered_ctors cname ();
            mint_show_global ("s_ctor_" ^ cname) cname
          end
        ) sv
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.types n ->
        let vs = variant_shape n in
        List.iter (fun (cname, _) ->
          if not (Hashtbl.mem registered_ctors cname) then begin
            Hashtbl.add registered_ctors cname ();
            mint_show_global ("s_ctor_" ^ cname) cname
          end
        ) vs
      | _ -> ()
    ) show_types
  end;
  let show_fn_defs =
    Hashtbl.fold (fun tag t acc -> emit_show_fn tag t :: acc) show_types []
  in
  let fn_defs = List.map emit_fn_def fns in
  let closure_adapters = List.map emit_closure_adapter fns in
  (* Reset counters for the main body. *)
  reg_counter := 0;
  label_counter := 0;
  instrs := [];
  emit_instr "entry:";
  emit_instr
    "  call void @__lang_region_init(ptr @__lang_default_region, i64 4194304)";
  let r = emit_expr [] body_expr in
  (* Optional printf of main result. *)
  let print_lines =
    match main_format_of main_ty with
    | None -> []
    | Some (ty, fmt) ->
      let widen =
        if ty = "i32" && (match Ast.walk main_ty with Ast.TyBool -> true | _ -> false) then
          let r2 = fresh_reg () in
          ([ Printf.sprintf "  %s = zext i1 %s to i32" r2 r ], r2)
        else
          ([], r)
      in
      let (extra, r_final) = widen in
      extra @
      [ Printf.sprintf
          "  call i32 (ptr, ...) @printf(ptr @.fmt_%s, %s %s)"
          (String.sub fmt 1 (String.length fmt - 1)) ty r_final ]
  in
  List.iter emit_instr print_lines;
  emit_instr "  call void @__lang_region_free(ptr @__lang_default_region)";
  emit_instr "  ret i32 0";
  let body = String.concat "\n" (List.rev !instrs) in
  (* Drain pending closures (anonymous Funs accumulated during all of
     the above emits). Draining can push more pendings — keep going
     until the queue is empty. *)
  let anon_adapters = ref [] in
  let rec drain () =
    match !pending_closures with
    | [] -> ()
    | ce :: rest ->
      pending_closures := rest;
      anon_adapters := emit_anon_adapter ce :: !anon_adapters;
      drain ()
  in
  drain ();
  let anon_adapters = List.rev !anon_adapters in
  let format_globals =
    (* Hardcoded format strings. Byte lengths count LLVM escapes (`\0A`)
       as 1 byte each and include the null terminator. *)
    match main_format_of main_ty with
    | None -> []
    | Some (_, "%d") ->
      [ "@.fmt_d = private constant [4 x i8] c\"%d\\0A\\00\"" ]
    | Some (_, "%s") ->
      [ "@.fmt_s = private constant [4 x i8] c\"%s\\0A\\00\"" ]
    | _ -> []
  in
  let parts =
    [ "; LLVM IR generated by lang-ml (Phase 5)";
      "target triple = \"" ^ "x86_64-apple-macosx" ^ "\"";  (* clang will retarget if needed *)
      "" ]
    @ (if variant_typedefs = [] then [] else variant_typedefs @ [""])
    @ (if mono_variant_typedefs = [] then [] else mono_variant_typedefs @ [""])
    @ (if record_typedefs = [] then [] else record_typedefs @ [""])
    @ (if mono_record_typedefs = [] then [] else mono_record_typedefs @ [""])
    @ (if tuple_typedefs = [] then [] else tuple_typedefs @ [""])
    @ (if closure_typedefs = [] then [] else closure_typedefs @ [""])
    @ (if !anon_env_typedefs = [] then []
       else List.rev !anon_env_typedefs @ [""])
    @ (if !str_globals = [] then [] else List.rev !str_globals @ [""])
    @ (if !show_string_globals = [] then []
       else List.rev !show_string_globals @ [""])
    @ (if !show_format_globals = [] then []
       else List.rev !show_format_globals @ [""])
    @ format_globals
    @ [ "";
        runtime_decls;
        "";
        region_runtime_helpers;
        "";
        str_concat_helper;
        "" ]
    @ (if fn_defs = [] then [] else fn_defs @ [""])
    @ (if closure_adapters = [] then [] else closure_adapters @ [""])
    @ (if show_fn_defs = [] then [] else show_fn_defs @ [""])
    @ (if anon_adapters = [] then [] else anon_adapters @ [""])
    @ [ "define i32 @main() {";
        body;
        "}";
        "" ]
  in
  String.concat "\n" parts
