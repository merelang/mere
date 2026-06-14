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

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
