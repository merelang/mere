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

  (* basic eval through pipeline *)
  check "'42'"             (Pipeline.process "42")             "42";
  check "'1 + 2'"          (Pipeline.process "1 + 2")          "3";
  check "'2 * 3 + 4'"      (Pipeline.process "2 * 3 + 4")      "10";
  check "'2 + 3 * 4'"      (Pipeline.process "2 + 3 * 4")      "14";
  check "'(2 + 3) * 4'"    (Pipeline.process "(2 + 3) * 4")    "20";
  check "'10 - 3 - 2'"     (Pipeline.process "10 - 3 - 2")     "5";
  check "'-(2 + 3)'"       (Pipeline.process "-(2 + 3)")       "-5";
  check "'-5 + 3'"         (Pipeline.process "-5 + 3")         "-2";
  check "'  42  '"         (Pipeline.process "  42  ")         "42";

  (* line comments *)
  check "leading comment"  (Pipeline.process "// note\n42")    "42";
  check "trailing comment" (Pipeline.process "1 + 2 // sum")   "3";
  check "comment between"  (Pipeline.process "1 +\n// add two\n2") "3";

  (* pretty print through parse *)
  check "pp '1 + 2 * 3'"
    (Ast.pp (Pipeline.parse_only "1 + 2 * 3"))
    "(1 + (2 * 3))";
  check "pp '(1 + 2) * 3'"
    (Ast.pp (Pipeline.parse_only "(1 + 2) * 3"))
    "((1 + 2) * 3)";

  (* errors *)
  check_raises "lex error: '@'"  (fun () -> Pipeline.process "1 + @");
  check_raises "parse error: trailing" (fun () -> Pipeline.process "1 2");
  check_raises "parse error: missing )" (fun () -> Pipeline.process "(1 + 2");
  check_raises "parse error: empty"     (fun () -> Pipeline.process "");

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
