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
  check "'1 + 2'"          (Pipeline.process "1 + 2")          "3";
  check "factorial"
    (Pipeline.process "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 6") "720";
  check "type opt"
    (Pipeline.process "type opt = None | Some of int; Some 5") "Some 5";
  check "match opt"
    (Pipeline.process
      "type opt = None | Some of int;
       match Some 5 with | None -> 0 | Some n -> n + 1") "6";

  (* --- tuples: expressions --- *)
  check "tuple 2"
    (Pipeline.process "(1, 2)") "(1, 2)";
  check "tuple 3"
    (Pipeline.process "(1, 2, 3)") "(1, 2, 3)";
  check "tuple of mixed types"
    (Pipeline.process "(1, true, \"hi\")") "(1, true, \"hi\")";
  check "tuple type"
    (Pipeline.type_of "(1, 2)") "(int * int)";
  check "tuple type mixed"
    (Pipeline.type_of "(1, true, \"hi\")") "(int * bool * str)";

  (* --- tuples: pattern match --- *)
  check "match tuple"
    (Pipeline.process "match (1, 2) with | (a, b) -> a + b") "3";
  check "match tuple 3"
    (Pipeline.process "match (1, 2, 3) with | (a, b, c) -> a + b + c") "6";
  check "match tuple with wildcard"
    (Pipeline.process "match (1, 2, 3) with | (_, b, _) -> b") "2";

  (* --- multi-arg variants via tuple payload --- *)
  check "variant with tuple payload"
    (Pipeline.process
      "type pair = Pair of int * int;
       Pair (3, 4)") "Pair (3, 4)";
  check "match variant with tuple"
    (Pipeline.process
      "type pair = Pair of int * int;
       match Pair (3, 4) with | Pair (a, b) -> a * b") "12";
  check "type of pair"
    (Pipeline.type_of
      "type pair = Pair of int * int;
       Pair (3, 4)") "pair";

  (* --- linked list! --- *)
  check "list: sum to 6"
    (Pipeline.process
      "type intlist = INil | ICons of int * intlist;
       let rec sum = fn lst ->
         match lst with
         | INil -> 0
         | ICons (h, t) -> h + sum t
       in sum (ICons (1, ICons (2, ICons (3, INil))))") "6";
  check "list: length 4"
    (Pipeline.process
      "type intlist = INil | ICons of int * intlist;
       let rec len = fn lst ->
         match lst with
         | INil -> 0
         | ICons (_, t) -> 1 + len t
       in len (ICons (10, ICons (20, ICons (30, ICons (40, INil)))))") "4";

  (* --- binary tree --- *)
  check "tree: sum of node values"
    (Pipeline.process
      "type tree = Leaf | Node of tree * int * tree;
       let rec sum = fn t ->
         match t with
         | Leaf -> 0
         | Node (l, v, r) -> sum l + v + sum r
       in sum (Node (Node (Leaf, 1, Leaf), 2, Node (Leaf, 3, Leaf)))") "6";

  (* --- tuple via let then use --- *)
  check "let-bound tuple via match"
    (Pipeline.process
      "let p = (10, 20) in
       match p with | (a, b) -> a + b") "30";

  (* --- type errors --- *)
  check_raises "tuple size mismatch"
    (fun () -> Pipeline.type_of "match (1, 2) with | (a, b, c) -> a");
  check_raises "tuple element type mismatch in unify"
    (fun () -> Pipeline.type_of
      "let f = fn p -> match p with | (a, b) -> a + b in
       f (1, true)");
  check_raises "constructor expects tuple but got int"
    (fun () -> Pipeline.process
      "type pair = Pair of int * int;
       Pair 3");

  (* --- pp --- *)
  check "pp tuple"
    (Ast.pp (Pipeline.parse_only "(1, 2, 3)")) "(1, 2, 3)";
  check "pp_ty tuple"
    (Ast.pp_ty (Ast.TyTuple [Ast.TyInt; Ast.TyBool])) "(int * bool)";

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
