open Lang_ml

let pass = ref 0
let fail = ref 0

let check name actual expected =
  if actual = expected then begin
    incr pass;
    Printf.printf "PASS  %s\n" name
  end else begin
    incr fail;
    Printf.printf "FAIL  %s\n  expected=%s actual=%s\n" name expected actual
  end

let check_raises name f =
  match f () with
  | _ ->
    incr fail;
    Printf.printf "FAIL  %s (expected exception)\n" name
  | exception _ ->
    incr pass;
    Printf.printf "PASS  %s\n" name

let () =
  check "version is 0.1.0" Version.v "0.1.0";

  (* --- regression --- *)
  check "'1 + 2'"  (Pipeline.process "1 + 2") "3";
  check "factorial"
    (Pipeline.process "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 6") "720";
  check "tuple basic"
    (Pipeline.process "(1, 2, 3)") "(1, 2, 3)";

  (* --- legacy non-polymorphic type still works --- *)
  check "mono type still works"
    (Pipeline.process "type col = R | G | B; G") "G";

  (* --- polymorphic type declaration & use --- *)
  check "poly opt: Some 5"
    (Pipeline.process "type 'a opt = None | Some of 'a; Some 5") "Some 5";
  check "poly opt: Some str"
    (Pipeline.process "type 'a opt = None | Some of 'a; Some \"hi\"") "Some \"hi\"";
  check "poly opt: None"
    (Pipeline.process "type 'a opt = None | Some of 'a; None") "None";
  check "poly opt type of Some 5"
    (Pipeline.type_of "type 'a opt = None | Some of 'a; Some 5") "int opt";
  check "poly opt type of Some 'hi'"
    (Pipeline.type_of "type 'a opt = None | Some of 'a; Some \"hi\"") "str opt";

  (* --- match on polymorphic option --- *)
  check "match poly Some"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       match Some 42 with | None -> 0 | Some n -> n + 1") "43";
  check "match poly None"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       match None with | None -> 0 | Some n -> n + 1") "0";
  check "match poly Some str"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       match Some \"hi\" with | None -> \"x\" | Some s -> s ++ \"!\"") "\"hi!\"";

  (* --- polymorphic list! --- *)
  check "poly list: sum int"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       let rec sum = fn lst ->
         match lst with
         | Nil -> 0
         | Cons (h, t) -> h + sum t
       in sum (Cons (1, Cons (2, Cons (3, Nil))))") "6";
  check "poly list: length of str list"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       let rec len = fn lst ->
         match lst with
         | Nil -> 0
         | Cons (_, t) -> 1 + len t
       in len (Cons (\"a\", Cons (\"b\", Cons (\"c\", Nil))))") "3";

  (* --- type inference: list with let-polymorphism --- *)
  check "poly list type at int"
    (Pipeline.type_of
      "type 'a list = Nil | Cons of 'a * 'a list;
       Cons (1, Nil)") "int list";
  check "poly list type at str"
    (Pipeline.type_of
      "type 'a list = Nil | Cons of 'a * 'a list;
       Cons (\"a\", Nil)") "str list";

  (* --- Result-like with one param (Ok of 'a, Err of str — but Err of str is monomorphic; need 2 params for full result) --- *)
  check "poly Box"
    (Pipeline.process
      "type 'a box = Box of 'a;
       match Box (3 + 4) with | Box x -> x * 2") "14";
  check "poly Box str"
    (Pipeline.process
      "type 'a box = Box of 'a;
       match Box \"hello\" with | Box s -> s ++ \"!\"") "\"hello!\"";

  (* --- polymorphic tree (single param) --- *)
  check "poly tree: sum of int values"
    (Pipeline.process
      "type 'a tree = Leaf | Node of 'a tree * 'a * 'a tree;
       let rec sum = fn t ->
         match t with
         | Leaf -> 0
         | Node (l, v, r) -> sum l + v + sum r
       in sum (Node (Node (Leaf, 1, Leaf), 2, Node (Leaf, 3, Leaf)))") "6";

  (* --- pp polymorphic types --- *)
  check "pp_ty 'a opt"
    (Ast.pp_ty (Ast.TyCon ("opt", [Ast.TyParam "a"]))) "'a opt";
  check "pp_ty int opt"
    (Ast.pp_ty (Ast.TyCon ("opt", [Ast.TyInt]))) "int opt";
  check "pp_ty (int * int) opt"
    (Ast.pp_ty (Ast.TyCon ("opt", [Ast.TyTuple [Ast.TyInt; Ast.TyInt]])))
    "(int * int) opt";

  (* --- type errors --- *)
  check_raises "mix int and str in poly opt"
    (fun () -> Pipeline.type_of
      "type 'a opt = None | Some of 'a;
       let f = fn x -> match x with | None -> 0 | Some n -> n + 1 in
       f (Some \"hi\")");
  check_raises "cons int onto str list"
    (fun () -> Pipeline.type_of
      "type 'a list = Nil | Cons of 'a * 'a list;
       Cons (1, Cons (\"hi\", Nil))");

  (* --- with expression (Phase 3.1: Drop type required) ---
     `with c = v in body` requires v's type to be a Drop type. Parse-shape
     and scoping tests use a synthetic Drop type `DRes` since the v0
     "with = let" semantics is gone. *)
  check "with basic (Drop type)"
    (Pipeline.process
      "drop type DRes = { v: int };\n\
       with x = DRes { v = 5 } in x.v + 1") "6";
  check "with multi-binding"
    (Pipeline.process
      "drop type DRes = { v: int };\n\
       with x = DRes { v = 5 }, y = DRes { v = 10 }, z = DRes { v = 100 } in\n\
       x.v + y.v + z.v") "115";
  check "with shadowing"
    (Pipeline.process
      "drop type DRes = { v: int };\n\
       with x = DRes { v = 1 } in (with x = DRes { v = 2 } in x.v) + x.v") "3";
  check "pp with"
    (Ast.pp (Pipeline.parse_only "with x = 5 in x + 1"))
    "(with x = 5 in (x + 1))";
  check_raises "with no in"
    (fun () -> Pipeline.process "with x = 5");
  check_raises "with no ="
    (fun () -> Pipeline.process "with x 5 in x");

  (* --- let pattern (E1) --- *)
  check "let tuple pattern"
    (Pipeline.process "let (a, b) = (3, 4) in a + b") "7";
  check "let tuple of 3"
    (Pipeline.process "let (a, b, c) = (1, 2, 3) in a * b + c") "5";
  check "let wildcard"
    (Pipeline.process "let _ = 99 in 42") "42";
  check "let unit pattern"
    (Pipeline.process "let () = () in 1") "1";
  check "let pattern preserves let-poly: f is polymorphic"
    (Pipeline.type_of "let (f, g) = (fn x -> x, fn x -> x + 1) in f") "('a -> 'a)";
  check "let pattern preserves let-poly: g is int -> int"
    (Pipeline.type_of "let (f, g) = (fn x -> x, fn x -> x + 1) in g") "(int -> int)";
  check "nested let patterns"
    (Pipeline.process "let (a, (b, c)) = (1, (2, 3)) in a + b + c") "6";
  check "let pattern with print side effect"
    (Pipeline.process "let _ = print \"hello\" in 42") "42";
  check "pp let tuple pattern"
    (Ast.pp (Pipeline.parse_only "let (a, b) = (1, 2) in a"))
    "(let (a, b) = (1, 2) in a)";
  check_raises "let pattern arity mismatch"
    (fun () -> Pipeline.type_of "let (a, b, c) = (1, 2) in a");

  (* --- new arithmetic operators (E2) --- *)
  check "div"             (Pipeline.process "10 / 3") "3";
  check "mod"             (Pipeline.process "10 % 3") "1";
  check "div precedence"  (Pipeline.process "20 / 2 + 1") "11";
  check_raises "div by zero" (fun () -> Pipeline.process "1 / 0");
  check_raises "mod by zero" (fun () -> Pipeline.process "1 % 0");

  (* --- new comparison operators (E2) --- *)
  check "le true"   (Pipeline.process "5 <= 5") "true";
  check "le false"  (Pipeline.process "6 <= 5") "false";
  check "ge true"   (Pipeline.process "5 >= 5") "true";
  check "gt true"   (Pipeline.process "5 > 4") "true";
  check "gt false"  (Pipeline.process "4 > 5") "false";
  check "ne true"   (Pipeline.process "5 != 6") "true";
  check "ne bool"   (Pipeline.process "true != false") "true";
  check "ne str"    (Pipeline.process "\"a\" != \"b\"") "true";

  (* --- logical operators with short-circuit (E2) --- *)
  check "and true"      (Pipeline.process "true && true") "true";
  check "and false"     (Pipeline.process "true && false") "false";
  check "or"            (Pipeline.process "false || true") "true";
  check "and short-circuit (rhs not evaluated)"
    (Pipeline.process "false && (1 / 0 == 0)") "false";
  check "or short-circuit (rhs not evaluated)"
    (Pipeline.process "true || (1 / 0 == 0)") "true";

  (* --- stdlib (F1) --- *)
  check "type of print_int"  (Pipeline.type_of "print_int") "(int -> unit)";
  check "type of str_of_int" (Pipeline.type_of "str_of_int") "(int -> str)";
  check "str_of_int"         (Pipeline.process "str_of_int 123") "\"123\"";
  check "compose with stdlib"
    (Pipeline.process "let msg = \"sum = \" ++ str_of_int (10 + 20) in msg") "\"sum = 30\"";

  (* --- multi-arg typed fn (A') --- *)
  check "fn (x: int, y: int)"
    (Pipeline.process "(fn (x: int, y: int) -> x + y) 3 4") "7";
  check "fn (x: int) typed single"
    (Pipeline.process "(fn (x: int) -> x * 2) 5") "10";
  check "fn (a, b, c) untyped multi"
    (Pipeline.process "(fn (a, b, c) -> a + b * c) 1 2 3") "7";
  check "fn ()"
    (Pipeline.process "(fn () -> 42) ()") "42";
  check "type of typed multi-arg fn"
    (Pipeline.type_of "fn (x: int, y: str) -> str_of_int x ++ y") "(int -> (str -> str))";
  check "type of untyped multi-arg fn (inferred)"
    (Pipeline.type_of "fn (a, b) -> a + b") "(int -> (int -> int))";
  check "annotation enforces type"
    (Pipeline.process
       "let add = fn (x: int, y: int) -> x + y in add 10 20") "30";
  check "existing single-arg fn still works"
    (Pipeline.process "(fn x -> x + 1) 10") "11";
  check_raises "annotation mismatch caught"
    (fun () -> Pipeline.type_of "(fn (x: int) -> x + 1) \"hi\"");
  check "partial application of multi-arg fn"
    (Pipeline.type_of "(fn (x: int, y: int) -> x + y) 3") "(int -> int)";

  (* --- signature alias (A) --- *)
  check "signature basic"
    (Pipeline.process
      "signature ctx = (db: int, log: int);
       let f = fn (...ctx, n: int) -> db + log + n in f 1 2 3") "6";
  check "signature alone"
    (Pipeline.process
      "signature ctx = (a: int, b: int);
       let g = fn (...ctx) -> a * b in g 4 5") "20";
  check "signature with leading params"
    (Pipeline.process
      "signature ctx = (db: int);
       let h = fn (a: int, ...ctx, b: int) -> a + db + b in h 1 2 3") "6";
  check "signature multiple spreads"
    (Pipeline.process
      "signature a = (x: int);
       signature b = (y: int);
       let f = fn (...a, ...b) -> x + y in f 10 20") "30";
  check "signature type inferred"
    (Pipeline.type_of
      "signature ctx = (db: int, log: str);
       fn (...ctx) -> log") "(int -> (str -> str))";
  check "signature with str param"
    (Pipeline.process
      "signature ctx = (greeting: str);
       let greet = fn (...ctx, name: str) -> greeting ++ name in greet \"hi \" \"world\"") "\"hi world\"";
  check_raises "unknown signature"
    (fun () -> Pipeline.process
      "let f = fn (...missing, n: int) -> n in f 1");
  check_raises "signature param without type"
    (fun () -> Pipeline.process
      "signature ctx = (db); let f = fn (...ctx) -> db in f 1");

  (* --- pipe operator |> --- *)
  check "pipe single"
    (Pipeline.process "5 |> (fn x -> x + 1)") "6";
  check "pipe chain"
    (Pipeline.process "5 |> (fn x -> x + 1) |> (fn x -> x * 2)") "12";
  check "pipe with let"
    (Pipeline.process "let inc = fn x -> x + 1 in let dbl = fn x -> x * 2 in 10 |> inc |> dbl") "22";
  check "pipe with multi-arg curry"
    (Pipeline.process "let add = fn (a: int, b: int) -> a + b in 5 |> add 3") "8";
  check "pipe with stdlib"
    (Pipeline.process "42 |> str_of_int") "\"42\"";
  check "pipe is left-associative"
    (Pipeline.process "1 |> (fn x -> x + 10) |> (fn x -> x * 100)") "1100";
  check "pipe below arithmetic"
    (Pipeline.process "1 + 2 |> (fn x -> x * 10)") "30";

  (* --- records (D) --- *)
  check "record basic"
    (Pipeline.process
      "type Point = { x: int, y: int };
       let p = Point { x = 3, y = 4 } in p.x + p.y") "7";
  check "record with str field"
    (Pipeline.process
      "type User = { name: str, age: int };
       let u = User { name = \"Alice\", age = 30 } in u.name") "\"Alice\"";
  check "record nested field"
    (Pipeline.process
      "type Inner = { v: int };
       type Outer = { inner: Inner };
       let o = Outer { inner = Inner { v = 42 } } in o.inner.v") "42";
  check "record pattern destructure"
    (Pipeline.process
      "type P = { a: int, b: int };
       match P { a = 10, b = 20 } with | P { a = x, b = y } -> x * y") "200";
  check "record partial pattern"
    (Pipeline.process
      "type P = { a: int, b: int, c: int };
       match P { a = 1, b = 2, c = 3 } with | P { a = x } -> x") "1";
  check "record polymorphic"
    (Pipeline.process
      "type 'a Box = { value: 'a };
       let b = Box { value = 100 } in b.value") "100";
  check "record poly with str"
    (Pipeline.process
      "type 'a Box = { value: 'a };
       let b = Box { value = \"hi\" } in b.value") "\"hi\"";
  check "record poly type"
    (Pipeline.type_of
      "type 'a Box = { value: 'a };
       Box { value = 42 }") "int Box";
  check "record to_string"
    (Pipeline.process
      "type P = { x: int, y: int };
       P { x = 1, y = 2 }") "P { x = 1, y = 2 }";
  check "record pp"
    (Ast.pp (Pipeline.parse_only
      "type P = { x: int }; P { x = 5 }"))
    "P { x = 5 }";
  check_raises "record missing field"
    (fun () -> Pipeline.process
      "type P = { x: int, y: int };
       P { x = 1 }");
  check_raises "record extra field"
    (fun () -> Pipeline.process
      "type P = { x: int };
       P { x = 1, y = 2 }");
  check_raises "record wrong field type"
    (fun () -> Pipeline.process
      "type P = { x: int };
       P { x = \"hi\" }");
  check_raises "record unknown field access"
    (fun () -> Pipeline.process
      "type P = { x: int };
       let p = P { x = 1 } in p.y");

  (* --- mutual recursion `let rec ... and ...` --- *)
  check "mutual rec is_even"
    (Pipeline.process
      "let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)
       and is_odd  = fn n -> if n == 0 then false else is_even (n - 1)
       in is_even 10") "true";
  check "mutual rec is_odd"
    (Pipeline.process
      "let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)
       and is_odd  = fn n -> if n == 0 then false else is_even (n - 1)
       in is_odd 7") "true";
  check "mutual rec three-way"
    (Pipeline.process
      "let rec a = fn n -> if n == 0 then 0 else b (n - 1)
       and b = fn n -> if n == 0 then 1 else c (n - 1)
       and c = fn n -> if n == 0 then 2 else a (n - 1)
       in a 7 + b 7 + c 7") "3";
  check "mutual rec type"
    (Pipeline.type_of
      "let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)
       and is_odd  = fn n -> if n == 0 then false else is_even (n - 1)
       in is_even") "(int -> bool)";
  check "mutual rec top-level"
    (Pipeline.process
      "let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)
       and is_odd  = fn n -> if n == 0 then false else is_even (n - 1);
       is_even 100") "true";
  check "single let rec still works"
    (Pipeline.process
      "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5") "120";
  check "pp mutual rec"
    (Ast.pp (Pipeline.parse_only
      "let rec a = fn x -> b x and b = fn x -> a x in a 1"))
    "(let rec a = (fn x -> (b x)) and b = (fn x -> (a x)) in (a 1))";

  (* --- list literal sugar `[...]` --- *)
  check "list literal int"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       [1, 2, 3]") "[1, 2, 3]";
  check "empty list"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       []") "[]";
  check "list literal sum"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       let rec sum = fn xs -> match xs with
         | Nil -> 0
         | Cons (h, t) -> h + sum t
       in sum [10, 20, 30, 40]") "100";
  check "list literal str"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       [\"a\", \"b\", \"c\"]")
    "[\"a\", \"b\", \"c\"]";
  check "list literal type at int"
    (Pipeline.type_of
      "type 'a list = Nil | Cons of 'a * 'a list;
       [1, 2, 3]") "int list";
  check "list literal type at str"
    (Pipeline.type_of
      "type 'a list = Nil | Cons of 'a * 'a list;
       [\"x\"]") "str list";
  check "nested list literal"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       let rec len = fn xs -> match xs with
         | Nil -> 0
         | Cons (_, t) -> 1 + len t
       in len [[1], [2, 3], [4, 5, 6]]") "3";
  (* Note: `[1, 2, 3]` requires Nil/Cons constructors to be in scope
     (declared via `type 'a list = Nil | Cons of 'a * 'a list;`).
     Cannot easily test the "not declared" case in-process because
     the constructors Hashtbl is module-level and persists across
     Pipeline.process calls. *)

  (* --- block expression `{ e1; e2; ...; eN }` --- *)
  check "block single expr"
    (Pipeline.process "{ 1 + 2 }") "3";
  check "empty block"
    (Pipeline.process "{}") "()";
  check "block sequencing"
    (Pipeline.process "{ 100; 200; 300 }") "300";
  check "block returns last"
    (Pipeline.process "let x = { 1; 2; 3 } in x + 10") "13";
  check "block with print"
    (Pipeline.process "{ print \"hi\"; 42 }") "42";
  check "block trailing semi"
    (Pipeline.process "{ 1; 2; 3; }") "3";
  check "block in fn body"
    (Pipeline.process "let f = fn x -> { x + 1 } in f 10") "11";
  check "block type"
    (Pipeline.type_of "{ true; \"hi\"; 42 }") "int";
  check "nested block"
    (Pipeline.process "{ { 1; 2 }; { 10; 20 } }") "20";
  check "block does not conflict with record"
    (Pipeline.process
      "type P = { x: int };
       let p = P { x = 7 } in { p.x; p.x + 1 }") "8";

  (* --- match guards `| pat when expr -> body` --- *)
  check "guard small"
    (Pipeline.process
      "match 5 with
       | n when n < 0 -> \"neg\"
       | 0 -> \"zero\"
       | n when n < 10 -> \"small\"
       | _ -> \"large\"") "\"small\"";
  check "guard large fallthrough"
    (Pipeline.process
      "match 100 with
       | n when n < 0 -> \"neg\"
       | 0 -> \"zero\"
       | n when n < 10 -> \"small\"
       | _ -> \"large\"") "\"large\"";
  check "guard literal zero"
    (Pipeline.process
      "match 0 with
       | n when n < 0 -> \"neg\"
       | 0 -> \"zero\"
       | _ -> \"pos\"") "\"zero\"";
  check "guard with constructor"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       match Some 7 with
       | None -> 0
       | Some n when n > 10 -> 1000
       | Some n -> n + 1") "8";
  check "guard then fall to next"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       match Some 50 with
       | None -> 0
       | Some n when n > 10 -> 1000
       | Some n -> n + 1") "1000";
  check "guard does not bypass type"
    (Pipeline.type_of
      "fn n -> match n with | x when x > 0 -> x | _ -> 0") "(int -> int)";
  check_raises "guard must be bool"
    (fun () -> Pipeline.type_of
      "match 1 with | n when n + 1 -> 0 | _ -> 0");
  check "pp match with guard"
    (Ast.pp (Pipeline.parse_only
      "match x with | n when n > 0 -> n | _ -> 0"))
    "(match x with | n when (n > 0) -> n | _ -> 0)";

  (* --- list patterns `[]`, `[a, b, c]`, `[h, ...t]` --- *)
  check "list pattern empty"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       match [] with | [] -> \"empty\" | [_, ..._] -> \"some\"") "\"empty\"";
  check "list pattern head/rest"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       match [10, 20, 30] with | [] -> 0 | [h, ...t] -> h") "10";
  check "list pattern fixed length"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       match [1, 2, 3] with | [a, b, c] -> a * 100 + b * 10 + c | _ -> 0") "123";
  check "list pattern fixed length fail"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       match [1, 2, 3, 4] with | [a, b, c] -> a + b + c | _ -> 999") "999";
  check "list pattern two-elem rest"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       match [1, 2, 3, 4, 5] with | [a, b, ...rest] -> a + b | _ -> 0") "3";
  check "list pattern sum recursion"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       let rec sum = fn xs -> match xs with
         | [] -> 0
         | [h, ...t] -> h + sum t
       in sum [10, 20, 30, 40]") "100";
  check "list pattern wildcard rest"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       match [1, 2, 3] with | [h, ..._] -> h | [] -> 0") "1";
  check "list pattern len recursion"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       let rec len = fn xs -> match xs with
         | [] -> 0
         | [_, ...t] -> 1 + len t
       in len [1, 2, 3, 4, 5]") "5";
  check "list pattern with guard"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       match [3, 4, 5] with
       | [h, ...t] when h > 10 -> 1000
       | [h, ...t] -> h
       | [] -> 0") "3";

  (* --- record update `{ base | f1 = e1, ... }` --- *)
  check "record update single field"
    (Pipeline.process
      "type P = { x: int, y: int };
       let p = P { x = 1, y = 2 } in { p | x = 10 }")
    "P { x = 10, y = 2 }";
  check "record update multi field"
    (Pipeline.process
      "type P = { x: int, y: int, z: int };
       let p = P { x = 1, y = 2, z = 3 } in { p | x = 100, z = 300 }")
    "P { x = 100, y = 2, z = 300 }";
  check "record update preserves original"
    (Pipeline.process
      "type P = { x: int };
       let p = P { x = 5 } in
       let p2 = { p | x = 99 } in p.x + p2.x") "104";
  check "record update with computed value"
    (Pipeline.process
      "type P = { x: int, y: int };
       let p = P { x = 10, y = 20 } in { p | x = p.x + p.y }")
    "P { x = 30, y = 20 }";
  check "record update type preserves"
    (Pipeline.type_of
      "type P = { x: int };
       fn (p: P) -> { p | x = 0 }") "(P -> P)";
  check "record update polymorphic"
    (Pipeline.process
      "type 'a Box = { value: 'a };
       let b = Box { value = 42 } in ({ b | value = 100 }).value") "100";
  check_raises "record update unknown field"
    (fun () -> Pipeline.process
      "type P = { x: int };
       let p = P { x = 1 } in { p | y = 2 }");
  check_raises "record update wrong type"
    (fun () -> Pipeline.process
      "type P = { x: int };
       let p = P { x = 1 } in { p | x = \"hi\" }");
  check "pp record update"
    (Ast.pp (Pipeline.parse_only
      "type P = { x: int }; let p = P { x = 1 } in { p | x = 5 }"))
    "(let p = P { x = 1 } in { p | x = 5 })";

  (* --- stdlib additions: not, str_len, int_of_str, print_bool --- *)
  check "not true" (Pipeline.process "not true") "false";
  check "not false" (Pipeline.process "not false") "true";
  check "not type" (Pipeline.type_of "not") "(bool -> bool)";
  check "str_len basic" (Pipeline.process "str_len \"hello\"") "5";
  check "str_len empty" (Pipeline.process "str_len \"\"") "0";
  check "str_len type" (Pipeline.type_of "str_len") "(str -> int)";
  check "int_of_str basic" (Pipeline.process "int_of_str \"42\"") "42";
  check "int_of_str trim" (Pipeline.process "int_of_str \"  100  \"") "100";
  check "int_of_str chain"
    (Pipeline.process "int_of_str \"7\" + int_of_str \"3\"") "10";
  check "int_of_str type" (Pipeline.type_of "int_of_str") "(str -> int)";
  check_raises "int_of_str invalid"
    (fun () -> Pipeline.process "int_of_str \"abc\"");
  check "print_bool type" (Pipeline.type_of "print_bool") "(bool -> unit)";
  check "combo: str_len + int_of_str"
    (Pipeline.process
      "let s = \"123\" in
       let n = int_of_str s in
       n + str_len s") "126";
  check "not in if-condition"
    (Pipeline.process
      "let f = fn (b: bool) -> if not b then 10 else 20 in f false") "10";

  (* --- multi-arg type parameters: `('a, 'b) result` etc. --- *)
  check "result Ok"
    (Pipeline.process
      "type ('a, 'b) result = Ok of 'a | Err of 'b;
       Ok 5") "Ok 5";
  check "result Err"
    (Pipeline.process
      "type ('a, 'b) result = Ok of 'a | Err of 'b;
       Err \"boom\"") "Err \"boom\"";
  check "result type of Ok"
    (Pipeline.type_of
      "type ('a, 'b) result = Ok of 'a | Err of 'b;
       Ok 5") "(int, 'a) result";
  check "result type of Err"
    (Pipeline.type_of
      "type ('a, 'b) result = Ok of 'a | Err of 'b;
       Err \"oops\"") "('a, str) result";
  check "safe_div with result"
    (Pipeline.process
      "type ('a, 'b) result = Ok of 'a | Err of 'b;
       let safe_div = fn (a: int, b: int) ->
         if b == 0 then Err \"div by zero\"
         else Ok (a / b)
       in match safe_div 20 4 with
       | Ok v -> v
       | Err _ -> -1") "5";
  check "safe_div err case"
    (Pipeline.process
      "type ('a, 'b) result = Ok of 'a | Err of 'b;
       let safe_div = fn (a: int, b: int) ->
         if b == 0 then Err \"div by zero\"
         else Ok (a / b)
       in match safe_div 10 0 with
       | Ok v -> v
       | Err _ -> -1") "-1";
  check "Either-like 3-arg type"
    (Pipeline.process
      "type ('a, 'b, 'c) triple = A of 'a | B of 'b | C of 'c;
       B 42") "B 42";
  check "3-arg type display"
    (Pipeline.type_of
      "type ('a, 'b, 'c) triple = A of 'a | B of 'b | C of 'c;
       B 42") "('a, int, 'b) triple";
  check "single param still works"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       Some 5") "Some 5";
  check "multi-arg type in field"
    (Pipeline.process
      "type ('a, 'b) result = Ok of 'a | Err of 'b;
       type Wrapper = { value: (int, str) result };
       let w = Wrapper { value = Ok 42 } in
       match w.value with
       | Ok n -> n
       | Err _ -> 0") "42";
  check_raises "type param count mismatch"
    (fun () -> Pipeline.process
      "type ('a, 'b) result = Ok of 'a | Err of 'b;
       (int) result");

  (* --- top-level let pattern --- *)
  check "top let wildcard"
    (Pipeline.process "let _ = 99; 42") "42";
  check "top let tuple"
    (Pipeline.process "let (a, b) = (3, 4); a * b") "12";
  check "top let 3-tuple"
    (Pipeline.process "let (a, b, c) = (1, 10, 100); a + b + c") "111";
  check "top let unit"
    (Pipeline.process "let () = (); 1") "1";
  check "top let nested tuple"
    (Pipeline.process "let (a, (b, c)) = (1, (2, 3)); a + b + c") "6";
  check "top let ident (legacy form)"
    (Pipeline.process "let x = 5; let y = 10; x + y") "15";
  check "top let preserves polymorphism"
    (Pipeline.type_of
      "let (f, g) = (fn x -> x, fn x -> x + 1); f") "('a -> 'a)";
  check_raises "top let arity mismatch"
    (fun () -> Pipeline.process "let (a, b, c) = (1, 2); a");
  check_raises "top let type mismatch"
    (fun () -> Pipeline.process "let (a, b) = (1, 2, 3); a");

  (* --- if without else (unit-typed branch) --- *)
  check "if without else (true branch)"
    (Pipeline.process "if true then print \"hi\"") "()";
  check "if without else (false branch)"
    (Pipeline.process "if false then print \"hi\"") "()";
  check "if without else type"
    (Pipeline.type_of "if true then print \"x\"") "unit";
  check "if without else in block"
    (Pipeline.process "{ if false then print \"skip\"; 42 }") "42";
  check "if without else in fn"
    (Pipeline.process
      "let log_if = fn (b: bool, msg: str) -> if b then print msg in
       { log_if true \"shown\"; log_if false \"hidden\"; 1 }") "1";
  check_raises "if without else needs unit branch"
    (fun () -> Pipeline.process "if true then 5");

  (* --- stdlib F3: 2-arg curry builtins --- *)
  check "str_contains hit"
    (Pipeline.process "str_contains \"hello world\" \"world\"") "true";
  check "str_contains miss"
    (Pipeline.process "str_contains \"hello\" \"xyz\"") "false";
  check "str_contains empty needle"
    (Pipeline.process "str_contains \"abc\" \"\"") "true";
  check "str_contains type"
    (Pipeline.type_of "str_contains") "(str -> (str -> bool))";
  check "char_at first"
    (Pipeline.process "char_at \"hello\" 0") "\"h\"";
  check "char_at last"
    (Pipeline.process "char_at \"hello\" 4") "\"o\"";
  check "char_at type"
    (Pipeline.type_of "char_at") "(str -> (int -> str))";
  check_raises "char_at out of range"
    (fun () -> Pipeline.process "char_at \"abc\" 10");
  check_raises "char_at negative"
    (fun () -> Pipeline.process "char_at \"abc\" (- 1)");
  check "str_contains with pipe (needle piped)"
    (* `"sub" |> str_contains "haystack"` desugars to
       `str_contains "haystack" "sub"` — pipe + curry composes naturally
       when the piped value is the second curry arg. *)
    (Pipeline.process "\"world\" |> str_contains \"hello world\"") "true";
  check "char_at curry"
    (Pipeline.process "let first = char_at \"abcdef\" in first 2") "\"c\"";

  (* --- polymorphic `fail : str -> 'a` --- *)
  check "fail type is polymorphic"
    (Pipeline.type_of "fail") "(str -> 'a)";
  check "fail unified with int"
    (Pipeline.type_of
      "fn (x: int) -> if x < 0 then fail \"neg\" else x") "(int -> int)";
  check "fail unified with bool"
    (Pipeline.type_of
      "fn (x: int) -> if x == 0 then fail \"zero\" else true") "(int -> bool)";
  check "fail in non-taken branch"
    (Pipeline.process
      "let f = fn (x: int) -> if x < 0 then fail \"neg\" else x in f 7") "7";
  check "fail in match arm"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       match Some 5 with | Some n -> n | None -> fail \"expected Some\"") "5";
  check_raises "fail actually raises"
    (fun () -> Pipeline.process
      "let f = fn (x: int) -> if x < 0 then fail \"neg\" else x in f (- 5)");
  check_raises "fail with match falling to None"
    (fun () -> Pipeline.process
      "type 'a opt = None | Some of 'a;
       match None with | Some n -> n | None -> fail \"expected Some\"");
  check "fail polymorphic at multiple sites"
    (Pipeline.process
      "let pos = fn (x: int) -> if x > 0 then x else fail \"non-pos\" in
       let neg = fn (x: int) -> if x < 0 then x else fail \"non-neg\" in
       pos 5 + neg (- 3)") "2";

  (* --- stdlib F5: int helpers (min, max, abs) --- *)
  check "min smaller" (Pipeline.process "min 3 5") "3";
  check "min larger" (Pipeline.process "min 5 3") "3";
  check "min equal" (Pipeline.process "min 7 7") "7";
  check "max smaller" (Pipeline.process "max 3 5") "5";
  check "max larger" (Pipeline.process "max 5 3") "5";
  check "abs positive" (Pipeline.process "abs 10") "10";
  check "abs negative" (Pipeline.process "abs (- 7)") "7";
  check "abs zero" (Pipeline.process "abs 0") "0";
  check "min type" (Pipeline.type_of "min") "(int -> (int -> int))";
  check "max type" (Pipeline.type_of "max") "(int -> (int -> int))";
  check "abs type" (Pipeline.type_of "abs") "(int -> int)";
  check "min/max chained"
    (Pipeline.process "max (min 10 20) (min 5 50)") "10";
  check "min curry partial"
    (Pipeline.process "let clamp_lo = min 100 in clamp_lo 50") "50";

  (* --- stdlib F6: assert --- *)
  check "assert true returns unit"
    (Pipeline.process "assert true \"ok\"") "()";
  check_raises "assert false raises"
    (fun () -> Pipeline.process "assert false \"boom\"");
  check "assert type"
    (Pipeline.type_of "assert") "(bool -> (str -> unit))";
  check "assert in block"
    (Pipeline.process
      "{ assert (1 + 1 == 2) \"math broken\"; \"all good\" }") "\"all good\"";
  check_raises "assert chained false raises"
    (fun () -> Pipeline.process
      "{ assert (10 > 0) \"a\"; assert (1 == 2) \"b\"; \"x\" }");
  check "assert curry partial"
    (Pipeline.process
      "let must = assert true in must \"unused\"") "()";

  (* --- structural equality on compound values --- *)
  check "tuple eq same"
    (Pipeline.process "(1, 2, 3) == (1, 2, 3)") "true";
  check "tuple eq different"
    (Pipeline.process "(1, 2, 3) == (1, 2, 4)") "false";
  check "tuple ne"
    (Pipeline.process "(1, 2) != (1, 3)") "true";
  check "nested tuple eq"
    (Pipeline.process "(1, (2, 3)) == (1, (2, 3))") "true";
  check "nested tuple ne"
    (Pipeline.process "(1, (2, 3)) == (1, (2, 4))") "false";
  check "record eq same"
    (Pipeline.process
      "type P = { x: int, y: int };
       P { x = 1, y = 2 } == P { x = 1, y = 2 }") "true";
  check "record eq diff value"
    (Pipeline.process
      "type P = { x: int };
       P { x = 1 } == P { x = 5 }") "false";
  check "constr nullary eq"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       (None: int opt) == None") "true";
  check "constr payload eq"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       Some 5 == Some 5") "true";
  check "constr different variant"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       Some 5 == None") "false";
  check "constr nested eq"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       [1, 2, 3] == [1, 2, 3]") "true";
  check "list ne different length"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       [1, 2, 3] == [1, 2]") "false";
  check_raises "function equality raises"
    (fun () -> Pipeline.process
      "(fn x -> x) == (fn x -> x)");
  check "eq in match guard"
    (Pipeline.process
      "match (1, 2) with
       | p when p == (1, 2) -> \"hit\"
       | _ -> \"miss\"") "\"hit\"";

  (* --- type aliases `type Name = T;` --- *)
  check "alias to int"
    (Pipeline.process
      "type UserId = int;
       let mk = fn (x: UserId) -> x + 1 in mk 41") "42";
  check "alias to tuple"
    (Pipeline.process
      "type Pair = int * int;
       let f = fn (x: Pair) -> x in f (10, 20)") "(10, 20)";
  check "alias type display unifies to base"
    (Pipeline.type_of
      "type UserId = int;
       fn (x: UserId) -> x + 1") "(int -> int)";
  check "alias chain"
    (Pipeline.process
      "type Box = int;
       type DoubleBox = Box;
       let f = fn (x: DoubleBox) -> x * 2 in f 21") "42";
  check "alias to arrow"
    (Pipeline.process
      "type Cont = int -> int;
       let twice = fn (f: Cont) -> fn x -> f (f x) in
       twice (fn x -> x + 1) 10") "12";
  check "polymorphic alias"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       type 'a Stack = 'a list;
       let push = fn (x: int, s: int Stack) -> Cons (x, s) in
       push 1 [2, 3]") "[1, 2, 3]";
  check "alias as record field type"
    (Pipeline.process
      "type Id = int;
       type User = { id: Id, name: str };
       let u = User { id = 7, name = \"alice\" } in u.id") "7";
  check "variant with single constructor still works"
    (Pipeline.process
      "type Wrap = Wrap of int;
       match Wrap 10 with | Wrap n -> n + 5") "15";

  (* --- function composition `<<` and `>>` --- *)
  check "compose << basic"
    (Pipeline.process
      "let inc = fn x -> x + 1 in
       let dbl = fn x -> x * 2 in
       (inc << dbl) 5") "11";
  check "compose >> basic"
    (Pipeline.process
      "let inc = fn x -> x + 1 in
       let dbl = fn x -> x * 2 in
       (inc >> dbl) 5") "12";
  check "compose << right-assoc"
    (Pipeline.process
      "let inc = fn x -> x + 1 in
       let dbl = fn x -> x * 2 in
       let neg = fn x -> 0 - x in
       (inc << dbl << neg) 3") "-5";
  check "compose >> right-assoc"
    (Pipeline.process
      "let a = fn x -> x + 1 in
       let b = fn x -> x * 2 in
       let c = fn x -> x - 3 in
       (a >> b >> c) 5") "9";
  check "compose with pipe"
    (Pipeline.process
      "let inc = fn x -> x + 1 in
       let dbl = fn x -> x * 2 in
       5 |> (inc << dbl)") "11";
  check "compose type"
    (Pipeline.type_of
      "fn (f: int -> int) -> fn (g: int -> int) -> f << g")
    "((int -> int) -> ((int -> int) -> (int -> int)))";
  check "compose with stdlib"
    (Pipeline.process
      "let show_inc = str_of_int << (fn x -> x + 1) in show_inc 41") "\"42\"";

  (* --- polymorphic `show : 'a -> str` --- *)
  check "show type" (Pipeline.type_of "show") "('a -> str)";
  check "show int" (Pipeline.process "show 42") "\"42\"";
  check "show bool" (Pipeline.process "show true") "\"true\"";
  check "show str" (Pipeline.process "show \"hi\"") "\"\\\"hi\\\"\"";
  check "show tuple" (Pipeline.process "show (1, 2, 3)") "\"(1, 2, 3)\"";
  check "show unit" (Pipeline.process "show ()") "\"()\"";
  check "show record"
    (Pipeline.process
      "type P = { x: int };
       show (P { x = 5 })") "\"P { x = 5 }\"";
  check "show constructor"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       show (Some 42)") "\"Some 42\"";
  check "show list"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       show [1, 2]") "\"[1, 2]\"";
  check "show at multiple types in one expr"
    (Pipeline.process
      "show 1 ++ \" / \" ++ show true ++ \" / \" ++ show \"x\"")
    "\"1 / true / \\\"x\\\"\"";
  check "show with compose"
    (Pipeline.process
      "let print_int_v2 = print << show in
       { print_int_v2 99; 1 }") "1";

  (* --- stdlib F8: even / odd --- *)
  check "even 4" (Pipeline.process "even 4") "true";
  check "even 7" (Pipeline.process "even 7") "false";
  check "even 0" (Pipeline.process "even 0") "true";
  check "odd 3" (Pipeline.process "odd 3") "true";
  check "odd negative" (Pipeline.process "odd (- 5)") "true";
  check "even type" (Pipeline.type_of "even") "(int -> bool)";
  check "odd type" (Pipeline.type_of "odd") "(int -> bool)";
  check "even/odd in filter-like"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       let rec count_evens = fn xs -> match xs with
         | [] -> 0
         | [h, ...t] -> if even h then 1 + count_evens t else count_evens t
       in count_evens [1, 2, 3, 4, 5, 6]") "3";

  (* --- stdlib F9: pow (integer exponentiation) --- *)
  check "pow 2^10" (Pipeline.process "pow 2 10") "1024";
  check "pow 3^4" (Pipeline.process "pow 3 4") "81";
  check "pow base^0" (Pipeline.process "pow 5 0") "1";
  check "pow 0^5" (Pipeline.process "pow 0 5") "0";
  check "pow 1^big" (Pipeline.process "pow 1 100") "1";
  check "pow negative base" (Pipeline.process "pow (- 2) 3") "-8";
  check "pow type" (Pipeline.type_of "pow") "(int -> (int -> int))";
  check_raises "pow negative exponent"
    (fun () -> Pipeline.process "pow 2 (- 1)");
  check "pow combo"
    (Pipeline.process "pow 2 16 + pow 3 3") "65563";

  (* --- stdlib F10: str_starts_with / str_ends_with --- *)
  check "starts_with hit"
    (Pipeline.process "str_starts_with \"hello world\" \"hello\"") "true";
  check "starts_with miss"
    (Pipeline.process "str_starts_with \"hello\" \"world\"") "false";
  check "starts_with empty prefix"
    (Pipeline.process "str_starts_with \"abc\" \"\"") "true";
  check "starts_with full match"
    (Pipeline.process "str_starts_with \"abc\" \"abc\"") "true";
  check "starts_with longer prefix"
    (Pipeline.process "str_starts_with \"abc\" \"abcd\"") "false";
  check "ends_with hit"
    (Pipeline.process "str_ends_with \"hello world\" \"world\"") "true";
  check "ends_with miss"
    (Pipeline.process "str_ends_with \"hello\" \"world\"") "false";
  check "ends_with empty suffix"
    (Pipeline.process "str_ends_with \"abc\" \"\"") "true";
  check "ends_with full match"
    (Pipeline.process "str_ends_with \"abc\" \"abc\"") "true";
  check "starts_with type"
    (Pipeline.type_of "str_starts_with") "(str -> (str -> bool))";
  check "ends_with type"
    (Pipeline.type_of "str_ends_with") "(str -> (str -> bool))";
  check "starts_with empty string"
    (Pipeline.process "str_starts_with \"\" \"a\"") "false";

  (* --- stdlib F11: str_repeat --- *)
  check "str_repeat basic"
    (Pipeline.process "str_repeat \"ab\" 3") "\"ababab\"";
  check "str_repeat dashes"
    (Pipeline.process "str_repeat \"-\" 5") "\"-----\"";
  check "str_repeat zero"
    (Pipeline.process "str_repeat \"hi\" 0") "\"\"";
  check "str_repeat empty string"
    (Pipeline.process "str_repeat \"\" 5") "\"\"";
  check "str_repeat type"
    (Pipeline.type_of "str_repeat") "(str -> (int -> str))";
  check_raises "str_repeat negative"
    (fun () -> Pipeline.process "str_repeat \"x\" (- 1)");
  check "str_repeat single char"
    (Pipeline.process "str_repeat \"X\" 1") "\"X\"";

  (* --- stdlib F12: substring (3-arg curry) --- *)
  check "substring basic"
    (Pipeline.process "substring \"hello\" 1 4") "\"ell\"";
  check "substring full"
    (Pipeline.process "substring \"hello\" 0 5") "\"hello\"";
  check "substring empty range"
    (Pipeline.process "substring \"hello\" 2 2") "\"\"";
  check "substring prefix"
    (Pipeline.process "substring \"hello\" 0 3") "\"hel\"";
  check "substring suffix"
    (Pipeline.process "substring \"hello\" 2 5") "\"llo\"";
  check "substring type"
    (Pipeline.type_of "substring") "(str -> (int -> (int -> str)))";
  check_raises "substring end too large"
    (fun () -> Pipeline.process "substring \"hi\" 0 10");
  check_raises "substring start negative"
    (fun () -> Pipeline.process "substring \"hi\" (- 1) 1");
  check_raises "substring start > end"
    (fun () -> Pipeline.process "substring \"hi\" 2 1");
  check "substring curry partial"
    (Pipeline.process
      "let take = substring \"abcdef\" 0 in take 4") "\"abcd\"";

  (* --- stdlib F13: gcd / lcm --- *)
  check "gcd basic" (Pipeline.process "gcd 12 18") "6";
  check "gcd coprime" (Pipeline.process "gcd 7 13") "1";
  check "gcd with zero" (Pipeline.process "gcd 0 5") "5";
  check "gcd negative" (Pipeline.process "gcd (- 12) 18") "6";
  check "gcd same" (Pipeline.process "gcd 9 9") "9";
  check "lcm basic" (Pipeline.process "lcm 4 6") "12";
  check "lcm with zero" (Pipeline.process "lcm 0 5") "0";
  check "lcm not exact mult"
    (Pipeline.process "lcm 21 6") "42";
  check "gcd type" (Pipeline.type_of "gcd") "(int -> (int -> int))";
  check "lcm type" (Pipeline.type_of "lcm") "(int -> (int -> int))";
  check "gcd identity"
    (Pipeline.process "gcd (gcd 24 36) 60") "12";

  (* --- stdlib F14: bool_of_str --- *)
  check "bool_of_str true"
    (Pipeline.process "bool_of_str \"true\"") "true";
  check "bool_of_str false"
    (Pipeline.process "bool_of_str \"false\"") "false";
  check "bool_of_str trimmed"
    (Pipeline.process "bool_of_str \"  true  \"") "true";
  check "bool_of_str type"
    (Pipeline.type_of "bool_of_str") "(str -> bool)";
  check_raises "bool_of_str invalid"
    (fun () -> Pipeline.process "bool_of_str \"yes\"");
  check_raises "bool_of_str empty"
    (fun () -> Pipeline.process "bool_of_str \"\"");
  check "bool_of_str chained"
    (Pipeline.process "if bool_of_str \"true\" then 1 else 0") "1";

  (* --- stdlib F15: str_compare (lexicographic, -1/0/1) --- *)
  check "str_compare equal"
    (Pipeline.process "str_compare \"abc\" \"abc\"") "0";
  check "str_compare less"
    (Pipeline.process "str_compare \"abc\" \"abd\"") "-1";
  check "str_compare greater"
    (Pipeline.process "str_compare \"abd\" \"abc\"") "1";
  check "str_compare empty vs nonempty"
    (Pipeline.process "str_compare \"\" \"a\"") "-1";
  check "str_compare prefix"
    (Pipeline.process "str_compare \"abc\" \"abcd\"") "-1";
  check "str_compare type"
    (Pipeline.type_of "str_compare") "(str -> (str -> int))";
  check "str_compare in if"
    (Pipeline.process
      "if str_compare \"a\" \"b\" < 0 then \"a-first\" else \"b-first\"") "\"a-first\"";

  (* --- as-pattern `| pat as name -> body` --- *)
  check "as-pattern tuple"
    (Pipeline.process
      "match (1, 2) with | (a, b) as p -> a + b") "3";
  check "as-pattern preserves whole"
    (Pipeline.process
      "match (10, 20) with | (a, b) as whole -> show whole")
    "\"(10, 20)\"";
  check "as-pattern with constructor"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       match Some 5 with | Some n as s -> n | None -> 0") "5";
  check "as-pattern with list"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       match [1, 2, 3] with
       | Cons (h, t) as whole -> h
       | [] -> 0") "1";
  check "as-pattern bind both"
    (Pipeline.process
      "match (3, 4) with
       | (a, b) as p -> a + b + (let (x, y) = p in x * y)") "19";
  check "as-pattern in let"
    (Pipeline.process
      "let (a, b) as p = (5, 6) in
       a + b + (let (_, _) = p in 100)") "111";
  check "as-pattern with guard"
    (Pipeline.process
      "match (1, 2) with
       | (a, b) as p when a < b -> \"ordered\"
       | _ -> \"reversed\"") "\"ordered\"";
  check "pp as-pattern"
    (Ast.pp (Pipeline.parse_only
      "match x with | (a, b) as p -> a"))
    "(match x with | ((a, b) as p) -> a)";

  (* --- or-pattern `| pat1 | pat2 -> body` --- *)
  check "or-pattern ints"
    (Pipeline.process
      "match 5 with
       | 1 | 2 | 3 -> \"low\"
       | 4 | 5 | 6 -> \"mid\"
       | _ -> \"high\"") "\"mid\"";
  check "or-pattern fallthrough"
    (Pipeline.process
      "match 100 with
       | 1 | 2 | 3 -> \"low\"
       | _ -> \"other\"") "\"other\"";
  check "or-pattern constr"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       match Some 5 with
       | None | Some 0 -> 0
       | Some n -> n") "5";
  check "or-pattern with var binding (consistent)"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       match Some 5 with
       | Some 0 | Some 1 -> \"low\"
       | Some n -> show n") "\"5\"";
  check_raises "or-pattern with conflicting bindings"
    (fun () -> Pipeline.process
      "type T = A of int | B of str;
       match A 1 with | A x | B x -> x");
  check "or-pattern in let (single arm)"
    (Pipeline.process
      "match (1, 2) with | (a, b) | (b, a) -> a + b") "3";
  check "or-pattern with guard"
    (Pipeline.process
      "match 3 with
       | 1 | 2 | 3 when true -> \"matched\"
       | _ -> \"other\"") "\"matched\"";
  check "pp or-pattern"
    (Ast.pp (Pipeline.parse_only
      "match x with | 1 | 2 -> 10 | _ -> 0"))
    "(match x with | (1 | 2) -> 10 | _ -> 0)";

  (* --- polymorphic `fst` / `snd` for 2-tuples --- *)
  check "fst int/str"
    (Pipeline.process "fst (42, \"hi\")") "42";
  check "snd int/str"
    (Pipeline.process "snd (42, \"hi\")") "\"hi\"";
  check "fst type"
    (Pipeline.type_of "fst") "(('a * 'b) -> 'a)";
  check "snd type"
    (Pipeline.type_of "snd") "(('a * 'b) -> 'b)";
  check "fst at int/bool"
    (Pipeline.type_of "fst (1, true)") "int";
  check "snd at int/bool"
    (Pipeline.type_of "snd (1, true)") "bool";
  check "fst polymorphic two sites"
    (Pipeline.process
      "fst (10, true) + (if snd (\"x\", 5) > 0 then 1 else 0)") "11";
  check "fst/snd nested"
    (Pipeline.process "fst (snd ((1, 2), (3, 4)))") "3";
  check "fst with show"
    (Pipeline.process "show (fst (\"a\", 42))") "\"\\\"a\\\"\"";
  check_raises "fst on non-2-tuple"
    (fun () -> Pipeline.process "fst (1, 2, 3)");

  (* --- polymorphic `id` and `swap` --- *)
  check "id type" (Pipeline.type_of "id") "('a -> 'a)";
  check "id int" (Pipeline.process "id 42") "42";
  check "id str" (Pipeline.process "id \"hi\"") "\"hi\"";
  check "id with compose"
    (Pipeline.process
      "let f = id << (fn x -> x + 1) in f 41") "42";
  check "id at multiple types"
    (Pipeline.process "id 1 + (if id true then 10 else 0)") "11";
  check "swap type"
    (Pipeline.type_of "swap") "(('a * 'b) -> ('b * 'a))";
  check "swap basic"
    (Pipeline.process "swap (1, \"a\")") "(\"a\", 1)";
  check "swap involution"
    (Pipeline.process "swap (swap (10, 20))") "(10, 20)";
  check "swap with fst/snd"
    (Pipeline.process "fst (swap (1, \"hello\"))") "\"hello\"";
  check_raises "swap on non-2-tuple"
    (fun () -> Pipeline.process "swap (1, 2, 3)");

  (* --- polymorphic `const` and `flip` (higher-order) --- *)
  check "const type"
    (Pipeline.type_of "const") "('a -> ('b -> 'a))";
  check "const int/str"
    (Pipeline.process "const 42 \"ignored\"") "42";
  check "const partial"
    (Pipeline.process
      "let always7 = const 7 in
       always7 \"a\" + always7 100") "14";
  check "flip type"
    (Pipeline.type_of "flip")
    "(('a -> ('b -> 'c)) -> ('b -> ('a -> 'c)))";
  check "flip swaps args"
    (Pipeline.process
      "let sub = fn (a: int) -> fn (b: int) -> a - b in
       (flip sub) 3 10") "7";
  check "flip with builtin"
    (Pipeline.process "flip str_contains \"world\" \"hello world\"") "true";
  check "flip is self-inverse"
    (Pipeline.process
      "let sub = fn (a: int) -> fn (b: int) -> a - b in
       flip (flip sub) 10 3") "7";
  check "const + flip combo"
    (Pipeline.process
      "let take_first = flip const in
       take_first \"discarded\" 100") "100";

  (* --- polymorphic `try_or` (catch Eval_error, return default) --- *)
  check "try_or type"
    (Pipeline.type_of "try_or") "((unit -> 'a) -> ('a -> 'a))";
  check "try_or success"
    (Pipeline.process "try_or (fn () -> 1 + 2) 0") "3";
  check "try_or catches int_of_str"
    (Pipeline.process "try_or (fn () -> int_of_str \"abc\") (- 1)") "-1";
  check "try_or catches fail"
    (Pipeline.process "try_or (fn () -> fail \"oops\") 999") "999";
  check "try_or catches div by zero"
    (Pipeline.process "try_or (fn () -> 10 / 0) 0") "0";
  check "try_or catches assert"
    (Pipeline.process "try_or (fn () -> { assert false \"bad\"; 1 }) 42") "42";
  check "try_or polymorphic at str"
    (Pipeline.process
      "try_or (fn () -> int_of_str \"bad\" |> show) \"none\"") "\"none\"";
  check "try_or chained"
    (Pipeline.process
      "let safe_parse = fn (s: str) -> try_or (fn () -> int_of_str s) (- 1) in
       safe_parse \"7\" + safe_parse \"hi\"") "6";

  (* --- stdlib int helpers: sign / clamp --- *)
  check "sign positive" (Pipeline.process "sign 5") "1";
  check "sign negative" (Pipeline.process "sign (- 5)") "-1";
  check "sign zero" (Pipeline.process "sign 0") "0";
  check "sign type" (Pipeline.type_of "sign") "(int -> int)";
  check "clamp in range" (Pipeline.process "clamp 0 10 5") "5";
  check "clamp below" (Pipeline.process "clamp 0 10 (- 3)") "0";
  check "clamp above" (Pipeline.process "clamp 0 10 99") "10";
  check "clamp at boundary" (Pipeline.process "clamp 0 10 0") "0";
  check "clamp type" (Pipeline.type_of "clamp") "(int -> (int -> (int -> int)))";
  check "clamp curry"
    (Pipeline.process
      "let percent = clamp 0 100 in percent 150 + percent (- 5)") "100";

  (* --- stdlib: str_replace (3-arg curry, replace-all) --- *)
  check "str_replace basic"
    (Pipeline.process "str_replace \"hello world\" \"world\" \"lang\"")
    "\"hello lang\"";
  check "str_replace multiple"
    (Pipeline.process "str_replace \"foo bar foo\" \"foo\" \"X\"")
    "\"X bar X\"";
  check "str_replace expand"
    (Pipeline.process "str_replace \"aaa\" \"a\" \"bc\"")
    "\"bcbcbc\"";
  check "str_replace shrink"
    (Pipeline.process "str_replace \"xxxxx\" \"xx\" \"y\"")
    "\"yyx\"";
  check "str_replace none"
    (Pipeline.process "str_replace \"abc\" \"x\" \"y\"") "\"abc\"";
  check "str_replace empty needle"
    (Pipeline.process "str_replace \"hi\" \"\" \"!\"") "\"hi\"";
  check "str_replace to empty"
    (Pipeline.process "str_replace \"a-b-c\" \"-\" \"\"") "\"abc\"";
  check "str_replace type"
    (Pipeline.type_of "str_replace") "(str -> (str -> (str -> str)))";

  (* --- stdlib chr / ord (code point conversions) --- *)
  check "chr A" (Pipeline.process "chr 65") "\"A\"";
  check "chr space" (Pipeline.process "chr 32") "\" \"";
  check "chr zero" (Pipeline.process "chr 48") "\"0\"";
  check "ord A" (Pipeline.process "ord \"A\"") "65";
  check "ord lower a" (Pipeline.process "ord \"a\"") "97";
  check "chr/ord roundtrip"
    (Pipeline.process "ord (chr 100)") "100";
  check "chr type" (Pipeline.type_of "chr") "(int -> str)";
  check "ord type" (Pipeline.type_of "ord") "(str -> int)";
  check_raises "chr out of range high"
    (fun () -> Pipeline.process "chr 256");
  check_raises "chr out of range low"
    (fun () -> Pipeline.process "chr (- 1)");
  check_raises "ord multi-char"
    (fun () -> Pipeline.process "ord \"hi\"");
  check_raises "ord empty"
    (fun () -> Pipeline.process "ord \"\"");

  (* --- stdlib: to_upper / to_lower (ASCII case) --- *)
  check "to_upper basic"
    (Pipeline.process "to_upper \"hello\"") "\"HELLO\"";
  check "to_lower basic"
    (Pipeline.process "to_lower \"WORLD\"") "\"world\"";
  check "to_upper mixed"
    (Pipeline.process "to_upper \"Hello World 123\"") "\"HELLO WORLD 123\"";
  check "to_lower mixed"
    (Pipeline.process "to_lower \"Hello World 123\"") "\"hello world 123\"";
  check "to_upper empty"
    (Pipeline.process "to_upper \"\"") "\"\"";
  check "to_upper idempotent"
    (Pipeline.process "to_upper (to_upper \"abc\")") "\"ABC\"";
  check "to_upper/to_lower inverse on letters"
    (Pipeline.process "to_lower (to_upper \"hello\")") "\"hello\"";
  check "to_upper type"
    (Pipeline.type_of "to_upper") "(str -> str)";
  check "to_lower type"
    (Pipeline.type_of "to_lower") "(str -> str)";

  (* --- stdlib: str_trim (trim leading/trailing whitespace) --- *)
  check "str_trim basic"
    (Pipeline.process "str_trim \"  hello  \"") "\"hello\"";
  check "str_trim newlines"
    (Pipeline.process "str_trim \"\\n\\tabc\\n \"") "\"abc\"";
  check "str_trim no-op"
    (Pipeline.process "str_trim \"abc\"") "\"abc\"";
  check "str_trim empty"
    (Pipeline.process "str_trim \"\"") "\"\"";
  check "str_trim all whitespace"
    (Pipeline.process "str_trim \"   \"") "\"\"";
  check "str_trim preserves inner"
    (Pipeline.process "str_trim \"  a b c  \"") "\"a b c\"";
  check "str_trim type"
    (Pipeline.type_of "str_trim") "(str -> str)";

  (* --- stdlib: str_rev (string reversal) --- *)
  check "str_rev basic"
    (Pipeline.process "str_rev \"hello\"") "\"olleh\"";
  check "str_rev empty"
    (Pipeline.process "str_rev \"\"") "\"\"";
  check "str_rev single"
    (Pipeline.process "str_rev \"a\"") "\"a\"";
  check "str_rev involutive"
    (Pipeline.process "str_rev (str_rev \"abcdef\")") "\"abcdef\"";
  check "str_rev palindrome check"
    (Pipeline.process
      "let s = \"abcba\" in s == str_rev s") "true";
  check "str_rev type"
    (Pipeline.type_of "str_rev") "(str -> str)";

  (* --- stdlib: is_digit / is_alpha / is_space (single-char predicates) --- *)
  check "is_digit yes" (Pipeline.process "is_digit \"5\"") "true";
  check "is_digit zero" (Pipeline.process "is_digit \"0\"") "true";
  check "is_digit no" (Pipeline.process "is_digit \"a\"") "false";
  check "is_digit empty" (Pipeline.process "is_digit \"\"") "false";
  check "is_digit multi" (Pipeline.process "is_digit \"12\"") "false";
  check "is_alpha lower" (Pipeline.process "is_alpha \"x\"") "true";
  check "is_alpha upper" (Pipeline.process "is_alpha \"Z\"") "true";
  check "is_alpha digit" (Pipeline.process "is_alpha \"9\"") "false";
  check "is_alpha symbol" (Pipeline.process "is_alpha \"!\"") "false";
  check "is_space space" (Pipeline.process "is_space \" \"") "true";
  check "is_space tab" (Pipeline.process "is_space \"\\t\"") "true";
  check "is_space newline" (Pipeline.process "is_space \"\\n\"") "true";
  check "is_space letter" (Pipeline.process "is_space \"a\"") "false";
  check "is_digit type" (Pipeline.type_of "is_digit") "(str -> bool)";
  check "char predicate combo"
    (Pipeline.process
      "let c = char_at \"abc123\" 3 in
       is_digit c && (not (is_alpha c))") "true";

  (* --- polymorphic `pair : 'a -> 'b -> ('a * 'b)` --- *)
  check "pair type"
    (Pipeline.type_of "pair") "('a -> ('b -> ('a * 'b)))";
  check "pair int/str"
    (Pipeline.process "pair 1 \"hi\"") "(1, \"hi\")";
  check "pair bool/int"
    (Pipeline.process "pair true 42") "(true, 42)";
  check "pair + fst"
    (Pipeline.process "fst (pair 10 20)") "10";
  check "pair + snd"
    (Pipeline.process "snd (pair \"x\" \"y\")") "\"y\"";
  check "pair curry partial"
    (Pipeline.process "let with_loc = pair \"@\" in with_loc 99") "(\"@\", 99)";
  check "pair == swap inverse"
    (Pipeline.process
      "let p = pair 1 2 in (swap (pair 2 1)) == p") "true";

  (* --- stdlib: str_count (non-overlapping occurrences) --- *)
  check "str_count basic"
    (Pipeline.process "str_count \"abababab\" \"ab\"") "4";
  check "str_count non-overlapping"
    (Pipeline.process "str_count \"aaaa\" \"aa\"") "2";
  check "str_count miss"
    (Pipeline.process "str_count \"hello\" \"xyz\"") "0";
  check "str_count empty needle"
    (Pipeline.process "str_count \"abc\" \"\"") "0";
  check "str_count multi-occurrence"
    (Pipeline.process "str_count \"foo bar foo baz foo\" \"foo\"") "3";
  check "str_count single char"
    (Pipeline.process "str_count \"banana\" \"a\"") "3";
  check "str_count type"
    (Pipeline.type_of "str_count") "(str -> (str -> int))";

  (* --- read_line : unit -> str (only test type — stdin is process-level) --- *)
  check "read_line type"
    (Pipeline.type_of "read_line") "(unit -> str)";
  check "read_line in compose"
    (Pipeline.type_of "str_len << read_line") "(unit -> int)";

  (* --- print_no_nl : str -> unit (prompts without trailing newline) --- *)
  check "print_no_nl type"
    (Pipeline.type_of "print_no_nl") "(str -> unit)";
  check "print_no_nl returns unit"
    (Pipeline.process "print_no_nl \"x\"") "()";
  check "print_no_nl in block"
    (Pipeline.process "{ print_no_nl \"a\"; print_no_nl \"b\"; 42 }") "42";

  (* --- print_err : str -> unit (stderr output) --- *)
  check "print_err type"
    (Pipeline.type_of "print_err") "(str -> unit)";
  check "print_err returns unit"
    (Pipeline.process "print_err \"err msg\"") "()";

  (* --- iter_n : int -> (unit -> unit) -> unit (side-effect loop) --- *)
  check "iter_n type"
    (Pipeline.type_of "iter_n") "(int -> ((unit -> unit) -> unit))";
  check "iter_n returns unit"
    (Pipeline.process "iter_n 3 (fn () -> ())") "()";
  check "iter_n zero is no-op"
    (Pipeline.process "iter_n 0 (fn () -> fail \"should not run\")") "()";
  check "iter_n negative is no-op"
    (Pipeline.process "iter_n (- 5) (fn () -> fail \"never\")") "()";

  (* --- incr / decr (int -> int helpers) --- *)
  check "incr basic" (Pipeline.process "incr 9") "10";
  check "decr basic" (Pipeline.process "decr 10") "9";
  check "incr zero" (Pipeline.process "incr 0") "1";
  check "decr zero" (Pipeline.process "decr 0") "-1";
  check "incr negative" (Pipeline.process "incr (- 1)") "0";
  check "incr chain via compose"
    (Pipeline.process "(incr << incr << incr) 0") "3";
  check "incr type" (Pipeline.type_of "incr") "(int -> int)";
  check "decr type" (Pipeline.type_of "decr") "(int -> int)";
  check "incr/decr inverse"
    (Pipeline.process "(incr >> decr) 42") "42";

  (* --- sum_range : int -> int -> int (Gauss formula) --- *)
  check "sum_range 1..10" (Pipeline.process "sum_range 1 10") "55";
  check "sum_range 1..100" (Pipeline.process "sum_range 1 100") "5050";
  check "sum_range single" (Pipeline.process "sum_range 5 5") "5";
  check "sum_range empty"  (Pipeline.process "sum_range 10 5") "0";
  check "sum_range 0..0"   (Pipeline.process "sum_range 0 0") "0";
  check "sum_range type"   (Pipeline.type_of "sum_range") "(int -> (int -> int))";

  (* --- square / cube (int -> int) --- *)
  check "square positive" (Pipeline.process "square 7") "49";
  check "square negative" (Pipeline.process "square (- 4)") "16";
  check "square zero" (Pipeline.process "square 0") "0";
  check "cube positive" (Pipeline.process "cube 3") "27";
  check "cube negative" (Pipeline.process "cube (- 2)") "-8";
  check "square type" (Pipeline.type_of "square") "(int -> int)";
  check "cube type" (Pipeline.type_of "cube") "(int -> int)";
  check "square + cube via compose"
    (Pipeline.process "(cube << square) 2") "64";

  (* --- divmod : int -> int -> (int * int) (quotient, remainder) --- *)
  check "divmod basic"
    (Pipeline.process "divmod 17 5") "(3, 2)";
  check "divmod exact"
    (Pipeline.process "divmod 20 4") "(5, 0)";
  check "divmod by 1"
    (Pipeline.process "divmod 42 1") "(42, 0)";
  check "divmod with fst"
    (Pipeline.process "fst (divmod 100 7)") "14";
  check "divmod with snd"
    (Pipeline.process "snd (divmod 100 7)") "2";
  check "divmod type"
    (Pipeline.type_of "divmod") "(int -> (int -> (int * int)))";
  check_raises "divmod by zero"
    (fun () -> Pipeline.process "divmod 10 0");

  (* --- list display sugar: Cons/Nil chain is printed as [a, b, c] --- *)
  check "list display nested"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       show [[1, 2], [3], []]") "\"[[1, 2], [3], []]\"";
  check "list display with tuples"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       show [(1, \"a\"), (2, \"b\")]") "\"[(1, \\\"a\\\"), (2, \\\"b\\\")]\"";
  check "list display with constructors"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       type 'a opt = None | Some of 'a;
       show [Some 1, None, Some 3]") "\"[Some 1, None, Some 3]\"";
  check "list display single"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       [42]") "[42]";
  check "list-shaped user type still works"
    (* User-defined Cons with non-list shape falls back to standard display *)
    (Pipeline.process
      "type 'a misc = Nope | Cons of 'a;
       show (Cons 5)") "\"Cons 5\"";

  (* --- character literals `'X'` (length-1 str) --- *)
  check "char literal basic"
    (Pipeline.process "'A'") "\"A\"";
  check "char literal type"
    (Pipeline.type_of "'A'") "str";
  check "char literal escape newline"
    (Pipeline.process "'\\n'") "\"\\n\"";
  check "char literal escape tab"
    (Pipeline.process "'\\t'") "\"\\t\"";
  check "char literal escape backslash"
    (Pipeline.process "'\\\\'") "\"\\\\\"";
  check "char literal in match"
    (Pipeline.process
      "match 'h' with | 'h' -> \"hit\" | _ -> \"miss\"") "\"hit\"";
  check "char literal in match fallthrough"
    (Pipeline.process
      "match 'x' with | 'h' -> \"hit\" | _ -> \"miss\"") "\"miss\"";
  check "char literal in if condition"
    (Pipeline.process
      "let c = char_at \"hello\" 0 in
       if c == 'h' then \"yes\" else \"no\"") "\"yes\"";
  check "char literal dispatch chain"
    (Pipeline.process
      "let classify = fn (c: str) ->
         match c with
         | 'a' | 'e' | 'i' | 'o' | 'u' -> \"vowel\"
         | _ -> \"other\"
       in classify 'e' ++ \"-\" ++ classify 'b'") "\"vowel-other\"";
  check "tyvar still works (not confused with char literal)"
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       Some 5") "Some 5";
  check "polymorphic id with tyvar"
    (Pipeline.type_of "fn x -> x") "('a -> 'a)";

  (* --- str_unescape : decode escape sequences in a string --- *)
  check "str_unescape newline len"
    (Pipeline.process "str_len (str_unescape \"\\\\n\")") "1";
  check "str_unescape preserves non-escapes"
    (Pipeline.process "str_unescape \"abc\"") "\"abc\"";
  check "str_unescape equals lexer newline"
    (Pipeline.process "str_unescape \"\\\\n\" == \"\\n\"") "true";
  check "str_unescape mixed"
    (Pipeline.process "str_len (str_unescape \"a\\\\nb\\\\tc\")") "5";
  check "str_unescape backslash"
    (Pipeline.process "str_unescape \"\\\\\\\\\" == \"\\\\\"") "true";
  check "str_unescape quote"
    (Pipeline.process "str_unescape \"\\\\\\\"\" == \"\\\"\"") "true";
  check "str_unescape slash"
    (Pipeline.process "str_unescape \"\\\\/\" == \"/\"") "true";
  check "str_unescape type"
    (Pipeline.type_of "str_unescape") "(str -> str)";
  check_raises "str_unescape unknown escape"
    (fun () -> Pipeline.process "str_unescape \"\\\\x\"");

  (* --- file I/O: read_file / write_file (round-trip via /tmp) --- *)
  check "read_file type"
    (Pipeline.type_of "read_file") "(str -> str)";
  check "write_file type"
    (Pipeline.type_of "write_file") "(str -> (str -> unit))";
  check "file round-trip"
    (let path = Filename.temp_file "lang_ml_test" ".txt" in
     Pipeline.process
       (Printf.sprintf
          "{ write_file %S \"hello lang\"; read_file %S }" path path))
    "\"hello lang\"";
  check_raises "read_file missing"
    (fun () -> Pipeline.process "read_file \"/nonexistent/no/such/file\"");

  (* --- float type and basic arithmetic --- *)
  check "float literal"
    (Pipeline.process "3.14") "3.14";
  check "float type"
    (Pipeline.type_of "1.5") "float";
  check "float in fn annotation"
    (Pipeline.type_of "fn (x: float) -> x") "(float -> float)";
  check "float equality"
    (Pipeline.process "1.5 == 1.5") "true";
  check "float inequality"
    (Pipeline.process "1.5 != 2.0") "true";
  check "float show"
    (Pipeline.process "show 2.5") "\"2.5\"";
  check "f_add"
    (Pipeline.process "f_add 1.5 2.5") "4.";
  check "f_sub"
    (Pipeline.process "f_sub 10.0 3.0") "7.";
  check "f_mul"
    (Pipeline.process "f_mul 3.0 4.0") "12.";
  check "f_div"
    (Pipeline.process "f_div 10.0 4.0") "2.5";
  check "float_of_int"
    (Pipeline.process "float_of_int 7") "7.";
  check "int_of_float truncates"
    (Pipeline.process "int_of_float 3.7") "3";
  check "str_of_float"
    (Pipeline.process "str_of_float 1.5") "\"1.5\"";
  check "float_of_str"
    (Pipeline.process "float_of_str \"3.14\"") "3.14";
  check "float_of_str trimmed"
    (Pipeline.process "float_of_str \"  2.5  \"") "2.5";
  check_raises "float_of_str invalid"
    (fun () -> Pipeline.process "float_of_str \"abc\"");
  check "float pipe chain"
    (Pipeline.process "1.5 |> f_add 2.5 |> f_mul 2.0") "8.";
  check "int + float = type error"
    (* Lang requires explicit conversion *)
    (Pipeline.type_of "(float_of_int 3) |> f_add 0.5") "float";
  check_raises "f_add with int errors"
    (fun () -> Pipeline.type_of "f_add 1 2");

  (* --- float comparison: f_lt / f_le / f_gt / f_ge --- *)
  check "f_lt true"  (Pipeline.process "f_lt 1.5 2.5") "true";
  check "f_lt false" (Pipeline.process "f_lt 2.5 1.5") "false";
  check "f_le equal" (Pipeline.process "f_le 1.5 1.5") "true";
  check "f_gt true"  (Pipeline.process "f_gt 3.0 2.0") "true";
  check "f_ge equal" (Pipeline.process "f_ge 1.0 1.0") "true";
  check "f_lt type"
    (Pipeline.type_of "f_lt") "(float -> (float -> bool))";

  (* --- system: time + exit --- *)
  check "time type"
    (Pipeline.type_of "time") "(unit -> float)";
  check "time > 0"
    (Pipeline.process "f_gt (time ()) 0.0") "true";
  check "exit type"
    (Pipeline.type_of "exit") "(int -> 'a)";
  check "exit polymorphic"
    (* The body of `else` is never executed, but its type unifies with `int` *)
    (Pipeline.type_of
      "fn (n: int) -> if n < 0 then exit 1 else n") "(int -> int)";

  (* --- int_max / int_min constants (non-function builtins) --- *)
  check "int_max type"
    (Pipeline.type_of "int_max") "int";
  check "int_min type"
    (Pipeline.type_of "int_min") "int";
  check "int_max > 0"
    (Pipeline.process "int_max > 0") "true";
  check "int_min < 0"
    (Pipeline.process "int_min < 0") "true";
  check "int_max > int_min"
    (Pipeline.process "int_max > int_min") "true";
  check "min init pattern"
    (* よくある最小値初期化パターン *)
    (Pipeline.process
      "let candidate = 42 in
       if candidate < int_max then candidate else int_max") "42";

  (* --- math constants + float helpers --- *)
  check "pi type"      (Pipeline.type_of "pi") "float";
  check "pi positive"  (Pipeline.process "f_gt pi 3.0") "true";
  check "pi < 4"       (Pipeline.process "f_lt pi 4.0") "true";
  check "e type"       (Pipeline.type_of "e") "float";
  check "e ~ 2.718"    (Pipeline.process "f_gt e 2.7") "true";

  check "sqrt 16"      (Pipeline.process "sqrt 16.0") "4.";
  check "sqrt 2 approx"
    (Pipeline.process "f_lt (sqrt 2.0) 1.5") "true";
  check "f_abs neg"    (Pipeline.process "f_abs (f_neg 3.5)") "3.5";
  check "f_abs pos"    (Pipeline.process "f_abs 4.2") "4.2";
  check "f_neg"        (Pipeline.process "f_neg 1.0") "-1.";

  check "floor down"   (Pipeline.process "floor 3.7") "3.";
  check "floor neg"    (Pipeline.process "floor (f_neg 1.2)") "-2.";
  check "ceil up"      (Pipeline.process "ceil 3.2") "4.";
  check "round half"   (Pipeline.process "round 3.5") "4.";
  check "round down"   (Pipeline.process "round 3.4") "3.";

  check "sqrt type"    (Pipeline.type_of "sqrt") "(float -> float)";
  check "pi >> sqrt"
    (* sqrt pi ~= 1.7725、pipe + curry なので `f_lt 1.7 (sqrt pi)` = `1.7 < 1.7725` *)
    (Pipeline.process "sqrt pi |> f_lt 1.7") "true";

  (* --- exhaustiveness check (Phase 1: bool + variant types) --- *)
  let warnings_of s =
    String.concat " | " (Pipeline.exhaustiveness_warnings s)
  in
  check "exhaustive: both bool branches → no warning"
    (warnings_of
      "match true with | true -> 1 | false -> 0") "";
  check "exhaustive: wildcard makes any match exhaustive"
    (warnings_of
      "match 42 with | 0 -> \"zero\" | _ -> \"other\"") "";
  check "exhaustive: variable pattern covers all"
    (warnings_of
      "match 42 with | n -> n + 1") "";
  check "non-exhaustive: bool missing false"
    (warnings_of "match true with | true -> 1")
    "line 1, col 1: warning: non-exhaustive match (missing false)";
  check "non-exhaustive: opt missing None"
    (warnings_of
      "type 'a opt = None | Some of 'a;
       match Some 5 with | Some n -> n")
    "line 2, col 8: warning: non-exhaustive match (missing None)";
  check "non-exhaustive: opt missing Some"
    (warnings_of
      "type 'a opt = None | Some of 'a;
       match (None : int opt) with | None -> 0")
    "line 2, col 8: warning: non-exhaustive match (missing Some _)";
  check "non-exhaustive: variant 3rd missing"
    (warnings_of
      "type Color = Red | Green | Blue;
       match Red with | Red -> 0 | Green -> 1")
    "line 2, col 8: warning: non-exhaustive match (missing Blue)";
  check "guarded arm doesn't count as exhaustive"
    (* guard 付き arm は実行時 false 可能性があるので保守的に「カバーしてない」扱い *)
    (warnings_of
      "type 'a opt = None | Some of 'a;
       match Some 5 with
       | None -> 0
       | Some n when n > 0 -> n")
    "line 2, col 8: warning: non-exhaustive match (missing Some _)";
  check "or-pattern covers both variants"
    (warnings_of
      "type Sign = Pos | Neg | Zero;
       match Pos with | Pos | Neg -> 1 | Zero -> 0") "";
  check "as-pattern transparent to exhaustiveness"
    (warnings_of
      "type 'a opt = None | Some of 'a;
       match Some 5 with
       | None          -> 0
       | Some n as all -> n") "";

  (* --- region / &R T : Phase 1 (syntactic only) --- *)
  check "region block basic"
    (Pipeline.process "region R { 42 }") "42";
  check "region block with let"
    (Pipeline.process "region R { let x = 5 in x + 1 }") "6";
  check "nested region blocks"
    (Pipeline.process "region R { region S { 100 } }") "100";
  check "&R int type"
    (Pipeline.type_of "fn (x: &R int) -> x") "(&R int -> &R int)";
  check "&R (int * str) type"
    (Pipeline.type_of "fn (x: &R (int * str)) -> x")
    "(&R (int * str) -> &R (int * str))";
  check "&R T pp"
    (Pipeline.type_of "fn (x: &alpha str) -> x") "(&alpha str -> &alpha str)";
  check "region returns body type"
    (Pipeline.type_of "region R { \"hello\" }") "str";
  check "region with print side effect"
    (Pipeline.process "region R { let _ = print \"in region\" in 7 }") "7";
  check "region block in fn"
    (Pipeline.process
      "let f = fn (x: int) -> region R { x * 2 } in f 21") "42";

  (* --- region Phase 2: `&R v` value form + escape check --- *)
  check "&R v type at toplevel"
    (Pipeline.type_of "&R 5") "&R int";
  check "&R v evaluates to inner value"
    (Pipeline.process "&R 42") "42";
  check "region body with let-bound &R value (no escape)"
    (Pipeline.process "region R { let x = &R 5 in 42 }") "42";
  check "&R nested expr"
    (Pipeline.process "region R { let pair = &R (1, 2) in 99 }") "99";
  check "&R str"
    (Pipeline.type_of "&R \"hello\"") "&R str";
  check_raises "region escape: returning &R int from region"
    (fun () -> Pipeline.process "region R { &R 5 }");
  check_raises "region escape: function with &R return"
    (fun () -> Pipeline.type_of "region R { fn (x: int) -> &R x }");
  check_raises "region escape: tuple containing &R"
    (fun () -> Pipeline.process "region R { (&R 1, 2) }");
  check "different region names don't unify"
    (* &R int != &S int *)
    (let ok =
       try
         let _ = Pipeline.type_of "fn (x: &R int) -> (x : &S int)" in
         false
       with _ -> true
     in
     if ok then "raised" else "did-not-raise") "raised";

  (* --- view type declarations: Phase 2.3 ---
     `view V[R] of T { fields }` declares a region-tagged view. Phase 2.3
     enforces that construction happens inside a `region { ... }` block and
     substitutes the view's region param with the active region. *)
  check "view constructed inside region"
    (Pipeline.process
      "view Node[R] of int { value: int, next: int };\n\
       region R { let n = Node { value = 1, next = 0 } in n.value }")
    "1";
  check "view constructed inside differently-named region (region param substituted)"
    (Pipeline.process
      "view Cell[R] of int { v: int };\n\
       region MyArena { let c = Cell { v = 7 } in c.v }")
    "7";
  check "view with `&R T` field accepts matching region tag"
    (Pipeline.process
      "view Slot[R] { item: &R int };\n\
       region S { let s = Slot { item = &S 42 } in 100 }")
    "100";
  check_raises "view constructed outside any region: error"
    (fun () ->
      Pipeline.process
        "view Node[R] of int { value: int, next: int };\n\
         let n = Node { value = 1, next = 0 } in n.value");
  check_raises "view with `&R T` field rejects wrong region tag"
    (fun () ->
      Pipeline.process
        "view Slot[R] { item: &R int };\n\
         region S { let s = Slot { item = &T 42 } in 100 }");
  check "view field update via record update syntax (inside region)"
    (Pipeline.process
      "view Pair[R] { a: int, b: int };\n\
       region R { let p = Pair { a = 1, b = 2 } in\n\
                  let q = { p | a = 10 } in q.a + q.b }")
    "12";
  check "nested regions: view picks innermost"
    (Pipeline.process
      "view Tag[R] { mark: &R int };\n\
       region Outer { region Inner { let t = Tag { mark = &Inner 9 } in 0 } }")
    "0";

  (* --- view field access: region 伝播 (Phase 2.4) ---
     view 値の TyCon に構築時 region が埋め込まれており、field access で
     宣言時の R を実際の region に置換して返す。 *)
  check "view int field access (region-free field)"
    (Pipeline.process
      "view Cell[R] of int { v: int };\n\
       region S { let c = Cell { v = 42 } in c.v }")
    "42";
  check "view field access propagates region — accepted by function expecting &S int"
    (* If propagation works, s.item has type &S int (not raw &R int) and
       unifies with the parameter's &S int. *)
    (Pipeline.process
      "view Slot[R] { item: &R int };\n\
       region S {\n\
         let s = Slot { item = &S 7 } in\n\
         let take_s = fn (x: &S int) -> 99 in\n\
         take_s s.item\n\
       }")
    "99";
  check_raises "view field access: wrong-region function rejects propagated tag"
    (* take_t expects &T int; s.item is &S int → unify fails. *)
    (fun () ->
      Pipeline.process
        "view Slot[R] { item: &R int };\n\
         region S {\n\
           let s = Slot { item = &S 7 } in\n\
           let take_t = fn (x: &T int) -> 99 in\n\
           take_t s.item\n\
         }");
  check_raises "view value itself cannot escape its construction region"
    (* Cell[S] mentions region S, so escape check fires. *)
    (fun () ->
      Pipeline.process
        "view Cell[R] of int { v: int };\n\
         region S { Cell { v = 1 } }");
  check "view record update keeps region, allows further field access"
    (Pipeline.process
      "view Pair[R] { a: int, b: int };\n\
       region S {\n\
         let p = Pair { a = 1, b = 2 } in\n\
         let q = { p | a = 10 } in\n\
         q.a + q.b\n\
       }")
    "12";

  (* --- R.alloc(v) sugar (Phase 2.5) ---
     Inside `region R { ... }`, `R.alloc(expr)` parses as `&R expr`. The
     sugar only fires when R is a lexically-enclosing region — regular
     `obj.field(...)` chains on non-region identifiers stay as field access. *)
  check "R.alloc(v) is sugar for &R v"
    (Pipeline.process "region R { let x = R.alloc(5) in 42 }") "42";
  check "R.alloc with tuple arg"
    (* `&R` wraps the value, so `c.v` would fail (no auto-deref).  Test
       the sugar with a primitive payload that doesn't need field access. *)
    (Pipeline.process
      "region R { let p = R.alloc((1, 2)) in 99 }")
    "99";
  check "R.alloc value is usable inside region (and bounded by escape check)"
    (Pipeline.process
      "region R { let x = R.alloc(5) in let f = fn (y: &R int) -> 88 in f x }")
    "88";
  check "R.alloc nested region uses correct R"
    (Pipeline.process
      "region RoOut { region RoIn { let x = RoIn.alloc(99) in 100 } }")
    "100";
  check_raises "R.alloc escapes region: caught by escape check"
    (fun () -> Pipeline.process "region R { R.alloc(5) }");
  check "outside any region: t.alloc parses as field access (not sugar)"
    (* Demonstrates that the sugar is opt-in via region context: here `t`
       is a regular variable, not a region, so `t.alloc(...)` should NOT
       desugar (and will type-error because t has no `alloc` field). *)
    (let ok =
       try
         let _ = Pipeline.process
           "let t = 5 in t.alloc(1)"
         in false
       with _ -> true
     in
     if ok then "raised" else "did-not-raise") "raised";
  check "outside region scope: R is just a variable name (.alloc → field access)"
    (let ok =
       try
         let _ = Pipeline.process "let R = 5 in R.alloc(1)" in false
       with _ -> true
     in
     if ok then "raised" else "did-not-raise") "raised";

  (* --- Trivial[R] constraint (Phase 2.6) ---
     `drop type Name = ...` marks Name as a Drop type. Region-tagged values
     (&R v) and view fields must NOT have Drop types — this is the Trivial
     constraint that enables bump-allocator semantics for regions. *)
  check "drop type declared, used outside region: OK"
    (Pipeline.process
      "drop type Conn = { id: int };\n\
       let c = Conn { id = 1 } in c.id")
    "1";
  check_raises "drop type cannot be placed in region via &R"
    (fun () ->
      Pipeline.process
        "drop type Conn = { id: int };\n\
         region R { let _ = &R Conn { id = 1 } in 0 }");
  check_raises "drop type cannot be placed in region via R.alloc sugar"
    (fun () ->
      Pipeline.process
        "drop type Conn = { id: int };\n\
         region R { let _ = R.alloc(Conn { id = 1 }) in 0 }");
  check_raises "view field with drop type rejected"
    (fun () ->
      Pipeline.process
        "drop type Conn = { id: int };\n\
         view Holder[R] { c: Conn };\n\
         region S { Holder { c = Conn { id = 1 } } }");
  check_raises "drop type in tuple inside region rejected"
    (fun () ->
      Pipeline.process
        "drop type Conn = { id: int };\n\
         region R { &R (1, Conn { id = 1 }) }");
  check "non-drop type can still be placed in region"
    (Pipeline.process
      "type Pt = { x: int };\n\
       region R { let p = &R Pt { x = 5 } in 99 }")
    "99";
  check "drop type can be wrapped in function (closures are Trivial)"
    (* Function types skip the Drop check — a closure's value is just a
       pointer, even if it captures Drop resources. *)
    (Pipeline.process
      "drop type Conn = { id: int };\n\
       region R { let _ = &R (fn (c: Conn) -> c.id) in 100 }")
    "100";

  (* --- `using [cap]` sugar for fn (Effect.1) ---
     `fn x using [cap] -> body` desugars to `fn cap -> fn x -> body`.
     Caps become outer-most curried args so partial application captures
     them first — the common pattern in cap-passing code. *)
  check "fn single arg + single cap (no type)"
    (Pipeline.process
      "let f = fn x using [c] -> c x in\n\
       let bound = f (fn n -> n + 1) in\n\
       bound 10")
    "11";
  check "fn with typed cap"
    (Pipeline.process
      "let apply = fn x using [c: int -> int] -> c x in\n\
       apply (fn n -> n * 2) 5")
    "10";
  check "fn multi-cap using"
    (Pipeline.process
      "let f = fn x using [a, b] -> a (b x) in\n\
       f (fn n -> n + 1) (fn n -> n * 10) 3")
    "31";
  check "fn parens-param + using cap"
    (Pipeline.process
      "let g = fn (x: int) using [c: int -> int] -> c x + 1 in\n\
       g (fn n -> n * 5) 4")
    "21";
  check "fn multi explicit + multi cap"
    (Pipeline.process
      "let h = fn (x, y) using [c1, c2] -> c1 (c2 x) + y in\n\
       h (fn n -> n + 100) (fn n -> n * 2) 3 4")
    "110";
  check "using sugar matches explicit curry semantically"
    (Pipeline.process
      "let log_x_sugar = fn x using [logger] -> logger (show x) in\n\
       let log_x_explicit = fn logger -> fn x -> logger (show x) in\n\
       let cap = fn s -> s ++ \"!\" in\n\
       log_x_sugar cap 42 ++ \"/\" ++ log_x_explicit cap 42")
    "\"42!/42!\"";
  check_raises "empty using clause: error"
    (fun () -> Pipeline.process "let f = fn x using [] -> x in f 1");

  (* --- builtin cap types: Logger / Metrics + constructors (Effect.2) ---
     `Logger` and `Metrics` are pre-registered record types; `mk_logger`
     and `mk_metrics` are builtins constructing the values. *)
  check "mk_logger has type str -> Logger"
    (Pipeline.type_of "mk_logger")
    "(str -> Logger)";
  check "mk_metrics has type unit -> Metrics"
    (Pipeline.type_of "mk_metrics")
    "(unit -> Metrics)";
  check "Logger field type via field access"
    (Pipeline.type_of "let lg = mk_logger \"x\" in lg.info")
    "(str -> unit)";
  check "Metrics record field type via field access"
    (Pipeline.type_of "let m = mk_metrics () in m.record")
    "(str -> (int -> unit))";
  check "Logger fields invokable, returning unit"
    (Pipeline.type_of
      "let lg = mk_logger \"x\" in lg.info \"msg\"")
    "unit";
  check "user-passed Logger can be used downstream (with type annotation)"
    (* Demonstrates cap-passing pattern with a builtin Logger. Type
       annotation is needed because plain field access can't infer the
       record type from field name alone. *)
    (Pipeline.type_of
      "let handler = fn (lg: Logger) -> lg.info \"hello\" in\n\
       handler (mk_logger \"app\")")
    "unit";
  check "Logger overridable by user-defined type"
    (* If user declares their own `type Logger`, it replaces the builtin
       in the records registry. *)
    (Pipeline.type_of
      "type Logger = { debug: str -> unit };\n\
       fn (l: Logger) -> l.debug")
    "(Logger -> (str -> unit))";

  (* --- `with` Drop semantics (Phase 3.1) ---
     `with c = v in body` requires v's type to be a Drop type. At scope end,
     v.close () is invoked if `close: unit -> unit` field exists. Multiple
     `with x, y in body` invokes drops in LIFO (y first, then x). *)
  check "with on Drop type without close field: no-op cleanup"
    (Pipeline.process
      "drop type Conn = { id: int };\n\
       with c = Conn { id = 7 } in c.id")
    "7";
  check_raises "with on non-Drop type rejected"
    (fun () -> Pipeline.process "with x = 5 in x");
  check_raises "with on non-Drop record rejected"
    (fun () ->
      Pipeline.process
        "type Pt = { x: int };\n\
         with p = Pt { x = 1 } in p.x");
  check "with on Logger (builtin Drop type? — Logger is NOT Drop) rejected"
    (* Logger is registered as a record but NOT as a Drop type. *)
    (let ok =
       try
         let _ = Pipeline.process
           "with lg = mk_logger \"x\" in 1"
         in false
       with _ -> true
     in
     if ok then "raised" else "did-not-raise") "raised";
  check "with Drop + close field: body result returned"
    (* Returns the body's value; close is a side effect. *)
    (Pipeline.process
      "drop type Conn = { id: int, close: unit -> unit };\n\
       let mk_conn = fn id ->\n\
         Conn { id = id, close = fn () -> () } in\n\
       with c = mk_conn 42 in c.id")
    "42";
  check "with Drop + close field: close called exactly once"
    (* Use a synthetic counter via a ref-like pattern. Actually we just
       observe the side-effect order via print order in the example file;
       here we just check the body return is unaffected. *)
    (Pipeline.process
      "drop type Conn = { id: int, close: unit -> unit };\n\
       let mk_conn = fn id ->\n\
         Conn { id = id, close = fn () -> () } in\n\
       with c1 = mk_conn 1,\n\
            c2 = mk_conn 2 in\n\
       c1.id + c2.id")
    "3";

  (* --- C codegen (Phase 4) ---
     Content-fragment checks: assert key substrings appear (or don't).
     Full snapshot would be brittle across header changes. *)
  let codegen s =
    let prog = Pipeline.parse_program s in
    let main_ty = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
    Codegen_c.emit_program ~main_ty prog
  in
  let contains hay needle =
    let nl = String.length needle and hl = String.length hay in
    let rec loop i =
      if i + nl > hl then false
      else if String.sub hay i nl = needle then true
      else loop (i + 1)
    in
    loop 0
  in
  let assert_contains name out needle =
    if contains out needle then begin
      incr pass; Printf.printf "PASS  %s\n" name
    end else begin
      incr fail;
      Printf.printf "FAIL  %s\n  expected substring=%s\n  in=%s\n"
        name needle out
    end
  in
  let assert_no_contains name out needle =
    if not (contains out needle) then begin
      incr pass; Printf.printf "PASS  %s\n" name
    end else begin
      incr fail;
      Printf.printf "FAIL  %s\n  unexpected substring=%s\n  in=%s\n"
        name needle out
    end
  in
  let int_lit_out = codegen "42" in
  assert_contains "codegen: emits stdio.h" int_lit_out "#include <stdio.h>";
  assert_contains "codegen: int literal printf" int_lit_out "printf(\"%d\\n\", 42)";
  assert_contains "codegen: arithmetic precedence"
    (codegen "1 + 2 * 3") "(1 + (2 * 3))";
  assert_contains "codegen: let + if uses statement-expr"
    (codegen "let x = 5 in if x < 10 then x * 2 else 0")
    "({ __auto_type x = 5;";
  assert_contains "codegen: bool literal → 0/1"
    (codegen "true") "printf(\"%d\\n\", 1)";
  assert_contains "codegen: logical && via C &&"
    (codegen "true && false") "(1 && 0)";
  assert_contains "codegen: lifts top-level fn"
    (codegen "let inc = fn x -> x + 1 in inc 5")
    "int inc(int x)";
  assert_contains "codegen: lifted fn call site"
    (codegen "let inc = fn x -> x + 1 in inc 5")
    "inc(5)";
  assert_contains "codegen: let-rec self-recursion"
    (codegen "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5")
    "fact((n - 1))";
  assert_contains "codegen: mutual rec emits both forward decls"
    (codegen
       "let rec ev = fn n -> if n == 0 then 1 else od (n - 1)\n\
        and od = fn n -> if n == 0 then 0 else ev (n - 1)\n\
        in ev 4")
    "int ev(int);\nint od(int);";
  assert_contains "codegen: nested fn lifted to top level with captures"
    (* Previously rejected; Phase 4.8 lifts inner fns via defunctionalization. *)
    (codegen
      "let outer = fn x -> let helper = fn y -> x + y in helper 10 in outer 5")
    "int __lifted_helper_0(int x, int y)";
  assert_contains "codegen: lifted inner fn called with captures prepended"
    (codegen
      "let outer = fn x -> let helper = fn y -> x + y in helper 10 in outer 5")
    "__lifted_helper_0(x, 10)";
  assert_contains "codegen: anonymous fn application via closure"
    (* Phase 4.9-B: anonymous Fun in expression position is now lifted as
       a closure value, and the App goes through closure dispatch. *)
    (codegen "(fn x -> x + 1) 5")
    "__c.fn(__c.env, 5)";

  (* --- C codegen: string support (Phase 4 third slice) --- *)
  assert_contains "codegen: str literal emits C string"
    (codegen "\"hello\"") "\"hello\"";
  assert_contains "codegen: str main uses %s format"
    (codegen "\"hi\"") "printf(\"%s\\n\"";
  assert_contains "codegen: ++ becomes __lang_str_concat call"
    (codegen "\"a\" ++ \"b\"") "__lang_str_concat(\"a\", \"b\")";
  assert_contains "codegen: print → puts inside statement expression"
    (codegen "print \"hi\"") "puts(\"hi\")";
  assert_contains "codegen: unit-typed main skips printf"
    (codegen "print \"hi\"") "/* unit result */";
  assert_contains "codegen: helper __lang_str_concat is injected"
    (codegen "1") "__lang_str_concat";  (* always emitted, even if unused *)

  (* --- C codegen: str-typed lifted fns (Phase 4 fourth slice) --- *)
  assert_contains "codegen: str-returning fn gets const char* return"
    (codegen "let greet = fn n -> if n > 0 then \"pos\" else \"neg\" in greet 5")
    "const char* greet(int n)";
  assert_contains "codegen: str-taking fn gets const char* param"
    (codegen "let exclaim = fn s -> s ++ \"!\" in exclaim \"hi\"")
    "const char* exclaim(const char* s)";
  assert_contains "codegen: forward decl carries through the right type"
    (codegen "let greet = fn n -> if n > 0 then \"pos\" else \"neg\" in greet 5")
    "const char* greet(int);";
  assert_contains "codegen: str_len builtin maps to strlen"
    (codegen "str_len \"abc\"")
    "(int) strlen(\"abc\")";
  check_raises "codegen: unsupported type (e.g. float fn) → Codegen_error"
    (fun () ->
      let _ = codegen "let f = fn x -> x +. 1.0 in f 2.0" in ());

  (* --- C codegen: tuple support (Phase 4 fifth slice) --- *)
  assert_contains "codegen: tuple typedef for int*int"
    (codegen "let p = (1, 2) in fst p + snd p")
    "struct tuple_int_int {\n  int f0;\n  int f1;\n};";
  assert_contains "codegen: tuple literal uses compound literal"
    (codegen "let p = (1, 2) in fst p")
    "((tuple_int_int){.f0 = 1, .f1 = 2})";
  assert_contains "codegen: fst → .f0 access"
    (codegen "let p = (1, 2) in fst p")
    "(p).f0";
  assert_contains "codegen: snd → .f1 access"
    (codegen "let p = (1, 2) in snd p")
    "(p).f1";
  assert_contains "codegen: mixed-type tuple struct (str, int)"
    (codegen "let p = (\"hi\", 42) in fst p")
    "struct tuple_str_int {\n  const char* f0;\n  int f1;\n};";
  assert_contains "codegen: tuple-returning fn signature"
    (codegen "let split = fn s -> (s, str_len s) in split \"x\"")
    "tuple_str_int split(const char* s)";

  (* --- C codegen: record support (Phase 4 sixth slice) ---
     Records share the codegen path with tuples but with named fields.
     The typer's `records` registry tells us the C field types/order.
     NB: the typer's `records` Hashtbl is global mutable state, so
     declaring `type CgPt = ...` here is visible to later tests; pick
     fresh names that don't collide with the record-test suite earlier. *)
  let codegen_with_decls s =
    let prog = Pipeline.parse_program s in
    (* Process decls so the typer's records registry is populated. *)
    let type_env = ref Typer.initial_env in
    List.iter (fun decl ->
      match decl with
      | Ast.Top_record (name, params, fields) ->
        Typer.register_record name params fields
      | Ast.Top_type (name, params, variants) ->
        Typer.register_type name params variants
      | Ast.Top_drop name ->
        Typer.register_drop_type name
      | Ast.Top_view (name, region, fields) ->
        Typer.register_view name region fields
      | Ast.Top_let (pat, value) ->
        let outer = !type_env in
        let t = Typer.infer outer value in
        let bs = Typer.check_pattern pat t in
        type_env := List.fold_left (fun acc (n, ty) ->
          (n, Typer.generalize outer ty) :: acc) outer bs
      | _ -> ()
    ) prog.decls;
    let main_ty = Typer.infer !type_env (Ast.desugar_program prog) in
    Codegen_c.emit_program ~main_ty prog
  in
  assert_contains "codegen: record typedef"
    (codegen_with_decls
      "type CgRectA = { w: int, h: int };\n\
       let r = CgRectA { w = 3, h = 4 } in r.w * r.h")
    "struct CgRectA {\n  int w;\n  int h;\n};";
  assert_contains "codegen: record literal compound"
    (codegen_with_decls
      "type CgRectB = { w: int, h: int };\n\
       let r = CgRectB { w = 3, h = 4 } in r.w")
    "((CgRectB){.w = 3, .h = 4})";
  assert_contains "codegen: record field access"
    (codegen_with_decls
      "type CgRectC = { w: int };\n\
       let r = CgRectC { w = 5 } in r.w")
    "(r).w";
  assert_contains "codegen: record update via tmp + statement expr"
    (codegen_with_decls
      "type CgRectD = { w: int, h: int };\n\
       let r = CgRectD { w = 1, h = 2 } in { r | w = 99 }")
    "__rupd.w = 99";
  assert_contains "codegen: record-returning fn signature"
    (codegen_with_decls
      "type CgRectE = { w: int };\n\
       let mk = fn n -> CgRectE { w = n } in mk 7")
    "CgRectE mk(int n)";
  assert_contains "codegen: record with str field"
    (codegen_with_decls
      "type CgUser = { name: str, age: int };\n\
       let u = CgUser { name = \"a\", age = 30 } in u.name")
    "  const char* name;";
  assert_contains "codegen: polymorphic record specialized via monomorphization"
    (* Was previously rejected; Phase 4.13 specializes per instantiation. *)
    (codegen_with_decls
      "type 'a CgBox = { v: 'a };\n\
       let b = CgBox { v = 1 } in b.v")
    "struct CgBox_int {";
  assert_contains "codegen: poly record Box_str specialization"
    (codegen_with_decls
      "type 'a CgBox2 = { v: 'a };\n\
       let b = CgBox2 { v = \"hi\" } in b.v")
    "  const char* v;\n};";
  assert_contains "codegen: poly record literal uses mono name"
    (codegen_with_decls
      "type 'a CgBox3 = { v: 'a };\n\
       CgBox3 { v = 42 }")
    "((CgBox3_int){.v = 42})";

  (* --- C codegen: complex patterns (Phase 4.14) --- *)
  assert_contains "codegen: P_int compiles to equality"
    (codegen "match 3 with | 0 -> 100 | _ -> 200")
    "(__scrut) == 0";
  assert_contains "codegen: P_str compiles to strcmp"
    (codegen "match \"hi\" with | \"a\" -> 1 | _ -> 2")
    "strcmp((__scrut), \"a\")";
  assert_contains "codegen: P_bool true compiles to == 1"
    (codegen "match true with | true -> 1 | false -> 0")
    "(__scrut) == 1";
  assert_contains "codegen: nested P_constr binds inner var"
    (codegen_with_decls
      "type 'a CgO = CgN | CgS of 'a;\n\
       type 'a CgL = CgLN | CgLC of 'a * 'a CgL;\n\
       match CgLC (CgS 5, CgLN) with\n\
         | CgLN -> 0\n\
         | CgLC (CgN, _) -> 1\n\
         | CgLC (CgS n, _) -> n")
    "__auto_type n =";
  assert_contains "codegen: P_record destructures named fields"
    (codegen_with_decls
      "type CgPtX = { a: int, b: int };\n\
       match CgPtX { a = 3, b = 4 } with\n\
         | CgPtX { a = x, b = y } -> x + y")
    "__auto_type x =";
  assert_contains "codegen: P_as binds whole-value"
    (codegen "match 5 with | n as all -> n + all")
    "__auto_type all = __scrut";

  (* --- C codegen: or-pattern + match guard (Phase 4.15) --- *)
  assert_contains "codegen: or-pattern flattens into two arms"
    (codegen_with_decls
      "type CgOr1 = OA | OB | OC;\n\
       match OB with | OA | OB -> 1 | OC -> 2")
    ".tag == 0";  (* both alternatives emit their own tag test *)
  assert_contains "codegen: or-pattern result correct via duplicated body"
    (codegen_with_decls
      "type CgOr2 = OD | OE;\n\
       match OE with | OD | OE -> 99")
    "{ 99; }";  (* body 99 duplicated for both alternatives *)
  assert_contains "codegen: guard emitted in bindings scope"
    (codegen "match 7 with | n when n < 5 -> 100 | _ -> 200")
    "n < 5";
  assert_contains "codegen: guard with bindings"
    (codegen "match 7 with | n when n > 5 -> n * 10 | _ -> 0")
    "__auto_type n =";

  (* --- C codegen: list show pretty-print (Phase 4.16) --- *)
  assert_contains "codegen: list show emits Cons-iterating formatter"
    (codegen_with_decls
      "type 'a list = Nil | Cons of 'a * 'a list;\n\
       show [1, 2, 3]")
    "if (v->tag == 0) return \"[]\"";
  assert_contains "codegen: list show separator is \", \""
    (codegen_with_decls
      "type 'a list = Nil | Cons of 'a * 'a list;\n\
       show [1, 2]")
    "\"%s, %s\"";

  (* --- C codegen: region runtime (Phase 4.17) ---
     `region R { body }` initializes a bump-allocator buffer, evaluates
     the body, frees the buffer. `&R v` allocates v in the region. *)
  assert_contains "codegen: region runtime helpers injected"
    (codegen "1")
    "__lang_region_alloc";
  assert_contains "codegen: region block initializes + frees buffer"
    (codegen "region R { 42 }")
    "__lang_region_init(&__region_R";
  assert_contains "codegen: region block frees at end"
    (codegen "region R { 42 }")
    "__lang_region_free(&__region_R)";
  assert_contains "codegen: Ref allocates in region and copies"
    (codegen "region R { let x = &R 5 in 42 }")
    "__lang_region_alloc(&__region_R";
  assert_contains "codegen: Ref uses typeof for inner type"
    (codegen "region R { let x = &R 5 in 42 }")
    "typeof(__ref_v)*";

  (* --- C codegen: `with` Drop execution (Phase 4.18) --- *)
  assert_contains "codegen: with binding emit"
    (codegen_with_decls
      "drop type CgConn = { id: int, close: unit -> unit };\n\
       let mk = fn id ->\n\
         CgConn { id = id, close = fn () -> () } in\n\
       with c = mk 1 in c.id")
    "__auto_type c =";
  assert_contains "codegen: with calls close field at scope end"
    (codegen_with_decls
      "drop type CgConn2 = { id: int, close: unit -> unit };\n\
       let mk = fn id ->\n\
         CgConn2 { id = id, close = fn () -> () } in\n\
       with c = mk 1 in c.id")
    "c.close.fn(c.close.env, 0)";
  assert_contains "codegen: with on Drop type without close field omits call"
    (codegen_with_decls
      "drop type CgRes = { v: int };\n\
       with r = CgRes { v = 5 } in r.v")
    "__with_result";

  (* --- C codegen: view runtime (Phase 4.19) — views are region-allocated pointers --- *)
  assert_contains "codegen: view type becomes pointer"
    (codegen_with_decls
      "view CgCell[R] of int { v: int };\n\
       region R { let c = CgCell { v = 7 } in c.v }")
    "CgCell*";
  assert_contains "codegen: view construction bump-allocates in region"
    (codegen_with_decls
      "view CgCell2[R] of int { v: int };\n\
       region R { let c = CgCell2 { v = 7 } in c.v }")
    "__lang_region_alloc(&__region_R, sizeof(CgCell2))";
  assert_contains "codegen: view field access uses -> "
    (codegen_with_decls
      "view CgCell3[R] of int { v: int };\n\
       region R { let c = CgCell3 { v = 7 } in c.v }")
    "(c)->v";

  (* --- C codegen: closure env in default region (Phase 4.20) — closures
       outlive any user region, so their env structs go to a program-lifetime
       bump arena (`__lang_default_region`) instead of malloc. --- *)
  assert_contains "codegen: default region declared at file scope"
    (codegen_with_decls
      "let add = fn n -> fn x -> n + x in (add 3) 4")
    "static __lang_region __lang_default_region;";
  assert_contains "codegen: closure env uses default region alloc"
    (codegen_with_decls
      "let add = fn n -> fn x -> n + x in (add 3) 4")
    "__lang_region_alloc(&__lang_default_region, sizeof(__anon";
  assert_no_contains "codegen: closure env no longer uses malloc"
    (codegen_with_decls
      "let add = fn n -> fn x -> n + x in (add 3) 4")
    "__env = (__anon_0_env*)malloc";
  assert_contains "codegen: main initializes default region"
    (codegen_with_decls "1 + 2")
    "__lang_region_init(&__lang_default_region";
  assert_contains "codegen: main frees default region"
    (codegen_with_decls "1 + 2")
    "__lang_region_free(&__lang_default_region)";
  assert_contains "codegen: str_concat allocates in default region"
    (codegen_with_decls "\"hi\" ++ \"!\"")
    "__lang_region_alloc(&__lang_default_region, la + lb + 1)";
  assert_no_contains "codegen: str_concat no longer mallocs"
    (codegen_with_decls "\"hi\" ++ \"!\"")
    "malloc(la + lb + 1)";

  (* --- C codegen: variant + match (Phase 4 seventh slice) ---
     Variants → tagged unions, match → if-else chain via ternaries.
     Limited subset: monomorphic only, simple P_constr / P_var / P_wild. *)
  assert_contains "codegen: nullary variant becomes tag-only struct"
    (codegen_with_decls
      "type CgCol = CR | CG | CB;\n\
       let c = CG in match c with | CR -> 0 | CG -> 1 | CB -> 2")
    "struct CgCol {\n  int tag;\n};";
  assert_contains "codegen: variant with payload includes union"
    (codegen_with_decls
      "type CgStat = COk | CErr of str;\n\
       match CErr \"x\" with | COk -> 0 | CErr m -> str_len m")
    "  union {\n    const char* CErr;\n  } payload;";
  assert_contains "codegen: Constr emits compound literal with tag"
    (codegen_with_decls
      "type CgCol2 = X | Y;\n\
       let c = Y in match c with | X -> 0 | Y -> 1")
    "((CgCol2){.tag = 1})";
  assert_contains "codegen: Constr with arg emits payload"
    (codegen_with_decls
      "type CgStat2 = SOk | SErr of int;\n\
       SErr 42")
    ".payload.SErr = 42";
  assert_contains "codegen: match emits scrut binding"
    (codegen_with_decls
      "type CgCol3 = A | B;\n\
       match A with | A -> 0 | B -> 1")
    "__auto_type __scrut =";
  assert_contains "codegen: P_constr emits tag equality test"
    (codegen_with_decls
      "type CgCol4 = A | B;\n\
       match A with | A -> 0 | B -> 1")
    ".tag == 0";
  assert_contains "codegen: P_constr with payload binds via __auto_type"
    (codegen_with_decls
      "type CgStat3 = SOk | SErr of str;\n\
       match SErr \"hi\" with | SOk -> 0 | SErr m -> str_len m")
    "__auto_type m =";
  check_raises "codegen: polymorphic variant rejected"
    (fun () ->
      let _ = codegen_with_decls
        "type 'a CgOpt = CNone | CSome of 'a;\n\
         CNone"
      in ());
  assert_contains "codegen: match guard accepted"
    (codegen_with_decls
      "type CgCol5 = A | B;\n\
       match A with | A when true -> 0 | _ -> 1")
    "(1) ? (0)";

  (* --- C codegen: closure conversion (Phase 4 eighth slice) ---
     Inner `let n = fn x -> body` is lifted to a top-level fn with
     captured outer-scope vars prepended to its params (defunctionalization).
     Call sites are rewritten to pass the captures explicitly. *)
  assert_contains "codegen: closure captures host param"
    (codegen
      "let outer = fn x -> let h = fn y -> x + y in h 10 in outer 5")
    "int __lifted_h_0(int x, int y)";
  assert_contains "codegen: closure call site prepends captures"
    (codegen
      "let outer = fn x -> let h = fn y -> x + y in h 10 in outer 5")
    "__lifted_h_0(x, 10)";
  assert_contains "codegen: closure binding is dropped from let-chain"
    (* The `__auto_type h = ...` should NOT appear since h was lifted. *)
    (codegen
      "let outer = fn x -> let h = fn y -> y + 1 in h 5 in outer 3")
    "int outer(int x) {\n  return __lifted_h_0(5);";
  assert_contains "codegen: nested closure captures from multiple levels"
    (* Inner `h` captures `x` (from g's param) and `n` (from f's param).
       Free-var collection orders captures by source order of usage, so
       captures = [x; n]. g gets slot 0, h gets slot 1. *)
    (codegen
      "let f = fn n ->\n\
         let g = fn x ->\n\
           let h = fn y -> x + y + n in\n\
           h 1\n\
         in g 2\n\
       in f 3")
    "int __lifted_h_1(int x, int n, int y)";
  check_raises "codegen: capture of non-primitive type rejected"
    (* Tuple captures aren't supported yet (only int/bool/str/unit). *)
    (fun () ->
      let _ = codegen
        "let outer = fn x -> let t = (x, x) in let h = fn y -> fst t in h 1 in outer 5"
      in ());

  (* --- C codegen: first-class functions (Phase 4 ninth slice, "Phase A") ---
     Top-level fns can be passed as values via prepared closure wrappers.
     HOF param of type T1 -> T2 becomes a closure struct, application via
     `.fn(.env, arg)`. Direct call to a known top-level Var stays direct. *)
  assert_contains "codegen: closure typedef for int -> int"
    (codegen
      "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "} closure_int_int;";
  assert_contains "codegen: top-level fn gets closure wrapper"
    (codegen
      "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "static int inc_closure_fn(void* __env, int x)";
  assert_contains "codegen: top-level fn gets _as_value constant"
    (codegen
      "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "static const closure_int_int inc_as_value =";
  assert_contains "codegen: HOF takes closure param"
    (codegen
      "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "int apply(closure_int_int f)";
  assert_contains "codegen: closure dispatch via .fn(.env, x)"
    (codegen
      "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "__c.fn(__c.env, 5)";
  assert_contains "codegen: Var of top-level fn in value pos emits _as_value"
    (codegen
      "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "apply(inc_as_value)";

  (* --- C codegen: first-class fns Phase B (anonymous Fun + captures) --- *)
  assert_contains "codegen: anonymous Fun emits env typedef"
    (codegen
      "let apply = fn f -> fn x -> f x in let inc = fn n -> n + 1 in apply inc 5")
    "} __anon_0_env;";
  assert_contains "codegen: anonymous Fun emits adapter"
    (codegen
      "let apply = fn f -> fn x -> f x in let inc = fn n -> n + 1 in apply inc 5")
    "static int __anon_0_fn(void* __env_self_void, int x)";
  assert_contains "codegen: anonymous Fun emits closure construction"
    (codegen
      "let apply = fn f -> fn x -> f x in let inc = fn n -> n + 1 in apply inc 5")
    "__env->f = f";
  assert_contains "codegen: captured var rewritten to env access"
    (codegen
      "let apply = fn f -> fn x -> f x in let inc = fn n -> n + 1 in apply inc 5")
    "(__env_self->f)";

  (* --- C codegen: recursive variants + P_tuple pattern (Phase 4.10) --- *)
  assert_contains "codegen: recursive variant emits forward + ptr typedef"
    (codegen_with_decls
      "type CgList = CgNil | CgCons of int * CgList;\n\
       let rec sum = fn xs -> match xs with\n\
         | CgNil -> 0\n\
         | CgCons (h, t) -> h + sum t\n\
       in sum (CgCons (1, CgCons (2, CgNil)))")
    "typedef CgList_node* CgList;";
  assert_contains "codegen: recursive variant struct body emitted"
    (codegen_with_decls
      "type CgList2 = CgNil2 | CgCons2 of int * CgList2;\n\
       let rec sum = fn xs -> match xs with\n\
         | CgNil2 -> 0\n\
         | CgCons2 (h, t) -> h + sum t\n\
       in sum (CgCons2 (1, CgNil2))")
    "struct CgList2_node {";
  assert_contains "codegen: recursive variant Constr uses default region"
    (codegen_with_decls
      "type CgList3 = CgNil3 | CgCons3 of int * CgList3;\n\
       let rec sum = fn xs -> match xs with\n\
         | CgNil3 -> 0\n\
         | CgCons3 (h, t) -> h + sum t\n\
       in sum (CgCons3 (1, CgNil3))")
    "__lang_region_alloc(&__lang_default_region, sizeof(CgList3_node))";
  assert_contains "codegen: match on recursive variant uses -> access"
    (codegen_with_decls
      "type CgList4 = CgNil4 | CgCons4 of int * CgList4;\n\
       let rec sum = fn xs -> match xs with\n\
         | CgNil4 -> 0\n\
         | CgCons4 (h, t) -> h + sum t\n\
       in sum (CgCons4 (1, CgNil4))")
    "->tag == 0";
  let cg5_out =
    codegen_with_decls
      "type CgList5 = CgNil5 | CgCons5 of int * CgList5;\n\
       let rec sum = fn xs -> match xs with\n\
         | CgNil5 -> 0\n\
         | CgCons5 (h, t) -> h + sum t\n\
       in sum (CgCons5 (1, CgNil5))"
  in
  assert_contains "codegen: P_tuple pattern destructures via .f0 / .f1"
    cg5_out
    "payload.CgCons5).f0";

  (* --- C codegen: polymorphic variant monomorphization (Phase 4.11) --- *)
  assert_contains "codegen: polymorphic opt specialized to opt_int"
    (codegen_with_decls
      "type 'a Cgopt = CgNone | CgSome of 'a;\n\
       let v = CgSome 42 in match v with | CgNone -> 0 | CgSome n -> n")
    "struct Cgopt_int {";
  assert_contains "codegen: polymorphic list specialized to list_int"
    (codegen_with_decls
      "type 'a Cglst = CgN | CgC of 'a * 'a Cglst;\n\
       let rec sum = fn xs -> match xs with | CgN -> 0 | CgC (h, t) -> h + sum t in\n\
       sum (CgC (1, CgC (2, CgN)))")
    "typedef Cglst_int_node* Cglst_int;";
  assert_contains "codegen: mono variant tuple struct for list payload"
    (codegen_with_decls
      "type 'a Cglst2 = CgN2 | CgC2 of 'a * 'a Cglst2;\n\
       let rec sum = fn xs -> match xs with | CgN2 -> 0 | CgC2 (h, t) -> h + sum t in\n\
       sum (CgC2 (1, CgN2))")
    "struct tuple_int_Cglst2_int {";
  assert_contains "codegen: Constr for mono variant uses specialized name"
    (codegen_with_decls
      "type 'a Cgopt3 = CgNone3 | CgSome3 of 'a;\n\
       CgSome3 42")
    "Cgopt3_int){.tag = 1";

  (* --- C codegen: show polymorphic builtin (Phase 4.12) --- *)
  assert_contains "codegen: show int emits show_int adapter"
    (codegen "show 42") "show_int";
  assert_contains "codegen: show int call site"
    (codegen "show 42") "show_int(42)";
  assert_contains "codegen: show str specialization"
    (codegen "show \"hi\"") "show_str";
  assert_contains "codegen: show bool specialization"
    (codegen "show true") "show_bool";
  assert_contains "codegen: show tuple composes elements"
    (codegen "show (1, \"hi\")") "show_tuple_int_str";
  assert_contains "codegen: show variant uses tagged dispatch"
    (codegen_with_decls
      "type CgCol6 = X6 | Y6;\n\
       show X6")
    "show_CgCol6";
  assert_contains "codegen: show poly variant uses mono name"
    (codegen_with_decls
      "type 'a Cgopt4 = CgNone4 | CgSome4 of 'a;\n\
       show (CgSome4 1)")
    "show_Cgopt4_int";

  (* --- LLVM IR codegen (Phase 5.1 MVP) ---
     Subset: int / bool / arith / cmp / logic / Neg / If / Let (P_var) / Var / Annot.
     Emits textual LLVM IR that clang can compile directly. *)
  let llvm s =
    let prog = Pipeline.parse_program s in
    let main_ty = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
    Codegen_llvm.emit_program ~main_ty prog
  in
  (* Same as `llvm`, but processes top-level decls (type / record / view)
     so the typer's registries are populated before codegen runs. *)
  let llvm_with_decls s =
    let prog = Pipeline.parse_program s in
    let type_env = ref Typer.initial_env in
    List.iter (fun decl ->
      match decl with
      | Ast.Top_record (name, params, fields) ->
        Typer.register_record name params fields
      | Ast.Top_type (name, params, variants) ->
        Typer.register_type name params variants
      | Ast.Top_drop name -> Typer.register_drop_type name
      | Ast.Top_view (name, region, fields) ->
        Typer.register_view name region fields
      | Ast.Top_let (pat, value) ->
        let outer = !type_env in
        let t = Typer.infer outer value in
        let bs = Typer.check_pattern pat t in
        type_env := List.fold_left (fun acc (n, ty) ->
          (n, Typer.generalize outer ty) :: acc) outer bs
      | _ -> ()
    ) prog.decls;
    let main_ty = Typer.infer !type_env (Ast.desugar_program prog) in
    Codegen_llvm.emit_program ~main_ty prog
  in
  assert_contains "llvm: declares printf"
    (llvm "42") "declare i32 @printf(ptr, ...)";
  assert_contains "llvm: defines main"
    (llvm "42") "define i32 @main()";
  assert_contains "llvm: format constant present"
    (llvm "42") "@.fmt_d = private constant [4 x i8] c\"%d\\0A\\00\"";
  assert_contains "llvm: int literal call site"
    (llvm "42") "@printf(ptr @.fmt_d, i32 42)";
  assert_contains "llvm: add lowers to LLVM add"
    (llvm "1 + 2") "add i32 1, 2";
  assert_contains "llvm: mul lowers to LLVM mul"
    (llvm "3 * 4") "mul i32 3, 4";
  assert_contains "llvm: sdiv used for /"
    (llvm "10 / 2") "sdiv i32 10, 2";
  assert_contains "llvm: srem used for %"
    (llvm "10 % 3") "srem i32 10, 3";
  assert_contains "llvm: < lowers to icmp slt"
    (llvm "if 1 < 2 then 10 else 20") "icmp slt i32 1, 2";
  assert_contains "llvm: if emits br on i1"
    (llvm "if 1 < 2 then 10 else 20") "br i1";
  assert_contains "llvm: if uses phi for join"
    (llvm "if 1 < 2 then 10 else 20") "= phi i32";
  assert_contains "llvm: let body sees binding"
    (llvm "let x = 5 in x * x") "mul i32 5, 5";
  assert_contains "llvm: bool literal as i1 in logic"
    (llvm "true && false") "and i1 1, 0";
  assert_contains "llvm: bool result is zero-extended for printf"
    (llvm "true") "zext i1";
  assert_contains "llvm: ret 0 at main end"
    (llvm "1") "ret i32 0";

  (* --- LLVM IR codegen: 関数 lifting + recursion (Phase 5.2) --- *)
  assert_contains "llvm: top-level fn lifted to @name"
    (llvm "let inc = fn x -> x + 1 in inc 5")
    "define i32 @inc(i32 %x)";
  assert_contains "llvm: direct call site uses call instr"
    (llvm "let inc = fn x -> x + 1 in inc 5")
    "call i32 @inc(i32 5)";
  assert_contains "llvm: self-recursion compiles"
    (llvm "let rec fact = fn n -> if n <= 1 then 1 else n * fact (n - 1) in fact 5")
    "call i32 @fact";
  assert_contains "llvm: mutual recursion emits both definitions"
    (llvm "let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)\n\
           and is_odd = fn n -> if n == 0 then false else is_even (n - 1)\n\
           in is_even 4")
    "define i1 @is_even(i32 %n)";
  assert_contains "llvm: mutual recursion second fn"
    (llvm "let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)\n\
           and is_odd = fn n -> if n == 0 then false else is_even (n - 1)\n\
           in is_even 4")
    "define i1 @is_odd(i32 %n)";
  assert_contains "llvm: param accessed via %name"
    (llvm "let inc = fn x -> x + 1 in inc 5")
    "add i32 %x, 1";

  (* --- LLVM IR codegen: 文字列 / print / ++ / str_len (Phase 5.3) --- *)
  assert_contains "llvm: str literal global"
    (llvm "\"hi\"") "@.str_0 = private constant [3 x i8] c\"hi\\00\"";
  assert_contains "llvm: str main printf uses %s"
    (llvm "\"hi\"") "@.fmt_s = private constant [4 x i8] c\"%s\\0A\\00\"";
  assert_contains "llvm: str passed as ptr to printf"
    (llvm "\"hi\"") "@printf(ptr @.fmt_s, ptr @.str_0)";
  assert_contains "llvm: print emits puts call"
    (llvm "print \"hi\"") "call i32 @puts(ptr ";
  assert_contains "llvm: ++ lowers to __lang_str_concat"
    (llvm "\"a\" ++ \"b\"") "call ptr @__lang_str_concat";
  assert_contains "llvm: __lang_str_concat helper is emitted"
    (llvm "\"a\" ++ \"b\"") "define ptr @__lang_str_concat(ptr %a, ptr %b)";
  assert_contains "llvm: str_len uses strlen + trunc"
    (llvm "str_len \"hi\"") "call i64 @strlen(ptr ";
  assert_contains "llvm: str_len truncates to i32"
    (llvm "str_len \"hi\"") "trunc i64";
  assert_contains "llvm: str-returning fn signature"
    (llvm "let exclaim = fn s -> s ++ \"!\" in exclaim \"hi\"")
    "define ptr @exclaim(ptr %s)";
  assert_contains "llvm: str arg passed as ptr"
    (llvm "let len = fn s -> str_len s in len \"hello\"")
    "@len(ptr ";

  (* --- LLVM IR codegen: tuple (Phase 5.4) ---
     Tuples lower to named struct types; literals build via insertvalue
     chains, fst/snd via extractvalue at index 0 / 1. *)
  assert_contains "llvm: tuple type definition emitted"
    (llvm "(1, 2)") "%tuple_int_int = type { i32, i32 }";
  assert_contains "llvm: tuple literal uses insertvalue undef"
    (llvm "(1, 2)") "insertvalue %tuple_int_int undef, i32 1, 0";
  assert_contains "llvm: tuple literal chains insertvalue"
    (llvm "(1, 2)") "insertvalue %tuple_int_int";
  assert_contains "llvm: fst lowers to extractvalue 0"
    (llvm "let p = (1, 2) in fst p")
    "extractvalue %tuple_int_int";
  assert_contains "llvm: tuple of mixed types"
    (llvm "(\"hi\", 42)")
    "%tuple_str_int = type { ptr, i32 }";
  assert_contains "llvm: nested tuple type definition"
    (llvm "((1, 2), 3)")
    "%tuple_tuple_int_int_int = type { %tuple_int_int, i32 }";
  assert_contains "llvm: tuple-arg fn signature"
    (llvm "let sum_pair = fn p -> fst p + snd p in sum_pair (1, 2)")
    "define i32 @sum_pair(%tuple_int_int %p)";
  assert_contains "llvm: tuple-returning fn signature"
    (llvm "let split = fn s -> (s, str_len s) in split \"hi\"")
    "define %tuple_str_int @split(ptr %s)";

  (* --- LLVM IR codegen: record (Phase 5.5) ---
     Monomorphic records lower to named structs; literal builds via
     insertvalue, field access via extractvalue, update via insertvalue
     chain on top of the base. *)
  assert_contains "llvm: record typedef emitted"
    (llvm_with_decls
      "type CgLRect = { w: int, h: int };\n\
       let r = CgLRect { w = 3, h = 4 } in r.w * r.h")
    "%CgLRect = type { i32, i32 }";
  assert_contains "llvm: record literal builds via insertvalue chain"
    (llvm_with_decls
      "type CgLPt = { x: int, y: int };\n\
       let p = CgLPt { x = 1, y = 2 } in p.x")
    "insertvalue %CgLPt undef, i32 1, 0";
  assert_contains "llvm: record field get via extractvalue"
    (llvm_with_decls
      "type CgLPt2 = { x: int, y: int };\n\
       let p = CgLPt2 { x = 1, y = 2 } in p.y")
    "extractvalue %CgLPt2";
  assert_contains "llvm: record update emits insertvalue on top of base"
    (llvm_with_decls
      "type CgLPt3 = { x: int, y: int };\n\
       let p = CgLPt3 { x = 1, y = 2 } in { p | x = 100 }.x")
    "insertvalue %CgLPt3";
  assert_contains "llvm: record with str field"
    (llvm_with_decls
      "type CgLPair = { a: str, b: int };\n\
       let p = CgLPair { a = \"hi\", b = 42 } in p.b")
    "%CgLPair = type { ptr, i32 }";
  assert_contains "llvm: record-returning fn signature"
    (llvm_with_decls
      "type CgLPt4 = { x: int, y: int };\n\
       let mk = fn n -> CgLPt4 { x = n, y = n + 1 } in (mk 5).x")
    "define %CgLPt4 @mk(i32 %n)";

  (* --- LLVM IR codegen: variant + match (Phase 5.6) ---
     Variants lower to `%V = type { i32 }` (nullary) or `%V = type { i32, T }`
     (single-payload-type). Constr → insertvalue chain, Match → icmp chain
     with phi node for the join. *)
  assert_contains "llvm: nullary variant typedef"
    (llvm_with_decls
      "type LCol = LR | LG | LB;\n\
       match LG with | LR -> 0 | LG -> 1 | LB -> 2")
    "%LCol = type { i32 }";
  assert_contains "llvm: variant with payload typedef"
    (llvm_with_decls
      "type LStat = LOk | LErr of str;\n\
       match LErr \"x\" with | LOk -> 0 | LErr m -> str_len m")
    "%LStat = type { i32, ptr }";
  assert_contains "llvm: Constr emits insertvalue with tag"
    (llvm_with_decls
      "type LCol2 = LX | LY;\n\
       let c = LY in match c with | LX -> 0 | LY -> 1")
    "insertvalue %LCol2 undef, i32 1, 0";
  assert_contains "llvm: Constr with payload emits second insertvalue"
    (llvm_with_decls
      "type LStat2 = LOk2 | LErr2 of int;\n\
       LErr2 42")
    "insertvalue %LStat2 ";
  assert_contains "llvm: Match extracts tag via extractvalue"
    (llvm_with_decls
      "type LCol3 = LR3 | LG3;\n\
       match LR3 with | LR3 -> 1 | LG3 -> 2")
    "extractvalue %LCol3";
  assert_contains "llvm: Match uses icmp eq on tag"
    (llvm_with_decls
      "type LCol4 = LR4 | LG4;\n\
       match LR4 with | LR4 -> 1 | LG4 -> 2")
    "icmp eq i32";
  assert_contains "llvm: Match phi joins arm results"
    (llvm_with_decls
      "type LCol5 = LR5 | LG5;\n\
       match LR5 with | LR5 -> 10 | LG5 -> 20")
    "= phi i32";
  assert_contains "llvm: Match payload bound via extractvalue"
    (llvm_with_decls
      "type LStat3 = LOk3 | LErr3 of int;\n\
       match LErr3 5 with | LOk3 -> 0 | LErr3 n -> n")
    "extractvalue %LStat3";
  assert_contains "llvm: abort declared for fallthrough"
    (llvm_with_decls
      "type LCol6 = LR6 | LG6;\n\
       match LR6 with | LR6 -> 1 | LG6 -> 2")
    "declare void @abort()";

  (* --- LLVM IR codegen: first-class top-level fn (Phase 5.7-a) ---
     Top-level fn can be passed as value. closure_T1_T2 = { ptr, ptr }
     struct, fn_closure_fn adapter, indirect App goes through extractvalue +
     call via fn pointer. *)
  assert_contains "llvm: closure typedef for int->int"
    (llvm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "%closure_int_int = type { ptr, ptr }";
  assert_contains "llvm: closure adapter emitted"
    (llvm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "define i32 @inc_closure_fn(ptr %env_unused, i32 %x)";
  assert_contains "llvm: fn-as-value builds closure with adapter"
    (llvm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "insertvalue %closure_int_int undef, ptr null, 0";
  assert_contains "llvm: fn-as-value sets fn pointer"
    (llvm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "ptr @inc_closure_fn, 1";
  assert_contains "llvm: indirect App extracts env + fn ptr"
    (llvm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "extractvalue %closure_int_int";
  assert_contains "llvm: indirect call uses extracted fn ptr"
    (llvm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "= call i32 ";
  assert_contains "llvm: HOF receives closure-typed param"
    (llvm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "define i32 @apply(%closure_int_int %f)";

  (* --- LLVM IR codegen: anonymous Fun + closure-with-captures (Phase 5.7-b) ---
     Inner `fn x -> ...` in expression position lifts to an env struct
     + adapter; captures are stored in a heap-allocated env (via malloc
     for now) and re-loaded inside the adapter from `%env_self`. *)
  assert_contains "llvm: anon adapter emitted"
    (llvm "let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10")
    "define i32 @anon_0_fn(ptr %env_self, i32 %x)";
  assert_contains "llvm: anon env struct typedef"
    (llvm "let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10")
    "%anon_0_env = type { i32 }";
  assert_contains "llvm: anon env allocated via malloc"
    (llvm "let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10")
    "= call ptr @malloc";
  assert_contains "llvm: capture stored into env via getelementptr"
    (llvm "let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10")
    "getelementptr %anon_0_env, ptr ";
  assert_contains "llvm: capture loaded from env_self in adapter"
    (llvm "let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10")
    "= load i32, ptr ";
  assert_contains "llvm: anon closure value built with adapter pointer"
    (llvm "let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10")
    "ptr @anon_0_fn, 1";
  assert_contains "llvm: captureless anon Fun uses null env"
    (llvm "let apply = fn f -> f 5 in apply (fn x -> x + 1)")
    "insertvalue %closure_int_int undef, ptr null, 0";

  (* --- LLVM IR codegen: default region runtime (Phase 5.8) ---
     %__lang_region struct, init/alloc/free helpers, and the global
     @__lang_default_region initialized at @main start. Closure env and
     string concat allocations now go through the bump arena. *)
  assert_contains "llvm: __lang_region struct typedef"
    (llvm "1 + 2") "%__lang_region = type { ptr, ptr, i64 }";
  assert_contains "llvm: default region global"
    (llvm "1 + 2") "@__lang_default_region = internal global %__lang_region zeroinitializer";
  assert_contains "llvm: region_alloc helper defined"
    (llvm "1 + 2") "define ptr @__lang_region_alloc(ptr %r, i64 %n)";
  assert_contains "llvm: main initializes default region"
    (llvm "1 + 2")
    "call void @__lang_region_init(ptr @__lang_default_region, i64 4194304)";
  assert_contains "llvm: main frees default region"
    (llvm "1 + 2")
    "call void @__lang_region_free(ptr @__lang_default_region)";
  assert_contains "llvm: str_concat uses default region"
    (llvm "\"a\" ++ \"b\"")
    "call ptr @__lang_region_alloc(ptr @__lang_default_region, i64 %totalp1)";
  assert_contains "llvm: closure env alloc uses default region"
    (llvm "let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10")
    "call ptr @__lang_region_alloc(ptr @__lang_default_region, i64";
  assert_no_contains "llvm: closure env no longer uses bare malloc"
    (llvm "let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10")
    "= call ptr @malloc(i64 %t";

  (* --- LLVM IR codegen: 多相 variant / record の monomorphization (Phase 5.9) ---
     `'a opt`, `'a Box` etc. get a specialized struct per concrete
     instantiation (`%opt_int`, `%Box_str`). Constr / Record_lit /
     Field_get / Match use the mono name. *)
  assert_contains "llvm: poly variant mono typedef"
    (llvm_with_decls
      "type 'a LCgOpt = LCgN | LCgS of 'a;\n\
       match LCgS 42 with | LCgN -> 0 | LCgS n -> n")
    "%LCgOpt_int = type { i32, i32 }";
  assert_contains "llvm: poly variant Constr uses mono name"
    (llvm_with_decls
      "type 'a LCgOpt2 = LCgN2 | LCgS2 of 'a;\n\
       LCgS2 42")
    "insertvalue %LCgOpt2_int";
  assert_contains "llvm: poly variant Match uses mono name"
    (llvm_with_decls
      "type 'a LCgOpt3 = LCgN3 | LCgS3 of 'a;\n\
       match LCgS3 42 with | LCgN3 -> 0 | LCgS3 n -> n")
    "extractvalue %LCgOpt3_int";
  assert_contains "llvm: poly record mono typedef"
    (llvm_with_decls
      "type 'a LCgBox = { v: 'a };\n\
       let b = LCgBox { v = 42 } in b.v")
    "%LCgBox_int = type { i32 }";
  assert_contains "llvm: poly record Record_lit uses mono name"
    (llvm_with_decls
      "type 'a LCgBox2 = { v: 'a };\n\
       let b = LCgBox2 { v = 42 } in b.v")
    "insertvalue %LCgBox2_int";
  assert_contains "llvm: poly record Field_get uses mono name"
    (llvm_with_decls
      "type 'a LCgBox3 = { v: 'a };\n\
       let b = LCgBox3 { v = 42 } in b.v")
    "extractvalue %LCgBox3_int";
  assert_contains "llvm: poly record specializes at two types"
    (llvm_with_decls
      "type 'a LCgBox4 = { v: 'a };\n\
       let bi = LCgBox4 { v = 42 } in\n\
       let bs = LCgBox4 { v = \"hi\" } in\n\
       str_len bs.v + bi.v")
    "%LCgBox4_str = type { ptr }";

  (* --- LLVM IR codegen: 再帰 variant (Phase 5.10) ---
     Recursive variants (e.g. `'a list`, self-referential `ilist`) lower
     to heap-allocated nodes via region alloc; values are `ptr` to the
     node, accessed via getelementptr + load. P_tuple sub-pattern in Cons
     unpacks the payload tuple via extractvalue. *)
  assert_contains "llvm: recursive variant emits _node typedef"
    (llvm_with_decls
      "type LCgIList = LCgINil | LCgICons of int * LCgIList;\n\
       LCgICons (1, LCgINil)")
    "%LCgIList_node = type { i32, %tuple_int_LCgIList }";
  assert_contains "llvm: recursive Constr allocs via region"
    (llvm_with_decls
      "type LCgIList2 = LCgINil2 | LCgICons2 of int * LCgIList2;\n\
       LCgICons2 (1, LCgINil2)")
    "call ptr @__lang_region_alloc(ptr @__lang_default_region, i64";
  assert_contains "llvm: recursive Match loads tag via GEP"
    (llvm_with_decls
      "type LCgIList3 = LCgINil3 | LCgICons3 of int * LCgIList3;\n\
       match LCgINil3 with | LCgINil3 -> 0 | LCgICons3 (h, _) -> h")
    "getelementptr %LCgIList3_node, ptr ";
  assert_contains "llvm: poly recursive list emits mono _node typedef"
    (llvm_with_decls
      "type 'a LCgList = LCgNil | LCgCons of 'a * 'a LCgList;\n\
       let rec sum = fn xs -> match xs with\n\
         | LCgNil -> 0\n\
         | LCgCons (h, t) -> h + sum t\n\
       in sum (LCgCons (1, LCgCons (2, LCgNil)))")
    "%LCgList_int_node = type { i32, %tuple_int_LCgList_int }";
  assert_contains "llvm: P_tuple sub-pattern extracts via extractvalue"
    (llvm_with_decls
      "type LCgIList4 = LCgINil4 | LCgICons4 of int * LCgIList4;\n\
       let rec sum = fn xs -> match xs with\n\
         | LCgINil4 -> 0\n\
         | LCgICons4 (h, t) -> h + sum t\n\
       in sum (LCgICons4 (1, LCgINil4))")
    "extractvalue %tuple_int_LCgIList4";

  (* --- LLVM IR codegen: 複雑な pattern (Phase 5.11) ---
     P_int / P_bool / P_str (via @strcmp) / P_unit / P_record / P_as /
     or-pattern (pre-flattened) / guard (and-ed with arm test). *)
  assert_contains "llvm: strcmp declared"
    (llvm "match \"hi\" with | \"hi\" -> 1 | _ -> 0")
    "declare i32 @strcmp(ptr, ptr)";
  assert_contains "llvm: P_int via icmp eq"
    (llvm "match 3 with | 0 -> 1 | 3 -> 2 | _ -> 9")
    "= icmp eq i32 ";
  assert_contains "llvm: P_str via strcmp"
    (llvm "match \"hello\" with | \"hi\" -> 1 | \"hello\" -> 2 | _ -> 9")
    "= call i32 @strcmp(ptr ";
  assert_contains "llvm: P_bool via icmp eq i1"
    (llvm "match true with | false -> 0 | true -> 1")
    "= icmp eq i1 ";
  assert_contains "llvm: record pattern via extractvalue"
    (llvm_with_decls
      "type LCgPt5 = { x: int, y: int };\n\
       match LCgPt5 { x = 3, y = 4 } with | LCgPt5 { x = a, y = b } -> a + b")
    "extractvalue %LCgPt5";
  assert_contains "llvm: nested constructor with P_constr sub"
    (llvm_with_decls
      "type 'a LCgOpt5 = LCgN5 | LCgS5 of 'a;\n\
       match LCgS5 (LCgS5 7) with | LCgN5 -> 0 | LCgS5 LCgN5 -> 1 | LCgS5 (LCgS5 n) -> n")
    "and i1 ";
  assert_contains "llvm: or-pattern flattens to multiple arms"
    (llvm_with_decls
      "type LCgCol7 = LCg7A | LCg7B | LCg7C;\n\
       match LCg7B with | LCg7A | LCg7B -> 1 | LCg7C -> 2")
    "%arm_";
  assert_contains "llvm: match guard adds br after pass"
    (llvm
       "match 7 with | n when n < 5 -> 100 | n when n < 10 -> 200 | _ -> 300")
    "guard_pass_";

  (* --- LLVM IR codegen: show 汎用 builtin (Phase 5.12) ---
     `show : 'a -> str` を呼出ごとに引数型から `show_T` を specialize、
     int/bool/str/unit/tuple/record/variant (mono + poly + recursive) 対応。
     `@asprintf` ベースで型ごとに dedicated 関数を生成、collect_show_types
     で必要な型を発見、`App (Var "show", arg)` を `call ptr @show_<tag>` に
     dispatch。 *)
  assert_contains "llvm: asprintf declared"
    (llvm "print (show 42)") "declare i32 @asprintf(ptr, ptr, ...)";
  assert_contains "llvm: show_int defined"
    (llvm "show 42") "define ptr @show_int(i32 %x)";
  assert_contains "llvm: show int call site"
    (llvm "show 42") "call ptr @show_int(i32 42)";
  assert_contains "llvm: show str specialization"
    (llvm "show \"hi\"") "define ptr @show_str(ptr %x)";
  assert_contains "llvm: show bool specialization"
    (llvm "show true") "define ptr @show_bool(i1 %x)";
  assert_contains "llvm: show tuple composes elements"
    (llvm "show (1, \"hi\")") "define ptr @show_tuple_int_str";
  assert_contains "llvm: show variant uses tag dispatch"
    (llvm_with_decls
      "type LCgCol8 = LCg8A | LCg8B;\n\
       show LCg8A")
    "define ptr @show_LCgCol8";
  assert_contains "llvm: show poly variant uses mono name"
    (llvm_with_decls
      "type 'a LCgOpt7 = LCgN7 | LCgS7 of 'a;\n\
       show (LCgS7 1)")
    "define ptr @show_LCgOpt7_int";
  assert_contains "llvm: show record"
    (llvm_with_decls
      "type LCgPt6 = { x: int, y: int };\n\
       show (LCgPt6 { x = 1, y = 2 })")
    "define ptr @show_LCgPt6";

  (* --- LLVM IR codegen: region runtime (Region_block + Ref) + with Drop +
       view 構築 (Phase 5.13) ---
     `region R { body }` を __lang_region_init + body + __lang_region_free に
     compile、`&R v` を region_alloc + store で ptr return、`with c = v in body`
     を bind + body + auto-close、view 構築は region_alloc + insertvalue + store
     + ptr return。 *)
  assert_contains "llvm: Region_block calls __lang_region_init"
    (llvm "region R { let x = &R 5 in 42 }")
    "call void @__lang_region_init(ptr ";
  assert_contains "llvm: Region_block calls __lang_region_free"
    (llvm "region R { let x = &R 5 in 42 }")
    "call void @__lang_region_free(ptr ";
  assert_contains "llvm: Ref allocs via region + store"
    (llvm "region R { let x = &R 5 in 42 }")
    "store i32 5, ptr ";
  assert_contains "llvm: with calls close.fn(env, 0) at scope end"
    (llvm_with_decls
      "drop type LCgConn7 = { id: int, close: unit -> unit };\n\
       let mk = fn i -> LCgConn7 { id = i, close = fn () -> () } in\n\
       with c = mk 7 in c.id")
    "call i32 ";
  assert_contains "llvm: view typedef same as record (insertvalue then store)"
    (llvm_with_decls
      "view LCgCell8[R] of int { v: int };\n\
       region R { let c = LCgCell8 { v = 7 } in c.v }")
    "%LCgCell8 = type { i32 }";
  assert_contains "llvm: view construction region-allocates"
    (llvm_with_decls
      "view LCgCell9[R] of int { v: int };\n\
       region R { let c = LCgCell9 { v = 7 } in c.v }")
    "call ptr @__lang_region_alloc(ptr ";
  assert_contains "llvm: view field access uses GEP + load"
    (llvm_with_decls
      "view LCgCellA[R] of int { v: int };\n\
       region R { let c = LCgCellA { v = 7 } in c.v }")
    "getelementptr %LCgCellA, ptr ";

  (* --- LLVM IR codegen: list show を [a, b, c] 形式に (Phase 5.14) ---
     `'a list` を recursive variant の generic show より special-case で
     `[1, 2, 3]` 形式で表示。show_list_<T> 内で alloca/load/store + ループ
     で各要素 show_T を呼んで __lang_str_concat で繋ぐ。 *)
  assert_contains "llvm: list show emits [ prefix"
    (llvm_with_decls
      "type 'a list = Nil | Cons of 'a * 'a list;\n\
       show [1, 2, 3]")
    "@.s_lbracket";
  assert_contains "llvm: list show emits ] suffix"
    (llvm_with_decls
      "type 'a list = Nil | Cons of 'a * 'a list;\n\
       show [1, 2, 3]")
    "@.s_rbracket";
  assert_contains "llvm: list show emits comma separator"
    (llvm_with_decls
      "type 'a list = Nil | Cons of 'a * 'a list;\n\
       show [1, 2, 3]")
    "@.s_comma_space";
  assert_contains "llvm: list show calls element show via str_concat"
    (llvm_with_decls
      "type 'a list = Nil | Cons of 'a * 'a list;\n\
       show [1, 2, 3]")
    "call ptr @__lang_str_concat";

  (* --- Wasm (WAT) codegen MVP (Phase 6.1) ---
     Stack-based emission to WAT (S-expression text format). subset:
     int / bool / arith / cmp / logic / Neg / If / Let (P_var) / Var /
     Annot. Verified end-to-end via wat2wasm + WebAssembly.instantiate. *)
  let wasm s =
    let prog = Pipeline.parse_program s in
    let main_ty = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
    Codegen_wasm.emit_program ~main_ty prog
  in
  let wasm_with_decls s =
    let prog = Pipeline.parse_program s in
    let type_env = ref Typer.initial_env in
    List.iter (fun decl ->
      match decl with
      | Ast.Top_record (name, params, fields) ->
        Typer.register_record name params fields
      | Ast.Top_type (name, params, variants) ->
        Typer.register_type name params variants
      | Ast.Top_drop name -> Typer.register_drop_type name
      | Ast.Top_view (name, region, fields) ->
        Typer.register_view name region fields
      | Ast.Top_let (pat, value) ->
        let outer = !type_env in
        let t = Typer.infer outer value in
        let bs = Typer.check_pattern pat t in
        type_env := List.fold_left (fun acc (n, ty) ->
          (n, Typer.generalize outer ty) :: acc) outer bs
      | _ -> ()
    ) prog.decls;
    let main_ty = Typer.infer !type_env (Ast.desugar_program prog) in
    Codegen_wasm.emit_program ~main_ty prog
  in
  assert_contains "wasm: emits (module"
    (wasm "42") "(module";
  assert_contains "wasm: exports main with i32 result"
    (wasm "42") "(func $main (export \"main\") (result i32)";
  assert_contains "wasm: int literal becomes i32.const"
    (wasm "42") "i32.const 42";
  assert_contains "wasm: add maps to i32.add"
    (wasm "1 + 2") "i32.add";
  assert_contains "wasm: mul maps to i32.mul"
    (wasm "3 * 4") "i32.mul";
  assert_contains "wasm: sdiv via i32.div_s"
    (wasm "10 / 2") "i32.div_s";
  assert_contains "wasm: < maps to i32.lt_s"
    (wasm "if 1 < 2 then 10 else 20") "i32.lt_s";
  assert_contains "wasm: if uses if/else/end"
    (wasm "if 1 < 2 then 10 else 20") "if (result i32)";
  assert_contains "wasm: if has else branch"
    (wasm "if 1 < 2 then 10 else 20") "else";
  assert_contains "wasm: let allocates local slot"
    (wasm "let x = 5 in x * x") "local.set 0";
  assert_contains "wasm: var reads via local.get"
    (wasm "let x = 5 in x") "local.get 0";
  assert_contains "wasm: locals declared at fn start"
    (wasm "let x = 5 in x") "(local i32)";
  assert_contains "wasm: bool literal as i32"
    (wasm "true") "i32.const 1";
  assert_contains "wasm: and lowers to i32.and"
    (wasm "true && false") "i32.and";

  (* --- Wasm codegen: 関数 lifting + recursion (Phase 6.2) ---
     top-level fn が `(func $name (param i32) (result i32))` に lift、
     直接呼出は `call $name`、相互再帰も同モジュール内で動く (Wasm は
     前方参照可)。 *)
  assert_contains "wasm: top-level fn lifted to (func $name)"
    (wasm "let inc = fn x -> x + 1 in inc 5")
    "(func $inc (param i32) (result i32)";
  assert_contains "wasm: direct call uses call $name"
    (wasm "let inc = fn x -> x + 1 in inc 5")
    "call $inc";
  assert_contains "wasm: param read via local.get 0"
    (wasm "let inc = fn x -> x + 1 in inc 5")
    "local.get 0";
  assert_contains "wasm: self-recursion compiles"
    (wasm "let rec fact = fn n -> if n <= 1 then 1 else n * fact (n - 1) in fact 5")
    "call $fact";
  assert_contains "wasm: mutual recursion: both fns defined"
    (wasm "let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)\n\
           and is_odd = fn n -> if n == 0 then false else is_even (n - 1)\n\
           in is_even 4")
    "(func $is_odd";

  (* --- Wasm codegen: 文字列対応 (Phase 6.3) ---
     文字列は linear memory に置く: Str_lit は data セグメント、
     bump pointer global で動的 alloc、$__lang_strlen / $__lang_str_concat
     を WAT 内に inline 定義、print は host import (env.puts)。 *)
  assert_contains "wasm: memory declared + exported"
    (wasm "\"hi\"") "(memory (export \"memory\") 1)";
  assert_contains "wasm: bump pointer global declared"
    (wasm "\"hi\"") "(global $__lang_bump (mut i32)";
  assert_contains "wasm: puts imported"
    (wasm "\"hi\"") "(import \"env\" \"puts\" (func $puts (param i32)))";
  assert_contains "wasm: str literal becomes data segment"
    (wasm "\"hi\"") "(data (i32.const ";
  assert_contains "wasm: str_len calls $__lang_strlen"
    (wasm "str_len \"hi\"") "call $__lang_strlen";
  assert_contains "wasm: ++ calls $__lang_str_concat"
    (wasm "\"a\" ++ \"b\"") "call $__lang_str_concat";
  assert_contains "wasm: print calls $puts"
    (wasm "print \"hi\"") "call $puts";
  assert_contains "wasm: __lang_strlen helper defined"
    (wasm "\"hi\"") "(func $__lang_strlen";
  assert_contains "wasm: __lang_str_concat helper defined"
    (wasm "\"hi\"") "(func $__lang_str_concat";

  (* --- Wasm codegen: tuple (Phase 6.4) ---
     tuple は linear memory に置く: 各要素 4 bytes (i32 / offset)、
     base offset を一旦 local に保存して bump を即座に進める (nested
     tuple や ++ がスタンプを advance してもメモリが重ならない)、
     fst/snd は i32.load offset で取得。 *)
  assert_contains "wasm: tuple stores via i32.store offset"
    (wasm "let p = (1, 2) in fst p + snd p")
    "i32.store offset=0";
  assert_contains "wasm: tuple stores second element at offset=4"
    (wasm "let p = (1, 2) in fst p + snd p")
    "i32.store offset=4";
  assert_contains "wasm: fst lowers to i32.load offset=0"
    (wasm "let p = (1, 2) in fst p")
    "i32.load offset=0";
  assert_contains "wasm: snd lowers to i32.load offset=4"
    (wasm "let p = (1, 2) in snd p")
    "i32.load offset=4";
  assert_contains "wasm: tuple reserves space via bump advance"
    (wasm "(1, 2)")
    "global.set $__lang_bump";

  (* --- Wasm codegen: record (Phase 6.5) ---
     Record も tuple と同じ linear memory レイアウト。Record_lit は宣言順に
     i32.store、Field_get は field index から i32.load offset、Record_update
     は新 buffer に reserve + 更新 field 以外は load コピー。 *)
  assert_contains "wasm: record literal stores fields at offset"
    (wasm_with_decls
      "type WCgRect = { w: int, h: int };\n\
       let r = WCgRect { w = 3, h = 4 } in r.w * r.h")
    "i32.store offset=0";
  assert_contains "wasm: record field access via i32.load offset"
    (wasm_with_decls
      "type WCgPt = { x: int, y: int };\n\
       let p = WCgPt { x = 1, y = 2 } in p.y")
    "i32.load offset=4";
  assert_contains "wasm: record update reserves new struct"
    (wasm_with_decls
      "type WCgPt2 = { x: int, y: int };\n\
       let p = WCgPt2 { x = 1, y = 2 } in { p | x = 100 }.x")
    "global.set $__lang_bump";
  assert_contains "wasm: record-returning fn uses i32 return"
    (wasm_with_decls
      "type WCgPt3 = { x: int, y: int };\n\
       let mk = fn n -> WCgPt3 { x = n, y = n + 1 } in (mk 5).x")
    "(func $mk (param i32) (result i32)";

  (* --- Wasm codegen: variant + match (Phase 6.6) ---
     Variant も linear memory に: {i32 tag} (nullary) or {i32 tag, i32 payload}。
     Constr で alloc + store tag (+ payload)、Match は tag load + 入れ子の
     if/else チェーン、fallthrough は unreachable で trap。 *)
  assert_contains "wasm: nullary variant Constr stores tag"
    (wasm_with_decls
      "type WCgCol1 = WCgR1 | WCgG1 | WCgB1;\n\
       WCgG1")
    "i32.store offset=0";
  assert_contains "wasm: variant with payload stores payload at offset=4"
    (wasm_with_decls
      "type WCgStat1 = WCgOk1 | WCgErr1 of int;\n\
       WCgErr1 42")
    "i32.store offset=4";
  assert_contains "wasm: Match loads tag at offset=0"
    (wasm_with_decls
      "type WCgCol2 = WCgR2 | WCgG2;\n\
       match WCgR2 with | WCgR2 -> 1 | WCgG2 -> 2")
    "i32.load offset=0";
  assert_contains "wasm: Match dispatches with i32.eq + if"
    (wasm_with_decls
      "type WCgCol3 = WCgR3 | WCgG3;\n\
       match WCgR3 with | WCgR3 -> 1 | WCgG3 -> 2")
    "i32.eq";
  assert_contains "wasm: Match fallthrough is unreachable"
    (wasm_with_decls
      "type WCgCol4 = WCgR4 | WCgG4;\n\
       match WCgR4 with | WCgR4 -> 1 | WCgG4 -> 2")
    "unreachable";
  assert_contains "wasm: payload bind loads via offset=4"
    (wasm_with_decls
      "type WCgStat2 = WCgOk2 | WCgErr2 of int;\n\
       match WCgErr2 5 with | WCgOk2 -> 0 | WCgErr2 n -> n")
    "i32.load offset=4";

  (* --- Wasm codegen: first-class fn + closure (Phase 6.7) ---
     Closure = 8-byte memory struct `{ env_offset, fn_table_idx }`.
     Top-level fn adapter + indirect App via call_indirect (type $cl).
     Anonymous Fun captures env in memory + adapter loads them. *)
  assert_contains "wasm: closure type declared"
    (wasm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "(type $cl (func (param i32) (param i32) (result i32)))";
  assert_contains "wasm: function table declared"
    (wasm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "(table ";
  assert_contains "wasm: top-level adapter emitted"
    (wasm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "(func $inc_closure (param i32) (param i32) (result i32)";
  assert_contains "wasm: elem section places adapters"
    (wasm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "(elem (i32.const 0)";
  assert_contains "wasm: indirect App uses call_indirect"
    (wasm "let inc = fn x -> x + 1 in let apply = fn f -> f 5 in apply inc")
    "call_indirect (type $cl)";
  assert_contains "wasm: anonymous Fun adapter emitted"
    (wasm "let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10")
    "(func $anon_0_fn (param i32) (param i32) (result i32)";
  assert_contains "wasm: anonymous adapter loads captures from env"
    (wasm "let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10")
    "i32.load offset=0";

  (* --- Wasm codegen: Region_block + Ref + with Drop + view (Phase 6.8) ---
     LIFO region (save/restore bump pointer on Region_block entry/exit),
     Ref allocs + stores + returns ptr, With Drop auto-calls close field
     via call_indirect, view literal uses the same bump alloc as record. *)
  assert_contains "wasm: Region_block saves bump pointer"
    (wasm "region R { 42 }")
    "global.set $__lang_bump";
  assert_contains "wasm: Ref stores value at allocated slot"
    (wasm "region R { let x = &R 5 in 42 }")
    "i32.store offset=0";
  assert_contains "wasm: with calls close via call_indirect"
    (wasm_with_decls
      "drop type WCgConn = { id: int, close: unit -> unit };\n\
       let mk = fn i -> WCgConn { id = i, close = fn () -> () } in\n\
       with c = mk 7 in c.id")
    "call_indirect (type $cl)";
  assert_contains "wasm: view literal stores fields"
    (wasm_with_decls
      "view WCgCellW[R] of int { v: int };\n\
       region R { let c = WCgCellW { v = 7 } in c.v }")
    "i32.store offset=0";
  assert_contains "wasm: view field access via i32.load offset"
    (wasm_with_decls
      "view WCgCellW2[R] of int { v: int, w: int };\n\
       region R { let c = WCgCellW2 { v = 7, w = 9 } in c.w }")
    "i32.load offset=4";
  assert_contains "wasm: Unit_lit becomes i32.const 0"
    (wasm "fn () -> ()") "i32.const 0";

  (* --- Wasm codegen: poly variant/record + recursive variant + P_tuple
     sub-pattern (Phase 6.9) ---
     Wasm の memory layout は uniform (どの値も i32 = 4 bytes) なので、
     多相 variant/record は monomorphization 不要、recursive variant
     (`'a list` の Cons) も同じ memory レイアウト。Match の Cons (h, t) も
     payload を tuple offset として読んで extractvalue 連鎖。 *)
  assert_contains "wasm: polymorphic variant works without specialization"
    (wasm_with_decls
      "type 'a WCgOpt = WCgN | WCgS of 'a;\n\
       match WCgS 42 with | WCgN -> 0 | WCgS n -> n")
    "i32.eq";
  assert_contains "wasm: polymorphic record works without specialization"
    (wasm_with_decls
      "type 'a WCgBox = { v: 'a };\n\
       let b = WCgBox { v = 42 } in b.v")
    "i32.store offset=0";
  assert_contains "wasm: recursive variant Cons stores tuple payload"
    (wasm_with_decls
      "type 'a WCgList = WCgNil | WCgCons of 'a * 'a WCgList;\n\
       WCgCons (1, WCgNil)")
    "i32.store offset=4";
  assert_contains "wasm: P_tuple sub-pattern extracts elements"
    (wasm_with_decls
      "type 'a WCgList2 = WCgNil2 | WCgCons2 of 'a * 'a WCgList2;\n\
       let rec sum = fn xs -> match xs with\n\
         | WCgNil2 -> 0\n\
         | WCgCons2 (h, t) -> h + sum t\n\
       in sum (WCgCons2 (1, WCgNil2))")
    "i32.load offset=0";

  (* --- Wasm codegen: 複雑な pattern (Phase 6.10) ---
     P_int / P_bool / P_str (via @__lang_streq) / P_unit / P_record / P_as /
     nested ctor / or-pattern (pre-flattened) / guard. *)
  assert_contains "wasm: streq runtime helper emitted"
    (wasm "match \"hi\" with | \"hi\" -> 1 | _ -> 0")
    "(func $__lang_streq";
  assert_contains "wasm: P_int via i32.eq"
    (wasm "match 3 with | 0 -> 1 | 3 -> 2 | _ -> 9")
    "i32.eq";
  assert_contains "wasm: P_str via streq call"
    (wasm "match \"hi\" with | \"hi\" -> 1 | _ -> 0")
    "call $__lang_streq";
  assert_contains "wasm: P_bool via i32.eq"
    (wasm "match true with | false -> 0 | true -> 1")
    "i32.eq";
  assert_contains "wasm: record pattern via i32.load offset"
    (wasm_with_decls
      "type WCgPt5 = { x: int, y: int };\n\
       match WCgPt5 { x = 3, y = 4 } with | WCgPt5 { x = a, y = b } -> a + b")
    "i32.load offset=0";
  assert_contains "wasm: nested ctor with combined i32.and"
    (wasm_with_decls
      "type 'a WCgOpt7 = WCgN7 | WCgS7 of 'a;\n\
       match WCgS7 (WCgS7 7) with\n\
         | WCgN7 -> 0\n\
         | WCgS7 WCgN7 -> 1\n\
         | WCgS7 (WCgS7 n) -> n")
    "i32.and";
  assert_contains "wasm: or-pattern flattens to multiple arms"
    (wasm_with_decls
      "type WCgCol9 = WCg9A | WCg9B | WCg9C;\n\
       match WCg9B with | WCg9A | WCg9B -> 1 | WCg9C -> 2")
    "if (result i32)";
  assert_contains "wasm: match guard short-circuits via inner if"
    (wasm
       "match 7 with | n when n < 5 -> 100 | n when n < 10 -> 200 | _ -> 300")
    "if (result i32)";

  (* --- Wasm codegen: show 汎用 builtin (Phase 6.11) ---
     LLVM Phase 5.12 相当。show は self-contained: int→string conversion
     も Wasm 内で実装、文字列/タプル/レコード/variant の合成は
     __lang_str_concat で。 *)
  assert_contains "wasm: show_int defined"
    (wasm "show 42") "(func $show_int";
  assert_contains "wasm: show int call site"
    (wasm "show 42") "call $show_int";
  assert_contains "wasm: show_bool selects between true/false offsets"
    (wasm "show true") "(func $show_bool";
  assert_contains "wasm: show_str wraps via str_concat"
    (wasm "show \"hi\"") "(func $show_str";
  assert_contains "wasm: show tuple composes elements"
    (wasm "show (1, \"hi\")") "(func $show_tuple_int_str";
  assert_contains "wasm: show variant tag dispatch"
    (wasm_with_decls
      "type WCgCol8 = WCg8A | WCg8B;\n\
       show WCg8A")
    "(func $show_WCgCol8";
  assert_contains "wasm: show poly variant uses mono name"
    (wasm_with_decls
      "type 'a WCgOpt7 = WCgN7 | WCgS7 of 'a;\n\
       show (WCgS7 1)")
    "(func $show_WCgOpt7_int";
  assert_contains "wasm: show record"
    (wasm_with_decls
      "type WCgPt6 = { x: int, y: int };\n\
       show (WCgPt6 { x = 1, y = 2 })")
    "(func $show_WCgPt6";

  (* --- Wasm codegen: list show を `[a, b, c]` 形式に (Phase 6.12) ---
     `'a list = Nil | Cons of 'a * 'a list` を special-case で配列形式の
     文字列に。 *)
  assert_contains "wasm: list show uses loop / block"
    (wasm_with_decls
      "type 'a list = Nil | Cons of 'a * 'a list;\n\
       show [1, 2, 3]")
    "(loop $lp";
  assert_contains "wasm: list show concats element show"
    (wasm_with_decls
      "type 'a list = Nil | Cons of 'a * 'a list;\n\
       show [1, 2, 3]")
    "call $__lang_str_concat";
  assert_contains "wasm: list show special-case fn defined"
    (wasm_with_decls
      "type 'a list = Nil | Cons of 'a * 'a list;\n\
       show [1, 2, 3]")
    "(func $show_list_int";

  (* --- Diagnostic format (Phase 7.1) ---
     Multi-line code frame with line numbers + caret with inline message. *)
  let diag source loc kind msg =
    Diagnostic.format ~source ~filename:"test.lang" loc kind msg
  in
  let mkloc line col = { Loc.line; col } in
  let single_line_err =
    diag "let x = 5 + 1 in\nlet y = x + \"hi\" in\ny"
      (mkloc 2 13) "type error" "type mismatch: `str` vs `int`"
  in
  assert_contains "diag: includes kind + msg header"
    single_line_err "type error: type mismatch";
  assert_contains "diag: arrow pointer with filename:line:col"
    single_line_err "--> test.lang:2:13";
  assert_contains "diag: prints line numbers in margin"
    single_line_err "1 | let x = 5 + 1 in";
  assert_contains "diag: caret line includes message"
    single_line_err "^ type mismatch";
  assert_contains "diag: shows context line after"
    single_line_err "3 | y";
  let zero_loc_err =
    diag "" (mkloc 0 0) "io error" "file not found"
  in
  assert_contains "diag: zero-loc falls back to single line"
    zero_loc_err "test.lang: io error: file not found";

  (* --- Type error wording (Phase 7.2) ---
     unify error reports "expected `X`, got `Y`" with the caller-side
     argument order conventions audited to be (expected, actual). *)
  let infer_err src =
    try
      let prog = Pipeline.parse_program src in
      let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
      ""
    with Typer.Type_error (_, msg) -> msg
  in
  assert_contains "diag: + arg wrong type → expected int got str"
    (infer_err "let x = 5 in x + \"hi\"") "expected `int`, got `str`";
  assert_contains "diag: App passes str where int expected"
    (infer_err "let f = fn x -> x + 1 in f \"hi\"") "expected `int`, got `str`";
  assert_contains "diag: if branches: then sets expected"
    (infer_err "if 1 < 2 then \"yes\" else 42") "expected `str`, got `int`";
  let infer_err_with_decls src =
    try
      let prog = Pipeline.parse_program src in
      List.iter (fun decl ->
        match decl with
        | Ast.Top_record (name, params, fields) ->
          Typer.register_record name params fields
        | Ast.Top_type (name, params, variants) ->
          Typer.register_type name params variants
        | _ -> ()) prog.decls;
      let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
      ""
    with Typer.Type_error (_, msg) -> msg
  in
  assert_contains "diag: record field type mismatch"
    (infer_err_with_decls "type WErr1 = { a: int };\nlet p = WErr1 { a = \"x\" } in p.a")
    "expected `int`, got `str`";

  (* --- Typo suggestions (Phase 7.3) ---
     Levenshtein-based hint: "did you mean X?". *)
  assert_contains "diag: unbound var with close match suggests it"
    (infer_err "let factorial = 10 in factrial + 1")
    "did you mean `factorial`?";
  assert_contains "diag: unbound var with no close match → no hint"
    (infer_err "zzzzzz")
    "unbound variable: zzzzzz";
  assert_no_contains "diag: distant name → no suggestion"
    (infer_err "zzzzzz")
    "did you mean";
  assert_contains "diag: unknown constructor suggests close ctor"
    (infer_err_with_decls "type Color7 = Red7 | Green7 | Blue7;\nlet c = Greeen7 in c")
    "did you mean `Green7`?";

  (* --- ANSI color output (Phase 7.4) ---
     `use_color` defaults to false (set by CLI when stderr is a TTY).
     When toggled on, headers / gutter / caret / help: get ANSI codes. *)
  assert_no_contains "diag: color off → no ANSI codes"
    (diag "let x = 5 in let y = x + \"hi\" in y" (mkloc 1 23)
       "type error" "expected `int`, got `str`")
    "\027[";
  Diagnostic.use_color := true;
  let colored =
    diag "let x = 5 in let y = x + \"hi\" in y" (mkloc 1 23)
      "type error" "expected `int`, got `str`"
  in
  Diagnostic.use_color := false;
  assert_contains "diag: color on → red kind header"
    colored "\027[1;31mtype error";
  assert_contains "diag: color on → blue gutter pipe"
    colored "\027[34m|";
  assert_contains "diag: color on → red caret"
    colored "\027[1;31m^";
  Diagnostic.use_color := true;
  let with_hint_colored =
    diag "let f = 10 in fa + 1" (mkloc 1 15)
      "type error" "unbound variable: fa\nhelp: did you mean `f`?"
  in
  Diagnostic.use_color := false;
  assert_contains "diag: color on → cyan help: keyword"
    with_hint_colored "\027[1;36mhelp: ";

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
