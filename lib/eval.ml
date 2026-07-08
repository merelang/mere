(* Tree-walking interpreter. *)

exception Eval_error of Loc.t * string

type value =
  | V_int of int
  | V_float of float
  | V_bool of bool
  | V_str of string
  | V_unit
  | V_closure of string * Ast.expr * env
  | V_builtin of string * (value -> value)
  | V_constr of string * value option
  | V_tuple of value list
  | V_record of string * (string * value) list
  | V_vec of value array ref
    (* `'a Vec` — region-aware growable vector (Phase 12.1, Q-010
       narrowed -> first implementation stage). Backed by a mutable array ref;
       push reallocates. Trivial[R] when element type is Trivial[R]. *)
  | V_strbuf of Buffer.t
    (* `StrBuf[R]` — region-aware mutable string buffer (Phase 12.7,
       Q-010 narrowed). Minimal implementation of design doc
       13_region_std_types.md §4. Internally an OCaml Buffer holding
       the string's bytes. Treated as Trivial, so it can live in a
       region. The type is TyCon ("StrBuf", [TyRef BR R TyUnit])
       (1-arg region marker, the same convention as view types). *)
  | V_map of (value, value) Hashtbl.t * value list ref
    (* `Map[R, K, V]` — region-aware mutable associative map (Phase 12.10,
       Q-010 narrowed). Minimal implementation of design doc
       13_region_std_types.md §5. Internally an OCaml Hashtbl using
       polymorphic hash / eq (note: keys containing closures / refs are
       identified per-ref). The type is TyCon ("Map",
       [TyRef BR R TyUnit; K; V]).
       Phase 27.1: the 2nd component is the insertion-order key list
       (so that map_iter iterates in deterministic order). The Hashtbl
       itself preserves O(1) lookup. *)
  | V_channel of value Queue.t * Mutex.t * Condition.t
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

and env = (string * value ref) list

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
  | V_float f -> string_of_float f
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
    let elems = Array.to_list !arr in
    "Vec[" ^ String.concat ", " (List.map to_string elems) ^ "]"
  | V_strbuf buf ->
    "StrBuf[" ^ Ast.escape_string (Buffer.contents buf) ^ "]"
  | V_map (tbl, keys) ->
    let parts = List.map (fun k ->
      let v = Hashtbl.find tbl k in
      to_string k ^ " => " ^ to_string v) !keys in
    "Map[" ^ String.concat ", " parts ^ "]"
  | V_channel _ -> "<channel>"
  | V_thread _ -> "<thread>"

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

