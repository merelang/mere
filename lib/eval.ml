(* Tree-walking interpreter. *)

exception Eval_error of Loc.t * string

type value =
  | V_int of int
  | V_bool of bool
  | V_str of string
  | V_unit
  | V_closure of string * Ast.expr * env
  | V_builtin of string * (value -> value)
  | V_constr of string * value option
  | V_tuple of value list
  | V_record of string * (string * value) list

and env = (string * value ref) list

let rec to_string = function
  | V_int n -> string_of_int n
  | V_bool b -> if b then "true" else "false"
  | V_str s -> Ast.escape_string s
  | V_unit -> "()"
  | V_closure (param, _, _) -> "<closure:" ^ param ^ ">"
  | V_builtin (name, _) -> "<builtin:" ^ name ^ ">"
  | V_constr (name, None) -> name
  | V_constr (name, Some v) -> name ^ " " ^ to_string v
  | V_tuple vs ->
    "(" ^ String.concat ", " (List.map to_string vs) ^ ")"
  | V_record (name, fields) ->
    let parts = List.map (fun (f, v) -> f ^ " = " ^ to_string v) fields in
    name ^ " { " ^ String.concat ", " parts ^ " }"

let type_error loc msg = raise (Eval_error (loc, msg))

let builtin_print =
  V_builtin ("print", fun v ->
    (match v with
     | V_str s -> print_endline s
     | _ -> failwith "print: expected str");
    V_unit)

let builtin_print_int =
  V_builtin ("print_int", fun v ->
    (match v with
     | V_int n -> print_endline (string_of_int n)
     | _ -> failwith "print_int: expected int");
    V_unit)

let builtin_str_of_int =
  V_builtin ("str_of_int", fun v ->
    match v with
    | V_int n -> V_str (string_of_int n)
    | _ -> failwith "str_of_int: expected int")

let builtin_print_bool =
  V_builtin ("print_bool", fun v ->
    (match v with
     | V_bool b -> print_endline (if b then "true" else "false")
     | _ -> failwith "print_bool: expected bool");
    V_unit)

let builtin_not =
  V_builtin ("not", fun v ->
    match v with
    | V_bool b -> V_bool (not b)
    | _ -> failwith "not: expected bool")

let builtin_str_len =
  V_builtin ("str_len", fun v ->
    match v with
    | V_str s -> V_int (String.length s)
    | _ -> failwith "str_len: expected str")

let builtin_int_of_str =
  V_builtin ("int_of_str", fun v ->
    match v with
    | V_str s ->
      (try V_int (int_of_string (String.trim s))
       with Failure _ ->
         raise (Eval_error (Loc.dummy,
           Printf.sprintf "int_of_str: %S is not a valid int" s)))
    | _ -> failwith "int_of_str: expected str")

let initial_env : env =
  [ ("print", ref builtin_print);
    ("print_int", ref builtin_print_int);
    ("print_bool", ref builtin_print_bool);
    ("str_of_int", ref builtin_str_of_int);
    ("not", ref builtin_not);
    ("str_len", ref builtin_str_len);
    ("int_of_str", ref builtin_int_of_str);
  ]

