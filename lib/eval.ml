(* Tree-walking interpreter. *)

exception Eval_error of Loc.t * string

(* v0.1.271: how deep a Mere program may recurse in the interpreter.
   OCaml 5 grows the main fibre's stack by copying it, so past about a million
   frames the cost stops being the program's and becomes the copying's: 1M
   frames take 0.9s, 2M take 3.1s, and 10M take 68s before the host finally
   raises Stack_overflow. That is not a limit anyone can use -- a program that
   recurses that deep has already failed on every compiled backend, where the
   stack runs out two orders of magnitude earlier -- so the interpreter says so
   at a depth it can still say it quickly.
   MERE_MAX_DEPTH raises or lowers it for a program that genuinely wants the
   host's own ceiling. *)
let max_depth =
  ref
    (match Sys.getenv_opt "MERE_MAX_DEPTH" with
     | Some s -> (try int_of_string s with _ -> 1_000_000)
     | None -> 1_000_000)

let call_depth = ref 0

type value =
  | V_int of int
  | V_float of float
  | V_bool of bool
  | V_str of string
  | V_bytes of string
    (* immutable raw byte sequence (a first-class binary type). Held as an OCaml string
       (which carries NULs), so binary-safe; distinct from V_str at the type
       level so codegen picks the length-prefixed representation. *)
  | V_unit
  | V_closure of string * Ast.expr * env
  | V_builtin of string * (value -> value)
  | V_constr of string * value option
  | V_tuple of value list
  | V_record of string * (string * value) list
  | V_vec of vecbuf
    (* `'a Vec` — region-aware growable vector (Phase 12.1, Q-010
       narrowed -> first implementation stage). Backed by a capacity-carrying
       buffer (`vecbuf` below), so push is amortised O(1).
       Trivial[R] when element type is Trivial[R]. *)
  | V_strbuf of Buffer.t
  (* A mutable byte buffer: one byte per byte, random access, and growable.
     `StrBuf` is the same shape for text and cannot serve — it appends only, and a
     string ends at a zero byte in the compiled backends. `Vec[R, int]` can do the
     access but costs eight bytes per byte. What needed this was reconstructing a
     PNG scanline, which reads the row above it and writes the row it is on. *)
  | V_bytebuf of bytebuf
    (* `StrBuf[R]` — region-aware mutable string buffer (Phase 12.7,
       Q-010 narrowed). Minimal implementation of design doc
       13_region_std_types.md §4. Internally an OCaml Buffer holding
       the string's bytes. Treated as Trivial, so it can live in a
       region. The type is TyCon ("StrBuf", [TyRef BR R TyUnit])
       (1-arg region marker, the same convention as view types). *)
  | V_map of map_state
    (* `Map[R, K, V]` — region-aware mutable associative map (Phase 12.10,
       Q-010 narrowed). Minimal implementation of design doc
       13_region_std_types.md §5. Internally an OCaml Hashtbl using
       polymorphic hash / eq (note: keys containing closures / refs are
       identified per-ref). The type is TyCon ("Map",
       [TyRef BR R TyUnit; K; V]).
       Phase 27.1: the 2nd component tracks insertion order (so map_iter
       iterates deterministically). Stored newest-first for O(1) prepend
       on insert; readers reverse it. The Hashtbl gives O(1) lookup, so a
       map fills in O(n) rather than the old O(n^2) (`@ [k]` append). *)
  | V_channel of value Queue.t * Mutex.t * Condition.t * bool ref
  | V_file of in_channel                (* v0.1.59: streaming file read *)
  | V_rwfile of Unix.file_descr         (* v0.1.115: read/write handle (file_openrw / file_pwrite / file_pread) *)
    (* v0.1.47: the bool ref is the "closed" flag for graceful shutdown.
       channel_close sets it; channel_recv_opt returns None once the
       channel is closed and drained (workers can then return and be
       joined). *)
    (* `Channel[T]` — blocking FIFO queue for cross-thread communication
       (Q-012 step 3a, concurrency narrowing Sub-Q C). Guarded by a
       Mutex; channel_recv blocks on the Condition until an element is
       available. Send/Sync type checking is minimal at this stage
       (the interp shares the OCaml heap and leaves races to the GC);
       the full trait check lands with the C backend, where shared
       memory makes data races real. *)
  | V_thread of value Domain.t
    (* `ThreadHandle` — a worker spawned on a fresh OCaml 5 domain
       (Sub-Q A: OS-thread / Domain-like). `join` blocks on Domain.join.
       The domain runs the `unit -> unit` closure passed to `spawn`. *)

(* Q-063: the interpreter's Map, with the same tombstone discipline the C
   backend got in v0.1.317. `m_order` is newest-first and APPEND-ONLY: a delete
   touches only the hash table, so it costs O(1) instead of the O(live)
   `List.filter` this used to do. The list therefore accumulates keys that are
   no longer present, and keys present more than once (deleted and re-inserted),
   so every reader walks it newest-first and keeps the FIRST occurrence of each
   key that is still in `m_tbl` -- which puts a re-inserted key at its new
   position, matching the compiled backends. `m_order_n` exists so the
   compaction trigger does not have to call List.length, which would put the
   O(live) back where it was taken from. *)
and map_state = {
  m_tbl : (value, value) Hashtbl.t;
  mutable m_order : value list;
  mutable m_order_n : int;
}

and bytebuf = { mutable bb_data : Bytes.t; mutable bb_len : int }

(* v0.1.349: a Vec's storage, with capacity. Slots [0, vc_len) are live and
   the rest is V_unit filler, so `vec_push` doubles instead of reallocating.
   It was `value array ref` with an `Array.append` per push -- O(n) per push,
   so filling an n-element Vec cost O(n^2) HERE while every compiled backend
   was already amortised. That asymptotic sat in the parity oracle, which is
   what bounds the input size a differential gate can afford: 200k pushes took
   74s interpreted and 0.01s compiled. *)
and vecbuf = { mutable vc_data : value array; mutable vc_len : int }

and env = (string * value ref) list

let vecbuf_of_array (a : value array) : vecbuf =
  { vc_data = a; vc_len = Array.length a }

let vecbuf_empty () : vecbuf = { vc_data = [||]; vc_len = 0 }

(* The live prefix as an array. Copy-free when the buffer happens to be exactly
   full, so the result is READ-ONLY -- a caller that mutates must go through
   vc_data / vc_len instead (vec_reverse, vec_set and vec_sort do). *)
let vecbuf_live (v : vecbuf) : value array =
  if v.vc_len = Array.length v.vc_data then v.vc_data
  else Array.sub v.vc_data 0 v.vc_len

let vecbuf_push (v : vecbuf) (x : value) : unit =
  if v.vc_len = Array.length v.vc_data then begin
    let cap = if v.vc_len = 0 then 8 else v.vc_len * 2 in
    let d = Array.make cap V_unit in
    Array.blit v.vc_data 0 d 0 v.vc_len;
    v.vc_data <- d
  end;
  v.vc_data.(v.vc_len) <- x;
  v.vc_len <- v.vc_len + 1

(* hex <-> raw byte string, shared by bytes display / to_json
   and the bytes_of_hex / hex_of_bytes builtins. Lowercase, 2 chars per byte. *)
(* Q-063: the live keys of a map, oldest-first. Walks `m_order` newest-first
   keeping the first occurrence of each key still present, then reverses -- so
   a key deleted and re-inserted appears once, at the position of its LATEST
   insertion, which is where the compiled backends put it. *)
let map_live_keys (m : map_state) : value list =
  (* The common case is a map that has never been deleted from, where the list
     is already exactly the live keys: skip building a dedup table for it, so
     iteration does not pay for a facility only churn needs. *)
  if m.m_order_n = Hashtbl.length m.m_tbl then List.rev m.m_order else
  let seen = Hashtbl.create (Hashtbl.length m.m_tbl * 2 + 1) in
  let out = ref [] in
  List.iter (fun k ->
    if Hashtbl.mem m.m_tbl k && not (Hashtbl.mem seen k) then begin
      Hashtbl.replace seen k ();
      out := k :: !out
    end) m.m_order;
  !out

(* Drop the stale and duplicate entries when they outnumber the live ones, so
   the append-only list stays proportional to the live set rather than to the
   number of writes. O(order) once per O(live) deletes, i.e. amortised O(1) --
   the same trade as the C backend's squeeze. *)
let map_maybe_compact (m : map_state) : unit =
  let live = Hashtbl.length m.m_tbl in
  if m.m_order_n > 2 * live + 8 then begin
    let oldest_first = map_live_keys m in
    m.m_order <- List.rev oldest_first;
    m.m_order_n <- List.length m.m_order
  end

let hex_of_string (s : string) : string =
  let b = Buffer.create (String.length s * 2) in
  String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents b

let string_of_hex (h : string) : string =
  let n = String.length h in
  if n mod 2 <> 0 then failwith "bytes_of_hex: odd-length hex string";
  let hexval c =
    match c with
    | '0'..'9' -> Char.code c - Char.code '0'
    | 'a'..'f' -> Char.code c - Char.code 'a' + 10
    | 'A'..'F' -> Char.code c - Char.code 'A' + 10
    | _ -> failwith "bytes_of_hex: non-hex character"
  in
  let b = Buffer.create (n / 2) in
  let i = ref 0 in
  while !i < n do
    Buffer.add_char b (Char.chr (hexval h.[!i] * 16 + hexval h.[!i + 1]));
    i := !i + 2
  done;
  Buffer.contents b

(* v0.1.12 (N4): float → string, normalized to a trailing ".0" for
   whole-valued floats ("550.0"). Kept identical to the C runtime
   (__lang_str_of_float), the LLVM helper, and the Wasm JS host so all
   backends agree.

   v0.1.65 (mere-ruby dogfood): shortest ROUND-TRIP formatting. The old
   %.12g (OCaml string_of_float) lost information: 0.1 + 0.2 printed as
   "0.3", and float_of_str could not get the original back. Try %.12g
   first — every value it already represented faithfully keeps its exact
   old rendering — then widen toward %.17g until the string parses back
   to the same double (Ruby / JS / Python print floats this way). *)
let format_float f =
  let rec go p =
    let s = Printf.sprintf "%.*g" p f in
    if p >= 17 then s
    else if (try float_of_string s = f with _ -> false) then s
    else go (p + 1)
  in
  let s = go 12 in
  if String.contains s '.' || String.contains s 'e' || String.contains s 'E'
     || String.contains s 'n' || String.contains s 'i'
  then s
  else s ^ ".0"

(* Try to interpret a value as a Nil-terminated Cons chain.
   Returns Some [v1; v2; ...] when the value walks all the way to Nil,
   None otherwise (mid-chain shape mismatch or non-Cons head). *)
let rec try_as_list = function
  | V_constr ("Nil", None) -> Some []
  | V_constr ("Cons", Some (V_tuple [h; tail])) ->
    (match try_as_list tail with
     | Some rest -> Some (h :: rest)
     | None -> None)
  | _ -> None

and to_string = function
  | V_int n -> string_of_int n
  | V_bytes s -> "bytes[" ^ hex_of_string s ^ "]"
  | V_bytebuf b -> "bytebuf[" ^ hex_of_string (Bytes.sub_string b.bb_data 0 b.bb_len) ^ "]"
  | V_float f -> format_float f
  | V_bool b -> if b then "true" else "false"
  | V_str s -> Ast.escape_string s
  | V_unit -> "()"
  | V_closure (param, _, _) -> "<closure:" ^ param ^ ">"
  | V_builtin (name, _) -> "<builtin:" ^ name ^ ">"
  (* Cons/Nil chain -> `[a, b, c]` notation when the chain is well-formed. *)
  | V_constr ("Nil", None) -> "[]"
  | V_constr ("Cons", Some (V_tuple [_; _])) as v ->
    (match try_as_list v with
     | Some elems ->
       "[" ^ String.concat ", " (List.map to_string elems) ^ "]"
     | None ->
       (* Fallback: malformed chain (e.g. user-defined non-list Cons) *)
       (match v with
        | V_constr (name, Some inner) -> name ^ " " ^ to_string inner
        | _ -> assert false))
  | V_constr (name, None) -> name
  | V_constr (name, Some v) -> name ^ " " ^ to_string v
  | V_tuple vs ->
    "(" ^ String.concat ", " (List.map to_string vs) ^ ")"
  | V_record (name, fields) ->
    let parts = List.map (fun (f, v) -> f ^ " = " ^ to_string v) fields in
    name ^ " { " ^ String.concat ", " parts ^ " }"
  | V_vec arr ->
    let elems = Array.to_list (vecbuf_live arr) in
    "Vec[" ^ String.concat ", " (List.map to_string elems) ^ "]"
  | V_strbuf buf ->
    "StrBuf[" ^ Ast.escape_string (Buffer.contents buf) ^ "]"
  | V_map m ->
    let parts = List.map (fun k ->
      let v = Hashtbl.find m.m_tbl k in
      to_string k ^ " => " ^ to_string v) (map_live_keys m) in
    "Map[" ^ String.concat ", " parts ^ "]"
  | V_channel _ -> "<channel>"
  | V_file _ -> "<file>"
  | V_rwfile _ -> "<file>"
  | V_thread _ -> "<thread>"

(* `to_json x` — structural JSON serialization of any value, the derive-y
   sibling of `show` (compile-time-specialized ad-hoc polymorphism, no trait
   machinery). Records drop their type name and become JSON objects
   (`Post { id = 1; title = "hi" }` -> `{"id":1,"title":"hi"}`), lists/tuples
   become arrays, and a variant becomes `"Name"` (nullary) or
   `{"Name": payload}`. Motivated by the mere-blog dogfood (PAIN B3): hand-
   written record->JSON writers collapse to `to_json x`. *)
and to_json_string = function
  | V_int n -> string_of_int n
  | V_bytes s -> "\"" ^ hex_of_string s ^ "\""  (* JSON has no byte type: hex string *)
  | V_bytebuf b ->
    "\"" ^ hex_of_string (Bytes.sub_string b.bb_data 0 b.bb_len) ^ "\""
  | V_float f -> format_float f
  | V_bool b -> if b then "true" else "false"
  | V_str s -> Ast.escape_string s
  | V_unit -> "null"
  | V_closure _ | V_builtin _ | V_channel _ | V_thread _ | V_file _ | V_rwfile _ -> "null"
  | V_constr ("Nil", None) -> "[]"
  | V_constr ("Cons", Some (V_tuple [_; _])) as v ->
    (match try_as_list v with
     | Some elems ->
       "[" ^ String.concat "," (List.map to_json_string elems) ^ "]"
     | None ->
       (match v with
        | V_constr (name, Some inner) ->
          "{" ^ Ast.escape_string name ^ ":" ^ to_json_string inner ^ "}"
        | _ -> assert false))
  (* option is a transparent JSON nullable: None -> null, Some x -> x. This is
     the idiomatic API encoding and keeps `of_json` symmetric (a nullable /
     omittable field round-trips). Other variants stay tagged. *)
  | V_constr ("None", None) -> "null"
  | V_constr ("Some", Some v) -> to_json_string v
  | V_constr (name, None) -> Ast.escape_string name
  | V_constr (name, Some v) ->
    "{" ^ Ast.escape_string name ^ ":" ^ to_json_string v ^ "}"
  | V_tuple vs ->
    "[" ^ String.concat "," (List.map to_json_string vs) ^ "]"
  | V_record (_, fields) ->
    let parts =
      List.map (fun (f, v) ->
        Ast.escape_string f ^ ":" ^ to_json_string v) fields in
    "{" ^ String.concat "," parts ^ "}"
  | V_vec arr ->
    "[" ^ String.concat "," (List.map to_json_string (Array.to_list (vecbuf_live arr))) ^ "]"
  | V_strbuf buf -> Ast.escape_string (Buffer.contents buf)
  | V_map m ->
    let parts = List.map (fun k ->
      let v = Hashtbl.find m.m_tbl k in
      (* JSON object keys must be strings: use the key's string form. *)
      let ks = match k with V_str s -> s | _ -> to_string k in
      Ast.escape_string ks ^ ":" ^ to_json_string v) (map_live_keys m) in
    "{" ^ String.concat "," parts ^ "}"

let type_error loc msg = raise (Eval_error (loc, msg))

let builtin_print =
  V_builtin ("print", fun v ->
    (match v with
     | V_str s -> print_endline s
     | _ -> failwith "print: expected str");
    V_unit)

(* Capability constructors. Each cap field is a V_builtin closure that
   captures the constructor's parameters (e.g., logger prefix) and
   performs the I/O via print_endline. *)
let builtin_mk_logger =
  V_builtin ("mk_logger", fun v ->
    match v with
    | V_str prefix ->
      let mk_field level =
        V_builtin (level, fun msg_v ->
          (match msg_v with
           | V_str msg ->
             print_endline (prefix ^ " [" ^ level ^ "] " ^ msg)
           | _ -> failwith (level ^ ": expected str"));
          V_unit)
      in
      V_record ("Logger",
        [("info",  mk_field "INFO");
         ("warn",  mk_field "WARN");
         ("error", mk_field "ERROR")])
    | _ -> failwith "mk_logger: expected str")

let builtin_mk_metrics =
  V_builtin ("mk_metrics", fun v ->
    match v with
    | V_unit ->
      let inc_field =
        V_builtin ("inc", fun name_v ->
          (match name_v with
           | V_str name -> print_endline ("[METRIC] inc " ^ name)
           | _ -> failwith "inc: expected str");
          V_unit)
      in
      let record_field =
        V_builtin ("record", fun name_v ->
          match name_v with
          | V_str name ->
            V_builtin ("record_2", fun n_v ->
              (match n_v with
               | V_int n ->
                 print_endline ("[METRIC] " ^ name ^ "=" ^ string_of_int n)
               | _ -> failwith "record: 2nd arg expected int");
              V_unit)
          | _ -> failwith "record: 1st arg expected str")
      in
      V_record ("Metrics",
        [("inc", inc_field); ("record", record_field)])
    | _ -> failwith "mk_metrics: expected unit")

(* ---- v0.1.305: a virtual clock (opt-in, MERE_VIRTUAL_CLOCK=1) ------------

   The rule is Go's testing/synctest rule: WHEN EVERY LIVE THREAD IS PARKED,
   NOTHING CAN HAPPEN EXCEPT TIME, so the clock jumps to the earliest pending
   deadline instead of anybody actually waiting. A test that sleeps for thirty
   virtual seconds finishes in microseconds, and the ORDER in which timers fire
   becomes a function of the program rather than of the machine's load.

   Why this is a redesign of the waits and not a patch on top of them: the
   thread-registry instrumentation marks a thread blocked and THEN parks it on
   the channel's own condition variable. Between those two steps there is a
   window, and a clock that decides "everyone is parked, advance" inside that
   window signals a condvar nobody is on yet -- the wakeup is lost, which is a
   flaky test, which is the disease a virtual clock exists to cure. So under
   the virtual clock every wait parks on ONE scheduler condvar, and "how many
   are blocked" is incremented under the SAME lock the park happens under. The
   last thread to park is the one that advances the clock.

   What routes through it: channel_recv / channel_recv_opt /
   channel_recv_timeout, sleep_ms / sleep, join, and `time` (which reads the
   virtual clock). What does not: par_map's internal joins and OS-level waits
   (stdin, sockets) -- a thread in one of those counts as running, so the clock
   conservatively refuses to advance past it. The C backend has its own runtime
   and is untouched; deterministic-time tests are an interpreter workload.

   If every live thread parks and NO deadline is pending, the program can only
   deadlock, and the run fails saying so rather than hanging -- under a virtual
   clock a hang is never the intended behaviour of a test.

   Off unless MERE_VIRTUAL_CLOCK is set: the default run of every existing
   program is byte-identical. *)
let vclock_on = Sys.getenv_opt "MERE_VIRTUAL_CLOCK" <> None
let sched_m = Mutex.create ()
let sched_cv = Condition.create ()
(* Starts at the real time of day so `time` stays epoch-shaped; only
   DIFFERENCES are deterministic, which is what tests may compare. *)
let sched_now_v = ref (Unix.gettimeofday ())
let sched_live = ref 1          (* main *)
let sched_blocked = ref 0
let sched_deadlines : float list ref = ref []

let sched_now () =
  Mutex.lock sched_m; let t = !sched_now_v in Mutex.unlock sched_m; t

(* Any state change a parked thread might be waiting on (a send, a close, a
   worker finishing) broadcasts here; waiters re-check their own predicate. *)
let sched_notify () =
  Mutex.lock sched_m; Condition.broadcast sched_cv; Mutex.unlock sched_m

let sched_add_live () =
  Mutex.lock sched_m; incr sched_live; Mutex.unlock sched_m
let sched_drop_live () =
  Mutex.lock sched_m; decr sched_live; Condition.broadcast sched_cv;
  Mutex.unlock sched_m

let sched_remove_one x l =
  let rec go acc = function
    | [] -> List.rev acc
    | y :: t when y = x -> List.rev_append acc t
    | y :: t -> go (y :: acc) t
  in go [] l

(* Park until `pred` answers true (it is called with the scheduler lock held,
   and may briefly take a channel's mutex -- lock order is scheduler first,
   channel second, everywhere). Returns false instead if `deadline` (absolute,
   in virtual seconds) arrives first. *)
let sched_wait ?deadline pred =
  Mutex.lock sched_m;
  (match deadline with
   | Some d -> sched_deadlines := d :: !sched_deadlines
   | None -> ());
  let leave r =
    (match deadline with
     | Some d -> sched_deadlines := sched_remove_one d !sched_deadlines
     | None -> ());
    Mutex.unlock sched_m; r
  in
  let rec loop () =
    if pred () then leave true
    else match deadline with
      | Some d when !sched_now_v >= d -> leave false
      | _ ->
        incr sched_blocked;
        if !sched_blocked >= !sched_live then begin
          (* I am the last one awake. Advance time or declare the deadlock. *)
          match !sched_deadlines with
          | [] ->
            decr sched_blocked;
            ignore (leave false);
            raise (Eval_error (Loc.dummy,
              "virtual clock: every live thread is blocked and no timer is \
               pending -- the program can only deadlock"))
          | ds when List.exists (fun d -> d <= !sched_now_v) ds ->
            (* A deadline has already fired; its owner was woken by the
               broadcast that advanced the clock and just has not been
               scheduled yet, so it is still counted blocked and its deadline
               is still registered. The world is not stuck -- it is mid-step.
               Advancing again from here is the spin this arm exists to stop:
               the minimum of the registered deadlines IS the expired one, so
               "advance" would set the clock to where it already is, forever,
               while holding the lock the woken thread needs to leave. Park
               instead -- parking releases the lock -- and let the owner run;
               whatever it does next (send, finish, park again) comes back
               through here. *)
            Condition.wait sched_cv sched_m;
            decr sched_blocked;
            loop ()
          | ds ->
            sched_now_v := List.fold_left min infinity ds;
            Condition.broadcast sched_cv;
            decr sched_blocked;
            loop ()
        end else begin
          Condition.wait sched_cv sched_m;
          decr sched_blocked;
          loop ()
        end
  in
  loop ()

let sched_sleep sec =
  let dl = sched_now () +. sec in
  ignore (sched_wait ~deadline:dl (fun () -> false))

let builtin_time =
  V_builtin ("time", fun v ->
    match v with
    | V_unit ->
      V_float (if vclock_on then sched_now () else Unix.gettimeofday ())
    | _ -> failwith "time: expected unit")

let builtin_exit =
  V_builtin ("exit", fun v ->
    match v with
    | V_int code -> exit code
    | _ -> failwith "exit: expected int")

let builtin_read_line =
  V_builtin ("read_line", fun v ->
    match v with
    | V_unit ->
      (try V_str (input_line stdin)
       with End_of_file -> V_str "")
    | _ -> failwith "read_line: expected unit")

let builtin_read_stdin =
  V_builtin ("read_stdin", fun v ->
    match v with
    | V_unit -> V_str (In_channel.input_all stdin)
    | _ -> failwith "read_stdin: expected unit")

(* v0.1.13 (mk dogfood): run a command line via /bin/sh, inheriting stdio,
   and return its exit code.
   v0.1.16 (mk dogfood P4): NOT Sys.command — that lowers to libc system(),
   which serializes across threads on macOS (a global lock), so `par_map
   (fn c -> run c) cmds` ran commands one at a time. fork/exec via
   Unix.create_process is thread-safe, letting `run` calls in different
   domains truly overlap. *)
let builtin_run =
  V_builtin ("run", fun v ->
    match v with
    | V_str cmd ->
      let pid =
        Unix.create_process "/bin/sh" [| "sh"; "-c"; cmd |]
          Unix.stdin Unix.stdout Unix.stderr
      in
      let (_, status) = Unix.waitpid [] pid in
      let code = match status with
        | Unix.WEXITED n -> n
        | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n
      in
      V_int code
    | _ -> failwith "run: expected str")

(* v0.1.18 (mrog dogfood): raw terminal mode + single-key input. Saved
   termios so tty_restore puts the terminal back exactly. Raw = no echo,
   no canonical (line) buffering; ISIG left on so Ctrl-C still works. *)
let saved_termios : Unix.terminal_io option ref = ref None

(* v0.1.21 (mwasm dogfood): true byte length of a file via stat. *)
let builtin_file_size =
  V_builtin ("file_size", fun v ->
    match v with
    | V_str path ->
      (try V_int (Unix.stat path).Unix.st_size
       with Unix.Unix_error (e, _, _) ->
         raise (Eval_error (Loc.dummy,
           "file_size: " ^ path ^ ": " ^ Unix.error_message e)))
    | _ -> failwith "file_size: expected str")

let builtin_tty_raw =
  V_builtin ("tty_raw", fun v ->
    match v with
    | V_unit ->
      (if Unix.isatty Unix.stdin then begin
         let tio = Unix.tcgetattr Unix.stdin in
         if !saved_termios = None then saved_termios := Some tio;
         Unix.tcsetattr Unix.stdin Unix.TCSANOW
           { tio with Unix.c_icanon = false; Unix.c_echo = false;
                      Unix.c_vmin = 1; Unix.c_vtime = 0 }
       end);
      V_unit
    | _ -> failwith "tty_raw: expected unit")

let builtin_tty_restore =
  V_builtin ("tty_restore", fun v ->
    match v with
    | V_unit ->
      (match !saved_termios with
       | Some tio when Unix.isatty Unix.stdin ->
         Unix.tcsetattr Unix.stdin Unix.TCSANOW tio
       | _ -> ());
      V_unit
    | _ -> failwith "tty_restore: expected unit")

let builtin_read_key =
  V_builtin ("read_key", fun v ->
    match v with
    | V_unit ->
      let buf = Bytes.create 1 in
      let n = Unix.read Unix.stdin buf 0 1 in
      V_str (if n = 0 then "" else Bytes.sub_string buf 0 1)
    | _ -> failwith "read_key: expected unit")

(* Non-blocking single-byte stdin: -1 when nothing is ready. read_key blocks,
   which a device emulator cannot afford — polling a UART's line-status register
   must not stop the machine. select with a zero timeout leaves stdin's flags
   alone, so this composes with tty_raw and with a plain pipe alike. *)
let builtin_stdin_byte =
  V_builtin ("stdin_byte", fun v ->
    match v with
    | V_unit ->
      let (ready, _, _) = Unix.select [Unix.stdin] [] [] 0.0 in
      if ready = [] then V_int (-1)
      else begin
        let buf = Bytes.create 1 in
        let n = Unix.read Unix.stdin buf 0 1 in
        if n = 0 then V_int (-1) else V_int (Char.code (Bytes.get buf 0))
      end
    | _ -> failwith "stdin_byte: expected unit")

let builtin_print_no_nl =
  V_builtin ("print_no_nl", fun v ->
    (match v with
     | V_str s -> print_string s; flush stdout
     | _ -> failwith "print_no_nl: expected str");
    V_unit)

let builtin_print_err =
  V_builtin ("print_err", fun v ->
    (match v with
     | V_str s -> prerr_endline s
     | _ -> failwith "print_err: expected str");
    V_unit)

let builtin_read_file =
  V_builtin ("read_file", fun v ->
    match v with
    | V_str path ->
      (try
         let ic = open_in path in
         let len = in_channel_length ic in
         let buf = Bytes.create len in
         really_input ic buf 0 len;
         close_in ic;
         V_str (Bytes.to_string buf)
       with Sys_error msg ->
         raise (Eval_error (Loc.dummy, "read_file: " ^ msg)))
    | _ -> failwith "read_file: expected str")

(* v0.1.43 (bytes story): binary-safe file read — an int vec of byte
   values 0..255. `read_file`'s str carries NULs fine here (OCaml
   strings), but truncates at the first NUL on the C backend; this is
   the path that means the same thing everywhere. *)
let builtin_read_file_bytes =
  V_builtin ("read_file_bytes", fun v ->
    match v with
    | V_str path ->
      (try
         let ic = open_in_bin path in
         let len = in_channel_length ic in
         let buf = Bytes.create len in
         really_input ic buf 0 len;
         close_in ic;
         V_vec (vecbuf_of_array
                  (Array.init len (fun i -> V_int (Char.code (Bytes.get buf i)))))
       with Sys_error msg ->
         raise (Eval_error (Loc.dummy, "read_file_bytes: " ^ msg)))
    | _ -> failwith "read_file_bytes: expected str")

(* v0.1.44: the write half — each vec element must be an int in 0..255. *)
let builtin_write_file_bytes =
  V_builtin ("write_file_bytes", fun p ->
    match p with
    | V_str path ->
      V_builtin ("write_file_bytes_partial", fun v ->
        match v with
        | V_vec arr ->
          (try
             let oc = open_out_bin path in
             Array.iter (fun elt ->
               match elt with
               | V_int b when b >= 0 && b <= 255 ->
                 output_char oc (Char.chr b)
               | V_int b ->
                 close_out oc;
                 raise (Eval_error (Loc.dummy,
                   Printf.sprintf "write_file_bytes: byte value %d out of range 0..255" b))
               | _ -> failwith "write_file_bytes: expected int vec") (vecbuf_live arr);
             close_out oc;
             V_unit
           with Sys_error msg ->
             raise (Eval_error (Loc.dummy, "write_file_bytes: " ^ msg)))
        | _ -> failwith "write_file_bytes: expected int vec")
    | _ -> failwith "write_file_bytes: expected str path")

(* Phase 19.6: I/O extensions. read_lines, file_exists, env_var, args.
   read_lines / args return str list, so they depend on the prelude's
   `type 'a list`. env_var returns str option (the prelude's `'a option`). *)

let rec str_list_to_v_local = function
  | [] -> V_constr ("Nil", None)
  | s :: rest ->
    V_constr ("Cons", Some (V_tuple [V_str s; str_list_to_v_local rest]))

let builtin_read_lines =
  V_builtin ("read_lines", fun v ->
    match v with
    | V_str path ->
      (try
         let ic = open_in path in
         let rec collect acc =
           match input_line ic with
           | line -> collect (line :: acc)
           | exception End_of_file -> List.rev acc
         in
         let lines = collect [] in
         close_in ic;
         str_list_to_v_local lines
       with Sys_error msg ->
         raise (Eval_error (Loc.dummy, "read_lines: " ^ msg)))
    | _ -> failwith "read_lines: expected str")

let builtin_file_exists =
  V_builtin ("file_exists", fun v ->
    match v with
    | V_str path -> V_bool (Sys.file_exists path)
    | _ -> failwith "file_exists: expected str")

(* Phase 44: fs primitives for the docs site SSG *)
let builtin_list_dir =
  V_builtin ("list_dir", fun v ->
    match v with
    | V_str path ->
      (try
         let entries = Sys.readdir path in
         (* Exclude `.` and `..`. Sort for a stable order. *)
         let lst = Array.to_list entries
                   |> List.filter (fun n -> n <> "." && n <> "..")
                   |> List.sort compare in
         str_list_to_v_local lst
       with Sys_error msg ->
         raise (Eval_error (Loc.dummy, "list_dir: " ^ msg)))
    | _ -> failwith "list_dir: expected str")

(* Phase 44.6: file_mtime / sleep_ms — for dev server / watch *)
let builtin_file_mtime =
  V_builtin ("file_mtime", fun v ->
    match v with
    | V_str path ->
      (try V_float (Unix.stat path).Unix.st_mtime
       with Unix.Unix_error (e, _, _) ->
         raise (Eval_error (Loc.dummy,
           "file_mtime: " ^ Unix.error_message e ^ ": " ^ path)))
    | _ -> failwith "file_mtime: expected str")

let builtin_sleep_ms =
  V_builtin ("sleep_ms", fun v ->
    match v with
    | V_int ms ->
      if vclock_on then sched_sleep (float_of_int ms /. 1000.0)
      else Unix.sleepf (float_of_int ms /. 1000.0);
      V_unit
    | _ -> failwith "sleep_ms: expected int")

let builtin_mkdir_p =
  V_builtin ("mkdir_p", fun v ->
    match v with
    | V_str path ->
      (* Equivalent to `mkdir -p`: create intermediate dirs as well; ignore errors if already exists *)
      let rec mk p =
        if p = "" || p = "/" || p = "." then ()
        else if Sys.file_exists p then ()
        else begin
          mk (Filename.dirname p);
          try Unix.mkdir p 0o755 with
          | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
          | Unix.Unix_error (e, _, _) ->
            raise (Eval_error (Loc.dummy,
              "mkdir_p: " ^ Unix.error_message e ^ ": " ^ p))
        end
      in
      (try mk path; V_unit
       with Eval_error _ as e -> raise e
          | Sys_error msg ->
            raise (Eval_error (Loc.dummy, "mkdir_p: " ^ msg)))
    | _ -> failwith "mkdir_p: expected str")

let builtin_env_var =
  V_builtin ("env_var", fun v ->
    match v with
    | V_str name ->
      (match Sys.getenv_opt name with
       | None -> V_constr ("None", None)
       | Some s -> V_constr ("Some", Some (V_str s)))
    | _ -> failwith "env_var: expected str")

(* v0.1.12 (N3): the program's own arguments, i.e. everything AFTER the
   script path — matching the native backend's `args()` (argv[1..] with the
   binary name dropped). The CLI entry point sets this to the args following
   the .mere file; reading Sys.argv[1..] here instead would wrongly include
   the script path, so interp and native disagreed. Defaults to [] (REPL,
   tests, embedded use). *)
let program_argv : string list ref = ref []

let builtin_args =
  V_builtin ("args", fun v ->
    match v with
    | V_unit -> str_list_to_v_local !program_argv
    | _ -> failwith "args: expected unit")

let builtin_write_file =
  V_builtin ("write_file", fun path_val ->
    match path_val with
    | V_str path ->
      V_builtin ("write_file_partial", fun content_val ->
        match content_val with
        | V_str content ->
          (try
             let oc = open_out path in
             output_string oc content;
             close_out oc;
             V_unit
           with Sys_error msg ->
             raise (Eval_error (Loc.dummy, "write_file: " ^ msg)))
        | _ -> failwith "write_file: 2nd arg expected str")
    | _ -> failwith "write_file: 1st arg expected str")

let builtin_print_int =
  V_builtin ("print_int", fun v ->
    (match v with
     | V_int n -> print_endline (string_of_int n)
     | _ -> failwith "print_int: expected int");
    V_unit)

let builtin_str_of_int =
  V_builtin ("str_of_int", fun v ->
    match v with
    | V_int n -> V_str (string_of_int n)
    | _ -> failwith "str_of_int: expected int")

let builtin_float_of_int =
  V_builtin ("float_of_int", fun v ->
    match v with
    | V_int n -> V_float (float_of_int n)
    | _ -> failwith "float_of_int: expected int")

let builtin_int_of_float =
  V_builtin ("int_of_float", fun v ->
    match v with
    | V_float f -> V_int (int_of_float f)
    | _ -> failwith "int_of_float: expected float")

let builtin_str_of_float =
  V_builtin ("str_of_float", fun v ->
    match v with
    | V_float f -> V_str (format_float f)
    | _ -> failwith "str_of_float: expected float")

let builtin_float_of_str =
  V_builtin ("float_of_str", fun v ->
    match v with
    | V_str s ->
      (try V_float (float_of_string (String.trim s))
       with Failure _ ->
         raise (Eval_error (Loc.dummy,
           Printf.sprintf "float_of_str: %S is not a valid float" s)))
    | _ -> failwith "float_of_str: expected str")

let builtin_f_add =
  V_builtin ("f_add", fun a ->
    match a with
    | V_float x ->
      V_builtin ("f_add_partial", fun b ->
        match b with
        | V_float y -> V_float (x +. y)
        | _ -> failwith "f_add: 2nd arg expected float")
    | _ -> failwith "f_add: 1st arg expected float")

let builtin_f_sub =
  V_builtin ("f_sub", fun a ->
    match a with
    | V_float x ->
      V_builtin ("f_sub_partial", fun b ->
        match b with
        | V_float y -> V_float (x -. y)
        | _ -> failwith "f_sub: 2nd arg expected float")
    | _ -> failwith "f_sub: 1st arg expected float")

let builtin_f_mul =
  V_builtin ("f_mul", fun a ->
    match a with
    | V_float x ->
      V_builtin ("f_mul_partial", fun b ->
        match b with
        | V_float y -> V_float (x *. y)
        | _ -> failwith "f_mul: 2nd arg expected float")
    | _ -> failwith "f_mul: 1st arg expected float")

let builtin_f_div =
  V_builtin ("f_div", fun a ->
    match a with
    | V_float x ->
      V_builtin ("f_div_partial", fun b ->
        match b with
        | V_float y -> V_float (x /. y)  (* IEEE 754: 1.0 /. 0.0 -> inf, nan etc. *)
        | _ -> failwith "f_div: 2nd arg expected float")
    | _ -> failwith "f_div: 1st arg expected float")

let make_float_cmp name op =
  V_builtin (name, fun a ->
    match a with
    | V_float x ->
      V_builtin (name ^ "_partial", fun b ->
        match b with
        | V_float y -> V_bool (op x y)
        | _ -> failwith (name ^ ": 2nd arg expected float"))
    | _ -> failwith (name ^ ": 1st arg expected float"))

let builtin_f_lt = make_float_cmp "f_lt" (<)
let builtin_f_le = make_float_cmp "f_le" (<=)
let builtin_f_gt = make_float_cmp "f_gt" (>)
let builtin_f_ge = make_float_cmp "f_ge" (>=)

let builtin_f_abs =
  V_builtin ("f_abs", fun v ->
    match v with
    | V_float f -> V_float (Float.abs f)
    | _ -> failwith "f_abs: expected float")

let builtin_f_neg =
  V_builtin ("f_neg", fun v ->
    match v with
    | V_float f -> V_float (-. f)
    | _ -> failwith "f_neg: expected float")

let builtin_sqrt =
  V_builtin ("sqrt", fun v ->
    match v with
    | V_float f -> V_float (Float.sqrt f)
    | _ -> failwith "sqrt: expected float")

let builtin_floor =
  V_builtin ("floor", fun v ->
    match v with
    | V_float f -> V_float (Float.floor f)
    | _ -> failwith "floor: expected float")

let builtin_ceil =
  V_builtin ("ceil", fun v ->
    match v with
    | V_float f -> V_float (Float.ceil f)
    | _ -> failwith "ceil: expected float")

let builtin_round =
  V_builtin ("round", fun v ->
    match v with
    | V_float f -> V_float (Float.round f)
    | _ -> failwith "round: expected float")

(* Phase 19.7: math extensions — natural log / exp / trig / comparisons / random. *)

let unary_float name f =
  V_builtin (name, fun v ->
    match v with
    | V_float x -> V_float (f x)
    | _ -> failwith (name ^ ": expected float"))

let builtin_log = unary_float "log" Float.log
let builtin_exp = unary_float "exp" Float.exp
let builtin_sin = unary_float "sin" Float.sin
let builtin_cos = unary_float "cos" Float.cos
let builtin_tan = unary_float "tan" Float.tan

let binary_float name f =
  V_builtin (name, fun a ->
    match a with
    | V_float fa ->
      V_builtin (name ^ "_p1", fun b ->
        match b with
        | V_float fb -> V_float (f fa fb)
        | _ -> failwith (name ^ ": 2nd arg expected float"))
    | _ -> failwith (name ^ ": 1st arg expected float"))

(* Q-038: the halves are taken with a LOGICAL shift and a mask, so each result is
   below 2^32 and fits this interpreter's native int. Returning the whole pattern
   would not: as a signed int64 it exceeds 63 bits for -1.5, 1e308, inf and nan. *)
let builtin_float_bits_hi =
  V_builtin ("float_bits_hi", fun v ->
    match v with
    | V_float f ->
      V_int (Int64.to_int (Int64.shift_right_logical (Int64.bits_of_float f) 32))
    | _ -> failwith "float_bits_hi: expected float")

let builtin_float_bits_lo =
  V_builtin ("float_bits_lo", fun v ->
    match v with
    | V_float f ->
      V_int (Int64.to_int (Int64.logand (Int64.bits_of_float f) 0xFFFFFFFFL))
    | _ -> failwith "float_bits_lo: expected float")

let builtin_float_of_bits =
  V_builtin ("float_of_bits", fun hi ->
    match hi with
    | V_int h ->
      V_builtin ("float_of_bits.1", fun lo ->
        match lo with
        | V_int l ->
          let h64 = Int64.logand (Int64.of_int h) 0xFFFFFFFFL in
          let l64 = Int64.logand (Int64.of_int l) 0xFFFFFFFFL in
          V_float (Int64.float_of_bits (Int64.logor (Int64.shift_left h64 32) l64))
        | _ -> failwith "float_of_bits: 2nd arg expected int")
    | _ -> failwith "float_of_bits: 1st arg expected int")

let builtin_f32_bits =
  V_builtin ("f32_bits", fun v ->
    match v with
    | V_float f -> V_int (Int32.to_int (Int32.bits_of_float f) land 0xFFFFFFFF)
    | _ -> failwith "f32_bits: expected float")

let builtin_float_of_f32_bits =
  V_builtin ("float_of_f32_bits", fun v ->
    match v with
    | V_int b -> V_float (Int32.float_of_bits (Int32.of_int (b land 0xFFFFFFFF)))
    | _ -> failwith "float_of_f32_bits: expected int")

let builtin_atan2 = binary_float "atan2" Float.atan2
let builtin_f_min = binary_float "f_min" Float.min
let builtin_f_max = binary_float "f_max" Float.max
let builtin_f_pow = binary_float "f_pow" Float.pow

(* random_int n: returns an int in 0..n-1. Raises when n <= 0. *)
let builtin_random_int =
  V_builtin ("random_int", fun v ->
    match v with
    | V_int n ->
      if n <= 0 then
        raise (Eval_error (Loc.dummy,
          "random_int: bound must be positive (got " ^ string_of_int n ^ ")"))
      else V_int (Random.int n)
    | _ -> failwith "random_int: expected int")

(* random_float (): returns a float with 0.0 <= x < 1.0. *)
let builtin_random_float =
  V_builtin ("random_float", fun v ->
    match v with
    | V_unit -> V_float (Random.float 1.0)
    | _ -> failwith "random_float: expected unit")

let builtin_print_bool =
  V_builtin ("print_bool", fun v ->
    (match v with
     | V_bool b -> print_endline (if b then "true" else "false")
     | _ -> failwith "print_bool: expected bool");
    V_unit)

let builtin_not =
  V_builtin ("not", fun v ->
    match v with
    | V_bool b -> V_bool (not b)
    | _ -> failwith "not: expected bool")

let builtin_str_len =
  V_builtin ("str_len", fun v ->
    match v with
    | V_str s -> V_int (String.length s)
    | _ -> failwith "str_len: expected str")

let builtin_int_of_str =
  V_builtin ("int_of_str", fun v ->
    match v with
    | V_str s ->
      (* v0.1.60 (Result-pipeline probe): the accepted form is now pinned
         to `WS* [+-]? DIGIT+ WS*` on every backend — the compiled
         backends used atoi-style parsing that silently returned 0 (or a
         partial prefix) on invalid input while the interpreter raised,
         a real cross-backend divergence. OCaml's own int_of_string also
         accepts 0x/0o/0b/_ forms, which the compiled backends never did,
         so the strict-decimal validation below is the shared spec. *)
      let t = String.trim s in
      let valid =
        let n = String.length t in
        if n = 0 then false
        else
          let start = if t.[0] = '+' || t.[0] = '-' then 1 else 0 in
          n > start
          && (let ok = ref true in
              String.iteri (fun i c ->
                if i >= start && (c < '0' || c > '9') then ok := false) t;
              !ok)
      in
      if valid then V_int (int_of_string t)
      else
        raise (Eval_error (Loc.dummy,
          Printf.sprintf "int_of_str: %S is not a valid int" s))
    | _ -> failwith "int_of_str: expected str")

let builtin_bool_of_str =
  V_builtin ("bool_of_str", fun v ->
    match v with
    | V_str s ->
      (match String.trim s with
       | "true" -> V_bool true
       | "false" -> V_bool false
       | _ ->
         raise (Eval_error (Loc.dummy,
           Printf.sprintf "bool_of_str: %S is not 'true' or 'false'" s)))
    | _ -> failwith "bool_of_str: expected str")

let builtin_str_compare =
  V_builtin ("str_compare", fun a ->
    match a with
    | V_str x ->
      V_builtin ("str_compare_partial", fun b ->
        match b with
        | V_str y ->
          let c = String.compare x y in
          V_int (if c < 0 then -1 else if c > 0 then 1 else 0)
        | _ -> failwith "str_compare: 2nd arg expected str")
    | _ -> failwith "str_compare: 1st arg expected str")

let builtin_str_count =
  V_builtin ("str_count", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("str_count_partial", fun n_val ->
        match n_val with
        | V_str needle ->
          if needle = "" then V_int 0
          else begin
            let s_len = String.length s in
            let n_len = String.length needle in
            let rec scan i acc =
              if i + n_len > s_len then acc
              else if String.sub s i n_len = needle then
                scan (i + n_len) (acc + 1)  (* non-overlapping *)
              else scan (i + 1) acc
            in
            V_int (scan 0 0)
          end
        | _ -> failwith "str_count: 2nd arg expected str")
    | _ -> failwith "str_count: 1st arg expected str")

let builtin_str_contains =
  V_builtin ("str_contains", fun haystack ->
    match haystack with
    | V_str h ->
      V_builtin ("str_contains_partial", fun needle ->
        match needle with
        | V_str n ->
          let h_len = String.length h in
          let n_len = String.length n in
          let rec scan i =
            if n_len = 0 then true
            else if i + n_len > h_len then false
            else if String.sub h i n_len = n then true
            else scan (i + 1)
          in
          V_bool (scan 0)
        | _ -> failwith "str_contains: 2nd arg expected str")
    | _ -> failwith "str_contains: 1st arg expected str")

(* Phase 19.1: str_index_of, str_split, str_join *)

let builtin_str_index_of =
  V_builtin ("str_index_of", fun haystack ->
    match haystack with
    | V_str h ->
      V_builtin ("str_index_of_partial", fun needle ->
        match needle with
        | V_str n ->
          let h_len = String.length h in
          let n_len = String.length n in
          if n_len = 0 then V_int 0
          else
            let rec scan i =
              if i + n_len > h_len then V_int (-1)
              else if String.sub h i n_len = n then V_int i
              else scan (i + 1)
            in
            scan 0
        | _ -> failwith "str_index_of: 2nd arg expected str")
    | _ -> failwith "str_index_of: 1st arg expected str")

(* v0.1.302: str_last_index_of — the same search from the other end.
   The empty needle answers h_len rather than 0: it occurs at every position
   including one past the last byte, and the LAST of those is the length. That
   keeps `str_index_of s "" <= str_last_index_of s ""` true for every s, which
   is the property a caller splitting on a separator relies on. *)
let builtin_str_last_index_of =
  V_builtin ("str_last_index_of", fun haystack ->
    match haystack with
    | V_str h ->
      V_builtin ("str_last_index_of_partial", fun needle ->
        match needle with
        | V_str n ->
          let h_len = String.length h in
          let n_len = String.length n in
          if n_len = 0 then V_int h_len
          else if n_len > h_len then V_int (-1)
          else
            let rec scan i =
              if i < 0 then V_int (-1)
              else if String.sub h i n_len = n then V_int i
              else scan (i - 1)
            in
            scan (h_len - n_len)
        | _ -> failwith "str_last_index_of: 2nd arg expected str")
    | _ -> failwith "str_last_index_of: 1st arg expected str")

(* Helper: produce an OCaml list of str → wrap as V_constr Nil/Cons chain. *)
let rec str_list_to_v = function
  | [] -> V_constr ("Nil", None)
  | s :: rest ->
    V_constr ("Cons", Some (V_tuple [V_str s; str_list_to_v rest]))

let builtin_str_split =
  V_builtin ("str_split", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("str_split_partial", fun d_val ->
        match d_val with
        | V_str delim ->
          let s_len = String.length s in
          let d_len = String.length delim in
          if d_len = 0 then
            (* Empty delimiter → single-element list with the original string,
               matching common conventions (Python "abc".split("") errors but
               we choose pragmatic single-element output). *)
            str_list_to_v [s]
          else begin
            let rec loop start acc =
              if start > s_len then List.rev acc
              else
                let rec find i =
                  if i + d_len > s_len then None
                  else if String.sub s i d_len = delim then Some i
                  else find (i + 1)
                in
                match find start with
                | None -> List.rev (String.sub s start (s_len - start) :: acc)
                | Some pos ->
                  let part = String.sub s start (pos - start) in
                  loop (pos + d_len) (part :: acc)
            in
            str_list_to_v (loop 0 [])
          end
        | _ -> failwith "str_split: 2nd arg expected str (delimiter)")
    | _ -> failwith "str_split: 1st arg expected str")

(* v0.1.38 (Unicode probe): UTF-8 codepoint helpers. A str stays a byte
   string (str_len / substring / char_at are byte-indexed, documented);
   these give the codepoint view. An invalid or truncated sequence
   counts as a single unit, so they never loop or throw. *)
let utf8_span_len b =
  if b < 0x80 then 1
  else if b >= 0xC0 && b <= 0xDF then 2
  else if b >= 0xE0 && b <= 0xEF then 3
  else if b >= 0xF0 && b <= 0xF7 then 4
  else 1

let builtin_utf8_len =
  V_builtin ("utf8_len", fun v ->
    match v with
    | V_str s ->
      let n = String.length s in
      let rec go i acc =
        if i >= n then acc
        else go (i + min (utf8_span_len (Char.code s.[i])) (n - i)) (acc + 1)
      in
      V_int (go 0 0)
    | _ -> failwith "utf8_len: expected str")

let builtin_utf8_chars =
  V_builtin ("utf8_chars", fun v ->
    match v with
    | V_str s ->
      let n = String.length s in
      let rec go i acc =
        if i >= n then List.rev acc
        else
          let l = min (utf8_span_len (Char.code s.[i])) (n - i) in
          go (i + l) (String.sub s i l :: acc)
      in
      str_list_to_v (go 0 [])
    | _ -> failwith "utf8_chars: expected str")

(* v0.1.42 (bitwise): ops on the interpreter's OCaml int (normally 63
   bits). bit_shr is the arithmetic shift (asr). Shift counts are
   masked to 0..62 so out-of-range counts don't hit OCaml's unspecified
   shift behavior; portable programs should stay in 0..31 anyway (the
   LLVM / Wasm backends are 32-bit). *)
let bit_binop name f =
  V_builtin (name, fun a ->
    match a with
    | V_int x ->
      V_builtin (name ^ "_partial", fun b ->
        match b with
        | V_int y -> V_int (f x y)
        | _ -> failwith (name ^ ": 2nd arg expected int"))
    | _ -> failwith (name ^ ": 1st arg expected int"))

let builtin_bit_and = bit_binop "bit_and" (land)
let builtin_bit_or  = bit_binop "bit_or" (lor)
let builtin_bit_xor = bit_binop "bit_xor" (lxor)
let builtin_bit_shl = bit_binop "bit_shl"
  (fun x n -> if n < 0 || n > 62 then 0 else x lsl n)
let builtin_bit_shr = bit_binop "bit_shr"
  (fun x n -> if n < 0 then x else x asr (min n 62))
let builtin_bit_not =
  V_builtin ("bit_not", fun v ->
    match v with
    | V_int x -> V_int (lnot x)
    | _ -> failwith "bit_not: expected int")

let builtin_str_join =
  V_builtin ("str_join", fun sep_val ->
    match sep_val with
    | V_str sep ->
      V_builtin ("str_join_partial", fun lst ->
        let rec collect v =
          match v with
          | V_constr ("Nil", None) -> []
          | V_constr ("Cons", Some (V_tuple [V_str s; rest])) ->
            s :: collect rest
          | V_constr ("Cons", Some (V_tuple [_; _])) ->
            failwith "str_join: list element expected str"
          | _ -> failwith "str_join: 2nd arg expected str list"
        in
        V_str (String.concat sep (collect lst)))
    | _ -> failwith "str_join: 1st arg expected str (separator)")

let builtin_min =
  V_builtin ("min", fun a ->
    match a with
    | V_int x ->
      V_builtin ("min_partial", fun b ->
        match b with
        | V_int y -> V_int (if x < y then x else y)
        | _ -> failwith "min: 2nd arg expected int")
    | _ -> failwith "min: 1st arg expected int")

let builtin_max =
  V_builtin ("max", fun a ->
    match a with
    | V_int x ->
      V_builtin ("max_partial", fun b ->
        match b with
        | V_int y -> V_int (if x > y then x else y)
        | _ -> failwith "max: 2nd arg expected int")
    | _ -> failwith "max: 1st arg expected int")

let builtin_abs =
  V_builtin ("abs", fun v ->
    match v with
    | V_int n -> V_int (if n < 0 then -n else n)
    | _ -> failwith "abs: expected int")

let builtin_even =
  V_builtin ("even", fun v ->
    match v with
    | V_int n -> V_bool (n mod 2 = 0)
    | _ -> failwith "even: expected int")

let builtin_odd =
  V_builtin ("odd", fun v ->
    match v with
    | V_int n -> V_bool (n mod 2 <> 0)
    | _ -> failwith "odd: expected int")

let builtin_clamp =
  V_builtin ("clamp", fun lo_val ->
    match lo_val with
    | V_int lo ->
      V_builtin ("clamp_p1", fun hi_val ->
        match hi_val with
        | V_int hi ->
          V_builtin ("clamp_p2", fun x_val ->
            match x_val with
            | V_int x ->
              if x < lo then V_int lo
              else if x > hi then V_int hi
              else V_int x
            | _ -> failwith "clamp: 3rd arg expected int")
        | _ -> failwith "clamp: 2nd arg expected int")
    | _ -> failwith "clamp: 1st arg expected int")

let builtin_gcd =
  V_builtin ("gcd", fun a ->
    match a with
    | V_int x ->
      V_builtin ("gcd_partial", fun b ->
        match b with
        | V_int y ->
          let rec euclid a b =
            if b = 0 then a
            else euclid b (a mod b)
          in
          V_int (euclid (abs x) (abs y))
        | _ -> failwith "gcd: 2nd arg expected int")
    | _ -> failwith "gcd: 1st arg expected int")

let builtin_fail =
  V_builtin ("fail", fun v ->
    match v with
    | V_str msg -> raise (Eval_error (Loc.dummy, "fail: " ^ msg))
    | _ -> failwith "fail: expected str")

let builtin_show =
  V_builtin ("show", fun v -> V_str (to_string v))

let builtin_to_json =
  V_builtin ("to_json", fun v -> V_str (to_json_string v))

(* Fallback for a bare/indirect `of_json` reference. The normal path is the
   `App (Var "of_json", arg)` special case in eval_in, which has the target
   type; used as a plain value it has no type context and cannot decode. *)
let builtin_of_json =
  V_builtin ("of_json", fun _ ->
    raise (Eval_error (Loc.dummy,
      "of_json must be applied directly where its result type is known \
       (e.g. `let r: T = of_json s`); it can't be used as a first-class value")))

(* Phase 12.6 — Q-010 narrowed: the first step toward trait-style API
   unification. Adds `len` as a polymorphic `'a -> int` builtin that
   dispatches at runtime by looking at the value variant:
     - V_vec       -> array length (covers the V_vec runtime that
                     Vec[R, T] and OwnedVec[T] share)
     - V_str       -> byte length
     - V_constr (Nil/Cons ...) -> element count via list traversal
     - V_tuple     -> arity
     - else        -> eval error
   This is ad-hoc polymorphism (same bucket as show) — not a full
   trait system, but it provides a single API for
   `Vec[R, T] / OwnedVec[T] / list / str / tuple`. A proper trait
   system will come in a future slice. *)
let rec vec_len_via_constr v =
  match v with
  | V_constr ("Nil", None) -> 0
  | V_constr ("Cons", Some (V_tuple [_; tail])) -> 1 + vec_len_via_constr tail
  | _ -> -1

let builtin_len =
  V_builtin ("len", fun v ->
    match v with
    | V_vec arr -> V_int arr.vc_len
    | V_strbuf buf -> V_int (Buffer.length buf)
    | V_map m -> V_int (Hashtbl.length m.m_tbl)
    | V_str s -> V_int (String.length s)
    | V_tuple es -> V_int (List.length es)
    | V_constr _ ->
      let n = vec_len_via_constr v in
      if n < 0 then
        raise (Eval_error (Loc.dummy,
          "len: constructor value is not a recognized list (Nil/Cons chain)"))
      else V_int n
    | _ ->
      raise (Eval_error (Loc.dummy,
        "len: value has no defined length (expected Vec / OwnedVec / StrBuf / Map / list / str / tuple)")))

(* --- Vec builtins (Phase 12.1) ---
   `'a Vec` is a region-aware growable vector. In the interpreter
   the underlying storage is `value array ref` — `push` reallocates
   when full. Operations are mutating, so multiple `&R Vec` borrows
   to the same Vec are subject to the borrow checker rules. *)
let builtin_vec_new =
  V_builtin ("vec_new", fun v ->
    match v with
    | V_unit -> V_vec (vecbuf_empty ())
    | _ -> failwith "vec_new: expected unit")

let builtin_vec_push =
  V_builtin ("vec_push", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_push_p1", fun x ->
        vecbuf_push arr x;
        V_unit)
    | _ -> failwith "vec_push: expected Vec")

let builtin_vec_get =
  V_builtin ("vec_get", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_get_p1", fun idx ->
        match idx with
        | V_int i ->
          if i < 0 || i >= arr.vc_len then
            raise (Eval_error (Loc.dummy,
              Printf.sprintf "vec_get: index %d out of bounds (len = %d)"
                i arr.vc_len))
          else arr.vc_data.(i)
        | _ -> failwith "vec_get: expected int index")
    | _ -> failwith "vec_get: expected Vec")

let builtin_vec_len =
  V_builtin ("vec_len", fun v ->
    match v with
    | V_vec arr -> V_int arr.vc_len
    | _ -> failwith "vec_len: expected Vec")

(* The higher-order Vec API (Phase 12.9) requires apply_value_ref, so
   it is placed after apply_value_ref is defined (`builtin_vec_iter`
   etc. appear later). The in-place mutation `vec_set` does not need
   apply_value_ref, but is placed together as part of the Phase 12.9
   group. *)

(* OwnedVec[T] (Phase 12.5) — the runtime shares V_vec. Only the type
   system treats it as a separate type. The contrast with `Vec[R, T]`
   is expressed by the fact that OwnedVec is registered as a Drop type
   and so cannot live in a region. *)
let builtin_owned_vec_new =
  V_builtin ("owned_vec_new", fun v ->
    match v with
    | V_unit -> V_vec (vecbuf_empty ())
    | _ -> failwith "owned_vec_new: expected unit")

let builtin_owned_vec_push =
  V_builtin ("owned_vec_push", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("owned_vec_push_p1", fun x ->
        vecbuf_push arr x;
        V_unit)
    | _ -> failwith "owned_vec_push: expected OwnedVec")

let builtin_owned_vec_get =
  V_builtin ("owned_vec_get", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("owned_vec_get_p1", fun idx ->
        match idx with
        | V_int i ->
          if i < 0 || i >= arr.vc_len then
            raise (Eval_error (Loc.dummy,
              Printf.sprintf "owned_vec_get: index %d out of bounds (len = %d)"
                i arr.vc_len))
          else arr.vc_data.(i)
        | _ -> failwith "owned_vec_get: expected int index")
    | _ -> failwith "owned_vec_get: expected OwnedVec")

let builtin_owned_vec_len =
  V_builtin ("owned_vec_len", fun v ->
    match v with
    | V_vec arr -> V_int arr.vc_len
    | _ -> failwith "owned_vec_len: expected OwnedVec")

(* StrBuf[R] builtins (Phase 12.7) — a mutable string buffer inside a
   region. Implemented as an OCaml Buffer; push appends, and to_str
   returns a snapshot. *)
(* --- ByteBuf: a mutable byte buffer ---------------------------------------

   `bytebuf_new n` is n zeroed bytes with random access; `push` grows it. The two
   halves exist because the two things that need it are different: reconstructing
   a PNG scanline reads the row above and writes the row it is on (random access,
   fixed size), and building a file appends (growth). Freezing gives a `bytes`,
   which is the type that can leave the program. *)

let expect_bytebuf who v =
  match v with
  | V_bytebuf b -> b
  | _ -> failwith (who ^ ": expected ByteBuf")

let bb_ensure (b : bytebuf) (n : int) =
  if n > Bytes.length b.bb_data then begin
    let cap = max n (max 64 (Bytes.length b.bb_data * 2)) in
    let bigger = Bytes.make cap '\000' in
    Bytes.blit b.bb_data 0 bigger 0 b.bb_len;
    b.bb_data <- bigger
  end

let builtin_bytebuf_new =
  V_builtin ("bytebuf_new", fun v ->
    match v with
    | V_int n when n >= 0 ->
      V_bytebuf { bb_data = Bytes.make (max n 1) '\000'; bb_len = n }
    | V_int _ -> failwith "bytebuf_new: negative length"
    | _ -> failwith "bytebuf_new: expected int")

let builtin_bytebuf_len =
  V_builtin ("bytebuf_len", fun v -> V_int (expect_bytebuf "bytebuf_len" v).bb_len)

let builtin_bytebuf_get =
  V_builtin ("bytebuf_get", fun v ->
    let b = expect_bytebuf "bytebuf_get" v in
    V_builtin ("bytebuf_get_p1", fun i ->
      match i with
      | V_int i when i >= 0 && i < b.bb_len ->
        V_int (Char.code (Bytes.get b.bb_data i))
      | V_int i ->
        raise (Eval_error (Loc.dummy,
          Printf.sprintf "bytebuf_get: index %d out of bounds (len = %d)" i b.bb_len))
      | _ -> failwith "bytebuf_get: expected int"))

let builtin_bytebuf_set =
  V_builtin ("bytebuf_set", fun v ->
    let b = expect_bytebuf "bytebuf_set" v in
    V_builtin ("bytebuf_set_p1", fun i ->
      match i with
      | V_int i ->
        V_builtin ("bytebuf_set_p2", fun x ->
          match x with
          | V_int x when i >= 0 && i < b.bb_len ->
            Bytes.set b.bb_data i (Char.chr (x land 255)); V_unit
          | V_int _ ->
            raise (Eval_error (Loc.dummy,
              Printf.sprintf "bytebuf_set: index %d out of bounds (len = %d)" i b.bb_len))
          | _ -> failwith "bytebuf_set: expected int")
      | _ -> failwith "bytebuf_set: expected int"))

let builtin_bytebuf_push =
  V_builtin ("bytebuf_push", fun v ->
    let b = expect_bytebuf "bytebuf_push" v in
    V_builtin ("bytebuf_push_p1", fun x ->
      match x with
      | V_int x ->
        bb_ensure b (b.bb_len + 1);
        Bytes.set b.bb_data b.bb_len (Char.chr (x land 255));
        b.bb_len <- b.bb_len + 1;
        V_unit
      | _ -> failwith "bytebuf_push: expected int"))

let builtin_bytes_of_bytebuf =
  V_builtin ("bytes_of_bytebuf", fun v ->
    let b = expect_bytebuf "bytes_of_bytebuf" v in
    V_bytes (Bytes.sub_string b.bb_data 0 b.bb_len))

let builtin_bytebuf_of_bytes =
  V_builtin ("bytebuf_of_bytes", fun v ->
    match v with
    | V_bytes s ->
      V_bytebuf { bb_data = Bytes.of_string (if s = "" then "\000" else s);
                  bb_len = String.length s }
    | _ -> failwith "bytebuf_of_bytes: expected bytes")

let builtin_strbuf_new =
  V_builtin ("strbuf_new", fun v ->
    match v with
    | V_unit -> V_strbuf (Buffer.create 64)
    | _ -> failwith "strbuf_new: expected unit")

let builtin_strbuf_push =
  V_builtin ("strbuf_push", fun v ->
    match v with
    | V_strbuf buf ->
      V_builtin ("strbuf_push_p1", fun s ->
        match s with
        | V_str s -> Buffer.add_string buf s; V_unit
        | _ -> failwith "strbuf_push: expected str")
    | _ -> failwith "strbuf_push: expected StrBuf")

let builtin_strbuf_to_str =
  V_builtin ("strbuf_to_str", fun v ->
    match v with
    | V_strbuf buf -> V_str (Buffer.contents buf)
    | _ -> failwith "strbuf_to_str: expected StrBuf")

let builtin_strbuf_len =
  V_builtin ("strbuf_len", fun v ->
    match v with
    | V_strbuf buf -> V_int (Buffer.length buf)
    | _ -> failwith "strbuf_len: expected StrBuf")

(* Map[R, K, V] builtins (Phase 12.10). Internally an OCaml Hashtbl
   (polymorphic hash/eq). Designed to use Lang values
   (V_int / V_str / V_bool / V_tuple of primitives) as keys. Be careful
   with keys containing closures or refs — they are identified
   per-ref. *)
let builtin_map_new =
  V_builtin ("map_new", fun v ->
    match v with
    | V_unit -> V_map { m_tbl = Hashtbl.create 16; m_order = []; m_order_n = 0 }
    | _ -> failwith "map_new: expected unit")

let builtin_map_set =
  V_builtin ("map_set", fun v ->
    match v with
    | V_map m ->
      V_builtin ("map_set_p1", fun k ->
        V_builtin ("map_set_p2", fun vv ->
          (* Phase 27.1: track insertion order. Only record NEW keys;
             existing keys keep their original position. The list is kept
             newest-first (O(1) prepend); readers reverse it to recover
             insertion order. Appending (`@ [k]`) was O(n) per new key =
             O(n^2) to fill a map (measured this). *)
          if not (Hashtbl.mem m.m_tbl k) then begin
            m.m_order <- k :: m.m_order;
            m.m_order_n <- m.m_order_n + 1
          end;
          Hashtbl.replace m.m_tbl k vv;
          V_unit))
    | _ -> failwith "map_set: expected Map")

let builtin_map_get =
  V_builtin ("map_get", fun v ->
    match v with
    | V_map m ->
      V_builtin ("map_get_p1", fun k ->
        match Hashtbl.find_opt m.m_tbl k with
        | Some vv -> vv
        | None ->
          raise (Eval_error (Loc.dummy,
            "map_get: key not found in Map (use map_has to check first)")))
    | _ -> failwith "map_get: expected Map")

let builtin_map_has =
  V_builtin ("map_has", fun v ->
    match v with
    | V_map m ->
      V_builtin ("map_has_p1", fun k ->
        V_bool (Hashtbl.mem m.m_tbl k))
    | _ -> failwith "map_has: expected Map")

let builtin_map_len =
  V_builtin ("map_len", fun v ->
    match v with
    | V_map m -> V_int (Hashtbl.length m.m_tbl)
    | _ -> failwith "map_len: expected Map")

(* Phase 39.A' #2 / Q-063: map_delete — Hashtbl.remove and nothing else.
   This used to also do `List.filter` over the insertion-order list to keep it
   exact, which made one delete O(live): 20k operations over a live set grown
   from 500 to 8,000 went 0.38 s to 1.92 s, where O(1) is flat. The list is
   append-only now and readers skip what is gone (see map_live_keys), with
   map_maybe_compact keeping it proportional to the live set. *)
(* v0.1.297: map_compact / vec_compact — no-ops here. Compaction is an
   optimization the C backend performs (private-arena generation swap); the
   interpreter has no arenas, so the honest answer is unit. *)
(* v0.1.299: no arenas here; a trigger reading 0 just never fires on the
   interpreter, which is the no-op collector it already has. *)
let builtin_map_recycle =
  V_builtin ("map_recycle", fun v ->
    match v with
    | V_map m -> Hashtbl.reset m.m_tbl; m.m_order <- []; m.m_order_n <- 0; V_unit
    | _ -> failwith "map_recycle: expected Map")

let builtin_map_bytes = V_builtin ("map_bytes", fun _ -> V_int 0)
let builtin_vec_bytes = V_builtin ("vec_bytes", fun _ -> V_int 0)

let builtin_map_clear =
  V_builtin ("map_clear", fun v ->
    match v with
    | V_map m -> Hashtbl.reset m.m_tbl; m.m_order <- []; m.m_order_n <- 0; V_unit
    | _ -> failwith "map_clear: expected Map")

let builtin_map_compact =
  V_builtin ("map_compact", fun _ -> V_unit)
let builtin_vec_compact =
  V_builtin ("vec_compact", fun _ -> V_unit)

let builtin_map_delete =
  V_builtin ("map_delete", fun v ->
    match v with
    | V_map m ->
      V_builtin ("map_delete_p1", fun k ->
        if Hashtbl.mem m.m_tbl k then begin
          Hashtbl.remove m.m_tbl k;
          map_maybe_compact m
        end;
        V_unit)
    | _ -> failwith "map_delete: expected Map")

(* Phase 19.2: map_iter — apply (K -> V -> unit) to each entry.
   Note: defined here for grouping with other map_* builtins, but
   uses apply_value_ref which is defined later. The forward-reference
   pattern matches builtin_vec_iter (line ~930). *)

let builtin_fst =
  V_builtin ("fst", fun v ->
    match v with
    | V_tuple [a; _] -> a
    | _ -> failwith "fst: expected 2-tuple")

let builtin_snd =
  V_builtin ("snd", fun v ->
    match v with
    | V_tuple [_; b] -> b
    | _ -> failwith "snd: expected 2-tuple")

(* Forward-reference into eval_in's apply machinery so higher-order builtins
   like `flip` can call user functions (V_closure / V_builtin) at runtime.
   Patched at the bottom of this file, after eval_in is defined. *)
let apply_value_ref : (value -> value -> value) ref =
  ref (fun _ _ -> failwith "apply_value_ref: not initialized (BUG)")

let builtin_try_or =
  V_builtin ("try_or", fun f ->
    V_builtin ("try_or_partial", fun default ->
      let saved = !call_depth in
      try !apply_value_ref f V_unit
      with Eval_error _ ->
        (* the frames the failure unwound are gone, so the count of them goes
           too -- otherwise a program that catches inside a loop drifts upward
           until it reports a depth it is not at *)
        call_depth := saved;
        default))

(* Phase 12.9: higher-order Vec API (iter / map / fold / set).
   Calls user functions (V_closure / V_builtin) via apply_value_ref. *)
let builtin_vec_iter =
  V_builtin ("vec_iter", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_iter_p1", fun f ->
        Array.iter (fun x -> ignore (!apply_value_ref f x)) (vecbuf_live arr);
        V_unit)
    | _ -> failwith "vec_iter: expected Vec")

