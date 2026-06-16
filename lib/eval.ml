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

let builtin_bool_of_str =
  V_builtin ("bool_of_str", fun v ->
    match v with
    | V_str s ->
      (match String.trim s with
       | "true" -> V_bool true
       | "false" -> V_bool false
       | _ ->
         raise (Eval_error (Loc.dummy,
           Printf.sprintf "bool_of_str: %S is not 'true' or 'false'" s)))
    | _ -> failwith "bool_of_str: expected str")

let builtin_str_compare =
  V_builtin ("str_compare", fun a ->
    match a with
    | V_str x ->
      V_builtin ("str_compare_partial", fun b ->
        match b with
        | V_str y ->
          let c = String.compare x y in
          V_int (if c < 0 then -1 else if c > 0 then 1 else 0)
        | _ -> failwith "str_compare: 2nd arg expected str")
    | _ -> failwith "str_compare: 1st arg expected str")

let builtin_str_contains =
  V_builtin ("str_contains", fun haystack ->
    match haystack with
    | V_str h ->
      V_builtin ("str_contains_partial", fun needle ->
        match needle with
        | V_str n ->
          let h_len = String.length h in
          let n_len = String.length n in
          let rec scan i =
            if n_len = 0 then true
            else if i + n_len > h_len then false
            else if String.sub h i n_len = n then true
            else scan (i + 1)
          in
          V_bool (scan 0)
        | _ -> failwith "str_contains: 2nd arg expected str")
    | _ -> failwith "str_contains: 1st arg expected str")

let builtin_min =
  V_builtin ("min", fun a ->
    match a with
    | V_int x ->
      V_builtin ("min_partial", fun b ->
        match b with
        | V_int y -> V_int (if x < y then x else y)
        | _ -> failwith "min: 2nd arg expected int")
    | _ -> failwith "min: 1st arg expected int")

let builtin_max =
  V_builtin ("max", fun a ->
    match a with
    | V_int x ->
      V_builtin ("max_partial", fun b ->
        match b with
        | V_int y -> V_int (if x > y then x else y)
        | _ -> failwith "max: 2nd arg expected int")
    | _ -> failwith "max: 1st arg expected int")

let builtin_abs =
  V_builtin ("abs", fun v ->
    match v with
    | V_int n -> V_int (if n < 0 then -n else n)
    | _ -> failwith "abs: expected int")

let builtin_even =
  V_builtin ("even", fun v ->
    match v with
    | V_int n -> V_bool (n mod 2 = 0)
    | _ -> failwith "even: expected int")

let builtin_odd =
  V_builtin ("odd", fun v ->
    match v with
    | V_int n -> V_bool (n mod 2 <> 0)
    | _ -> failwith "odd: expected int")

let builtin_sign =
  V_builtin ("sign", fun v ->
    match v with
    | V_int n -> V_int (if n > 0 then 1 else if n < 0 then -1 else 0)
    | _ -> failwith "sign: expected int")

let builtin_clamp =
  V_builtin ("clamp", fun lo_val ->
    match lo_val with
    | V_int lo ->
      V_builtin ("clamp_p1", fun hi_val ->
        match hi_val with
        | V_int hi ->
          V_builtin ("clamp_p2", fun x_val ->
            match x_val with
            | V_int x ->
              if x < lo then V_int lo
              else if x > hi then V_int hi
              else V_int x
            | _ -> failwith "clamp: 3rd arg expected int")
        | _ -> failwith "clamp: 2nd arg expected int")
    | _ -> failwith "clamp: 1st arg expected int")

let builtin_gcd =
  V_builtin ("gcd", fun a ->
    match a with
    | V_int x ->
      V_builtin ("gcd_partial", fun b ->
        match b with
        | V_int y ->
          let rec euclid a b =
            if b = 0 then a
            else euclid b (a mod b)
          in
          V_int (euclid (abs x) (abs y))
        | _ -> failwith "gcd: 2nd arg expected int")
    | _ -> failwith "gcd: 1st arg expected int")

let builtin_lcm =
  V_builtin ("lcm", fun a ->
    match a with
    | V_int x ->
      V_builtin ("lcm_partial", fun b ->
        match b with
        | V_int y ->
          if x = 0 || y = 0 then V_int 0
          else
            let rec euclid a b =
              if b = 0 then a
              else euclid b (a mod b)
            in
            let g = euclid (abs x) (abs y) in
            V_int (abs (x / g * y))
        | _ -> failwith "lcm: 2nd arg expected int")
    | _ -> failwith "lcm: 1st arg expected int")