let builtin_time =
  V_builtin ("time", fun v ->
    match v with
    | V_unit -> V_float (Unix.gettimeofday ())
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
      Unix.sleepf (float_of_int ms /. 1000.0);
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

let builtin_args =
  V_builtin ("args", fun v ->
    match v with
    | V_unit ->
      (* OCaml's Sys.argv[0] is the executable name — from the Mere
         program's perspective, returning "the program's own args"
         (argv[1..]) is the natural choice. *)
      let argv = Sys.argv in
      let n = Array.length argv in
      let args = if n <= 1 then [] else
        Array.to_list (Array.sub argv 1 (n - 1))
      in
      str_list_to_v_local args
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
    | V_float f -> V_str (string_of_float f)
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
      (try V_int (int_of_string (String.trim s))
       with Failure _ ->
         raise (Eval_error (Loc.dummy,
           Printf.sprintf "int_of_str: %S is not a valid int" s)))
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

let builtin_sign =
  V_builtin ("sign", fun v ->
    match v with
    | V_int n -> V_int (if n > 0 then 1 else if n < 0 then -1 else 0)
    | _ -> failwith "sign: expected int")

let builtin_incr =
  V_builtin ("incr", fun v ->
    match v with
    | V_int n -> V_int (n + 1)
    | _ -> failwith "incr: expected int")

let builtin_decr =
  V_builtin ("decr", fun v ->
    match v with
    | V_int n -> V_int (n - 1)
    | _ -> failwith "decr: expected int")

let builtin_square =
  V_builtin ("square", fun v ->
    match v with
    | V_int n -> V_int (n * n)
    | _ -> failwith "square: expected int")

let builtin_cube =
  V_builtin ("cube", fun v ->
    match v with
    | V_int n -> V_int (n * n * n)
    | _ -> failwith "cube: expected int")

let builtin_divmod =
  V_builtin ("divmod", fun a_val ->
    match a_val with
    | V_int a ->
      V_builtin ("divmod_partial", fun b_val ->
        match b_val with
        | V_int 0 ->
          raise (Eval_error (Loc.dummy, "divmod: division by zero"))
        | V_int b ->
          V_tuple [V_int (a / b); V_int (a mod b)]
        | _ -> failwith "divmod: 2nd arg expected int")
    | _ -> failwith "divmod: 1st arg expected int")

let builtin_sum_range =
  V_builtin ("sum_range", fun lo_val ->
    match lo_val with
    | V_int lo ->
      V_builtin ("sum_range_partial", fun hi_val ->
        match hi_val with
        | V_int hi ->
          if lo > hi then V_int 0
          else V_int ((hi - lo + 1) * (lo + hi) / 2)
        | _ -> failwith "sum_range: 2nd arg expected int")
    | _ -> failwith "sum_range: 1st arg expected int")

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

let builtin_lcm =
  V_builtin ("lcm", fun a ->
    match a with
    | V_int x ->
      V_builtin ("lcm_partial", fun b ->
        match b with
        | V_int y ->
          if x = 0 || y = 0 then V_int 0
          else
            let rec euclid a b =
              if b = 0 then a
              else euclid b (a mod b)
            in
            let g = euclid (abs x) (abs y) in
            V_int (abs (x / g * y))
        | _ -> failwith "lcm: 2nd arg expected int")
    | _ -> failwith "lcm: 1st arg expected int")

let builtin_pow =
  V_builtin ("pow", fun base ->
    match base with
    | V_int b ->
      V_builtin ("pow_partial", fun exp ->
        match exp with
        | V_int e when e < 0 ->
          raise (Eval_error (Loc.dummy,
            Printf.sprintf "pow: negative exponent %d" e))
        | V_int e ->
          (* iterative integer exponentiation *)
          let rec loop acc base exp =
            if exp = 0 then acc
            else if exp mod 2 = 1 then loop (acc * base) (base * base) (exp / 2)
            else loop acc (base * base) (exp / 2)
          in
          V_int (loop 1 b e)
        | _ -> failwith "pow: 2nd arg expected int")
    | _ -> failwith "pow: 1st arg expected int")

let builtin_fail =
  V_builtin ("fail", fun v ->
    match v with
    | V_str msg -> raise (Eval_error (Loc.dummy, "fail: " ^ msg))
    | _ -> failwith "fail: expected str")

let builtin_show =
  V_builtin ("show", fun v -> V_str (to_string v))

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
    | V_vec arr -> V_int (Array.length !arr)
    | V_strbuf buf -> V_int (Buffer.length buf)
    | V_map (tbl, _) -> V_int (Hashtbl.length tbl)
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
    | V_unit -> V_vec (ref [||])
    | _ -> failwith "vec_new: expected unit")

let builtin_vec_push =
  V_builtin ("vec_push", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_push_p1", fun x ->
        arr := Array.append !arr [| x |];
        V_unit)
    | _ -> failwith "vec_push: expected Vec")

let builtin_vec_get =
  V_builtin ("vec_get", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_get_p1", fun idx ->
        match idx with
        | V_int i ->
          if i < 0 || i >= Array.length !arr then
            raise (Eval_error (Loc.dummy,
              Printf.sprintf "vec_get: index %d out of bounds (len = %d)"
                i (Array.length !arr)))
          else (!arr).(i)
        | _ -> failwith "vec_get: expected int index")
    | _ -> failwith "vec_get: expected Vec")

let builtin_vec_len =
  V_builtin ("vec_len", fun v ->
    match v with
    | V_vec arr -> V_int (Array.length !arr)
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
    | V_unit -> V_vec (ref [||])
    | _ -> failwith "owned_vec_new: expected unit")

let builtin_owned_vec_push =
  V_builtin ("owned_vec_push", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("owned_vec_push_p1", fun x ->
        arr := Array.append !arr [| x |];
        V_unit)
    | _ -> failwith "owned_vec_push: expected OwnedVec")

let builtin_owned_vec_get =
  V_builtin ("owned_vec_get", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("owned_vec_get_p1", fun idx ->
        match idx with
        | V_int i ->
          if i < 0 || i >= Array.length !arr then
            raise (Eval_error (Loc.dummy,
              Printf.sprintf "owned_vec_get: index %d out of bounds (len = %d)"
                i (Array.length !arr)))
          else (!arr).(i)
        | _ -> failwith "owned_vec_get: expected int index")
    | _ -> failwith "owned_vec_get: expected OwnedVec")

