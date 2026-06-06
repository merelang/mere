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
  (* version smoke *)
  check "version is 0.1.0" Version.v "0.1.0";

  (* arithmetic *)
  check "'42'"             (Pipeline.process "42")             "42";
  check "'1 + 2'"          (Pipeline.process "1 + 2")          "3";
  check "'2 * 3 + 4'"      (Pipeline.process "2 * 3 + 4")      "10";
  check "'2 + 3 * 4'"      (Pipeline.process "2 + 3 * 4")      "14";
  check "'(2 + 3) * 4'"    (Pipeline.process "(2 + 3) * 4")    "20";
  check "'10 - 3 - 2'"     (Pipeline.process "10 - 3 - 2")     "5";
  check "'-(2 + 3)'"       (Pipeline.process "-(2 + 3)")       "-5";
  check "'-5 + 3'"         (Pipeline.process "-5 + 3")         "-2";

  (* line comments *)
  check "leading comment"  (Pipeline.process "// note\n42")    "42";
  check "trailing comment" (Pipeline.process "1 + 2 // sum")   "3";

  (* let bindings *)
  check "'let x = 5 in x + 1'"
    (Pipeline.process "let x = 5 in x + 1") "6";
  check "'let x = 5 in let y = 10 in x * y'"
    (Pipeline.process "let x = 5 in let y = 10 in x * y") "50";
  check "inner shadow"
    (Pipeline.process "let x = 1 in (let x = 2 in x)") "2";
  check "outer x preserved"
    (Pipeline.process "let x = 1 in (let x = 2 in x) + x") "3";
  check "multi-char ident"
    (Pipeline.process "let foo = 7 in foo * foo") "49";
  check "let with comment"
    (Pipeline.process "let x = 5 // bound\nin x + 1") "6";

  (* pretty print *)
  check "pp '1 + 2 * 3'"
    (Ast.pp (Pipeline.parse_only "1 + 2 * 3"))
    "(1 + (2 * 3))";
  check "pp let"
    (Ast.pp (Pipeline.parse_only "let x = 5 in x + 1"))
    "(let x = 5 in (x + 1))";

  (* errors *)
  check_raises "lex error: '@'"            (fun () -> Pipeline.process "1 + @");
  check_raises "parse error: trailing"     (fun () -> Pipeline.process "1 2");
  check_raises "parse error: missing )"    (fun () -> Pipeline.process "(1 + 2");
  check_raises "parse error: empty"        (fun () -> Pipeline.process "");
  check_raises "eval error: unbound var"   (fun () -> Pipeline.process "x + 1");
  check_raises "parse error: let no in"    (fun () -> Pipeline.process "let x = 5");
  check_raises "parse error: let no eq"    (fun () -> Pipeline.process "let x 5 in x");

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
