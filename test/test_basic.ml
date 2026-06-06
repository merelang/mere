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

  (* --- regression: eval (Pipeline.process, no type check) --- *)
  check "'1 + 2'"          (Pipeline.process "1 + 2")          "3";
  check "let basic"        (Pipeline.process "let x = 5 in x + 1") "6";
  check "twice"
    (Pipeline.process "let twice = fn f -> fn x -> f (f x) in twice (fn x -> x + 1) 5") "7";
  check "let rec factorial"
    (Pipeline.process "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 6") "720";
  check "top decls"
    (Pipeline.process "let x = 5; let y = 10; x + y") "15";

  (* --- HM inference: unannotated functions --- *)
  check "type 'fn x -> x + 1'"
    (Pipeline.type_of "fn x -> x + 1") "(int -> int)";
  check "type 'let inc = fn x -> x + 1 in inc 5'"
    (Pipeline.type_of "let inc = fn x -> x + 1 in inc 5") "int";
  check "type 'fn x -> x' (polymorphic identity)"
    (Pipeline.type_of "fn x -> x") "('a -> 'a)";
  check "type 'fn f -> fn x -> f x'"
    (Pipeline.type_of "fn f -> fn x -> f x") "(('a -> 'b) -> ('a -> 'b))";

  (* --- HM let-polymorphism --- *)
  check "let-poly id used at int and bool"
    (Pipeline.type_of "let id = fn x -> x in if id true then id 1 else id 2") "int";
  check "let-poly twice"
    (Pipeline.type_of "let twice = fn f -> fn x -> f (f x) in twice (fn x -> x + 1) 5") "int";
  check "let-poly compose"
    (Pipeline.type_of "let compose = fn f -> fn g -> fn x -> f (g x) in compose (fn x -> x * 2) (fn x -> x + 1) 5") "int";

  (* --- HM let rec without annotation --- *)
  check "type factorial without annotation"
    (Pipeline.type_of "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5") "int";
  check "type fibonacci without annotation"
    (Pipeline.type_of "let rec fib = fn n -> if n < 2 then n else fib (n - 1) + fib (n - 2) in fib 10") "int";

  (* --- HM with top decls --- *)
  check "type top decls (unannotated fn)"
    (Pipeline.type_of "let inc = fn x -> x + 1; let f = fn x -> x; inc 5") "int";
  check "type top let rec without annotation"
    (Pipeline.type_of "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1); fact 10") "int";

  (* --- annotations still work as constraints --- *)
  check "annotation narrows"
    (Pipeline.type_of "(fn x -> x + 1) : int -> int") "(int -> int)";
  check "annotation on polymorphic"
    (Pipeline.type_of "(fn x -> x) : int -> int") "(int -> int)";

  (* --- process_typed integrates check + eval --- *)
  check "process_typed factorial unannotated"
    (Pipeline.process_typed "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10")
    "3628800";
  check "process_typed compose unannotated"
    (Pipeline.process_typed "let compose = fn f -> fn g -> fn x -> f (g x) in compose (fn x -> x * 2) (fn x -> x + 1) 5")
    "12";

  (* --- type errors still caught --- *)
  check_raises "type error: int + bool"
    (fun () -> Pipeline.type_of "1 + true");
  check_raises "type error: if cond not bool"
    (fun () -> Pipeline.type_of "if 1 then 2 else 3");
  check_raises "type error: branches differ"
    (fun () -> Pipeline.type_of "if true then 1 else false");
  check_raises "type error: apply int"
    (fun () -> Pipeline.type_of "5 1");
  check_raises "type error: annotation lies"
    (fun () -> Pipeline.type_of "(1 : bool)");
  check_raises "type error: unbound"
    (fun () -> Pipeline.type_of "y + 1");
  check_raises "type error: occurs check"
    (fun () -> Pipeline.type_of "fn x -> x x");
  check_raises "type error: let rec wrong shape"
    (fun () -> Pipeline.type_of "let rec f = fn n -> n + true in f 1");

  (* --- type pp --- *)
  check "pp_ty int"     (Ast.pp_ty Ast.TyInt) "int";
  check "pp_ty bool"    (Ast.pp_ty Ast.TyBool) "bool";
  check "pp_ty arrow"   (Ast.pp_ty (Ast.TyArrow (Ast.TyInt, Ast.TyBool))) "(int -> bool)";

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
