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

  (* --- regression: arithmetic / let / bool / if / fn (via process, eval only) --- *)
  check "'1 + 2'"          (Pipeline.process "1 + 2")          "3";
  check "'2 + 3 * 4'"      (Pipeline.process "2 + 3 * 4")      "14";
  check "'-(2 + 3)'"       (Pipeline.process "-(2 + 3)")       "-5";
  check "let basic"        (Pipeline.process "let x = 5 in x + 1") "6";
  check "if + comparison"  (Pipeline.process "if 1 < 2 then 100 else 200") "100";
  check "max-like"
    (Pipeline.process "let a = 7 in let b = 3 in if a < b then b else a") "7";
  check "twice"
    (Pipeline.process "let twice = fn f -> fn x -> f (f x) in twice (fn x -> x + 1) 5") "7";
  check "compose"
    (Pipeline.process "let compose = fn f -> fn g -> fn x -> f (g x) in compose (fn x -> x * 2) (fn x -> x + 1) 5") "12";
  check "partial application"
    (Pipeline.process "let add = fn x -> fn y -> x + y in let inc = add 1 in inc 10") "11";

  (* --- annotations (eval transparent) --- *)
  check "annot transparent"
    (Pipeline.process "(1 + 2 : int)") "3";
  check "annotated function applied"
    (Pipeline.process "((fn x -> x + 1) : int -> int) 5") "6";

  (* --- type pretty printing --- *)
  check "pp_ty int"            (Ast.pp_ty Ast.TyInt) "int";
  check "pp_ty bool"           (Ast.pp_ty Ast.TyBool) "bool";
  check "pp_ty int -> bool"
    (Ast.pp_ty (Ast.TyArrow (Ast.TyInt, Ast.TyBool))) "(int -> bool)";
  check "pp_ty curried"
    (Ast.pp_ty (Ast.TyArrow (Ast.TyInt, Ast.TyArrow (Ast.TyInt, Ast.TyInt))))
    "(int -> (int -> int))";

  (* --- type checking: well-typed --- *)
  check "type '1 + 2'"             (Pipeline.type_of "1 + 2")          "int";
  check "type '1 < 2'"             (Pipeline.type_of "1 < 2")          "bool";
  check "type 'true'"              (Pipeline.type_of "true")           "bool";
  check "type let int"             (Pipeline.type_of "let x = 5 in x") "int";
  check "type let bool"
    (Pipeline.type_of "let x = true in x") "bool";
  check "type if returning int"
    (Pipeline.type_of "if true then 1 else 2") "int";
  check "type annotated fn"
    (Pipeline.type_of "(fn x -> x + 1) : int -> int") "(int -> int)";
  check "type annotated fn applied"
    (Pipeline.type_of "((fn x -> x + 1) : int -> int) 5") "int";
  check "type higher-order (int->int)->int"
    (Pipeline.type_of "(fn f -> f 5) : (int -> int) -> int")
    "((int -> int) -> int)";
  check "type let-bound fn"
    (Pipeline.type_of "let f = (fn x -> x + 1) : int -> int in f 10") "int";
  check "type if with bool branches"
    (Pipeline.type_of "if true then false else true") "bool";

  (* --- type checking: process_typed runs both --- *)
  check "process_typed '1 + 2 * 3'"
    (Pipeline.process_typed "1 + 2 * 3") "7";
  check "process_typed annotated fn"
    (Pipeline.process_typed "((fn x -> if x < 0 then -x else x) : int -> int) (-7)") "7";

  (* --- type errors --- *)
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
  check_raises "type error: fn without annot"
    (fun () -> Pipeline.type_of "fn x -> x + 1");
  check_raises "type error: unbound"
    (fun () -> Pipeline.type_of "y + 1");
  check_raises "type error: bool < int"
    (fun () -> Pipeline.type_of "true < 1");

  (* --- runtime errors (process, no type check) --- *)
  check_raises "lex error: '@'"      (fun () -> Pipeline.process "1 + @");
  check_raises "parse error: empty"  (fun () -> Pipeline.process "");

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
