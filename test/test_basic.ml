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

  (* --- regression: single-expression programs --- *)
  check "'1 + 2'"          (Pipeline.process "1 + 2")          "3";
  check "let-in basic"     (Pipeline.process "let x = 5 in x + 1") "6";
  check "fn + app"         (Pipeline.process "(fn x -> x + 1) 5") "6";
  check "if + comparison"  (Pipeline.process "if 1 < 2 then 100 else 200") "100";
  check "twice"
    (Pipeline.process "let twice = fn f -> fn x -> f (f x) in twice (fn x -> x + 1) 5") "7";
  check "let rec factorial"
    (Pipeline.process "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 6") "720";
  check "annotated fn applied"
    (Pipeline.process "((fn x -> x + 1) : int -> int) 5") "6";

  (* --- top-level decls (slice 8) --- *)
  check "single top let"
    (Pipeline.process "let x = 5; x + 1") "6";
  check "two top lets"
    (Pipeline.process "let x = 5; let y = 10; x * y") "50";
  check "top let with fn"
    (Pipeline.process "let f = fn n -> n + 1; f 10") "11";
  check "top let rec"
    (Pipeline.process "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1); fact 6") "720";
  check "top decls reference earlier"
    (Pipeline.process "let x = 10; let f = fn n -> n + x; f 5") "15";
  check "mix of top let and in-let"
    (Pipeline.process "let x = 5; let f = fn n -> n + x in f 10") "15";
  check "top let with annotated value"
    (Pipeline.process "let f = (fn x -> x + 1) : int -> int; f 5") "6";

  (* --- type checks with top decls --- *)
  check "type top decls"
    (Pipeline.type_of "let x = 5; let y = 10; x + y") "int";
  check "type top let rec"
    (Pipeline.type_of "let rec fact = (fn n -> if n < 1 then 1 else n * fact (n - 1)) : int -> int; fact 5") "int";
  check "type top fn"
    (Pipeline.type_of "let f = (fn x -> x + 1) : int -> int; f") "(int -> int)";
  check "process_typed multi-decl"
    (Pipeline.process_typed "let x = 5; let y = 10; x + y") "15";

  (* --- pretty print after desugar --- *)
  check "pp top decls desugar"
    (Ast.pp (Pipeline.parse_only "let x = 5; x + 1"))
    "(let x = 5 in (x + 1))";

  (* --- errors --- *)
  check_raises "let without ; or in"
    (fun () -> Pipeline.process "let x = 5");
  check_raises "top decl without ;"
    (fun () -> Pipeline.process "let x = 5 let y = 10; x + y");
  check_raises "no main expr"
    (fun () -> Pipeline.process "let x = 5;");
  check_raises "lex error"
    (fun () -> Pipeline.process "1 + @");
  check_raises "type error in main"
    (fun () -> Pipeline.type_of "let x = 5; x + true");

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
