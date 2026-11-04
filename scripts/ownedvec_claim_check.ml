(* Exercise the interpreter runtime directly: no evaluator call-stack state or
   frontend move analysis stands between the two competing domains and ov_use. *)
module E = Mere.Eval

type outcome = Won of E.value | Rejected | Unexpected of exn
exception Double_acquisition of string

let apply f x = !E.apply_value_ref f x
let require condition message = if not condition then failwith message
let ownership_prefixes = List.map (fun op -> op ^ ": an OwnedVec belongs to one thread")
  ["claim_probe"; "owned_vec_len"; "owned_vec_get"; "owned_vec_push"; "owned_vec_to_vec"; "show"; "to_json"]

let attempt f =
  try Won (f ()) with
  | E.Eval_error (_, message) when
      List.exists (fun prefix -> String.starts_with ~prefix message) ownership_prefixes -> Rejected
  | exn -> Unexpected exn

let operations = ["direct"; "len"; "generic_len"; "get"; "push"; "convert"; "show"; "to_json"]

let operation name storage length () =
  let vector = E.V_vec storage in
  match name with
  | "direct" -> E.ov_use "claim_probe" storage; E.V_unit
  | "len" -> apply E.builtin_owned_vec_len vector
  | "generic_len" -> apply E.builtin_len vector
  | "get" ->
    (try apply (apply E.builtin_owned_vec_get vector) (E.V_int 0) with
     | E.Eval_error (_, message) when length = 0 && String.starts_with ~prefix:"owned_vec_get: index" message ->
       (* A failed lookup must still claim empty storage before checking bounds. *)
       E.V_unit)
  | "push" -> apply (apply E.builtin_owned_vec_push vector) (E.V_int (E.owner_now ()))
  | "convert" -> apply E.builtin_owned_vec_to_vec vector
  | "show" -> apply E.builtin_show vector
  | "to_json" -> apply E.builtin_to_json vector
  | _ -> failwith "unknown operation"

let reset storage length =
  storage.E.vc_data <- Array.make 4 E.V_unit;
  if length = 1 then storage.E.vc_data.(0) <- E.V_int 7;
  storage.E.vc_len <- length;
  E.ov_release storage;
  require (Atomic.get storage.E.vc_owner = E.ov_released) "release did not publish the unclaimed state"

let verify name storage length winner value =
  require (Atomic.get storage.E.vc_owner = winner) "the recorded owner is not the winner";
  let expected_length = length + if name = "push" then 1 else 0 in
  require (storage.E.vc_len = expected_length) "storage length changed incorrectly";
  if length = 1 then require (storage.E.vc_data.(0) = E.V_int 7) "existing element changed";
  let valid = match name, value with
    | "direct", E.V_unit -> true
    | ("len" | "generic_len"), E.V_int n -> n = length
    | "get", E.V_unit -> length = 0
    | "get", E.V_int 7 -> length = 1
    | "push", E.V_unit -> storage.E.vc_data.(length) = E.V_int winner
    | "convert", E.V_vec copy ->
      not copy.E.vc_owned && Atomic.get copy.E.vc_owner = winner && copy.E.vc_len = length &&
      (length = 0 || copy.E.vc_data.(0) = E.V_int 7)
    | "show", E.V_str text -> text = (if length = 0 then "Vec[]" else "Vec[7]")
    | "to_json", E.V_str text -> text = (if length = 0 then "[]" else "[7]")
    | _ -> false in
  require valid (name ^ ": incorrect result")

let publication name length =
  let storage = E.vecbuf_empty ~owned:true () in
  reset storage length;
  let winner, result = Domain.join (Domain.spawn (fun () ->
    E.owner_now (), operation name storage length ())) in
  verify name storage length winner result;
  match attempt (operation name storage length) with
  | Rejected -> ()
  | Unexpected exn -> raise exn
  | Won _ -> failwith "a later foreign operation was accepted"

let race ~poison name length rounds =
  let storage = E.vecbuf_empty ~owned:true () in
  let phase = Atomic.make 0 and completed = Atomic.make 0 in
  let entered = Atomic.make 0 and loaded = Atomic.make 0 in
  let other_id = Atomic.make (-1) in
  let result = ref Rejected in
  let rendezvous counter =
    ignore (Atomic.fetch_and_add counter 1);
    while Atomic.get counter <> 2 do Domain.cpu_relax () done in
  let compete () =
    rendezvous entered;
    attempt (fun () ->
      if poison then begin
        (* Deliberately unsafe reference control, confined to this test binary.
           Force both readers between load and store to validate the observer. *)
        let previous = Atomic.get storage.E.vc_owner in
        require (previous = E.ov_released) "unsafe control did not observe released storage";
        rendezvous loaded;
        Atomic.set storage.E.vc_owner (E.owner_now ());
        E.V_unit
      end else operation name storage length ()) in
  let worker = Domain.spawn (fun () ->
    Atomic.set other_id (E.owner_now ());
    let rec loop previous =
      let rec wait () =
        let next = Atomic.get phase in
        if next = previous then (Domain.cpu_relax (); wait ()) else next in
      let next = wait () in
      if next >= 0 then begin
        result := compete ();
        Atomic.set completed next;
        loop next
      end in
    loop 0) in
  Fun.protect ~finally:(fun () -> Atomic.set phase (-1); Domain.join worker) (fun () ->
    for round = 1 to rounds do
      reset storage length;
      Atomic.set entered 0;
      Atomic.set loaded 0;
      Atomic.set phase round;
      let mine = compete () in
      while Atomic.get completed <> round do Domain.cpu_relax () done;
      require (Atomic.get other_id <> E.owner_now ()) "the contenders have the same identity";
      let winner, value = match mine, !result with
        | Won _, Won _ -> raise (Double_acquisition (Printf.sprintf "%s length=%d round=%d" name length round))
        | Won value, Rejected -> E.owner_now (), value
        | Rejected, Won value -> Atomic.get other_id, value
        | Unexpected exn, _ | _, Unexpected exn -> raise exn
        | Rejected, Rejected -> failwith "neither contender acquired released storage" in
      verify name storage length winner value
    done)

let () =
  try
    if Array.length Sys.argv > 1 then begin
      require (Array.to_list Sys.argv = [Sys.argv.(0); "--poison"]) "unknown arguments";
      race ~poison:true "direct" 0 1;
      failwith "the unsafe reference control was accepted"
    end;
    let rounds = ref 0 in
    List.iter (fun name ->
      List.iter (fun length ->
        publication name length;
        let count = if name = "direct" then 20_000 else 2_000 in
        race ~poison:false name length count;
        rounds := !rounds + count;
        Printf.printf "  ok    %s length=%d: publication and %d races\n%!" name length count
      ) [0; 1]
    ) operations;
    let vector = E.vecbuf_empty () in
    let creator = E.owner_now () in
    Domain.join (Domain.spawn (fun () -> E.read_vec vector));
    E.read_vec vector;
    require (Atomic.get vector.E.vc_owner = creator lor E.shared_bit) "Vec read lost its shared bit";
    require (!rounds = 68_000) "some races did not run";
    Printf.printf "ownedvec_claim: ok (16 publication checks, %d races, Vec sharing)\n%!" !rounds
  with
  | Double_acquisition details ->
    Printf.eprintf "ownedvec_claim: DOUBLE_ACQUISITION %s\n%!" details;
    exit 1
  | exn ->
    Printf.eprintf "ownedvec_claim: FAIL %s\n%!" (Printexc.to_string exn);
    exit 2