let builtin_vec_map =
  V_builtin ("vec_map", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_map_p1", fun f ->
        let mapped = Array.map (fun x -> !apply_value_ref f x) (vecbuf_live arr) in
        V_vec (vecbuf_of_array mapped))
    | _ -> failwith "vec_map: expected Vec")

let builtin_vec_fold =
  V_builtin ("vec_fold", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_fold_p1", fun init ->
        V_builtin ("vec_fold_p2", fun f ->
          Array.fold_left (fun acc x ->
            let acc_x = !apply_value_ref f acc in
            !apply_value_ref acc_x x
          ) init (vecbuf_live arr)))
    | _ -> failwith "vec_fold: expected Vec")

(* Phase 19.2: map_iter — call (K -> V -> unit) for each entry.
   Curried closure: apply f to K (returns inner V_builtin), apply
   inner to V (returns unit). *)
let builtin_map_iter =
  V_builtin ("map_iter", fun v ->
    match v with
    | V_map m ->
      V_builtin ("map_iter_p1", fun f ->
        (* Phase 27.1: iterate in insertion order so output matches
           C / LLVM / Wasm Map runtime (which all use parallel arrays). *)
        List.iter (fun k ->
          let vv = Hashtbl.find m.m_tbl k in
          let f_k = !apply_value_ref f k in
          ignore (!apply_value_ref f_k vv)
        ) (map_live_keys m);
        V_unit)
    | _ -> failwith "map_iter: expected Map")

