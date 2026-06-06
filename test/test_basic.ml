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
  check "'-(2 + 3)'"       (Pipeline.process "-(2 + 3)")       "-5";
  check "let basic"        (Pipeline.process "let x = 5 in x + 1") "6";
  check "if + comparison"  (Pipeline.process "if 1 < 2 then 100 else 200") "100";
  check "twice (higher-order)"
    (Pipeline.process "let twice = fn f -> fn x -> f (f x) in twice (fn x -> x + 1) 5") "7";
  check "annotated function applied"
    (Pipeline.process "((fn x -> x + 1) : int -> int) 5") "6";
  check "type '1 + 2'"     (Pipeline.type_of "1 + 2") "int";

  (* --- let rec (eval) --- *)
  check "factorial 0"
    (Pipeline.process
       "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 0") "1";
  check "factorial 1"
    (Pipeline.process
       "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 1") "1";
  check "factorial 5"
    (Pipeline.process
       "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5") "120";
  check "factorial 10"
    (Pipeline.process
       "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10") "3628800";
  check "fibonacci 0"
    (Pipeline.process
       "let rec fib = fn n -> if n < 2 then n else fib (n - 1) + fib (n - 2) in fib 0") "0";
  check "fibonacci 1"
    (Pipeline.process
       "let rec fib = fn n -> if n < 2 then n else fib (n - 1) + fib (n - 2) in fib 1") "1";
  check "fibonacci 10"
    (Pipeline.process
       "let rec fib = fn n -> if n < 2 then n else fib (n - 1) + fib (n - 2) in fib 10") "55";
  check "let rec + multi-arg via currying"
    (Pipeline.process
       "let rec range_sum = fn lo -> fn hi -> if hi < lo then 0 else lo + range_sum (lo + 1) hi in range_sum 1 10") "55";

  (* --- let rec (typed) --- *)
  check "type factorial"
    (Pipeline.type_of
       "let rec fact = (fn n -> if n < 1 then 1 else n * fact (n - 1)) : int -> int in fact")
    "(int -> int)";
  check "type factorial applied"
    (Pipeline.type_of
       "let rec fact = (fn n -> if n < 1 then 1 else n * fact (n - 1)) : int -> int in fact 5")
    "int";
  check "process_typed factorial"
    (Pipeline.process_typed
       "let rec fact = (fn n -> if n < 1 then 1 else n * fact (n - 1)) : int -> int in fact 6")
    "720";

  (* --- pretty print let rec --- *)
  check "pp let rec"
    (Ast.pp (Pipeline.parse_only "let rec f = fn n -> n in f 1"))
    "(let rec f = (fn n -> n) in (f 1))";

  (* --- errors --- *)
  check_raises "let rec missing in"
    (fun () -> Pipeline.process "let rec f = fn n -> n");
  check_raises "let rec missing eq"
    (fun () -> Pipeline.process "let rec f fn n -> n in f 1");
  check_raises "type error: let rec without annotation"
    (fun () -> Pipeline.type_of
       "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5");
  check_raises "type error: let rec annotation lies"
    (fun () -> Pipeline.type_of
       "let rec f = (fn n -> n + 1) : int -> bool in f 1");

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