let builtin_owned_vec_len =
  V_builtin ("owned_vec_len", fun v ->
    match v with
    | V_vec arr -> V_int (Array.length !arr)
    | _ -> failwith "owned_vec_len: expected OwnedVec")

(* StrBuf[R] builtins (Phase 12.7) — a mutable string buffer inside a
   region. Implemented as an OCaml Buffer; push appends, and to_str
   returns a snapshot. *)
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
    | V_unit -> V_map (Hashtbl.create 16, ref [])
    | _ -> failwith "map_new: expected unit")

let builtin_map_set =
  V_builtin ("map_set", fun v ->
    match v with
    | V_map (tbl, keys) ->
      V_builtin ("map_set_p1", fun k ->
        V_builtin ("map_set_p2", fun vv ->
          (* Phase 27.1: track insertion order. Only append to keys list
             for NEW keys; existing keys keep their original position. *)
          if not (Hashtbl.mem tbl k) then keys := !keys @ [k];
          Hashtbl.replace tbl k vv;
          V_unit))
    | _ -> failwith "map_set: expected Map")

let builtin_map_get =
  V_builtin ("map_get", fun v ->
    match v with
    | V_map (tbl, _) ->
      V_builtin ("map_get_p1", fun k ->
        match Hashtbl.find_opt tbl k with
        | Some vv -> vv
        | None ->
          raise (Eval_error (Loc.dummy,
            "map_get: key not found in Map (use map_has to check first)")))
    | _ -> failwith "map_get: expected Map")

let builtin_map_has =
  V_builtin ("map_has", fun v ->
    match v with
    | V_map (tbl, _) ->
      V_builtin ("map_has_p1", fun k ->
        V_bool (Hashtbl.mem tbl k))
    | _ -> failwith "map_has: expected Map")

let builtin_map_len =
  V_builtin ("map_len", fun v ->
    match v with
    | V_map (tbl, _) -> V_int (Hashtbl.length tbl)
    | _ -> failwith "map_len: expected Map")

(* Phase 39.A' #2: map_delete — Hashtbl.remove. No-op if the key is
   absent. To preserve Phase 27.1 insertion order, also removes from
   the keys list. *)
let builtin_map_delete =
  V_builtin ("map_delete", fun v ->
    match v with
    | V_map (tbl, keys) ->
      V_builtin ("map_delete_p1", fun k ->
        if Hashtbl.mem tbl k then begin
          Hashtbl.remove tbl k;
          keys := List.filter (fun kk -> kk <> k) !keys
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

let builtin_id =
  V_builtin ("id", fun v -> v)

let builtin_swap =
  V_builtin ("swap", fun v ->
    match v with
    | V_tuple [a; b] -> V_tuple [b; a]
    | _ -> failwith "swap: expected 2-tuple")

let builtin_pair =
  V_builtin ("pair", fun a ->
    V_builtin ("pair_partial", fun b -> V_tuple [a; b]))

let builtin_const =
  V_builtin ("const", fun a ->
    V_builtin ("const_partial", fun _b -> a))

(* Forward-reference into eval_in's apply machinery so higher-order builtins
   like `flip` can call user functions (V_closure / V_builtin) at runtime.
   Patched at the bottom of this file, after eval_in is defined. *)
let apply_value_ref : (value -> value -> value) ref =
  ref (fun _ _ -> failwith "apply_value_ref: not initialized (BUG)")

let builtin_flip =
  V_builtin ("flip", fun f ->
    V_builtin ("flip_p1", fun b ->
      V_builtin ("flip_p2", fun a ->
        (* flip f b a = (f a) b *)
        let f_a = !apply_value_ref f a in
        !apply_value_ref f_a b)))

let builtin_try_or =
  V_builtin ("try_or", fun f ->
    V_builtin ("try_or_partial", fun default ->
      try !apply_value_ref f V_unit
      with Eval_error _ -> default))

(* Phase 12.9: higher-order Vec API (iter / map / fold / set).
   Calls user functions (V_closure / V_builtin) via apply_value_ref. *)
let builtin_vec_iter =
  V_builtin ("vec_iter", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_iter_p1", fun f ->
        Array.iter (fun x -> ignore (!apply_value_ref f x)) !arr;
        V_unit)
    | _ -> failwith "vec_iter: expected Vec")

let builtin_vec_map =
  V_builtin ("vec_map", fun v ->
    match v with
    | V_vec arr ->
      V_builtin ("vec_map_p1", fun f ->
        let mapped = Array.map (fun x -> !apply_value_ref f x) !arr in
        V_vec (ref mapped))
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
          ) init !arr))
    | _ -> failwith "vec_fold: expected Vec")