let builtin_vec_set =
  V_builtin ("vec_set", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_set_p1", fun idx ->
        V_builtin ("vec_set_p2", fun new_val ->
          match idx with
          | V_int i ->
            if i < 0 || i >= arr.vc_len then
              raise (Eval_error (Loc.dummy,
                Printf.sprintf "vec_set: index %d out of bounds (len = %d)"
                  i arr.vc_len))
            else begin
              arr.vc_data.(i) <- new_val;
              V_unit
            end
          | _ -> failwith "vec_set: expected int index"))
    | _ -> failwith "vec_set: expected Vec")

(* Phase 19.3: vec_reverse (in-place) / vec_concat (returns new Vec). *)
let builtin_vec_reverse =
  V_builtin ("vec_reverse", fun v ->
    match v with
    | V_vec arr ->
      let n = arr.vc_len in
      for i = 0 to (n / 2) - 1 do
        let j = n - 1 - i in
        let tmp = arr.vc_data.(i) in
        arr.vc_data.(i) <- arr.vc_data.(j);
        arr.vc_data.(j) <- tmp
      done;
      V_unit
    | _ -> failwith "vec_reverse: expected Vec")

let builtin_vec_concat =
  V_builtin ("vec_concat", fun v1 ->
    match v1 with
    | V_vec a1 ->
      V_builtin ("vec_concat_p1", fun v2 ->
        match v2 with
        | V_vec a2 ->
          V_vec (vecbuf_of_array (Array.append (vecbuf_live a1) (vecbuf_live a2)))
        | _ -> failwith "vec_concat: 2nd arg expected Vec")
    | _ -> failwith "vec_concat: 1st arg expected Vec")