let rec match_pattern (p : Ast.pattern) (v : value) : (string * value) list option =
  match p.pnode, v with
  | Ast.P_wild, _ -> Some []
  | Ast.P_var n, _ -> Some [(n, v)]
  | Ast.P_int n, V_int m when n = m -> Some []
  | Ast.P_bool b, V_bool b' when b = b' -> Some []
  | Ast.P_str s, V_str s' when s = s' -> Some []
  | Ast.P_unit, V_unit -> Some []
  | Ast.P_constr (c, None), V_constr (c', None) when c = c' -> Some []
  | Ast.P_constr (c, Some sub_p), V_constr (c', Some sub_v) when c = c' ->
    match_pattern sub_p sub_v
  | Ast.P_tuple ps, V_tuple vs when List.length ps = List.length vs ->
    let rec combine acc ps vs =
      match ps, vs with
      | [], [] -> Some acc
      | p :: ps', v :: vs' ->
        (match match_pattern p v with
         | None -> None
         | Some bs -> combine (acc @ bs) ps' vs')
      | _ -> None
    in
    combine [] ps vs
  | Ast.P_record (name, fpats), V_record (vname, fields) when name = vname ->
    let rec combine acc fpats =
      match fpats with
      | [] -> Some acc
      | (fname, fpat) :: rest ->
        (match List.assoc_opt fname fields with
         | None -> None
         | Some v ->
           (match match_pattern fpat v with
            | None -> None
            | Some bs -> combine (acc @ bs) rest))
    in
    combine [] fpats
  | _ -> None

let rec eval_in (env : env) (e : Ast.expr) =
  match e.Ast.node with
  | Ast.Int_lit n -> V_int n
  | Ast.Bool_lit b -> V_bool b
  | Ast.Str_lit s -> V_str s
  | Ast.Unit_lit -> V_unit
  | Ast.Var name ->
    (try !(List.assoc name env)
     with Not_found ->
       type_error e.Ast.loc ("unbound variable: " ^ name))
  | Ast.Neg a ->
    (match eval_in env a with
     | V_int x -> V_int (- x)
     | _ -> type_error e.Ast.loc "unary - requires int")
  | Ast.Bin (op, a, b) ->
    let va = eval_in env a in
    let vb = eval_in env b in
    (match op, va, vb with
     | Ast.Add, V_int x, V_int y -> V_int (x + y)
     | Ast.Sub, V_int x, V_int y -> V_int (x - y)
     | Ast.Mul, V_int x, V_int y -> V_int (x * y)
     | Ast.Div, V_int _, V_int 0 ->
       type_error e.Ast.loc "division by zero"
     | Ast.Div, V_int x, V_int y -> V_int (x / y)
     | Ast.Mod, V_int _, V_int 0 ->
       type_error e.Ast.loc "modulo by zero"
     | Ast.Mod, V_int x, V_int y -> V_int (x mod y)
     | Ast.Concat, V_str x, V_str y -> V_str (x ^ y)
     | (Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod), _, _ ->
       type_error e.Ast.loc "arithmetic requires int operands"
     | Ast.Concat, _, _ ->
       type_error e.Ast.loc "++ requires str operands")
  | Ast.Cmp (op, a, b) ->
    (match eval_in env a, eval_in env b with
     | V_int x, V_int y ->
       (match op with
        | Ast.Eq -> V_bool (x = y)
        | Ast.Ne -> V_bool (x <> y)
        | Ast.Lt -> V_bool (x < y)
        | Ast.Le -> V_bool (x <= y)
        | Ast.Gt -> V_bool (x > y)
        | Ast.Ge -> V_bool (x >= y))
     | V_bool x, V_bool y when op = Ast.Eq -> V_bool (x = y)
     | V_bool x, V_bool y when op = Ast.Ne -> V_bool (x <> y)
     | V_str x, V_str y when op = Ast.Eq -> V_bool (x = y)
     | V_str x, V_str y when op = Ast.Ne -> V_bool (x <> y)
     | _ -> type_error e.Ast.loc "comparison type mismatch")
  | Ast.Logic (op, a, b) ->
    (* short-circuit evaluation: don't evaluate b unless needed *)
    (match op, eval_in env a with
     | Ast.And, V_bool false -> V_bool false
     | Ast.Or, V_bool true -> V_bool true
     | (Ast.And | Ast.Or), V_bool _ ->
       (match eval_in env b with
        | V_bool _ as v -> v
        | _ -> type_error e.Ast.loc "logical operator: rhs must be bool")
     | _ ->
       type_error e.Ast.loc "logical operator: lhs must be bool")
  | Ast.Let (pat, value, body) ->
    let v = eval_in env value in
    (match match_pattern pat v with
     | Some bindings ->
       let env' = List.fold_left (fun acc (n, v) -> (n, ref v) :: acc) env bindings in
       eval_in env' body
     | None ->
       type_error e.Ast.loc "let pattern did not match (use irrefutable patterns)")
  | Ast.Let_rec (bindings, body) ->
    (* Mutual recursion: placeholder ref for each name, evaluate each
       value under the env with all placeholders, then backpatch each. *)
    let placeholders = List.map (fun (n, _) -> (n, ref V_unit)) bindings in
    let env' = List.fold_left (fun acc (n, r) -> (n, r) :: acc) env placeholders in
    List.iter (fun (n, value) ->
      let v = eval_in env' value in
      let r = List.assoc n placeholders in
      r := v
    ) bindings;
    eval_in env' body
  | Ast.With (name, value, body) ->
    (* v0: identical to Let in semantics. Q-007 narrowing says scope-bound
       resource cleanup will be added later when we have Drop/destructors. *)
    let v = eval_in env value in
    eval_in ((name, ref v) :: env) body
  | Ast.If (cond, then_, else_) ->
    (match eval_in env cond with
     | V_bool true -> eval_in env then_
     | V_bool false -> eval_in env else_
     | _ -> type_error e.Ast.loc "if condition must be bool")
  | Ast.Fun (param, _ty_opt, body) ->
    V_closure (param, body, env)
  | Ast.App (f, arg) ->
    (match eval_in env f with
     | V_closure (param, body, captured) ->
       let v = eval_in env arg in
       eval_in ((param, ref v) :: captured) body
     | V_builtin (_, fn) ->
       let v = eval_in env arg in
       fn v
     | _ -> type_error e.Ast.loc "applying non-function")
  | Ast.Annot (inner, _) -> eval_in env inner
  | Ast.Constr (name, None) -> V_constr (name, None)
  | Ast.Constr (name, Some arg) ->
    let v = eval_in env arg in
    V_constr (name, Some v)
  | Ast.Match (scrut, arms) ->
    let v = eval_in env scrut in
    let rec try_arms = function
      | [] -> type_error e.Ast.loc "no matching arm in match"
      | (p, guard, body) :: rest ->
        (match match_pattern p v with
         | Some bindings ->
           let env' = List.fold_left (fun acc (n, v) -> (n, ref v) :: acc) env bindings in
           let g_ok = match guard with
             | None -> true
             | Some g ->
               (match eval_in env' g with
                | V_bool b -> b
                | _ -> type_error g.Ast.loc "match guard must be bool")
           in
           if g_ok then eval_in env' body
           else try_arms rest
         | None -> try_arms rest)
    in
    try_arms arms
  | Ast.Tuple es ->
    V_tuple (List.map (eval_in env) es)
  | Ast.Record_lit (name, fields) ->
    V_record (name, List.map (fun (f, e) -> (f, eval_in env e)) fields)
  | Ast.Field_get (inner, fname) ->
    (match eval_in env inner with
     | V_record (_, fields) ->
       (try List.assoc fname fields
        with Not_found ->
          type_error e.Ast.loc ("record has no field " ^ fname))
     | _ -> type_error e.Ast.loc "field access on non-record value")
  | Ast.Record_update (base, updates) ->
    (match eval_in env base with
     | V_record (name, base_fields) ->
       (* Replace matching fields, preserve order of declared fields. *)
       let new_fields = List.map (fun (fname, fval) ->
         match List.assoc_opt fname updates with
         | Some upd_expr -> (fname, eval_in env upd_expr)
         | None -> (fname, fval)
       ) base_fields in
       V_record (name, new_fields)
     | _ -> type_error e.Ast.loc "record update on non-record value")

let eval expr = eval_in initial_env expr