(* Phase 19.2: map_iter — call (K -> V -> unit) for each entry.
   Curried closure: apply f to K (returns inner V_builtin), apply
   inner to V (returns unit). *)
let builtin_map_iter =
  V_builtin ("map_iter", fun v ->
    match v with
    | V_map (tbl, keys) ->
      V_builtin ("map_iter_p1", fun f ->
        (* Phase 27.1: iterate in insertion order so output matches
           C / LLVM / Wasm Map runtime (which all use parallel arrays). *)
        List.iter (fun k ->
          let vv = Hashtbl.find tbl k in
          let f_k = !apply_value_ref f k in
          ignore (!apply_value_ref f_k vv)
        ) !keys;
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
            if i < 0 || i >= Array.length !arr then
              raise (Eval_error (Loc.dummy,
                Printf.sprintf "vec_set: index %d out of bounds (len = %d)"
                  i (Array.length !arr)))
            else begin
              (!arr).(i) <- new_val;
              V_unit
            end
          | _ -> failwith "vec_set: expected int index"))
    | _ -> failwith "vec_set: expected Vec")

(* Phase 19.3: vec_reverse (in-place) / vec_concat (returns new Vec). *)
let builtin_vec_reverse =
  V_builtin ("vec_reverse", fun v ->
    match v with
    | V_vec arr ->
      let n = Array.length !arr in
      for i = 0 to (n / 2) - 1 do
        let j = n - 1 - i in
        let tmp = (!arr).(i) in
        (!arr).(i) <- (!arr).(j);
        (!arr).(j) <- tmp
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
          V_vec (ref (Array.append !a1 !a2))
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
        Array.sort compare_v !arr;
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
          ) (Array.to_list !arr)
        ) in
        V_vec (ref filtered))
    | _ -> failwith "vec_filter: expected Vec")

let builtin_vec_to_list =
  V_builtin ("vec_to_list", fun v ->
    match v with
    | V_vec arr ->
      Array.fold_right (fun x acc ->
        V_constr ("Cons", Some (V_tuple [x; acc]))
      ) !arr (V_constr ("Nil", None))
    | _ -> failwith "vec_to_list: expected Vec")

let builtin_vec_to_owned =
  V_builtin ("vec_to_owned", fun v ->
    match v with
    | V_vec arr ->
      (* Deep copy: the underlying mutable array is duplicated so the
         OwnedVec result is independent of the source Vec's lifetime. *)
      V_vec (ref (Array.copy !arr))
    | _ -> failwith "vec_to_owned: expected Vec")

(* Phase 12.12: the reverse direction OwnedVec[T] -> Vec[R, T]. The
   region is injected by a typer special-case from the call site's
   active_regions. The runtime is a simple deep copy (since V_vec is
   shared, Array.copy makes it independent). *)
let builtin_owned_vec_to_vec =
  V_builtin ("owned_vec_to_vec", fun v ->
    match v with
    | V_vec arr -> V_vec (ref (Array.copy !arr))
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

let builtin_assert =
  V_builtin ("assert", fun cond ->
    match cond with
    | V_bool b ->
      V_builtin ("assert_partial", fun msg ->
        match msg with
        | V_str m ->
          if b then V_unit
          else raise (Eval_error (Loc.dummy, "assertion failed: " ^ m))
        | _ -> failwith "assert: 2nd arg expected str")
    | _ -> failwith "assert: 1st arg expected bool")

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
let lookup_extern (name : string) (_ty : Ast.ty) : value =
  match name with
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
      | V_int n -> Unix.sleep n; V_int 0
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
let builtin_spawn =
  V_builtin ("spawn", fun clos ->
    V_thread (Domain.spawn (fun () -> !apply_value_ref clos V_unit)))

let builtin_join =
  V_builtin ("join", fun h ->
    match h with
    | V_thread d -> ignore (Domain.join d); V_unit
    | _ -> failwith "join: expected a ThreadHandle")

let builtin_channel_new =
  V_builtin ("channel_new", fun _ ->
    V_channel (Queue.create (), Mutex.create (), Condition.create ()))

let builtin_channel_send =
  V_builtin ("channel_send", fun ch ->
    match ch with
    | V_channel (q, m, c) ->
      V_builtin ("channel_send_p", fun v ->
        Mutex.lock m;
        Queue.push v q;
        Condition.signal c;
        Mutex.unlock m;
        V_unit)
    | _ -> failwith "channel_send: expected a Channel")

let builtin_channel_recv =
  V_builtin ("channel_recv", fun ch ->
    match ch with
    | V_channel (q, m, c) ->
      Mutex.lock m;
      while Queue.is_empty q do Condition.wait c m done;
      let v = Queue.pop q in
      Mutex.unlock m;
      v
    | _ -> failwith "channel_recv: expected a Channel")

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
        List.map (fun x -> Domain.spawn (fun () -> !apply_value_ref f x)) elems
      in
      let results = List.map Domain.join domains in
      List.fold_right
        (fun h tail -> V_constr ("Cons", Some (V_tuple [h; tail])))
        results (V_constr ("Nil", None))))

