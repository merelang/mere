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

  (* arithmetic (regression) *)
  check "'1 + 2'"          (Pipeline.process "1 + 2")          "3";
  check "'2 + 3 * 4'"      (Pipeline.process "2 + 3 * 4")      "14";
  check "'(2 + 3) * 4'"    (Pipeline.process "(2 + 3) * 4")    "20";
  check "'-(2 + 3)'"       (Pipeline.process "-(2 + 3)")       "-5";

  (* comments (regression) *)
  check "leading comment"  (Pipeline.process "// note\n42")    "42";
  check "trailing comment" (Pipeline.process "1 + 2 // sum")   "3";

  (* let (regression) *)
  check "let basic"        (Pipeline.process "let x = 5 in x + 1") "6";
  check "inner shadow"     (Pipeline.process "let x = 1 in (let x = 2 in x)") "2";

  (* bool / if (regression) *)
  check "'1 < 2'"          (Pipeline.process "1 < 2")  "true";
  check "'1 == 1'"         (Pipeline.process "1 == 1") "true";
  check "if + comparison"  (Pipeline.process "if 1 < 2 then 100 else 200") "100";
  check "max-like"
    (Pipeline.process "let a = 7 in let b = 3 in if a < b then b else a") "7";

  (* lambda + application *)
  check "'(fn x -> x + 1) 5'"
    (Pipeline.process "(fn x -> x + 1) 5") "6";
  check "let-bound function"
    (Pipeline.process "let inc = fn x -> x + 1 in inc 5") "6";
  check "square"
    (Pipeline.process "let sq = fn x -> x * x in sq 7") "49";

  (* closure: lexical scope *)
  check "lexical capture"
    (Pipeline.process "let x = 10 in (fn y -> x + y) 5") "15";
  check "captured x not affected by later shadow"
    (Pipeline.process "let x = 1 in let f = fn y -> x + y in let x = 100 in f 10") "11";

  (* currying *)
  check "curry two args"
    (Pipeline.process "(fn x -> fn y -> x + y) 3 4") "7";
  check "let-bound curried add"
    (Pipeline.process "let add = fn x -> fn y -> x + y in add 3 4") "7";

  (* higher-order *)
  check "twice"
    (Pipeline.process "let twice = fn f -> fn x -> f (f x) in twice (fn x -> x + 1) 5") "7";
  check "compose"
    (Pipeline.process "let compose = fn f -> fn g -> fn x -> f (g x) in compose (fn x -> x * 2) (fn x -> x + 1) 5") "12";
  check "partial application"
    (Pipeline.process "let add = fn x -> fn y -> x + y in let inc = add 1 in inc 10") "11";

  (* fn + if combo (mini factorial-style without recursion: 3! manually) *)
  check "fn + if combo"
    (Pipeline.process "let pos = fn x -> if 0 < x then x else -x in pos (-7)") "7";

  (* pretty print *)
  check "pp fn"
    (Ast.pp (Pipeline.parse_only "fn x -> x + 1"))
    "(fn x -> (x + 1))";
  check "pp app"
    (Ast.pp (Pipeline.parse_only "f x y"))
    "((f x) y)";

  (* closure to_string *)
  check "closure printed"
    (Pipeline.process "fn x -> x") "<closure:x>";

  (* errors *)
  check_raises "lex error: '@'"            (fun () -> Pipeline.process "1 + @");
  check_raises "parse error: trailing"     (fun () -> Pipeline.process "1 2 fn");
  check_raises "parse error: missing )"    (fun () -> Pipeline.process "(1 + 2");
  check_raises "eval error: unbound var"   (fun () -> Pipeline.process "x + 1");
  check_raises "parse error: fn no arrow"  (fun () -> Pipeline.process "fn x x + 1");
  check_raises "type error: apply int"     (fun () -> Pipeline.process "5 1");
  check_raises "type error: closure + 1"   (fun () -> Pipeline.process "(fn x -> x) + 1");

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
