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

  (* --- with expression (Q-007 first slice) --- *)
  check "with basic"
    (Pipeline.process "with x = 5 in x + 1") "6";
  check "with multi-binding"
    (Pipeline.process "with x = 5, y = 10, z = 100 in x + y + z") "115";
  check "with shadowing"
    (Pipeline.process "with x = 1 in (with x = 2 in x) + x") "3";
  check "with + fn"
    (Pipeline.process "with f = fn x -> x + 1 in f 10") "11";
  check "with let-poly: id at bool and int"
    (Pipeline.process "with id = fn x -> x in if id true then id 1 else id 2") "1";
  check "with type: polymorphic id"
    (Pipeline.type_of "with id = fn x -> x in id") "('a -> 'a)";
  check "with nested with let"
    (Pipeline.process
      "with logger = 100 in
       let log = fn n -> n + logger in
       with greeted = log 5 in greeted") "105";
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

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