(* Phase 19.3: vec_sort — in-place sort with comparator (T -> T -> int).
   Negative/0/positive convention like strcmp. *)
let builtin_vec_sort =
  V_builtin ("vec_sort", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_sort_p1", fun cmp ->
        let compare_v a b =
          let inner = !apply_value_ref cmp a in
          match !apply_value_ref inner b with
          | V_int n -> n
          | _ -> failwith "vec_sort: comparator must return int"
        in
        (* v0.1.349: the same bottom-up stable merge sort the compiled backends
           emit, written out here rather than delegated to Array.sort, because
           two properties of a sort are observable from a Mere program and
           Array.sort matched the compiled backends on neither:

             - stability. Array.sort is unstable, an insertion sort is stable,
               and the two printed equal-keyed elements in different orders.
             - the comparison sequence. A comparator is an arbitrary Mere
               closure and may count, print, or mutate; "how many times, in
               what order" is part of what the program does, so the four
               backends have to run the same algorithm, not merely produce
               sorted output. Array.stable_sort would fix the first and leave
               the second.

           Held to the compiled backends by test/parity/vec_sort_stable.mere,
           which prints the comparison count. *)
        let n = arr.vc_len in
        if n > 1 then begin
          let src = ref arr.vc_data in
          let dst = ref (Array.make n V_unit) in
          let w = ref 1 in
          while !w < n do
            let lo = ref 0 in
            while !lo < n do
              let mid = min (!lo + !w) n in
              let hi = min (!lo + 2 * !w) n in
              let i = ref !lo and j = ref mid in
              for k = !lo to hi - 1 do
                let take_right =
                  if !i >= mid then true
                  else if !j >= hi then false
                  else compare_v (!src).(!j) (!src).(!i) < 0
                in
                if take_right then begin
                  (!dst).(k) <- (!src).(!j); incr j
                end else begin
                  (!dst).(k) <- (!src).(!i); incr i
                end
              done;
              lo := !lo + 2 * !w
            done;
            let sw = !src in src := !dst; dst := sw;
            w := !w * 2
          done;
          if !src != arr.vc_data then Array.blit !src 0 arr.vc_data 0 n
        end;
        V_unit)
    | _ -> failwith "vec_sort: expected Vec")

(* Phase 12.11: vec_filter / vec_to_list / vec_to_owned。 *)
let builtin_vec_filter =
  V_builtin ("vec_filter", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_filter_p1", fun pred ->
        let filtered = Array.of_list (
          List.filter (fun x ->
            match !apply_value_ref pred x with
            | V_bool b -> b
            | _ -> failwith "vec_filter: predicate must return bool"
          ) (Array.to_list (vecbuf_live arr))
        ) in
        V_vec (vecbuf_of_array filtered))
    | _ -> failwith "vec_filter: expected Vec")

let builtin_vec_to_list =
  V_builtin ("vec_to_list", fun v ->
    match v with
    | V_vec arr ->
      Array.fold_right (fun x acc ->
        V_constr ("Cons", Some (V_tuple [x; acc]))
      ) (vecbuf_live arr) (V_constr ("Nil", None))
    | _ -> failwith "vec_to_list: expected Vec")