let builtin_pow =
  V_builtin ("pow", fun base ->
    match base with
    | V_int b ->
      V_builtin ("pow_partial", fun exp ->
        match exp with
        | V_int e when e < 0 ->
          raise (Eval_error (Loc.dummy,
            Printf.sprintf "pow: negative exponent %d" e))
        | V_int e ->
          (* iterative integer exponentiation *)
          let rec loop acc base exp =
            if exp = 0 then acc
            else if exp mod 2 = 1 then loop (acc * base) (base * base) (exp / 2)
            else loop acc (base * base) (exp / 2)
          in
          V_int (loop 1 b e)
        | _ -> failwith "pow: 2nd arg expected int")
    | _ -> failwith "pow: 1st arg expected int")

let builtin_fail =
  V_builtin ("fail", fun v ->
    match v with
    | V_str msg -> raise (Eval_error (Loc.dummy, "fail: " ^ msg))
    | _ -> failwith "fail: expected str")

let builtin_show =
  V_builtin ("show", fun v -> V_str (to_string v))

let builtin_fst =
  V_builtin ("fst", fun v ->
    match v with
    | V_tuple [a; _] -> a
    | _ -> failwith "fst: expected 2-tuple")

let builtin_snd =
  V_builtin ("snd", fun v ->
    match v with
    | V_tuple [_; b] -> b
    | _ -> failwith "snd: expected 2-tuple")

let builtin_id =
  V_builtin ("id", fun v -> v)

let builtin_swap =
  V_builtin ("swap", fun v ->
    match v with
    | V_tuple [a; b] -> V_tuple [b; a]
    | _ -> failwith "swap: expected 2-tuple")

let builtin_pair =
  V_builtin ("pair", fun a ->
    V_builtin ("pair_partial", fun b -> V_tuple [a; b]))

let builtin_const =
  V_builtin ("const", fun a ->
    V_builtin ("const_partial", fun _b -> a))

(* Forward-reference into eval_in's apply machinery so higher-order builtins
   like `flip` can call user functions (V_closure / V_builtin) at runtime.
   Patched at the bottom of this file, after eval_in is defined. *)
let apply_value_ref : (value -> value -> value) ref =
  ref (fun _ _ -> failwith "apply_value_ref: not initialized (BUG)")

let builtin_flip =
  V_builtin ("flip", fun f ->
    V_builtin ("flip_p1", fun b ->
      V_builtin ("flip_p2", fun a ->
        (* flip f b a = (f a) b *)
        let f_a = !apply_value_ref f a in
        !apply_value_ref f_a b)))

let builtin_try_or =
  V_builtin ("try_or", fun f ->
    V_builtin ("try_or_partial", fun default ->
      try !apply_value_ref f V_unit
      with Eval_error _ -> default))

let builtin_assert =
  V_builtin ("assert", fun cond ->
    match cond with
    | V_bool b ->
      V_builtin ("assert_partial", fun msg ->
        match msg with
        | V_str m ->
          if b then V_unit
          else raise (Eval_error (Loc.dummy, "assertion failed: " ^ m))
        | _ -> failwith "assert: 2nd arg expected str")
    | _ -> failwith "assert: 1st arg expected bool")

let builtin_str_starts_with =
  V_builtin ("str_starts_with", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("str_starts_with_partial", fun p_val ->
        match p_val with
        | V_str p ->
          let s_len = String.length s in
          let p_len = String.length p in
          V_bool (p_len <= s_len && String.sub s 0 p_len = p)
        | _ -> failwith "str_starts_with: 2nd arg expected str")
    | _ -> failwith "str_starts_with: 1st arg expected str")

let builtin_str_replace =
  V_builtin ("str_replace", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("str_replace_p1", fun old_val ->
        match old_val with
        | V_str old_str ->
          V_builtin ("str_replace_p2", fun new_val ->
            match new_val with
            | V_str new_str ->
              if old_str = "" then V_str s
              else begin
                let old_len = String.length old_str in
                let s_len = String.length s in
                let buf = Buffer.create s_len in
                let rec loop i =
                  if i + old_len > s_len then
                    Buffer.add_substring buf s i (s_len - i)
                  else if String.sub s i old_len = old_str then begin
                    Buffer.add_string buf new_str;
                    loop (i + old_len)
                  end else begin
                    Buffer.add_char buf s.[i];
                    loop (i + 1)
                  end
                in
                loop 0;
                V_str (Buffer.contents buf)
              end
            | _ -> failwith "str_replace: 3rd arg expected str")
        | _ -> failwith "str_replace: 2nd arg expected str")
    | _ -> failwith "str_replace: 1st arg expected str")

