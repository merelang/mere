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
  check "let basic"        (Pipeline.process "let x = 5 in x + 1") "6";
  check "twice"
    (Pipeline.process "let twice = fn f -> fn x -> f (f x) in twice (fn x -> x + 1) 5") "7";
  check "factorial"
    (Pipeline.process "let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 6") "720";
  check "type 'fn x -> x'"
    (Pipeline.type_of "fn x -> x") "('a -> 'a)";

  (* --- string literals --- *)
  check "string literal"
    (Pipeline.process "\"hello\"") "\"hello\"";
  check "escape \\n in literal"
    (Pipeline.process "\"a\\nb\"") "\"a\\nb\"";
  check "type of string"
    (Pipeline.type_of "\"hello\"") "str";

  (* --- string concat ++ --- *)
  check "str concat"
    (Pipeline.process "\"hello\" ++ \", world\"") "\"hello, world\"";
  check "str concat 3 parts"
    (Pipeline.process "\"a\" ++ \"b\" ++ \"c\"") "\"abc\"";
  check "type of concat"
    (Pipeline.type_of "\"hello\" ++ \"world\"") "str";

  (* --- string equality --- *)
  check "str eq true"
    (Pipeline.process "\"abc\" == \"abc\"") "true";
  check "str eq false"
    (Pipeline.process "\"abc\" == \"xyz\"") "false";

  (* --- unit literal --- *)
  check "unit literal"      (Pipeline.process "()") "()";
  check "type of unit"      (Pipeline.type_of "()") "unit";

  (* --- print builtin (note: stdout side effect not captured here) --- *)
  check "type of print"     (Pipeline.type_of "print") "(str -> unit)";
  check "print returns unit"
    (Pipeline.process "print \"hello\"") "()";

  (* --- bind a string in let --- *)
  check "let str"
    (Pipeline.process "let greet = fn who -> \"hello, \" ++ who in greet \"world\"") "\"hello, world\"";

  (* --- top decls with strings --- *)
  check "top decl strings"
    (Pipeline.process "let greet = fn name -> \"Hi, \" ++ name; greet \"Alice\"") "\"Hi, Alice\"";

  (* --- type errors --- *)
  check_raises "type error: str + int"
    (fun () -> Pipeline.type_of "\"x\" + 1");
  check_raises "type error: int ++ str"
    (fun () -> Pipeline.type_of "1 ++ \"x\"");
  check_raises "type error: print on int"
    (fun () -> Pipeline.type_of "print 5");
  check_raises "type error: str < str"
    (fun () -> Pipeline.type_of "\"a\" < \"b\"");
  check_raises "lex error: unterminated string"
    (fun () -> Pipeline.process "\"unterminated");
  check_raises "lex error: unknown escape"
    (fun () -> Pipeline.process "\"\\q\"");

  (* --- pp --- *)
  check "pp string"
    (Ast.pp (Pipeline.parse_only "\"hi\"")) "\"hi\"";
  check "pp unit"
    (Ast.pp (Pipeline.parse_only "()")) "()";
  check "pp ++"
    (Ast.pp (Pipeline.parse_only "\"a\" ++ \"b\"")) "(\"a\" ++ \"b\")";

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