let builtin_vec_to_owned =
  V_builtin ("vec_to_owned", fun v ->
    match v with
    | V_vec arr ->
      (* Deep copy: the underlying mutable array is duplicated so the
         OwnedVec result is independent of the source Vec's lifetime. *)
      V_vec (vecbuf_of_array (Array.copy (vecbuf_live arr)))
    | _ -> failwith "vec_to_owned: expected Vec")

(* Phase 12.12: the reverse direction OwnedVec[T] -> Vec[R, T]. The
   region is injected by a typer special-case from the call site's
   active_regions. The runtime is a simple deep copy (since V_vec is
   shared, Array.copy makes it independent). *)
let builtin_owned_vec_to_vec =
  V_builtin ("owned_vec_to_vec", fun v ->
    match v with
    | V_vec arr -> V_vec (vecbuf_of_array (Array.copy (vecbuf_live arr)))
    | _ -> failwith "owned_vec_to_vec: expected OwnedVec")

let builtin_iter_n =
  V_builtin ("iter_n", fun n_val ->
    match n_val with
    | V_int n ->
      V_builtin ("iter_n_partial", fun f ->
        for _ = 1 to n do
          ignore (!apply_value_ref f V_unit)
        done;
        V_unit)
    | _ -> failwith "iter_n: 1st arg expected int")

let builtin_str_eq =
  V_builtin ("str_eq", fun a_val ->
    match a_val with
    | V_str a ->
      V_builtin ("str_eq_partial", fun b_val ->
        match b_val with
        | V_str b -> V_bool (a = b)
        | _ -> failwith "str_eq: 2nd arg expected str")
    | _ -> failwith "str_eq: 1st arg expected str")

let builtin_str_starts_with =
  V_builtin ("str_starts_with", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("str_starts_with_partial", fun p_val ->
        match p_val with
        | V_str p ->
          let s_len = String.length s in
          let p_len = String.length p in
          V_bool (p_len <= s_len && String.sub s 0 p_len = p)
        | _ -> failwith "str_starts_with: 2nd arg expected str")
    | _ -> failwith "str_starts_with: 1st arg expected str")

let builtin_str_replace =
  V_builtin ("str_replace", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("str_replace_p1", fun old_val ->
        match old_val with
        | V_str old_str ->
          V_builtin ("str_replace_p2", fun new_val ->
            match new_val with
            | V_str new_str ->
              if old_str = "" then V_str s
              else begin
                let old_len = String.length old_str in
                let s_len = String.length s in
                let buf = Buffer.create s_len in
                let rec loop i =
                  if i + old_len > s_len then
                    Buffer.add_substring buf s i (s_len - i)
                  else if String.sub s i old_len = old_str then begin
                    Buffer.add_string buf new_str;
                    loop (i + old_len)
                  end else begin
                    Buffer.add_char buf s.[i];
                    loop (i + 1)
                  end
                in
                loop 0;
                V_str (Buffer.contents buf)
              end
            | _ -> failwith "str_replace: 3rd arg expected str")
        | _ -> failwith "str_replace: 2nd arg expected str")
    | _ -> failwith "str_replace: 1st arg expected str")

let builtin_substring =
  V_builtin ("substring", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("substring_p1", fun start_val ->
        match start_val with
        | V_int start ->
          V_builtin ("substring_p2", fun end_val ->
            match end_val with
            | V_int end_ ->
              let len = String.length s in
              if start < 0 || end_ > len || start > end_ then
                raise (Eval_error (Loc.dummy,
                  Printf.sprintf
                    "substring: range [%d, %d) invalid for str of length %d"
                    start end_ len))
              else V_str (String.sub s start (end_ - start))
            | _ -> failwith "substring: 3rd arg expected int")
        | _ -> failwith "substring: 2nd arg expected int")
    | _ -> failwith "substring: 1st arg expected str")

let builtin_str_repeat =
  V_builtin ("str_repeat", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("str_repeat_partial", fun n_val ->
        match n_val with
        | V_int n when n < 0 ->
          raise (Eval_error (Loc.dummy,
            Printf.sprintf "str_repeat: negative count %d" n))
        | V_int 0 -> V_str ""
        | V_int n ->
          let buf = Buffer.create (String.length s * n) in
          for _ = 1 to n do Buffer.add_string buf s done;
          V_str (Buffer.contents buf)
        | _ -> failwith "str_repeat: 2nd arg expected int")
    | _ -> failwith "str_repeat: 1st arg expected str")

let builtin_str_ends_with =
  V_builtin ("str_ends_with", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("str_ends_with_partial", fun p_val ->
        match p_val with
        | V_str p ->
          let s_len = String.length s in
          let p_len = String.length p in
          V_bool (p_len <= s_len && String.sub s (s_len - p_len) p_len = p)
        | _ -> failwith "str_ends_with: 2nd arg expected str")
    | _ -> failwith "str_ends_with: 1st arg expected str")

let builtin_str_trim =
  V_builtin ("str_trim", fun v ->
    match v with
    | V_str s -> V_str (String.trim s)
    | _ -> failwith "str_trim: expected str")

let builtin_is_digit =
  V_builtin ("is_digit", fun v ->
    match v with
    | V_str s when String.length s = 1 ->
      let c = s.[0] in
      V_bool (c >= '0' && c <= '9')
    | V_str _ -> V_bool false
    | _ -> failwith "is_digit: expected str")

let builtin_is_alpha =
  V_builtin ("is_alpha", fun v ->
    match v with
    | V_str s when String.length s = 1 ->
      let c = s.[0] in
      V_bool ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
    | V_str _ -> V_bool false
    | _ -> failwith "is_alpha: expected str")

let builtin_is_space =
  V_builtin ("is_space", fun v ->
    match v with
    | V_str s when String.length s = 1 ->
      let c = s.[0] in
      V_bool (c = ' ' || c = '\t' || c = '\n' || c = '\r')
    | V_str _ -> V_bool false
    | _ -> failwith "is_space: expected str")

let builtin_str_unescape =
  V_builtin ("str_unescape", fun v ->
    match v with
    | V_str s ->
      let n = String.length s in
      let buf = Buffer.create n in
      let rec loop i =
        if i >= n then ()
        else if s.[i] = '\\' && i + 1 < n then
          let c = match s.[i + 1] with
            | 'n'  -> '\n'
            | 't'  -> '\t'
            | 'r'  -> '\r'
            | '\\' -> '\\'
            | '"'  -> '"'
            | '/'  -> '/'
            | c ->
              raise (Eval_error (Loc.dummy,
                Printf.sprintf "str_unescape: unknown escape '\\%c'" c))
          in
          Buffer.add_char buf c;
          loop (i + 2)
        else begin
          Buffer.add_char buf s.[i];
          loop (i + 1)
        end
      in
      loop 0;
      V_str (Buffer.contents buf)
    | _ -> failwith "str_unescape: expected str")

let builtin_str_rev =
  V_builtin ("str_rev", fun v ->
    match v with
    | V_str s ->
      let n = String.length s in
      V_str (String.init n (fun i -> s.[n - 1 - i]))
    | _ -> failwith "str_rev: expected str")

let builtin_to_upper =
  V_builtin ("to_upper", fun v ->
    match v with
    | V_str s -> V_str (String.uppercase_ascii s)
    | _ -> failwith "to_upper: expected str")

let builtin_to_lower =
  V_builtin ("to_lower", fun v ->
    match v with
    | V_str s -> V_str (String.lowercase_ascii s)
    | _ -> failwith "to_lower: expected str")

let builtin_chr =
  V_builtin ("chr", fun v ->
    match v with
    | V_int n ->
      if n < 0 || n > 255 then
        raise (Eval_error (Loc.dummy,
          Printf.sprintf "chr: %d out of byte range [0, 255]" n))
      else V_str (String.make 1 (Char.chr n))
    | _ -> failwith "chr: expected int")

let builtin_ord =
  V_builtin ("ord", fun v ->
    match v with
    | V_str s ->
      if String.length s <> 1 then
        raise (Eval_error (Loc.dummy,
          Printf.sprintf "ord: expected single-char str, got length %d"
            (String.length s)))
      else V_int (Char.code s.[0])
    | _ -> failwith "ord: expected str")

let builtin_char_at =
  V_builtin ("char_at", fun s_val ->
    match s_val with
    | V_str s ->
      V_builtin ("char_at_partial", fun i_val ->
        match i_val with
        | V_int i ->
          if i < 0 || i >= String.length s then
            raise (Eval_error (Loc.dummy,
              Printf.sprintf "char_at: index %d out of range (len=%d)"
                i (String.length s)))
          else V_str (String.sub s i 1)
        | _ -> failwith "char_at: 2nd arg expected int")
    | _ -> failwith "char_at: 1st arg expected str")

(* Phase 32.1 (C1 FFI): OCaml mock implementations for extern fns. The
   3 codegen backends call the real C functions, but the interpreter
   goes through this mock at eval time to maintain 4-backend parity.
   Unknown extern names are rejected by lookup_extern with a helpful
   error. *)
(* The flat byte arena, mirroring the one codegen_c emits: a bump allocator over
   a fixed buffer, addressed by offsets, with the low bytes left as a null-ish
   guard. Without this the interpreter could not run a program that touches the
   arena at all, which meant scripts/ctest.sh compile-checked those programs and
   never compared their answers — and that is where `mem_get_u32be` sign-extending
   0x80000000 hid. Same capacity and same first offset, so the two agree on
   arithmetic as well as on values. *)
let arena_cap = 16 * 1024 * 1024
let arena = Bytes.make arena_cap '\000'
let arena_top = ref 8
let arena_lock = Mutex.create ()

let arena_bump (n : int) : int =
  Mutex.lock arena_lock;
  let p = !arena_top in
  let n = if n <= 0 then 1 else n in
  if p + n > arena_cap then begin
    Mutex.unlock arena_lock;
    failwith
      (Printf.sprintf
         "mem_alloc: byte arena exhausted (%d bytes requested; the arena is a \
          bump allocator with no free — reuse buffers instead of allocating per \
          request)" n)
  end else begin
    arena_top := p + n;
    Mutex.unlock arena_lock;
    p
  end

let arena_get (i : int) : int = Char.code (Bytes.get arena i)
let arena_set (i : int) (b : int) : unit =
  Bytes.set arena i (Char.chr (b land 0xff))

(* Two- and three-argument externs, spelled out because the mock table is
   curried builtins rather than a table of arities. *)
let extern2 name f =
  V_builtin (name, fun a ->
    V_builtin (name ^ "1", fun b -> f a b))

let extern3 name f =
  V_builtin (name, fun a ->
    V_builtin (name ^ "1", fun b ->
      V_builtin (name ^ "2", fun c -> f a b c)))

let want_int who = function
  | V_int i -> i
  | _ -> failwith (who ^ ": expected int")

let lookup_extern (name : string) (_ty : Ast.ty) : value =
  match name with
  | "mem_alloc" ->
    V_builtin ("mem_alloc", fun v -> V_int (arena_bump (want_int "mem_alloc" v)))
  | "mem_set_u8" ->
    extern3 "mem_set_u8" (fun p off b ->
      arena_set (want_int "mem_set_u8" p + want_int "mem_set_u8" off)
        (want_int "mem_set_u8" b);
      V_int 0)
  | "mem_get_u8" ->
    extern2 "mem_get_u8" (fun p off ->
      V_int (arena_get (want_int "mem_get_u8" p + want_int "mem_get_u8" off)))
  | "mem_set_u16be" ->
    extern3 "mem_set_u16be" (fun p off v ->
      let i = want_int "mem_set_u16be" p + want_int "mem_set_u16be" off in
      let v = want_int "mem_set_u16be" v in
      arena_set i (v lsr 8); arena_set (i + 1) v;
      V_int 0)
  | "mem_get_u16be" ->
    extern2 "mem_get_u16be" (fun p off ->
      let i = want_int "mem_get_u16be" p + want_int "mem_get_u16be" off in
      V_int ((arena_get i lsl 8) lor arena_get (i + 1)))
  | "mem_set_u32be" ->
    extern3 "mem_set_u32be" (fun p off v ->
      let i = want_int "mem_set_u32be" p + want_int "mem_set_u32be" off in
      let v = want_int "mem_set_u32be" v in
      arena_set i (v lsr 24); arena_set (i + 1) (v lsr 16);
      arena_set (i + 2) (v lsr 8); arena_set (i + 3) v;
      V_int 0)
  | "mem_get_u32be" ->
    (* Unsigned, which is the whole point: 0xFF008080 is an opaque pixel, not a
       negative number. *)
    extern2 "mem_get_u32be" (fun p off ->
      let i = want_int "mem_get_u32be" p + want_int "mem_get_u32be" off in
      V_int ((arena_get i lsl 24) lor (arena_get (i + 1) lsl 16)
             lor (arena_get (i + 2) lsl 8) lor arena_get (i + 3)))
  | "str_ptr" ->
    V_builtin ("str_ptr", fun v ->
      match v with
      | V_str s ->
        let n = String.length s in
        let p = arena_bump (n + 1) in
        Bytes.blit_string s 0 arena p n;
        arena_set (p + n) 0;
        V_int p
      | _ -> failwith "str_ptr: expected str")
  | "mem_copy_str" ->
    extern3 "mem_copy_str" (fun dst off s ->
      match s with
      | V_str s ->
        let d = want_int "mem_copy_str" dst + want_int "mem_copy_str" off in
        (* Stops at the first NUL, as the C one does — the count it returns is
           what the caller writes a length field from. *)
        let n =
          match String.index_opt s '\000' with
          | Some i -> i
          | None -> String.length s in
        Bytes.blit_string s 0 arena d n;
        V_int n
      | _ -> failwith "mem_copy_str: 3rd arg expected str")
  | "mem_to_str" ->
    extern2 "mem_to_str" (fun p len ->
      let p = want_int "mem_to_str" p and len = want_int "mem_to_str" len in
      V_str (Bytes.sub_string arena p len))
  | "getpid" ->
    V_builtin ("getpid", fun v ->
      match v with
      | V_unit -> V_int (Unix.getpid ())
      | _ -> failwith "getpid: expected unit")
  | "getenv" ->
    V_builtin ("getenv", fun v ->
      match v with
      | V_str s -> (try V_str (Sys.getenv s) with Not_found -> V_str "")
      | _ -> failwith "getenv: expected str")
  | "system" ->
    V_builtin ("system", fun v ->
      match v with
      | V_str s -> V_int (Sys.command s)
      | _ -> failwith "system: expected str")
  | "sleep" ->
    V_builtin ("sleep", fun v ->
      match v with
      | V_int n ->
        (if vclock_on then sched_sleep (float_of_int n) else Unix.sleep n);
        V_int 0
      | _ -> failwith "sleep: expected int")
  | "srand" ->
    V_builtin ("srand", fun v ->
      match v with
      | V_int n -> Random.init n; V_unit
      | _ -> failwith "srand: expected int")
  | "rand" ->
    V_builtin ("rand", fun v ->
      match v with
      | V_unit -> V_int (Random.int max_int)
      | _ -> failwith "rand: expected unit")
  | "unix_time" ->
    V_builtin ("unix_time", fun v ->
      match v with
      | V_unit -> V_int (int_of_float (Unix.time ()))
      | _ -> failwith "unix_time: expected unit")
  | "getppid" ->
    V_builtin ("getppid", fun v ->
      match v with
      | V_unit -> V_int (Unix.getppid ())
      | _ -> failwith "getppid: expected unit")
  | "setenv" ->
    (* setenv: str -> str -> int -> int — curried 3-arg *)
    V_builtin ("setenv", fun a ->
      match a with
      | V_str name ->
        V_builtin ("setenv1", fun b ->
          match b with
          | V_str value ->
            V_builtin ("setenv2", fun c ->
              match c with
              | V_int _overwrite ->
                Unix.putenv name value; V_int 0
              | _ -> failwith "setenv: 3rd arg expected int")
          | _ -> failwith "setenv: 2nd arg expected str")
      | _ -> failwith "setenv: 1st arg expected str")
  | _ ->
    (* Phase 32.1: unknown extern fails at call time rather than lookup
       (so that program analysis can still pass / running via codegen
       is not blocked). *)
    V_builtin (name, fun _v ->
      failwith (Printf.sprintf
        "extern fn %S: no interp mock implementation. Add a case to \
         Eval.lookup_extern, or run via codegen (-c / -ll / -w)." name))

(* === Q-012 step 3a: concurrency primitives (interp) ===
   spawn runs a `unit -> unit` closure on a fresh OCaml 5 domain (real
   multicore parallelism). A channel is a blocking FIFO guarded by a
   Mutex + Condition. This is the "thin runnable slice" (Plan Y): it lets
   test programs actually run two loops in one process; the full Send/Sync
   trait check + move tracking arrive with the shared-memory C backend. *)
(* ---- v0.1.304: a registry of live threads -------------------------------

   `spawn` used to build a V_thread and drop everything else on the floor: the
   runtime could not say how many workers existed, let alone what any of them was
   waiting for. A worker parked forever on a channel nobody sends to therefore
   cost nothing and said nothing -- the program printed its last line and exited
   0 with the thread still blocked.

   This is the answerable half of Go 1.27's `goroutineleak` profile. Go looks for
   goroutines blocked on synchronisation primitives that have become
   UNREACHABLE, which takes a tracing collector to decide; regions cannot answer
   it. What is answerable here is narrower and still worth saying: at exit, which
   threads are still blocked, and on what.

   WHICH ONES COUNT IS THE HARD PART, and the language already had the answer.
   `detach` means "I am not going to join this one", and a server's accept loop
   is SUPPOSED to block forever. So a thread is reported only when it was neither
   joined nor detached -- nobody claimed it and nobody disowned it. Without that
   distinction the report would call every well-formed server a leak, which is
   how a diagnostic gets ignored.

   Off unless MERE_THREAD_REPORT is set, and written to stderr. Go's profile is
   something you ask for as well, and a diagnostic on stdout would change what
   every existing program prints.

   Not covered: the MAIN thread blocking forever (it is never registered -- and
   a main that never returns is a hang, which is visible without a report), and
   anything the C backend does, which has its own runtime and its own pthreads. *)
type thread_wait =
  | T_running
  | T_blocked of string
  | T_finished
  (* v0.1.305: an uncaught failure in a worker used to vanish unless somebody
     joined the handle -- the domain stores the exception and nobody asks. The
     registry now keeps what killed it, so the leak report can say which
     failure went nowhere. *)
  | T_died of string

let thr_lock = Mutex.create ()
let thr_status : (int, string * thread_wait ref) Hashtbl.t = Hashtbl.create 8
(* id -> "joined" | "detached": the two ways a thread stops being anybody's
   business. Kept apart from thr_status because the parent writes this and the
   child writes that. *)
let thr_claimed : (int, string) Hashtbl.t = Hashtbl.create 8
let thr_seq = ref 0
let thr_hooked = ref false

let thr_guard : 'a. (unit -> 'a) -> 'a = fun f ->
  Mutex.lock thr_lock;
  match f () with
  | v -> Mutex.unlock thr_lock; v
  | exception e -> Mutex.unlock thr_lock; raise e

let thr_me () = (Domain.self () :> int)

let thr_set_wait w =
  thr_guard (fun () ->
    match Hashtbl.find_opt thr_status (thr_me ()) with
    | Some (_, st) -> st := w
    | None -> ())

(* Bracket a block so the status is restored however the wait ends -- a raise
   out of a wait would otherwise leave the thread reading as blocked for the
   rest of the program. *)
let thr_waiting what f =
  thr_set_wait (T_blocked what);
  match f () with
  | v -> thr_set_wait T_running; v
  | exception e -> thr_set_wait T_running; raise e

let thr_report () =
  let leaked =
    thr_guard (fun () ->
      Hashtbl.fold (fun id (label, st) acc ->
        if Hashtbl.mem thr_claimed id then acc
        else
          let why = match !st with
            | T_blocked what -> "blocked on " ^ what
            | T_running -> "still running"
            | T_finished -> "finished, never joined"
            | T_died msg -> "died: " ^ msg ^ ", never joined"
          in
          (label, why) :: acc)
        thr_status [])
  in
  if leaked <> [] then begin
    Printf.eprintf
      "mere: %d thread(s) neither joined nor detached at exit\n"
      (List.length leaked);
    List.iter (fun (label, why) -> Printf.eprintf "  %s: %s\n" label why)
      (List.sort compare leaked)
  end

let thr_install_hook () =
  let need =
    thr_guard (fun () ->
      if !thr_hooked then false else (thr_hooked := true; true))
  in
  if need && Sys.getenv_opt "MERE_THREAD_REPORT" <> None then at_exit thr_report

let builtin_spawn =
  V_builtin ("spawn", fun clos ->
    let n = thr_guard (fun () -> incr thr_seq; !thr_seq) in
    let label = Printf.sprintf "thread %d" n in
    thr_install_hook ();
    if vclock_on then sched_add_live ();
    V_thread (Domain.spawn (fun () ->
      let me = thr_me () in
      thr_guard (fun () -> Hashtbl.replace thr_status me (label, ref T_running));
      match !apply_value_ref clos V_unit with
      | v ->
        thr_set_wait T_finished;
        if vclock_on then sched_drop_live ();
        v
      | exception e ->
        let why = match e with
          | Eval_error (_, m) -> m
          | Failure m -> m
          | e -> Printexc.to_string e
        in
        thr_set_wait (T_died why);
        if vclock_on then sched_drop_live ();
        raise e)))

let builtin_join =
  V_builtin ("join", fun h ->
    match h with
    | V_thread d when vclock_on ->
      (* Domain.join itself is invisible to the scheduler, so first park on the
         registry saying the worker is done (its status is written BEFORE its
         live-count drops, so the broadcast cannot arrive early), then the real
         join returns without blocking. *)
      let id = (Domain.get_id d :> int) in
      ignore (thr_waiting "join" (fun () ->
        sched_wait (fun () ->
          thr_guard (fun () ->
            match Hashtbl.find_opt thr_status id with
            | Some (_, st) ->
              (match !st with T_finished | T_died _ -> true | _ -> false)
            | None -> false))));
      ignore (Domain.join d);
      thr_guard (fun () -> Hashtbl.replace thr_claimed id "joined");
      V_unit
    | V_thread d ->
      let id = (Domain.get_id d :> int) in
      ignore (Domain.join d);
      thr_guard (fun () -> Hashtbl.replace thr_claimed id "joined");
      V_unit
    | _ -> failwith "join: expected a ThreadHandle")

