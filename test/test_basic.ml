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

  (* arithmetic *)
  check "'42'"             (Pipeline.process "42")             "42";
  check "'1 + 2'"          (Pipeline.process "1 + 2")          "3";
  check "'2 + 3 * 4'"      (Pipeline.process "2 + 3 * 4")      "14";
  check "'(2 + 3) * 4'"    (Pipeline.process "(2 + 3) * 4")    "20";
  check "'10 - 3 - 2'"     (Pipeline.process "10 - 3 - 2")     "5";
  check "'-(2 + 3)'"       (Pipeline.process "-(2 + 3)")       "-5";

  (* comments *)
  check "leading comment"  (Pipeline.process "// note\n42")    "42";
  check "trailing comment" (Pipeline.process "1 + 2 // sum")   "3";

  (* let bindings *)
  check "let basic"
    (Pipeline.process "let x = 5 in x + 1") "6";
  check "nested let"
    (Pipeline.process "let x = 5 in let y = 10 in x * y") "50";
  check "inner shadow"
    (Pipeline.process "let x = 1 in (let x = 2 in x)") "2";

  (* boolean literals *)
  check "true literal"     (Pipeline.process "true")  "true";
  check "false literal"    (Pipeline.process "false") "false";

  (* comparison *)
  check "'1 < 2'"          (Pipeline.process "1 < 2")  "true";
  check "'2 < 1'"          (Pipeline.process "2 < 1")  "false";
  check "'1 == 1'"         (Pipeline.process "1 == 1") "true";
  check "'1 == 2'"         (Pipeline.process "1 == 2") "false";
  check "'true == true'"   (Pipeline.process "true == true")  "true";
  check "'true == false'"  (Pipeline.process "true == false") "false";
  check "comparison after arith"
    (Pipeline.process "1 + 2 < 4")  "true";
  check "comparison after arith eq"
    (Pipeline.process "2 * 3 == 6") "true";

  (* if-else *)
  check "'if true then 1 else 2'"
    (Pipeline.process "if true then 1 else 2") "1";
  check "'if false then 1 else 2'"
    (Pipeline.process "if false then 1 else 2") "2";
  check "if with comparison"
    (Pipeline.process "if 1 < 2 then 100 else 200") "100";
  check "if + let combo"
    (Pipeline.process "let x = 5 in if x < 10 then x * 2 else 0") "10";
  check "nested if (max-like)"
    (Pipeline.process "let a = 7 in let b = 3 in if a < b then b else a") "7";

  (* pretty print *)
  check "pp if"
    (Ast.pp (Pipeline.parse_only "if 1 < 2 then 3 else 4"))
    "(if (1 < 2) then 3 else 4)";
  check "pp bool"
    (Ast.pp (Pipeline.parse_only "true"))
    "true";

  (* errors *)
  check_raises "lex error: '@'"            (fun () -> Pipeline.process "1 + @");
  check_raises "parse error: trailing"     (fun () -> Pipeline.process "1 2");
  check_raises "parse error: missing )"    (fun () -> Pipeline.process "(1 + 2");
  check_raises "parse error: empty"        (fun () -> Pipeline.process "");
  check_raises "eval error: unbound var"   (fun () -> Pipeline.process "x + 1");
  check_raises "parse error: let no in"    (fun () -> Pipeline.process "let x = 5");
  check_raises "parse error: if no then"   (fun () -> Pipeline.process "if true 1 else 2");
  check_raises "parse error: if no else"   (fun () -> Pipeline.process "if true then 1");
  check_raises "type error: int + bool"    (fun () -> Pipeline.process "1 + true");
  check_raises "type error: if int cond"   (fun () -> Pipeline.process "if 5 then 1 else 2");
  check_raises "type error: bool < int"    (fun () -> Pipeline.process "true < 1");

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