let builtin_substring =
  V_builtin ("substring", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("substring_p1", fun start_val ->
        match start_val with
        | V_int start ->
          V_builtin ("substring_p2", fun end_val ->
            match end_val with
            | V_int end_ ->
              let len = String.length s in
              if start < 0 || end_ > len || start > end_ then
                raise (Eval_error (Loc.dummy,
                  Printf.sprintf
                    "substring: range [%d, %d) invalid for str of length %d"
                    start end_ len))
              else V_str (String.sub s start (end_ - start))
            | _ -> failwith "substring: 3rd arg expected int")
        | _ -> failwith "substring: 2nd arg expected int")
    | _ -> failwith "substring: 1st arg expected str")

let builtin_str_repeat =
  V_builtin ("str_repeat", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("str_repeat_partial", fun n_val ->
        match n_val with
        | V_int n when n < 0 ->
          raise (Eval_error (Loc.dummy,
            Printf.sprintf "str_repeat: negative count %d" n))
        | V_int 0 -> V_str ""
        | V_int n ->
          let buf = Buffer.create (String.length s * n) in
          for _ = 1 to n do Buffer.add_string buf s done;
          V_str (Buffer.contents buf)
        | _ -> failwith "str_repeat: 2nd arg expected int")
    | _ -> failwith "str_repeat: 1st arg expected str")

let builtin_str_ends_with =
  V_builtin ("str_ends_with", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("str_ends_with_partial", fun p_val ->
        match p_val with
        | V_str p ->
          let s_len = String.length s in
          let p_len = String.length p in
          V_bool (p_len <= s_len && String.sub s (s_len - p_len) p_len = p)
        | _ -> failwith "str_ends_with: 2nd arg expected str")
    | _ -> failwith "str_ends_with: 1st arg expected str")

let builtin_str_trim =
  V_builtin ("str_trim", fun v ->
    match v with
    | V_str s -> V_str (String.trim s)
    | _ -> failwith "str_trim: expected str")

let builtin_is_digit =
  V_builtin ("is_digit", fun v ->
    match v with
    | V_str s when String.length s = 1 ->
      let c = s.[0] in
      V_bool (c >= '0' && c <= '9')
    | V_str _ -> V_bool false
    | _ -> failwith "is_digit: expected str")

let builtin_is_alpha =
  V_builtin ("is_alpha", fun v ->
    match v with
    | V_str s when String.length s = 1 ->
      let c = s.[0] in
      V_bool ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
    | V_str _ -> V_bool false
    | _ -> failwith "is_alpha: expected str")

let builtin_is_space =
  V_builtin ("is_space", fun v ->
    match v with
    | V_str s when String.length s = 1 ->
      let c = s.[0] in
      V_bool (c = ' ' || c = '\t' || c = '\n' || c = '\r')
    | V_str _ -> V_bool false
    | _ -> failwith "is_space: expected str")

let builtin_str_rev =
  V_builtin ("str_rev", fun v ->
    match v with
    | V_str s ->
      let n = String.length s in
      V_str (String.init n (fun i -> s.[n - 1 - i]))
    | _ -> failwith "str_rev: expected str")

let builtin_to_upper =
  V_builtin ("to_upper", fun v ->
    match v with
    | V_str s -> V_str (String.uppercase_ascii s)
    | _ -> failwith "to_upper: expected str")

let builtin_to_lower =
  V_builtin ("to_lower", fun v ->
    match v with
    | V_str s -> V_str (String.lowercase_ascii s)
    | _ -> failwith "to_lower: expected str")

let builtin_chr =
  V_builtin ("chr", fun v ->
    match v with
    | V_int n ->
      if n < 0 || n > 255 then
        raise (Eval_error (Loc.dummy,
          Printf.sprintf "chr: %d out of byte range [0, 255]" n))
      else V_str (String.make 1 (Char.chr n))
    | _ -> failwith "chr: expected int")

let builtin_ord =
  V_builtin ("ord", fun v ->
    match v with
    | V_str s ->
      if String.length s <> 1 then
        raise (Eval_error (Loc.dummy,
          Printf.sprintf "ord: expected single-char str, got length %d"
            (String.length s)))
      else V_int (Char.code s.[0])
    | _ -> failwith "ord: expected str")

let builtin_char_at =
  V_builtin ("char_at", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("char_at_partial", fun i_val ->
        match i_val with
        | V_int i ->
          if i < 0 || i >= String.length s then
            raise (Eval_error (Loc.dummy,
              Printf.sprintf "char_at: index %d out of range (len=%d)"
                i (String.length s)))
          else V_str (String.sub s i 1)
        | _ -> failwith "char_at: 2nd arg expected int")
    | _ -> failwith "char_at: 1st arg expected str")

