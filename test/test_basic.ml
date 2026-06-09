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
  check "string concat"
    (Pipeline.process "\"a\" ++ \"b\"") "\"ab\"";

  (* --- sum types: declaration and use --- *)
  check "type decl + nullary constr"
    (Pipeline.process "type opt = None | Some of int; None") "None";
  check "type decl + unary constr"
    (Pipeline.process "type opt = None | Some of int; Some 5") "Some 5";
  check "type checks 'Some'"
    (Pipeline.type_of "type opt = None | Some of int; Some 5") "opt";
  check "type checks 'None'"
    (Pipeline.type_of "type opt = None | Some of int; None") "opt";

  (* --- match expression --- *)
  check "match Some"
    (Pipeline.process
      "type opt = None | Some of int;
       match Some 5 with | None -> 0 | Some n -> n + 1") "6";
  check "match None"
    (Pipeline.process
      "type opt = None | Some of int;
       match None with | None -> 0 | Some n -> n + 1") "0";
  check "match with let-bound scrut"
    (Pipeline.process
      "type opt = None | Some of int;
       let x = Some 10;
       match x with | None -> 0 | Some n -> n * 2") "20";

  (* --- wildcard and literal patterns --- *)
  check "match wildcard"
    (Pipeline.process
      "type sign = Pos | Neg | Zero;
       match Pos with | Zero -> 0 | _ -> 1") "1";
  check "match int literal pattern"
    (Pipeline.process
      "match 5 with | 0 -> \"zero\" | 5 -> \"five\" | _ -> \"other\"") "\"five\"";
  check "match bool pattern"
    (Pipeline.process
      "match true with | true -> 1 | false -> 0") "1";

  (* --- safe_div using sum types --- *)
  check "safe_div success"
    (Pipeline.process
      "type opt = None | Some of int;
       let safe_div = fn a -> fn b -> if b == 0 then None else Some (a * 100);
       match safe_div 5 2 with | None -> -1 | Some n -> n") "500";
  check "safe_div by zero"
    (Pipeline.process
      "type opt = None | Some of int;
       let safe_div = fn a -> fn b -> if b == 0 then None else Some (a * 100);
       match safe_div 5 0 with | None -> -1 | Some n -> n") "-1";

  (* --- type errors --- *)
  check_raises "constructor mismatch"
    (fun () -> Pipeline.process
       "type opt = None | Some of int; Some true");
  check_raises "unknown constructor"
    (fun () -> Pipeline.process
       "type opt = None | Some of int; Foo");
  check_raises "match arms inconsistent type"
    (fun () -> Pipeline.process
       "type opt = None | Some of int;
        match Some 5 with | None -> 0 | Some n -> \"oops\"");
  check_raises "constructor takes arg but given none"
    (fun () -> Pipeline.process
       "type opt = None | Some of int; Some");
  check_raises "nullary given arg"
    (fun () -> Pipeline.process
       "type opt = None | Some of int; None 5");

  (* --- runtime: match fallthrough (when no pattern matches; type check should normally prevent) --- *)
  (* match int with only specific values, no wildcard -> may fallthrough at runtime *)
  check_raises "non-exhaustive int match"
    (fun () -> Pipeline.process
       "match 99 with | 0 -> 0 | 1 -> 1");

  (* --- pp --- *)
  check "pp Constr"
    (Ast.pp (Pipeline.parse_only
       "type opt = None | Some of int; Some 5"))
    "(Some 5)";
  check "pp Match"
    (Ast.pp (Pipeline.parse_only
       "type opt = None | Some of int;
        match None with | None -> 0 | Some n -> n"))
    "(match None with | None -> 0 | Some n -> n)";

  Printf.printf "\n%d passed, %d failed\n" !pass !fail;
  if !fail > 0 then exit 1