(* v0.1.84 (mhttpd dogfood): fire-and-forget. The reference interpreter has
   no domain-detach, so this is a no-op that leaves the worker running
   unawaited — matching the observable fire-and-forget semantics (the C
   backend calls pthread_detach to release the thread's resources). *)
let builtin_detach =
  V_builtin ("detach", fun h ->
    match h with
    | V_thread d ->
      (* v0.1.304: a detached thread is disowned on purpose, so the leak report
         does not name it. This is the one place the language says "blocking
         forever here is the intent". *)
      thr_guard (fun () ->
        Hashtbl.replace thr_claimed (Domain.get_id d :> int) "detached");
      V_unit
    | _ -> failwith "detach: expected a ThreadHandle")

let builtin_channel_new =
  V_builtin ("channel_new", fun _ ->
    V_channel (Queue.create (), Mutex.create (), Condition.create (), ref false))

let builtin_channel_send =
  V_builtin ("channel_send", fun ch ->
    match ch with
    | V_channel (q, m, c, closed) ->
      V_builtin ("channel_send_p", fun v ->
        Mutex.lock m;
        if !closed then begin
          Mutex.unlock m;
          raise (Eval_error (Loc.dummy, "channel_send: channel is closed"))
        end;
        Queue.push v q;
        Condition.signal c;
        Mutex.unlock m;
        (* Under the virtual clock, receivers park on the scheduler condvar,
           not the channel's -- tell them the world changed. Never called with
           the channel mutex held (lock order: scheduler first, channel second). *)
        if vclock_on then sched_notify ();
        V_unit)
    | _ -> failwith "channel_send: expected a Channel")

let builtin_channel_recv =
  V_builtin ("channel_recv", fun ch ->
    match ch with
    | V_channel (q, m, c, closed) when vclock_on ->
      ignore c;
      let rec take () =
        Mutex.lock m;
        if not (Queue.is_empty q) then begin
          let v = Queue.pop q in Mutex.unlock m; v
        end else if !closed then begin
          Mutex.unlock m;
          raise (Eval_error (Loc.dummy,
                             "channel_recv: channel is closed and empty"))
        end else begin
          Mutex.unlock m;
          ignore (thr_waiting "channel_recv" (fun () ->
            sched_wait (fun () ->
              Mutex.lock m;
              let ready = not (Queue.is_empty q) || !closed in
              Mutex.unlock m; ready)));
          (* pred true means SOMETHING is there, not that it is ours -- another
             receiver may take it first, so go round and look again. *)
          take ()
        end
      in
      take ()
    | V_channel (q, m, c, closed) ->
      Mutex.lock m;
      thr_waiting "channel_recv" (fun () ->
        while Queue.is_empty q && not !closed do Condition.wait c m done);
      (* v0.1.47: a closed, drained channel used to block forever; now
         recv on it raises (use channel_recv_opt for the shutdown path). *)
      if Queue.is_empty q then begin
        Mutex.unlock m;
        raise (Eval_error (Loc.dummy, "channel_recv: channel is closed and empty"))
      end;
      let v = Queue.pop q in
      Mutex.unlock m;
      v
    | _ -> failwith "channel_recv: expected a Channel")

(* v0.1.47 (structured concurrency): close a channel. After close, sends
   raise and channel_recv_opt returns None once the queue drains. *)
let builtin_channel_close =
  V_builtin ("channel_close", fun ch ->
    match ch with
    | V_channel (_, m, c, closed) ->
      Mutex.lock m;
      closed := true;
      Condition.broadcast c;   (* wake every blocked recv so they see None *)
      Mutex.unlock m;
      if vclock_on then sched_notify ();
      V_unit
    | _ -> failwith "channel_close: expected a Channel")

(* channel_recv_opt: block for a value; return None when the channel is
   closed and empty. This is the primitive that lets a worker loop
   terminate (return unit) instead of blocking forever — which also
   means the loop is no longer bottom-typed, so it compiles. *)
(* v0.1.59 (mgrep dogfood): streaming per-line file input. EOF is None
   (option), not read_line's ambiguous "" sentinel. file_open fails on a
   missing path (catchable with try_or, matching read_file). *)
let builtin_file_open =
  V_builtin ("file_open", fun v ->
    match v with
    | V_str path ->
      (try V_file (open_in path)
       with Sys_error msg -> failwith ("file_open: " ^ msg))
    | _ -> failwith "file_open: expected str")

let builtin_file_read_line =
  V_builtin ("file_read_line", fun v ->
    match v with
    | V_file ch ->
      (try V_constr ("Some", Some (V_str (input_line ch)))
       with End_of_file -> V_constr ("None", None))
    | _ -> failwith "file_read_line: expected File")

(* Physical memory and machine CSRs exist only on the RV32I bare-metal target:
   there is no honest interpretation of a physical address or a trap vector in
   a hosted process, so these refuse loudly rather than pretending. They are
   bound at all (rather than left unbound) so the failure names the reason
   instead of reading like a typo. *)
let bare_only name =
  V_builtin (name, fun _ ->
    failwith (name ^ ": only available on the RV32I bare-metal target \
                      (mere -rv --bare)"))

let builtin_file_close =
  V_builtin ("file_close", fun v ->
    match v with
    | V_file ch -> close_in ch; V_unit
    | V_rwfile fd -> (try Unix.close fd with Unix.Unix_error _ -> ()); V_unit
    | _ -> failwith "file_close: expected File")

(* v0.1.115 (mbtree dogfood): read/write handle. `file_openrw path` opens the
   file for reading and writing, creating it (empty) if absent and NOT
   truncating an existing one — the open mode a random-access on-disk store
   needs. Returns a File handle usable with file_pread / file_pwrite /
   file_fsync / file_close. *)
let builtin_file_openrw =
  V_builtin ("file_openrw", fun v ->
    match v with
    | V_str path ->
      (try V_rwfile (Unix.openfile path [Unix.O_RDWR; Unix.O_CREAT] 0o644)
       with Unix.Unix_error (e, _, _) ->
         failwith ("file_openrw: " ^ path ^ ": " ^ Unix.error_message e))
    | _ -> failwith "file_openrw: expected str")

(* `file_pwrite handle offset bytes` writes the Vec[int]'s bytes at `offset`
   (extending the file if it writes past the current end) and returns the
   number of bytes written. The write half of file_pread. *)
let builtin_file_pwrite =
  V_builtin ("file_pwrite", fun fv ->
    match fv with
    | V_rwfile fd ->
      V_builtin ("file_pwrite_off", fun ov ->
        match ov with
        | V_int off ->
          V_builtin ("file_pwrite_bytes", fun bv ->
            match bv with
            | V_vec arr ->
              let a = vecbuf_live arr in
              let len = Array.length a in
              let buf = Bytes.create len in
              Array.iteri (fun i x ->
                match x with
                | V_int b ->
                  if b < 0 || b > 255 then
                    failwith (Printf.sprintf
                      "file_pwrite: byte value %d out of range 0..255" b);
                  Bytes.set buf i (Char.chr b)
                | _ -> failwith "file_pwrite: expected int vec") a;
              ignore (Unix.lseek fd off Unix.SEEK_SET);
              let rec write_all pos =
                if pos >= len then ()
                else
                  let n = Unix.write fd buf pos (len - pos) in
                  if n <= 0 then () else write_all (pos + n)
              in
              write_all 0;
              V_int len
            | _ -> failwith "file_pwrite: expected int vec")
        | _ -> failwith "file_pwrite: offset expected int")
    | _ -> failwith "file_pwrite: expected read/write File (use file_openrw)")

(* v0.1.222 (mraft dogfood): the same positioned write over `bytes`. The Vec
   version predates the bytes type, so a program with a byte string in hand had to
   turn it into one boxed int per byte first. *)
let builtin_file_pwrite_bytes =
  V_builtin ("file_pwrite_bytes", fun fv ->
    match fv with
    | V_rwfile fd ->
      V_builtin ("file_pwrite_bytes_off", fun ov ->
        match ov with
        | V_int off ->
          V_builtin ("file_pwrite_bytes_data", fun bv ->
            match bv with
            | V_bytes s ->
              (* V_bytes carries an immutable string; Unix.write wants bytes. *)
              let buf = Bytes.of_string s in
              let len = Bytes.length buf in
              ignore (Unix.lseek fd off Unix.SEEK_SET);
              let rec write_all pos =
                if pos >= len then ()
                else
                  let n = Unix.write fd buf pos (len - pos) in
                  if n <= 0 then () else write_all (pos + n)
              in
              write_all 0;
              V_int len
            | _ -> failwith "file_pwrite_bytes: expected bytes")
        | _ -> failwith "file_pwrite_bytes: offset expected int")
    | _ ->
      failwith "file_pwrite_bytes: expected read/write File (use file_openrw)")

(* `file_fsync handle` flushes buffered writes to stable storage. A durable
   store calls it at commit points. *)
let builtin_file_fsync =
  V_builtin ("file_fsync", fun v ->
    match v with
    | V_rwfile fd -> (try Unix.fsync fd with Unix.Unix_error _ -> ()); V_unit
    | _ -> failwith "file_fsync: expected read/write File (use file_openrw)")

(* v0.1.83 (msqlite dogfood): positioned read. `file_pread ch off len` seeks
   to `off` and reads up to `len` bytes, returning a Vec[int]. Reads fewer
   than `len` bytes only when `off + len` runs past EOF (partial tail); the
   returned Vec's length is the number of bytes actually read. *)
let builtin_file_pread =
  V_builtin ("file_pread", fun fv ->
    match fv with
    | V_file ch ->
      V_builtin ("file_pread_off", fun ov ->
        match ov with
        | V_int off ->
          V_builtin ("file_pread_len", fun lv ->
            match lv with
            | V_int len ->
              let flen = in_channel_length ch in
              let avail = if off >= flen then 0
                          else min len (flen - off) in
              let avail = if avail < 0 then 0 else avail in
              seek_in ch off;
              let buf = Bytes.create avail in
              really_input ch buf 0 avail;
              V_vec (vecbuf_of_array (Array.init avail
                (fun i -> V_int (Char.code (Bytes.get buf i)))))
            | _ -> failwith "file_pread: length expected int")
        | _ -> failwith "file_pread: offset expected int")
    | V_rwfile fd ->
      (* v0.1.115: positioned read on a read/write handle (file_openrw). *)
      V_builtin ("file_pread_off", fun ov ->
        match ov with
        | V_int off ->
          V_builtin ("file_pread_len", fun lv ->
            match lv with
            | V_int len ->
              let len = if len < 0 then 0 else len in
              ignore (Unix.lseek fd off Unix.SEEK_SET);
              let buf = Bytes.create len in
              let rec read_all pos =
                if pos >= len then pos
                else
                  let n = Unix.read fd buf pos (len - pos) in
                  if n <= 0 then pos else read_all (pos + n)
              in
              let got = read_all 0 in
              V_vec (vecbuf_of_array (Array.init got
                (fun i -> V_int (Char.code (Bytes.get buf i)))))
            | _ -> failwith "file_pread: length expected int")
        | _ -> failwith "file_pread: offset expected int")
    | _ -> failwith "file_pread: expected File")

let builtin_channel_recv_opt =
  V_builtin ("channel_recv_opt", fun ch ->
    match ch with
    | V_channel (q, m, c, closed) when vclock_on ->
      ignore c;
      let rec take () =
        Mutex.lock m;
        if not (Queue.is_empty q) then begin
          let v = Queue.pop q in
          Mutex.unlock m; V_constr ("Some", Some v)
        end else if !closed then begin
          Mutex.unlock m; V_constr ("None", None)
        end else begin
          Mutex.unlock m;
          ignore (thr_waiting "channel_recv_opt" (fun () ->
            sched_wait (fun () ->
              Mutex.lock m;
              let ready = not (Queue.is_empty q) || !closed in
              Mutex.unlock m; ready)));
          take ()
        end
      in
      take ()
    | V_channel (q, m, c, closed) ->
      Mutex.lock m;
      thr_waiting "channel_recv_opt" (fun () ->
        while Queue.is_empty q && not !closed do Condition.wait c m done);
      let result =
        if Queue.is_empty q then V_constr ("None", None)
        else V_constr ("Some", Some (Queue.pop q))
      in
      Mutex.unlock m;
      result
    | _ -> failwith "channel_recv_opt: expected a Channel")

(* v0.1.48 (structured concurrency): channel_recv_timeout ch ms — block up
   to `ms` milliseconds for a value; return None on timeout (or once the
   channel is closed and drained). Lets a supervisor collect results
   without hanging on a stuck worker. The reference interpreter polls at
   1 ms granularity (there is no timed condition wait in the stdlib); the
   C backend uses pthread_cond_timedwait. *)
let builtin_channel_recv_timeout =
  V_builtin ("channel_recv_timeout", fun ch ->
    match ch with
    | V_channel (q, m, c, closed) ->
      let _ = c in
      V_builtin ("channel_recv_timeout_p", fun tv ->
        match tv with
        | V_int ms when vclock_on ->
          (* The deadline is absolute virtual time, fixed once -- re-entering
             the wait after losing a value to another receiver must not extend
             it. ms = 0 stays a non-blocking try-recv: the deadline is already
             here, so the wait answers immediately. *)
          let dl = sched_now () +. (float_of_int ms /. 1000.0) in
          let rec take () =
            Mutex.lock m;
            if not (Queue.is_empty q) then begin
              let v = Queue.pop q in
              Mutex.unlock m; V_constr ("Some", Some v)
            end else if !closed then begin
              Mutex.unlock m; V_constr ("None", None)
            end else begin
              Mutex.unlock m;
              let alive = thr_waiting "channel_recv_timeout" (fun () ->
                sched_wait ~deadline:dl (fun () ->
                  Mutex.lock m;
                  let ready = not (Queue.is_empty q) || !closed in
                  Mutex.unlock m; ready))
              in
              if alive then take ()
              else begin
                Mutex.lock m;
                let r =
                  if not (Queue.is_empty q) then
                    V_constr ("Some", Some (Queue.pop q))
                  else V_constr ("None", None)
                in
                Mutex.unlock m; r
              end
            end
          in
          take ()
        | V_int ms ->
          let deadline = Unix.gettimeofday () +. (float_of_int ms /. 1000.0) in
          (* The timeout form polls rather than waiting on the condition, so the
             mark covers the whole poll rather than one iteration of it. *)
          let rec poll () =
            Mutex.lock m;
            if not (Queue.is_empty q) then begin
              let v = Queue.pop q in Mutex.unlock m; V_constr ("Some", Some v)
            end else if !closed then begin
              Mutex.unlock m; V_constr ("None", None)
            end else begin
              Mutex.unlock m;
              if Unix.gettimeofday () >= deadline then V_constr ("None", None)
              else begin Unix.sleepf 0.001; poll () end
            end
          in
          thr_waiting "channel_recv_timeout" poll
        | _ -> failwith "channel_recv_timeout: 2nd arg expected int")
    | _ -> failwith "channel_recv_timeout: expected a Channel")

(* Q-012 Phase 32: par_map f xs — apply f to each element in parallel (one
   OCaml domain per element) and collect the results in the original order.
   MVP: one domain per element (fine for small lists; a worker pool is a
   follow-up). Element types are Send-checked by the typer. *)
let builtin_par_map =
  V_builtin ("par_map", fun f ->
    V_builtin ("par_map_p", fun xs ->
      let elems =
        match try_as_list xs with
        | Some l -> l
        | None -> failwith "par_map: expected a list"
      in
      let domains =
        List.map (fun x ->
          (* Counted as live so the virtual clock refuses to advance past a
             worker that is still computing. The join below stays a real
             Domain.join, invisible to the scheduler -- so the clock also never
             advances while par_map's caller waits, which is conservative and
             correct: par_map is for computation, not for timers. *)
          if vclock_on then sched_add_live ();
          Domain.spawn (fun () ->
            match !apply_value_ref f x with
            | v -> if vclock_on then sched_drop_live (); v
            | exception e -> if vclock_on then sched_drop_live (); raise e))
          elems
      in
      let results = List.map Domain.join domains in
      List.fold_right
        (fun h tail -> V_constr ("Cons", Some (V_tuple [h; tail])))
        results (V_constr ("Nil", None))))

(* `bytes` builtins. Interp holds a bytes value as an OCaml
   string (NUL-safe), so most of these are thin wrappers. Index / slice raise
   on out-of-range, matching the str builtins' style. *)
let bytes_v s = V_bytes s
let expect_bytes name = function
  | V_bytes s -> s
  | _ -> failwith (name ^ ": expected bytes")

let builtin_bytes_len =
  V_builtin ("bytes_len", fun v -> V_int (String.length (expect_bytes "bytes_len" v)))

let builtin_bytes_get =
  V_builtin ("bytes_get", fun v ->
    let s = expect_bytes "bytes_get" v in
    V_builtin ("bytes_get_p1", fun i ->
      match i with
      | V_int i ->
        if i < 0 || i >= String.length s then
          raise (Eval_error (Loc.dummy, "bytes_get: index out of range"));
        V_int (Char.code s.[i])
      | _ -> failwith "bytes_get: expected int index"))

let builtin_bytes_slice =
  V_builtin ("bytes_slice", fun v ->
    let s = expect_bytes "bytes_slice" v in
    V_builtin ("bytes_slice_p1", fun start ->
      V_builtin ("bytes_slice_p2", fun len ->
        match start, len with
        | V_int start, V_int len ->
          if start < 0 || len < 0 || start + len > String.length s then
            raise (Eval_error (Loc.dummy, "bytes_slice: range out of bounds"));
          bytes_v (String.sub s start len)
        | _ -> failwith "bytes_slice: expected int start/len")))

let builtin_bytes_concat =
  V_builtin ("bytes_concat", fun a ->
    let a = expect_bytes "bytes_concat" a in
    V_builtin ("bytes_concat_p1", fun b ->
      bytes_v (a ^ expect_bytes "bytes_concat" b)))

let builtin_bytes_of_hex =
  V_builtin ("bytes_of_hex", fun v ->
    match v with V_str s -> bytes_v (string_of_hex s)
               | _ -> failwith "bytes_of_hex: expected str")

let builtin_hex_of_bytes =
  V_builtin ("hex_of_bytes", fun v -> V_str (hex_of_string (expect_bytes "hex_of_bytes" v)))

let builtin_bytes_of_str =
  V_builtin ("bytes_of_str", fun v ->
    match v with V_str s -> bytes_v s | _ -> failwith "bytes_of_str: expected str")

let builtin_str_of_bytes =
  V_builtin ("str_of_bytes", fun v -> V_str (expect_bytes "str_of_bytes" v))

(* The I/O boundary for `bytes`, which is where its absence hurt: everything in
   memory could be a `bytes` already, but reading, writing and printing one had to
   go through `str` or `Vec[int]`.

   Through `str` does not work at all in the compiled backends, where a `str` is a
   NUL-terminated C string: `print_no_nl (chr 0)` writes nothing there and the zero
   byte on the interpreter, so the same program produced different files depending
   on which backend ran it. A `bytes` carries its length in every backend, which is
   why these three can be correct. Found by the mpng dogfood. *)
let builtin_print_bytes =
  V_builtin ("print_bytes", fun v ->
    print_string (expect_bytes "print_bytes" v);
    flush stdout;
    V_unit)

let builtin_read_bytes =
  V_builtin ("read_bytes", fun v ->
    match v with
    | V_str path ->
      (try
         let ic = open_in_bin path in
         let n = in_channel_length ic in
         let s = really_input_string ic n in
         close_in ic;
         bytes_v s
       with Sys_error msg -> raise (Eval_error (Loc.dummy, "read_bytes: " ^ msg)))
    | _ -> failwith "read_bytes: expected str")

let builtin_write_bytes =
  V_builtin ("write_bytes", fun p ->
    match p with
    | V_str path ->
      V_builtin ("write_bytes_partial", fun v ->
        let s = expect_bytes "write_bytes" v in
        (try
           let oc = open_out_bin path in
           output_string oc s;
           close_out oc;
           V_unit
         with Sys_error msg -> raise (Eval_error (Loc.dummy, "write_bytes: " ^ msg))))
    | _ -> failwith "write_bytes: expected str")

let builtin_bytes_of_vec =
  V_builtin ("bytes_of_vec", fun v ->
    match v with
    | V_vec arr ->
      let a = vecbuf_live arr in
      let b = Buffer.create (Array.length a) in
      Array.iter (function
        | V_int n -> Buffer.add_char b (Char.chr (n land 0xFF))
        | _ -> failwith "bytes_of_vec: expected int elements") a;
      bytes_v (Buffer.contents b)
    | _ -> failwith "bytes_of_vec: expected Vec")

let builtin_vec_of_bytes =
  V_builtin ("vec_of_bytes", fun v ->
    let s = expect_bytes "vec_of_bytes" v in
    V_vec (vecbuf_of_array
             (Array.init (String.length s) (fun i -> V_int (Char.code s.[i])))))

let initial_env : env =
  [ ("print", ref builtin_print);
    (* bytes builtins *)
    ("bytes_len", ref builtin_bytes_len);
    ("bytes_get", ref builtin_bytes_get);
    ("bytes_slice", ref builtin_bytes_slice);
    ("bytes_concat", ref builtin_bytes_concat);
    ("bytes_of_hex", ref builtin_bytes_of_hex);
    ("hex_of_bytes", ref builtin_hex_of_bytes);
    ("bytebuf_new",  ref builtin_bytebuf_new);
    ("bytebuf_len",  ref builtin_bytebuf_len);
    ("bytebuf_get",  ref builtin_bytebuf_get);
    ("bytebuf_set",  ref builtin_bytebuf_set);
    ("bytebuf_push", ref builtin_bytebuf_push);
    ("bytes_of_bytebuf", ref builtin_bytes_of_bytebuf);
    ("bytebuf_of_bytes", ref builtin_bytebuf_of_bytes);
    ("print_bytes",  ref builtin_print_bytes);
    ("read_bytes",   ref builtin_read_bytes);
    ("write_bytes",  ref builtin_write_bytes);
    ("bytes_of_str", ref builtin_bytes_of_str);
    ("str_of_bytes", ref builtin_str_of_bytes);
    ("bytes_of_vec", ref builtin_bytes_of_vec);
    ("vec_of_bytes", ref builtin_vec_of_bytes);
    (* Q-012 step 3a: concurrency primitives *)
    ("spawn", ref builtin_spawn);
    ("join", ref builtin_join);
    ("detach", ref builtin_detach);
    ("channel_new", ref builtin_channel_new);
    ("channel_send", ref builtin_channel_send);
    ("channel_recv", ref builtin_channel_recv);
    ("channel_close", ref builtin_channel_close);
    ("channel_recv_opt", ref builtin_channel_recv_opt);
    ("stdin_byte", ref builtin_stdin_byte);
    ("raw_base", ref (bare_only "raw_base"));
    ("raw_len", ref (bare_only "raw_len"));
    ("trap_save", ref (bare_only "trap_save"));
    ("machine_scratch", ref (bare_only "machine_scratch"));
    ("closure_code", ref (bare_only "closure_code"));
    ("closure_env", ref (bare_only "closure_env"));
    ("set_trap_handler", ref (bare_only "set_trap_handler"));
    ("csr_read", ref (bare_only "csr_read"));
    ("csr_write", ref (bare_only "csr_write"));
    ("raw_window", ref (bare_only "raw_window"));
    ("raw_peek8", ref (bare_only "raw_peek8"));
    ("raw_peek32", ref (bare_only "raw_peek32"));
    ("raw_poke8", ref (bare_only "raw_poke8"));
    ("raw_poke32", ref (bare_only "raw_poke32"));
    ("file_open", ref builtin_file_open);
    ("file_read_line", ref builtin_file_read_line);
    ("file_close", ref builtin_file_close);
    ("file_openrw", ref builtin_file_openrw);
    ("file_pwrite", ref builtin_file_pwrite);
    ("file_pwrite_bytes", ref builtin_file_pwrite_bytes);
    ("file_fsync", ref builtin_file_fsync);
    ("channel_recv_timeout", ref builtin_channel_recv_timeout);
    ("par_map", ref builtin_par_map);
    ("read_line", ref builtin_read_line);
    ("read_stdin", ref builtin_read_stdin);
    ("run", ref builtin_run);
    ("tty_raw", ref builtin_tty_raw);
    ("tty_restore", ref builtin_tty_restore);
    ("read_key", ref builtin_read_key);
    ("file_size", ref builtin_file_size);
    ("time", ref builtin_time);
    ("exit", ref builtin_exit);
    ("int_max", ref (V_int max_int));
    ("int_min", ref (V_int min_int));
    ("print_no_nl", ref builtin_print_no_nl);
    ("print_err", ref builtin_print_err);
    ("read_file", ref builtin_read_file);
    ("read_file_bytes", ref builtin_read_file_bytes);
    ("file_pread", ref builtin_file_pread);
    ("write_file_bytes", ref builtin_write_file_bytes);
    ("write_file", ref builtin_write_file);
    ("read_lines", ref builtin_read_lines);
    ("list_dir", ref builtin_list_dir);
    ("mkdir_p", ref builtin_mkdir_p);
    ("file_mtime", ref builtin_file_mtime);
    ("sleep_ms", ref builtin_sleep_ms);
    ("file_exists", ref builtin_file_exists);
    ("env_var", ref builtin_env_var);
    ("args", ref builtin_args);
    ("print_int", ref builtin_print_int);
    ("print_bool", ref builtin_print_bool);
    ("str_of_int", ref builtin_str_of_int);
    ("float_of_int", ref builtin_float_of_int);
    ("int_of_float", ref builtin_int_of_float);
    ("str_of_float", ref builtin_str_of_float);
    ("float_of_str", ref builtin_float_of_str);
    ("f_add", ref builtin_f_add);
    ("f_sub", ref builtin_f_sub);
    ("f_mul", ref builtin_f_mul);
    ("f_div", ref builtin_f_div);
    ("f_lt", ref builtin_f_lt);
    ("f_le", ref builtin_f_le);
    ("f_gt", ref builtin_f_gt);
    ("f_ge", ref builtin_f_ge);
    ("f_abs", ref builtin_f_abs);
    ("f_neg", ref builtin_f_neg);
    ("sqrt", ref builtin_sqrt);
    ("log", ref builtin_log);
    ("exp", ref builtin_exp);
    ("sin", ref builtin_sin);
    ("cos", ref builtin_cos);
    ("tan", ref builtin_tan);
    ("atan2", ref builtin_atan2);
    ("float_bits_hi", ref builtin_float_bits_hi);
    ("float_bits_lo", ref builtin_float_bits_lo);
    ("float_of_bits", ref builtin_float_of_bits);
    ("f32_bits", ref builtin_f32_bits);
    ("float_of_f32_bits", ref builtin_float_of_f32_bits);
    ("f_min", ref builtin_f_min);
    ("f_max", ref builtin_f_max);
    ("f_pow", ref builtin_f_pow);
    ("random_int", ref builtin_random_int);
    ("random_float", ref builtin_random_float);
    ("floor", ref builtin_floor);
    ("ceil", ref builtin_ceil);
    ("round", ref builtin_round);
    ("pi", ref (V_float Float.pi));
    ("e", ref (V_float (Float.exp 1.0)));
    ("not", ref builtin_not);
    ("str_len", ref builtin_str_len);
    ("int_of_str", ref builtin_int_of_str);
    ("bool_of_str", ref builtin_bool_of_str);
    ("str_contains", ref builtin_str_contains);
    ("str_count", ref builtin_str_count);
    ("str_index_of", ref builtin_str_index_of);
    ("str_last_index_of", ref builtin_str_last_index_of);
    ("str_split", ref builtin_str_split);
    ("utf8_len", ref builtin_utf8_len);
    ("utf8_chars", ref builtin_utf8_chars);
    ("bit_and", ref builtin_bit_and);
    ("bit_or",  ref builtin_bit_or);
    ("bit_xor", ref builtin_bit_xor);
    ("bit_not", ref builtin_bit_not);
    ("bit_shl", ref builtin_bit_shl);
    ("bit_shr", ref builtin_bit_shr);
    ("str_join", ref builtin_str_join);
    ("str_compare", ref builtin_str_compare);
    ("str_eq",         ref builtin_str_eq);
    ("str_starts_with", ref builtin_str_starts_with);
    ("str_ends_with", ref builtin_str_ends_with);
    ("str_repeat", ref builtin_str_repeat);
    ("substring", ref builtin_substring);
    ("str_replace", ref builtin_str_replace);
    ("char_at", ref builtin_char_at);
    ("chr", ref builtin_chr);
    ("ord", ref builtin_ord);
    ("to_upper", ref builtin_to_upper);
    ("to_lower", ref builtin_to_lower);
    ("str_trim", ref builtin_str_trim);
    ("str_rev", ref builtin_str_rev);
    ("str_unescape", ref builtin_str_unescape);
    ("is_digit", ref builtin_is_digit);
    ("is_alpha", ref builtin_is_alpha);
    ("is_space", ref builtin_is_space);
    ("fail", ref builtin_fail);
    ("min", ref builtin_min);
    ("max", ref builtin_max);
    ("abs", ref builtin_abs);
    ("even", ref builtin_even);
    ("odd", ref builtin_odd);
    ("clamp", ref builtin_clamp);
    ("gcd", ref builtin_gcd);
    ("show", ref builtin_show);
    ("to_json", ref builtin_to_json);
    ("of_json", ref builtin_of_json);
    ("of_json_opt", ref builtin_of_json);
    ("fst", ref builtin_fst);
    ("snd", ref builtin_snd);
    ("try_or", ref builtin_try_or);
    ("iter_n", ref builtin_iter_n);
    ("mk_logger", ref builtin_mk_logger);
    ("mk_metrics", ref builtin_mk_metrics);
    ("vec_new",  ref builtin_vec_new);
    ("vec_push", ref builtin_vec_push);
    ("vec_get",  ref builtin_vec_get);
    ("vec_len",  ref builtin_vec_len);
    ("vec_iter", ref builtin_vec_iter);
    ("vec_map",  ref builtin_vec_map);
    ("vec_fold", ref builtin_vec_fold);
    ("vec_set",  ref builtin_vec_set);
    ("vec_reverse", ref builtin_vec_reverse);
    ("vec_concat",  ref builtin_vec_concat);
    ("vec_sort",    ref builtin_vec_sort);
    ("vec_filter",   ref builtin_vec_filter);
    ("vec_to_list",  ref builtin_vec_to_list);
    ("vec_to_owned", ref builtin_vec_to_owned);
    ("owned_vec_to_vec", ref builtin_owned_vec_to_vec);
    ("owned_vec_new",  ref builtin_owned_vec_new);
    ("owned_vec_push", ref builtin_owned_vec_push);
    ("owned_vec_get",  ref builtin_owned_vec_get);
    ("owned_vec_len",  ref builtin_owned_vec_len);
    ("strbuf_new",     ref builtin_strbuf_new);
    ("strbuf_push",    ref builtin_strbuf_push);
    ("strbuf_to_str",  ref builtin_strbuf_to_str);
    ("strbuf_len",     ref builtin_strbuf_len);
    ("map_new",        ref builtin_map_new);
    ("map_set",        ref builtin_map_set);
    ("map_iter",       ref builtin_map_iter);
    ("map_get",        ref builtin_map_get);
    ("map_has",        ref builtin_map_has);
    ("map_len",        ref builtin_map_len);
    ("map_delete",     ref builtin_map_delete);
    ("map_compact",    ref builtin_map_compact);
    ("map_clear",      ref builtin_map_clear);
    ("map_recycle",    ref builtin_map_recycle);
    ("map_bytes",      ref builtin_map_bytes);
    ("vec_bytes",      ref builtin_vec_bytes);
    ("vec_compact",    ref builtin_vec_compact);
    ("len",            ref builtin_len);
  ]

let rec match_pattern (p : Ast.pattern) (v : value) : (string * value) list option =
  match p.pnode, v with
  | Ast.P_wild, _ -> Some []
  | Ast.P_var n, _ -> Some [(n, v)]
  | Ast.P_int n, V_int m when n = m -> Some []
  | Ast.P_bool b, V_bool b' when b = b' -> Some []
  | Ast.P_str s, V_str s' when s = s' -> Some []
  | Ast.P_unit, V_unit -> Some []
  | Ast.P_constr (c, None), V_constr (c', None)
    when Ast.canonical_ctor c = c' -> Some []
  | Ast.P_constr (c, Some sub_p), V_constr (c', Some sub_v)
    when Ast.canonical_ctor c = c' ->
    match_pattern sub_p sub_v
  | Ast.P_tuple ps, V_tuple vs when List.length ps = List.length vs ->
    let rec combine acc ps vs =
      match ps, vs with
      | [], [] -> Some acc
      | p :: ps', v :: vs' ->
        (match match_pattern p v with
         | None -> None
         | Some bs -> combine (acc @ bs) ps' vs')
      | _ -> None
    in
    combine [] ps vs
  | Ast.P_record (name, fpats), V_record (vname, fields) when name = vname ->
    let rec combine acc fpats =
      match fpats with
      | [] -> Some acc
      | (fname, fpat) :: rest ->
        (match List.assoc_opt fname fields with
         | None -> None
         | Some v ->
           (match match_pattern fpat v with
            | None -> None
            | Some bs -> combine (acc @ bs) rest))
    in
    combine [] fpats
  | Ast.P_as (inner, name), v ->
    (* Match inner pattern + bind the whole value to `name`. *)
    (match match_pattern inner v with
     | None -> None
     | Some bs -> Some ((name, v) :: bs))
  | Ast.P_or (p1, p2), v ->
    (* Try the left branch first; on failure try the right. *)
    (match match_pattern p1 v with
     | Some bs -> Some bs
     | None -> match_pattern p2 v)
  | _ -> None

(* Structural equality for `==` / `!=`.  Recurses through tuples, records,
   and constructors.  Functions (closures/builtins) are not comparable —
   raise Eval_error since we cannot meaningfully equate them. *)
let rec value_eq a b =
  match a, b with
  | V_int x, V_int y -> x = y
  | V_float x, V_float y -> x = y
  | V_bool x, V_bool y -> x = y
  | V_str x, V_str y -> x = y
  | V_unit, V_unit -> true
  | V_tuple xs, V_tuple ys when List.length xs = List.length ys ->
    List.for_all2 value_eq xs ys
  | V_constr (n1, None), V_constr (n2, None) -> n1 = n2
  | V_constr (n1, Some v1), V_constr (n2, Some v2) -> n1 = n2 && value_eq v1 v2
  | V_constr _, V_constr _ -> false
  | V_record (n1, fs1), V_record (n2, fs2) when n1 = n2 ->
    (try List.for_all (fun (f, v1) ->
       value_eq v1 (List.assoc f fs2)
     ) fs1
     with Not_found -> false)
  | (V_closure _ | V_builtin _), _
  | _, (V_closure _ | V_builtin _) ->
    raise (Eval_error (Loc.dummy, "functions are not comparable with == / !="))
  | _ -> false

(* v0.1.11 derive-ord: structural, lexicographic comparison mirroring
   value_eq. Returns <0 / 0 / >0. Scalars compare directly; tuple / record
   compare component/field-wise; variants (including list = Nil/Cons) order
   by DECLARATION ORDER — the same tag order codegen assigns via List.iteri —
   so the interpreter agrees byte-for-byte with the native / wasm backends.
   Honest edges: float uses OCaml's total `compare` (NaN sorts as least);
   closures are ordered arbitrarily-but-totally (0), as value_eq treats them. *)
and constr_decl_index name =
  match Hashtbl.find_opt Typer.constructors name with
  | Some info ->
    (match Hashtbl.find_opt Exhaustive.type_variants info.Typer.type_name with
     | Some vs ->
       let rec idx i = function
         | [] -> 0
         | (c, _) :: _ when c = name -> i
         | _ :: t -> idx (i + 1) t
       in idx 0 vs
     | None -> 0)
  | None -> 0

and value_compare a b =
  match a, b with
  | V_int x, V_int y -> compare (x : int) y
  | V_float x, V_float y -> compare (x : float) y
  | V_bool x, V_bool y -> compare (x : bool) y
  | V_str x, V_str y -> String.compare x y
  | V_unit, V_unit -> 0
  | V_tuple xs, V_tuple ys -> compare_value_lists xs ys
  | V_constr (n1, p1), V_constr (n2, p2) ->
    let c = compare (constr_decl_index n1) (constr_decl_index n2) in
    if c <> 0 then c
    else (match p1, p2 with
      | None, None -> 0
      | Some v1, Some v2 -> value_compare v1 v2
      | None, Some _ -> -1
      | Some _, None -> 1)
  | V_record (n1, fs1), V_record (_, fs2) ->
    (* Compare fields in the type's DECLARED order (matches codegen), so
       two records of the same type compare deterministically regardless of
       how their field alists happen to be ordered. *)
    (match Hashtbl.find_opt Typer.records n1 with
     | Some info ->
       let rec go = function
         | [] -> 0
         | (f, _) :: rest ->
           (match List.assoc_opt f fs1, List.assoc_opt f fs2 with
            | Some v1, Some v2 ->
              let c = value_compare v1 v2 in if c <> 0 then c else go rest
            | _ -> go rest)
       in go info.Typer.r_fields
     | None -> 0)
  | _ -> 0

and compare_value_lists xs ys =
  match xs, ys with
  | [], [] -> 0
  | [], _ -> -1
  | _, [] -> 1
  | x :: xs', y :: ys' ->
    let c = value_compare x y in
    if c <> 0 then c else compare_value_lists xs' ys'

(* ===== of_json: type-directed JSON deserialization (mirror of to_json) =====
   `to_json` walks a runtime value (which already carries its structure), so it
   needs no type info. `of_json` goes the other way — a JSON string alone can't
   tell a record from a map, or a nullary constructor from a plain string — so
   it is driven by the target type read from the call node's inferred `ty`.
   We parse the input into a generic `jtree`, then convert it into the target
   `value` structurally: JSON object -> record fields (matched by name), array
   -> list / tuple, `null` -> None for `option`, string/object -> variant. *)

type jtree =
  | JNull
  | JBool of bool
  | JNum of string          (* raw numeric lexeme; int/float chosen by target *)
  | JStr of string
  | JArr of jtree list
  | JObj of (string * jtree) list

exception Json_parse_error of string

(* v0.1.306: a decoded JSON string must be valid UTF-8 (shortest form, no
   surrogates, max U+10FFFF). This is the parser's rule, not str's: utf8_len
   counts an invalid byte as one unit ON PURPOSE, because a str already in
   memory has no better answer. Bytes arriving as JSON do -- Go 1.27's
   encoding/json/v2 refuses them, and so does this. The same walk guards all
   three hand-written parsers (interp / C runtime / Wasm runtime); the parity
   gate holds them to one behaviour. *)
let json_utf8_valid (s : string) : bool =
  let n = String.length s in
  let rec go i =
    if i >= n then true
    else
      let c = Char.code s.[i] in
      if c < 0x80 then go (i + 1)
      else if c < 0xC2 || c > 0xF4 then false
      else
        let need, lo, hi =
          if c < 0xE0 then 1, 0x80, 0xBF
          else if c < 0xF0 then
            2, (if c = 0xE0 then 0xA0 else 0x80), (if c = 0xED then 0x9F else 0xBF)
          else
            3, (if c = 0xF0 then 0x90 else 0x80), (if c = 0xF4 then 0x8F else 0xBF)
        in
        if i + need >= n then false
        else
          let b1 = Char.code s.[i + 1] in
          if b1 < lo || b1 > hi then false
          else if need >= 2 && Char.code s.[i + 2] land 0xC0 <> 0x80 then false
          else if need >= 3 && Char.code s.[i + 3] land 0xC0 <> 0x80 then false
          else go (i + need + 1)
  in
  go 0

let parse_json_tree (s : string) : jtree =
  let n = String.length s in
  let pos = ref 0 in
  let error msg =
    raise (Json_parse_error
             (Printf.sprintf "of_json: %s (at offset %d)" msg !pos)) in
  let peek () = if !pos < n then Some s.[!pos] else None in
  let skip_ws () =
    while !pos < n &&
          (match s.[!pos] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false)
    do incr pos done in
  let expect c =
    if !pos < n && s.[!pos] = c then incr pos
    else error (Printf.sprintf "expected '%c'" c) in
  let parse_string_lit () =
    expect '"';
    let buf = Buffer.create 16 in
    let rec loop () =
      if !pos >= n then error "unterminated string";
      match s.[!pos] with
      | '"' -> incr pos
      | '\\' ->
        incr pos;
        if !pos >= n then error "bad escape";
        (match s.[!pos] with
         | 'n' -> Buffer.add_char buf '\n'
         | 't' -> Buffer.add_char buf '\t'
         | 'r' -> Buffer.add_char buf '\r'
         | 'b' -> Buffer.add_char buf '\b'
         | 'f' -> Buffer.add_char buf '\012'
         | '"' -> Buffer.add_char buf '"'
         | '\\' -> Buffer.add_char buf '\\'
         | '/' -> Buffer.add_char buf '/'
         | c -> Buffer.add_char buf c);
        incr pos; loop ()
      | c -> Buffer.add_char buf c; incr pos; loop ()
    in
    loop ();
    let out = Buffer.contents buf in
    if not (json_utf8_valid out) then error "invalid UTF-8 in string";
    out in
  let rec parse_value () =
    skip_ws ();
    match peek () with
    | None -> error "unexpected end of input"
    | Some '{' -> parse_object ()
    | Some '[' -> parse_array ()
    | Some '"' -> JStr (parse_string_lit ())
    | Some 't' -> parse_lit "true" (JBool true)
    | Some 'f' -> parse_lit "false" (JBool false)
    | Some 'n' -> parse_lit "null" JNull
    | Some c when c = '-' || (c >= '0' && c <= '9') -> parse_number ()
    | Some c -> error (Printf.sprintf "unexpected char '%c'" c)
  and parse_lit lit v =
    let len = String.length lit in
    if !pos + len <= n && String.sub s !pos len = lit then
      (pos := !pos + len; v)
    else error ("expected " ^ lit)
  and parse_number () =
    let start = !pos in
    if !pos < n && s.[!pos] = '-' then incr pos;
    while !pos < n &&
          (match s.[!pos] with
           | '0'..'9' | '.' | 'e' | 'E' | '+' | '-' -> true | _ -> false)
    do incr pos done;
    JNum (String.sub s start (!pos - start))
  and parse_array () =
    expect '[';
    skip_ws ();
    if peek () = Some ']' then (incr pos; JArr [])
    else begin
      let acc = ref [] in
      let rec loop () =
        let v = parse_value () in
        acc := v :: !acc;
        skip_ws ();
        match peek () with
        | Some ',' -> incr pos; loop ()
        | Some ']' -> incr pos
        | _ -> error "expected ',' or ']' in array"
      in
      loop ();
      JArr (List.rev !acc)
    end
  and parse_object () =
    expect '{';
    skip_ws ();
    if peek () = Some '}' then (incr pos; JObj [])
    else begin
      let acc = ref [] in
      let rec loop () =
        skip_ws ();
        let k = parse_string_lit () in
        skip_ws (); expect ':';
        let v = parse_value () in
        (* v0.1.303: a repeated key is refused rather than resolved. Silently
           keeping one of the two is a choice the input did not make, and the
           choice is not even stable across implementations -- this decoder kept
           the FIRST (assoc lookup over a list built in document order), Go's
           encoding/json v1 kept the LAST, and Go v2 stopped picking in 1.27.
           Refusing is the only answer that does not depend on who wrote the
           parser. of_json fails fast; of_json_opt answers None. *)
        if List.mem_assoc k !acc then
          error (Printf.sprintf "duplicate object key %S" k);
        acc := (k, v) :: !acc;
        skip_ws ();
        match peek () with
        | Some ',' -> incr pos; loop ()
        | Some '}' -> incr pos
        | _ -> error "expected ',' or '}' in object"
      in
      loop ();
      JObj (List.rev !acc)
    end
  in
  let v = parse_value () in
  skip_ws ();
  if !pos <> n then error "trailing content after JSON value";
  v

(* Substitute type params -> concrete args in a field/ctor type. *)
let of_json_build_subst params args =
  try List.combine params args with Invalid_argument _ -> []
let rec of_json_apply_subst subst t =
  match Ast.walk t with
  | Ast.TyParam p ->
    (match List.assoc_opt p subst with Some a -> a | None -> Ast.TyParam p)
  | Ast.TyArrow (a, b) ->
    Ast.TyArrow (of_json_apply_subst subst a, of_json_apply_subst subst b)
  | Ast.TyTuple ts -> Ast.TyTuple (List.map (of_json_apply_subst subst) ts)
  | Ast.TyCon (n, xs) -> Ast.TyCon (n, List.map (of_json_apply_subst subst) xs)
  | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, of_json_apply_subst subst inner)
  | other -> other

(* Convert a parsed jtree into a runtime value, directed by target type `t`. *)
let rec of_json_value (t : Ast.ty) (j : jtree) : value =
  let mismatch what =
    raise (Json_parse_error ("of_json: expected " ^ what)) in
  match Ast.walk t, j with
  | Ast.TyInt, JNum s ->
    (try V_int (int_of_string (String.trim s))
     with _ ->
       (try V_int (int_of_float (float_of_string s))
        with _ -> mismatch "an integer"))
  | Ast.TyFloat, JNum s ->
    (try V_float (float_of_string s) with _ -> mismatch "a number")
  | Ast.TyBool, JBool b -> V_bool b
  | Ast.TyStr, JStr s -> V_str s
  | Ast.TyUnit, JNull -> V_unit
  | Ast.TyTuple ts, JArr js when List.length ts = List.length js ->
    V_tuple (List.map2 of_json_value ts js)
  | Ast.TyCon ("list", [elem]), JArr js ->
    List.fold_right
      (fun jv acc -> V_constr ("Cons", Some (V_tuple [of_json_value elem jv; acc])))
      js (V_constr ("Nil", None))
  | Ast.TyCon ("option", [inner]), _ ->
    (match j with
     | JNull -> V_constr ("None", None)
     | _ -> V_constr ("Some", Some (of_json_value inner j)))
  | Ast.TyCon (name, args), _ when Hashtbl.mem Typer.records name ->
    (match j with
     | JObj fields ->
       let info = Hashtbl.find Typer.records name in
       let subst = of_json_build_subst info.Typer.r_params args in
       let vfields =
         List.map (fun (fname, fty) ->
           match List.assoc_opt fname fields with
           | Some jv -> (fname, of_json_value (of_json_apply_subst subst fty) jv)
           | None ->
             raise (Json_parse_error
                      (Printf.sprintf "of_json: missing field %S for record %s"
                         fname name)))
           info.Typer.r_fields
       in
       V_record (name, vfields)
     | _ -> mismatch ("a JSON object for record " ^ name))
  | Ast.TyCon (name, args), _ ->
    (* general variant: JSON string -> nullary ctor; {"Ctor": payload} -> Ctor payload *)
    (* v0.1.177: a name out of the JSON has to be a constructor OF THIS
       variant. The nullary branch used to build `V_constr (cname, None)`
       from whatever string arrived, so `of_json_opt "\"Nonsense\""` at a
       `status` returned `Some` holding a value that is not any case of the
       type — and `to_json` printed it straight back out. The C and Wasm
       decoders both answered None, so the interpreter, which is the parity
       harness's reference, was the one in the wrong.

       The object branch checked that the constructor exists but not that it
       belongs here, which lets a payload case from an unrelated variant
       through; `type_name` closes both. *)
    let of_this_variant cname =
      match Hashtbl.find_opt Typer.constructors cname with
      | Some info when info.Typer.type_name = name -> Some info
      | _ -> None
    in
    (match j with
     | JStr cname ->
       (match of_this_variant cname with
        | Some { Typer.arg = None; _ } -> V_constr (cname, None)
        | Some _ ->
          raise (Json_parse_error
                   (Printf.sprintf "of_json: %s of %s carries a payload" cname name))
        | None ->
          raise (Json_parse_error
                   (Printf.sprintf "of_json: %s is not a case of %s" cname name)))
     | JObj [(cname, payload)] ->
       (match of_this_variant cname with
        | Some info ->
          (match info.Typer.arg with
           | Some argty ->
             let subst = of_json_build_subst info.Typer.params args in
             V_constr (cname, Some (of_json_value (of_json_apply_subst subst argty) payload))
           | None -> V_constr (cname, None))
        | None ->
          raise (Json_parse_error
                   (Printf.sprintf "of_json: %s is not a case of %s" cname name)))
     | _ -> mismatch ("a variant value for " ^ name))
  | _ ->
    mismatch "a matching JSON shape for the target type"

(* Is every corner of this type known? A type variable anywhere means the
   call node cannot say what to decode into. *)
let rec oj_ty_is_concrete (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyVar _ | Ast.TyParam _ -> false
  | Ast.TyArrow (a, b) -> oj_ty_is_concrete a && oj_ty_is_concrete b
  | Ast.TyTuple ts -> List.for_all oj_ty_is_concrete ts
  | Ast.TyCon (_, args) -> List.for_all oj_ty_is_concrete args
  | Ast.TyRef (_, _, inner) -> oj_ty_is_concrete inner
  | _ -> true

(* The target type a witness value stands for. Records and constructors
   carry their type's name at runtime, which is what makes the witness form
   of of_json work on the interpreter at all. A value cannot carry its type
   ARGUMENTS, so a polymorphic record still needs the annotation. *)
let rec oj_ty_of_value (loc : Loc.t) (v : value) : Ast.ty =
  match v with
  | V_int _ -> Ast.TyInt
  | V_float _ -> Ast.TyFloat
  | V_bool _ -> Ast.TyBool
  | V_str _ -> Ast.TyStr
  | V_unit -> Ast.TyUnit
  | V_tuple vs -> Ast.TyTuple (List.map (oj_ty_of_value loc) vs)
  | V_record (name, _) -> Ast.TyCon (name, [])
  | V_constr (cname, _) ->
    (match Hashtbl.find_opt Typer.constructors cname with
     | Some info -> Ast.TyCon (info.Typer.type_name, [])
     | None ->
       type_error loc ("of_json_like: unknown constructor " ^ cname
                       ^ " in the witness"))
  | _ ->
    type_error loc
      "of_json_like: the witness must be a record, a constructor, a tuple or \
       a scalar — a closure or a handle cannot say what to decode into"

let rec eval_in (env : env) (e : Ast.expr) =
  match e.Ast.node with
  (* of_json_like: the target type comes from a witness value rather than
     from the call node, so this one works inside a polymorphic function —
     where the node's type is a variable and there is nothing here to
     resolve it with. The witness's runtime shape carries what is needed:
     a record and a constructor both know their type's name. *)
  | Ast.App ({ Ast.node = Ast.App ({ Ast.node = Ast.Var "of_json_like"; _ },
                                   witness_e); _ }, arg) ->
    let witness = eval_in env witness_e in
    let s =
      match eval_in env arg with
      | V_str s -> s
      | _ -> type_error e.Ast.loc "of_json_like: expected a str argument"
    in
    (* The node's own type wins when it is already concrete: the compiled
       backends use it, and agreeing with them keeps a polymorphic record
       (which the witness cannot describe, since a value does not carry its
       type arguments) working wherever the annotation does reach. *)
    let target =
      match e.Ast.ty with
      | Some t when oj_ty_is_concrete t -> Ast.walk t
      | _ -> oj_ty_of_value e.Ast.loc witness
    in
    (try of_json_value target (parse_json_tree s)
     with Json_parse_error msg -> type_error e.Ast.loc msg)
  (* The non-crashing witness form. Same target as of_json_like; None on any
     failure, which is what a caller trying candidate shapes needs. *)
  | Ast.App ({ Ast.node = Ast.App ({ Ast.node = Ast.Var "of_json_opt_like"; _ },
                                   witness_e); _ }, arg) ->
    let witness = eval_in env witness_e in
    let s =
      match eval_in env arg with
      | V_str s -> s
      | _ -> type_error e.Ast.loc "of_json_opt_like: expected a str argument"
    in
    let target =
      match e.Ast.ty with
      | Some t when oj_ty_is_concrete t ->
        (match Ast.walk t with
         | Ast.TyCon ("option", [inner]) -> Ast.walk inner
         | other -> other)
      | _ -> oj_ty_of_value e.Ast.loc witness
    in
    (try V_constr ("Some", Some (of_json_value target (parse_json_tree s)))
     with _ -> V_constr ("None", None))
  (* of_json applied directly: decode the string using the call node's type. *)
  | Ast.App ({ Ast.node = Ast.Var "of_json"; _ }, arg) ->
    let s =
      match eval_in env arg with
      | V_str s -> s
      | _ -> type_error e.Ast.loc "of_json: expected a str argument"
    in
    let target =
      match e.Ast.ty with
      | Some t -> t
      | None ->
        type_error e.Ast.loc
          "of_json: cannot infer target type (add a type annotation)"
    in
    (try of_json_value target (parse_json_tree s)
     with Json_parse_error msg -> type_error e.Ast.loc msg)
  (* of_json_opt: the non-crashing sibling. Returns None on any error. *)
  | Ast.App ({ Ast.node = Ast.Var "of_json_opt"; _ }, arg) ->
    let s =
      match eval_in env arg with
      | V_str s -> s
      | _ -> type_error e.Ast.loc "of_json_opt: expected a str argument"
    in
    (* result type is `T option`; decode T, wrap in Some, None on failure. *)
    let inner =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon ("option", [inner]) -> inner
         | _ -> type_error e.Ast.loc "of_json_opt: result type is not an option")
      | None ->
        type_error e.Ast.loc
          "of_json_opt: cannot infer target type (add a type annotation)"
    in
    (try V_constr ("Some", Some (of_json_value inner (parse_json_tree s)))
     with Json_parse_error _ -> V_constr ("None", None))
  | Ast.Int_lit n -> V_int n
  | Ast.Float_lit f -> V_float f
  | Ast.Bool_lit b -> V_bool b
  | Ast.Str_lit s -> V_str s
  | Ast.Unit_lit -> V_unit
  | Ast.Var name ->
    (try !(List.assoc name env)
     with Not_found ->
       type_error e.Ast.loc ("unbound variable: " ^ name))
  | Ast.Neg a ->
    (match eval_in env a with
     | V_int x -> V_int (- x)
     | V_float x -> V_float (-. x)  (* v0.1.44: -2.5 no longer needs f_neg *)
     | _ -> type_error e.Ast.loc "unary - requires int or float")
  | Ast.Bin (op, a, b) ->
    let va = eval_in env a in
    let vb = eval_in env b in
    (match op, va, vb with
     | Ast.Add, V_int x, V_int y -> V_int (x + y)
     | Ast.Sub, V_int x, V_int y -> V_int (x - y)
     | Ast.Mul, V_int x, V_int y -> V_int (x * y)
     | Ast.Div, V_int _, V_int 0 ->
       type_error e.Ast.loc "division by zero"
     | Ast.Div, V_int x, V_int y -> V_int (x / y)
     | Ast.Mod, V_int _, V_int 0 ->
       type_error e.Ast.loc "modulo by zero"
     | Ast.Mod, V_int x, V_int y -> V_int (x mod y)
     (* float arithmetic (operators overloaded on float; Mod stays int-only) *)
     | Ast.Add, V_float x, V_float y -> V_float (x +. y)
     | Ast.Sub, V_float x, V_float y -> V_float (x -. y)
     | Ast.Mul, V_float x, V_float y -> V_float (x *. y)
     | Ast.Div, V_float x, V_float y -> V_float (x /. y)
     | Ast.Concat, V_str x, V_str y -> V_str (x ^ y)
     | (Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod), _, _ ->
       type_error e.Ast.loc "arithmetic requires int (or float, except mod) operands"
     | Ast.Concat, _, _ ->
       type_error e.Ast.loc "++ requires str operands")
  | Ast.Cmp (op, a, b) ->
    let va = eval_in env a in
    let vb = eval_in env b in
    (match op with
     | Ast.Eq -> V_bool (value_eq va vb)
     | Ast.Ne -> V_bool (not (value_eq va vb))
     (* v0.1.11 derive-ord: all ordering routes through the structural
        value_compare (scalars, tuple, record, variant/list). *)
     | Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge ->
       (match va, vb with
        (* v0.1.260: two floats compare by IEEE, where every ordered
           comparison with NaN is false. value_compare is OCaml's TOTAL
           compare, which sorts NaN below everything -- right for derive-ord
           and wrong for the operator: `nan < 0.0` answered true here and
           false on all three compiled backends, which emit the float
           comparison. The parity case that found it could not be written
           until floats had exponent literals to reach NaN with. *)
        | V_float x, V_float y ->
          V_bool (match op with
            | Ast.Lt -> (x : float) < (y : float)
            | Ast.Le -> (x : float) <= (y : float)
            | Ast.Gt -> (x : float) > (y : float)
            | Ast.Ge -> (x : float) >= (y : float)
            | _ -> false)
        | _ ->
          let c = value_compare va vb in
          V_bool (match op with
            | Ast.Lt -> c < 0 | Ast.Le -> c <= 0
            | Ast.Gt -> c > 0 | Ast.Ge -> c >= 0
            | _ -> false)))
  | Ast.Logic (op, a, b) ->
    (* short-circuit evaluation: don't evaluate b unless needed *)
    (match op, eval_in env a with
     | Ast.And, V_bool false -> V_bool false
     | Ast.Or, V_bool true -> V_bool true
     | (Ast.And | Ast.Or), V_bool _ ->
       (match eval_in env b with
        | V_bool _ as v -> v
        | _ -> type_error e.Ast.loc "logical operator: rhs must be bool")
     | _ ->
       type_error e.Ast.loc "logical operator: lhs must be bool")
  | Ast.Let (pat, value, body) ->
    let v = eval_in env value in
    (match match_pattern pat v with
     | Some bindings ->
       let env' = List.fold_left (fun acc (n, v) -> (n, ref v) :: acc) env bindings in
       eval_in env' body
     | None ->
       type_error e.Ast.loc "let pattern did not match (use irrefutable patterns)")
  | Ast.Let_rec (bindings, body) ->
    (* Mutual recursion: placeholder ref for each name, evaluate each
       value under the env with all placeholders, then backpatch each. *)
    let placeholders = List.map (fun (n, _) -> (n, ref V_unit)) bindings in
    let env' = List.fold_left (fun acc (n, r) -> (n, r) :: acc) env placeholders in
    List.iter (fun (n, value) ->
      let v = eval_in env' value in
      let r = List.assoc n placeholders in
      r := v
    ) bindings;
    eval_in env' body
  | Ast.With (name, value, body) ->
    (* Phase 3.1: scope-bound resource cleanup. Eval body then invoke the
       value's `close` field (if present) as a unit-returning thunk. Drop
       order across nested with-bindings is naturally LIFO since each
       outer `with` waits for the inner body (and its drops) to finish
       before running its own close. *)
    let v = eval_in env value in
    let result = eval_in ((name, ref v) :: env) body in
    (match v with
     | V_record (_, fields) ->
       (match List.assoc_opt "close" fields with
        | Some close_fn -> ignore (!apply_value_ref close_fn V_unit)
        | None -> ())
     | _ -> ());
    result
  | Ast.If (cond, then_, else_) ->
    (match eval_in env cond with
     | V_bool true -> eval_in env then_
     | V_bool false -> eval_in env else_
     | _ -> type_error e.Ast.loc "if condition must be bool")
  | Ast.Fun (param, _ty_opt, body) ->
    V_closure (param, body, env)
  | Ast.App (f, arg) ->
    (match eval_in env f with
     | V_closure (param, body, captured) ->
       let v = eval_in env arg in
       let d = !call_depth in
       if d >= !max_depth then begin
         call_depth := 0;
         raise (Eval_error (e.Ast.loc, "stack overflow (recursion too deep)"))
       end;
       call_depth := d + 1;
       let r = eval_in ((param, ref v) :: captured) body in
       call_depth := d;
       r
     | V_builtin (_, fn) ->
       let v = eval_in env arg in
       fn v
     | _ -> type_error e.Ast.loc "applying non-function")
  | Ast.Annot (inner, _) -> eval_in env inner
  | Ast.Constr (name, None) ->
    (* Phase 18.1: canonicalize so M.Red and Red both become the bare
       canonical name (= the one originally declared). Pattern matching
       compares by string, so values constructed via qualified syntax
       must match unqualified patterns and vice versa. *)
    V_constr (Ast.canonical_ctor name, None)
  | Ast.Constr (name, Some arg) ->
    let v = eval_in env arg in
    V_constr (Ast.canonical_ctor name, Some v)
  | Ast.Match (scrut, arms) ->
    let v = eval_in env scrut in
    let rec try_arms = function
      | [] -> type_error e.Ast.loc "no matching arm in match"
      | (p, guard, body) :: rest ->
        (match match_pattern p v with
         | Some bindings ->
           let env' = List.fold_left (fun acc (n, v) -> (n, ref v) :: acc) env bindings in
           let g_ok = match guard with
             | None -> true
             | Some g ->
               (match eval_in env' g with
                | V_bool b -> b
                | _ -> type_error g.Ast.loc "match guard must be bool")
           in
           if g_ok then eval_in env' body
           else try_arms rest
         | None -> try_arms rest)
    in
    try_arms arms
  | Ast.Tuple es ->
    V_tuple (List.map (eval_in env) es)
  | Ast.Region_block (name, body) ->
    (* Phase 2: region scope syntactic + escape check (in typer).  At runtime
       the region is a unit-value placeholder; actual bump-allocation will
       come with codegen.  *)
    eval_in ((name, ref V_unit) :: env) body
  | Ast.Region_loop (name, x, body) ->
    (* The interpreter has no arenas, so the loop is just a loop: x starts
       None, Continue rebinds it Some, Done exits. The memory behaviour the
       construct exists for (swap arenas, deep-copy the carry) is codegen's. *)
    let rec go carry =
      let cell = ref carry in
      match eval_in ((x, cell) :: (name, ref V_unit) :: env) body with
      | V_constr ("Continue", Some c) -> go (V_constr ("Some", Some c))
      | V_constr ("Done", Some d) -> d
      | _ ->
        failwith "region loop body answered a non-region_flow value" 
    in
    go (V_constr ("None", None))
  | Ast.Ref (_mode, _region, inner) ->
    (* `&R v` — runtime is identity, the region tag exists only in the type
       system.  Eventual codegen will materialize this as an actual region
       allocation. *)
    eval_in env inner
  | Ast.Record_lit (name, fields) ->
    V_record (name, List.map (fun (f, e) -> (f, eval_in env e)) fields)
  | Ast.Field_get (inner, fname) ->
    (match eval_in env inner with
     | V_record (_, fields) ->
       (try List.assoc fname fields
        with Not_found ->
          type_error e.Ast.loc ("record has no field " ^ fname))
     | _ -> type_error e.Ast.loc "field access on non-record value")
  | Ast.Record_update (base, updates) ->
    (match eval_in env base with
     | V_record (name, base_fields) ->
       (* Replace matching fields, preserve order of declared fields. *)
       let new_fields = List.map (fun (fname, fval) ->
         match List.assoc_opt fname updates with
         | Some upd_expr -> (fname, eval_in env upd_expr)
         | None -> (fname, fval)
       ) base_fields in
       V_record (name, new_fields)
     | _ -> type_error e.Ast.loc "record update on non-record value")

let eval expr = eval_in initial_env expr

(* Patch apply_value_ref now that eval_in is bound, so higher-order builtins
   (`flip` and friends) can call into the evaluator at runtime. *)
let () =
  apply_value_ref := (fun f arg ->
    match f with
    | V_closure (param, body, captured) ->
      let d = !call_depth in
      if d >= !max_depth then begin
        call_depth := 0;
        raise (Eval_error (Loc.dummy, "stack overflow (recursion too deep)"))
      end;
      call_depth := d + 1;
      let r = eval_in ((param, ref arg) :: captured) body in
      call_depth := d;
      r
    | V_builtin (_, fn) -> fn arg
    | _ -> failwith "apply_value: not a function")