let initial_env : env =
  [ ("print", ref builtin_print);
    ("print_int", ref builtin_print_int);
    ("print_bool", ref builtin_print_bool);
    ("str_of_int", ref builtin_str_of_int);
    ("not", ref builtin_not);
    ("str_len", ref builtin_str_len);
    ("int_of_str", ref builtin_int_of_str);
    ("bool_of_str", ref builtin_bool_of_str);
    ("str_contains", ref builtin_str_contains);
    ("str_compare", ref builtin_str_compare);
    ("str_starts_with", ref builtin_str_starts_with);
    ("str_ends_with", ref builtin_str_ends_with);
    ("str_repeat", ref builtin_str_repeat);
    ("substring", ref builtin_substring);
    ("str_replace", ref builtin_str_replace);
    ("char_at", ref builtin_char_at);
    ("chr", ref builtin_chr);
    ("ord", ref builtin_ord);
    ("to_upper", ref builtin_to_upper);
    ("to_lower", ref builtin_to_lower);
    ("str_trim", ref builtin_str_trim);
    ("str_rev", ref builtin_str_rev);
    ("is_digit", ref builtin_is_digit);
    ("is_alpha", ref builtin_is_alpha);
    ("is_space", ref builtin_is_space);
    ("fail", ref builtin_fail);
    ("min", ref builtin_min);
    ("max", ref builtin_max);
    ("abs", ref builtin_abs);
    ("even", ref builtin_even);
    ("odd", ref builtin_odd);
    ("sign", ref builtin_sign);
    ("clamp", ref builtin_clamp);
    ("pow", ref builtin_pow);
    ("gcd", ref builtin_gcd);
    ("lcm", ref builtin_lcm);
    ("assert", ref builtin_assert);
    ("show", ref builtin_show);
    ("fst", ref builtin_fst);
    ("snd", ref builtin_snd);
    ("id", ref builtin_id);
    ("swap", ref builtin_swap);
    ("pair", ref builtin_pair);
    ("const", ref builtin_const);
    ("flip", ref builtin_flip);
    ("try_or", ref builtin_try_or);
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
  | Ast.P_as (inner, name), v ->
    (* Match inner pattern + bind the whole value to `name`. *)
    (match match_pattern inner v with
     | None -> None
     | Some bs -> Some ((name, v) :: bs))
  | Ast.P_or (p1, p2), v ->
    (* Try the left branch first; on failure try the right. *)
    (match match_pattern p1 v with
     | Some bs -> Some bs
     | None -> match_pattern p2 v)
  | _ -> None

(* Structural equality for `==` / `!=`.  Recurses through tuples, records,
   and constructors.  Functions (closures/builtins) are not comparable —
   raise Eval_error since we cannot meaningfully equate them. *)
let rec value_eq a b =
  match a, b with
  | V_int x, V_int y -> x = y
  | V_bool x, V_bool y -> x = y
  | V_str x, V_str y -> x = y
  | V_unit, V_unit -> true
  | V_tuple xs, V_tuple ys when List.length xs = List.length ys ->
    List.for_all2 value_eq xs ys
  | V_constr (n1, None), V_constr (n2, None) -> n1 = n2
  | V_constr (n1, Some v1), V_constr (n2, Some v2) -> n1 = n2 && value_eq v1 v2
  | V_constr _, V_constr _ -> false
  | V_record (n1, fs1), V_record (n2, fs2) when n1 = n2 ->
    (try List.for_all (fun (f, v1) ->
       value_eq v1 (List.assoc f fs2)
     ) fs1
     with Not_found -> false)
  | (V_closure _ | V_builtin _), _
  | _, (V_closure _ | V_builtin _) ->
    raise (Eval_error (Loc.dummy, "functions are not comparable with == / !="))
  | _ -> false

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
    let va = eval_in env a in
    let vb = eval_in env b in
    (match op, va, vb with
     | Ast.Lt, V_int x, V_int y -> V_bool (x < y)
     | Ast.Le, V_int x, V_int y -> V_bool (x <= y)
     | Ast.Gt, V_int x, V_int y -> V_bool (x > y)
     | Ast.Ge, V_int x, V_int y -> V_bool (x >= y)
     | (Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge), _, _ ->
       type_error e.Ast.loc "ordering requires int operands"
     | Ast.Eq, _, _ -> V_bool (value_eq va vb)
     | Ast.Ne, _, _ -> V_bool (not (value_eq va vb)))
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

(* Patch apply_value_ref now that eval_in is bound, so higher-order builtins
   (`flip` and friends) can call into the evaluator at runtime. *)
let () =
  apply_value_ref := (fun f arg ->
    match f with
    | V_closure (param, body, captured) ->
      eval_in ((param, ref arg) :: captured) body
    | V_builtin (_, fn) -> fn arg
    | _ -> failwith "apply_value: not a function")