let initial_env : env =
  [ ("print", ref builtin_print);
    (* Q-012 step 3a: concurrency primitives *)
    ("spawn", ref builtin_spawn);
    ("join", ref builtin_join);
    ("channel_new", ref builtin_channel_new);
    ("channel_send", ref builtin_channel_send);
    ("channel_recv", ref builtin_channel_recv);
    ("par_map", ref builtin_par_map);
    ("read_line", ref builtin_read_line);
    ("time", ref builtin_time);
    ("exit", ref builtin_exit);
    ("int_max", ref (V_int max_int));
    ("int_min", ref (V_int min_int));
    ("print_no_nl", ref builtin_print_no_nl);
    ("print_err", ref builtin_print_err);
    ("read_file", ref builtin_read_file);
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
    ("str_split", ref builtin_str_split);
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
    ("sign", ref builtin_sign);
    ("incr", ref builtin_incr);
    ("decr", ref builtin_decr);
    ("sum_range", ref builtin_sum_range);
    ("square", ref builtin_square);
    ("cube", ref builtin_cube);
    ("divmod", ref builtin_divmod);
    ("clamp", ref builtin_clamp);
    ("pow", ref builtin_pow);
    ("gcd", ref builtin_gcd);
    ("lcm", ref builtin_lcm);
    ("assert", ref builtin_assert);
    ("show", ref builtin_show);
    ("fst", ref builtin_fst);
    ("snd", ref builtin_snd);
    ("id", ref builtin_id);
    ("swap", ref builtin_swap);
    ("pair", ref builtin_pair);
    ("const", ref builtin_const);
    ("flip", ref builtin_flip);
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

let rec eval_in (env : env) (e : Ast.expr) =
  match e.Ast.node with
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
     | _ -> type_error e.Ast.loc "unary - requires int")
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
     | Ast.Concat, V_str x, V_str y -> V_str (x ^ y)
     | (Ast.Add | Ast.Sub | Ast.Mul | Ast.Div | Ast.Mod), _, _ ->
       type_error e.Ast.loc "arithmetic requires int operands"
     | Ast.Concat, _, _ ->
       type_error e.Ast.loc "++ requires str operands")
  | Ast.Cmp (op, a, b) ->
    let va = eval_in env a in
    let vb = eval_in env b in
    (match op, va, vb with
     | Ast.Lt, V_int x, V_int y -> V_bool (x < y)
     | Ast.Le, V_int x, V_int y -> V_bool (x <= y)
     | Ast.Gt, V_int x, V_int y -> V_bool (x > y)
     | Ast.Ge, V_int x, V_int y -> V_bool (x >= y)
     | (Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge), _, _ ->
       type_error e.Ast.loc "ordering requires int operands"
     | Ast.Eq, _, _ -> V_bool (value_eq va vb)
     | Ast.Ne, _, _ -> V_bool (not (value_eq va vb)))
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
       eval_in ((param, ref v) :: captured) body
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
      eval_in ((param, ref arg) :: captured) body
    | V_builtin (_, fn) -> fn arg
    | _ -> failwith "apply_value: not a function")
