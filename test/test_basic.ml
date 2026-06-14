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

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
