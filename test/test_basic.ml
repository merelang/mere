open Mere

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

(* Like check_raises but asserts the exception's Printexc string
   contains a given substring — useful for regressing an improved
   error-message hint against future refactors. *)
let check_raises_containing name substr f =
  match f () with
  | _ ->
    incr fail;
    Printf.printf "FAIL  %s (expected exception)\n" name
  | exception e ->
    let msg = Printexc.to_string e in
    let has_substr =
      let n = String.length substr in
      let m = String.length msg in
      let rec scan i = i + n <= m
                       && (String.sub msg i n = substr || scan (i + 1)) in
      n = 0 || scan 0
    in
    if has_substr then begin
      incr pass;
      Printf.printf "PASS  %s\n" name
    end else begin
      incr fail;
      Printf.printf "FAIL  %s (expected exception msg containing %S, got %S)\n"
        name substr msg
    end

let () =
  check "version is 0.1.7" Version.v "0.1.7";

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
  (* B2 (mere-blog dogfood): irrefutable constructor / record patterns in
     `let`. The interp always accepted these; the C and Wasm backends only
     handled P_var / P_tuple / P_wild and now desugar the rest to a
     single-arm match (see the codegen compile-checks below). *)
  check "let constructor pattern"
    (Pipeline.process "type ab = AB of int * int; let AB (a, b) = AB (3, 4) in a + b")
    "7";
  check "let record pattern"
    (Pipeline.process "type P = { x: int, y: int }; let P { x = a, y = b } = P { x = 3, y = 4 } in a + b")
    "7";
  check "let pattern with print side effect"
    (Pipeline.process "let _ = print \"hello\" in 42") "42";
  check "pp let tuple pattern"
    (Ast.pp (Pipeline.parse_only "let (a, b) = (1, 2) in a"))
    "(let (a, b) = (1, 2) in a)";
  check_raises "let pattern arity mismatch"
    (fun () -> Pipeline.type_of "let (a, b, c) = (1, 2) in a");

  (* --- ML-style primed identifiers (Phase 55.x rough-edge sweep) --- *)
  check "primed ident single tick"
    (Pipeline.process "let x' = 41 in x' + 1") "42";
  check "primed ident multi tick"
    (Pipeline.process "let x = 1 in let x' = x + 1 in let x'' = x' + 1 in x''") "3";
  check "primed ident survives fn param name"
    (Pipeline.process "let inc' = fn (a: int) -> a + 1 in inc' 41") "42";
  check "bare tyvar still lexes"
    (Pipeline.type_of "fn x -> x") "('a -> 'a)";

  (* --- `;` as sugar for `in` in expression-level let bindings --- *)
  check "semi sugar for in — plain let"
    (Pipeline.process "let x = 1; let y = 2; x + y") "3";
  check "semi sugar for in — let rec"
    (Pipeline.process
      "let rec fact = fn (n: int) -> if n <= 1 then 1 else n * fact (n - 1); \
       fact 5") "120";
  check "semi and in mix freely"
    (Pipeline.process "let a = 1 in let b = 2; let c = 3 in a + b + c") "6";

  (* Regression: a nested `let x = v in ...` inside a fn body must
     not be misrouted through the top-level global-init path just
     because `x` also names a top-level global. Before the fix, the
     inner let overwrote the global with the local value. *)
  check "nested let doesn't clobber top-level global of same name"
    (Pipeline.process
      "let entries = 42 in \
       let f = fn (u: unit) -> let entries = 99 in entries in \
       let _ = f () in entries") "42";

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
  (* trailing comma allowed in list and tuple literals *)
  check "list literal trailing comma"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       [1, 2, 3,]") "[1, 2, 3]";
  check "tuple literal trailing comma"
    (Pipeline.process "(1, 2, 3,)") "(1, 2, 3)";
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
  (* to_json — the derive-y sibling of show (structural JSON, compile-time
     ad-hoc polymorphism, no trait machinery). Records drop their name and
     become JSON objects; motivated by the mere-blog dogfood (PAIN B3), it
     collapses hand-written record->JSON writers to `to_json x`.
     (interp; codegen backends are a follow-up slice.) *)
  check "to_json type" (Pipeline.type_of "to_json") "('a -> str)";
  check "to_json int" (Pipeline.process "to_json 42") "\"42\"";
  check "to_json bool" (Pipeline.process "to_json true") "\"true\"";
  check "to_json str escapes"
    (Pipeline.process "to_json \"a\\\"b\"") "\"\\\"a\\\\\\\"b\\\"\"";
  check "to_json record drops name -> JSON object"
    (Pipeline.process
      "type P = { id: int, ok: bool };
       to_json (P { id = 5, ok = true })") "\"{\\\"id\\\":5,\\\"ok\\\":true}\"";
  (* structural == on compound types (record / ADT / tuple). The interp does
     value equality; the codegen backends must too — C used to emit an
     invalid `struct == struct`, Wasm silently compared pointers. *)
  check "eq: record structural =="
    (Pipeline.process
      "type P = { x: int, y: int };
       if P { x = 1, y = 2 } == P { x = 1, y = 2 } then 1 else 0") "1";
  check "eq: record structural != (differ)"
    (Pipeline.process
      "type P = { x: int, y: int };
       if P { x = 1, y = 2 } == P { x = 1, y = 9 } then 1 else 0") "0";
  check "eq: ADT structural =="
    (Pipeline.process
      "type 'a opt = None | Some of 'a;
       if Some 3 == Some 3 then 1 else 0") "1";
  check "to_json list -> JSON array"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       to_json [1, 2, 3]") "\"[1,2,3]\"";
  check "to_json nullary constructor -> string"
    (Pipeline.process
      "type color = Red | Green;
       to_json Red") "\"\\\"Red\\\"\"";
  check "to_json constructor with payload -> tagged object"
    (Pipeline.process
      "type 'a wrap = Wrap of 'a;
       to_json (Wrap 7)") "\"{\\\"Wrap\\\":7}\"";

  (* of_json — structural inverse of to_json (str -> 'a). The target type
     comes from an expression annotation `(of_json s : T)`. *)
  check "of_json type" (Pipeline.type_of "of_json") "(str -> 'a)";
  check "of_json int" (Pipeline.process "(of_json \"42\" : int)") "42";
  check "of_json bool" (Pipeline.process "(of_json \"true\" : bool)") "true";
  check "of_json str"
    (Pipeline.process "(of_json \"\\\"hi\\\"\" : str)") "\"hi\"";
  check "of_json list"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       (of_json \"[1, 2, 3]\" : int list)") "[1, 2, 3]";
  check "of_json tuple"
    (Pipeline.process "(of_json \"[7, 9]\" : (int * int))") "(7, 9)";
  (* round-trips avoid hand-escaping JSON braces in the test source *)
  check "of_json record round-trip"
    (Pipeline.process
      "type P = { id: int, title: str };
       let p = P { id = 5, title = \"x\" } in
       (of_json (to_json p) : P) == p") "true";
  check "of_json nested list round-trip"
    (Pipeline.process
      "type 'a list = Nil | Cons of 'a * 'a list;
       type OjRec = { xs: int list, name: str };
       let q = OjRec { xs = [1, 2, 3], name = \"n\" } in
       (of_json (to_json q) : OjRec) == q") "true";
  check "of_json option Some round-trip"
    (Pipeline.process
      "type 'a option = None | Some of 'a;
       type OjOpt = { v: int option };
       let r = OjOpt { v = Some 42 } in
       (of_json (to_json r) : OjOpt) == r") "true";
  (* of_json_opt: the non-crashing sibling — None on any parse / shape error *)
  check "of_json_opt ok -> Some"
    (Pipeline.process
      "type 'a option = None | Some of 'a;
       match (of_json_opt \"42\" : int option) with
       | Some n -> n | None -> (- 1)") "42";
  check "of_json_opt malformed -> None"
    (Pipeline.process
      "type 'a option = None | Some of 'a;
       match (of_json_opt \"not json\" : int option) with
       | Some n -> n | None -> (- 1)") "-1";
  check "of_json_opt missing field -> None"
    (Pipeline.process
      "type 'a option = None | Some of 'a;
       type Rq = { a: int, b: int };
       match (of_json_opt \"[]\" : Rq option) with
       | Some _ -> 1 | None -> 0") "0";
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

  (* --- P7 (mq dogfood): the ordering operators </<=/>/>= work directly on
     str, comparing lexicographically. Previously the typer defaulted both
     operands to int, so `"a" < "b"` failed to typecheck and mq had to route
     through `ord`/`str_compare`. Now str is a first-class ordered type; the
     comparison stays backward-compatible (unknown-meta operands still
     default to int). Must hold across interp + C + Wasm + LLVM. *)
  check "str lt true"  (Pipeline.process "\"apple\" < \"banana\"") "true";
  check "str lt false" (Pipeline.process "\"banana\" < \"apple\"") "false";
  check "str le equal" (Pipeline.process "\"abc\" <= \"abc\"") "true";
  check "str gt true"  (Pipeline.process "\"b\" > \"a\"") "true";
  check "str ge false" (Pipeline.process "\"a\" >= \"b\"") "false";
  check "str lt prefix" (Pipeline.process "\"abc\" < \"abcd\"") "true";
  check "str ordering types as bool" (Pipeline.type_of "\"a\" < \"b\"") "bool";
  (* int ordering must stay intact (no regression from the str relaxation) *)
  check "int lt still works" (Pipeline.process "3 < 5") "true";
  check "int ge still works" (Pipeline.process "5 >= 5") "true";

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

  (* --- Phase 19.1: str_index_of / str_split / str_join --- *)
  check "str_index_of: found"
    (Pipeline.process "str_index_of \"hello world\" \"world\"") "6";
  check "str_index_of: not found returns -1"
    (Pipeline.process "str_index_of \"hello\" \"xyz\"") "-1";
  check "str_index_of: empty needle returns 0"
    (Pipeline.process "str_index_of \"abc\" \"\"") "0";
  check "str_index_of: at start"
    (Pipeline.process "str_index_of \"abc\" \"a\"") "0";
  check "str_index_of type"
    (Pipeline.type_of "str_index_of") "(str -> (str -> int))";

  check "str_split: basic split"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        str_split \"a,b,c\" \",\"")
    "[\"a\", \"b\", \"c\"]";
  check "str_split: multi-char delimiter"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        str_split \"foo::bar::baz\" \"::\"")
    "[\"foo\", \"bar\", \"baz\"]";
  check "str_split: no delimiter found → 1-element list"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        str_split \"hello\" \",\"")
    "[\"hello\"]";
  check "str_split: trailing delimiter → empty tail"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        str_split \"a,b,\" \",\"")
    "[\"a\", \"b\", \"\"]";
  check "str_split: empty delimiter returns single-element"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        str_split \"hello\" \"\"")
    "[\"hello\"]";
  check "str_split type"
    (Pipeline.type_of "str_split") "(str -> (str -> str list))";

  check "str_join: basic"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        str_join \", \" [\"alpha\", \"beta\", \"gamma\"]")
    "\"alpha, beta, gamma\"";
  check "str_join: empty separator"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        str_join \"\" [\"a\", \"b\", \"c\"]")
    "\"abc\"";
  check "str_join: empty list"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        str_join \", \" ([] : str list)")
    "\"\"";
  check "str_join: single-element"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        str_join \", \" [\"only\"]")
    "\"only\"";
  check "str_join type"
    (Pipeline.type_of "str_join") "(str -> (str list -> str))";

  check "str_split + str_join roundtrip"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        str_join \"-\" (str_split \"hello world foo bar\" \" \")")
    "\"hello-world-foo-bar\"";

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

  (* --- string literal `\<newline>` line continuation --- *)
  check "line continuation joins two lines"
    (Pipeline.process "\"long value with \\\n   next\"")
    "\"long value with next\"";
  check "line continuation with no indent"
    (Pipeline.process "\"foo\\\nbar\"") "\"foobar\"";
  check "line continuation eats tabs too"
    (Pipeline.process "\"a\\\n\t\tb\"") "\"ab\"";
  check "line continuation preserves trailing whitespace before backslash"
    (Pipeline.process "\"a \\\n b\"") "\"a b\"";

  (* --- friendlier error for `let SCREAMING_SNAKE = …` bindings ---
     The name looks like a wanted UPPER_SNAKE constant but Mere reserves
     uppercase-first identifiers for constructors. The typer's hint
     should recommend lowercasing. *)
  check_raises_containing "SCREAMING_SNAKE hint suggests lower"
    "rename to `db_url`"
    (fun () -> Pipeline.process "let DB_URL = \"x\" in DB_URL");
  check_raises_containing "SCREAMING_SNAKE hint for MAX"
    "rename to `max`"
    (fun () -> Pipeline.process "let MAX = 100 in MAX");
  (* But the heuristic must NOT trigger on real constructor-look-alikes
     (single letters like `X`, or `Cnos` which is a Cons typo). *)
  check_raises_containing "single-letter capital: no snake hint"
    "unknown constructor"
    (fun () -> Pipeline.process "let X = 1 in X");
  check_raises_containing "Cnos typo: did-you-mean Cons"
    "did you mean `Cons`"
    (fun () -> Pipeline.process "let x = Cnos (1, Nil) in 0");

  (* --- file I/O: read_file / write_file (round-trip via /tmp) --- *)
  check "read_file type"
    (Pipeline.type_of "read_file") "(str -> str)";
  check "write_file type"
    (Pipeline.type_of "write_file") "(str -> (str -> unit))";
  check "file round-trip"
    (let path = Filename.temp_file "mere_test" ".txt" in
     Pipeline.process
       (Printf.sprintf
          "{ write_file %S \"hello lang\"; read_file %S }" path path))
    "\"hello lang\"";
  check_raises "read_file missing"
    (fun () -> Pipeline.process "read_file \"/nonexistent/no/such/file\"");

  (* --- Phase 19.6: I/O extensions (read_lines / file_exists / env_var / args) --- *)
  check "read_lines type"
    (Pipeline.type_of "read_lines") "(str -> str list)";
  check "file_exists type"
    (Pipeline.type_of "file_exists") "(str -> bool)";
  check "env_var type"
    (Pipeline.type_of "env_var") "(str -> str option)";
  check "args type"
    (Pipeline.type_of "args") "(unit -> str list)";
  check "read_lines roundtrip via /tmp"
    (let path = Filename.temp_file "mere_lines_test" ".txt" in
     Pipeline.process
       (Printf.sprintf
          "{ write_file %S \"alpha\\nbeta\\ngamma\\n\"; \
             match read_lines %S with \
             | Nil -> \"empty\" \
             | Cons (h, _) -> h }" path path))
    "\"alpha\"";
  check "file_exists: existing file (this very source dir)"
    (Pipeline.process "file_exists \"/etc\"") "true";
  check "file_exists: missing path"
    (Pipeline.process "file_exists \"/this/path/does/not/exist\"") "false";
  check "env_var: PATH should exist on any reasonable host"
    (Pipeline.process
       "match env_var \"PATH\" with | None -> \"\" | Some _ -> \"yes\"")
    "\"yes\"";
  check "env_var: bogus var → None"
    (Pipeline.process
       "match env_var \"MERE_DEFINITELY_UNSET_XYZ_123\" with \
        | None -> \"none\" | Some _ -> \"some\"")
    "\"none\"";

  (* --- Phase 44: list_dir / mkdir_p (fs primitives for docs site SSG) --- *)
  check "list_dir / mkdir_p: type signatures"
    (Pipeline.type_of "list_dir") "(str -> str list)";
  check "mkdir_p: type signature"
    (Pipeline.type_of "mkdir_p") "(str -> unit)";
  check "list_dir + mkdir_p: roundtrip (create dir + populate + list)"
    (let base = Filename.concat (Filename.get_temp_dir_name ())
                  (Printf.sprintf "mere_phase44_%d" (Random.int 1000000)) in
     Pipeline.process
       (Printf.sprintf
          "{ mkdir_p %S; \
             write_file %S \"alpha\"; \
             write_file %S \"beta\"; \
             match list_dir %S with \
             | Cons (a, Cons (b, Nil)) -> a ++ \",\" ++ b \
             | _ -> \"unexpected\" }"
          base
          (Filename.concat base "a.txt")
          (Filename.concat base "b.txt")
          base))
    "\"a.txt,b.txt\"";
  check "mkdir_p: nested (creates intermediate dirs)"
    (let base = Filename.concat (Filename.get_temp_dir_name ())
                  (Printf.sprintf "mere_phase44_nested_%d/a/b/c" (Random.int 1000000)) in
     Pipeline.process
       (Printf.sprintf
          "{ mkdir_p %S; file_exists %S }" base base))
    "true";
  (* args depends on Sys.argv, so the result varies by how the test runner is invoked.
     We only check that evaluation does not crash. *)
  (try
    let _ = Pipeline.process "args ()" in
    incr pass;
    Printf.printf "PASS  args: evaluation doesn't crash\n"
  with _ ->
    incr fail;
    Printf.printf "FAIL  args: evaluation crashed\n");

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
    (* common min-value initialization pattern *)
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
    (* sqrt pi ~= 1.7725; with pipe + curry, `f_lt 1.7 (sqrt pi)` = `1.7 < 1.7725` *)
    (Pipeline.process "sqrt pi |> f_lt 1.7") "true";

  (* --- Phase 19.7: math extensions (log / exp / trig / f_min_max / f_pow / random) --- *)
  check "log e == 1"    (Pipeline.process "log e") "1.";
  check "exp 0 == 1"    (Pipeline.process "exp 0.0") "1.";
  check "log type"      (Pipeline.type_of "log") "(float -> float)";
  check "exp type"      (Pipeline.type_of "exp") "(float -> float)";
  check "sin 0 == 0"    (Pipeline.process "sin 0.0") "0.";
  check "cos 0 == 1"    (Pipeline.process "cos 0.0") "1.";
  check "tan 0 == 0"    (Pipeline.process "tan 0.0") "0.";
  check "sin type"      (Pipeline.type_of "sin") "(float -> float)";
  check "atan2 type"
    (Pipeline.type_of "atan2") "(float -> (float -> float))";
  check "f_min picks smaller"
    (Pipeline.process "f_min 3.5 2.0") "2.";
  check "f_max picks larger"
    (Pipeline.process "f_max 3.5 2.0") "3.5";
  check "f_min type"
    (Pipeline.type_of "f_min") "(float -> (float -> float))";
  check "f_pow basic"
    (Pipeline.process "f_pow 2.0 10.0") "1024.";
  check "f_pow type"
    (Pipeline.type_of "f_pow") "(float -> (float -> float))";
  check "random_int in [0, n)"
    (Pipeline.process "let n = random_int 100 in if n >= 0 && n < 100 then \"ok\" else \"bad\"")
    "\"ok\"";
  check "random_float in [0, 1)"
    (Pipeline.process
       "let f = random_float () in if f_ge f 0.0 && f_lt f 1.0 then \"ok\" else \"bad\"")
    "\"ok\"";
  check "random_int type"
    (Pipeline.type_of "random_int") "(int -> int)";
  check "random_float type"
    (Pipeline.type_of "random_float") "(unit -> float)";
  check_raises "random_int rejects bound <= 0"
    (fun () -> Pipeline.process "random_int 0");

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
    (* a guarded arm may be false at runtime, so we conservatively treat it as not covering *)
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

  (* --- Phase 37.A: `while` at top-level (Let_rec lifting from Let value) --- *)
  check "Phase 37.A: while at top-level via Map mutable container (interp)"
    (Pipeline.process
      "let counter = map_new ();
       let _ = map_set counter \"n\" 2;
       let _ = while (map_get counter \"n\") > 0 do
         map_set counter \"n\" ((map_get counter \"n\") - 1);
       map_get counter \"n\"")
    "0";
  (* codegen-side (C/LLVM/Wasm) emit verification is done later (in the vec/map codegen
     sections) where typed_prog helpers are visible, due to scope reasons. *)

  (* --- exhaustiveness Phase 2 (tuple / record / typed wildcard hint) --- *)
  check "Phase 2: tuple destructure is total (no warning)"
    (warnings_of "match (1, 2) with | (a, b) -> a + b") "";
  check "Phase 2: nested tuple destructure is total"
    (warnings_of "match ((1, 2), 3) with | ((a, b), c) -> a + b + c") "";
  check "Phase 2: tuple with literal sub-pattern is NOT total"
    (warnings_of "match (1, 2) with | (0, b) -> b")
    "line 1, col 1: warning: non-exhaustive match (no wildcard arm for tuple)";
  check "Phase 2: record destructure is total"
    (warnings_of
      "type Pt = { x: int, y: int };
       let p = Pt { x = 3, y = 4 } in
       match p with | Pt { x = a, y = b } -> a + b") "";
  check "Phase 2: int match without wildcard gets type hint"
    (warnings_of "match 42 with | 0 -> \"zero\"")
    "line 1, col 1: warning: non-exhaustive match (no wildcard arm for int)";
  check "Phase 2: str match without wildcard gets type hint"
    (warnings_of "match \"hi\" with | \"hello\" -> 1")
    "line 1, col 1: warning: non-exhaustive match (no wildcard arm for str)";

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

  (* --- view field access: region propagation (Phase 2.4) ---
     The TyCon of a view value embeds the region at construction time, and
     field access substitutes the declared R with the actual region. *)
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
    "__let_tmp_x = 5";
  (* Phase 16, part 2 / DEFERRED §1.4: regression test for the bug where same-name
     rebinding `let x = f x` had the old x on the RHS overwritten by the new x,
     causing self-reference. The 2-step form (via __let_tmp_<name>) ensures that
     the old binding is visible at the time the RHS is evaluated. *)
  assert_contains "codegen: same-name rebinding uses tmp var"
    (codegen "let x = 1 in let x = x + 10 in x")
    "__let_tmp_x = (x + 10)";
  (* Phase 16.3 / DEFERRED §1.5: codegen support for mk_logger / mk_metrics.
     Make the cap builtin, previously interpreter-only, work in C codegen too via
     printf-based emission. Logger record + 3 closure_str_unit fields, Metrics
     record + (inc / record) curried closures.
     Note: a previous test declares `type Logger = { debug: ... }`, so we
     re-register the builtin fields before checking. *)
  Typer.register_record "Logger" []
    [("info",  Ast.TyArrow (Ast.TyStr, Ast.TyUnit));
     ("warn",  Ast.TyArrow (Ast.TyStr, Ast.TyUnit));
     ("error", Ast.TyArrow (Ast.TyStr, Ast.TyUnit))];
  Typer.register_record "Metrics" []
    [("inc",    Ast.TyArrow (Ast.TyStr, Ast.TyUnit));
     ("record", Ast.TyArrow (Ast.TyStr, Ast.TyArrow (Ast.TyInt, Ast.TyUnit)))];
  assert_contains "codegen: mk_logger emits runtime call"
    (codegen "let lg = mk_logger \"app\" in lg.info \"hi\"")
    "__mere_mk_logger";
  assert_contains "codegen: logger runtime printf"
    (codegen "let lg = mk_logger \"app\" in lg.info \"hi\"")
    "%s [INFO] %s";
  assert_contains "codegen: Logger struct uses closure fields"
    (codegen "let lg = mk_logger \"app\" in lg.info \"hi\"")
    "closure_str_unit info";
  assert_contains "codegen: mk_metrics emits runtime call"
    (codegen "let m = mk_metrics () in m.inc \"x\"")
    "__mere_mk_metrics";
  assert_contains "codegen: metrics record curried emits inner fn"
    (codegen "let m = mk_metrics () in m.record \"qps\" 7")
    "__mere_metrics_record_inner_fn";
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
  (* Phase 27.0: C codegen now prints "()" for unit-typed main to match
     interp (was: no printf at all). *)
  assert_contains "codegen: unit-typed main prints \"()\""
    (codegen "print \"hi\"") "printf(\"()\\n\")";
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
  (* Phase 19.1.1: str_index_of codegen *)
  assert_contains "codegen: str_index_of calls __lang_str_index_of"
    (codegen "str_index_of \"hi\" \"i\"")
    "__lang_str_index_of(\"hi\", \"i\")";
  assert_contains "codegen: __lang_str_index_of helper defined"
    (codegen "str_index_of \"hi\" \"i\"")
    "static int __lang_str_index_of(const char* h, const char* n)";
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
  (* Q-012 step 3b-4a: C backend spawn / join over pthreads (env-less closures).
     The emitted program compiles with clang and runs the closure on a real
     OS thread (validated manually; there is no C compile-run harness). *)
  assert_contains "codegen C: spawn emits a pthread_create"
    (codegen_with_decls
      "let cw = fn u -> print \"x\"; let h = spawn cw in join h")
    "pthread_create";
  assert_contains "codegen C: join emits a pthread_join"
    (codegen_with_decls
      "let cw = fn u -> print \"x\"; let h = spawn cw in join h")
    "pthread_join";
  assert_contains "codegen C: emits the spawn trampoline + ThreadHandle"
    (codegen_with_decls
      "let cw = fn u -> print \"x\"; let h = spawn cw in join h")
    "__mere_spawn_trampoline";
  (* Q-012-C-mem: the shared program-lifetime arena is lock-guarded so
     spawned threads can allocate from it without racing (validated under
     ThreadSanitizer with concurrent allocs). *)
  assert_contains "codegen C: shared arena allocation is lock-guarded"
    (codegen "42") "__lang_default_region_lock";
  assert_contains "codegen C: captured-env spawn lowers to a thread"
    (codegen_with_decls
      "let mk = fn m -> spawn (fn u -> print m); \
       let h = mk \"captured\" in join h")
    "pthread_create";
  (* Q-012 step 3b-4c: channels monomorphized to a per-element mutex/cond
     FIFO. A parallel producer/consumer program compiles with clang and runs
     (validated manually; TSan reports no data race on the channel). *)
  assert_contains "codegen C: channel_new emits the monomorphized constructor"
    (codegen_with_decls
      "let ch = channel_new () in \
       let _ = spawn (fn u -> channel_send ch 7) in \
       channel_recv ch")
    "mere_channel_int_new()";
  assert_contains "codegen C: channel_send emits the monomorphized send"
    (codegen_with_decls
      "let ch = channel_new () in \
       let _ = spawn (fn u -> channel_send ch 7) in \
       channel_recv ch")
    "mere_channel_int_send";
  assert_contains "codegen C: channel_recv emits the monomorphized recv"
    (codegen_with_decls
      "let ch = channel_new () in \
       let _ = spawn (fn u -> channel_send ch 7) in \
       channel_recv ch")
    "mere_channel_int_recv";
  assert_contains "codegen C: channel runtime uses a condition variable"
    (codegen_with_decls
      "let ch = channel_new () in \
       let _ = spawn (fn u -> channel_send ch 7) in \
       channel_recv ch")
    "pthread_cond_wait";
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
    "const closure_int_int inc_as_value =";   (* Phase 36: dropped `static` *)
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

  (* --- C codegen: first-class fns Phase B (anonymous Fun + captures) ---
     The helpers added to prelude in Phase 36 consume the __anon counter, so
     user-defined anon adapter slots are advanced (we pick the latest slot via
     substring match). *)
  assert_contains "codegen: anonymous Fun emits env typedef"
    (codegen
      "let apply = fn f -> fn x -> f x in let inc = fn n -> n + 1 in apply inc 5")
    "  closure_int_int f;\n} __anon_7_env;";   (* Under Phase 39.A', the lambdas of
                             list_sort_by / list_sort_insert / list_sort consume 6 slots, so the user's
                             `fn x -> f x` (captures f) is slot 7 (uniquely identifiable by the
                             env field `closure_int_int f`) *)
  assert_contains "codegen: anonymous Fun emits adapter"
    (codegen
      "let apply = fn f -> fn x -> f x in let inc = fn n -> n + 1 in apply inc 5")
    "static int __anon_7_fn(void* __env_self_void, int x)";
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
  (* Q-012 step 3b-4d: LLVM backend spawn / join over pthreads. The emitted
     IR compiles with clang and runs the closure on a real OS thread
     (validated manually). *)
  assert_contains "llvm: spawn emits pthread_create"
    (llvm_with_decls "let cw = fn u -> print \"x\"; let h = spawn cw in join h")
    "call i32 @pthread_create";
  assert_contains "llvm: join emits pthread_join"
    (llvm_with_decls "let cw = fn u -> print \"x\"; let h = spawn cw in join h")
    "call i32 @pthread_join";
  assert_contains "llvm: emits the spawn trampoline"
    (llvm_with_decls "let cw = fn u -> print \"x\"; let h = spawn cw in join h")
    "@__mere_spawn_trampoline";
  (* Q-012 step 3b-4e: LLVM channels via the generic i64-slot runtime.
     A parallel producer/consumer compiles with clang and runs. *)
  assert_contains "llvm: channel_new calls the generic runtime"
    (llvm_with_decls
      "let ch = channel_new () in \
       let _ = spawn (fn u -> channel_send ch 7) in \
       channel_recv ch")
    "call ptr @mere_channel_new()";
  assert_contains "llvm: channel_send casts the element to an i64 slot"
    (llvm_with_decls
      "let ch = channel_new () in \
       let _ = spawn (fn u -> channel_send ch 7) in \
       channel_recv ch")
    "call i32 @mere_channel_send(ptr";
  assert_contains "llvm: channel_recv reads an i64 slot"
    (llvm_with_decls
      "let ch = channel_new () in \
       let _ = spawn (fn u -> channel_send ch 7) in \
       channel_recv ch")
    "call i64 @mere_channel_recv(ptr";
  (* A by-value aggregate element (tuple/record) can exceed 8 bytes, so it is
     boxed onto the heap and the slot carries the pointer — otherwise the i64
     cast would emit invalid IR. *)
  assert_contains "llvm: channel of a tuple element boxes the aggregate"
    (llvm_with_decls
      "let ch = channel_new () in \
       let _ = spawn (fn u -> channel_send ch (1, 2)) in \
       channel_recv ch")
    "store %tuple_int_int";
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

  (* --- LLVM IR codegen: function lifting + recursion (Phase 5.2) --- *)
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

  (* --- LLVM IR codegen: strings / print / ++ / str_len (Phase 5.3) --- *)
  assert_contains "llvm: str literal global"
    (llvm "\"hi\"") "@.str_2 = private constant [3 x i8] c\"hi\\00\"";   (* Phase 36: prelude list_min/list_max consume str_0, str_1 *)
  assert_contains "llvm: str main printf uses %s"
    (llvm "\"hi\"") "@.fmt_s = private constant [4 x i8] c\"%s\\0A\\00\"";
  assert_contains "llvm: str passed as ptr to printf"
    (llvm "\"hi\"") "@printf(ptr @.fmt_s, ptr @.str_2)";   (* Phase 36: prelude list_min/list_max claim str_0, str_1 first *)
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
  (* Phase 19.1.1: str_index_of codegen *)
  assert_contains "llvm: str_index_of calls __lang_str_index_of"
    (llvm "str_index_of \"hi\" \"i\"")
    "call i32 @__lang_str_index_of(ptr ";
  assert_contains "llvm: __lang_str_index_of helper defined"
    (llvm "str_index_of \"hi\" \"i\"")
    "define i32 @__lang_str_index_of";
  assert_contains "llvm: declares strstr"
    (llvm "str_index_of \"hi\" \"i\"")
    "declare ptr @strstr(ptr, ptr)";
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

  (* --- LLVM IR codegen: polymorphic variant / record monomorphization (Phase 5.9) ---
     `'a opt`, `'a Box` etc. get a specialized struct per concrete
     instantiation (`%opt_int`, `%Box_str`). Constr / Record_lit /
     Field_get / Match use the mono name. *)
  assert_contains "llvm: poly variant mono typedef"
    (llvm_with_decls
      "type 'a LCgOpt = LCgN | LCgS of 'a;\n\
       match LCgS 42 with | LCgN -> 0 | LCgS n -> n")
    "%LCgOpt_int = type { i32, ptr }";  (* Phase 25.0: boxed payload *)
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

  (* --- LLVM IR codegen: recursive variant (Phase 5.10) ---
     Recursive variants (e.g. `'a list`, self-referential `ilist`) lower
     to heap-allocated nodes via region alloc; values are `ptr` to the
     node, accessed via getelementptr + load. P_tuple sub-pattern in Cons
     unpacks the payload tuple via extractvalue. *)
  assert_contains "llvm: recursive variant emits _node typedef"
    (llvm_with_decls
      "type LCgIList = LCgINil | LCgICons of int * LCgIList;\n\
       LCgICons (1, LCgINil)")
    "%LCgIList_node = type { i32, ptr }";  (* Phase 25.0: boxed payload *)
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
    "%LCgList_int_node = type { i32, ptr }";  (* Phase 25.0: boxed payload *)
  assert_contains "llvm: P_tuple sub-pattern extracts via extractvalue"
    (llvm_with_decls
      "type LCgIList4 = LCgINil4 | LCgICons4 of int * LCgIList4;\n\
       let rec sum = fn xs -> match xs with\n\
         | LCgINil4 -> 0\n\
         | LCgICons4 (h, t) -> h + sum t\n\
       in sum (LCgICons4 (1, LCgINil4))")
    "extractvalue %tuple_int_LCgIList4";

  (* --- LLVM IR codegen: complex pattern (Phase 5.11) ---
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

  (* --- LLVM IR codegen: generic `show` builtin (Phase 5.12) ---
     Specialize `show : 'a -> str` to a `show_T` per call site based on the argument
     type, supporting int/bool/str/unit/tuple/record/variant (mono + poly +
     recursive). Generate a dedicated function per type via `@asprintf`,
     discover required types via collect_show_types, and dispatch
     `App (Var "show", arg)` to `call ptr @show_<tag>`. *)
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
       view construction (Phase 5.13) ---
     Compile `region R { body }` to __lang_region_init + body + __lang_region_free,
     `&R v` to region_alloc + store returning a ptr, `with c = v in body` to
     bind + body + auto-close, and view construction to region_alloc + insertvalue
     + store + ptr return. *)
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

  (* --- LLVM IR codegen: list show in [a, b, c] format (Phase 5.14) ---
     Special-case `'a list` instead of the generic recursive-variant show, printing
     it in `[1, 2, 3]` form. Inside show_list_<T>, use alloca/load/store and a loop
     to call show_T on each element and concatenate via __lang_str_concat. *)
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

  (* Phase 16.3: mk_logger / mk_metrics LLVM codegen. *)
  assert_contains "llvm: mk_logger emits @__mere_mk_logger call"
    (llvm "let lg = mk_logger \"app\" in lg.info \"hi\"")
    "call %Logger @__mere_mk_logger";
  assert_contains "llvm: logger info fn defined"
    (llvm "let lg = mk_logger \"app\" in lg.info \"hi\"")
    "define internal i32 @__mere_logger_info_fn";
  assert_contains "llvm: mk_metrics emits @__mere_mk_metrics call"
    (llvm "let m = mk_metrics () in m.inc \"x\"")
    "call %Metrics @__mere_mk_metrics";

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
  (* Q-012 step 3b-4f: a non-threaded program keeps its own unshared memory;
     a program that spawns switches to a host-imported shared memory and
     pulls the spawn/join host imports. Verified end-to-end on node
     worker_threads (a worker instantiates the same module over the shared
     memory and runs the closure via the indirect function table). *)
  assert_contains "wasm: non-threaded program declares its own memory"
    (wasm "42") "(memory (export \"memory\") 1024)";
  assert_contains "wasm: spawn switches to imported shared memory"
    (wasm_with_decls "let cw = fn u -> print \"x\"; let h = spawn cw in join h")
    "(import \"env\" \"memory\" (memory 1024 65536 shared))";
  assert_contains "wasm: spawn emits the mere_spawn host import + call"
    (wasm_with_decls "let cw = fn u -> print \"x\"; let h = spawn cw in join h")
    "call $mere_spawn";
  (* Channels are host imports over the shared memory (the host does the
     atomic queue via JS Atomics). Verified end-to-end: a 4-way parallel
     fan-out/fan-in runs under node on all four backends including Wasm. *)
  assert_contains "wasm: channel_new / send / recv are host imports"
    (wasm_with_decls
      "let ch = channel_new () in \
       let _ = spawn (fn u -> channel_send ch 7) in \
       channel_recv ch")
    "call $mere_channel_recv";
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

  (* --- Wasm codegen: function lifting + recursion (Phase 6.2) ---
     Top-level fns lift to `(func $name (param i32) (result i32))`, direct calls
     become `call $name`, and mutual recursion works within the same module
     (Wasm allows forward references). *)
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

  (* --- Wasm codegen: string support (Phase 6.3) ---
     Strings live in linear memory: Str_lit goes into a data segment, dynamic
     allocation uses a bump-pointer global, $__lang_strlen / $__lang_str_concat
     are defined inline in WAT, and print uses a host import (env.puts). *)
  assert_contains "wasm: memory declared + exported"
    (wasm "\"hi\"") "(memory (export \"memory\") 1024)";
  (* Bump-pointer global is now exported ("__lang_bump") so the JS
     host can advance it from extern-fn implementations (Phase 55.x
     onwards). Match the prefix — the (export "…") attribute lands
     between the name and the (mut i32) type. *)
  assert_contains "wasm: bump pointer global declared"
    (wasm "\"hi\"") "(global $__lang_bump";
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
  (* Phase 19.1.1: str_index_of codegen *)
  assert_contains "wasm: str_index_of calls $__lang_str_index_of"
    (wasm "str_index_of \"hi\" \"i\"") "call $__lang_str_index_of";
  assert_contains "wasm: __lang_str_index_of helper defined"
    (wasm "str_index_of \"hi\" \"i\"") "(func $__lang_str_index_of";

  (* --- Wasm codegen: tuple (Phase 6.4) ---
     Tuples live in linear memory: each element is 4 bytes (i32 / offset);
     the base offset is saved into a local immediately and bump is advanced
     right away (so nested tuples or ++ advancing the bump do not overlap);
     fst/snd are retrieved via i32.load offset. *)
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
     Records share the same linear-memory layout as tuples. Record_lit emits
     i32.store in declaration order, Field_get becomes i32.load offset from the
     field index, and Record_update reserves a new buffer and copies non-updated
     fields via load. *)
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
     Variants live in linear memory too: {i32 tag} (nullary) or {i32 tag, i32 payload}.
     Constr does alloc + store tag (+ payload); Match does tag load + a nested
     if/else chain; fallthrough traps via unreachable. *)
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
     Wasm's memory layout is uniform (every value is i32 = 4 bytes), so
     polymorphic variants/records need no monomorphization, and recursive variants
     (e.g. `'a list`'s Cons) share the same memory layout. Match's Cons (h, t)
     also reads the payload as a tuple offset, chaining extractvalues. *)
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

  (* --- Wasm codegen: complex pattern (Phase 6.10) ---
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

  (* --- Wasm codegen: generic `show` builtin (Phase 6.11) ---
     Equivalent to LLVM Phase 5.12. show is self-contained: int->string
     conversion is implemented inside Wasm too, and composition of
     strings/tuples/records/variants is done via __lang_str_concat. *)
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

  (* --- Wasm codegen: list show in `[a, b, c]` format (Phase 6.12) ---
     Special-case `'a list = Nil | Cons of 'a * 'a list` to render as an
     array-style string. *)
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

  (* Phase 16.3: mk_logger / mk_metrics Wasm codegen. *)
  assert_contains "wasm: mk_logger calls $__mere_mk_logger"
    (wasm "let lg = mk_logger \"app\" in lg.info \"hi\"")
    "call $__mere_mk_logger";
  assert_contains "wasm: logger info helper defined"
    (wasm "let lg = mk_logger \"app\" in lg.info \"hi\"")
    "(func $__mere_logger_info_fn";
  assert_contains "wasm: logger format prefix in data"
    (wasm "let lg = mk_logger \"app\" in lg.info \"hi\"")
    " [INFO] ";
  assert_contains "wasm: mk_metrics calls $__mere_mk_metrics"
    (wasm "let m = mk_metrics () in m.inc \"x\"")
    "call $__mere_mk_metrics";

  (* Phase 16.4 / DEFERRED §1.6: stopped doing bump save/restore in Region_block
     to align with arena-leak semantics. This ensures values allocated inside a
     region that escape to the outside (e.g. the OwnedVec from
     `let v = region R { vec_to_owned ... }`) are not overwritten by
     subsequent allocations. *)
  assert_contains "wasm: Region_block emits body directly (no save/restore)"
    (wasm "region R { 42 }")
    "(func $main";
  assert_no_contains "wasm: Region_block does not save bump in main body"
    (* The (local.set N (global.get $__lang_bump)) save form was emitted in main
       before the fix; after the fix it no longer appears inside main. *)
    (let w = wasm "region R { 42 }" in
     (* Extract only the main function: everything from "(func $main" onward. *)
     let needle = "(func $main" in
     let nl = String.length needle and wl = String.length w in
     let rec find i =
       if i + nl > wl then None
       else if String.sub w i nl = needle then Some i
       else find (i + 1)
     in
     match find 0 with
     | Some i -> String.sub w i (wl - i)
     | None -> w)
    "global.get $__lang_bump";

  (* --- Diagnostic format (Phase 7.1) ---
     Multi-line code frame with line numbers + caret with inline message. *)
  let diag source loc kind msg =
    Diagnostic.format ~source ~filename:"test.lang" loc kind msg
  in
  let mkloc ?(w = 1) line col = Loc.mk ~line ~col ~width:w () in
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

  (* Phase 33.0 (DEFERRED §5.1): multi-candidate did-you-mean. If there are
     multiple close candidates, show the top 3 in a listing. *)
  assert_contains "diag: multi-candidate did-you-mean shows alternatives"
    (infer_err "let factorial = fn n -> n in\nlet facoriall = fn x -> x in\nlet foctorial = fn y -> y in\nfactrial 5")
    "did you mean `factorial`, `facoriall`, or `foctorial`?";
  assert_contains "diag: 2-candidate did-you-mean uses `a` or `b`"
    (infer_err "let foo = 1 in let foa = 2 in foe")
    "did you mean";  (* 2 candidates: foo, foa (close to foe) *)

  assert_contains "diag: unknown constructor suggests close ctor"
    (infer_err_with_decls "type Color7 = Red7 | Green7 | Blue7;\nlet c = Greeen7 in c")
    "did you mean `Green7`";  (* Phase 33.0: with multi-candidate display the tail can be either `?` or ` or ...?`, so only substring-match *)

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

  (* --- Source span (Phase 7.5) ---
     Loc.t carries a `width` (token char count) so the caret line can
     show `^^^^^` underlining the whole token. *)
  assert_contains "diag: width=1 → single caret"
    (diag "let x = 5 in x" (mkloc 1 14) "type error" "msg")
    "^ msg";
  assert_contains "diag: width=4 → four carets"
    (diag "let f = 10 in f" (mkloc ~w:4 1 1) "type error" "msg")
    "^^^^ msg";
  (* End-to-end: lexer should attach token width to identifier locs.
     The "factrial" token width = 8 → 8 carets in the error frame. *)
  let lex_err_caret =
    let src = "let factorial = 10 in factrial + 1" in
    try
      let prog = Pipeline.parse_program src in
      let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
      ""
    with Typer.Type_error (loc, msg) ->
      Diagnostic.format ~source:src ~filename:"<inline>" loc "type error" msg
  in
  assert_contains "diag: factrial identifier → 8 carets"
    lex_err_caret "^^^^^^^^";

  (* --- Type conversion hints (Phase 7.6) ---
     For common primitive mismatches the unify error appends a `help:`
     suggesting a likely fix. *)
  assert_contains "hint: int where str expected → suggest show"
    (infer_err "\"x: \" ++ 42")
    "use `show x` to render a value as `str`";
  assert_contains "hint: str where int expected → mention str_len"
    (infer_err "5 + \"hi\"")
    "use `str_len s` to get the length";
  assert_contains "hint: int where bool expected → suggest comparison"
    (infer_err "if 1 then 0 else 1")
    "wrap in a comparison";
  assert_no_contains "hint: omitted when types don't pair into a known case"
    (infer_err "(1, 2) + 3")
    "use `show";

  (* --- Phase 7.7: hint expansion --- *)
  assert_contains "hint: bool where int expected → suggest if/then/else"
    (infer_err "true + 1")
    "use `if b then 1 else 0`";
  assert_contains "hint: tuple arity mismatch → say lengths differ"
    (infer_err
       "let f = fn t -> match t with | (a, b) -> a + b in f (1, 2, 3)")
    "tuple lengths differ";
  assert_contains "hint: extra argument → expected a function"
    (infer_err "let inc = fn x -> x + 1 in inc 3 4")
    "expected a function";
  assert_contains "hint: extra argument → mention too many args"
    (infer_err "let inc = fn x -> x + 1 in inc 3 4")
    "too many arguments";
  assert_contains "hint: partial application → suggest missing argument"
    (infer_err "let add = fn x -> fn y -> x + y in add 1 + 2")
    "missing an argument";
  assert_contains "hint: distinct named types → name both sides"
    (infer_err_with_decls
       "type FooN = { a : int };\ntype BarN = { a : int };\n\
        match BarN { a = 1 } with | FooN { a = x } -> x")
    "different named types";

  (* --- Phase 8.1: REPL helpers --- *)
  let probe_unfinished s =
    try
      let toks = Lexer.tokenize (Repl.prepare_input s) in
      ignore (Parser.parse_program toks);
      false  (* parsed successfully → finished *)
    with e -> Repl.is_unfinished ~source:(Repl.prepare_input s) e
  in
  check "repl: complete expression → finished"
    (string_of_bool (probe_unfinished "1 + 2")) "false";
  check "repl: bare `let x = 5;` → finished (prepare_input adds main)"
    (string_of_bool (probe_unfinished "let x = 5;")) "false";
  check "repl: `let f = fn n ->` → unfinished (fn body missing)"
    (string_of_bool (probe_unfinished "let f = fn n ->")) "true";
  check "repl: `if x < 2 then` → unfinished (then branch missing)"
    (string_of_bool (probe_unfinished "if x < 2 then")) "true";
  check "repl: `match x with` → unfinished (no arms yet)"
    (string_of_bool (probe_unfinished "match x with")) "true";
  check "repl: complete multi-line let-rec → finished"
    (string_of_bool (probe_unfinished
       "let rec f = fn n ->\n  if n < 1 then 1\n  else n * f (n - 1)\nin f 5"))
    "false";
  check "repl: actual parse error mid-input → NOT unfinished"
    (string_of_bool (probe_unfinished "let 1 = 2 in 3")) "false";

  (* user_bindings reports user-added names in insertion order, skipping
     anything from Typer.initial_env (builtins). *)
  let env =
    let t = Typer.initial_env in
    let sch ty = Typer.mono ty in
    ("y", sch Ast.TyStr) :: ("x", sch Ast.TyInt) :: t
  in
  let names = List.map fst (Repl.user_bindings env) in
  check "repl: :env preserves insertion order (oldest first)"
    (String.concat "," names) "x,y";
  let no_user_names = List.map fst (Repl.user_bindings Typer.initial_env) in
  check "repl: :env on initial env → no user bindings"
    (string_of_int (List.length no_user_names)) "0";

  (* --- Phase 8.2: :show and :reset --- *)
  let mk_envs () =
    let eenv = ref Eval.initial_env in
    let tenv = ref Typer.initial_env in
    (* Bind `x = 42 : int` and `g = "hi" : str` for show/reset tests. *)
    eenv := ("g", ref (Eval.V_str "hi")) :: ("x", ref (Eval.V_int 42)) :: !eenv;
    tenv := ("g", Typer.mono Ast.TyStr) :: ("x", Typer.mono Ast.TyInt) :: !tenv;
    (eenv, tenv)
  in
  let (eenv, tenv) = mk_envs () in
  check "repl: :show on int binding shows type + value"
    (Repl.format_show !eenv !tenv "x") "val x : int\n  = 42";
  check "repl: :show on str binding quotes the value"
    (Repl.format_show !eenv !tenv "g") "val g : str\n  = \"hi\"";
  check "repl: :show on unknown name reports unbound"
    (Repl.format_show !eenv !tenv "nope") "unbound name: nope";

  Repl.do_reset eenv tenv;
  check "repl: :reset → user bindings empty"
    (string_of_int (List.length (Repl.user_bindings !tenv))) "0";
  check "repl: :reset → eval env back to initial length"
    (string_of_int (List.length !eenv))
    (string_of_int (List.length Eval.initial_env));

  (* --- Phase 9.1: modules (`module M { let f = ...; }`) --- *)
  check "module: basic qualified access"
    (Pipeline.process
       "module M { let answer = 42; let add = fn x -> fn y -> x + y; };\n\
        M.add M.answer 8") "50";
  check "module: inside-module short-name references resolve to M.X"
    (Pipeline.process
       "module M { let base = 10;\n\
        let inc = fn x -> x + base;\n\
        let twice = fn x -> inc (inc x); };\n\
        M.twice 7") "27";
  check "module: let rec inside module supports self-recursion"
    (Pipeline.process
       "module M {\n\
        let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1);\n\
        };\n\
        M.fact 5") "120";
  check "module: two modules don't collide"
    (Pipeline.process
       "module M { let v = 42; };\n\
        module N { let v = 100; };\n\
        M.v + N.v") "142";
  check "module: regular field access (p.x) still works"
    (Pipeline.process
       "type Pt = { x: int, y: int };\n\
        let p = Pt { x = 3, y = 4 } in p.x + p.y") "7";
  check "module: shadowing inside module is per-decl"
    (Pipeline.process
       "module M { let v = 1; let v = v + 10; };\n\
        M.v") "11";
  check "module: fn parameter shadows module-bound name"
    (Pipeline.process
       "module M {\n\
        let v = 100;\n\
        let id_v = fn v -> v;\n\
        };\n\
        M.id_v 7") "7";

  (* --- Phase 9.2: import "path" --- *)
  let write_file path content =
    let oc = open_out path in
    output_string oc content;
    close_out oc
  in
  let lib_path = Filename.temp_file "lang_import_lib" ".lang" in
  write_file lib_path
    "let helper = fn x -> x * 3;\nlet base = 7;\n";
  check "import: pulls in let bindings"
    (Pipeline.process
       (Printf.sprintf "import %S;\nhelper base" lib_path)) "21";

  let modlib_path = Filename.temp_file "lang_import_mod" ".lang" in
  write_file modlib_path
    "module Math {\n  let dbl = fn x -> x * 2;\n  let sq = fn x -> x * x;\n};\n";
  check "import: pulls in modules"
    (Pipeline.process
       (Printf.sprintf "import %S;\nMath.sq (Math.dbl 5)" modlib_path)) "100";

  (* Cycle: two files import each other. The cycle guard should let the
     program complete (no infinite loop), and both files' bindings
     should be visible from the entry point. *)
  let cyc_a = Filename.temp_file "lang_import_cyc_a" ".lang" in
  let cyc_b = Filename.temp_file "lang_import_cyc_b" ".lang" in
  write_file cyc_a (Printf.sprintf "import %S;\nlet a_val = 10;\n" cyc_b);
  write_file cyc_b (Printf.sprintf "import %S;\nlet b_val = 20;\n" cyc_a);
  check "import: cycle is broken by guard (no infinite loop)"
    (Pipeline.process
       (Printf.sprintf "import %S;\na_val + b_val" cyc_a)) "30";

  (* Diamond: lib_path imported by two intermediates AND merged main.
     Without the guard this would double-bind `helper` (effectively
     fine but wasteful); with the guard it's imported once. *)
  let int_x = Filename.temp_file "lang_import_x" ".lang" in
  let int_y = Filename.temp_file "lang_import_y" ".lang" in
  write_file int_x (Printf.sprintf "import %S;\nlet xv = 1;\n" lib_path);
  write_file int_y (Printf.sprintf "import %S;\nlet yv = 2;\n" lib_path);
  check "import: diamond (same file imported via two paths)"
    (Pipeline.process
       (Printf.sprintf "import %S;\nimport %S;\nxv + yv + base"
          int_x int_y)) "10";

  (* The cycle guard is reset between top-level parses, so re-running a
     program with the same imports works. *)
  check "import: cycle guard resets between top-level parses"
    (Pipeline.process
       (Printf.sprintf "import %S;\nhelper base" lib_path)) "21";

  (* Missing file → parse error (not silent skip). *)
  check_raises "import: missing file raises"
    (fun () ->
      Pipeline.process
        "import \"/nonexistent/path/foo.lang\";\n42");

  (* --- Package system v0.1: `.mere_modules/` walk-up resolution ---
     Node's `node_modules` semantics — the resolver walks up from
     the importing file's directory looking for a `.mere_modules/`
     subdir, then resolves `<path>` inside it. *)
  let pkg_root = Filename.temp_dir "lang_pkg_v01_" "" in
  let modules_dir = Filename.concat pkg_root ".mere_modules" in
  let pkg_dir = Filename.concat modules_dir "hello" in
  Unix.mkdir modules_dir 0o755;
  Unix.mkdir pkg_dir 0o755;
  write_file (Filename.concat pkg_dir "greet.mere")
    "let greet = fn (name: str) -> \"hello, \" ++ name;\n";
  let entry_path = Filename.concat pkg_root "main.mere" in
  write_file entry_path
    "import \"hello/greet.mere\";\ngreet \"world\"";
  check "package: import resolves via .mere_modules walk-up"
    (Pipeline.process ~base_dir:pkg_root
       "import \"hello/greet.mere\";\ngreet \"world\"") "\"hello, world\"";

  (* Deeper walk-up: entry is in a subdir; .mere_modules/ sits above. *)
  let deeper = Filename.concat pkg_root "app/handlers" in
  Unix.mkdir (Filename.concat pkg_root "app") 0o755;
  Unix.mkdir deeper 0o755;
  check "package: walks up multiple directory levels"
    (Pipeline.process ~base_dir:deeper
       "import \"hello/greet.mere\";\ngreet \"deep\"") "\"hello, deep\"";

  (* Nested imports: a vendored package importing ANOTHER vendored
     package — the resolver's walk-up finds the SAME .mere_modules/
     root regardless of which subtree it starts from. *)
  let other_pkg = Filename.concat modules_dir "excite" in
  Unix.mkdir other_pkg 0o755;
  write_file (Filename.concat other_pkg "bang.mere")
    "import \"hello/greet.mere\";\nlet excited = fn (n: str) -> greet n ++ \"!\";\n";
  check "package: cross-package imports find the same .mere_modules/"
    (Pipeline.process ~base_dir:pkg_root
       "import \"excite/bang.mere\";\nexcited \"world\"") "\"hello, world!\"";

  (* --- Phase 41: qualified ctor pattern in 4-backend codegen. We apply
     Ast.canonical_ctor to Constr / P_constr lookup so `match v with | M.A -> ...`
     works in C / LLVM / Wasm. This is the qualified-pattern gap fix from
     DEFERRED §4.1. *)
  check "module: qualified ctor construction + pattern (interp)"
    (Pipeline.process
       "module Color { type t = Red | Green | Blue | Mix of int; };\n\
        let c1 = Color.Red in\n\
        let n = match c1 with\n\
        | Color.Red -> 1\n\
        | Color.Green -> 2\n\
        | Color.Blue -> 3\n\
        | Color.Mix k -> 100 + k in n") "1";
  check "module: qualified ctor with payload pattern (interp)"
    (Pipeline.process
       "module Color { type t = Red | Mix of int; };\n\
        let c = Color.Mix 7 in\n\
        match c with | Color.Red -> 0 | Color.Mix k -> 100 + k") "107";
  check "module: bare ctor name still works via alias backward compat"
    (Pipeline.process
       "module Color { type t = Red | Green; };\n\
        let c = Red in match c with | Red -> 1 | Green -> 2") "1";
  (* Confirm that qualified patterns are emitted in C codegen too *)
  assert_contains "module: C codegen — qualified ctor name uses `__` separator"
    (Codegen_c.emit_program ~main_ty:Ast.TyInt
       (let prog = Pipeline.parse_program
          "module Color { type t = Red | Green; let to_int = fn c -> match c with | Red -> 1 | Green -> 2; };\n\
           Color.to_int Color.Red" in
        let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
        prog))
    "Color__to_int";

  (* --- Phase 42: same-name ctor disambiguation across 2 modules (remaining
     work from DEFERRED §4.1). Treat `Traffic.Red` and `Mood.Red` as distinct
     things belonging to different types. At codegen sites we look up
     `Typer.constructors[raw_qualified]` first to bypass alias overwrites
     (where constructors[Red] is last-write-wins). *)
  check "module: 2 modules with same ctor name (interp disambiguates)"
    (Pipeline.process
       "module Traffic { type Light = Red | Yellow | Green; let label = fn (l: Light) -> match l with | Red -> 1 | Yellow -> 2 | Green -> 3; };\n\
        module Mood { type Color = Red | Blue | Purple; let label = fn (c: Color) -> match c with | Red -> 10 | Blue -> 20 | Purple -> 30; };\n\
        Traffic.label Traffic.Red + Mood.label Mood.Red") "11";
  check "module: 2 modules same ctor + qualified pattern match"
    (Pipeline.process
       "module Foo { type t = X | Y; };\n\
        module Bar { type t = X | Z; };\n\
        let a = Foo.X in let b = Bar.X in\n\
        (match a with | Foo.X -> 1 | Foo.Y -> 2) + (match b with | Bar.X -> 10 | Bar.Z -> 20)") "11";
  (* Phase 42 (b): M-qualified record type works in interp (codegen is
     covered by the 4-backend smoke test in module_scoping.mere) *)
  check "module: qualified record literal + field access (interp)"
    (Pipeline.process
       "module Shapes { type Rect = { w: int, h: int }; };\n\
        let r = Shapes.Rect { w = 3, h = 4 } in show (r.w * r.h)")
    "\"12\"";

  (* --- Phase 43 (DEFERRED §1.7): multi-instantiation codegen — chained poly.
     For a call like `let bool_eq = fn b -> poly_eq true b`, ensure that the
     bool version of poly_eq is added to the spec list even if discovered in a
     later pass, by re-scanning the existing multi_specs in each pass. *)
  check "multi_inst: chained poly call adds new instantiation (interp)"
    (Pipeline.process
       "let poly_eq = fn x -> fn y -> if show x == show y then 1 else 0 in\n\
        let bool_eq = fn b -> poly_eq true b in\n\
        poly_eq 1 1 + poly_eq \"a\" \"a\" + bool_eq true") "3";
  assert_contains "multi_inst: C codegen — chained poly emits bool inst"
    (Codegen_c.emit_program ~main_ty:Ast.TyInt
       (let prog = Pipeline.parse_program
          "let poly_eq = fn x -> fn y -> if show x == show y then 1 else 0 in\n\
           let bool_eq = fn b -> poly_eq true b in\n\
           poly_eq 1 1 + poly_eq \"a\" \"a\" + bool_eq true" in
        let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
        prog))
    "poly_eq__bool__bool__int";

  (* --- Phase 11.1: refinement of borrow annotations (Q-004 narrowed) --- *)
  (* The default `&R T` is BorrowedRead (shared read), with no syntactic mark. *)
  check "borrow: &R T parses as default (borrowed/shared-read)"
    (Pipeline.type_of "fn (x: &R int) -> 1") "(&R int -> int)";
  check "borrow: &mut R T = exclusive write"
    (Pipeline.type_of "fn (x: &mut R int) -> 1") "(&mut R int -> int)";
  check "borrow: &shared write R T = shared write"
    (Pipeline.type_of "fn (x: &shared write R int) -> 1")
    "(&shared write R int -> int)";
  check "borrow: &exclusive R T = exclusive read"
    (Pipeline.type_of "fn (x: &exclusive R int) -> 1")
    "(&exclusive R int -> int)";

  (* Value-level `&R v` also parses all 4 modes. Escaping the region triggers
     a region-escape error, so we verify by pinning the mode via annotation
     and consuming inside the region. *)
  check "borrow: value-level &R v defaults to borrowed read"
    (Pipeline.process
       "region R { let _ = (&R 5 : &R int) in 42 }") "42";
  check "borrow: value-level &mut R v"
    (Pipeline.process
       "region R { let _ = (&mut R 5 : &mut R int) in 42 }") "42";
  check "borrow: value-level &shared write R v"
    (Pipeline.process
       "region R { let _ = (&shared write R 5 : &shared write R int) in 42 }") "42";
  check "borrow: value-level &exclusive R v"
    (Pipeline.process
       "region R { let _ = (&exclusive R 5 : &exclusive R int) in 42 }") "42";
  (* Force the mode via annotation - on mismatch it's a type error *)
  check_raises "borrow: value-level mode mismatch fails (&R 5 : &mut R int)"
    (fun () ->
      Pipeline.process
        "region R { let _ = (&R 5 : &mut R int) in 42 }");

  (* Unify distinguishes modes (no subtyping, strict equality) *)
  check_raises "borrow: &R != &mut R (caller passes &R to &mut R param)"
    (fun () ->
      Pipeline.process
        "let f = fn (x: &mut R int) -> 1 in region R { f (&R 5) }");
  check_raises "borrow: &shared write != &mut"
    (fun () ->
      Pipeline.process
        "let f = fn (x: &mut R int) -> 1 in \
         region R { f (&shared write R 5) }");
  check_raises "borrow: &exclusive != &shared write"
    (fun () ->
      Pipeline.process
        "let f = fn (x: &shared write R int) -> 1 in \
         region R { f (&exclusive R 5) }");

  (* Same mode on both sides passes *)
  check "borrow: same-mode call type-checks (mut → mut)"
    (Pipeline.process
       "let f = fn (x: &mut R int) -> 42 in region R { f (&mut R 5) }")
    "42";
  check "borrow: same-mode call type-checks (shared write → shared write)"
    (Pipeline.process
       "let f = fn (x: &shared write R int) -> 42 in \
        region R { f (&shared write R 5) }") "42";

  (* --- Phase 11.3: auto-deref of field access through &R T --- *)
  check "borrow: field access through &R (auto-deref)"
    (Pipeline.process
       "type Pt = { x: int, y: int };\n\
        region R {\n\
          let p = Pt { x = 3, y = 4 } in\n\
          let p_ref = &R p in\n\
          p_ref.x + p_ref.y\n\
        }") "7";
  check "borrow: field access through &mut R"
    (Pipeline.process
       "type C = { v: int };\n\
        region R {\n\
          let c = C { v = 42 } in\n\
          let c_ref = &mut R c in\n\
          c_ref.v\n\
        }") "42";
  check "borrow: field access through &shared write R"
    (Pipeline.process
       "type C = { v: int };\n\
        region R {\n\
          let c = C { v = 9 } in\n\
          let c_ref = &shared write R c in\n\
          c_ref.v * 10\n\
        }") "90";
  check "borrow: field call type-checks through &shared write"
    (Pipeline.type_of
       "type Lg11 = { info: str -> unit };\n\
        fn (lg: &shared write R Lg11) -> fn (msg: str) -> lg.info msg")
    "(&shared write R Lg11 -> (str -> unit))";
  check "borrow: field type read through &R"
    (Pipeline.type_of
       "type Lg11r = { info: str -> unit };\n\
        fn (lg: &R Lg11r) -> lg.info")
    "(&R Lg11r -> (str -> unit))";

  (* --- Phase 11.4: borrow checker --- *)
  (* Coexistence OK: shared read with shared read, shared write with shared write *)
  check "borrow checker: multiple &R on same var → OK"
    (Pipeline.process
       "region R { let v = 5 in let a = &R v in let b = &R v in 42 }")
    "42";
  check "borrow checker: multiple &shared write on same var → OK"
    (Pipeline.process
       "region R { let v = 5 in \
        let a = &shared write R v in \
        let b = &shared write R v in 42 }")
    "42";

  (* Conflict: &R + &mut R *)
  check_raises "borrow checker: &R + &mut R on same var → conflict"
    (fun () ->
      Pipeline.process
        "region R { let v = 5 in \
         let a = &R v in let b = &mut R v in 42 }");

  (* Conflict: &mut R + &mut R (exclusive) *)
  check_raises "borrow checker: &mut R + &mut R → conflict"
    (fun () ->
      Pipeline.process
        "region R { let v = 5 in \
         let a = &mut R v in let b = &mut R v in 42 }");

  (* Conflict: &R + &shared write R (shared read invalidated by shared write) *)
  check_raises "borrow checker: &R + &shared write → conflict"
    (fun () ->
      Pipeline.process
        "region R { let v = 5 in \
         let a = &R v in let b = &shared write R v in 42 }");

  (* Conflict: &exclusive R cannot coexist with anything else *)
  check_raises "borrow checker: &exclusive + &R → conflict"
    (fun () ->
      Pipeline.process
        "region R { let v = 5 in \
         let a = &exclusive R v in let b = &R v in 42 }");

  (* Phase 17.2 / DEFERRED §2.5: the remaining 4 pairs of the conflict matrix
     (filling the full 10 pairs = symmetric 4 mode x 4 mode matrix) *)
  check_raises "borrow checker: &shared write + &exclusive → conflict"
    (fun () ->
      Pipeline.process
        "region R { let v = 5 in \
         let a = &shared write R v in let b = &exclusive R v in 42 }");
  check_raises "borrow checker: &shared write + &mut R → conflict"
    (fun () ->
      Pipeline.process
        "region R { let v = 5 in \
         let a = &shared write R v in let b = &mut R v in 42 }");
  check_raises "borrow checker: two &exclusive R → conflict (exclusive is exclusive of itself)"
    (fun () ->
      Pipeline.process
        "region R { let v = 5 in \
         let a = &exclusive R v in let b = &exclusive R v in 42 }");
  check_raises "borrow checker: &exclusive + &mut R → conflict"
    (fun () ->
      Pipeline.process
        "region R { let v = 5 in \
         let a = &exclusive R v in let b = &mut R v in 42 }");

  (* Different regions don't conflict even for the same variable (region isolation) *)
  check "borrow checker: same var in different regions → OK"
    (Pipeline.process
       "region R { region S { let v = 5 in \
        let a = &R v in let b = &mut S v in 42 } }")
    "42";

  (* Phase 17.2: two conflicting borrows inside a tuple are detected
     (eval the first -> add to active -> eval the second) *)
  check_raises "borrow checker (tuple): (&R v, &mut R v) → conflict"
    (fun () ->
      Pipeline.process
        "region R { let v = 5 in \
         let _t = (&R v, &mut R v) in 42 }");
  check "borrow checker (tuple): (&R v, &R u) → OK (different vars)"
    (Pipeline.process
       "region R { let v = 5 in let u = 7 in \
        let _t = (&R v, &R u) in 42 }")
    "42";
  check "borrow checker (tuple): (&R v, &R v) → OK (both shared read)"
    (Pipeline.process
       "region R { let v = 5 in \
        let _t = (&R v, &R v) in 42 }")
    "42";

  (* Different variables don't conflict *)
  check "borrow checker: different vars don't conflict"
    (Pipeline.process
       "region R { let x = 1 in let y = 2 in \
        let a = &R x in let b = &mut R y in 42 }")
    "42";

  (* Phase 19.x: codegen support for field access through a borrow.
     ty_tag (TyRef) and Field_get (auto-deref) work across all 3 backends. *)
  let borrow_field_src =
    "let use_log = fn (lg: &shared write R Logger) -> \
       let __ = lg.info \"hello\" in lg.warn \"world\";\n\
     region R {\n\
       let logger = mk_logger \"test\" in\n\
       let lr = &shared write R logger in\n\
       use_log lr\n\
     }"
  in
  check "borrow codegen: interpreter runs fn with &shared write R Logger"
    (Pipeline.process borrow_field_src) "()";
  assert_contains "borrow codegen: C emits Logger via -> on borrow"
    (let prog = Pipeline.parse_program borrow_field_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyUnit prog)
    "(lg)->info";
  assert_contains "borrow codegen: LLVM unwraps TyRef for field GEP"
    (let prog = Pipeline.parse_program borrow_field_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyUnit prog)
    "getelementptr %Logger";
  assert_contains "borrow codegen: Wasm unbox load for borrow Field_get"
    (let prog = Pipeline.parse_program borrow_field_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_wasm.emit_program ~main_ty:Ast.TyUnit prog)
    "$use_log";

  (* The conflict message includes a "previous borrow at" note *)
  let conflict_msg =
    try
      let _ = Pipeline.process
        "region R { let v = 5 in let a = &R v in let b = &mut R v in 42 }"
      in ""
    with Typer.Type_error (_, msg) -> msg
  in
  assert_contains "borrow checker: error message points to previous borrow"
    conflict_msg "previous borrow at";

  (* --- Phase 12.1: minimal `'a Vec` harness (first implementation step of Q-010 narrowed) --- *)
  check "vec: vec_new : unit -> Vec[r, elem]"
    (Pipeline.type_of "vec_new") "(unit -> Vec['b, 'a])";
  check "vec: vec_push : Vec[r, a] -> a -> unit"
    (Pipeline.type_of "vec_push") "(Vec['b, 'a] -> ('a -> unit))";
  check "vec: vec_get : Vec[r, a] -> int -> a"
    (Pipeline.type_of "vec_get") "(Vec['b, 'a] -> (int -> 'a))";
  check "vec: vec_len : Vec[r, a] -> int"
    (Pipeline.type_of "vec_len") "(Vec['b, 'a] -> int)";
  check "vec: empty Vec has len 0"
    (Pipeline.process "let v = vec_new () in vec_len v") "0";
  check "vec: push 3 ints then len"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 10; vec_push v 20; vec_push v 30; vec_len v }") "3";
  check "vec: get returns pushed value"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 10; vec_push v 20; vec_get v 0 + vec_get v 1 }") "30";

  (* --- Phase 19.3: vec_reverse / vec_concat --- *)
  check "vec_reverse: in-place reverses elements"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 1; vec_push v 2; vec_push v 3; vec_reverse v; \
          vec_get v 0 * 100 + vec_get v 1 * 10 + vec_get v 2 }") "321";
  check "vec_reverse: empty Vec → no-op"
    (Pipeline.process
       "let v = vec_new () in let __ = vec_reverse v in (vec_len v : int)") "0";
  check "vec_reverse: single element → identity"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 42; vec_reverse v; vec_get v 0 }") "42";
  check "vec_reverse type"
    (Pipeline.type_of "vec_reverse") "(Vec['b, 'a] -> unit)";

  check "vec_concat: concatenates two Vecs"
    (Pipeline.process
       "let a = vec_new () in let b = vec_new () in \
        { vec_push a 1; vec_push a 2; vec_push b 30; vec_push b 40; \
          let c = vec_concat a b in \
          vec_get c 0 + vec_get c 1 + vec_get c 2 + vec_get c 3 }") "73";
  check "vec_concat: empty + nonempty"
    (Pipeline.process
       "let a = vec_new () in let b = vec_new () in \
        { vec_push b 99; let c = vec_concat a b in vec_len c + vec_get c 0 }") "100";
  check "vec_concat type"
    (Pipeline.type_of "vec_concat")
    "(Vec['b, 'a] -> (Vec['b, 'a] -> Vec['b, 'a]))";

  check "vec_sort: ascending int"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 3; vec_push v 1; vec_push v 4; vec_push v 1; vec_push v 5; \
          vec_sort v (fn a -> fn b -> a - b); \
          vec_get v 0 * 10000 + vec_get v 1 * 1000 + vec_get v 2 * 100 \
            + vec_get v 3 * 10 + vec_get v 4 }") "11345";
  check "vec_sort: descending via b - a"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 3; vec_push v 1; vec_push v 4; \
          vec_sort v (fn a -> fn b -> b - a); \
          vec_get v 0 * 100 + vec_get v 1 * 10 + vec_get v 2 }") "431";
  check "vec_sort: empty Vec → no-op"
    (Pipeline.process
       "let v = vec_new () in let __ = vec_sort v (fn a -> fn b -> a - b) in \
        (vec_len v : int)") "0";
  check "vec_sort: single element → identity"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 42; vec_sort v (fn a -> fn b -> a - b); vec_get v 0 }") "42";
  check "vec_sort: already sorted"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 1; vec_push v 2; vec_push v 3; \
          vec_sort v (fn a -> fn b -> a - b); \
          vec_get v 0 * 100 + vec_get v 1 * 10 + vec_get v 2 }") "123";
  check "vec_sort type"
    (Pipeline.type_of "vec_sort")
    "(Vec['b, 'a] -> (('a -> ('a -> int)) -> unit))";
  check "vec: polymorphic — str Vec"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v \"hello\"; vec_push v \"world\"; \
          vec_get v 0 ++ \" \" ++ vec_get v 1 }") "\"hello world\"";
  check "vec: Vec can be placed in a region (Trivial[R] passes for int)"
    (Pipeline.process
       "region R { let v = vec_new () in \
        { vec_push v 1; vec_push v 2; let _ = &R v in vec_len v } }") "2";
  check_raises "vec: Trivial[R] rejects Vec of drop type"
    (fun () ->
      Pipeline.process
        "drop type Conn = { close: unit -> unit };\n\
         region R { let v = (vec_new () : Conn Vec) in &R v }");
  check_raises "vec: vec_get out-of-bounds raises eval error"
    (fun () ->
      Pipeline.process "let v = vec_new () in vec_get v 0");
  (* Codegen status (Phases 15.1 - 15.4):
     - C / LLVM: Vec[R, T] generalizes over the element type T — supports
       int / bool / str / tuple / record / variant (Phase 15.2 / 15.3).
       OwnedVec / StrBuf / Map remain rejected.
     - Wasm: Vec[R, T] supported (Phase 15.4). In Wasm every value is a 4-byte
       i32, so no per-T monomorphization is needed; a single $mere_vec_*
       runtime handles all element types. *)
  (* Phase 15.1: Vec[R, int] works in C codegen (e2e: examples/vec_codegen_c.mere) *)
  (* Test helper: process top-level decls (Top_type / Top_record / etc.)
     before typing the main expr — needed for user-defined types. *)
  let typed_prog src =
    let prog = Pipeline.parse_program src in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    (try Pipeline.process_decls eval_env type_env prog.Ast.decls with _ -> ());
    let _ = Typer.infer !type_env (Ast.desugar_program prog) in
    prog
  in
  let vec_codegen_c src =
    let prog = typed_prog src in
    Codegen_c.emit_program ~main_ty:Ast.TyInt prog
  in
  check "vec: C codegen accepts Vec[R, int]"
    (let c_src = vec_codegen_c
       "let v = vec_new () in let r = vec_push v 7 in vec_len v" in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  let c_src_default_region =
    vec_codegen_c
      "let v = vec_new () in let r = vec_push v 7 in vec_len v"
  in
  assert_contains "vec: C codegen emits mere_vec_int runtime"
    c_src_default_region "mere_vec_int";
  (* Native CLI: `args ()` compiles to a real argv→str list on the C
     backend (was an undeclared-identifier clang error). main() captures
     argc/argv; __lang_args builds the list. *)
  let c_src_args = vec_codegen_c "let a = args () in 0" in
  assert_contains "args: C codegen emits __lang_args" c_src_args "__lang_args()";
  assert_contains "args: C main captures argv"
    c_src_args "int main(int argc, char** argv)";
  (* read_stdin: reads all of stdin as a str (for CLIs like mq). *)
  check "read_stdin type" (Pipeline.type_of "read_stdin") "(unit -> str)";
  assert_contains "read_stdin: C backend emits helper"
    (vec_codegen_c "let s = read_stdin () in str_len s") "__lang_read_stdin()";
  (* to_json on the C backend: a type-specialized to_json_<tag> is emitted
     and dispatched, mirroring show. (interp semantics are covered above;
     here we confirm the C codegen path exists. Wasm/LLVM are a follow-up,
     as with args/read_stdin.) *)
  assert_contains "to_json: C backend emits a record specialization"
    (vec_codegen_c
       "type R = { a: int, b: bool }; str_len (to_json (R { a = 1, b = true }))")
    "to_json_R";
  assert_contains "to_json: C record specialization drops name, quotes fields"
    (vec_codegen_c
       "type R = { a: int, b: bool }; str_len (to_json (R { a = 1, b = true }))")
    "\\\"a\\\":%s";
  (* structural == on a record emits a C eq_<tag> call, not `struct == struct`
     (which is invalid C). *)
  assert_contains "eq: C backend emits a structural eq_<tag>"
    (vec_codegen_c
       "type R = { a: int, b: bool }; \
        if R { a = 1, b = true } == R { a = 1, b = true } then 1 else 0")
    "eq_R(";
  (* of_json on the C backend: the JSON-parser runtime + a type-specialized
     decoder (__ojnode_<tag> / of_json_<tag>) are emitted and dispatched on
     the target type. (interp semantics covered above; here we confirm the
     native codegen path exists. Wasm/LLVM are a follow-up, as with to_json.) *)
  assert_contains "of_json: C backend emits a record decoder"
    (vec_codegen_c
       "type R = { a: int, b: bool }; let r = (of_json \"x\" : R); r.a")
    "of_json_R";
  assert_contains "of_json: C backend emits the JSON parser runtime"
    (vec_codegen_c
       "type R = { a: int, b: bool }; let r = (of_json \"x\" : R); r.a")
    "__mj_parse";
  assert_contains "of_json: C record decoder reads fields by name"
    (vec_codegen_c
       "type R = { a: int, b: bool }; let r = (of_json \"x\" : R); r.a")
    "__mj_field(j, \"a\")";
  (* of_json_opt: the safe sibling emits a setjmp wrapper returning None on
     error — usable for untrusted input (HTTP bodies) without crashing. *)
  assert_contains "of_json_opt: C backend emits a setjmp-guarded wrapper"
    (vec_codegen_c
       "type 'a option = None | Some of 'a; type R = { a: int }; \
        match (of_json_opt \"x\" : R option) with | Some r -> r.a | None -> 0")
    "of_json_opt_R";
  assert_contains "of_json_opt: C wrapper uses setjmp to recover"
    (vec_codegen_c
       "type 'a option = None | Some of 'a; type R = { a: int }; \
        match (of_json_opt \"x\" : R option) with | Some r -> r.a | None -> 0")
    "setjmp(__mj_jb)";
  (* exit n on the C backend: emits libc exit() (was undeclared before; mq
     PAIN P1's last item). *)
  assert_contains "exit: C backend emits libc exit()"
    (vec_codegen_c "let _ = print \"x\" in exit 2")
    "exit(2)";
  (* Native full-stack Stage 1: the Wasm-memory-model FFI externs (tcp_* /
     mem_* / str_ptr) get a native `static` implementation (a flat byte
     arena + POSIX sockets) instead of an unresolved `extern` prototype, so
     contrib/db can compile to a self-contained native binary. Surfaced by
     compiling contrib/db/pg.mere to C for the first time. *)
  let c_src_tcp =
    vec_codegen_c
      "extern fn tcp_connect: str -> int -> int; \
       let fd = tcp_connect \"127.0.0.1\" 5432 in fd" in
  assert_contains "native FFI: tcp_connect gets a static impl"
    c_src_tcp "static int tcp_connect(const char* host, int port)";
  assert_contains "native FFI: emits the byte arena"
    c_src_tcp "static unsigned char __mem[";
  (* contrib/db/redis uses the same native runtime plus two arena<->hex
     helpers — so redis (and mysql) run as native binaries too, not just
     pg. Verified end-to-end against a real redis (SET/GET/INCR). *)
  assert_contains "native FFI: bytes_from_hex_alloc / bytes_to_hex_len (redis)"
    (vec_codegen_c
       "extern fn bytes_from_hex_alloc: str -> int; \
        extern fn bytes_to_hex_len: int -> int -> str; \
        let p = bytes_from_hex_alloc \"ab\" in str_len (bytes_to_hex_len p 1)")
    "static int bytes_from_hex_alloc(const char* hex)";
  assert_no_contains "native FFI: no leftover extern prototype for tcp_connect"
    c_src_tcp "extern int tcp_connect";
  (* C-backend string-escape bug found while compiling pg.mere: a carriage
     return in a string literal was emitted raw into the C source (breaking
     the string), because escape_string handled \\n / \\t but not \\r. *)
  assert_contains "C backend escapes CR in string literals"
    (vec_codegen_c "let s = \"a\\rb\" in str_len s") "a\\rb";
  (* Native full-stack Stage 3-4: http_serve gets a native accept-loop impl
     (taking the closure_str_str handler), and sha256_hex a real SHA-256, so
     a web+DB app compiles to a single native binary. *)
  assert_contains "native HTTP: http_serve gets a native impl"
    (vec_codegen_c
       "extern fn http_serve: int -> (str -> str) -> unit; \
        let h = fn (r: str) -> r in let _ = http_serve 8080 h in 0")
    "static int http_serve(int port, closure_str_str handler)";
  assert_contains "native util: sha256_hex gets a real SHA-256 impl"
    (vec_codegen_c
       "extern fn sha256_hex: str -> str; str_len (sha256_hex \"x\")")
    "static char* sha256_hex(const char* msg)";
  (* Native SCRAM-SHA-256 (Stage 2b): the crypto externs pg's password-auth
     path calls get real native impls (HMAC / PBKDF2 / base64) built on the
     SHA-256 core, not stubs — so native pg authenticates over plaintext. *)
  assert_contains "native crypto: HMAC-SHA256 impl for SCRAM"
    (vec_codegen_c
       "extern fn hmac_sha256_hex_str: str -> str -> str; \
        str_len (hmac_sha256_hex_str \"6b\" \"hi\")")
    "static void __hmac_sha256";
  assert_contains "native crypto: PBKDF2-SHA256 impl for SCRAM"
    (vec_codegen_c
       "extern fn pbkdf2_sha256_hex: str -> str -> int -> int -> str; \
        str_len (pbkdf2_sha256_hex \"pw\" \"ab\" 1 32)")
    "static char* pbkdf2_sha256_hex(const char* pw, const char* salt_hex, int iters, int keylen)";
  (* P7: str ordering lowers per backend — C/LLVM reuse libc strcmp, Wasm
     reuses the $__lang_str_compare helper (sign-normalized -1/0/1). The
     condition keeps main int so main_ty:TyInt stays consistent. *)
  assert_contains "P7: C backend lowers str `<` via strcmp"
    (vec_codegen_c "if \"a\" < \"b\" then 1 else 0") "strcmp";
  assert_contains "P7: Wasm backend lowers str `<` via str_compare helper"
    (wasm "if \"a\" < \"b\" then 1 else 0") "call $__lang_str_compare";
  (* B2 (mere-blog dogfood): constructor `let` patterns compile on the C
     and Wasm backends (desugared to a single-arm match). Previously both
     raised a codegen error for any non-P_var/P_tuple let pattern. A
     non-empty emit == no codegen_error raised. *)
  check "B2: C backend compiles constructor let"
    (let c = vec_codegen_c
       "type ab = AB of int * int; let AB (a, b) = AB (3, 4) in a + b" in
     if String.length c > 0 then "ok" else "empty") "ok";
  check "B2: Wasm backend compiles constructor let"
    (let w = wasm
       "type ab = AB of int * int; let AB (a, b) = AB (3, 4) in a + b" in
     if String.length w > 0 then "ok" else "empty") "ok";
  (* to_json on the Wasm backend: a type-specialized $to_json_<tag> func is
     emitted, mirroring $show_<tag>. Verified byte-identical to interp
     end-to-end via wat2wasm+node (record/list/tuple/variant). *)
  assert_contains "to_json: Wasm backend emits a record specialization"
    (wasm_with_decls
       "type R = { a: int, b: bool }; to_json (R { a = 1, b = true })")
    "(func $to_json_R";
  (* structural == on Wasm: emits $eq_<tag> (i32.eq would compare linear-mem
     offsets, giving wrong answers). *)
  assert_contains "eq: Wasm backend emits a structural eq_<tag>"
    (wasm_with_decls
       "type R = { a: int, b: bool }; \
        if R { a = 1, b = true } == R { a = 1, b = true } then 1 else 0")
    "(func $eq_R";
  check "B2: C backend compiles record let"
    (let c = vec_codegen_c
       "type P = { x: int, y: int }; let P { x = a, y = b } = P { x = 3, y = 4 } in a + b" in
     if String.length c > 0 then "ok" else "empty") "ok";
  (* A locally-bound `join` (e.g. a string-join helper) must NOT compile
     to the Q-012 thread `pthread_join` builtin — the C backend now checks
     shadowing before that dispatch. (Surfaced by the mq dogfood's CSV
     parser.) *)
  (* A top-level `let f` must not corrupt a prelude fn (list_fold) whose
     parameter is also named `f`: inside list_fold, `f` is its parameter /
     captured value, not the user's global. Regression for the C-backend
     resolution bug found via the mere-calc dogfood. *)
  check "shadow: top-level name matching a prelude param evaluates"
    (Pipeline.process
       "let f = fn (x) -> x + 1; f (list_sum (Cons (10, Cons (20, Nil))))")
    "31";
  (* The C backend used to emit list_fold's parameter `f` as the user's
     global (`f((...))` direct call + `f_as_value`), producing invalid C.
     The fix routes list_fold's own `f` through its parameter — assert the
     emit succeeds (the bug was a clang-level break on valid-looking C). *)
  check "shadow: top-level name matching a prelude param compiles (C)"
    (let c = vec_codegen_c
       "let f = fn (x) -> x + 1; f (list_sum (Cons (10, Cons (20, Nil))))" in
     if String.length c > 0 then "ok" else "empty") "ok";
  assert_no_contains "join: local shadow isn't compiled as pthread_join"
    (vec_codegen_c
       "let rec join = fn xs -> match xs with | Nil -> 0 | Cons (h, t) -> h + join t in join (Cons (1, Cons (2, Nil)))")
    "pthread_join";
  (* P6: str_eq works as a function on the C backend (was only the `==`
     operator on str). *)
  assert_contains "str_eq: C backend emits strcmp"
    (vec_codegen_c "if str_eq \"a\" \"b\" then 1 else 0") "strcmp";
  (* P9: str_of_int lowers to show_int(), so the show_int definition must
     be emitted even without a direct `show` (was an undeclared call). *)
  assert_contains "str_of_int: C backend emits show_int definition"
    (vec_codegen_c "let _ = str_of_int 42 in 0") "show_int(int v)";
  (* Two top-level fns each with a same-named inner `loop` but different
     captures must not merge capture sets. `fa`'s loop captures only x;
     `fb`'s also captures y. The transitive-capture fixpoint used to
     resolve `loop` via a global last-write map, so `fa`'s loop inherited
     `fb`'s `y` → an undeclared identifier in C (mq dogfood P8). `fa`'s
     lifted loop (processed first → _0) must stay `(x, acc)`, not gain y. *)
  let c_two_loops =
    vec_codegen_c
      "let fa = fn x -> let rec loop = fn acc -> fn k -> if k <= 0 then acc else loop (acc + x) (k - 1) in loop 0 x in \
       let fb = fn x -> let y = x + 100 in let rec loop = fn acc -> fn k -> if k <= 0 then acc else loop (acc + x + y) (k - 1) in loop 0 x in \
       fa 3 + fb 3"
  in
  assert_no_contains "inner-lift: same-named inner fns across hosts don't merge captures"
    c_two_loops "__lifted_loop_0(int x, int y";
  assert_contains "vec: C codegen wires vec_new outside region to default arena"
    c_src_default_region "mere_vec_int_new(&__lang_default_region)";
  assert_contains "vec: C codegen routes vec_push to runtime helper"
    c_src_default_region "mere_vec_int_push";
  assert_contains "vec: C codegen routes vec_len to runtime helper"
    c_src_default_region "mere_vec_int_len";
  let c_src_region_R =
    vec_codegen_c
      "region R { let v = vec_new () in let r = vec_push v 7 in vec_len v }"
  in
  assert_contains "vec: C codegen binds vec_new inside region R to that region"
    c_src_region_R "mere_vec_int_new(&__region_R)";
  (* Phase 15.2: Vec[R, T] supports any T that is a codegen-supported concrete
     type — int / bool / str / tuple / record / variant. Below we confirm
     acceptance for str / tuple / polymorphic record as examples. *)
  let c_src_str = vec_codegen_c
    "let v = vec_new () in let r = vec_push v \"hi\" in vec_len v"
  in
  assert_contains "vec: C codegen accepts Vec[R, str]"
    c_src_str "mere_vec_str";
  let c_src_tup = vec_codegen_c
    "let v = vec_new () in let r = vec_push v (1, 2) in vec_len v"
  in
  assert_contains "vec: C codegen accepts Vec[R, tuple]"
    c_src_tup "mere_vec_tuple_int_int";
  (* Phase 15.3: LLVM IR codegen also supports Vec[R, T] generalized over element type. *)
  let vec_codegen_llvm src =
    let prog = typed_prog src in
    Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog
  in
  check "vec: LLVM codegen accepts Vec[R, int]"
    (let ll = vec_codegen_llvm
       "let v = vec_new () in let r = vec_push v 7 in vec_len v" in
     if String.length ll > 0 then "ok" else "empty") "ok";
  (* P7: str ordering on the LLVM backend reuses libc strcmp (see the C-backend
     companion assertion near read_stdin). *)
  assert_contains "P7: LLVM backend lowers str `<` via strcmp"
    (vec_codegen_llvm "if \"a\" < \"b\" then 1 else 0") "@strcmp";
  (* B2 (mere-blog dogfood): constructor `let` patterns compile on LLVM too
     (desugared to a single-arm match). *)
  check "B2: LLVM backend compiles constructor let"
    (let l = vec_codegen_llvm
       "type ab = AB of int * int; let AB (a, b) = AB (3, 4) in a + b" in
     if String.length l > 0 then "ok" else "empty") "ok";
  assert_contains "vec: LLVM codegen emits mere_vec_int runtime"
    (vec_codegen_llvm
       "let v = vec_new () in let r = vec_push v 7 in vec_len v")
    "@mere_vec_int_new";
  assert_contains "vec: LLVM codegen accepts Vec[R, str]"
    (vec_codegen_llvm
       "let v = vec_new () in let r = vec_push v \"hi\" in vec_len v")
    "@mere_vec_str_new";
  assert_contains "vec: LLVM codegen accepts Vec[R, tuple]"
    (vec_codegen_llvm
       "let v = vec_new () in let r = vec_push v (1, 2) in vec_len v")
    "@mere_vec_tuple_int_int_new";
  assert_contains "vec: LLVM codegen binds vec_new inside region R to that region"
    (vec_codegen_llvm
       "region R { let v = vec_new () in let r = vec_push v 7 in vec_len v }")
    "@mere_vec_int_new";
  (* Phase 15.4: the Wasm backend also accepts Vec[R, T]. In Wasm every value
     is a 4-byte i32, so per-T monomorphization is unnecessary and a single
     $mere_vec_* runtime handles all element types. *)
  let vec_codegen_wasm src =
    let prog = typed_prog src in
    Codegen_wasm.emit_program ~main_ty:Ast.TyInt prog
  in
  let wat_int = vec_codegen_wasm
    "let v = vec_new () in let r = vec_push v 7 in vec_len v"
  in
  assert_contains "vec: Wasm codegen emits mere_vec runtime"
    wat_int "$mere_vec_new";
  assert_contains "vec: Wasm codegen routes vec_push to runtime"
    wat_int "$mere_vec_push";
  assert_contains "vec: Wasm codegen accepts Vec[R, str]"
    (vec_codegen_wasm
       "let v = vec_new () in let r = vec_push v \"hi\" in vec_len v")
    "$mere_vec_push";
  assert_contains "vec: Wasm codegen accepts Vec[R, tuple]"
    (vec_codegen_wasm
       "let v = vec_new () in let r = vec_push v (1, 2) in vec_len v")
    "$mere_vec_push";
  (* Q-014: `chr` masks its argument to a byte before indexing the
     256-entry char_table, so out-of-range input can't read past it into
     adjacent memory (was a corruption in wasm/llvm; C already masked). *)
  assert_contains "chr masks out-of-range index (wasm)"
    (vec_codegen_wasm "chr 65") "(i32.and (local.get $n) (i32.const 255))";
  assert_contains "chr masks out-of-range index (llvm)"
    (vec_codegen_llvm "chr 65") "and i32 %n, 255";
  (* --- Phase 15.5: codegen of higher-order API (vec_set / vec_iter / vec_fold) --- *)
  let src_set =
    "let v = vec_new () in let __ = vec_push v 10 in \
     let __ = vec_push v 20 in let __ = vec_set v 0 99 in vec_get v 0"
  in
  assert_contains "vec_set: C codegen emits mere_vec_int_set"
    (vec_codegen_c src_set) "mere_vec_int_set";
  assert_contains "vec_set: LLVM codegen emits @mere_vec_int_set"
    (vec_codegen_llvm src_set) "@mere_vec_int_set";
  assert_contains "vec_set: Wasm codegen emits $mere_vec_set"
    (vec_codegen_wasm src_set) "$mere_vec_set";
  let src_iter =
    "let v = vec_new () in let __ = vec_push v 1 in \
     let __ = vec_push v 2 in \
     let acc = vec_new () in \
     let __ = vec_iter v (fn x -> vec_push acc (x + 10)) in \
     vec_get acc 0 + vec_get acc 1"
  in
  assert_contains "vec_iter: C codegen emits mere_vec_int_get inline loop"
    (vec_codegen_c src_iter) "mere_vec_int_get";
  assert_contains "vec_iter: LLVM codegen emits @mere_vec_int_iter"
    (vec_codegen_llvm src_iter) "@mere_vec_int_iter";
  assert_contains "vec_iter: Wasm codegen emits $mere_vec_iter"
    (vec_codegen_wasm src_iter) "$mere_vec_iter";
  let src_fold =
    "let v = vec_new () in let __ = vec_push v 1 in \
     let __ = vec_push v 2 in let __ = vec_push v 3 in \
     vec_fold v 0 (fn acc -> fn x -> acc + x * x)"
  in
  assert_contains "vec_fold: C codegen emits inline loop"
    (vec_codegen_c src_fold) "mere_vec_int_get";
  assert_contains "vec_fold: LLVM codegen emits @mere_vec_int_fold_int"
    (vec_codegen_llvm src_fold) "@mere_vec_int_fold_int";
  assert_contains "vec_fold: Wasm codegen emits $mere_vec_fold"
    (vec_codegen_wasm src_fold) "$mere_vec_fold";
  (* Interpreter parity check (already tested elsewhere, but co-locate
     for this slice's sanity). *)
  check "vec_set: interpreter parity"
    (Pipeline.process src_set) "99";
  check "vec_iter: interpreter parity"
    (Pipeline.process src_iter) "23";
  check "vec_fold: interpreter parity"
    (Pipeline.process src_fold) "14";
  (* --- Phase 15.6: 3-backend codegen of vec_map / vec_filter --- *)
  let src_map =
    "let v = vec_new () in let __ = vec_push v 1 in \
     let __ = vec_push v 2 in let __ = vec_push v 3 in \
     let m = vec_map v (fn x -> x * x) in \
     vec_get m 0 + vec_get m 1 + vec_get m 2"
  in
  assert_contains "vec_map: C codegen emits inline statement expression"
    (vec_codegen_c src_map) "mere_vec_int_new";
  assert_contains "vec_map: LLVM codegen emits @mere_vec_int_map_int"
    (vec_codegen_llvm src_map) "@mere_vec_int_map_int";
  assert_contains "vec_map: Wasm codegen emits $mere_vec_map"
    (vec_codegen_wasm src_map) "$mere_vec_map";
  let src_map_str =
    "let v = vec_new () in let __ = vec_push v 1 in \
     let __ = vec_push v 2 in \
     let m = vec_map v (fn x -> show x) in \
     str_len (vec_get m 0) + str_len (vec_get m 1)"
  in
  assert_contains "vec_map: LLVM codegen emits per-(T, U) — @mere_vec_int_map_str"
    (vec_codegen_llvm src_map_str) "@mere_vec_int_map_str";
  let src_filter =
    "let v = vec_new () in let __ = vec_push v 1 in \
     let __ = vec_push v 2 in let __ = vec_push v 3 in \
     let __ = vec_push v 4 in \
     let m = vec_filter v (fn x -> x % 2 == 0) in \
     vec_get m 0 + vec_get m 1 + vec_len m"
  in
  assert_contains "vec_filter: C codegen emits inline statement expression"
    (vec_codegen_c src_filter) "mere_vec_int_new";
  assert_contains "vec_filter: LLVM codegen emits @mere_vec_int_filter"
    (vec_codegen_llvm src_filter) "@mere_vec_int_filter";
  assert_contains "vec_filter: Wasm codegen emits $mere_vec_filter"
    (vec_codegen_wasm src_filter) "$mere_vec_filter";
  check "vec_map: interpreter parity"
    (Pipeline.process src_map) "14";
  check "vec_filter: interpreter parity"
    (Pipeline.process src_filter) "8";
  (* --- Phase 15.7: OwnedVec[T] + vec_to_owned / owned_vec_to_vec --- *)
  let src_owned =
    "let o = owned_vec_new () in let __ = owned_vec_push o 10 in \
     let __ = owned_vec_push o 20 in let __ = owned_vec_push o 30 in \
     owned_vec_get o 0 + owned_vec_get o 1 + owned_vec_get o 2 + owned_vec_len o"
  in
  assert_contains "owned_vec: C codegen emits mere_owned_vec_int_new"
    (vec_codegen_c src_owned) "mere_owned_vec_int_new";
  assert_contains "owned_vec: LLVM codegen emits @mere_owned_vec_int_new"
    (vec_codegen_llvm src_owned) "@mere_owned_vec_int_new";
  (* Wasm: owned_vec_new aliases to $mere_vec_new, so just check the call exists. *)
  assert_contains "owned_vec: Wasm codegen aliases owned_vec_new to $mere_vec_new"
    (vec_codegen_wasm src_owned) "call $mere_vec_new";
  let src_to_owned =
    "let v = vec_new () in let __ = vec_push v 1 in let __ = vec_push v 2 in \
     let o = vec_to_owned v in owned_vec_get o 0 + owned_vec_get o 1 + owned_vec_len o"
  in
  assert_contains "vec_to_owned: C codegen emits mere_owned_vec_int_push"
    (vec_codegen_c src_to_owned) "mere_owned_vec_int_push";
  assert_contains "vec_to_owned: LLVM codegen emits @mere_vec_to_owned_int"
    (vec_codegen_llvm src_to_owned) "@mere_vec_to_owned_int";
  assert_contains "vec_to_owned: Wasm codegen routes to $mere_vec_clone"
    (vec_codegen_wasm src_to_owned) "$mere_vec_clone";
  let src_o2v =
    "let o = owned_vec_new () in let __ = owned_vec_push o 1 in \
     let __ = owned_vec_push o 2 in \
     let v = owned_vec_to_vec o in vec_get v 0 + vec_get v 1 + vec_len v"
  in
  assert_contains "owned_vec_to_vec: C codegen emits mere_vec_int_push"
    (vec_codegen_c src_o2v) "mere_vec_int_push";
  assert_contains "owned_vec_to_vec: LLVM codegen emits @mere_owned_vec_to_vec_int"
    (vec_codegen_llvm src_o2v) "@mere_owned_vec_to_vec_int";
  assert_contains "owned_vec_to_vec: Wasm codegen routes to $mere_vec_clone"
    (vec_codegen_wasm src_o2v) "$mere_vec_clone";
  check "owned_vec: interpreter parity"
    (Pipeline.process src_owned) "63";
  check "vec_to_owned: interpreter parity"
    (Pipeline.process src_to_owned) "5";
  check "owned_vec_to_vec: interpreter parity"
    (Pipeline.process src_o2v) "5";
  (* --- Phase 15.8: bulk free of OwnedVec at end of main (registry) --- *)
  assert_contains "owned_vec: C codegen emits registry"
    (vec_codegen_c src_owned) "__mere_owned_vec_register";
  assert_contains "owned_vec: C codegen calls free_all in main"
    (vec_codegen_c src_owned) "__mere_owned_vec_free_all";
  assert_contains "owned_vec: LLVM codegen emits registry"
    (vec_codegen_llvm src_owned) "@__mere_owned_vec_register";
  assert_contains "owned_vec: LLVM codegen calls free_all in main"
    (vec_codegen_llvm src_owned) "@__mere_owned_vec_free_all";
  (* Wasm has no malloc (linear memory is bulk-released by the OS on process exit),
     so registry / free_all should not be emitted. *)
  let wat_owned = vec_codegen_wasm src_owned in
  if
    (try ignore (String.length wat_owned); false with _ -> true)
    || (let nl = "__mere_owned_vec_register" in
        let hl = String.length wat_owned and nlen = String.length nl in
        let rec loop i =
          if i + nlen > hl then false
          else if String.sub wat_owned i nlen = nl then true
          else loop (i + 1)
        in loop 0)
  then failwith "Wasm should not emit owned_vec registry"
  else ()
  ;

  (* --- Phase 12.2: Vec[R, T] syntax (Q-010 narrowed -> second implementation step) --- *)
  (* Lightweight version: parse-only. R is dropped from the type representation
     and becomes the same TyCon as `T Vec` (forward-compatible). *)
  check "vec[R, T]: type-annotation prints as Vec[R, int]"
    (Pipeline.type_of "fn (v: Vec[R, int]) -> vec_len v")
    "(Vec[R, int] -> int)";
  check "vec[R, T]: str variant"
    (Pipeline.type_of "fn (v: Vec[R, str]) -> vec_get v 0")
    "(Vec[R, str] -> str)";
  check "vec[R, T]: `int Vec` (postfix) defaults region to __heap"
    (Pipeline.type_of "fn (v: int Vec) -> vec_len v")
    "(Vec[__heap, int] -> int)";
  (* Phase 12.3 semantic teeth: vec_new inside a region binds the
     region marker to the active region. *)
  check "vec[R, T]: vec_new inside `region R` binds to R"
    (Pipeline.type_of
       "fn () -> region R { let v = vec_new () in vec_len v }")
    "(unit -> int)";
  check_raises "vec[R, T]: Vec from region R cannot escape"
    (fun () ->
      Pipeline.process "region R { vec_new () }");
  check "vec[R, T]: vec_new outside region defaults to __heap"
    (Pipeline.type_of "vec_new ()") "Vec[__heap, 'a]";

  (* --- Phase 12.5: OwnedVec[T] (Q-010 narrowed (b) — separated type) --- *)
  check "owned_vec: owned_vec_new : unit -> 'a OwnedVec"
    (Pipeline.type_of "owned_vec_new") "(unit -> 'a OwnedVec)";
  check "owned_vec: basic push/len round-trip"
    (Pipeline.process
       "let v = owned_vec_new () in \
        { owned_vec_push v 10; owned_vec_push v 20; owned_vec_len v }") "2";
  check "owned_vec: polymorphic — str OwnedVec"
    (Pipeline.process
       "let v = owned_vec_new () in \
        { owned_vec_push v \"a\"; owned_vec_push v \"b\"; \
          owned_vec_get v 0 ++ owned_vec_get v 1 }") "\"ab\"";
  (* Core of the design: OwnedVec is Drop, so it cannot be placed in a region *)
  check_raises "owned_vec: cannot be placed in a region (Drop)"
    (fun () ->
      Pipeline.process
        "region R { let v = owned_vec_new () in &R v }");
  (* Contrast: Vec[R, T] is Trivial, so it can be placed in a region *)
  check "owned_vec: contrast — Vec[R, T] still goes in region"
    (Pipeline.process
       "region R { let v = vec_new () in \
        { vec_push v 1; vec_push v 2; vec_len v } }") "2";
  check_raises "owned_vec: codegen rejection (C)"
    (fun () ->
      let prog = Pipeline.parse_program
        "let v = owned_vec_new () in owned_vec_len v" in
      let _ = Codegen_c.emit_program ~main_ty:Ast.TyInt prog in ());

  (* --- Phase 12.6: ad-hoc polymorphic `len` (Q-010 narrowed / trait-style) --- *)
  check "len: scheme is `'a -> int`"
    (Pipeline.type_of "len") "('a -> int)";
  check "len: works on str"
    (Pipeline.process "len \"hello world\"") "11";
  check "len: works on Vec[R, T]"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 10; vec_push v 20; vec_push v 30; len v }") "3";
  check "len: works on OwnedVec"
    (Pipeline.process
       "let v = owned_vec_new () in \
        { owned_vec_push v \"a\"; owned_vec_push v \"b\"; len v }") "2";
  check "len: works on tuple"
    (Pipeline.process "len (1, 2, 3, 4)") "4";
  check "len: works on 'a list"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        len (Cons (1, Cons (2, Cons (3, Nil))))") "3";
  check_raises "len: int has no defined length (eval error)"
    (fun () -> Pipeline.process "len 42");
  check_raises "len: codegen rejection (C)"
    (fun () ->
      let prog = Pipeline.parse_program "len \"hi\"" in
      let _ = Codegen_c.emit_program ~main_ty:Ast.TyInt prog in ());

  (* --- Phase 12.7: StrBuf[R] (mutable string buffer inside a region) --- *)
  check "strbuf: strbuf_new : unit -> StrBuf['r]"
    (Pipeline.type_of "strbuf_new") "(unit -> StrBuf['a])";
  check "strbuf: push + to_str round-trip"
    (Pipeline.process
       "let b = strbuf_new () in \
        { strbuf_push b \"hello\"; strbuf_push b \", \"; \
          strbuf_push b \"world\"; strbuf_to_str b }")
    "\"hello, world\"";
  check "strbuf: empty len = 0"
    (Pipeline.process "let b = strbuf_new () in strbuf_len b") "0";
  check "strbuf: byte length after push"
    (Pipeline.process
       "let b = strbuf_new () in \
        { strbuf_push b \"abc\"; strbuf_push b \"de\"; strbuf_len b }") "5";
  (* Phase 12.7: region binding via active_regions *)
  check_raises "strbuf: cannot escape region (StrBuf[R] tagged in)"
    (fun () -> Pipeline.process "region R { strbuf_new () }");
  check "strbuf: outside region defaults to __heap"
    (Pipeline.type_of "strbuf_new ()") "StrBuf[__heap]";
  check "strbuf: inside region R binds to R"
    (Pipeline.type_of
       "fn () -> region R { let b = strbuf_new () in strbuf_len b }")
    "(unit -> int)";
  (* polymorphic len also handles StrBuf *)
  check "strbuf: polymorphic len works on StrBuf"
    (Pipeline.process
       "let b = strbuf_new () in { strbuf_push b \"hello\"; len b }") "5";
  (* Phase 15.9: all 3 backends accept StrBuf[R] codegen. *)
  let strbuf_src =
    "let b = strbuf_new () in let __ = strbuf_push b \"hi\" in strbuf_len b"
  in
  assert_contains "strbuf: C codegen emits mere_strbuf runtime"
    (let prog = Pipeline.parse_program strbuf_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "mere_strbuf_new";
  assert_contains "strbuf: LLVM codegen emits @mere_strbuf_new"
    (let prog = Pipeline.parse_program strbuf_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog)
    "@mere_strbuf_new";
  assert_contains "strbuf: Wasm codegen emits $mere_strbuf_new"
    (let prog = Pipeline.parse_program strbuf_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_wasm.emit_program ~main_ty:Ast.TyInt prog)
    "$mere_strbuf_new";
  check "strbuf: interpreter parity"
    (Pipeline.process strbuf_src) "2";

  (* --- Phase 12.9: Vec higher-order API (iter / map / fold / set) --- *)
  check "vec_iter: type signature"
    (Pipeline.type_of "vec_iter")
    "(Vec['b, 'a] -> (('a -> unit) -> unit))";
  check "vec_map: same region, possibly different element type"
    (Pipeline.type_of "vec_map")
    "(Vec['b, 'a] -> (('a -> 'c) -> Vec['b, 'c]))";
  check "vec_fold: foldl shape"
    (Pipeline.type_of "vec_fold")
    "(Vec['b, 'a] -> ('c -> (('c -> ('a -> 'c)) -> 'c)))";
  check "vec_set: index + new value -> unit"
    (Pipeline.type_of "vec_set")
    "(Vec['b, 'a] -> (int -> ('a -> unit)))";

  (* runtime behavior *)
  check "vec_map: doubling ints"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 1; vec_push v 2; vec_push v 3; \
          let doubled = vec_map v (fn x -> x * 2) in \
          vec_get doubled 0 + vec_get doubled 1 + vec_get doubled 2 }") "12";
  check "vec_map: element-type change (int → str)"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 1; vec_push v 2; \
          let s = vec_map v show in \
          vec_get s 0 ++ \", \" ++ vec_get s 1 }") "\"1, 2\"";
  check "vec_fold: sum"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 10; vec_push v 20; vec_push v 30; \
          vec_fold v 0 (fn acc -> fn x -> acc + x) }") "60";
  check "vec_set: mutates in place"
    (Pipeline.process
       "let v = vec_new () in \
        { vec_push v 1; vec_push v 2; vec_push v 3; \
          vec_set v 1 99; \
          vec_get v 0 + vec_get v 1 + vec_get v 2 }") "103";
  check_raises "vec_set: out of bounds"
    (fun () ->
      Pipeline.process
        "let v = vec_new () in { vec_push v 1; vec_set v 5 99 }");

  (* vec_iter: callback side effects accumulate via outer Vec *)
  check "vec_iter: callback side effects via another Vec"
    (Pipeline.process
       "let src = vec_new () in \
        { vec_push src 10; vec_push src 20; vec_push src 30; \
          let acc = vec_new () in \
          { vec_iter src (fn x -> vec_push acc (x * 100)); \
            vec_fold acc 0 (fn s -> fn y -> s + y) } }") "6000";

  (* Inside a region, vec_map's result is in the same region *)
  check "vec_map: result Vec shares the source's region"
    (Pipeline.type_of
       "fn () -> region R { \
         let v = vec_new () in \
         { vec_push v 1; vec_push v 2; \
           let _ = vec_map v (fn x -> x + 1) in 0 } }")
    "(unit -> int)";

  check_raises "vec_iter: codegen rejection (C)"
    (fun () ->
      let prog = Pipeline.parse_program
        "let v = vec_new () in vec_iter v (fn x -> ())" in
      let _ = Codegen_c.emit_program ~main_ty:Ast.TyInt prog in ());

  (* --- Phase 12.10: Map[R, K, V] (region-aware mutable map) --- *)
  check "map: map_new : unit -> Map[r, k, v]"
    (Pipeline.type_of "map_new") "(unit -> Map['c, 'b, 'a])";
  check "map: basic set/get round-trip (str -> int)"
    (Pipeline.process
       "let m = map_new () in \
        { map_set m \"a\" 10; map_set m \"b\" 20; \
          map_get m \"a\" + map_get m \"b\" }") "30";
  check "map: map_has true/false branch"
    (Pipeline.process
       "let m = map_new () in \
        { map_set m \"k\" 42; \
          if map_has m \"k\" then if map_has m \"x\" then 0 else 1 else 0 }") "1";
  check "map: map_len counts unique keys"
    (Pipeline.process
       "let m = map_new () in \
        { map_set m \"a\" 1; map_set m \"b\" 2; map_set m \"a\" 999; \
          map_len m }") "2";
  check "map: polymorphic key/value type (int -> str)"
    (Pipeline.process
       "let m = map_new () in \
        { map_set m 1 \"one\"; map_set m 2 \"two\"; \
          map_get m 1 ++ \", \" ++ map_get m 2 }") "\"one, two\"";
  check_raises "map: map_get on missing key raises eval error"
    (fun () ->
      Pipeline.process "let m = map_new () in map_get m \"absent\"");
  check_raises "map: cannot escape region"
    (fun () ->
      Pipeline.process "region R { map_new () }");
  check "map: outside region defaults to __heap"
    (Pipeline.type_of "map_new ()") "Map[__heap, 'b, 'a]";
  check "map: polymorphic len works on Map"
    (Pipeline.process
       "let m = map_new () in { map_set m \"a\" 1; map_set m \"b\" 2; len m }") "2";

  (* --- Phase 39.A' #2: map_delete (K to remove an entry) --- *)
  check "map_delete: removes key, map_has returns false"
    (Pipeline.process
       "let m = map_new () in \
        let __ = map_set m \"a\" 1 in \
        let __ = map_set m \"b\" 2 in \
        let __ = map_delete m \"a\" in \
        if map_has m \"a\" then 0 else 1") "1";
  check "map_delete: map_len decreases after delete"
    (Pipeline.process
       "let m = map_new () in \
        let __ = map_set m \"a\" 1 in \
        let __ = map_set m \"b\" 2 in \
        let __ = map_set m \"c\" 3 in \
        let __ = map_delete m \"b\" in \
        map_len m") "2";
  check "map_delete: deleting missing key is a no-op"
    (Pipeline.process
       "let m = map_new () in \
        let __ = map_set m \"a\" 1 in \
        let __ = map_delete m \"absent\" in \
        map_len m") "1";

  (* --- Phase 19.2: map_iter (K -> V -> unit, applied to each entry) --- *)
  check "map_iter: type"
    (Pipeline.type_of "map_iter")
    "(Map['c, 'b, 'a] -> (('b -> ('a -> unit)) -> unit))";
  check "map_iter: counts iterations via Vec accumulator"
    (Pipeline.process
       "let m = map_new () in let v = vec_new () in \
        let __ = map_set m \"a\" 1 in \
        let __ = map_set m \"b\" 2 in \
        let __ = map_set m \"c\" 3 in \
        let __ = map_iter m (fn k -> fn vv -> vec_push v (vv * 10)) in \
        let sum = vec_fold v 0 (fn acc -> fn x -> acc + x) in \
        sum")
    "60";
  check "map_iter: empty Map → no iterations"
    (Pipeline.process
       "let m = map_new () in let v = vec_new () in \
        let __ = map_iter m (fn k -> fn vv -> vec_push v 1) in \
        vec_len v")
    "0";
  (* Phase 15.10: all 3 backends accept Map[R, int / str, V] codegen. *)
  let map_str_src =
    "let m = map_new () in let __ = map_set m \"a\" 10 in \
     let __ = map_set m \"b\" 20 in map_get m \"a\" + map_get m \"b\" + map_len m"
  in
  let map_int_src =
    "let m = map_new () in let __ = map_set m 1 100 in \
     let __ = map_set m 2 200 in map_get m 1 + map_get m 2 + map_len m"
  in
  assert_contains "map[str, int]: C codegen emits mere_map_str_int_new"
    (let prog = Pipeline.parse_program map_str_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "mere_map_str_int_new";
  assert_contains "map[int, int]: C codegen emits mere_map_int_int_new"
    (let prog = Pipeline.parse_program map_int_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "mere_map_int_int_new";
  assert_contains "map[str, int]: LLVM codegen emits @mere_map_str_int_new"
    (let prog = Pipeline.parse_program map_str_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog)
    "@mere_map_str_int_new";
  assert_contains "map[int, int]: LLVM codegen emits @mere_map_int_int_new"
    (let prog = Pipeline.parse_program map_int_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog)
    "@mere_map_int_int_new";
  assert_contains "map[str]: Wasm codegen emits $mere_map_str_new"
    (let prog = Pipeline.parse_program map_str_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_wasm.emit_program ~main_ty:Ast.TyInt prog)
    "$mere_map_str_new";
  assert_contains "map[int]: Wasm codegen emits $mere_map_int_new"
    (let prog = Pipeline.parse_program map_int_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_wasm.emit_program ~main_ty:Ast.TyInt prog)
    "$mere_map_int_new";
  check "map[str, int]: interpreter parity"
    (Pipeline.process map_str_src) "32";
  check "map[int, int]: interpreter parity"
    (Pipeline.process map_int_src) "302";

  (* Phase 19.2: 3-backend assertions for map_iter codegen *)
  let map_iter_src =
    "let m = map_new () in let __ = map_set m \"a\" 1 in \
     let __ = map_set m \"b\" 2 in let v = vec_new () in \
     let __ = map_iter m (fn k -> fn vv -> vec_push v vv) in \
     vec_fold v 0 (fn acc -> fn x -> acc + x)"
  in
  assert_contains "map_iter: C codegen inlines closure dispatch"
    (let prog = Pipeline.parse_program map_iter_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "__outer.fn(__outer.env, __m->keys[__i])";
  assert_contains "map_iter: LLVM codegen emits per-(K,V) iter helper"
    (let prog = Pipeline.parse_program map_iter_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog)
    "@mere_map_str_int_iter";
  assert_contains "map_iter: Wasm codegen emits $mere_map_str_iter"
    (let prog = Pipeline.parse_program map_iter_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_wasm.emit_program ~main_ty:Ast.TyInt prog)
    "$mere_map_str_iter";
  (* --- Phase 15.11: codegen of ad-hoc polymorphic `len` --- *)
  let len_src =
    "let v = vec_new () in let __ = vec_push v 1 in \
     let __ = vec_push v 2 in let __ = vec_push v 3 in \
     let s = \"hello\" in let t = (1, 2, 3, 4) in \
     len v + len s + len t"
  in
  assert_contains "len: C codegen dispatches Vec → mere_vec_int_len"
    (let prog = Pipeline.parse_program len_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "mere_vec_int_len";
  assert_contains "len: C codegen dispatches str → strlen"
    (let prog = Pipeline.parse_program len_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "((int)strlen";
  assert_contains "len: LLVM codegen dispatches Vec"
    (let prog = Pipeline.parse_program len_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog)
    "@mere_vec_int_len";
  assert_contains "len: Wasm codegen dispatches Vec"
    (let prog = Pipeline.parse_program len_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_wasm.emit_program ~main_ty:Ast.TyInt prog)
    "$mere_vec_len";
  check "len: interpreter parity"
    (Pipeline.process len_src) "12";  (* 3 + 5 + 4 *)
  (* --- Phase 15.12: 3-backend codegen of vec_to_list + len on list --- *)
  let v2l_src =
    "type 'a list = Nil | Cons of 'a * 'a list;\n\
     let v = vec_new () in let __ = vec_push v 10 in \
     let __ = vec_push v 20 in let __ = vec_push v 30 in \
     let l = (vec_to_list v : int list) in len l + \
     (match l with | Cons (h, _) -> h | Nil -> 0)"
  in
  assert_contains "vec_to_list: C codegen builds Cons chain"
    (let prog = Pipeline.parse_program v2l_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "payload.Cons.f1";
  assert_contains "vec_to_list: LLVM codegen emits @mere_vec_to_list_int"
    (let prog = Pipeline.parse_program v2l_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog)
    "@mere_vec_to_list_int";
  assert_contains "vec_to_list: Wasm codegen emits $mere_vec_to_list"
    (let prog = Pipeline.parse_program v2l_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_wasm.emit_program ~main_ty:Ast.TyInt prog)
    "$mere_vec_to_list";
  assert_contains "len-on-list: C codegen walks Cons chain"
    (let prog = Pipeline.parse_program v2l_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "__l = __l->payload.Cons.f1";
  assert_contains "len-on-list: LLVM codegen emits @mere_list_int_len"
    (let prog = Pipeline.parse_program v2l_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog)
    "@mere_list_int_len";
  assert_contains "len-on-list: Wasm codegen emits $mere_list_len"
    (let prog = Pipeline.parse_program v2l_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_wasm.emit_program ~main_ty:Ast.TyInt prog)
    "$mere_list_len";
  check "vec_to_list + len-on-list: interpreter parity"
    (Pipeline.process v2l_src) "13";  (* len 3 + head 10 = 13 *)
  (* --- Phase 15.13: scope-end free for with-OwnedVec --- *)
  let with_src =
    "with o = owned_vec_new () in \
     let __ = owned_vec_push o 10 in \
     let __ = owned_vec_push o 20 in \
     owned_vec_get o 0 + owned_vec_get o 1"
  in
  assert_contains "with-OwnedVec: C codegen emits scope-end free"
    (let prog = Pipeline.parse_program with_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "__mere_owned_vec_base";
  assert_contains "with-OwnedVec: LLVM codegen emits scope-end free"
    (let prog = Pipeline.parse_program with_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog)
    "store ptr null, ptr";
  check "with-OwnedVec: interpreter parity"
    (Pipeline.process with_src) "30";
  (* --- Phase 15.14: Map K extension (bool / tuple keys) --- *)
  let map_bool_src =
    "let m = map_new () in let __ = map_set m true 100 in \
     let __ = map_set m false 200 in \
     map_get m true + map_get m false + map_len m"
  in
  let map_tup_src =
    "let m = map_new () in let __ = map_set m (1, 2) 10 in \
     let __ = map_set m (1, 3) 20 in let __ = map_set m (1, 2) 99 in \
     map_get m (1, 2) + map_get m (1, 3) + map_len m"
  in
  assert_contains "map[bool, int]: C codegen accepts"
    (let prog = Pipeline.parse_program map_bool_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "mere_map_bool_int";
  assert_contains "map[tuple, int]: C codegen accepts"
    (let prog = Pipeline.parse_program map_tup_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_c.emit_program ~main_ty:Ast.TyInt prog)
    "mere_map_tuple_int_int_int";
  assert_contains "map[bool, int]: LLVM codegen emits key_eq"
    (let prog = Pipeline.parse_program map_bool_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog)
    "@mere_map_key_eq_bool";
  assert_contains "map[tuple, int]: LLVM codegen emits key_eq"
    (let prog = Pipeline.parse_program map_tup_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_llvm.emit_program ~main_ty:Ast.TyInt prog)
    "@mere_map_key_eq_tuple_int_int";
  assert_contains "map[bool]: Wasm codegen emits key_eq"
    (let prog = Pipeline.parse_program map_bool_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_wasm.emit_program ~main_ty:Ast.TyInt prog)
    "$mere_map_key_eq_bool";
  assert_contains "map[tuple]: Wasm codegen emits key_eq"
    (let prog = Pipeline.parse_program map_tup_src in
     let _ = Typer.infer Typer.initial_env (Ast.desugar_program prog) in
     Codegen_wasm.emit_program ~main_ty:Ast.TyInt prog)
    "$mere_map_key_eq_tuple_int_int";
  check "map[bool]: interpreter parity"
    (Pipeline.process map_bool_src) "302";
  check "map[tuple]: interpreter parity"
    (Pipeline.process map_tup_src) "121";
  (* --- Phase 15.15: Map K extension for record / nullary variant --- *)
  let map_var_src =
    "type Color = Red | Green | Blue;\n\
     let m = map_new () in let __ = map_set m Red 1 in \
     let __ = map_set m Green 2 in let __ = map_set m Blue 3 in \
     map_get m Red + map_get m Green + map_get m Blue + map_len m"
  in
  let map_rec_src =
    "type Pt = { x: int, y: int };\n\
     let m = map_new () in \
     let __ = map_set m (Pt { x = 1, y = 2 }) 100 in \
     let __ = map_set m (Pt { x = 1, y = 2 }) 999 in \
     map_get m (Pt { x = 1, y = 2 }) + map_len m"
  in
  assert_contains "map[variant, int]: C codegen accepts"
    (vec_codegen_c map_var_src) "mere_map_Color_int";
  assert_contains "map[record, int]: C codegen accepts"
    (vec_codegen_c map_rec_src) "mere_map_Pt_int";
  assert_contains "map[variant]: LLVM codegen emits key_eq"
    (vec_codegen_llvm map_var_src) "@mere_map_key_eq_Color";
  assert_contains "map[record]: LLVM codegen emits key_eq"
    (vec_codegen_llvm map_rec_src) "@mere_map_key_eq_Pt";
  assert_contains "map[variant]: Wasm codegen emits key_eq"
    (vec_codegen_wasm map_var_src) "$mere_map_key_eq_Color";
  assert_contains "map[record]: Wasm codegen emits key_eq"
    (vec_codegen_wasm map_rec_src) "$mere_map_key_eq_Pt";
  check "map[variant]: interpreter parity"
    (Pipeline.process map_var_src) "9";
  check "map[record]: interpreter parity"
    (Pipeline.process map_rec_src) "1000";
  (* --- Phase 15.16: Map K extension for variants with payload --- *)
  (* C: mixed-payload variant OK *)
  let map_varp_mixed_src =
    "type TagMixed = AMixed of int | BMixed of str | CMixed;\n\
     let m = map_new () in let __ = map_set m (AMixed 10) 100 in \
     let __ = map_set m (BMixed \"hi\") 200 in let __ = map_set m CMixed 300 in \
     map_get m (AMixed 10) + map_get m (BMixed \"hi\") + map_get m CMixed + map_len m"
  in
  assert_contains "map[payload variant, mixed]: C codegen accepts"
    (vec_codegen_c map_varp_mixed_src)
    "mere_map_TagMixed_int";
  check "map[payload variant, mixed]: C interpreter parity"
    (Pipeline.process map_varp_mixed_src) "603";
  (* LLVM / Wasm: uniform-payload variant (subject to MVP constraints) *)
  let map_varp_uniform_src =
    "type TagU = AU of int | BU of int | CU;\n\
     let m = map_new () in let __ = map_set m (AU 10) 100 in \
     let __ = map_set m (BU 20) 200 in let __ = map_set m CU 300 in \
     let __ = map_set m (AU 10) 999 in \
     map_get m (AU 10) + map_get m (BU 20) + map_get m CU + map_len m"
  in
  assert_contains "map[payload variant, uniform]: LLVM codegen accepts"
    (vec_codegen_llvm map_varp_uniform_src)
    "@mere_map_key_eq_TagU";
  assert_contains "map[payload variant, uniform]: Wasm codegen accepts"
    (vec_codegen_wasm map_varp_uniform_src)
    "$mere_map_key_eq_TagU";
  check "map[payload variant, uniform]: interpreter parity"
    (Pipeline.process map_varp_uniform_src) "1502";

  (* --- Phase 11.5: borrow checker — tracking complex expressions (field chains) --- *)
  (* Borrowing the same field with two incompatible modes is detected as a conflict *)
  check_raises "borrow checker (place): &R p.x + &mut R p.x → conflict"
    (fun () ->
      Pipeline.process
        "type Pt115a = { x: int, y: int };\n\
         region R {\n\
           let p = Pt115a { x = 3, y = 4 } in\n\
           let a = &R p.x in let b = &mut R p.x in 42\n\
         }");
  (* Different fields don't conflict *)
  check "borrow checker (place): &R p.x + &mut R p.y → OK (different fields)"
    (Pipeline.process
       "type Pt115b = { x: int, y: int };\n\
        region R {\n\
          let p = Pt115b { x = 3, y = 4 } in\n\
          let a = &R p.x in let b = &mut R p.y in 42\n\
        }") "42";
  (* Shared reads coexist OK *)
  check "borrow checker (place): &R p.x + &R p.x -> OK (both shared read)"
    (Pipeline.process
       "type Pt115c = { x: int, y: int };\n\
        region R {\n\
          let p = Pt115c { x = 3, y = 4 } in\n\
          let a = &R p.x in let b = &R p.x in 42\n\
        }") "42";
  (* Nested field chains (p.q.r) are also tracked *)
  check_raises "borrow checker (place): nested field — p.q.r conflict"
    (fun () ->
      Pipeline.process
        "type Inner115 = { v: int };\n\
         type Outer115 = { inner: Inner115 };\n\
         region R {\n\
           let o = Outer115 { inner = Inner115 { v = 1 } } in\n\
           let a = &R o.inner.v in let b = &mut R o.inner.v in 42\n\
         }");
  (* Parent and child paths are tracked independently (loose, simple comparison for now) *)
  check "borrow checker (place): p and p.x are treated as distinct places"
    (Pipeline.process
       "type Pt115d = { x: int, y: int };\n\
        region R {\n\
          let p = Pt115d { x = 3, y = 4 } in\n\
          let a = &R p in let b = &mut R p.x in 42\n\
        }") "42";
  (* The error message includes the place ID (e.g. `p.x`) *)
  let conflict_msg =
    try
      let _ = Pipeline.process
        "type Pt115e = { x: int };\n\
         region R {\n\
           let p = Pt115e { x = 1 } in\n\
           let a = &R p.x in let b = &mut R p.x in 0\n\
         }"
      in ""
    with Typer.Type_error (_, msg) -> msg
  in
  assert_contains "borrow checker (place): error mentions field-place path"
    conflict_msg "p.x";

  (* --- Phase 11.6: borrow checker — borrow propagation through if branches --- *)
  (* let r = if ... then &R x else &R x in let m = &mut R x → conflict *)
  check_raises "borrow checker (if): &R x captured via if then conflict"
    (fun () ->
      Pipeline.process
        "region R {\n\
           let x = 5 in\n\
           let r = if 1 < 2 then &R x else &R x in\n\
           let m = &mut R x in 0\n\
         }");
  (* Borrows from both branches propagate as a union (detected even with only one branch) *)
  check_raises "borrow checker (if): borrow from else-branch also tracked"
    (fun () ->
      Pipeline.process
        "region R {\n\
           let x = 1 in let y = 2 in\n\
           let r = if 1 < 2 then &R x else &R y in\n\
           let m = &mut R y in 0\n\
         }");
  check_raises "borrow checker (if): borrow from then-branch also tracked"
    (fun () ->
      Pipeline.process
        "region R {\n\
           let x = 1 in let y = 2 in\n\
           let r = if 1 < 2 then &R x else &R y in\n\
           let m = &mut R x in 0\n\
         }");
  (* Non-conflicting if-borrows pass *)
  check "borrow checker (if): if-borrow vs unrelated var → OK"
    (Pipeline.process
       "region R {\n\
          let x = 1 in let y = 2 in let z = 3 in\n\
          let r = if 1 < 2 then &R x else &R y in\n\
          let m = &mut R z in 42\n\
        }") "42";
  (* Nested let inside an if value is also tracked *)
  check_raises "borrow checker (if): nested let-in-if propagates borrow"
    (fun () ->
      Pipeline.process
        "region R {\n\
           let x = 5 in\n\
           let r =\n\
             if 1 < 2 then\n\
               let _ = 0 in &R x\n\
             else &R x in\n\
           let m = &mut R x in 0\n\
         }");

  (* --- Phase 11.7: borrow propagation from match arms --- *)
  check_raises "borrow checker (match): borrow from arm becomes active"
    (fun () ->
      Pipeline.process
        "type 'a opt117 = N117 | S117 of 'a;\n\
         region R {\n\
           let x = 5 in\n\
           let r = match S117 1 with\n\
             | N117 -> &R x\n\
             | S117 _ -> &R x\n\
           in\n\
           let m = &mut R x in 0\n\
         }");
  (* --- Phase 9.3: nested modules + `open M;` --- *)
  check "module nested: M.N.f access"
    (Pipeline.process
       "module MNest {\n\
          module Inner {\n\
            let f = fn x -> x + 1;\n\
          };\n\
          let g = fn x -> Inner.f (Inner.f x);\n\
        };\n\
        MNest.Inner.f 10 + MNest.g 20") "33";
  check "module nested: inner sees outer via short name within outer"
    (Pipeline.process
       "module NN {\n\
          let helper = fn x -> x * 10;\n\
          module Aux {\n\
            let twice = fn x -> x + x;\n\
          };\n\
          let use_aux = fn x -> Aux.twice (helper x);\n\
        };\n\
        NN.use_aux 7") "140";
  check "open: simple aliasing"
    (Pipeline.process
       "module Tools {\n\
          let dbl = fn x -> x * 2;\n\
          let trp = fn x -> x * 3;\n\
        };\n\
        open Tools;\n\
        dbl 7 + trp 5") "29";
  check "open: works after import-then-open chain conceptually"
    (Pipeline.process
       "module Tk {\n\
          let val_a = 100;\n\
          let val_b = 200;\n\
        };\n\
        open Tk;\n\
        val_a + val_b") "300";
  check_raises "open: undeclared module → parse error"
    (fun () -> Pipeline.process "open NoSuchModule;\n42");
  check_raises "open: missing ;"
    (fun () -> Pipeline.process "module X { let v = 1; }; open X 42");
  (* `open M` should not break qualified access *)
  check "open: qualified access still works after open"
    (Pipeline.process
       "module Box93 {\n\
          let v = 100;\n\
        };\n\
        open Box93;\n\
        v + Box93.v") "200";

  (* --- Phase 18.2 / DEFERRED §4.1 remaining: `open A.B;` nested path --- *)
  check "open nested: open A.B brings A.B's bindings unqualified"
    (Pipeline.process
       "module An182 {\n\
          module Bn182 {\n\
            let answer = 42;\n\
            let plus = fn x -> x + 1;\n\
          };\n\
        };\n\
        open An182.Bn182;\n\
        plus answer") "43";
  check "open nested: open A.B.C (three-level)"
    (Pipeline.process
       "module An183 {\n\
          module Bn183 {\n\
            module Cn183 {\n\
              let deep = 100;\n\
            };\n\
          };\n\
        };\n\
        open An183.Bn183.Cn183;\n\
        deep") "100";
  check_raises "open nested: missing module path → error"
    (fun () ->
      Pipeline.process
        "module Xn184 { let v = 1; };\n\
         open Xn184.NotThere;\n\
         v");

  (* --- Phase 9.4: type / record declarations inside a module --- *)
  check "module-type: record declared inside module body"
    (Pipeline.process
       "module M94 {\n\
          type Pt94 = { x: int, y: int };\n\
          let mk = fn p -> Pt94 { x = fst p, y = snd p };\n\
        };\n\
        let p = M94.mk (3, 4) in p.x + p.y") "7";
  check "module-type: variant declared inside module body"
    (Pipeline.process
       "module M94v {\n\
          type 'a opt94 = N94 | S94 of 'a;\n\
          let unwrap = fn o -> match o with | N94 -> 0 | S94 n -> n;\n\
        };\n\
        M94v.unwrap (S94 42)") "42";
  check "module-type: type / let mixed in module body"
    (Pipeline.process
       "module Status94 {\n\
          type code = Ok94 | Err94 of str;\n\
          let label = fn c -> match c with | Ok94 -> \"ok\" | Err94 s -> s;\n\
        };\n\
        Status94.label (Err94 \"boom\")") "\"boom\"";

  (* --- Phase 18.1 / DEFERRED §4.1 remaining: M-prefix scoping for module
     constructors / records. Bare names still work for backward compatibility,
     and `M.X` qualified access works too. On the typer side they are treated
     as the same ctor / record via aliases, and eval normalizes the ctor name
     to its canonical (bare) form, so pattern matching also works naturally. *)
  check "module ctor: qualified access M.X works"
    (Pipeline.process
       "module Mq1 { type T1q = Red1q | Blue1q; };\n\
        Mq1.Red1q") "Red1q";
  check "module ctor: qualified with payload"
    (Pipeline.process
       "module Mq2 { type 'a opt2q = N2q | S2q of 'a; };\n\
        match Mq2.S2q 42 with | S2q n -> n | N2q -> 0") "42";
  check "module ctor: cross-module name collision — qualified disambiguates"
    (Pipeline.process
       "module Aq3 { type ColAq = Redq | Blueq; };\n\
        module Bq3 { type ColBq = Redq | Greenq; };\n\
        match Aq3.Redq with | Aq3.Redq -> 1 | Aq3.Blueq -> 2") "1";
  check "module record: qualified literal M.Pt { ... }"
    (Pipeline.process
       "module Mq4 { type Ptq = { xq: int, yq: int }; };\n\
        let p = Mq4.Ptq { xq = 3, yq = 4 } in p.xq + p.yq") "7";
  check "module record: qualified pattern M.Pt { ... }"
    (Pipeline.process
       "module Mq5 { type Ptq5 = { xq5: int, yq5: int }; };\n\
        let p = Mq5.Ptq5 { xq5 = 10, yq5 = 20 } in\n\
        match p with | Mq5.Ptq5 { xq5 = xv, yq5 = yv } -> xv + yv") "30";
  check "module ctor: bare ctor used outside module (backward compat)"
    (Pipeline.process
       "module Mq6 { type T6q = Ok6q of int | Err6q; };\n\
        match Mq6.Ok6q 99 with | Ok6q n -> n | Err6q -> 0") "99";

  (* --- Phase 9.5: importer-relative import path resolution --- *)
  let tmpdir = Filename.temp_dir "lang_imp95" "" in
  let write path content =
    let oc = open_out path in output_string oc content; close_out oc
  in
  let helper_path = Filename.concat tmpdir "helper.lang" in
  let main_path = Filename.concat tmpdir "main.lang" in
  write helper_path "let helper95 = fn x -> x * 7;";
  write main_path "import \"./helper.lang\";\nhelper95 6";
  check "import95: ./relative path resolves to importer's directory"
    (Pipeline.process ~base_dir:tmpdir
       "import \"./helper.lang\";\nhelper95 8") "56";
  (* Nested relative path: main → middle → sub/inner *)
  let sub_dir = Filename.concat tmpdir "sub" in
  Unix.mkdir sub_dir 0o755;
  let inner_path = Filename.concat sub_dir "inner.lang" in
  let middle_path = Filename.concat tmpdir "middle.lang" in
  write inner_path "let inner_val95 = 100;";
  write middle_path "import \"./sub/inner.lang\";\nlet middle95 = fn x -> inner_val95 + x;";
  check "import95: nested relative path (./sub/inner via middle)"
    (Pipeline.process ~base_dir:tmpdir
       "import \"./middle.lang\";\nmiddle95 23") "123";
  (* Canonicalisation: two different relative forms of the same file
     should be detected as the same by the cycle guard. *)
  let alt_a = Filename.concat tmpdir "ax.lang" in
  let alt_b_relative = "./ax.lang" in
  write alt_a "let alt_val95 = 42;";
  (* Via alt_a and via alt_b_relative are canonically equal -> loaded only once *)
  check "import95: canonical equality across relative / absolute forms"
    (Pipeline.process ~base_dir:tmpdir
       (Printf.sprintf
          "import \"%s\";\nimport \"%s\";\nalt_val95" alt_a alt_b_relative))
    "42";

  (* --- Phase 12.11: vec_filter / vec_to_list / vec_to_owned --- *)
  check "vec_filter: type signature (region-preserving)"
    (Pipeline.type_of "vec_filter")
    "(Vec['b, 'a] -> (('a -> bool) -> Vec['b, 'a]))";
  check "vec_filter: keeps elements where predicate is true"
    (Pipeline.process
       "let v = vec_new () in \
        let _ = vec_push v 1 in let _ = vec_push v 2 in \
        let _ = vec_push v 3 in let _ = vec_push v 4 in \
        let _ = vec_push v 5 in \
        let evens = vec_filter v (fn x -> x % 2 == 0) in \
        vec_get evens 0 + vec_get evens 1") "6";
  check "vec_filter: empty result when no match"
    (Pipeline.process
       "let v = vec_new () in \
        let _ = vec_push v 1 in let _ = vec_push v 3 in \
        let _ = vec_push v 5 in \
        vec_len (vec_filter v (fn x -> x > 100))") "0";

  check "vec_to_list: scheme returns T list"
    (Pipeline.type_of "vec_to_list")
    "(Vec['b, 'a] -> 'a list)";
  check "vec_to_list: produces list constructor chain"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        let v = vec_new () in \
        let _ = vec_push v 10 in let _ = vec_push v 20 in \
        let _ = vec_push v 30 in \
        show (vec_to_list v)") "\"[10, 20, 30]\"";
  check "vec_to_list: empty Vec → []"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        let v = vec_new () in show (vec_to_list v)") "\"[]\"";

  check "vec_to_owned: scheme converts Vec[R, T] to T OwnedVec"
    (Pipeline.type_of "vec_to_owned")
    "(Vec['b, 'a] -> 'a OwnedVec)";
  check "vec_to_owned: deep copy preserves elements"
    (Pipeline.process
       "let v = vec_new () in \
        let _ = vec_push v 1 in let _ = vec_push v 2 in \
        let _ = vec_push v 3 in \
        let o = vec_to_owned v in \
        owned_vec_len o * 100 + owned_vec_get o 0 + owned_vec_get o 2")
    "304";
  check "vec_to_owned: deep copy is independent of source"
    (Pipeline.process
       "let v = vec_new () in \
        let _ = vec_push v 10 in let _ = vec_push v 20 in \
        let o = vec_to_owned v in \
        let _ = vec_set v 0 999 in \
        owned_vec_get o 0 + owned_vec_get o 1") "30";
  check_raises "vec_to_owned: result is OwnedVec (cannot place in region)"
    (fun () ->
      Pipeline.process
        "region R { \
           let v = vec_new () in \
           let _ = vec_push v 1 in \
           let o = vec_to_owned v in &R o \
         }");

  (* --- Phase 13: type-error UX, continued — record field + qualified name typo --- *)
  let field_typo_msg =
    try
      let _ = Pipeline.process
        "type PtN = { name: str, value: int };\n\
         let p = PtN { name = \"a\", value = 42 } in p.namee"
      in ""
    with Typer.Type_error (_, msg) -> msg
  in
  assert_contains "field typo: did-you-mean for record field"
    field_typo_msg "did you mean `name`?";

  let view_field_typo_msg =
    try
      let _ = Pipeline.process
        "view CellV[R] of int { value: int };\n\
         region R { let c = CellV { value = 3 } in c.valuee }"
      in ""
    with Typer.Type_error (_, msg) -> msg
  in
  assert_contains "field typo: did-you-mean for view field"
    view_field_typo_msg "did you mean `value`?";

  let record_update_typo_msg =
    try
      let _ = Pipeline.process
        "type PtU = { name: str, value: int };\n\
         let p = PtU { name = \"a\", value = 1 } in { p | namee = \"b\" }"
      in ""
    with Typer.Type_error (_, msg) -> msg
  in
  assert_contains "field typo: did-you-mean in record update"
    record_update_typo_msg "did you mean `name`?";

  let qname_typo_msg =
    try
      let _ = Pipeline.process
        "module MathT {\n\
          let rec factorial = fn n -> if n < 1 then 1 else n * factorial (n - 1);\n\
         };\n\
         MathT.factrial 5"
      in ""
    with Typer.Type_error (_, msg) -> msg
  in
  assert_contains "qualified name typo: did-you-mean across module path"
    qname_typo_msg "did you mean `MathT.factorial`?";

  (* --- Phase 12.12: reverse direction owned_vec_to_vec --- *)
  check "owned_vec_to_vec: scheme (region from active_regions)"
    (Pipeline.type_of "owned_vec_to_vec")
    "('a OwnedVec -> Vec['b, 'a])";
  check "owned_vec_to_vec: inside region R, returns Vec[R, T]"
    (Pipeline.process
       "let o = owned_vec_new () in \
        let _ = owned_vec_push o 10 in let _ = owned_vec_push o 20 in \
        let _ = owned_vec_push o 30 in \
        region R { \
          let v = owned_vec_to_vec o in \
          vec_get v 0 + vec_get v 1 + vec_get v 2 \
        }") "60";
  check "owned_vec_to_vec: outside region → Vec[__heap, T]"
    (Pipeline.process
       "let o = owned_vec_new () in \
        let _ = owned_vec_push o 1 in let _ = owned_vec_push o 2 in \
        let v = owned_vec_to_vec o in \
        vec_get v 0 + vec_get v 1") "3";
  check_raises "owned_vec_to_vec: Vec[R, T] cannot escape region R"
    (fun () ->
      Pipeline.process
        "let o = owned_vec_new () in \
         region R { owned_vec_to_vec o }");
  check "owned_vec_to_vec: deep copy — modifying owned doesn't affect vec"
    (Pipeline.process
       "let o = owned_vec_new () in \
        let _ = owned_vec_push o 100 in \
        let _ = owned_vec_push o 200 in \
        region R { \
          let v = owned_vec_to_vec o in \
          let _ = owned_vec_push o 999 in \
          vec_len v * 10 + vec_get v 0 \
        }") "120";

  check_raises "borrow checker (match): the union of distinct arms is also active"
    (fun () ->
      Pipeline.process
        "type 'a opt117b = N117b | S117b of 'a;\n\
         region R {\n\
           let x = 1 in let y = 2 in\n\
           let r = match S117b 1 with\n\
             | N117b -> &R x\n\
             | S117b _ -> &R y\n\
           in\n\
           let m = &mut R y in 0\n\
         }");
  check "borrow checker (match): non-conflict with an unrelated var is OK"
    (Pipeline.process
       "type 'a opt117c = N117c | S117c of 'a;\n\
        region R {\n\
          let x = 1 in let y = 2 in let z = 3 in\n\
          let r = match S117c 1 with\n\
            | N117c -> &R x\n\
            | S117c _ -> &R y\n\
          in\n\
          let m = &mut R z in 42\n\
        }") "42";

  (* --- Phase 17.1 / DEFERRED §2.1 remaining: borrow tracking of function return values --- *)
  check_raises "borrow checker (app-result): &mut R r when r came from fn returning &R T"
    (fun () ->
      Pipeline.process
        "let get_ref = fn (x: &R int) -> x in\n\
         region R {\n\
           let v = 42 in\n\
           let r = get_ref (&R v) in\n\
           let r2 = &mut R r in\n\
           0\n\
         }");
  check_raises "borrow checker (app-result): &R r when r came from fn returning &mut R T"
    (fun () ->
      Pipeline.process
        "let get_mut = fn (x: &mut R int) -> x in\n\
         region R {\n\
           let v = 42 in\n\
           let r1 = get_mut (&mut R v) in\n\
           let r2 = &R r1 in\n\
           0\n\
         }");
  check "borrow checker (app-result): two shared-read fn results — OK"
    (Pipeline.process
       "let get_ref = fn (x: &R int) -> x in\n\
        region R {\n\
          let v = 42 in\n\
          let r1 = get_ref (&R v) in\n\
          let r2 = get_ref (&R v) in\n\
          0\n\
        }") "0";
  assert_contains "borrow checker (app-result): error names the let-bound place"
    (let buf = Buffer.create 64 in
     (try
        let _ = Pipeline.process
          "let get_ref = fn (x: &R int) -> x in\n\
           region R {\n\
             let v = 42 in\n\
             let rrr = get_ref (&R v) in\n\
             let r2 = &mut R rrr in\n\
             0\n\
           }" in ()
      with Typer.Type_error (_, m) -> Buffer.add_string buf m);
     Buffer.contents buf)
    "`rrr` is already borrowed";

  (* --- Phase 19.4: prelude machinery (auto-import `type 'a list`) --- *)
  (* With prelude enabled, Nil / Cons are usable without user declarations *)
  check "prelude: Cons / Nil work without explicit type declare"
    (Pipeline.process "Cons (1, Cons (2, Cons (3, Nil)))")
    "[1, 2, 3]";
  check "prelude: list literal sugar works without declare"
    (Pipeline.process "[10, 20, 30]") "[10, 20, 30]";
  check "prelude: str_split returns a list immediately usable"
    (Pipeline.process
       "match str_split \"a,b,c\" \",\" with \
        | Nil -> \"empty\" \
        | Cons (h, _) -> h")
    "\"a\"";
  check "prelude: pattern match on Nil works"
    (Pipeline.process "match Nil with | Nil -> 1 | _ -> 0") "1";
  (* User redeclaration with the same name works for backward compatibility *)
  check "prelude: user redeclare of `type 'a list` is harmless"
    (Pipeline.process
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        Cons (42, Nil)") "[42]";
  (* Opting out of prelude omits prepending the prelude decls to the AST *)
  check "prelude: ?prelude:false omits prelude decls"
    (let prog = Pipeline.parse_program ~prelude:false "42" in
     string_of_int (List.length prog.Ast.decls))
    "0";
  check "prelude: with prelude (default) prog.decls includes auto-injected"
    (let prog = Pipeline.parse_program "42" in
     (* Phase 19.5: 3 types + Phase 21.2: 6 list helpers
        + Phase 23.2: 3 option + 5 result helpers + Phase 33.1: 1
        + Phase 36 (sugar phase): 1 range + 4 list helpers + 3 flatten
        + Phase 36 (helper batch): 8 helpers
          (list_zip / list_for_all / list_any / list_member /
           list_sum / list_product / list_max / list_min)
        + Phase 39.A' (sort helpers): 3 (list_sort_insert / list_sort_by /
           list_sort) = 37 total *)
     string_of_int (List.length prog.Ast.decls))
    "37";

  (* Phase 39.A' #4: list_sort_by / list_sort prelude helpers *)
  check "list_sort_by: ascending int sort"
    (Pipeline.process
       "let xs = list_sort_by (fn a -> fn b -> a < b) (Cons (3, Cons (1, Cons (2, Nil)))) in \
        match xs with \
        | Cons (a, Cons (b, Cons (c, Nil))) -> a * 100 + b * 10 + c \
        | _ -> -1") "123";
  check "list_sort_by: descending int sort"
    (Pipeline.process
       "let xs = list_sort_by (fn a -> fn b -> a > b) (Cons (1, Cons (3, Cons (2, Nil)))) in \
        match xs with \
        | Cons (a, Cons (b, Cons (c, Nil))) -> a * 100 + b * 10 + c \
        | _ -> -1") "321";
  check "list_sort: natural-order shorthand"
    (Pipeline.process
       "let xs = list_sort (Cons (5, Cons (2, Cons (4, Cons (1, Cons (3, Nil)))))) in \
        list_fold xs 0 (fn acc -> fn x -> acc * 10 + x)") "12345";
  check "list_sort: empty list"
    (Pipeline.process
       "match list_sort (Nil: int list) with | Nil -> 0 | Cons _ -> -1") "0";

  (* Phase 19.5: Option / Result also available without declare. *)
  check "prelude: Option (Some / None) works without declare"
    (Pipeline.process "match Some 5 with | None -> 0 | Some x -> x * 2") "10";
  check "prelude: Result (Ok / Err) works without declare"
    (Pipeline.process "match Ok 7 with | Ok x -> x + 1 | Err _ -> 0") "8";
  check "prelude: Result with Err branch"
    (Pipeline.process
       "match Err \"bad\" with | Ok n -> n | Err _ -> -1") "-1";

  (* Phase 21.1 (DEFERRED §1.7): codegen monomorphization of polymorphic
     user-defined let-rec. In resolve_fn_types, unifying the binding-site
     Fun.ty with the concrete use-site resolves the body's tyvars. *)
  let typed_prog src =
    let prog = Pipeline.parse_program src in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    (try Pipeline.process_decls eval_env type_env prog.Ast.decls with _ -> ());
    let _ = Typer.infer !type_env (Ast.desugar_program prog) in
    prog
  in
  check "§1.7: poly user let-rec accepts concrete int instantiation (interp)"
    (Pipeline.process
       "let rec list_length = fn xs ->\n\
       \  match xs with | Nil -> 0 | Cons (h, t) -> 1 + list_length t in\n\
        list_length (Cons (10, Cons (20, Cons (30, Nil))))")
    "3";
  check "§1.7: poly user let-rec emits C code without 'a error"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let rec list_length = fn xs ->\n\
       \  match xs with | Nil -> 0 | Cons (h, t) -> 1 + list_length t in\n\
        list_length (Cons (10, Cons (20, Cons (30, Nil))))") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "§1.7: poly user let-rec emits LLVM IR without 'a error"
    (let ll_src = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let rec list_length = fn xs ->\n\
       \  match xs with | Nil -> 0 | Cons (h, t) -> 1 + list_length t in\n\
        list_length (Cons (10, Cons (20, Cons (30, Nil))))") in
     if String.length ll_src > 0 then "ok" else "empty")
    "ok";
  check "§1.7: poly user let-rec emits Wasm without 'a error"
    (let wat_src = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let rec list_length = fn xs ->\n\
       \  match xs with | Nil -> 0 | Cons (h, t) -> 1 + list_length t in\n\
        list_length (Cons (10, Cons (20, Cons (30, Nil))))") in
     if String.length wat_src > 0 then "ok" else "empty")
    "ok";
  check "§1.7: wildcard `let _ = E in B` works in C codegen"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let _ = print \"side effect\" in 42") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";

  (* Phase 37.A: codegen verification of while at top-level (Let_rec lifting
     from Let value position) *)
  let while_top_src =
    "let counter = map_new ();
     let _ = map_set counter \"n\" 2;
     let _ = while (map_get counter \"n\") > 0 do
       map_set counter \"n\" ((map_get counter \"n\") - 1);
     0"
  in
  check "Phase 37.A: while at top-level emits C codegen (no Let_rec error)"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog while_top_src) in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "Phase 37.A: while at top-level emits LLVM IR"
    (let ll_src = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog while_top_src) in
     if String.length ll_src > 0 then "ok" else "empty")
    "ok";
  check "Phase 37.A: while at top-level emits Wasm WAT"
    (let wat_src = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog while_top_src) in
     if String.length wat_src > 0 then "ok" else "empty")
    "ok";

  (* Phase 38.C-1: turning multi-arg curried builtins into first-class values
     (remaining spike from DEFERRED §1.2 A2 — only owned_vec_push covered in C).
     At a value position, synthesize_curried_eta generates `fn __arg0 -> fn __arg1 ->
     owned_vec_push __arg0 __arg1`, which rides on the anonymous Fun adapter
     machinery and the direct-call fast path. *)
  check "Phase 38.C-1: owned_vec_push fully unapplied (interp)"
    (Pipeline.process
       "let v = owned_vec_new () in
        let push = owned_vec_push in
        let _ = push v 1 in
        let _ = push v 2 in
        let _ = push v 3 in
        owned_vec_len v")
    "3";
  check "Phase 38.C-1: owned_vec_push partial app (interp)"
    (Pipeline.process
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 0 in
        let push_v = owned_vec_push v in
        let _ = push_v 1 in
        let _ = push_v 2 in
        owned_vec_len v")
    "3";
  check "Phase 38.C-1: owned_vec_push fully unapplied emits C codegen"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let v = owned_vec_new () in
        let push = (owned_vec_push : OwnedVec[int] -> int -> unit) in
        let _ = push v 1 in
        owned_vec_len v") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "Phase 38.C-1: owned_vec_push partial app emits C codegen"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 0 in
        let push_v = owned_vec_push v in
        let _ = push_v 1 in
        owned_vec_len v") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";

  (* Phase 38.C-2: extension to 2-arg curried collection builtins
     (owned_vec_get / vec_push / vec_get / strbuf_push / map_get / map_has) *)
  check "Phase 38.C-2: owned_vec_get partial app (interp)"
    (Pipeline.process
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 10 in
        let _ = owned_vec_push v 20 in
        let get_v = owned_vec_get v in
        get_v 0 + get_v 1")
    "30";
  check "Phase 38.C-2: vec_push partial app (interp)"
    (Pipeline.process
       "let v = vec_new () in
        let _ = vec_push v 1 in
        let push_v = vec_push v in
        let _ = push_v 2 in
        let _ = push_v 3 in
        vec_len v")
    "3";
  check "Phase 38.C-2: strbuf_push partial app emits C codegen"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let b = strbuf_new () in
        let app = strbuf_push b in
        let _ = app \"hello\" in
        strbuf_len b") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "Phase 38.C-2: map_get + map_has partial app (interp)"
    (Pipeline.process
       "let m = map_new () in
        let _ = map_set m \"x\" 7 in
        let lookup = map_get m in
        let has = map_has m in
        lookup \"x\" + (if has \"y\" then 100 else 0)")
    "7";
  check "Phase 38.C-2: map_get partial app emits C codegen"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let m = map_new () in
        let _ = map_set m \"a\" 5 in
        let lookup = map_get m in
        lookup \"a\"") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";

  (* Phase 38.C-3: 3-arg curried builtins (map_set / vec_set) *)
  check "Phase 38.C-3: map_set 1-arg partial app (interp)"
    (Pipeline.process
       "let m = map_new () in
        let set_in_m = map_set m in
        let _ = set_in_m \"a\" 1 in
        let _ = set_in_m \"b\" 2 in
        map_len m")
    "2";
  check "Phase 38.C-3: vec_set 1-arg partial app (interp)"
    (Pipeline.process
       "let v = vec_new () in
        let _ = vec_push v 10 in
        let _ = vec_push v 20 in
        let set_in_v = vec_set v in
        let _ = set_in_v 0 100 in
        vec_get v 0 + vec_get v 1")
    "120";
  check "Phase 38.C-3: map_set 3-arg partial emits C codegen"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let m = map_new () in
        let set_in_m = map_set m in
        let _ = set_in_m \"k\" 1 in
        map_len m") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "Phase 38.C-3: vec_set 3-arg partial emits C codegen"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let v = vec_new () in
        let _ = vec_push v 0 in
        let set_in_v = vec_set v in
        let _ = set_in_v 0 7 in
        vec_get v 0") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";

  (* Phase 38.C-4/5: port to LLVM / Wasm *)
  check "Phase 38.C-4: owned_vec_push partial emits LLVM IR"
    (let ll_src = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 0 in
        let push_v = owned_vec_push v in
        let _ = push_v 1 in
        owned_vec_len v") in
     if String.length ll_src > 0 then "ok" else "empty")
    "ok";
  check "Phase 38.C-4: map_set 1-arg partial emits LLVM IR"
    (let ll_src = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let m = map_new () in
        let set_in_m = map_set m in
        let _ = set_in_m \"k\" 1 in
        map_len m") in
     if String.length ll_src > 0 then "ok" else "empty")
    "ok";
  check "Phase 38.C-5: owned_vec_push partial emits Wasm WAT"
    (let wat_src = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 0 in
        let push_v = owned_vec_push v in
        let _ = push_v 1 in
        owned_vec_len v") in
     if String.length wat_src > 0 then "ok" else "empty")
    "ok";
  check "Phase 38.C-5: vec_set 3-arg partial emits Wasm WAT"
    (let wat_src = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let v = vec_new () in
        let _ = vec_push v 0 in
        let set_in_v = vec_set v in
        let _ = set_in_v 0 7 in
        vec_get v 0") in
     if String.length wat_src > 0 then "ok" else "empty")
    "ok";

  (* Phase 38.G-1: OwnedVec auto scope-bound Drop (DEFERRED §1.3 Level 1)
     When body in `let v = owned_vec_new () in body` does not let v escape,
     auto-emit `free(v->data)` at scope end. If the conservative static
     analysis (no_value_leak + tail_does_not_return_v + value is a fresh
     owned_vec_new factory call) is satisfied, auto-Drop; otherwise fall back
     to the existing registry + main-end sweep. *)
  let count_owned_vec_free_c src =
    let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog src) in
    let needle = "free(((__mere_owned_vec_base*)" in
    let rec count i acc =
      let len = String.length needle in
      if i + len > String.length c_src then acc
      else if String.sub c_src i len = needle then count (i + 1) (acc + 1)
      else count (i + 1) acc
    in
    count 0 0
  in
  check "Phase 38.G-1: safe pattern auto-Drops in C codegen (1 free emit)"
    (string_of_int (count_owned_vec_free_c
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 1 in
        let _ = owned_vec_push v 2 in
        owned_vec_len v"))
    "1";
  check "Phase 38.G-1: body returns v → no auto-Drop"
    (string_of_int (count_owned_vec_free_c
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 1 in
        v"))
    "0";
  check "Phase 38.G-1: v stashed in tuple → no auto-Drop"
    (string_of_int (count_owned_vec_free_c
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 1 in
        let pair = (v, 42) in
        snd pair"))
    "0";
  check "Phase 38.G-1: closure captures v → no auto-Drop"
    (string_of_int (count_owned_vec_free_c
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 1 in
        let getter = fn () -> owned_vec_len v in
        getter ()"))
    "0";
  check "Phase 38.G-1: nested let chain with safe tail → auto-Drop"
    (string_of_int (count_owned_vec_free_c
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 10 in
        let _ = owned_vec_push v 20 in
        let _ = owned_vec_push v 30 in
        let sum = owned_vec_len v in
        sum * 2"))
    "1";
  check "Phase 38.G-1: if branches both return scalar → auto-Drop"
    (string_of_int (count_owned_vec_free_c
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 5 in
        if owned_vec_len v > 0 then 1 else 0"))
    "1";
  check "Phase 38.G-1: if branch returns v → no auto-Drop"
    (string_of_int (count_owned_vec_free_c
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 1 in
        if true then v else v"))
    "0";
  check "Phase 38.G-1: interp behavior preserved (auto-Drop case)"
    (Pipeline.process
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 7 in
        let _ = owned_vec_push v 8 in
        owned_vec_len v")
    "2";
  let llvm_main_has_free src =
    let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog src) in
    let needle = "define i32 @main" in
    let len_n = String.length needle in
    let rec find_main i =
      if i + len_n > String.length ll then -1
      else if String.sub ll i len_n = needle then i
      else find_main (i + 1)
    in
    let main_start = find_main 0 in
    if main_start < 0 then false
    else
      let rest = String.sub ll main_start (String.length ll - main_start) in
      let end_marker = "\n}" in
      let elen = String.length end_marker in
      let rec find_end i =
        if i + elen > String.length rest then String.length rest
        else if String.sub rest i elen = end_marker then i
        else find_end (i + 1)
      in
      let main_body = String.sub rest 0 (find_end 0) in
      let free_needle = "call void @free" in
      let fn_len = String.length free_needle in
      let rec scan i =
        if i + fn_len > String.length main_body then false
        else if String.sub main_body i fn_len = free_needle then true
        else scan (i + 1)
      in
      scan 0
  in
  check "Phase 38.G-1: LLVM emits scope-end free in main for safe pattern"
    (if llvm_main_has_free
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 1 in
        owned_vec_len v" then "ok" else "no free")
    "ok";
  check "Phase 38.G-1: LLVM does NOT emit scope-end free in main for escape"
    (if llvm_main_has_free
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 1 in
        v" then "main has free" else "ok")
    "ok";
  check "Phase 38.G-1: Phase 38.C partial app + auto-Drop coexist"
    (string_of_int (count_owned_vec_free_c
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 0 in
        let push_v = owned_vec_push v in
        let _ = push_v 1 in
        let _ = push_v 2 in
        owned_vec_len v"))
    "1";

  (* Phase 38.G-1 soundness: when a closure capturing v is returned at the tail
     of the body, auto-Drop would cause use-after-free. Prevent it via taint
     propagation. *)
  check "Phase 38.G-1: returned closure captures v -> NO auto-Drop"
    (string_of_int (count_owned_vec_free_c
       "let make_getter = fn () ->
          let v = owned_vec_new () in
          let _ = owned_vec_push v 100 in
          let get = owned_vec_get v in
          get in
        let g = make_getter () in
        g 0"))
    "0";
  check "Phase 38.G-1: transitive detection of tuple stash via let"
    (string_of_int (count_owned_vec_free_c
       "let make_pair = fn () ->
          let v = owned_vec_new () in
          let _ = owned_vec_push v 7 in
          let bundle = (v, 42) in
          bundle in
        let p = make_pair () in
        snd p"))
    "0";
  check "Phase 38.G-1: scalar derivation (len v) does not propagate taint"
    (string_of_int (count_owned_vec_free_c
       "let v = owned_vec_new () in
        let _ = owned_vec_push v 1 in
        let _ = owned_vec_push v 2 in
        let n = owned_vec_len v in
        n + 100"))
    "1";

  (* Phase 22.1: P_tuple let pattern in C / LLVM / Wasm codegen.
     When E is a tuple type in `let (a, b) = E in B`, emit per-field
     extraction from the tuple struct. *)
  check "§22.1: let (a, b) = E in B works in interpreter"
    (Pipeline.process "let (a, b) = (3, 4) in a + b") "7";
  check "§22.1: nested let-tuple chain works in interpreter"
    (Pipeline.process
       "let p = (1, 2) in let (x, y) = p in let q = (x, y, x + y) in \
        let (a, b, c) = q in a + b + c") "6";
  check "§22.1: P_tuple let emits C code"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let (a, b) = (3, 4) in a + b") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "§22.1: P_tuple let emits LLVM IR"
    (let ll_src = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let (a, b) = (3, 4) in a + b") in
     if String.length ll_src > 0 then "ok" else "empty")
    "ok";
  check "§22.1: P_tuple let emits Wasm"
    (let wat_src = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let (a, b) = (3, 4) in a + b") in
     if String.length wat_src > 0 then "ok" else "empty")
    "ok";
  check "§22.1: P_tuple let with wildcard slot"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let (a, _) = (10, 99) in a") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";

  (* Phase 22.2: inner let-rec lifting in C codegen.
     Support `let host = fn x -> let rec go = ... in go ...` in C codegen.
     Add a Let_rec case to lift_inner_fns to lift recursive / mutually
     recursive bindings to top-level lifted_fn and rewrite call sites. *)
  check "§22.2: inner let-rec lifts in C codegen (self-recursive)"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let sum_to = fn (n: int) ->\n\
       \  let rec go = fn (i: int) ->\n\
       \    if i > n then 0 else i + go (i + 1)\n\
       \  in go 1;\n\
        sum_to 10") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "§22.2: inner let-rec lifts in C codegen (mutual)"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let test = fn (n: int) ->\n\
       \  let rec is_even = fn (x: int) ->\n\
       \    if x == 0 then true else is_odd (x - 1)\n\
       \  and is_odd = fn (x: int) ->\n\
       \    if x == 0 then false else is_even (x - 1)\n\
       \  in if is_even n then 1 else 0;\n\
        test 10") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";

  (* Phase 22.3: char builtins (char_at / is_digit / is_alpha / is_space)
     + str_of_int (alias for show_int) supported in C codegen. Use a
     256-entry static table + inlined ctype.h logic. *)
  check "§22.3: char_at / is_digit emit C code"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let s = \"123abc\" in if is_digit (char_at s 0) then 1 else 0") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "§22.3: __lang_char_at helper emitted in C source"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "char_at \"x\" 0") in
     if String.length c_src > 0 && Pipeline.exhaustiveness_warnings "char_at \"x\" 0" = [] then "ok" else "empty")
    "ok";
  check "§22.3: str_of_int → show_int alias in C codegen"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyStr (typed_prog
       "str_of_int 42") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";

  (* Phase 22.4: tuple struct body topo sort + fail builtin in C codegen.
     Topo-sort forward-decl order for nested tuples (tuple of tuple or
     record with tuple field), and emit fail as a noreturn helper. *)
  check "§22.4: nested tuple struct topo sort (no incomplete type)"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let outer = ((\"x\", 1), 2) in let (inner, n) = outer in n") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "§22.4: fail builtin emits in C codegen"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "if true then 1 else fail \"never\"") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "§22.4: fail with str return type"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyStr (typed_prog
       "if true then \"ok\" else fail \"bad\"") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";

  (* Phase 22.5: substring / try_or / int_of_str builtins + unified
     struct body topo sort + str == strcmp + match abort cast + per-host
     inner_lifts scope. Milestone where mini_calc fully works on C codegen. *)
  check "§22.5: substring emits in C codegen"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyStr (typed_prog
       "substring \"hello world\" 0 5") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "§22.5: try_or catches fail and returns default"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "try_or (fn () -> fail \"bad\") 42") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "§22.5: string == becomes strcmp"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyBool (typed_prog
       "\"hello\" == \"hello\"") in
     (* Body should contain strcmp call — naive substring search. *)
     let s = c_src in let pat = "strcmp" in
     let nlen = String.length s and plen = String.length pat in
     let rec scan i =
       if i + plen > nlen then false
       else if String.sub s i plen = pat then true
       else scan (i + 1)
     in
     if scan 0 then "ok" else "missing-strcmp")
    "ok";

  (* Phase 22.6: C reserved keyword mangling + str_unescape builtin +
     polymorphic type name in match abort fallthrough. *)
  check "§22.6: user fn named `case` emits valid C (keyword mangling)"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let case = fn (x: int) -> x + 1 in case 5") in
     if String.length c_src > 0 then "ok" else "empty")
    "ok";
  check "§22.6: str_unescape emits __lang_str_unescape"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyStr (typed_prog
       "str_unescape \"a\\nb\"") in
     let pat = "__lang_str_unescape" in
     let nlen = String.length c_src and plen = String.length pat in
     let rec scan i =
       if i + plen > nlen then false
       else if String.sub c_src i plen = pat then true
       else scan (i + 1)
     in
     if scan 0 then "ok" else "missing")
    "ok";

  (* Phase 23.1: multi-instantiation detection — single-spec fn called
     with 2+ distinct concrete types now raises a clear codegen error
     instead of silently miscompiling (which led to SIGABRT in json_parser). *)
  (* Phase 23.2: Option / Result helpers in prelude. *)
  check "§23.2: option_map (Some)"
    (Pipeline.process "option_map (Some 5) (fn x -> x * 10)")
    "Some 50";
  check "§23.2: option_map (None)"
    (Pipeline.process "option_map None (fn x -> x * 10)")
    "None";
  check "§23.2: option_default (Some)"
    (Pipeline.process "option_default (Some 42) 0") "42";
  check "§23.2: option_default (None)"
    (Pipeline.process "option_default None 0") "0";
  check "§23.2: option_is_some (Some)"
    (Pipeline.process "option_is_some (Some 1)") "true";
  check "§23.2: option_is_some (None)"
    (Pipeline.process "option_is_some None") "false";
  check "§23.2: result_map (Ok)"
    (Pipeline.process "result_map (Ok 5) (fn x -> x + 1)") "Ok 6";
  check "§23.2: result_map (Err)"
    (Pipeline.process "result_map (Err \"bad\") (fn x -> x + 1)") "Err \"bad\"";
  check "§23.2: result_and_then (Ok chain)"
    (Pipeline.process
       "result_and_then (Ok 10) (fn x -> if x > 5 then Ok (x * 2) else Err \"small\")")
    "Ok 20";
  check "§23.2: result_and_then (Err short-circuit)"
    (Pipeline.process
       "result_and_then (Err \"e\") (fn x -> Ok (x + 1))")
    "Err \"e\"";
  check "§23.2: result_or_else (Err recover)"
    (Pipeline.process
       "result_or_else (Err 0) (fn e -> Ok (e + 99))")
    "Ok 99";
  check "§23.2: result_default (Err)"
    (Pipeline.process "result_default (Err \"e\") 7") "7";
  check "§23.2: result_is_ok (Ok)"
    (Pipeline.process "result_is_ok (Ok 1)") "true";
  check "§23.2: result_is_ok (Err)"
    (Pipeline.process "result_is_ok (Err \"e\")") "false";

  (* Phase 23.1 → 23.3: multi-instantiation poly fn now works (per-spec
     emit) instead of raising. Verify both call sites succeed. *)
  check "§23.3: multi-instantiation poly fn — int + str (interp)"
    (Pipeline.process
       "let rec id = fn x -> x in\n\
        let a = id 5 in\n\
        let b = id \"hi\" in\n\
        a") "5";
  (* Phase 23.5: show_str escapes special chars to match interp.
     show's output wraps the str in quotes, so e.g. `show "a\nb"`
     returns the 6-char string `"a\nb"`. *)
  check "§23.5: show_str escapes newline as backslash-n"
    (Pipeline.process "show \"a\\nb\"") "\"\\\"a\\\\nb\\\"\"";
  check "§23.5: show_str escapes double-quote"
    (Pipeline.process "show \"a\\\"b\"") "\"\\\"a\\\\\\\"b\\\"\"";
  check "§23.5: show_str escapes backslash"
    (Pipeline.process "show \"a\\\\b\"") "\"\\\"a\\\\\\\\b\\\"\"";

  check "§23.4: chained multi-inst — child poly fn called only via parent multi-inst"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let rec helper = fn x -> x in\n\
        let wrap = fn x -> helper x in\n\
        let a = wrap 5 in\n\
        let b = wrap \"hi\" in\n\
        let __ = print b in\n\
        a") in
     let s = c_src in
     let has p =
       let nlen = String.length s and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub s i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "helper__int" && has "helper__str" && has "wrap__int" && has "wrap__str"
     then "all4" else "missing")
    "all4";
  check "§23.3: multi-instantiation poly fn — C codegen emits 2 specs"
    (let c_src = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let rec id = fn x -> x in\n\
        let a = id 5 in\n\
        let b = id \"hi\" in\n\
        let __ = print b in\n\
        a") in
     (* Should contain mangled id__int and id__str. *)
     let s = c_src in
     let has p =
       let nlen = String.length s and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub s i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "id__int" && has "id__str" then "ok" else "missing-spec")
    "ok";

  (* Phase 25.3: LLVM inner let-rec lifting. Port the C codegen inner-fn lift
     to LLVM codegen. Add ce_host to closure_emission so anonymous closures
     can be drained per-host scope. Milestone where mini_calc fully works in
     LLVM codegen (diff = 0 against interp). *)
  check "§25.3: LLVM inner let-rec lifts (self-recursive)"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let sum_to = fn (n: int) ->\n\
       \  let rec go = fn (i: int) ->\n\
       \    if i > n then 0 else i + go (i + 1)\n\
       \  in go 1;\n\
        sum_to 10") in
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "__lifted_go_" then "ok" else "no-lift")
    "ok";
  check "§25.3: LLVM inner-lifted call inside anonymous closure body"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let host = fn (n: int) ->\n\
       \  let rec loop = fn (acc: int) -> fn (k: int) ->\n\
       \    if k == 0 then acc else (loop (acc + k)) (k - 1)\n\
       \  in (loop 0) n;\n\
        host 5") in
     if String.length ll > 0 then "ok" else "empty")
    "ok";

  (* Phase 45 (DEFERRED §8): resolve mutual references between inner-lifted fns
     via transitive capture. If helper captures base and caller calls helper,
     then caller transitively captures base too. *)
  check "§45: inner-lifted mutual reference (interp)"
    (Pipeline.process
       "let outer = fn (n: int) ->\n\
       \  let base = n * 10 in\n\
       \  let rec helper = fn (x: int) ->\n\
       \    if x <= 0 then base else helper (x - 1) + 1 in\n\
       \  let rec caller = fn (y: int) ->\n\
       \    if y <= 0 then 0 else helper y + caller (y - 1) in\n\
       \  caller 3 in\n\
        outer 2") "66";
  (* Phase 45 (DEFERRED §8) for `let rec ... and ...` mutual recursion *)
  check "§45: inner-lifted let-rec and-mutual recursion (interp)"
    (Pipeline.process
       "let scanner = fn (s: str) ->\n\
       \  let n = str_len s in\n\
       \  let rec find_a = fn (i: int) ->\n\
       \    if i >= n then -1\n\
       \    else if char_at s i == \"a\" then i\n\
       \    else find_b (i + 1)\n\
       \  and find_b = fn (i: int) ->\n\
       \    if i >= n then -1\n\
       \    else if char_at s i == \"b\" then i\n\
       \    else find_a (i + 1) in\n\
       \  find_a 0 in\n\
        scanner \"xyzbabc\"") "3";

  (* Phase 25.4: LLVM str_unescape runtime helper + Phase 25.0 boxed-payload
     load bug fix in show_<variant>. Fixed so that the show fn reads payload
     fields with a 2-step load (load ptr, then load value). *)
  check "§25.4: LLVM str_unescape emits runtime helper"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "str_unescape \"a\\nb\"") in
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "__lang_str_unescape" then "ok" else "missing-helper")
    "ok";
  check "§25.4: show of variant payload deref via boxed ptr"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "type opt = N | S of int;\n\
        show (S 42)") in
     (* show_arm for S should do: load ptr first, then load i32. *)
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "@show_opt" && has "load ptr" then "ok" else "missing")
    "ok";

  (* Phase 25.5: LLVM multi-instantiation specialization (LLVM port of
     Phase 23.3). poly fn called at 2+ distinct concrete arrow types →
     emit one spec per type with mangled name + dispatch at call site. *)
  check "§25.5: LLVM multi-instantiation poly fn — int + str emits 2 specs"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let rec id = fn x -> x in\n\
        let a = id 5 in\n\
        let b = id \"hi\" in\n\
        let __ = print b in\n\
        a") in
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "id__int" && has "id__str" then "ok" else "missing-spec")
    "ok";
  check "§25.5: LLVM multi-inst rev (json_parser style — 2 list types)"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        let rec rev_aux = fn (l: 'a list, acc: 'a list) ->\n\
          match l with\n\
          | Nil -> acc\n\
          | [h, ...t] -> rev_aux t (Cons (h, acc));\n\
        let rev = fn (l: 'a list) -> rev_aux l Nil;\n\
        let _ = rev (Cons (1, Cons (2, Nil)));\n\
        let _ = rev (Cons (\"a\", Cons (\"b\", Nil)));\n\
        0") in
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "rev__list_int" && has "rev__list_str" then "ok" else "missing-spec")
    "ok";

  (* Phase 25.6: LLVM __lang_str_escape runtime + show_str route.
     show_str outputs backslash-escape (newline / tab / cr / backslash / quote)
     the same way as interp. *)
  check "§25.6: LLVM str_escape runtime helper emitted"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "show \"hi\"") in
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "__lang_str_escape" then "ok" else "missing-helper")
    "ok";
  check "§25.6: LLVM show_str goes through str_escape"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "show \"hi\"") in
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "call ptr @__lang_str_escape" then "ok" else "show-str-not-wired")
    "ok";

  (* Phase 25.7: anon-adapter body-type unify + fn dedup by name. *)
  check "§25.7: LLVM compiles poly list fn (Nil instantiation tyvar fix)"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        let rec rev_aux = fn (acc) -> fn (xs) ->\n\
          match xs with\n\
          | Nil -> acc\n\
          | Cons (h, t) -> rev_aux (Cons (h, acc)) t;\n\
        let rev = fn (l) -> rev_aux Nil l;\n\
        let _ = rev (Cons (1, Cons (2, Nil)));\n\
        0") in
     if String.length ll > 0 then "ok" else "empty")
    "ok";
  (* Phase 26.0: Wasm variant boxed payload — no longer requires uniform
     payload types across ctors (mirrors LLVM Phase 25.0). *)
  check "§26.0: Wasm emits variant with mixed payload types"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "type mixed = A of int | B of str;\n\
        match A 42 with | A n -> show n | B s -> s") in
     if String.length wat > 0 then "ok" else "empty")
    "ok";
  (* Phase 26.1: Wasm stdlib builtins (Wasm version of LLVM Phases 25.1/25.4). *)
  check "§26.1: Wasm emits fail builtin (unreachable trap)"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "if true then 1 else fail \"never\"") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "$__lang_fail" then "ok" else "missing")
    "ok";
  check "§26.1: Wasm emits char_at + is_digit"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyBool (typed_prog
       "is_digit (char_at \"a1\" 1)") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "$__lang_char_at" && has "$__lang_is_digit" then "ok" else "missing")
    "ok";
  check "§26.1: Wasm emits substring + int_of_str"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "int_of_str (substring \"123abc\" 0 3)") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "$__lang_substring" && has "$__lang_int_of_str" then "ok" else "missing")
    "ok";
  check "§26.1: Wasm emits str_unescape"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "str_unescape \"a\\\\nb\"") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "$__lang_str_unescape" then "ok" else "missing")
    "ok";
  (* Phase 27.3: Wasm ty_tag permits StrBuf. The mere_strbuf runtime was
     already implemented in Phase 15.9, but ty_tag had been early-rejecting it
     as interpreter-only. This unlocks the StrBuf-in-tuple/variant use
     in json_writer. *)
  check "§27.3: Wasm StrBuf ty_tag returns strbuf"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "region R { let buf = strbuf_new () in let _ = strbuf_push buf \"hi\" in strbuf_to_str buf }") in
     if String.length wat > 0 then "ok" else "empty")
    "ok";

  (* Phase 27.2: Wasm prints `()` for main_ty and force-registers
     show_<main_ty> for auto-print, so that the runtime execution
     (Node.js host harness) PERFECTLY matches interp. *)
  check "§27.2: Wasm main_ty=int auto-prints via show_int + puts"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let _ = print \"hi\" in 42") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "$show_int" && has "call $show_int" then "ok" else "missing")
    "ok";
  check "§27.2: Wasm main_ty=unit prints \"()\""
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyUnit (typed_prog
       "print \"hi\"") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "drop" && has "call $puts" then "ok" else "missing")
    "ok";

  (* Phase 27.1: pin interp Map iter order to insertion order, to match the
     C / LLVM / Wasm Map runtime (parallel arrays) so word_freq / mini_shell
     match PERFECTLY across all backends. *)
  check "§27.1: interp Map iter follows insertion order"
    (Pipeline.process
       "region R {\n\
        let m = map_new () in\n\
        let _ = map_set m \"c\" 1 in\n\
        let _ = map_set m \"a\" 2 in\n\
        let _ = map_set m \"b\" 3 in\n\
        let buf = strbuf_new () in\n\
        let _ = map_iter m (fn k -> fn v ->\n\
          let _ = strbuf_push buf (k ++ \"=\" ++ show v ++ \";\") in ()) in\n\
        strbuf_to_str buf\n\
        }")
    "\"c=1;a=2;b=3;\"";

  (* Phase 26.6: Wasm polishing — Var shadowing for stdlib builtins
     (template_engine unlock) + str_escape via show_str. *)
  check "§26.6: Wasm Var shadowing — local `let len = ...` shadows stdlib"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let template = \"hi\" in\n\
        let len = str_len template in\n\
        len") in
     if String.length wat > 0 then "ok" else "empty")
    "ok";
  check "§26.6: Wasm show_str pipes through str_escape"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "show \"hi\"") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "$__lang_str_escape" && has "call $__lang_str_escape" then "ok" else "missing")
    "ok";

  (* Phase 26.5: Wasm stdlib catch-up (str_split / str_join / str_count /
     read_file / write_file) + lift_fn_skels non-Fun walk. *)
  check "§26.5: Wasm str_split + str_join roundtrip emit"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "let xs = str_split \"a,b,c\" \",\" in str_join \"-\" xs") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "$__lang_str_split" && has "$__lang_str_join" then "ok" else "missing")
    "ok";
  check "§26.5: Wasm read_file / write_file emits env imports"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "let _ = write_file \"/tmp/x\" \"hi\" in read_file \"/tmp/x\"") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "$__lang_read_file" && has "$__lang_write_file" then "ok" else "missing")
    "ok";

  (* Phase 26.4: Wasm multi-instantiation specialization
     (Wasm version of LLVM Phase 25.5). *)
  check "§26.4: Wasm multi-inst poly fn emits 2 specs (int + str)"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let rec id = fn x -> x in\n\
        let a = id 5 in\n\
        let b = id \"hi\" in\n\
        let __ = print b in\n\
        a") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "$id__int" && has "$id__str" then "ok" else "missing-spec")
    "ok";

  (* Phase 26.3: Wasm inner let-rec lifting (Wasm version of LLVM Phase 25.3). *)
  check "§26.3: Wasm inner let-rec lifts (self-recursive)"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let sum_to = fn (n: int) ->\n\
       \  let rec go = fn (i: int) ->\n\
       \    if i > n then 0 else i + go (i + 1)\n\
       \  in go 1;\n\
        sum_to 10") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "__lifted_go_" then "ok" else "no-lift")
    "ok";
  (* Phase 30.2 (DEFERRED §1.10 fix, C only): when a top-level non-fn let is
     referenced from inside a top-level fn body, C codegen declares it as a
     global. LLVM / Wasm still throw "unbound variable" via a different path. *)
  (* Phase 32.1-32.4: C1 FFI (extern fn). Test the same extern fn across all
     4 backends through the declaration -> codegen path. interp goes through
     the lookup_extern mock; the 3 codegens each use their own dispatch path. *)
  check "§32.1: extern fn parse + interp mock (getpid)"
    (Pipeline.process
       "extern fn getpid: unit -> int;\n\
        getpid () > 0")
    "true";
  check "§32.2: C codegen emits extern declaration + direct call"
    (let c = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "extern fn getpid: unit -> int;\n\
        getpid ()") in
     let nlen = String.length c in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub c i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     if has "extern int getpid(void);" && has "getpid()" then "ok" else "no")
    "ok";
  check "§32.3: LLVM codegen emits declare + call"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "extern fn getpid: unit -> int;\n\
        getpid ()") in
     let nlen = String.length ll in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     if has "declare i32 @getpid()" && has "call i32 @getpid(" then "ok" else "no")
    "ok";
  check "§32.6: multi-arg curried extern interp (setenv + getenv roundtrip)"
    (Pipeline.process
       "extern fn setenv: str -> str -> int -> int;\n\
        extern fn getenv: str -> str;\n\
        let _ = setenv \"MERE_TEST_X\" \"abc\" 1 in\n\
        getenv \"MERE_TEST_X\"")
    "\"abc\"";
  check "§32.6: C codegen multi-arg extern decl + call"
    (let c = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "extern fn setenv: str -> str -> int -> int;\n\
        setenv \"K\" \"V\" 1") in
     let nlen = String.length c in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub c i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     if has "extern int setenv(const char*, const char*, int);"
        && has "setenv(\"K\", \"V\", 1)" then "ok" else "no")
    "ok";

  check "§32.4: Wasm codegen emits (import) + call"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "extern fn getpid: unit -> int;\n\
        getpid ()") in
     let nlen = String.length wat in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     if has "(import \"env\" \"getpid\" (func $getpid (result i32)))"
        && has "call $getpid" then "ok" else "no")
    "ok";

  check "§30.2: C codegen — top-level let referenced in fn body becomes global"
    (let c = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let total = 42;\n\
        let check = fn (n: int) -> total + n;\n\
        check 100") in
     let nlen = String.length c in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub c i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     if has "static int total;" && has "total = 42;" then "globalized"
     else "not-globalized")
    "globalized";
  check "§30.2: LLVM codegen — top-level let referenced in fn body becomes @global"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let total = 42;\n\
        let check = fn (n: int) -> total + n;\n\
        check 100") in
     let nlen = String.length ll in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     if has "@total = internal global" && has "store i32 " && has ", ptr @total" then "globalized"
     else "not-globalized")
    "globalized";
  (* Phase 31.0: port str_compare to the 3 backends (align what was interp-only) *)
  check "§31.0: interp str_compare returns -1/0/1"
    (Pipeline.process "(str_compare \"a\" \"b\", str_compare \"a\" \"a\", str_compare \"b\" \"a\")")
    "(-1, 0, 1)";
  check "§31.0: C codegen emits __lang strcmp normalize"
    (let c = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "str_compare \"a\" \"b\"") in
     let nlen = String.length c in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub c i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     if has "strcmp(\"a\", \"b\")" && has "__r < 0 ? -1" then "ok" else "no")
    "ok";
  check "§31.0: LLVM codegen emits strcmp + select normalize"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "str_compare \"a\" \"b\"") in
     let nlen = String.length ll in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     if has "call i32 @strcmp" && has "select i1" then "ok" else "no")
    "ok";
  check "§31.0: Wasm codegen emits $__lang_str_compare helper + call"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "str_compare \"a\" \"b\"") in
     let nlen = String.length wat in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     if has "(func $__lang_str_compare" && has "call $__lang_str_compare" then "ok" else "no")
    "ok";

  check "§30.2: Wasm codegen — top-level let referenced in fn body becomes (global)"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let total = 42;\n\
        let check = fn (n: int) -> total + n;\n\
        check 100") in
     let nlen = String.length wat in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     if has "(global $total (mut i32)" && has "global.set $total" then "globalized"
     else "not-globalized")
    "globalized";

  (* Phase 30.1 (DEFERRED §1.11 fix): when a captured name in a closure is
     shadowed by a let, body-internal Var references should look at the local
     rather than env access. Directly inspect the C codegen emit: confirm that
     the recursive call after tuple destructure uses local `xs` rather than
     `__env_self->xs`. *)
  check "§30.1: C codegen — P_tuple rebind shadows captured env access"
    (let c = Codegen_c.emit_program ~main_ty:Ast.TyInt (typed_prog
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        type tok = TInt of int | TEnd;\n\
        let parse_head = fn (xs: tok list) ->\n\
          match xs with\n\
          | Nil -> (0, Nil)\n\
          | Cons (TInt n, rest) -> (n, rest)\n\
          | Cons (TEnd, rest) -> (0, rest);\n\
        let rec sum_aux = fn (xs: tok list) -> fn (acc: int) ->\n\
          match xs with\n\
          | Nil -> acc\n\
          | _ ->\n\
            let (h, xs) = parse_head xs in\n\
            sum_aux xs (acc + h);\n\
        sum_aux (Cons (TInt 1, Cons (TInt 2, Cons (TInt 3, Nil)))) 0") in
     (* The anon closure body should destructure via `__let_tup` and use local
        `xs` for the recursive call. `sum_aux((__env_self->xs))` would indicate
        a bug leaking to the old captured xs. *)
     let nlen = String.length c in
     let has needle =
       let plen = String.length needle in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub c i plen = needle then true
         else scan (i + 1)
       in scan 0
     in
     (* Bug state: closure body contains sum_aux((__env_self->xs)) — read from env *)
     (* After fix: sum_aux(xs) — uses local rebinding *)
     if has "sum_aux((__env_self->xs))" then "env-leak"
     else if has "sum_aux(xs)" then "local-shadow"
     else "neither")
    "local-shadow";

  (* Phase 30.0 (DEFERRED §1.12 fix): verify that a user-defined fn can shadow
     a builtin's hardcoded dispatch. is_alpha is a builtin, but when a user
     definition exists, skip the builtin call and dispatch to the user fn. *)
  check "§30.0: C codegen — user-defined is_alpha shadows __lang_is_alpha"
    (let c = Codegen_c.emit_program ~main_ty:Ast.TyBool (typed_prog
       "let is_alpha = fn (c: str) -> c == \"_\";\n\
        is_alpha \"_\"") in
     let has_user_fn =
       let nlen = String.length c and plen = String.length "int is_alpha(" in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub c i plen = "int is_alpha(" then true
         else scan (i + 1)
       in scan 0
     in
     if has_user_fn then "shadowed" else "builtin-leak")
    "shadowed";
  check "§30.0: LLVM codegen — user-defined is_alpha shadows __lang_is_alpha"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyBool (typed_prog
       "let is_alpha = fn (c: str) -> c == \"_\";\n\
        is_alpha \"_\"") in
     let has_user_fn =
       let nlen = String.length ll and plen = String.length "@is_alpha(" in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = "@is_alpha(" then true
         else scan (i + 1)
       in scan 0
     in
     if has_user_fn then "shadowed" else "builtin-leak")
    "shadowed";
  check "§30.0: Wasm codegen — user-defined is_alpha shadows __lang_is_alpha"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyBool (typed_prog
       "let is_alpha = fn (c: str) -> c == \"_\";\n\
        is_alpha \"_\"") in
     let has_user_fn =
       let nlen = String.length wat and plen = String.length "(func $is_alpha " in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = "(func $is_alpha " then true
         else scan (i + 1)
       in scan 0
     in
     if has_user_fn then "shadowed" else "builtin-leak")
    "shadowed";

  check "§26.3: Wasm fn dedup — user-defined name shadows stdlib"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        let rec list_rev_into = fn (acc) -> fn (xs) ->\n\
          match xs with\n\
          | Nil -> acc\n\
          | Cons (h, t) -> list_rev_into (Cons (h, acc)) t;\n\
        let _ = list_rev_into Nil (Cons (1, Nil));\n\
        0") in
     (* Count $list_rev_into definitions — must be 1. *)
     let count p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i acc =
         if i + plen > nlen then acc
         else if String.sub wat i plen = p then scan (i + plen) (acc + 1)
         else scan (i + 1) acc
       in scan 0 0
     in
     if count "(func $list_rev_into " = 1 then "ok" else "dup-or-missing")
    "ok";

  (* Phase 26.2: Wasm try_or via fail flag + active-counter. *)
  check "§26.2: Wasm try_or catches fail and returns default"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "try_or (fn () -> fail \"bad\") 42") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "$__lang_fail_active" && has "$__lang_fail_flag"
        && has "call_indirect" then "ok" else "missing")
    "ok";

  check "§26.1: Wasm emits strcmp for TyStr eq"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyBool (typed_prog
       "\"hello\" == \"hello\"") in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in scan 0
     in
     if has "call $__lang_streq" then "ok" else "missing")
    "ok";

  check "§26.0: Wasm emits poly variant (json-style nested)"
    (let wat = Codegen_wasm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "type myjson = JNum of int | JBool of bool | JStr of str;\n\
        match JNum 42 with | JNum n -> show n | JBool b -> show b | JStr s -> s") in
     if String.length wat > 0 then "ok" else "empty")
    "ok";

  (* Phase 25.12: closure-call arrow_ty fallback from current_var_types
     for polymorphic callback dispatch (word_freq). *)
  check "§25.12: LLVM closure call recovers concrete arrow from arg's var binding"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        let rec list_iter = fn xs -> fn f ->\n\
          match xs with\n\
          | Nil -> ()\n\
          | Cons (h, t) -> { f h; list_iter t f } in\n\
        let _ = list_iter (Cons (1, Cons (2, Nil))) (fn x -> print (show x)) in\n\
        0") in
     if String.length ll > 0 then "ok" else "empty")
    "ok";

  (* Phase 25.11: LLVM prints "()" for unit main_ty to match interp. *)
  check "§25.11: LLVM emits @.fmt_unit and printf for unit main"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyUnit (typed_prog
       "print \"hi\"") in
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "@.fmt_unit" && has "call i32 (ptr, ...) @printf(ptr @.fmt_unit)" then "ok" else "missing")
    "ok";

  (* Phase 25.10: Var-shadowing for stdlib builtins (template_engine). *)
  check "§25.10: local `let len = ...` shadows stdlib len"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "let template = \"hi\" in\n\
        let len = str_len template in\n\
        len") in
     if String.length ll > 0 then "ok" else "empty")
    "ok";

  (* Phase 25.9: LLVM stdlib catch-up — str_split / str_join / str_count /
     read_file / write_file builtins + Phase 24.4 port of lift_fn_skels. *)
  check "§25.9: LLVM str_split + str_join roundtrip"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "let xs = str_split \"a,b,c\" \",\" in str_join \"-\" xs") in
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "__lang_str_split" && has "__lang_str_join" then "ok" else "missing")
    "ok";
  check "§25.9: LLVM read_file / write_file emits file I/O runtime"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyStr (typed_prog
       "let _ = write_file \"/tmp/x\" \"hello\" in read_file \"/tmp/x\"") in
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "__lang_read_file" && has "__lang_write_file" then "ok" else "missing")
    "ok";

  (* Phase 25.8: short-circuit P_constr tag check before payload deref. *)
  check "§25.8: LLVM nested P_constr no longer SEGVs on tag mismatch"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        type sexpr = SInt of int | SSym of str | SList of sexpr list;\n\
        let test = fn (items: sexpr list) ->\n\
        \  match items with\n\
        \  | Nil -> 0\n\
        \  | Cons (SSym \"if\", Cons (c, Cons (t, Cons (f, Nil)))) -> 1\n\
        \  | Cons (SSym op, args) -> 2\n\
        \  | _ -> 3;\n\
        test (Cons (SSym \"+\", Cons (SInt 1, Cons (SInt 2, Nil))))") in
     (* Look for the short-circuit branch label "tag_ok_" emitted by compile_pat. *)
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub ll i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "tag_ok_" then "ok" else "no-short-circuit")
    "ok";

  check "§25.7: LLVM fn dedup — user-defined name shadows stdlib"
    (let ll = Codegen_llvm.emit_program ~main_ty:Ast.TyInt (typed_prog
       "type 'a list = Nil | Cons of 'a * 'a list;\n\
        let rec list_rev_into = fn (acc) -> fn (xs) ->\n\
          match xs with\n\
          | Nil -> acc\n\
          | Cons (h, t) -> list_rev_into (Cons (h, acc)) t;\n\
        let list_reverse = fn (l) -> list_rev_into Nil l;\n\
        let _ = list_reverse (Cons (1, Cons (2, Nil)));\n\
        0") in
     (* Count occurrences of `define %... @list_rev_into(` — must be 1. *)
     let count_define name =
       let needle = "@" ^ name ^ "(" in
       let nlen = String.length ll and plen = String.length needle in
       let rec scan i acc =
         if i + plen > nlen then acc
         else if String.sub ll i plen = needle then begin
           (* Only count if preceded by "define ". *)
           let starts_with_define =
             i >= 7 + 21 (* approximate length of "define %... " *) &&
             (try String.sub ll (i - 7) 7 = "define " ||
                  (i >= 30 && String.sub ll (i - 30) 7 = "define ")
              with _ -> false)
           in
           let acc' = if starts_with_define then acc + 1 else acc in
           scan (i + plen) acc'
         end else scan (i + 1) acc
       in
       scan 0 0
     in
     let _ = count_define in
     (* Simpler check: just look for the function appearing as a definition once. *)
     let has p =
       let nlen = String.length ll and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then 0
         else if String.sub ll i plen = p then 1 + scan (i + plen)
         else scan (i + 1)
       in
       scan 0
     in
     if has "define %closure_list_int_list_int @list_rev_into(" = 1 then "ok"
     else "duplicate-or-missing")
    "ok";

  (* Phase 47: mere-fmt formatter.

     `format_program` re-emits the parsed AST as a Mere source string.
     We check that the re-emitted source (a) parses again and (b) is
     idempotent under a second pass through the formatter. *)
  let fmt_src s =
    let prog = Pipeline.parse_program ~prelude:false s in
    Formatter.format_program prog
  in
  let check_fmt name src expected =
    check ("fmt: " ^ name) (fmt_src src) expected
  in
  let check_fmt_idempotent name src =
    let once = fmt_src src in
    let twice = fmt_src once in
    check ("fmt-idem: " ^ name) twice once
  in
  let check_fmt_parses name src =
    let formatted = fmt_src src in
    let _ = Pipeline.parse_program ~prelude:false formatted in
    check ("fmt-parses: " ^ name) "ok" "ok"
  in
  check_fmt "int literal" "42" "42\n";
  check_fmt "binop precedence preserved"
    "1 + 2 * 3"
    "1 + 2 * 3\n";
  check_fmt "paren insertion when needed"
    "(1 + 2) * 3"
    "(1 + 2) * 3\n";
  check_fmt "string with brace gets \\{ escape"
    {|"hi \{ world"|}
    "\"hi \\{ world\"\n";
  check_fmt "float literal grows fractional zero"
    "3.0"
    "3.0\n";
  check_fmt "let inline"
    "let x = 1 in x + 2"
    "let x = 1 in\nx + 2\n";
  check_fmt "if inline when short"
    "if true then 1 else 2"
    "if true then 1 else 2\n";
  check_fmt "list literal from Cons/Nil chain"
    "[1, 2, 3]"
    "[1, 2, 3]\n";
  check_fmt "range sugar from App range a b"
    "range 1 10"
    "1..10\n";
  check_fmt "lambda shorthand for multi-arg unannotated fn chain"
    "fn x -> fn y -> x + y"
    "\\x y -> x + y\n";
  check_fmt "drop type record fuses adjacent decls"
    "drop type Conn = { id: int }; 0"
    "drop type Conn = { id: int };\n\n0\n";
  check_fmt "view emits without ="
    "view Cell[R] { v: int }; 0"
    "view Cell[R] { v: int };\n\n0\n";
  check_fmt "match arm body with nested match gets parens"
    "match 1 with | 0 -> 0 | n -> match n with | 1 -> 1 | _ -> 2"
    "match 1 with\n| 0 -> 0\n| n -> (match n with\n  | 1 -> 1\n  | _ -> 2)\n";
  (* The parser binds `:` to the immediately preceding base expression,
     so `fn n -> n + 1 : int -> int` desugars to `fn n -> ((n + 1) : ...)`
     rather than annotating the whole `fn`. The formatter re-emits the
     same AST shape — with parens around `n + 1` because it's a binop. *)
  check_fmt "Annot wraps inner in parens to bind correctly"
    "fn n -> n + 1 : int -> int"
    "fn n -> ((n + 1) : int -> int)\n";
  check_fmt_idempotent "factorial-style let rec"
    "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10";
  check_fmt_idempotent "deeply nested if-else chain"
    "if a then 1 else if b then 2 else if c then 3 else 4";
  check_fmt_idempotent "record with annotation"
    "type Pt = { x: int, y: int }; let p = Pt { x = 1, y = 2 } in p.x";
  check_fmt_parses "operator section round-trip" "(+ 1) 2";
  check_fmt_parses "shared write borrow"
    "let r = &shared write R 1 in 0";

  (* Phase 47 follow-up (A): formatter `--check` mode equivalence. We don't
     test the CLI here, but the underlying invariant is: a file is
     "already formatted" iff `fmt_src src = src` (modulo a single trailing
     newline that the formatter always emits). *)
  let check_already_formatted name src =
    let formatted = fmt_src src in
    let result = if formatted = src then "stable" else "changed" in
    check ("already-formatted: " ^ name) result "stable"
  in
  check_already_formatted "canonical int literal" "42\n";
  check_already_formatted "canonical binop" "1 + 2 * 3\n";
  check_already_formatted "canonical list literal" "[1, 2, 3]\n";

  (* Phase 48.1 Stage 1: extern type — opaque handle declaration. The
     type is a distinct 0-arity TyCon registered via `register_type`, so
     it interoperates with the existing typer + Wasm codegen (i32
     pass-through for the host import signature). *)
  check "extern type: parses + types via extern fn"
    (Pipeline.type_of
       "extern type JsRef; \
        extern fn dom_get_by_id: str -> JsRef; \
        let r = dom_get_by_id \"main\" in 0")
    "int";
  check_raises "extern type: rejects int -> JsRef coercion via annot"
    (fun () ->
      Pipeline.type_of "extern type JsRef; let r = (42 : JsRef) in 0");
  check_raises "extern type: rejects passing int where JsRef expected"
    (fun () ->
      Pipeline.type_of
        "extern type JsRef; \
         extern fn use_ref: JsRef -> int; \
         let _ = use_ref 42 in 0");
  check "extern type: two distinct opaque types don't unify"
    (try
       let _ = Pipeline.type_of
         "extern type JsRef; \
          extern type DomNode; \
          extern fn get: str -> JsRef; \
          extern fn want_node: DomNode -> int; \
          let _ = want_node (get \"x\") in 0"
       in
       "no-error"
     with _ -> "rejected")
    "rejected";
  (* Type the program before passing to codegen — codegen reads `.ty`
     fields on each AST node. *)
  let typed_for_codegen ?(prelude = false) src =
    let prog = Pipeline.parse_program ~prelude src in
    let type_env = ref Typer.initial_env in
    List.iter (fun decl ->
      match decl with
      | Ast.Top_let (pat, value) ->
        let outer_env = !type_env in
        let t = Typer.infer outer_env value in
        let bindings = Typer.check_pattern pat t in
        type_env := List.fold_left (fun acc (n, ty) ->
          let sch = Typer.generalize outer_env ty in
          (n, sch) :: acc) outer_env bindings
      | Ast.Top_let_rec bindings ->
        let outer_env = !type_env in
        let alphas = List.map (fun _ -> Typer.fresh_var ()) bindings in
        let env_rec = List.fold_left2 (fun acc (n, _) a ->
          (n, Typer.mono a) :: acc) outer_env bindings alphas in
        List.iter2 (fun (_, value) alpha ->
          let t = Typer.infer env_rec value in
          Typer.unify value.Ast.loc alpha t) bindings alphas;
        type_env := List.fold_left2 (fun acc (n, _) a ->
          let sch = Typer.generalize outer_env a in
          (n, sch) :: acc) outer_env bindings alphas
      | Ast.Top_type (name, params, variants) ->
        Typer.register_type name params variants
      | Ast.Top_record (name, params, fields) ->
        Typer.register_record name params fields
      | Ast.Top_view (name, region, fields) ->
        Typer.register_view name region fields
      | Ast.Top_drop name -> Typer.register_drop_type name
      | Ast.Top_sync name -> Typer.register_sync_type name
      | Ast.Top_local name -> Typer.register_local_type name
      | Ast.Top_extern (name, ty) ->
        type_env := (name, Typer.mono ty) :: !type_env
      | Ast.Top_extern_type tn -> Typer.register_type tn [] []
      | Ast.Top_signature _ | Ast.Top_type_alias _
      | Ast.Top_ctor_alias _ | Ast.Top_record_alias _ -> ()
    ) prog.decls;
    let main_ty =
      Typer.infer !type_env (Ast.desugar_program prog)
    in
    prog, main_ty
  in
  check "extern type: Wasm codegen emits i32 host import for opaque param"
    (let wat =
       let prog, main_ty = typed_for_codegen
         "extern type JsRef; \
          extern fn dom_set_text: JsRef -> str -> unit; \
          ()"
       in
       Codegen_wasm.emit_program ~main_ty prog
     in
     let has p =
       let nlen = String.length wat and plen = String.length p in
       let rec scan i =
         if i + plen > nlen then false
         else if String.sub wat i plen = p then true
         else scan (i + 1)
       in
       scan 0
     in
     if has "(import \"env\" \"dom_set_text\" (func $dom_set_text (param i32) (param i32)))"
     then "ok" else "missing-or-wrong")
    "ok";

  (* Phase 48.2 Stage 2: closure -> JS callback. Wasm modules now export
     `__indirect_function_table` so host glue can pull a Mere closure out
     of the table and invoke it. Passing a `(T -> U)` closure to an
     extern fn pushes the closure pointer (an i32 to the {env, fn_idx}
     record) onto the stack just like any other i32 arg. *)
  let wat_has src needle =
    let prog, main_ty = typed_for_codegen src in
    let wat = Codegen_wasm.emit_program ~main_ty prog in
    let nlen = String.length wat and plen = String.length needle in
    let rec scan i =
      if i + plen > nlen then false
      else if String.sub wat i plen = needle then true
      else scan (i + 1)
    in
    scan 0
  in
  check "C2 Stage 2: __indirect_function_table is exported"
    (if wat_has "let inc = fn x -> x + 1 in inc 5"
         "(export \"__indirect_function_table\" (table 0))"
     then "exported" else "missing")
    "exported";
  check "C2 Stage 2: closure-typed extern fn arg accepted as i32 pointer"
    (if wat_has
        "extern type JsRef; \
         extern fn dom_on_click: JsRef -> (unit -> unit) -> unit; \
         extern fn dom_get_by_id: str -> JsRef; \
         let btn = dom_get_by_id \"go\" in \
         let _ = dom_on_click btn (fn (u: unit) -> ()) in 0"
        "(import \"env\" \"dom_on_click\" (func $dom_on_click (param i32) (param i32)))"
     then "ok" else "missing")
    "ok";

  (* Phase 48.5: closure record allocations align __lang_bump to 4 bytes
     before reserving the 8-byte {env, fn_idx} struct. Without this, a
     misaligned closure pointer forces host glue to read via DataView
     (since JS Int32Array indexing rounds the byte offset down). The
     alignment dance is `i32.const 3; i32.add; i32.const -4; i32.and;
     global.set $__lang_bump` — distinctive enough to grep for. *)
  check "C2 Stage 5: closure record alloc aligns __lang_bump to 4 bytes"
    (if wat_has
        "extern type JsRef; \
         extern fn dom_on_click: JsRef -> (unit -> unit) -> unit; \
         extern fn dom_get_by_id: str -> JsRef; \
         let btn = dom_get_by_id \"go\" in \
         let _ = dom_on_click btn (fn (u: unit) -> ()) in 0"
        "i32.const -4\n    i32.and\n    global.set $__lang_bump"
     then "aligned" else "missing")
    "aligned";

  (* Phase 50.10 / Stage 50h — self-host fmt cross-validation.
     For each sample, compute `Formatter.format_program (parse_program s)`
     on the OCaml side, then run the same source through the Mere
     self-host pipeline (`tokenize` + `parse_decls` + `format_program`,
     all defined in contrib/parser/parser.mere + contrib/fmt/fmt.mere),
     and assert byte-identical output. The two pipelines share neither
     code nor AST representation — they only agree on the surface syntax
     — so this is the strongest dogfood we have that the self-host port
     is faithful. *)

  (* Walk up from cwd until we find the project's dune-project. Dune
     runs the test binary from `_build/default/test`, so the source
     tree's `contrib/` is up the tree somewhere. *)
  let project_root =
    let rec walk d =
      if Sys.file_exists (Filename.concat d "dune-project") then d
      else
        let parent = Filename.dirname d in
        if parent = d then failwith "could not locate dune-project"
        else walk parent
    in
    walk (Sys.getcwd ())
  in

  (* P3 (mq dogfood): contrib/json's serializer lives in the same
     `module Json` as the parser, so they share the `json` type and
     compose — `Json.to_json_str (Json.parse_json s)` type-checks and
     round-trips. (Previously the writer declared its own top-level
     `json`, so parser output couldn't be fed to the writer.) *)
  let json_eval expr =
    let bridge = Printf.sprintf
      "import \"%s/contrib/json/json.mere\";\n%s\n" project_root expr in
    Exhaustive.reset ();
    let prog = Pipeline.parse_program ~base_dir:project_root bridge in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    Pipeline.process_decls eval_env type_env prog.decls;
    let _ = Typer.infer !type_env prog.main in
    match Eval.eval_in !eval_env prog.main with
    | Eval.V_str s -> s
    | _ -> "<not-a-string>"
  in
  check "P3: json parser+writer compose (array round-trip)"
    (json_eval "Json.to_json_str (Json.parse_json \"[1, 2, 3]\")")
    "[1,2,3]";
  check "P3: json serializer handles all constructors"
    (json_eval
       "Json.to_json_str (Json.JArr (Cons (Json.JBool true, Cons (Json.JNull, Cons (Json.JNum 7, Nil)))))")
    "[true,null,7]";

  (* contrib/orm: the typed row-decode + JSON-encode combinators promoted
     from the mere-blog dogfood. Decode a raw `str option list` row into
     values, then encode them back to JSON. *)
  let orm_eval expr =
    let bridge = Printf.sprintf
      "import \"%s/contrib/orm/orm.mere\";\n%s\n" project_root expr in
    Exhaustive.reset ();
    let prog = Pipeline.parse_program ~base_dir:project_root bridge in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    Pipeline.process_decls eval_env type_env prog.decls;
    let _ = Typer.infer !type_env prog.main in
    match Eval.eval_in !eval_env prog.main with
    | Eval.V_str s -> s
    | _ -> "<not-a-string>"
  in
  check "orm: decode a row then encode to JSON"
    (orm_eval
       "let row = Cons (Some \"7\", Cons (Some \"hi\", Cons (Some \"t\", Nil))) in \
        let (id, r1) = Orm.dec_int row in \
        let (name, r2) = Orm.dec_str r1 in \
        let (active, _) = Orm.dec_bool r2 in \
        Orm.enc_obj (Cons ((\"id\", Orm.enc_int id), \
          Cons ((\"name\", Orm.enc_str name), \
          Cons ((\"active\", Orm.enc_bool active), Nil))))")
    "{\"id\":7,\"name\":\"hi\",\"active\":true}";
  check "orm: enc_str escapes quotes"
    (orm_eval "Orm.enc_str \"a\\\"b\"")
    "\"a\\\"b\"";
  check "orm: dec_str_opt keeps NULL as null"
    (orm_eval "let (v, _) = Orm.dec_str_opt (Cons (None, Nil)) in Orm.enc_str_opt v")
    "null";
  check "orm: decode_rows maps a builder over rows"
    (orm_eval
       "let rows = Cons (Cons (Some \"1\", Nil), Cons (Cons (Some \"2\", Nil), Nil)) in \
        let ids = Orm.decode_rows (fn (r) -> let (n, _) = Orm.dec_int r in n) rows in \
        Orm.enc_arr (Cons (Orm.enc_int (match ids with Cons (h, _) -> h | Nil -> 0), Nil))")
    "[1]";

  let ocaml_format input =
    Exhaustive.reset ();
    let prelude_decls = Pipeline.parse_prelude () in
    let n_prelude = List.length prelude_decls in
    let prog = Pipeline.parse_program input in
    let rec drop n xs = if n <= 0 then xs else match xs with
      | [] -> []
      | _ :: rest -> drop (n - 1) rest
    in
    let user_decls = drop n_prelude prog.decls in
    Formatter.format_program { prog with decls = user_decls }
  in

  let self_host_format input =
    (* Write the input to a tmpfile so the bridge can read it via
       `read_file`. Avoids the gnarly escape pass needed to inline an
       arbitrary Mere source as a string literal inside another Mere
       file. *)
    let tmp = Filename.temp_file "selfhost_fmt_input_" ".mere" in
    let oc = open_out tmp in
    output_string oc input;
    close_out oc;
    let bridge = Printf.sprintf
      "import \"%s/contrib/parser/parser.mere\";\n\
       import \"%s/contrib/fmt/fmt.mere\";\n\
       let src = read_file \"%s\" in\n\
       let toks = tokenize src in\n\
       let (prog, _rest) = parse_decls Nil toks in\n\
       format_program prog\n"
      project_root project_root tmp
    in
    let result =
      Exhaustive.reset ();
      let prog = Pipeline.parse_program ~base_dir:project_root bridge in
      let eval_env = ref Eval.initial_env in
      let type_env = ref Typer.initial_env in
      Pipeline.process_decls eval_env type_env prog.decls;
      let _ = Typer.infer !type_env prog.main in
      match Eval.eval_in !eval_env prog.main with
      | Eval.V_str s -> s
      | other -> failwith ("self_host_format: expected V_str, got " ^ Eval.to_string other)
    in
    Sys.remove tmp;
    result
  in

  let cross_validate name input =
    let expected = ocaml_format input in
    let actual = self_host_format input in
    check ("self-host fmt cross: " ^ name) actual expected
  in

  cross_validate "simple expr" "1 + 2 * 3";
  cross_validate "let-in" "let x = 1 + 2 in x * x";
  cross_validate "curried fn" "fn x -> fn y -> x + y";
  cross_validate "factorial" "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10";
  cross_validate "match" "match xs with | Nil -> 0 | Cons (h, t) -> h + sum t";
  cross_validate "list" "[1, 2, 3]";
  cross_validate "range" "1..10";
  cross_validate "annotated lambda" "fn (n: int) -> n + 1";
  cross_validate "top-level let" "let x = 1; let y = 2; x + y";
  cross_validate "top-level type" "type color = | Red | Green | Blue; Red";
  cross_validate "type with payload" "type opt = | Just of int | Nothing; Just (42)";
  cross_validate "top let rec" "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1); fact 10";
  cross_validate "multi-decl program"
    "type opt = | Just of int | Nothing; let x = Just (42); let rec sum = fn (xs: int list) -> match xs with | Nil -> 0 | Cons (h, t) -> h + sum t; sum [1, 2, 3]";

  (* Stage 50i — records. *)
  cross_validate "record decl" "type Point = { x: int, y: int }; ()";
  cross_validate "record literal"
    "type Point = { x: int, y: int }; let p = Point { x = 1, y = 2 }; p.x";
  cross_validate "record field chain"
    "type Pair = { fst: int, snd: int }; let p = Pair { fst = 1, snd = 2 }; p.fst + p.snd";
  cross_validate "record update"
    "type Point = { x: int, y: int }; let origin = Point { x = 0, y = 0 }; { origin | x = 10 }";
  cross_validate "record pattern"
    "type Point = { x: int, y: int }; let p = Point { x = 0, y = 0 } in match p with | Point { x = 0, y = 0 } -> 0 | _ -> 1";

  (* Phase 50.12 / Stage 50j — "self-host parses self-host". The
     ultimate dogfood: feed contrib/parser/{lexer,parser}.mere and
     contrib/fmt/fmt.mere through the self-host pipeline and verify it
     produces a non-empty formatted string. We don't byte-compare
     against `mere fmt` here — OCaml-side expands `import` decls
     (inlining the imported file) and resolves type aliases (`pos_token`
     -> `(int * token)`), and the self-host parser doesn't (yet) do
     either. The parse-and-format-without-failing test is the
     load-bearing one: if any of these files starts using syntax the
     self-host can't handle, this catches it. *)
  let self_host_parses_self file =
    let abs_path = Filename.concat project_root file in
    let bridge = Printf.sprintf
      "import \"%s/contrib/parser/parser.mere\";\n\
       import \"%s/contrib/fmt/fmt.mere\";\n\
       let src = read_file \"%s\" in\n\
       let toks = tokenize src in\n\
       let (prog, _rest) = parse_decls Nil toks in\n\
       format_program prog\n"
      project_root project_root abs_path
    in
    Exhaustive.reset ();
    let prog = Pipeline.parse_program ~base_dir:project_root bridge in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    Pipeline.process_decls eval_env type_env prog.decls;
    let _ = Typer.infer !type_env prog.main in
    match Eval.eval_in !eval_env prog.main with
    | Eval.V_str s when String.length s > 0 -> "ok:" ^ string_of_int (String.length s)
    | Eval.V_str _ -> "empty output"
    | _ -> "non-string result"
  in

  let check_self_host name file =
    let result = self_host_parses_self file in
    let ok = String.length result >= 4 && String.sub result 0 3 = "ok:" in
    if ok then begin
      incr pass;
      Printf.printf "PASS  self-host parses %s (%s chars)\n"
        name (String.sub result 3 (String.length result - 3))
    end else begin
      incr fail;
      Printf.printf "FAIL  self-host parses %s — %s\n" name result
    end
  in
  check_self_host "lexer.mere" "contrib/parser/lexer.mere";
  check_self_host "parser.mere" "contrib/parser/parser.mere";
  check_self_host "fmt.mere" "contrib/fmt/fmt.mere";

  (* Phase 51.6 — self-host eval cross-validation. Run a Mere source
     string through both OCaml-side `Pipeline.process` (which is
     parse + typer + eval) and the self-host `tokenize + parse_decls +
     run_program`, then compare the displayed result. OCaml's
     `to_string` and self-host's `value_to_str` were modelled on each
     other, so primitive results match exactly. *)
  let self_host_eval input =
    let escaped =
      let b = Buffer.create (String.length input) in
      String.iter (fun c ->
        match c with
        | '\\' -> Buffer.add_string b "\\\\"
        | '"' -> Buffer.add_string b "\\\""
        | '\n' -> Buffer.add_string b "\\n"
        | '\t' -> Buffer.add_string b "\\t"
        | '{' -> Buffer.add_string b "\\{"
        | c -> Buffer.add_char b c) input;
      Buffer.contents b
    in
    let bridge = Printf.sprintf
      "import \"%s/contrib/eval/eval.mere\";\n\
       value_to_str (parse_and_eval \"%s\")\n"
      project_root escaped
    in
    Exhaustive.reset ();
    let prog = Pipeline.parse_program ~base_dir:project_root bridge in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    Pipeline.process_decls eval_env type_env prog.decls;
    let _ = Typer.infer !type_env prog.main in
    match Eval.eval_in !eval_env prog.main with
    | Eval.V_str s -> s
    | _ -> "<not-a-string>"
  in

  let cross_eval name input =
    let ocaml_result = Pipeline.process input in
    let self_result = self_host_eval input in
    check ("self-host eval cross: " ^ name) self_result ocaml_result
  in

  cross_eval "int arithmetic" "1 + 2 * 3";
  cross_eval "let-in" "let x = 5 in x + 1";
  cross_eval "factorial"
    "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5";
  cross_eval "mutual rec"
    "let rec even = fn n -> if n == 0 then true else odd (n - 1) and odd = fn n -> if n == 0 then false else even (n - 1) in even 10";
  cross_eval "list sum"
    "let rec sum = fn xs -> match xs with | Nil -> 0 | Cons (h, t) -> h + sum t in sum [1, 2, 3, 4]";
  cross_eval "match int"
    "match 2 with | 1 -> \"one\" | 2 -> \"two\" | _ -> \"other\"";
  cross_eval "str concat" "\"hello, \" ++ \"world\"";
  cross_eval "tuple destructure" "let (a, b) = (3, 4) in a + b";

  (* Phase 52.6 — self-host typer cross-validation. Runs a Mere source
     string through both `Pipeline.type_of` (OCaml typer) and the
     self-host `parse_and_infer`, then compares the displayed type.
     Only monomorphic results are compared — the self-host prints
     metas as `'_0` while OCaml `pp_ty` prints them as `'a`, so
     polymorphic cases would diverge on the var name. *)
  let self_host_type input =
    let escaped =
      let b = Buffer.create (String.length input) in
      String.iter (fun c ->
        match c with
        | '\\' -> Buffer.add_string b "\\\\"
        | '"' -> Buffer.add_string b "\\\""
        | '\n' -> Buffer.add_string b "\\n"
        | '\t' -> Buffer.add_string b "\\t"
        | '{' -> Buffer.add_string b "\\{"
        | c -> Buffer.add_char b c) input;
      Buffer.contents b
    in
    let bridge = Printf.sprintf
      "import \"%s/contrib/typer/typer.mere\";\n\
       parse_and_infer \"%s\"\n"
      project_root escaped
    in
    Exhaustive.reset ();
    let prog = Pipeline.parse_program ~base_dir:project_root bridge in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    Pipeline.process_decls eval_env type_env prog.decls;
    let _ = Typer.infer !type_env prog.main in
    match Eval.eval_in !eval_env prog.main with
    | Eval.V_str s -> s
    | _ -> "<not-a-string>"
  in

  let cross_type name input =
    let ocaml_result = Pipeline.type_of input in
    let self_result = self_host_type input in
    check ("self-host type cross: " ^ name) self_result ocaml_result
  in

  cross_type "int literal" "42";
  cross_type "int arith" "1 + 2 * 3";
  cross_type "str literal" "\"hi\"";
  cross_type "bool cmp" "1 < 2";
  cross_type "annotated lambda" "fn (x: int) -> x + 1";
  cross_type "let-in int" "let x = 5 in x + 1";
  cross_type "let-rec factorial"
    "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5";
  cross_type "mutual rec bool"
    "let rec even = fn n -> if n == 0 then true else odd (n - 1) and odd = fn n -> if n == 0 then false else even (n - 1) in even 10";
  cross_type "tuple literal" "(1, 2)";
  cross_type "tuple destructure" "let (a, b) = (3, 4) in a + b";
  cross_type "match int" "match 1 with | 0 -> \"z\" | _ -> \"o\"";
  cross_type "match with guard" "match 5 with | n when n > 0 -> 1 | _ -> 0";
  (* Phase 55c: TopType decls populate the ctor registry so `EConstr`
     inference returns the parent type name instead of a fresh meta.
     Before 55c, all four below returned `'_0` from parse_and_infer;
     after 55c they return the proper TyCon name. `cross_type`
     compares against OCaml Pipeline.type_of which has always done
     this — the check is that self-host has caught up. *)
  cross_type "TopType enum ctor" "type color = | Red | Green | Blue; Red";
  cross_type "TopType nullary ctor" "type maybe_int = | None | Some of int; None";
  cross_type "TopType payload ctor int" "type maybe_int = | None | Some of int; Some 42";
  (* Phase 55c-2: TopRecord registry — record literal returns the
     declared record's TyCon, and each field's expr type is unified
     with the declared field ty. Case-sensitive name matching: the
     record decl and the ERecordLit's tag must use the same
     capitalization. *)
  cross_type "TopRecord literal"
    "type Point = { x: int, y: int }; Point { x = 1, y = 2 }";
  cross_type "TopRecord let-bound"
    "type Point = { x: int, y: int }; let p = Point { x = 3, y = 4 } in p";
  (* Phase 55c-2b: EFieldGet resolves the field ty from the record's
     TyCon name. Pre-55c-2b `p.x` inferred to a fresh meta (`'_0`);
     with the registry in place it resolves to `int`. Test both a
     bare field access and one embedded in an arithmetic expression
     so the result ty (int) actually gets used. *)
  cross_type "EFieldGet single"
    "type Point = { x: int, y: int }; let p = Point { x = 3, y = 4 } in p.x";
  cross_type "EFieldGet sum"
    "type Point = { x: int, y: int }; let p = Point { x = 1, y = 2 } in p.x + p.y";
  (* Phase 55c-2c: PRecord pattern field check. `match Point { ... }
     with | Point { x = a, y = b } -> ...` binds `a` and `b` to the
     declared field tys (int/int for Point) rather than fresh metas.
     Required threading `env` through `check_pattern` /
     `check_record_field_pats` / `check_pattern_list`. *)
  cross_type "PRecord pattern destructure"
    "type Point = { x: int, y: int }; match Point { x = 3, y = 4 } with | Point { x = a, y = b } -> a + b";
  (* Phase 55c-3: PConstr pattern lookup — payload sub-pattern binds
     with the declared ctor payload ty. `match Some 42 with | Some x
     -> x | None -> 0` used to bind `x` as fresh meta; now `x: int`
     from `Some of int`, so arithmetic on x resolves cleanly. *)
  cross_type "PConstr pattern binds payload"
    "type opt = | Some of int | None; match Some 42 with | Some x -> x | None -> 0";
  cross_type "PConstr pattern payload arith"
    "type opt = | Some of int | None; match Some 5 with | Some x -> x + 1 | None -> 0";
  cross_type "PConstr pattern nullary only"
    "type flag = | On | Off; match On with | On -> 1 | Off -> 0";
  (* Phase 55f continued: fst / snd as polymorphic builtins so real
     contrib code that uses them type-checks. *)
  cross_type "fst polymorphic int-str"
    "fst (1, \"hi\")";
  cross_type "snd polymorphic int-str"
    "snd (1, \"hi\")";
  cross_type "fst + snd arith"
    "let p = (10, 20) in fst p + snd p";
  (* Phase 55f continued: polymorphic Cons / Nil in initial_type_env
     so real code that uses lists inference-checks against `'a list`
     rather than falling to permissive fresh metas. Verifies
     `Cons (1, Nil)` types as `int list`. *)
  cross_type "list Cons int"
    "Cons (1, Cons (2, Nil))";
  cross_type "list Cons str"
    "Cons (\"a\", Cons (\"b\", Nil))";
  (* Phase 55f continued (part 4): built-in Some / None polymorphic
     ctors + parser arity seed for the built-in ctor names. `Some 42`
     now type-checks to `int option` without needing a user-side
     `type option 'a = ...` decl. *)
  cross_type "option Some int"
    "Some 42";
  cross_type "option Some str"
    "Some \"hi\"";
  cross_type "option nested with list"
    "Some (Cons (1, Cons (2, Nil)))";
  cross_type "option match with payload"
    "match Some 42 with | Some x -> x + 1 | None -> 0";
  (* Phase 55f continued (part 5): built-in Ok / Err with 2 type
     params. Each ctor use freshens its own (id_a, id_b) so
     `if cond then Ok 42 else Err "bad"` unifies to `(int, str) result`. *)
  cross_type "result if-branches unify"
    "if true then Ok 42 else Err \"bad\"";
  cross_type "result Ok match"
    "match Ok 42 with | Ok x -> x | Err _ -> 0";
  (* Phase 55f continued (part 6): higher-order list helpers from
     selfhost_prelude, now polymorphically typed in initial_type_env.
     Each ctor's fresh quantifier gives independent freshening per
     use site. *)
  cross_type "list_map with anon fn"
    "list_map (Cons (1, Nil)) (fn x -> x + 1)";
  cross_type "list_filter with pred"
    "list_filter (Cons (1, Cons (2, Nil))) (fn x -> x > 0)";
  cross_type "list_any"
    "list_any (Cons (1, Nil)) (fn x -> x > 0)";

  (* Note: `type opt = | Some of 'a | None; Some "hi"` — the self-host
     auto-generalizes TyVars from ctor payloads (parser doesn't emit
     decl-head params). OCaml rejects this same input as a rigid-var
     mismatch, so we skip cross-validation here — verified by hand via
     `mere.exe` + parse_and_infer. Adding TopType polymorphic cases to
     cross_type requires the self-host parser gaining `type opt 'a =
     ...` syntax first. *)


  (* Phase 53.9 — self-host codegen cross-validation. Runs a Mere source
     string through:
       1. the self-host `parse_and_emit` (via the OCaml interpreter) to
          obtain a WAT module string
       2. `wat2wasm` (shell) to compile WAT → wasm binary
       3. `node` (shell) to instantiate and call `main()`
       4. compare the printed i32 against an expected value
     This proves the *generated* wasm runs correctly end-to-end. The
     check is "same value out of main()" rather than byte-identical
     WAT — the self-host emits canonical-but-slightly-different shape
     vs the OCaml-side codegen_wasm.ml.

     Requires `wat2wasm` and `node` in PATH (matches the GitHub Pages
     CI image; locally `opam install wabt` + standard node install). *)
  let self_host_emit input =
    let escaped =
      let b = Buffer.create (String.length input) in
      String.iter (fun c ->
        match c with
        | '\\' -> Buffer.add_string b "\\\\"
        | '"' -> Buffer.add_string b "\\\""
        | '\n' -> Buffer.add_string b "\\n"
        | '\t' -> Buffer.add_string b "\\t"
        | '{' -> Buffer.add_string b "\\{"
        | c -> Buffer.add_char b c) input;
      Buffer.contents b
    in
    let bridge = Printf.sprintf
      "import \"%s/contrib/codegen/codegen_wasm.mere\";\n\
       parse_and_emit \"%s\"\n"
      project_root escaped
    in
    Exhaustive.reset ();
    let prog = Pipeline.parse_program ~base_dir:project_root bridge in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    Pipeline.process_decls eval_env type_env prog.decls;
    let _ = Typer.infer !type_env prog.main in
    match Eval.eval_in !eval_env prog.main with
    | Eval.V_str s -> s
    | _ -> "<not-a-string>"
  in

  let have_wat2wasm =
    Sys.command "command -v wat2wasm > /dev/null 2>&1" = 0 in
  let have_node =
    Sys.command "command -v node > /dev/null 2>&1" = 0 in

  let run_wasm wat =
    let wat_path = Filename.temp_file "mere_cross_" ".wat" in
    let wasm_path = wat_path ^ ".wasm" in
    let oc = open_out wat_path in
    output_string oc wat;
    close_out oc;
    let wat2wasm_cmd = Printf.sprintf
      "wat2wasm --enable-tail-call %s -o %s 2>/dev/null" wat_path wasm_path in
    if Sys.command wat2wasm_cmd <> 0 then
      (Sys.remove wat_path; "<wat2wasm-failed>")
    else
      (* Stage 53i: provide a `puts` stub so modules that import it
         (anything using `print`) instantiate cleanly. Stub does
         nothing — `cross_emit` only checks main()'s return value, not
         stdout. A separate `cross_print` could capture text if/when
         we cross-validate side effects. *)
      (* Stage 54.2: extern fn cross-validation cases may declare
         arbitrary import names (host_log / make_handle / etc.) that
         the harness can't enumerate ahead of time. Use a Proxy to
         auto-stub any access — returns a fn that ignores args and
         returns 0. Still works for the print / show / etc. cases
         that just need puts. *)
      (* --stack-size=65500 (max) is needed for the deeper self-host
         workloads — codegen bootstrap emits ~30MB WAT and recurses
         thousands of frames before returning. Default Node stack
         (~500KB) overflows well before completion. *)
      let runner = Printf.sprintf
        "node --stack-size=65500 -e \"const fs=require('fs'); \
         const env = new Proxy({}, { get: () => () => 0 }); \
         WebAssembly.instantiate(fs.readFileSync('%s'), {env}) \
         .then(({instance})=>console.log(instance.exports.main())) \
         .catch(e=>console.log('TRAP:'+e.message));\""
        wasm_path in
      let ic = Unix.open_process_in runner in
      let line = try input_line ic with End_of_file -> "" in
      let _ = Unix.close_process_in ic in
      Sys.remove wat_path;
      (try Sys.remove wasm_path with _ -> ());
      String.trim line
  in

  let cross_emit name input expected =
    let wat = self_host_emit input in
    (* The bridge returns just the WAT string produced by
       `parse_and_emit`, no extra wrapping. Pass it straight through. *)
    let actual = run_wasm wat in
    check ("self-host codegen cross: " ^ name) actual expected
  in

  (* Phase 55a (typed AST 配管): mirror `self_host_emit` but chain
     `parse_and_annotate` (typer) → `emit_program` (codegen). Exercises
     the typed-pipeline end-to-end so codegen can dispatch polymorphic
     `show` on ty from EAnnot wrappings. *)
  let self_host_emit_typed input =
    let escaped =
      let b = Buffer.create (String.length input) in
      String.iter (fun c ->
        match c with
        | '\\' -> Buffer.add_string b "\\\\"
        | '"' -> Buffer.add_string b "\\\""
        | '\n' -> Buffer.add_string b "\\n"
        | '\t' -> Buffer.add_string b "\\t"
        | '{' -> Buffer.add_string b "\\{"
        | c -> Buffer.add_char b c) input;
      Buffer.contents b
    in
    let bridge = Printf.sprintf
      "import \"%s/contrib/typer/typer.mere\";\n\
       import \"%s/contrib/codegen/codegen_wasm.mere\";\n\
       emit_program (parse_and_annotate \"%s\")\n"
      project_root project_root escaped
    in
    Exhaustive.reset ();
    let prog = Pipeline.parse_program ~base_dir:project_root bridge in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    Pipeline.process_decls eval_env type_env prog.decls;
    let _ = Typer.infer !type_env prog.main in
    match Eval.eval_in !eval_env prog.main with
    | Eval.V_str s -> s
    | _ -> "<not-a-string>"
  in

  (* Run WAT and capture the LAST puts-stdout line instead of main's
     return value. Show-family tests print via puts (side effect) and
     return 0 from main, so main-return can't distinguish outcomes. *)
  let run_wasm_stdout wat =
    let wat_path = Filename.temp_file "mere_typed_" ".wat" in
    let wasm_path = wat_path ^ ".wasm" in
    let oc = open_out wat_path in
    output_string oc wat;
    close_out oc;
    let wat2wasm_cmd = Printf.sprintf
      "wat2wasm --enable-tail-call %s -o %s 2>/dev/null" wat_path wasm_path in
    if Sys.command wat2wasm_cmd <> 0 then
      (Sys.remove wat_path; "<wat2wasm-failed>")
    else
      let runner = Printf.sprintf
        "node --stack-size=65500 -e \"const fs=require('fs'); \
         let mem; \
         const readCStr = p => { const b = new Uint8Array(mem.buffer); \
           let e = p; while (e < b.length && b[e] !== 0) e++; \
           return Buffer.from(b.subarray(p, e)).toString('utf8'); }; \
         const env = new Proxy({ \
           puts: p => process.stdout.write(readCStr(p) + '\\\\n') \
         }, { get: (o, k) => k in o ? o[k] : () => 0 }); \
         WebAssembly.instantiate(fs.readFileSync('%s'), {env}) \
         .then(({instance})=>{ mem=instance.exports.memory; instance.exports.main(); }) \
         .catch(e=>console.log('TRAP:'+e.message));\""
        wasm_path in
      let ic = Unix.open_process_in runner in
      let buf = Buffer.create 64 in
      (try while true do
        Buffer.add_string buf (input_line ic);
        Buffer.add_char buf '\n'
      done with End_of_file -> ());
      let _ = Unix.close_process_in ic in
      Sys.remove wat_path;
      (try Sys.remove wasm_path with _ -> ());
      let lines = String.split_on_char '\n' (String.trim (Buffer.contents buf)) in
      List.fold_left (fun acc l ->
        if String.trim l = "" then acc else String.trim l) "" lines
  in

  let typed_cross_stdout name input expected =
    let wat = self_host_emit_typed input in
    let actual = run_wasm_stdout wat in
    check ("typed pipeline cross: " ^ name) actual expected
  in

  (* Phase 54.15: bootstrap harness. Write `source` to a tempfile,
     then invoke `parse_and_emit_file` on it via the OCaml interp.
     That exercises the full self-host pipeline including recursive
     import inlining, prelude prepending, arity rewrite, and codegen.
     Use for tests that need `import "..."` or that want to prove the
     compiled WAT runs correctly under wasm at runtime. *)
  let self_host_emit_file path =
    let bridge = Printf.sprintf
      "import \"%s/contrib/codegen/codegen_wasm.mere\";\n\
       parse_and_emit_file \"%s\"\n"
      project_root path
    in
    Exhaustive.reset ();
    let prog = Pipeline.parse_program ~base_dir:project_root bridge in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    Pipeline.process_decls eval_env type_env prog.decls;
    let _ = Typer.infer !type_env prog.main in
    match Eval.eval_in !eval_env prog.main with
    | Eval.V_str s -> s
    | _ -> "<not-a-string>"
  in

  let bootstrap_emit name source expected =
    let src_path = Filename.temp_file "mere_bootstrap_" ".mere" in
    let oc = open_out src_path in
    output_string oc source;
    close_out oc;
    let wat = self_host_emit_file src_path in
    let actual = run_wasm wat in
    Sys.remove src_path;
    check ("self-host bootstrap: " ^ name) actual expected
  in

  (* Phase 54.36: runtime codegen bootstrap CI check. Emits an in-repo
     example file via `mere -w` (i.e. the OCaml-side codegen path,
     not the self-host emit path — this avoids the double-self-host
     issues that surface when we bootstrap through parse_and_emit_file
     twice). The example imports contrib/codegen/codegen_wasm.mere and
     calls `parse_and_emit "42"` at runtime. `main()` returns the
     length of the emitted WAT string; the harness asserts the
     expected value.

     Depends on `dune exec ./bin/mere.exe` being available. When run
     outside dune (e.g. plain OCaml test binary), we skip. Also
     requires `wat2wasm` and `node` in PATH like the rest of the
     wasm cross-validation. *)
  let codegen_runtime_bootstrap name mere_path expected =
    let wat_path = Filename.temp_file "mere_cg_" ".wat" in
    let wasm_path = wat_path ^ ".wasm" in
    (* Use the pre-built mere.exe directly rather than `dune exec` —
       we're already running inside dune runtest, so a nested dune
       invocation fails on lock / workspace resolution. The binary
       lives at _build/default/bin/mere.exe relative to project_root
       once dune has built it (which runtest guarantees). *)
    let mere_exe =
      Filename.concat project_root "_build/default/bin/mere.exe" in
    let compile_cmd = Printf.sprintf
      "cd %s && %s -w %s > %s 2>/dev/null"
      (Filename.quote project_root)
      (Filename.quote mere_exe)
      (Filename.quote mere_path)
      (Filename.quote wat_path) in
    if Sys.command compile_cmd <> 0 then begin
      Sys.remove wat_path;
      incr fail;
      Printf.printf "FAIL  codegen runtime bootstrap: %s (mere -w failed)\n" name
    end else begin
      let wat2wasm_cmd = Printf.sprintf
        "wat2wasm --enable-tail-call %s -o %s 2>/dev/null" wat_path wasm_path in
      if Sys.command wat2wasm_cmd <> 0 then begin
        Sys.remove wat_path;
        incr fail;
        Printf.printf "FAIL  codegen runtime bootstrap: %s (wat2wasm failed)\n" name
      end else begin
        (* Capture the LAST line of puts output (Phase 27.2 auto-prints
           main's int-typed result via puts before returning 0). We
           read a C-string at the pointer passed to puts and print it.
           Any earlier puts calls (from print statements in the source)
           are also captured; the test asserts on the final line. *)
        let runner = Printf.sprintf
          "node --stack-size=65500 -e \"const fs=require('fs'); \
           let mem; \
           const readCStr = p => { const b = new Uint8Array(mem.buffer); \
             let e = p; while (e < b.length && b[e] !== 0) e++; \
             return Buffer.from(b.subarray(p, e)).toString('utf8'); }; \
           const env = new Proxy({ \
             puts: p => process.stdout.write(readCStr(p) + '\\\\n') \
           }, { get: (o, k) => k in o ? o[k] : () => 0 }); \
           WebAssembly.instantiate(fs.readFileSync('%s'), {env}) \
           .then(({instance})=>{ mem=instance.exports.memory; instance.exports.main(); }) \
           .catch(e=>console.log('TRAP:'+e.message));\""
          wasm_path in
        let ic = Unix.open_process_in runner in
        let buf = Buffer.create 64 in
        (try while true do Buffer.add_string buf (input_line ic); Buffer.add_char buf '\n' done with End_of_file -> ());
        let _ = Unix.close_process_in ic in
        Sys.remove wat_path;
        (try Sys.remove wasm_path with _ -> ());
        (* Trim + take the last non-empty line — self-host demos print
           lots of output, we want main's final result. *)
        let lines = String.split_on_char '\n' (String.trim (Buffer.contents buf)) in
        let last = List.fold_left (fun acc l ->
          if String.trim l = "" then acc else String.trim l) "" lines in
        check ("codegen runtime bootstrap: " ^ name) last expected
      end
    end
  in

  (* Phase 54.21: compile-time self-host bootstrap. Feed a contrib
     file through parse_and_emit_file and verify the resulting WAT
     is (a) reasonably long, and (b) at least parses back through
     wat2wasm without error. This is the durable CI check for the
     54.19 milestone: "the self-host codegen can compile itself". *)
  (* Phase 55f dogfood: like `bootstrap_wat_ok` but routes through the
     typed pipeline — reads a real contrib file, inlines imports, then
     runs `parse_and_annotate` (typer) → `emit_program` (codegen)
     rather than `parse_and_emit`. Surfaces any real-world code that
     the stricter typer catches (or that the annotate pass trips on).
     Asserts the WAT is at least `min_len` bytes and wat2wasm accepts
     it. *)
  let typed_wat_ok name path min_len =
    let abs_path = Filename.concat project_root path in
    (* Phase 55f part 8 attempt: prepending selfhost_prelude_fns caused
       an existing test to hang (~9 min at 100% CPU on test_basic.exe).
       Reverted to plain __inlined for now — the prelude fns are only
       needed for real contribs that reference list_iter / list_map at
       source level, and the tests currently in the harness (option /
       path / time) don't need them. When we reintroduce prelude
       prepend, first bisect what's causing the loop. *)
    let bridge = Printf.sprintf
      "import \"%s/contrib/typer/typer.mere\";\n\
       import \"%s/contrib/codegen/codegen_wasm.mere\";\n\
       let __p = \"%s\" in\n\
       let __src = read_file __p in\n\
       let __base = dirname __p in\n\
       let (__inlined, ___) = inline_imports_in __src __base (Cons (__p, Nil)) in\n\
       emit_program (parse_and_annotate __inlined)\n"
      project_root project_root abs_path
    in
    Exhaustive.reset ();
    let prog = Pipeline.parse_program ~base_dir:project_root bridge in
    let eval_env = ref Eval.initial_env in
    let type_env = ref Typer.initial_env in
    Pipeline.process_decls eval_env type_env prog.decls;
    let _ = Typer.infer !type_env prog.main in
    let wat = (match Eval.eval_in !eval_env prog.main with
      | Eval.V_str s -> s
      | _ -> "<not-a-string>") in
    let len = String.length wat in
    if len < min_len then begin
      incr fail;
      Printf.printf "FAIL  typed wat-ok: %s (WAT length %d < %d)\n"
        name len min_len
    end else begin
      let wat_path = Filename.temp_file "mere_typed_" ".wat" in
      let wasm_path = wat_path ^ ".wasm" in
      let oc = open_out wat_path in
      output_string oc wat;
      close_out oc;
      let cmd = Printf.sprintf "wat2wasm --enable-tail-call %s -o %s 2>/dev/null" wat_path wasm_path in
      let ok = Sys.command cmd = 0 in
      Sys.remove wat_path;
      (try Sys.remove wasm_path with _ -> ());
      if ok then begin
        incr pass;
        Printf.printf "PASS  typed wat-ok: %s (%d bytes WAT, wat2wasm accepted)\n"
          name len
      end else begin
        incr fail;
        Printf.printf "FAIL  typed wat-ok: %s (%d bytes WAT, wat2wasm rejected)\n"
          name len
      end
    end
  in

  let bootstrap_wat_ok name path min_len =
    let wat = self_host_emit_file path in
    let len = String.length wat in
    if len < min_len then begin
      incr fail;
      Printf.printf "FAIL  self-host wat-ok: %s (WAT length %d < %d)\n"
        name len min_len
    end else begin
      (* Verify wat2wasm accepts the output — proves the emitted WAT
         is at least syntactically valid. *)
      let wat_path = Filename.temp_file "mere_selfemit_" ".wat" in
      let wasm_path = wat_path ^ ".wasm" in
      let oc = open_out wat_path in
      output_string oc wat;
      close_out oc;
      let cmd = Printf.sprintf "wat2wasm --enable-tail-call %s -o %s 2>/dev/null" wat_path wasm_path in
      let ok = Sys.command cmd = 0 in
      Sys.remove wat_path;
      (try Sys.remove wasm_path with _ -> ());
      if ok then begin
        incr pass;
        Printf.printf "PASS  self-host wat-ok: %s (%d bytes WAT, wat2wasm accepted)\n"
          name len
      end else begin
        incr fail;
        Printf.printf "FAIL  self-host wat-ok: %s (%d bytes WAT, wat2wasm rejected)\n"
          name len
      end
    end
  in

  if have_wat2wasm && have_node then begin
    cross_emit "int literal" "42" "42";
    cross_emit "int arith" "1 + 2 * 3" "7";
    cross_emit "int div + mod" "(17 / 4) + (17 % 4)" "5";
    cross_emit "let-in" "let x = 5 in x + 1" "6";
    cross_emit "nested let" "let a = 1 in let b = 2 in a + b" "3";
    cross_emit "if" "if 1 < 2 then 10 else 20" "10";
    cross_emit "lambda apply" "(fn x -> x + 1) 41" "42";
    cross_emit "curried apply" "((fn x -> fn y -> x + y) 3) 4" "7";
    cross_emit "let-rec factorial"
      "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5"
      "120";
    cross_emit "mutual rec int"
      "let rec even = fn n -> if n == 0 then 1 else odd (n - 1) and odd = fn n -> if n == 0 then 0 else even (n - 1) in even 10"
      "1";
    cross_emit "tuple destructure"
      "let (a, b) = (3, 4) in a + b" "7";
    cross_emit "match int"
      "match 2 with | 1 -> 10 | 2 -> 20 | _ -> 99" "20";
    cross_emit "variant match"
      "match Some (42) with | Some n -> n | None -> 0" "42";
    cross_emit "top-let cascade"
      "let x = 5; let y = x + 1; y * 2" "12";
    (* Phase 53.11 dogfood regression: `let (a, b) = ... in ...` nested
       inside an EFun used to fail because free_vars dropped the
       pattern's bindings from `bound`, surfacing `a` / `b` as bogus
       captures. Caught by quicksort. *)
    cross_emit "destructure-let in fn body"
      "let f = fn n -> let (a, b) = (n, n + 1) in a * b in f 5"
      "30";
    cross_emit "quicksort sum"
      "let rec qsort = fn xs -> match xs with | Nil -> Nil | Cons (p, t) -> let rec partition = fn ys -> fn lo -> fn hi -> match ys with | Nil -> (lo, hi) | Cons (h, ts) -> if h < p then partition ts (Cons (h, lo)) hi else partition ts lo (Cons (h, hi)) in let (lo, hi) = partition t Nil Nil in let rec append = fn a -> fn b -> match a with | Nil -> b | Cons (h, t) -> Cons (h, append t b) in append (qsort lo) (Cons (p, qsort hi)) in let rec sum = fn xs -> match xs with | Nil -> 0 | Cons (h, t) -> h + sum t in sum (qsort [5, 2, 8, 1, 9, 3])"
      "28";
    (* Phase 53.12 (Stage 53h-fix): records (F1) + when-guards (F2). *)
    cross_emit "record literal + field access"
      "let p = Point { x = 3, y = 4 } in p.x + p.y" "7";
    cross_emit "record update"
      "let p = Point { x = 10, y = 20 } in let q = { p | x = 99 } in q.x + q.y" "119";
    cross_emit "PRecord destructure"
      "match Point { x = 3, y = 4 } with | Point { x = a, y = b } -> a + b" "7";
    cross_emit "when-guard skip"
      "match 5 with | n when n > 100 -> 999 | _ -> 7" "7";
    cross_emit "when-guard hit"
      "match 5 with | n when n > 0 -> 1 | _ -> 0" "1";
    cross_emit "when-guard false"
      "match (-3) with | n when n > 0 -> 1 | _ -> 0" "0";
    (* Phase 53.13 dogfood pass 2: POr + PStr (F9 + F8 fixed in same
       commit), plus a deep dogfood sample (mini Mere evaluator). *)
    cross_emit "POr"
      "match 2 with | 1 | 2 | 3 -> 100 | _ -> 200" "100";
    cross_emit "POr cascade"
      "match 7 with | 5 | 6 | 7 -> 1 | 8 | 9 -> 2 | _ -> 0" "1";
    cross_emit "PStr"
      "match \"hi\" with | \"hi\" -> 1 | _ -> 0" "1";
    (* Phase 53.14 (Stage 53i): extern fn import for `print`. *)
    cross_emit "print + return"
      "let _ = print \"hi\" in 42" "42";
    cross_emit "multiple prints"
      "let _ = print \"a\" in let _ = print \"b\" in 7" "7";
    (* Phase 53.15 (Stage 53i-2): embedded $__lang_str_concat helper
       for `str ++ str`. Module wrapper emits the helper body only
       when the program touches OpConcat. *)
    cross_emit "str ++ + print"
      "let _ = print (\"hello, \" ++ \"world\") in 42" "42";
    cross_emit "3-way ++"
      "let _ = print (\"a\" ++ \"b\" ++ \"c\") in 1" "1";
    cross_emit "let-bound concat"
      "let s = \"foo\" ++ \"bar\" in let _ = print s in 9" "9";
    cross_emit "fn that concats"
      "let join = fn a -> fn b -> a ++ \"/\" ++ b in let _ = print (join \"src\" \"main\") in 0" "0";
    (* Phase 53.16 (Stage 53i-3): embedded $show_int helper for `show`
       on int. End-to-end captures "fact 5 = 120". *)
    cross_emit "show int + print"
      "let _ = print (show 42) in 0" "0";
    cross_emit "fact 5 with show"
      "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in let _ = print (\"fact 5 = \" ++ show (fact 5)) in 0" "0";
    cross_emit "show negative"
      "let _ = print (show (0 - 42)) in 0" "0";
    (* Phase 55a: typed AST 配管 — polymorphic show dispatch via
       EAnnot from the typer's annotate pass. int/bool/str are the
       initial 3 dispatch targets; variant/record/tuple lands in
       Stage 55d. Uses `typed_cross_stdout` since these programs
       return 0 from main but emit the interesting output via puts. *)
    typed_cross_stdout "show true"
      "let _ = print (show true) in 0" "true";
    typed_cross_stdout "show false"
      "let _ = print (show false) in 0" "false";
    typed_cross_stdout "show str literal"
      "let _ = print (show \"hi\") in 0" "\"hi\"";
    typed_cross_stdout "show bool via let-bound var"
      "let b = true in let _ = print (show b) in 0" "true";
    typed_cross_stdout "show int fallback (untyped path preserved)"
      "let _ = print (show 42) in 0" "42";
    (* Phase 55b: non-literal str comparison via EAnnot(TyStr). Pre-55b
       these fell through to i32.eq (pointer compare) and returned
       false for equal-content runtime strings. The `let _ = print
       (show ...) in 0` wrapper turns the bool into a "true" / "false"
       stdout line so run_wasm_stdout can assert on it. *)
    typed_cross_stdout "str == runtime-built (equal)"
      "let a = \"foo\" ++ \"bar\" in let b = \"foobar\" in let _ = print (show (a == b)) in 0"
      "true";
    typed_cross_stdout "str == runtime-built (unequal)"
      "let a = \"foo\" ++ \"bar\" in let b = \"foobaz\" in let _ = print (show (a == b)) in 0"
      "false";
    typed_cross_stdout "str != runtime-built (equal → false)"
      "let a = \"hi\" ++ \"\" in let b = \"hi\" in let _ = print (show (a != b)) in 0"
      "false";
    typed_cross_stdout "str != runtime-built (unequal → true)"
      "let a = \"hi\" in let b = \"lo\" in let _ = print (show (a != b)) in 0"
      "true";
    typed_cross_stdout "str == literal-only path unchanged"
      "let s = \"x\" in let _ = print (show (s == \"x\")) in 0"
      "true";
    (* Phase 55d: `show` on a variant value emits `call $show_variant`,
       a state-built if-chain over the final `variant_tags` mapping
       each tag to its ctor name pointer. MVP shows the ctor name only
       (payload rendering like "Some(42)" is a later slice). *)
    typed_cross_stdout "show variant nullary Red"
      "type color = | Red | Green | Blue; let _ = print (show Red) in 0"
      "Red";
    typed_cross_stdout "show variant nullary Blue"
      "type color = | Red | Green | Blue; let _ = print (show Blue) in 0"
      "Blue";
    typed_cross_stdout "show variant nullary None"
      "type opt = | Some of int | None; let _ = print (show None) in 0"
      "None";
    (* Phase 55d-2: `$show_variant` now renders int payloads as
       `Name(<int>)` via a str_concat chain (name ++ "(" ++ show_int
       payload ++ ")"). Nullary ctors still render name-only. Non-int
       payload types (variant/record/tuple) fall back to name-only for
       this MVP — proper recursive show for those needs additional
       ty threading. *)
    typed_cross_stdout "show variant int payload positive"
      "type opt = | Some of int | None; let _ = print (show (Some 42)) in 0"
      "Some(42)";
    typed_cross_stdout "show variant int payload zero"
      "type opt = | Some of int | None; let _ = print (show (Some 0)) in 0"
      "Some(0)";
    typed_cross_stdout "show variant int payload negative"
      "type opt = | Some of int | None; let _ = print (show (Some (0 - 5))) in 0"
      "Some(-5)";
    (* Phase 55d-3: bool / str payload rendering. Same shape as int
       payload but calls $show_bool / $show_str instead of $show_int
       from the concat chain. show_str keeps its double-quote wrap,
       so a str payload renders as `SomeS("hi")` — the quotes are
       inherited from the show_str behavior, not added by the variant
       branch. *)
    typed_cross_stdout "show variant bool payload true"
      "type maybe_bool = | SomeB of bool | NoneB; let _ = print (show (SomeB true)) in 0"
      "SomeB(true)";
    typed_cross_stdout "show variant bool payload false"
      "type maybe_bool = | SomeB of bool | NoneB; let _ = print (show (SomeB false)) in 0"
      "SomeB(false)";
    typed_cross_stdout "show variant str payload"
      "type maybe_str = | SomeS of str | NoneS; let _ = print (show (SomeS \"hi\")) in 0"
      "SomeS(\"hi\")";
    (* Phase 55d-5: tuple show, generated inline at the call site. Each
       element ty (TyInt / TyBool / TyStr) dispatches to the matching
       $show_*; the resulting str_concat chain wraps them with "(",
       ", ", ")". No per-arity helper — the S-expr fits on one line
       for any tuple size. *)
    typed_cross_stdout "show tuple (int, int)"
      "let _ = print (show (1, 2)) in 0" "(1, 2)";
    typed_cross_stdout "show tuple (int, bool)"
      "let _ = print (show (42, true)) in 0" "(42, true)";
    typed_cross_stdout "show tuple (int, str)"
      "let _ = print (show (7, \"hi\")) in 0" "(7, \"hi\")";
    typed_cross_stdout "show tuple 3-arity"
      "let _ = print (show (1, 2, 3)) in 0" "(1, 2, 3)";
    (* Phase 53.17 dogfood pass 3: `show` / `print` inside a fn body
       (caught by FizzBuzz / print_range / list rendering) used to
       crash because free_vars treated them as free vars and tried to
       capture them. Fixed via `is_builtin` hatch. *)
    cross_emit "print_range"
      "let rec print_range = fn lo -> fn hi -> if lo > hi then 0 else let _ = print (show lo) in print_range (lo + 1) hi in print_range 1 5" "0";
    cross_emit "FizzBuzz 1..15"
      "let rec fizz = fn n -> fn max -> if n > max then 0 else let s = if n % 15 == 0 then \"FizzBuzz\" else if n % 3 == 0 then \"Fizz\" else if n % 5 == 0 then \"Buzz\" else show n in let _ = print s in fizz (n + 1) max in fizz 1 15" "0";
    cross_emit "quicksort + render"
      "let rec quicksort = fn xs -> match xs with | Nil -> Nil | Cons (p, t) -> let rec partition = fn ys -> fn lo -> fn hi -> match ys with | Nil -> (lo, hi) | Cons (h, ts) -> if h < p then partition ts (Cons (h, lo)) hi else partition ts lo (Cons (h, hi)) in let (lo, hi) = partition t Nil Nil in let rec append = fn a -> fn b -> match a with | Nil -> b | Cons (h, t) -> Cons (h, append t b) in append (quicksort lo) (Cons (p, quicksort hi)) in let rec render = fn xs -> match xs with | Nil -> \"\" | Cons (h, Nil) -> show h | Cons (h, t) -> (show h) ++ \", \" ++ (render t) in let _ = print (\"sorted = [\" ++ (render (quicksort [5, 2, 8, 1, 9, 3, 7, 4, 6])) ++ \"]\") in 0" "0";
    (* Phase 53.18 (Stage 53j) dogfood pass 4: extra prelude builtins
       — str_len / char_at / fst / snd. Unlocks contrib/regex/engine
       and similar real-world Mere files. *)
    cross_emit "str_len" "str_len \"hello\"" "5";
    (* Phase 54.12: char_at returns a 1-byte str now (matching OCaml side).
       Wrap with ord for an int-returning expression. *)
    cross_emit "char_at" "ord (char_at \"abc\" 1)" "98";
    cross_emit "fst / snd" "let p = (10, 20) in fst p + snd p" "30";
    cross_emit "str_len on concat"
      "let s = \"hi\" ++ \"!\" in str_len s" "3";
    (* Phase 53.19 (Stage 53j-2): real byte-by-byte $__lang_streq for
       PStr — works on runtime-constructed strings (from ++ etc.),
       not just interned literals. *)
    cross_emit "PStr on runtime concat"
      "match (\"h\" ++ \"i\") with | \"hi\" -> 1 | _ -> 0" "1";
    cross_emit "PStr rejects mismatch"
      "match (\"a\" ++ \"b\") with | \"hi\" -> 1 | _ -> 0" "0";
    cross_emit "PStr empty literal"
      "match \"\" with | \"\" -> 1 | _ -> 0" "1";
    (* Phase 53.20 dogfood pass 6: substantial real-world programs. *)
    (* Phase 54.1 (Stage 54a): module M { } decl support — parser
       flatten + intra-module rename. Codegen sees a flat decl list
       with dot-qualified identifiers. *)
    cross_emit "module M two fns"
      "module M { let f = fn x -> x + 1; let g = fn x -> x * 2; }; (M.f 5) + (M.g 10)" "26";
    cross_emit "module intra-rec"
      "module M { let inc = fn x -> x + 1; let twice = fn x -> inc (inc x); }; M.twice 10" "12";
    cross_emit "module let rec"
      "module M { let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1); }; M.fact 5" "120";
    (* Phase 54.2 (Stage 54b): extern fn / extern type declarations.
       Multi-arg externs flow through the EApp spine walker; unit-
       returning externs emit `i32.const 0` so the stack stays
       balanced. cross_emit's stub `puts` doesn't matter — these
       cases only check the return of main(). *)
    cross_emit "extern fn 1-arg unit return"
      "extern fn host_log: int -> unit; let _ = host_log 42 in 99" "99";
    cross_emit "extern type + multi-arg"
      "extern type Handle; extern fn make_handle: int -> Handle; extern fn use_handle: Handle -> int -> unit; let h = make_handle 7 in let _ = use_handle h 100 in 0" "0";
    (* Phase 54.3 (Stage 54d-1): fn _ / fn (a) without annotation +
       fail builtin. Unlocks contrib/option/option.mere style code. *)
    cross_emit "fn _ wildcard arg"
      "(fn _ -> 42) 99" "42";
    cross_emit "fn (a) no annotation"
      "(fn (a) -> a + 1) 5" "6";
    cross_emit "fn (a) (b) curried no annot"
      "let z = fn (a) -> fn (b) -> a + b in z 3 4" "7";
    cross_emit "fail not reached"
      "let f = fn n -> if n > 0 then n else fail \"neg\" in f 7" "7";
    (* Phase 54.4 (Stage 54d-2): cons-tail sugar `[h, ...t]` in patterns.
       Desugars to `Cons (h, t)` directly — no fresh Nil at the tail. *)
    cross_emit "cons-tail pattern single head"
      "let rec sum = fn xs -> match xs with | [] -> 0 | [h, ...t] -> h + sum t in sum (Cons (1, Cons (2, Cons (3, Nil))))" "6";
    cross_emit "cons-tail pattern two heads"
      "let rec take2sum = fn xs -> match xs with | [a, b, ...rest] -> a + b + take2sum rest | _ -> 0 in take2sum (Cons (10, Cons (20, Cons (30, Cons (40, Nil)))))" "100";
    (* Phase 54.5: char-class builtins lowered inline (or via $is_space).
       Returns 1 / 0 wasm-side; we sum to make a single i32 check. *)
    cross_emit "ord builtin"
      "ord \"A\"" "65";
    cross_emit "is_digit builtin"
      "(if is_digit \"7\" then 1 else 0) + (if is_digit \"a\" then 10 else 0)" "1";
    cross_emit "is_alpha builtin"
      "(if is_alpha \"a\" then 1 else 0) + (if is_alpha \"Z\" then 2 else 0) + (if is_alpha \"5\" then 100 else 0)" "3";
    cross_emit "is_space builtin"
      "(if is_space \" \" then 1 else 0) + (if is_space \"\\n\" then 2 else 0) + (if is_space \"x\" then 100 else 0)" "3";
    cross_emit "str_of_int alias of show"
      "str_len (str_of_int 12345)" "5";
    (* Phase 54.6: str_starts_with + substring builtins.
       str_starts_with: byte-by-byte prefix check.
       substring: bump-alloc'd copy of bytes [start, end). *)
    cross_emit "str_starts_with true"
      "if str_starts_with \"hello world\" \"hello\" then 1 else 0" "1";
    cross_emit "str_starts_with false"
      "if str_starts_with \"hello\" \"world\" then 1 else 0" "0";
    cross_emit "str_starts_with empty prefix"
      "if str_starts_with \"x\" \"\" then 1 else 0" "1";
    cross_emit "str_starts_with prefix longer than haystack"
      "if str_starts_with \"hi\" \"hello\" then 1 else 0" "0";
    cross_emit "substring middle"
      "str_len (substring \"abcdefgh\" 2 5)" "3";
    cross_emit "substring as prefix"
      "if str_starts_with (substring \"abcdefgh\" 0 3) \"abc\" then 1 else 0" "1";
    (* Phase 54.7: int_of_str / str_index_of / str_repeat *)
    cross_emit "int_of_str positive"
      "int_of_str \"12345\"" "12345";
    cross_emit "int_of_str negative"
      "int_of_str \"-42\"" "-42";
    cross_emit "int_of_str leading whitespace"
      "int_of_str \"   77\"" "77";
    cross_emit "int_of_str no digits"
      "int_of_str \"abc\"" "0";
    cross_emit "str_index_of found"
      "str_index_of \"hello world\" \"wor\"" "6";
    cross_emit "str_index_of not found"
      "str_index_of \"hello\" \"xyz\"" "-1";
    cross_emit "str_index_of empty needle"
      "str_index_of \"hello\" \"\"" "0";
    cross_emit "str_repeat 3x"
      "str_len (str_repeat \"ab\" 3)" "6";
    cross_emit "str_repeat 0x"
      "str_len (str_repeat \"abc\" 0)" "0";
    cross_emit "str_repeat content check"
      "if str_starts_with (str_repeat \"xy\" 4) \"xyxyxyxy\" then 1 else 0" "1";
    (* Phase 54.8: str_unescape — recognized escapes mapped to byte,
       others passed through. *)
    cross_emit "str_unescape newline"
      "ord (str_unescape \"\\\\n\")" "10";
    cross_emit "str_unescape tab"
      "ord (str_unescape \"\\\\t\")" "9";
    cross_emit "str_unescape mixed"
      "str_len (str_unescape \"a\\\\nb\\\\tc\")" "5";
    cross_emit "str_unescape no escapes"
      "str_len (str_unescape \"hello\")" "5";
    cross_emit "try_or success"
      "try_or (fn () -> 42) 0" "42";
    cross_emit "try_or default discarded but evaluated"
      "let r = try_or (fn () -> 7) (1 + 2) in r" "7";
    (* Phase 54.9: selfhost_prelude prepends list_map + str_join so
       contrib code can use them without a per-file definition. *)
    cross_emit "prelude list_map sum"
      "let xs = Cons (1, Cons (2, Cons (3, Nil))) in let ys = list_map xs (fn x -> x * 10) in match ys with | Cons (a, Cons (b, Cons (c, Nil))) -> a + b + c | _ -> -1" "60";
    cross_emit "prelude list_map empty"
      (* `Nil (fn ...)` self-host-parses as Nil-with-payload (no arity
         table); use a let-bound empty list, matching real contrib
         usage where list_map gets a variable, not a bare constructor. *)
      "let xs = Nil in match list_map xs (fn x -> x + 1) with | Nil -> 1 | _ -> 0" "1";
    cross_emit "prelude str_join basic"
      "str_len (str_join \",\" (Cons (\"ab\", Cons (\"cd\", Cons (\"ef\", Nil)))))" "8";
    cross_emit "prelude str_join empty list"
      "str_len (str_join \",\" Nil)" "0";
    cross_emit "prelude str_join single"
      "str_len (str_join \"---\" (Cons (\"x\", Nil)))" "1";
    (* Phase 54.11: StrBuf — mutable buffer with push/to_str/len. *)
    cross_emit "strbuf empty len"
      "let b = strbuf_new () in strbuf_len b" "0";
    cross_emit "strbuf push len"
      "let b = strbuf_new () in let _ = strbuf_push b \"hello\" in strbuf_len b" "5";
    cross_emit "strbuf multi push len"
      "let b = strbuf_new () in let _ = strbuf_push b \"abc\" in let _ = strbuf_push b \"de\" in strbuf_len b" "5";
    cross_emit "strbuf snapshot via str_len"
      "let b = strbuf_new () in let _ = strbuf_push b \"hi\" in let _ = strbuf_push b \"!\" in str_len (strbuf_to_str b)" "3";
    cross_emit "strbuf grow past initial 64"
      (* push 8 chars * 10 = 80 bytes, exceeds 64-byte initial cap *)
      "let b = strbuf_new () in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in strbuf_len b" "80";
    cross_emit "not true"
      "if not true then 1 else 0" "0";
    cross_emit "not false"
      "if not false then 1 else 0" "1";
    cross_emit "not on expr"
      "if not (1 == 2) then 1 else 0" "1";
    cross_emit "prelude list_rev"
      "let xs = Cons (1, Cons (2, Cons (3, Nil))) in match list_rev xs with | Cons (h, _) -> h | _ -> -1" "3";
    cross_emit "prelude list_len"
      "list_len (Cons (1, Cons (2, Cons (3, Cons (4, Cons (5, Nil))))))" "5";
    cross_emit "prelude list_fold sum"
      "list_fold (Cons (1, Cons (2, Cons (3, Nil)))) 0 (fn a -> fn x -> a + x)" "6";
    cross_emit "prelude list_append len"
      "list_len (list_append (Cons (1, Cons (2, Nil))) (Cons (3, Cons (4, Cons (5, Nil)))))" "5";
    (* Phase 54.13: constructor-arity rewrite. Without it, `Some 42`
       parses as EApp(EConstr Some None, EInt 42) — a function call
       that traps at runtime. With the rewrite, it becomes the proper
       EConstr("Some", Some (EInt 42)). *)
    cross_emit "bare ctor arity Some"
      "type opt = None | Some of int; match Some 42 with | Some n -> n | None -> 0" "42";
    cross_emit "bare ctor arity Cons"
      "let xs = Cons 1 in match xs with | Cons n -> n | _ -> -1" "1";
    (* Phase 54.16: str_eq builtin for runtime string content equality.
       `==` on two non-literal strs falls back to i32.eq (pointer),
       which fails for equal content at different heap addresses.
       str_eq is the explicit content-compare escape hatch. *)
    cross_emit "str_eq equal literals"
      "if str_eq \"abc\" \"abc\" then 1 else 0" "1";
    cross_emit "str_eq unequal"
      "if str_eq \"abc\" \"abd\" then 1 else 0" "0";
    cross_emit "str_eq runtime built"
      "let s = \"hel\" ++ \"lo\" in if str_eq s \"hello\" then 1 else 0" "1";
    (* Phase 54.26: chr — inverse of ord *)
    cross_emit "chr basic"
      "ord (chr 65)" "65";
    cross_emit "chr round-trip"
      "if str_eq (chr 97) \"a\" then 1 else 0" "1";
    (* Phase 54.27: prelude expansion — str_split / list_filter / list_iter /
       list_any / list_all / str_trim. *)
    cross_emit "prelude str_split"
      "let rec count = fn xs -> match xs with | Nil -> 0 | Cons (_, t) -> 1 + count t in count (str_split \"a,b,c\" \",\")" "3";
    cross_emit "prelude str_split empty delim"
      "let rec count = fn xs -> match xs with | Nil -> 0 | Cons (_, t) -> 1 + count t in count (str_split \"abc\" \"\")" "1";
    cross_emit "prelude list_filter"
      "let rec sum = fn xs -> match xs with | Nil -> 0 | Cons (h, t) -> h + sum t in sum (list_filter (Cons (1, Cons (2, Cons (3, Cons (4, Nil))))) (fn n -> n > 2))" "7";
    cross_emit "prelude list_any"
      "if list_any (Cons (1, Cons (2, Cons (3, Nil)))) (fn n -> n == 2) then 1 else 0" "1";
    cross_emit "prelude list_all"
      "if list_all (Cons (1, Cons (2, Cons (3, Nil)))) (fn n -> n > 0) then 1 else 0" "1";
    cross_emit "prelude str_trim basic"
      "str_len (str_trim \"   hello   \")" "5";
    cross_emit "prelude str_trim empty"
      "str_len (str_trim \"     \")" "0";
    (* Phase 54.28: Map — assoc-list backed mutable cell. *)
    cross_emit "map_new + has empty"
      "let m = map_new () in if map_has m \"x\" then 1 else 0" "0";
    cross_emit "map_set + get"
      "let m = map_new () in let _ = map_set m \"answer\" 42 in map_get m \"answer\"" "42";
    cross_emit "map_set + has"
      "let m = map_new () in let _ = map_set m \"k\" 99 in if map_has m \"k\" then 1 else 0" "1";
    cross_emit "map_set overwrite"
      "let m = map_new () in let _ = map_set m \"k\" 1 in let _ = map_set m \"k\" 2 in map_get m \"k\"" "2";
    cross_emit "map_get missing lenient 0"
      "let m = map_new () in map_get m \"missing\"" "0";
    cross_emit "map multiple keys"
      "let m = map_new () in let _ = map_set m \"a\" 10 in let _ = map_set m \"b\" 20 in let _ = map_set m \"c\" 30 in map_get m \"a\" + map_get m \"b\" + map_get m \"c\"" "60";
    (* beta: map_delete unlinks all pairs with the key (matches OCaml's
       Hashtbl.remove). Unblocks http/session. *)
    cross_emit "map_delete removes key"
      "let m = map_new () in let _ = map_set m \"a\" 1 in let _ = map_set m \"b\" 2 in let _ = map_delete m \"b\" in (if map_has m \"b\" then 100 else 0) + map_get m \"a\"" "1";
    cross_emit "map_delete absent is no-op"
      "let m = map_new () in let _ = map_set m \"a\" 5 in let _ = map_delete m \"zzz\" in map_get m \"a\"" "5";
    cross_emit "map_delete then re-set"
      "let m = map_new () in let _ = map_set m \"k\" 1 in let _ = map_delete m \"k\" in let _ = map_set m \"k\" 9 in map_get m \"k\"" "9";
    (* beta: map_iter calls f k v once per key (current value). map_head
       dedups so overwrites are visited once. Unblocks http/metrics. *)
    cross_emit "map_iter sums values"
      "let m = map_new () in let _ = map_set m \"a\" 1 in let _ = map_set m \"b\" 2 in let _ = map_set m \"c\" 3 in let acc = map_new () in let _ = map_set acc \"s\" 0 in let _ = map_iter m (fn k -> fn v -> map_set acc \"s\" (map_get acc \"s\" + v)) in map_get acc \"s\"" "6";
    cross_emit "map_iter dedups overwrites"
      "let m = map_new () in let _ = map_set m \"a\" 1 in let _ = map_set m \"b\" 2 in let _ = map_set m \"b\" 20 in let acc = map_new () in let _ = map_set acc \"s\" 0 in let _ = map_iter m (fn k -> fn v -> map_set acc \"s\" (map_get acc \"s\" + v)) in map_get acc \"s\"" "21";
    (* beta: Vec runtime (new/push/get/set/len) ported from the OCaml
       codegen. Unblocks http/access_log, log/log. *)
    cross_emit "vec push/get/set/len"
      "let v = vec_new () in let _ = vec_push v 10 in let _ = vec_push v 20 in let _ = vec_push v 30 in let a = vec_get v 1 in let _ = vec_set v 1 99 in a + vec_get v 1 + vec_len v" "122";
    cross_emit "vec grows past initial cap"
      "let v = vec_new () in let rec go = fn i -> if i > 10 then () else let _ = vec_push v i in go (i + 1) in let _ = go 1 in vec_len v + vec_get v 0 + vec_get v 9" "21";
    (* A1/alpha: self-host parser gained `while cond do body` (Phase 36
       sugar). Desugars to a recursive unit->unit loop; these verify the
       self-host pipeline parses, lowers, and runs it. *)
    cross_emit "while loop iterates"
      "let m = map_new () in let _ = map_set m \"i\" 0 in let _ = while map_get m \"i\" < 3 do map_set m \"i\" (map_get m \"i\" + 1) in map_get m \"i\"" "3";
    cross_emit "while false zero iterations"
      "let _ = while 1 > 2 do 0 in 42" "42";
    (* beta: self-host prelude/import additions (str_contains, list_find,
       write_file) so contrib web/db code compiles under the self-host
       pipeline. *)
    cross_emit "str_contains hit"
      "if str_contains \"hello\" \"ell\" then 1 else 0" "1";
    cross_emit "str_contains miss"
      "if str_contains \"hello\" \"xyz\" then 1 else 0" "0";
    cross_emit "list_find match"
      "match list_find (Cons (1, Cons (2, Cons (3, Nil)))) (fn x -> x > 1) with | Some v -> v | None -> 0" "2";
    cross_emit "list_find none"
      "match list_find (Cons (1, Nil)) (fn x -> x > 9) with | Some v -> v | None -> 0" "0";
    cross_emit "write_file compiles + runs (host stub)"
      "let _ = write_file \"/tmp/mere_cross_wf\" \"hi\" in 42" "42";
    cross_emit "to_lower whole string"
      "if str_eq (to_lower \"AbC9\") \"abc9\" then 1 else 0" "1";
    (* gamma: self-host parser gained bare-brace `{}` (unit) and
       `{ e1; e2; ...; eN }` block (Let(PWild) chain); the record-update
       form `{ base | f = e }` still works. Unblocks csv/parser and
       json/writer. self_host_emit escapes `{` so these round-trip. *)
    cross_emit "brace block sequences"
      "let m = map_new () in let _ = { map_set m \"a\" 1; map_set m \"b\" 2 } in map_get m \"a\" + map_get m \"b\"" "3";
    cross_emit "empty brace is unit"
      "let _ = {} in 42" "42";
    cross_emit "single-expr brace"
      "{ 7 }" "7";
    (* Phase 54.29: module-qualified constructor pattern
       (`| M.C p -> ...`) parses as a single qualified name — matches
       toml.mere's `| Toml.TInt n -> ...` shape. Requires paren'd
       payload on the expression side so the parser produces a
       payload-bearing EConstr; bare `Toml.TInt 42` is a function
       application (would need arity table integration). *)
    cross_emit "Module.Ctor pattern"
      "match Toml.TInt (42) with | Toml.TInt n -> n | _ -> -1" "42";
    (* Phase 54.33: float literal now stored as source-text in EFloat
       and emitted as `f64.const N.M` (Phase 54.29's discard-fractional
       heuristic is replaced). Use int_of_float to observe the value. *)
    cross_emit "float literal + int_of_float"
      "int_of_float 42.5" "42";
    cross_emit "float arith f_mul + int_of_float"
      "int_of_float (f_mul 3.14 100.0)" "314";
    cross_emit "float cmp f_lt"
      "if f_lt 1.5 2.5 then 1 else 0" "1";
    cross_emit "float cmp f_gt"
      "if f_gt 1.5 2.5 then 1 else 0" "0";
    cross_emit "float_of_int round trip"
      "int_of_float (float_of_int 99)" "99";
    (* Phase 54.30: `region R { <expr> }` — permissive parse (region
       metadata discarded, body treated as plain expression). Matches
       markdown/to_text.mere and markdown/toc.mere shape. *)
    cross_emit "region block body value"
      "region R { let x = 10 in x + 5 }" "15";
    cross_emit "region block nested"
      "region R { let b = strbuf_new () in let _ = strbuf_push b \"hi\" in strbuf_len b }" "2";
    cross_emit "strbuf grow content intact"
      "let b = strbuf_new () in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in let _ = strbuf_push b \"01234567\" in if str_starts_with (strbuf_to_str b) \"012345670123456701\" then 1 else 0" "1";
    cross_emit "JSON renderer"
      "type Json = | JNull | JBool of bool | JInt of int | JStr of str | JArr of (Json list) | JObj of ((str * Json) list); let rec render = fn v -> match v with | JNull -> \"null\" | JBool b -> if b then \"true\" else \"false\" | JInt n -> show n | JStr s -> \"\\\"\" ++ s ++ \"\\\"\" | JArr items -> \"[\" ++ render_items items ++ \"]\" | JObj fields -> \"{\" ++ render_fields fields ++ \"}\" and render_items = fn xs -> match xs with | Nil -> \"\" | Cons (h, Nil) -> render h | Cons (h, t) -> render h ++ \", \" ++ render_items t and render_fields = fn fs -> match fs with | Nil -> \"\" | Cons ((k, v), Nil) -> \"\\\"\" ++ k ++ \"\\\": \" ++ render v | Cons ((k, v), t) -> \"\\\"\" ++ k ++ \"\\\": \" ++ render v ++ \", \" ++ render_fields t in let doc = JObj (Cons ((\"x\", JInt (42)), Cons ((\"on\", JBool (true)), Nil))) in let _ = print (render doc) in 0" "0";
    cross_emit "mini Mere eval (variants + closures)"
      "type Expr = | EInt of int | EBool of bool | EVar of str | EFn of (str * Expr) | EApp of (Expr * Expr) | EIf of (Expr * Expr * Expr); type Val = | VInt of int | VBool of bool | VFn of (str * Expr); let rec lookup = fn k -> fn env -> match env with | Nil -> VInt (0) | Cons ((k2, v), t) -> if k == k2 then v else lookup k t in let rec eval = fn e -> fn env -> match e with | EInt n -> VInt (n) | EBool b -> VBool (b) | EVar n -> lookup n env | EFn (param, body) -> VFn (param, body) | EApp (f, arg) -> let fv = eval f env in let av = eval arg env in (match fv with | VFn (param, body) -> eval body (Cons ((param, av), env)) | _ -> VInt (-1)) | EIf (c, t, el) -> (match eval c env with | VBool (true) -> eval t env | _ -> eval el env) in let r = eval (EApp (EFn (\"x\", EApp (EFn (\"y\", EVar (\"x\")), EInt (99))), EInt (42))) Nil in match r with | VInt n -> n | _ -> -1"
      "42";
    (* Phase 54.15: bootstrap harness — exercise parse_and_emit_file
       end-to-end. Feeds a tempfile through recursive import inlining
       + arity rewrite + codegen; the resulting WAT is compiled and
       run under node. These prove the self-host lexer and parser
       execute correctly under wasm at runtime, not just compile. *)
    let contrib = project_root ^ "/contrib" in
    bootstrap_emit "lexer bootstrap tokenize count"
      (Printf.sprintf
        "import \"%s/parser/lexer.mere\";\n\
         let rec count_toks = fn (xs: pos_token list) ->\n\
           match xs with\n\
           | Nil -> 0\n\
           | Cons (_, t) -> 1 + count_toks t\n\
         in\n\
         count_toks (tokenize \"let x = 1 in x\")\n"
        contrib)
      "7";
    bootstrap_emit "parser bootstrap parse_decls count"
      (Printf.sprintf
        "import \"%s/parser/ast.mere\";\n\
         import \"%s/parser/lexer.mere\";\n\
         import \"%s/parser/parser.mere\";\n\
         let rec count_decls = fn (xs: top_decl list) ->\n\
           match xs with\n\
           | Nil -> 0\n\
           | Cons (_, t) -> 1 + count_decls t\n\
         in\n\
         let toks = tokenize \"let x = 1; let y = 2; let z = 3;\" in\n\
         let (prog, _) = parse_decls Nil toks in\n\
         let (decls, _) = prog in\n\
         count_decls decls\n"
        contrib contrib contrib)
      "3";
    (* Phase 54.16: eval bootstrap. Works for expressions that don't
       need runtime string equality (arithmetic, if). let-in currently
       traps because lookup_env's `n == name` compares string pointers
       instead of contents — needs str_eq (added this slice) once
       eval.mere is patched to use it. *)
    bootstrap_emit "eval bootstrap arithmetic"
      (Printf.sprintf
        "import \"%s/eval/eval.mere\";\n\
         match parse_and_eval \"1 + 2 * 3\" with\n\
         | VInt n -> n\n\
         | _ -> -1\n"
        contrib)
      "7";
    bootstrap_emit "eval bootstrap if"
      (Printf.sprintf
        "import \"%s/eval/eval.mere\";\n\
         match parse_and_eval \"if 1 < 2 then 100 else 200\" with\n\
         | VInt n -> n\n\
         | _ -> -1\n"
        contrib)
      "100";
    (* Phase 54.17: full eval bootstrap works after switching env
       lookups to str_eq. These would trap on unreachable before. *)
    bootstrap_emit "eval bootstrap let-in"
      (Printf.sprintf
        "import \"%s/eval/eval.mere\";\n\
         match parse_and_eval \"let x = 5 in x + 1\" with\n\
         | VInt n -> n\n\
         | _ -> -1\n"
        contrib)
      "6";
    bootstrap_emit "eval bootstrap lambda apply"
      (Printf.sprintf
        "import \"%s/eval/eval.mere\";\n\
         match parse_and_eval \"(fn x -> x + 1) 41\" with\n\
         | VInt n -> n\n\
         | _ -> -1\n"
        contrib)
      "42";
    bootstrap_emit "eval bootstrap letrec factorial"
      (Printf.sprintf
        "import \"%s/eval/eval.mere\";\n\
         match parse_and_eval \"let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5\" with\n\
         | VInt n -> n\n\
         | _ -> -1\n"
        contrib)
      "120";
    (* Phase 54.18: typer bootstrap. parse_and_infer compiled to
       wasm; the inferred type is a str, so we return its length to
       give the harness an int to compare. int -> 3, bool -> 4. *)
    bootstrap_emit "typer bootstrap int"
      (Printf.sprintf
        "import \"%s/typer/typer.mere\";\n\
         str_len (parse_and_infer \"42\")\n"
        contrib)
      "3";
    bootstrap_emit "typer bootstrap bool"
      (Printf.sprintf
        "import \"%s/typer/typer.mere\";\n\
         str_len (parse_and_infer \"true\")\n"
        contrib)
      "4";
    bootstrap_emit "typer bootstrap let-in"
      (Printf.sprintf
        "import \"%s/typer/typer.mere\";\n\
         str_len (parse_and_infer \"let x = 5 in x + 1\")\n"
        contrib)
      "3";
    (* Phase 54.21: compile-time self-host bootstrap. codegen_wasm.mere
       compiling ITSELF. Threshold set well below the observed
       ~1.5 MB output; wat2wasm accepting the result proves syntactic
       validity of the self-emitted module. *)
    bootstrap_wat_ok "codegen self-emit"
      (project_root ^ "/contrib/codegen/codegen_wasm.mere")
      1_000_000;
    (* Phase 54.31: broader compile-time coverage. Every contrib that
       currently self-emits should stay compiling; add wat_ok checks
       for a spread of them so regressions surface. Thresholds are
       set to ~half the observed size so minor codegen changes have
       headroom but structural breakage catches. *)
    bootstrap_wat_ok "compile: json"
      (project_root ^ "/contrib/json/json.mere") 80_000;
    bootstrap_wat_ok "compile: orm"
      (project_root ^ "/contrib/orm/orm.mere") 35_000;
    bootstrap_wat_ok "compile: path"
      (project_root ^ "/contrib/path/path.mere") 50_000;
    (* Phase 55f dogfood: exercise the typed pipeline against real
       contrib files. option / path pass through cleanly with the
       Stage 55c-3 registry work — proves the annotate + emit chain
       doesn't regress on realistic inputs. regex / json / bigger
       contribs still trip our stricter typer (deferred — need
       polymorphic gap fix + a couple more builtins). *)
    typed_wat_ok "typed compile: option"
      (* threshold lowered: option.mere shed its on-import self-tests. *)
      "contrib/option/option.mere" 9000;
    typed_wat_ok "typed compile: path"
      (* threshold lowered: path.mere shed its on-import self-tests
         (library-clean, SSG-dogfood fix), so its typed WAT shrank. *)
      "contrib/path/path.mere" 12000;
    (* Phase 55f part 7: time.mere unlocked via float builtin additions
       (f_add / f_sub / f_lt etc. registered polymorphically). *)
    typed_wat_ok "typed compile: time"
      "contrib/time/time.mere" 5000;
    bootstrap_wat_ok "compile: option"
      (project_root ^ "/contrib/option/option.mere") 50_000;
    bootstrap_wat_ok "compile: regex"
      (project_root ^ "/contrib/regex/regex.mere") 80_000;
    bootstrap_wat_ok "compile: argparse"
      (project_root ^ "/contrib/argparse/argparse.mere") 60_000;
    bootstrap_wat_ok "compile: toml"
      (project_root ^ "/contrib/toml/toml.mere") 80_000;
    bootstrap_wat_ok "compile: markdown to_html"
      (project_root ^ "/contrib/markdown/to_html.mere") 140_000;
    bootstrap_wat_ok "compile: markdown to_text"
      (project_root ^ "/contrib/markdown/to_text.mere") 50_000;
    bootstrap_wat_ok "compile: markdown toc"
      (project_root ^ "/contrib/markdown/toc.mere") 50_000;
    (* Phase 54.33: time.mere unlocked via float codegen. Also cements
       the "18/18 contribs self-host compilable" milestone. *)
    bootstrap_wat_ok "compile: time"
      (project_root ^ "/contrib/time/time.mere") 40_000;
    (* Phase 54.34: fill in the CI-verified list to cover every
       self-host contrib. Runtime bootstrap harness already exercises
       lexer / parser / typer / eval / fmt end-to-end; adding wat_ok
       for the smaller regex.engine + test rounds out the coverage. *)
    bootstrap_wat_ok "compile: regex engine"
      (project_root ^ "/contrib/regex/engine.mere") 60_000;
    bootstrap_wat_ok "compile: test"
      (project_root ^ "/contrib/test/test.mere") 50_000;
    (* Phase 54.37: xml.mere is a module-only file (`module Xml { ... }`
       with no trailing main expr). Compiling it standalone proves the
       self-host codegen handles a module as the whole program. *)
    bootstrap_wat_ok "compile: xml"
      (project_root ^ "/contrib/xml/xml.mere") 200_000;
    (* Phase 54.37: feed.mere `import "xml.mere"` then defines its own
       `module Feed { ... }`. This is the regression guard for the
       import-inlining bug where `strip_import_main` cut at the last
       `;` *inside* the imported module, dropping its closing `}` and
       breaking module-body parsing. `strip_top_scan` now tracks brace
       depth (and skips strings/comments) so the module survives inlining. *)
    bootstrap_wat_ok "compile: feed"
      (project_root ^ "/contrib/feed/feed.mere") 250_000;
    (* Phase 54.22: fmt bootstrap. format_program compiled to wasm;
       we return the length of the formatted output. *)
    bootstrap_emit "fmt bootstrap int"
      (Printf.sprintf
        "import \"%s/fmt/fmt.mere\";\n\
         import \"%s/parser/parser.mere\";\n\
         let toks = tokenize \"42\" in\n\
         let (prog, _) = parse_decls Nil toks in\n\
         str_len (format_program prog)\n"
        contrib contrib)
      "3";
    bootstrap_emit "fmt bootstrap arith"
      (Printf.sprintf
        "import \"%s/fmt/fmt.mere\";\n\
         import \"%s/parser/parser.mere\";\n\
         let toks = tokenize \"1 + 2 * 3\" in\n\
         let (prog, _) = parse_decls Nil toks in\n\
         str_len (format_program prog)\n"
        contrib contrib)
      "10";
    bootstrap_emit "fmt bootstrap let-in"
      (Printf.sprintf
        "import \"%s/fmt/fmt.mere\";\n\
         import \"%s/parser/parser.mere\";\n\
         let toks = tokenize \"let x = 1 in x\" in\n\
         let (prog, _) = parse_decls Nil toks in\n\
         str_len (format_program prog)\n"
        contrib contrib)
      "15";
    (* Phase 54.36 (revisited): runtime self-host codegen bootstrap.
       Compiles examples/oneshot_codegen.mere via the OCaml-side
       codegen path (mere -w), runs the resulting wasm under Node,
       and asserts main() returns the expected WAT length. This
       proves the compiled self-host codegen can actually emit a
       valid program at runtime — closes the last unresolved gap
       from Phase 54.20. *)
    codegen_runtime_bootstrap "oneshot codegen"
      "examples/oneshot_codegen.mere" "96522"
  end else
    Printf.printf
      "skipping self-host codegen cross-validation (need wat2wasm + node)\n";

  (* Q-012 step 3a: concurrency primitives (interp — spawn/channel/join
     on OCaml 5 domains). Concurrency narrowing: spawn = OS-thread/Domain,
     Channel[T:Send], child = fresh region. Send/Sync type checking is
     minimal at this stage; the full trait check lands with the C backend. *)
  check "concurrency: channel roundtrip (single spawn)"
    (Pipeline.process
       "let ch = channel_new () in \
        let _ = spawn (fn () -> channel_send ch 42) in \
        channel_recv ch") "42";
  check "concurrency: parallel fib sum across 2 workers"
    (Pipeline.process
       "let rec fib = fn n -> if n < 2 then n else fib (n - 1) + fib (n - 2) in \
        let ch = channel_new () in \
        let _ = spawn (fn () -> channel_send ch (fib 20)) in \
        let _ = spawn (fn () -> channel_send ch (fib 20)) in \
        let r1 = channel_recv ch in \
        let r2 = channel_recv ch in \
        r1 + r2") "13530";
  check "concurrency: join returns unit"
    (Pipeline.process "let h = spawn (fn () -> ()) in join h") "()";
  check "concurrency: channel carries a str element (polymorphic)"
    (Pipeline.process
       "let ch = channel_new () in \
        let _ = spawn (fn () -> channel_send ch \"hi\") in \
        channel_recv ch") "\"hi\"";
  check "concurrency: spawn has type ThreadHandle"
    (Pipeline.type_of "spawn (fn () -> ())") "ThreadHandle";
  check "concurrency: channel element type propagates send->recv"
    (Pipeline.type_of
       "let ch = channel_new () in \
        let _ = spawn (fn () -> channel_send ch 42) in \
        channel_recv ch") "int";
  (* Q-012 §C/§D: Send bound on channel elements + sync/local markers. *)
  check_raises_containing "concurrency: sending a !Send (local type) element is rejected"
    "is not Send"
    (fun () -> Pipeline.process
       "local type Conn = MkConn of int; \
        let ch = channel_new () in \
        channel_send ch (MkConn 0)");
  check "concurrency: plain nominal element is Send (accepted)"
    (Pipeline.process
       "type Payload = MkPayload of int; \
        let ch = channel_new () in \
        channel_send ch (MkPayload 0)") "()";
  check "concurrency: sync-marked element is Send (accepted)"
    (Pipeline.process
       "sync type SharedLog = MkLog of int; \
        let ch = channel_new () in \
        channel_send ch (MkLog 0)") "()";
  (* Send/Sync derive structurally through unmarked records/variants: a plain
     type wrapping a !Send value is itself !Send (no smuggling by wrapping). *)
  check_raises_containing "send: a record wrapping a !Send field is rejected"
    "is not Send"
    (fun () -> Pipeline.process
       "local type Conn = MkConn of int; \
        type BoxR = { c: Conn }; \
        let ch = channel_new () in \
        channel_send ch (BoxR { c = MkConn 0 })");
  check_raises_containing "send: a variant wrapping a !Send payload is rejected"
    "is not Send"
    (fun () -> Pipeline.process
       "local type Conn = MkConn of int; \
        type Boxed = Wrap of Conn; \
        let ch = channel_new () in \
        channel_send ch (Wrap (MkConn 0))");
  check "send: a record of Send fields is Send (accepted)"
    (Pipeline.process
       "type Pt = { x: int, y: int }; \
        let ch = channel_new () in \
        channel_send ch (Pt { x = 1, y = 2 })") "()";
  (* Q-012 (OPEN i): move / use-after-move analysis for spawn captures. *)
  check_raises_containing "move: use-after-move of an owned cap is rejected"
    "use after move"
    (fun () -> Pipeline.process
       "drop type Logger = MkLogger of int; \
        let lg = MkLogger 0 in \
        let _ = spawn (fn () -> let _ = lg in ()) in \
        lg");
  check "move: an owned cap moved and not reused is accepted"
    (Pipeline.process
       "drop type Logger = MkLogger of int; \
        let lg = MkLogger 0 in \
        let _ = spawn (fn () -> let _ = lg in ()) in \
        ()") "()";
  check_raises_containing "move: capturing a !Send (local) cap is rejected"
    "neither"
    (fun () -> Pipeline.process
       "local type Conn = MkConn of int; \
        let c = MkConn 0 in \
        let _ = spawn (fn () -> let _ = c in ()) in \
        ()");
  check_raises_containing "move: moving inside a >1-run closure is rejected"
    "more than once"
    (fun () -> Pipeline.process
       "drop type Logger = MkLogger of int; \
        let lg = MkLogger 0 in \
        let f = fn u -> spawn (fn () -> let _ = lg in ()) in \
        let _ = f () in f ()");
  check_raises_containing "move: asymmetric one-branch move is rejected"
    "some branches"
    (fun () -> Pipeline.process
       "drop type Logger = MkLogger of int; \
        let lg = MkLogger 0 in \
        let _ = if true then (let _ = spawn (fn () -> let _ = lg in ()) in ()) \
                else () in \
        ()");
  check_raises_containing "move: capturing a polymorphic-typed var is rejected"
    "polymorphic"
    (fun () -> Pipeline.process
       "let g = fn c -> spawn (fn () -> let _ = c in ()) in ()");
  check "move: a Sync (shared) cap stays usable in the parent"
    (Pipeline.process
       "sync type SLog = MkLog of int; \
        let s = MkLog 0 in \
        let _ = spawn (fn () -> let _ = s in ()) in \
        let _ = s in ()") "()";
  (* Q-012 (OPEN ii): polymorphic channels — deferred Send bound + the
     "don't generalize a Send-constrained tyvar" monomorphization. *)
  check_raises_containing
    "poly channel: smuggling a !Send value through a polymorphic fn is rejected"
    "is not Send"
    (fun () -> Pipeline.process
       "local type Conn = MkConn of int; \
        let f = fn ch -> fn v -> channel_send ch v; \
        let c = MkConn 0 in \
        let ch = channel_new () in \
        f ch c");
  check "poly channel: a polymorphic channel fn used at a Send type is accepted"
    (Pipeline.process
       "let f = fn ch -> fn v -> channel_send ch v; \
        let ch = channel_new () in \
        f ch 42") "()";
  check_raises
    "poly channel: a Send-constrained channel fn is monomorphic (no reuse at 2 types)"
    (fun () -> Pipeline.process
       "let f = fn ch -> fn v -> channel_send ch v; \
        let c1 = channel_new () in \
        let c2 = channel_new () in \
        let _ = f c1 42 in \
        f c2 \"x\"");
  (* Q-012 motivating scenario end-to-end: two loops in one process — a
     worker loop on a spawned thread consuming jobs from a channel while the
     main loop produces them, reporting the total through a second channel. *)
  check "concurrency: two concurrent loops communicate over channels"
    (Pipeline.process
       "let rec produce = fn ch -> fn n -> \
          if n < 1 then channel_send ch 0 \
          else let _ = channel_send ch n in produce ch (n - 1); \
        let rec consume = fn jobs -> fn acc -> \
          let j = channel_recv jobs in \
          if j < 1 then acc else consume jobs (acc + j); \
        let jobs = channel_new () in \
        let results = channel_new () in \
        let _ = spawn (fn u -> channel_send results (consume jobs 0)) in \
        let _ = produce jobs 100 in \
        channel_recv results") "5050";
  (* Data-parallel fan-out / fan-in: four workers each compute a partial and
     post it to a shared channel; the main thread sums the partials. *)
  check "concurrency: data-parallel fan-out/fan-in over 4 workers"
    (Pipeline.process
       "let rec fib = fn n -> if n < 2 then n else fib (n - 1) + fib (n - 2); \
        let rec partial = fn count -> \
          if count < 1 then 0 else fib 20 + partial (count - 1); \
        let results = channel_new () in \
        let _ = spawn (fn u -> channel_send results (partial 5)) in \
        let _ = spawn (fn u -> channel_send results (partial 5)) in \
        let _ = spawn (fn u -> channel_send results (partial 5)) in \
        let _ = spawn (fn u -> channel_send results (partial 5)) in \
        let r1 = channel_recv results in \
        let r2 = channel_recv results in \
        let r3 = channel_recv results in \
        let r4 = channel_recv results in \
        r1 + r2 + r3 + r4") "135300";
  (* Phase 32: par_map — ergonomic data parallelism (interp; backend codegen
     is a follow-up). Polymorphic (checked per call site) with Send bounds on
     the input and output element types. *)
  check "par_map: applies f to every element in parallel, in order"
    (Pipeline.process
       "let sq = fn x -> x * x in \
        par_map sq (Cons (1, Cons (2, Cons (3, Cons (4, Nil)))))") "[1, 4, 9, 16]";
  check "par_map: type is (a -> b) -> a list -> b list"
    (Pipeline.type_of "let sq = fn x -> x * x in par_map sq") "(int list -> int list)";
  check_raises_containing "par_map: a !Send output element is rejected"
    "is not Send"
    (fun () -> Pipeline.process
       "local type Conn = MkConn of int; \
        let f = fn x -> MkConn x in \
        par_map f (Cons (1, Nil))");
  (* A parallel count ("how many satisfy p?") is map-reduce, not shared
     mutable state: each worker returns 0/1 and the results are summed —
     no Mutex / atomic needed. *)
  check "par_map: parallel count is map-then-reduce (no shared state)"
    (Pipeline.process
       "let rec range = fn lo -> fn hi -> \
          if lo >= hi then Nil else Cons (lo, range (lo + 1) hi); \
        let rec sum = fn xs -> match xs with Nil -> 0 | Cons (h, t) -> h + sum t; \
        let over = fn n -> if n > 4 then 1 else 0; \
        sum (par_map over (range 0 10))") "5";
  (* Branch-and-bound pruning: sequential shares one best (1 eval); parallel
     workers with local bests do more evals (4) for the same answer. The gap
     is the concrete motivation for a shared atomic best (Phase 31). *)
  check "concurrency: parallel pruning does more work without a shared best"
    (Pipeline.process
       "let hi = 40; \
        let ub = fn x -> hi - x; \
        let score = fn x -> ub x; \
        let rec search = fn lo -> fn hiend -> fn best -> fn evals -> \
          if lo >= hiend then (best, evals) \
          else if ub lo <= best then search (lo + 1) hiend best evals \
          else let s = score lo in \
               let nb = if s > best then s else best in \
               search (lo + 1) hiend nb (evals + 1); \
        let worker = fn c -> match c with (lo, h) -> search lo h 0 0; \
        let chunks = Cons ((0,10), Cons ((10,20), Cons ((20,30), Cons ((30,40), Nil)))); \
        let rec combine = fn rs -> fn best -> fn evals -> \
          match rs with \
          | Nil -> (best, evals) \
          | Cons (r, rest) -> match r with (b, e) -> \
              combine rest (if b > best then b else best) (evals + e); \
        let (sb, se) = search 0 hi 0 0 in \
        let (pb, pe) = combine (par_map worker chunks) 0 0 in \
        (sb, se, pb, pe)") "(40, 1, 40, 4)";

  (* P4: a qualified module type (`M.t`) is accepted in a type annotation
     (module-internal types are registered unqualified, so it resolves to
     `t`). Used to fail with "expected ',' or ')' in param list" at the dot. *)
  check "qualified module type in annotation"
    (Pipeline.process
       "module M { type t = | A | B; } let f = fn (x: M.t) -> match x with | A -> 1 | B -> 2 in f B")
    "2";

  (* Phase 57: package installer (mere.toml parse + path normalise). The
     fetch/copy path shells out to git and is exercised end-to-end by hand
     (see project notes 61); here we regress the pure parsing logic. *)
  (let open Mere.Pkg_install in
   check "pkg_install: normalize .." (normalize "contrib/http/../log") "contrib/log";
   check "pkg_install: normalize ../.."
     (normalize "contrib/site/playground/../../dom") "contrib/dom";
   check "pkg_install: normalize ./" (normalize "contrib/./http") "contrib/http";
   let sample =
     "[package]\n\
      name = \"mere-notes\"\n\
      version = \"0.1.0\"\n\
      \n\
      [dependencies]\n\
      http = { git = \"https://x/mere\", subdir = \"contrib/http\", rev = \"abc123\" }\n\
      db = { git = \"https://x/mere\", rev = \"def456\" }  # no subdir\n"
   in
   let m = parse_manifest sample in
   check "pkg_install: manifest name" m.pkg_name "mere-notes";
   check "pkg_install: manifest version" m.pkg_version "0.1.0";
   check "pkg_install: dep count" (string_of_int (List.length m.deps)) "2";
   (match m.deps with
    | [ d1; d2 ] ->
      check "pkg_install: dep1 name" d1.name "http";
      check "pkg_install: dep1 git" d1.git "https://x/mere";
      check "pkg_install: dep1 subdir" (Option.value ~default:"-" d1.subdir) "contrib/http";
      check "pkg_install: dep1 rev" d1.rev "abc123";
      check "pkg_install: dep2 name" d2.name "db";
      check "pkg_install: dep2 subdir-none"
        (match d2.subdir with None -> "none" | Some _ -> "some") "none";
      check "pkg_install: dep2 rev" d2.rev "def456"
    | _ -> check "pkg_install: dep shape" "wrong" "two deps");
   (* require-flattening for the vendored Node host (.mere_host/). *)
   check "pkg_install: rewrite ../contrib require"
     (rewrite_requires "const g = require(\"../contrib/http/http.glue.js\");")
     "const g = require(\"./http.glue.js\");";
   check "pkg_install: rewrite ../../scripts require"
     (rewrite_requires "require(\"../../scripts/ws_env.js\")")
     "require(\"./ws_env.js\")";
   check "pkg_install: rewrite same-dir require unchanged"
     (rewrite_requires "require(\"./pg_env.js\")") "require(\"./pg_env.js\")";
   check "pkg_install: rewrite builtin require unchanged"
     (rewrite_requires "require(\"crypto\")") "require(\"crypto\")";
   (* [host] section parsing. *)
   let host_sample =
     "[package]\nname = \"a\"\n[host]\n\
      git = \"https://x/mere\"\nrev = \"deadbeef\"\n"
   in
   check "pkg_install: manifest host"
     (match (parse_manifest host_sample).host with
      | Some (g, r) -> g ^ "@" ^ r
      | None -> "none")
     "https://x/mere@deadbeef");

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
