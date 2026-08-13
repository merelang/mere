(* Wasm (WebAssembly) codegen — Phase 6.1 MVP.

   Emits WAT (WebAssembly Text format), an S-expression representation
   that `wat2wasm` (wabt) parses into a `.wasm` binary. Mirrors the
   first slice scope of the other backends: int / bool / arith / cmp /
   logic / Neg / If / Let (P_var) / Var / Annot.

   Wasm is stack-based (no SSA), so emission is a different shape from
   the C / LLVM backends: each expression pushes its result onto the
   stack; the surrounding context pops in the order the instructions
   were emitted.

   The runtime is just `WebAssembly.instantiate(...)`; the main module
   exports a `main` function whose return type is i32 (Lang bool also
   widens to i32). Strings / records / variants are deferred to later
   slices since they need linear memory + (typically) a small runtime. *)

exception Codegen_error of Loc.t * string

let unsupported loc what =
  raise (Codegen_error (loc, "unsupported (wasm codegen, Phase 6.1 MVP): " ^ what))

(* Host builtins with no Wasm lowering yet. Like codegen_llvm.ml's twin list,
   this makes the gap loud: without it these fall through to the generic
   "unbound variable" tail, which reads like a user typo rather than a
   backend hole. It is the Wasm column of the host-builtin support
   matrix, in code; a real arm (or an explicit `unsupported` arm) fires
   (The matrix itself is generated: docs/host-matrix.md, from
   scripts/host_matrix.sh. Entries here that the matrix reports as `yes` are
   inert and were removed in v0.1.228 — a list that lies is worse than none.)
   before the tail, so an entry here is inert once the builtin is handled.
   Names that already have a stub (file_exists/args/run/random_int/exit) or
   an explicit unsupported arm (file_open family, list_dir, mkdir_p,
   file_mtime, sleep_ms, channel_close/recv_opt/recv_timeout) are NOT listed. *)
let host_builtins_without_wasm_lowering =
  [ (* v0.1.228: found by scripts/host_matrix.sh. Both came with the `bytes` type in
       v0.1.216, after this list was written, and fell through to "unbound variable"
       — the exact hole the list exists to close, reopened by a later feature.
       (`par_map` is handled at the tail instead: it is desugared before codegen, so
       this name never reaches here.) *)
    "read_bytes"; "write_bytes";
    "read_key"; "tty_raw"; "tty_restore";
    "read_lines"; "file_pread";
    "random_float"; "detach" ]

(* Accumulator for the function body's instructions (one WAT token per
   list entry). The driver concatenates them with newlines + indent. *)
let instrs : string list ref = ref []
let emit_instr s = instrs := s :: !instrs

(* Local slot bookkeeping. Lang variables map to Wasm locals; we mint
   a fresh slot per Let binding. Wasm locals are typed, so we track the
   declared type per slot. Value slots are i64 (v0.1.127: Mere's uniform
   value model widened from i32 — ints are true 64-bit, pointers carry a
   32-bit address zero-extended, wrapped back at memory operations); f64
   temp slots (Phase 34.3) and raw i32 address temps keep their own types. *)
let local_counter = ref 0
let local_types : string list ref = ref []  (* in declaration order; index = slot *)
let locals : (string * int) list ref = ref []
let fresh_local () =
  let n = !local_counter in
  incr local_counter;
  local_types := !local_types @ ["i64"];
  n
let fresh_local_i32 () =
  let n = !local_counter in
  incr local_counter;
  local_types := !local_types @ ["i32"];
  n
let fresh_local_f64 () =
  let n = !local_counter in
  incr local_counter;
  local_types := !local_types @ ["f64"];
  n

(* String literals live in linear memory. Each Str_lit is laid out
   sequentially starting at `str_initial_offset` (we reserve the first
   slot of memory for the bump-allocator's top pointer just out of
   habit, even though it actually lives in a Wasm global). *)
let str_initial_offset = 16
let str_data_decls : string list ref = ref []
let str_offset_counter = ref str_initial_offset

(* WAT data-string escape: printable ASCII as-is, otherwise \HH. *)
let wasm_string_escape (s : string) : string =
  let buf = Buffer.create (String.length s + 4) in
  String.iter (fun c ->
    let code = Char.code c in
    if code >= 32 && code <= 126 && c <> '"' && c <> '\\' then
      Buffer.add_char buf c
    else
      Buffer.add_string buf (Printf.sprintf "\\%02x" code)
  ) s;
  Buffer.contents buf

let fresh_str_offset (s : string) : int =
  (* byte-safe: emit [i32 len header][bytes]['\0'] and return the address of
     byte0 (= off + 4). The length header lets embedded NULs survive. *)
  let off = !str_offset_counter in
  let n = String.length s in
  str_offset_counter := off + 4 + n + 1;
  let len_hdr =
    Printf.sprintf "\\%02x\\%02x\\%02x\\%02x"
      (n land 0xff) ((n asr 8) land 0xff)
      ((n asr 16) land 0xff) ((n asr 24) land 0xff)
  in
  let escaped = wasm_string_escape s in
  str_data_decls :=
    Printf.sprintf "  (data (i32.const %d) \"%s%s\\00\")" off len_hdr escaped
    :: !str_data_decls;
  off + 4

(* Reset per emit_program. *)
let print_no_nl_used = ref false
(* print_bytes needs its own host import: `print_no_nl` takes a NUL-terminated
   pointer, which is exactly what a byte sequence cannot be. Gated, so a program
   that does not use it imports nothing new and runs on an older host. *)
let print_bytes_used = ref false

let reset () =
  print_no_nl_used := false;
  print_bytes_used := false;
  instrs := [];
  local_counter := 0;
  local_types := [];
  locals := []

(* ── Function lifting (Phase 6.2) ── *)

type fn_skel = {
  sname : string;
  sparam : string;
  sbody : Ast.expr;
  sfun : Ast.expr;
}

type fn_decl = {
  name : string;
  param : string;
  body : Ast.expr;
  param_ty : Ast.ty;
  return_ty : Ast.ty;
}

(* Which Mere line each emitted function came from, in the order they are
   emitted. It is collected always — it costs nothing and changes no output — and
   printed only by `mere -wg`, which is what a source map is built from.

   A Wasm source map maps *byte offsets in the assembled binary*, and this
   backend emits text for `wat2wasm` to assemble. So the compiler cannot produce
   the map itself: it says which function came from which line, and the tool that
   has the binary matches the two up by name. Same division as the RV32I debug
   map, for the same reason — whoever knows the addresses is not whoever knows
   the source. *)
let debug_fn_lines : (string * int) list ref = ref []

let record_fn_line (name : string) (loc : Loc.t) =
  (* A position that names a file came from the prelude or an import, and is not
     a line of the source being compiled. *)
  if loc.Loc.line > 0 && loc.Loc.file = None then
    debug_fn_lines := (name, loc.Loc.line) :: !debug_fn_lines

let toplevel_fn_names : (string, unit) Hashtbl.t = Hashtbl.create 8
(* v0.1.172: declaration position of each top-level fn. Top-level bindings
   are sequential — the typer rejects a forward reference — so `show` used
   above a later `let show = ...` is still the builtin, and the shadowing
   guard has to ask "bound before here?" rather than "bound anywhere?".
   `<=` rather than `<` so a recursive fn counts as binding its own name. *)
let toplevel_fn_pos : (string, int) Hashtbl.t = Hashtbl.create 8
let current_toplevel_pos = ref max_int
let toplevel_binds_here name =
  match Hashtbl.find_opt toplevel_fn_pos name with
  | Some p -> p <= !current_toplevel_pos
  | None -> Hashtbl.mem toplevel_fn_names name


(* Phase 30.2c (DEFERRED §1.10 fix, Wasm): keep the names of top-level
   non-fn lets. In Wasm all values are i32 (literal int / ptr to linear
   memory), so declare them as (global $<name> (mut i32) (i32.const 0)) and
   initialize via `global.set` at the start of main. emit_expr Var "name"
   becomes `global.get $<name>`. *)
let top_globals_wasm : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Phase 32.4 (C1 FFI, Wasm): declare extern fns as env host imports and
   call them via `call $<name>`. The Node.js host harness
   (scripts/run_wasm.js) provides default impls in env (getpid / getppid etc.). *)
let extern_fn_decls_wasm : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Phase 15.4: Vec[R, T] runtime used flag. All Mere values lower to a
   4-byte i32 in Wasm (scalars are direct, structured types are linear-
   memory offsets), so a single $mere_vec_* runtime handles every element
   type — no per-T monomorphization is needed (unlike C / LLVM which use
   typed structs). The flag is set the first time emit_expr / ty
   inspection sees a Vec value; emit_program emits the helpers iff true. *)
let vec_used = ref false

(* Phase 15.5: vec_iter / vec_fold reference `(type $cl)` and use
   `call_indirect`, which both require a funcref table to be declared
   in the module. Track usage so emit_program can declare a (possibly
   empty) table when these helpers are emitted. *)
let vec_higher_order_used = ref false

(* Phase 15.9: StrBuf[R] usage flag — runtime is single non-polymorphic. *)
let strbuf_used = ref false
let bytes_used = ref false  (* gate the Wasm bytes runtime *)
let bytes_vec_used = ref false  (* gate the bytes <-> Vec[int] bridge *)

(* Phase 16.3: Logger / Metrics builtin usage flags. *)
let logger_used = ref false
let metrics_used = ref false
(* Q-012: set when the program uses spawn / join / channel. Switches the
   module to host-imported shared memory + pulls the pthread-like host
   imports (mere_spawn / mere_join). *)
let uses_threads = ref false
(* Phase 26.1: stdlib builtin usage flags for Wasm. *)
let char_table_used = ref false
let fail_used = ref false
let substring_used = ref false
let int_of_str_used = ref false
let str_unescape_used = ref false
(* Phase 26.5: stdlib catch-up — str_split / str_join / str_count / file I/O. *)
let str_split_used = ref false
let str_join_used = ref false
let str_count_used = ref false
let file_io_used = ref false
let file_bytes_io_used = ref false  (* binary file I/O host imports (read/write_file_bytes) *)
(* v0.1.153: positioned file I/O on an open handle (file_openrw / file_pread /
   file_pwrite / file_fsync / file_close). Separate from file_bytes_io_used
   because a paged store rewrites one node at a time and never wants the
   whole-file read/replace pair. *)
let file_pio_used = ref false
(* Phase 2: true while emitting a command-style component
   (--component on a unit/CLI program). Command components get real WASI via
   the wasi_snapshot_preview1 adapter; args() returns the actual argv. *)
let wasm_component_command = ref false
let wasm_args_host_used = ref false  (* args() on a plain host: emit $__lang_args_host + arg_count/arg_get imports *)
let wasm_args_used = ref false  (* command component called args() -> emit $__lang_args + wasi args imports *)
let wasm_time_used = ref false  (* command component called time() -> real $__lang_time via wasi clock_time_get *)
let wasm_env_used = ref false  (* command component called env_var() -> emit $__lang_env_var + wasi environ imports *)
let wasm_stdin_used = ref false  (* command component called read_stdin() -> emit $__lang_read_stdin + wasi fd_read import *)
(* Phase 3 sockets: a command component that declares the mhttp-style socket /
   raw-memory externs (tcp_connect/read/write/close, mem_alloc/get_u8/copy_str/
   to_str, str_ptr) gets in-module _h helpers backed by p2 wasi:sockets +
   linear memory, instead of env host imports. *)
let wasm_socket_ffi = ref false
let socket_ffi_externs =
  ["tcp_connect"; "tcp_listen"; "tcp_accept"; "tcp_read"; "tcp_write"; "tcp_close";
   "udp_open"; "udp_send"; "udp_recv"; "tcp_set_timeout";
   "mem_alloc"; "mem_get_u8"; "mem_set_u8"; "mem_get_u16be"; "mem_set_u16be";
   "mem_copy_str"; "mem_to_str"; "str_ptr"]

(* Phase 15.10/15.14: Map[R, K, V] — in Wasm all values are i32, so no per-V
   is needed; only per-K. Register K's type in `map_key_types`, and
   emit_program emits one set of per-K helpers per entry. `map_int_used` /
   `map_str_used` are kept for backward compatibility (new code goes
   through the table). *)
let map_int_used = ref false
let map_str_used = ref false
let map_key_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4

(* Phase 15.12: vec_to_list and len-on-list share the same list structure,
   so emit the runtime if either is used. Tag values are determined at codegen
   time. *)
let vec_to_list_used = ref false
let list_len_used = ref false

(* Names bound by a pattern (for the free-vars walk). *)
let pattern_vars (p : Ast.pattern) : string list =
  let rec go p =
    match p.Ast.pnode with
    | Ast.P_var n -> [n]
    | Ast.P_constr (_, Some sub) -> go sub
    | Ast.P_tuple ps -> List.concat_map go ps
    | Ast.P_record (_, fs) -> List.concat_map (fun (_, p) -> go p) fs
    | Ast.P_as (inner, n) -> n :: go inner
    | Ast.P_or (a, _) -> go a
    | _ -> []
  in
  go p

let free_vars (e : Ast.expr) (initially_bound : string list) : string list =
  let seen = Hashtbl.create 8 in
  let order = ref [] in
  let add n =
    if not (Hashtbl.mem seen n) then begin
      Hashtbl.add seen n ();
      order := n :: !order
    end
  in
  let rec go (e : Ast.expr) (bound : string list) =
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit -> ()
    | Ast.Var n -> if not (List.mem n bound) then add n
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a bound; go b bound
    | Ast.Neg a | Ast.Annot (a, _) -> go a bound
    | Ast.Let (pat, v, body) ->
      go v bound;
      go body (pattern_vars pat @ bound)
    | Ast.Let_rec (bindings, body) ->
      let names = List.map fst bindings in
      let bound' = names @ bound in
      List.iter (fun (_, v) -> go v bound') bindings;
      go body bound'
    | Ast.With (n, v, body) -> go v bound; go body (n :: bound)
    | Ast.If (c, t, e_) -> go c bound; go t bound; go e_ bound
    | Ast.Fun (param, _, body) -> go body (param :: bound)
    | Ast.Constr (_, Some a) -> go a bound
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      go s bound;
      List.iter (fun (pat, g, b) ->
        let bound' = pattern_vars pat @ bound in
        (match g with Some ge -> go ge bound' | None -> ()); go b bound') arms
    | Ast.Tuple es -> List.iter (fun e -> go e bound) es
    | Ast.Region_block (n, b) -> go b (n :: bound)
    | Ast.Ref (_, _, a) -> go a bound
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e bound) fs
    | Ast.Field_get (a, _) -> go a bound
    | Ast.Record_update (a, fs) ->
      go a bound; List.iter (fun (_, e) -> go e bound) fs
  in
  go e initially_bound;
  List.rev !order

(* ── Closure machinery (Phase 6.7) ──
   Wasm closures are 8-byte memory structs `{ env_offset, fn_table_idx }`.
   The fn pointer is a `funcref` table index, not a memory pointer —
   indirect calls go through `call_indirect (type $cl)`. Every
   closure-callable function has signature `(env, x) -> result` and is
   registered in the module's table. *)

(* Function names that appear in the module's `(elem ...)` section.
   List position == table index. *)
let table_entries : string list ref = ref []
let register_in_table (name : string) : int =
  let idx = List.length !table_entries in
  table_entries := !table_entries @ [name];
  idx

(* Top-level fn name → its closure adapter's table index. Populated
   when we emit the per-top-level-fn `<name>_closure` wrapper. *)
let fn_closure_table_idx : (string, int) Hashtbl.t = Hashtbl.create 4

(* Phase 35.3: eta-wrapped nullary factory adapters (vec_new / owned_vec_new
   / strbuf_new / map_new_<k_tag>) used as first-class values. Key = adapter
   slug, value = (builtin name, ret_ty, table_idx). *)
(* Phase 38.C (DEFERRED §1.2 A2): syntactic eta-expansion for multi-arg curried
   builtins used in value position (same logic as the helper of the same name
   in codegen_c / codegen_llvm). Routes through an anonymous Fun adapter +
   each builtin's direct-call fast path (line 1653 etc.). *)
let synthesize_curried_eta_wasm (name : string) (arrow_ty : Ast.ty) (loc : Loc.t)
    : Ast.expr =
  let mk node ty = Ast.{ node; ty = Some ty; loc } in
  let rec uncurry t =
    match Ast.walk t with
    | Ast.TyArrow (a, b) ->
      let args, ret = uncurry b in (a :: args, ret)
    | other -> ([], other)
  in
  let arg_tys, ret_ty = uncurry arrow_ty in
  let n = List.length arg_tys in
  if n = 0 then
    raise (Codegen_error (loc, name ^ ": cannot eta-expand non-arrow type"));
  let rec build_app i acc acc_ty =
    if i >= n then acc
    else
      let arg_ty = List.nth arg_tys i in
      let arg_node = mk (Ast.Var (Printf.sprintf "__arg%d" i)) arg_ty in
      let new_ty =
        match Ast.walk acc_ty with
        | Ast.TyArrow (_, b) -> b
        | _ -> ret_ty
      in
      build_app (i + 1) (mk (Ast.App (acc, arg_node)) new_ty) new_ty
  in
  let inner_apps = build_app 0 (mk (Ast.Var name) arrow_ty) arrow_ty in
  let rec wrap i body_acc body_ty =
    if i < 0 then body_acc
    else
      let arg_ty = List.nth arg_tys i in
      let fn_ty = Ast.TyArrow (arg_ty, body_ty) in
      let fn_node =
        mk (Ast.Fun (Printf.sprintf "__arg%d" i, Some arg_ty, body_acc)) fn_ty
      in
      wrap (i - 1) fn_node fn_ty
  in
  wrap (n - 1) inner_apps ret_ty

(* v0.1.164: an extern applied to fewer arguments than it declares. The
   extern path collapses a curried App chain into one `call $name`, which
   is right when the application is saturated and emits a call with the
   wrong arity when it is not — `worker_call req` on a two-argument
   extern produced WAT that wat2wasm rejected. Wrapping the missing
   arguments in a lambda routes the whole thing through the ordinary
   anonymous-closure path, so a partially applied extern becomes a value
   like any other. *)
let eta_wrap_partial_extern (partial : Ast.expr) (missing : Ast.ty list)
    (ret_ty : Ast.ty) (loc : Loc.t) : Ast.expr =
  let mk node ty = Ast.{ node; ty = Some ty; loc } in
  let names = List.mapi (fun i _ -> Printf.sprintf "__eta%d" i) missing in
  (* Apply the fresh parameters left to right, tracking the result type. *)
  let rec apply acc acc_ty ns ts =
    match ns, ts with
    | [], [] -> acc
    | n :: ns', t :: ts' ->
      let res =
        match Ast.walk acc_ty with Ast.TyArrow (_, b) -> b | _ -> ret_ty in
      apply (mk (Ast.App (acc, mk (Ast.Var n) t)) res) res ns' ts'
    | _ -> acc
  in
  let partial_ty =
    match partial.Ast.ty with
    | Some t -> t
    | None -> List.fold_right (fun a b -> Ast.TyArrow (a, b)) missing ret_ty
  in
  let body = apply partial partial_ty names missing in
  (* Then close over them right to left. *)
  let rec wrap ns ts body_acc body_ty =
    match List.rev ns, List.rev ts with
    | [], [] -> body_acc
    | n :: _, t :: _ ->
      let fn_ty = Ast.TyArrow (t, body_ty) in
      let node = mk (Ast.Fun (n, Some t, body_acc)) fn_ty in
      wrap (List.rev (List.tl (List.rev ns))) (List.rev (List.tl (List.rev ts)))
        node fn_ty
    | _ -> body_acc
  in
  wrap names missing body ret_ty

let eta_adapters_wasm : (string, string * Ast.ty * int) Hashtbl.t =
  Hashtbl.create 4

(* Anonymous-Fun closure emission state. *)
type closure_emission = {
  ce_adapter_name : string;
  ce_param        : string;
  ce_body         : Ast.expr;
  ce_captures     : (string * int) list;  (* (name, source local slot) *)
  ce_table_idx    : int;
  mutable ce_host : string;  (* Phase 26.3: host scope at queue time *)
}
let pending_closures : closure_emission list ref = ref []
let anon_counter = ref 0
let fresh_anon_name () =
  let n = !anon_counter in
  incr anon_counter;
  Printf.sprintf "anon_%d_fn" n

(* Phase 26.3: inner-fn lifting (port from codegen_llvm Phase 25.3).
   Inner `let X = fn ...` / `let rec X = fn ... and Y = ...` are lifted
   to top-level Wasm fns; captures are prepended as i32 params. *)
type lifted_inner_wasm = {
  lifted_name : string;
  captures    : string list;  (* free var names in order *)
}
let inner_lifts_wasm : (string, lifted_inner_wasm) Hashtbl.t = Hashtbl.create 8
let inner_lifts_by_host_wasm : (string, (string, lifted_inner_wasm) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 8

(* Phase 39.A2 (Wasm port): inner-lifted fn at value position. For each fn,
   register an adapter in the fn table; at the use site, alloc env in the bump
   heap + store captures + write the closure value (env_offset, table_idx) to
   memory. *)
let inner_lift_closures_emitted_wasm : (string, int) Hashtbl.t = Hashtbl.create 4
let inner_lift_closure_pending_wasm :
  (string * string list * int) list ref = ref []
let set_inner_lifts_for_host_wasm (host : string) : unit =
  Hashtbl.reset inner_lifts_wasm;
  (match Hashtbl.find_opt inner_lifts_by_host_wasm host with
   | Some tbl -> Hashtbl.iter (fun k v -> Hashtbl.add inner_lifts_wasm k v) tbl
   | None -> ());
  (* v0.1.172: the host also fixes where we are in the file, which is what
     the shadowing guard needs — a builtin used inside fn #3 is not affected
     by a same-named binding introduced at #9. "$main" and lifted helpers
     with no recorded position fall back to "everything is in scope". *)
  current_toplevel_pos :=
    (match Hashtbl.find_opt toplevel_fn_pos host with
     | Some p -> p
     | None -> max_int)

(* Wasm tail-call proposal — set to true only while emit_expr is
   producing a value in tail position of the enclosing function
   body. The App emissions look at the flag and switch `call` /
   `call_indirect` to `return_call` / `return_call_indirect` when
   set, so deeply tail-recursive Mere code (parser walkers, list
   iterations) doesn't grow the JS stack. Requires wat2wasm's
   `--enable-tail-call` (or an equivalent V8 default). *)
let wasm_tail_pos = ref false

(* True only while emit_expr is walking the top-level `let a = … in
   let b = … in … 0` spine of the main body. This is the ONE context
   where a `let x = v in …` with x registered in top_globals_wasm
   should compile to `global.set $x` (the Phase 36 initialization
   trick). Any nested `let x = v in …` inside a fn body that happens
   to share a name with a top-level global is a plain local
   shadowing binding, and gets a fresh slot.

   Bug this closes: a top-level `let entries = kv_load … in` at the
   importing file's top makes `entries` a global; when a value-
   position `let entries = _map_entries …` inside an imported
   module's fn body was emitted, the name-only check misrouted it
   to `global.set $entries`, silently overwriting the KV strbuf
   pointer with an unrelated Entry list. Downstream kv_save then
   wrote 0 bytes to disk. *)
let wasm_in_top_level_body = ref false

type lifted_fn_wasm = {
  l_name     : string;
  l_captures : string list;
  l_param    : string;
  l_body     : Ast.expr;
  l_host     : string;
}

let inner_fn_counter_wasm = ref 0
let fresh_inner_name_wasm (base : string) : string =
  let n = !inner_fn_counter_wasm in
  incr inner_fn_counter_wasm;
  Printf.sprintf "__lifted_%s_%d" base n

let lifted_fns_wasm : lifted_fn_wasm list ref = ref []

(* Phase 26.3: name of the currently-emitting top-level (or lifted) fn,
   so anonymous-Fun closures queued in pending_closures can remember
   their host scope for inner_lifts dispatch. *)
let current_host_fn_wasm : string ref = ref ""

(* Each variant constructor → integer tag. Populated up front from
   Exhaustive.type_variants. *)
let variant_tags : (string, int) Hashtbl.t = Hashtbl.create 16

(* Types whose `show_<ty_tag>` function we need to emit. *)
let show_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Same, for `to_json_<ty_tag>` (derive JSON sibling of show). *)
let to_json_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* `of_json` — keyed by target (result) type tag. When non-empty, the WAT
   JSON-parser runtime is emitted. *)
let of_json_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* `of_json_opt` — keyed by the INNER type tag (result is `T option`). *)
let of_json_opt_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

(* Compound types compared with == / != — need a structural `eq_<tag>`
   (Wasm `i32.eq` on a compound value compares linear-memory offsets, not
   contents). Keyed by ty_tag. *)
let eq_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

let needs_struct_eq (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyTuple _ -> true
  | Ast.TyCon (name, _) ->
    Hashtbl.mem Typer.records name
    || Hashtbl.mem Typer.types name
    || name = "list"
  | _ -> false

(* v0.1.11 derive-ord: compound types ordered with < <= > >= need a
   structural `cmp_<tag>` (-1/0/1). Same compound set as needs_struct_eq. *)
let cmp_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8
let needs_struct_cmp = needs_struct_eq

(* Cache: literal string → data segment offset, so repeated literals
   (e.g. `, ` between tuple elements) share one segment. *)
let show_str_offsets : (string, int) Hashtbl.t = Hashtbl.create 16
let intern_show_str (s : string) : int =
  match Hashtbl.find_opt show_str_offsets s with
  | Some off -> off
  | None ->
    let off = fresh_str_offset s in
    Hashtbl.add show_str_offsets s off;
    off

(* Phase 26.0: variant payload "presence" check (not type) — returns
   true if any ctor has a payload, false if all-nullary. Used to decide
   the variant cell size (8 bytes if any payload, else 4).
   In Wasm, all i32-wide values fit at offset 4 regardless of static
   type, so unlike Phase 6 MVP we no longer require uniform payload
   types — per-ctor type info is recovered via ctor_payload_ty at each
   constr / match site. Mirrors LLVM Phase 25.0 (boxed payload). *)
let variant_has_payload (vname : string) : bool =
  match Hashtbl.find_opt Exhaustive.type_variants vname with
  | None ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unknown variant type `%s` at Wasm codegen" vname))
  | Some vs ->
    List.exists (fun (_, p) -> p <> None) vs

(* Phase 26.0: per-ctor payload type. Used by Constr emit (to size the
   boxed payload alloc) and by match P_constr (to compile sub-patterns
   with the correct type). For poly variants the caller substitutes
   type params with concrete args from the surrounding context. *)
let ctor_payload_ty (cname : string) : Ast.ty option =
  match Hashtbl.find_opt Typer.constructors cname with
  | None -> None
  | Some info -> info.Typer.arg

(* Kept for backwards compatibility with code that hasn't been ported
   to per-ctor lookup yet; returns the first payload type seen across
   the variant's ctors, ignoring shape mismatches. *)
let variant_payload_ty (vname : string) : Ast.ty option =
  match Hashtbl.find_opt Exhaustive.type_variants vname with
  | None ->
    raise (Codegen_error (Loc.dummy,
      Printf.sprintf "unknown variant type `%s` at Wasm codegen" vname))
  | Some vs ->
    let payloads = List.filter_map (fun (_, p) -> p) vs in
    (match payloads with [] -> None | p :: _ -> Some p)

(* Stable name fragment per type for show fn naming. Mirrors C/LLVM
   codegen's ty_tag so e.g. `int list` lowers to `show_list_int`. *)
let rec ty_tag (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyCon ("OwnedVec", _) ->
    raise (Codegen_error (Loc.dummy,
      "unsupported in Wasm codegen subset: OwnedVec (not implemented for Wasm in Phase 15)"))
  | Ast.TyCon ("StrBuf", _) ->
    (* Phase 27.3: StrBuf is implemented in Wasm too via the mere_strbuf_*
       runtime. Make ty_tag return a value so it can also be used via tuple
       / variant payload types. *)
    "strbuf"
  | Ast.TyCon ("Map", [_region; k_ty; v_ty]) ->
    (* Phase 43: In Wasm too, Map is an i32 pointer, so return a ty_tag so
       it can be treated as a carrier in tuple / closure env / variant
       payload. The K / V tags prevent identifier collisions
       (`map_str_int` vs `map_int_str`). *)
    "map_" ^ ty_tag k_ty ^ "_" ^ ty_tag v_ty
  | Ast.TyCon ("Map", _) ->
    raise (Codegen_error (Loc.dummy,
      "unsupported in Wasm codegen subset: Map (when region / K / V is not concrete)"))
  | Ast.TyInt -> "int"
  | Ast.TyBool -> "bool"
  | Ast.TyStr -> "str"
  | Ast.TyUnit -> "unit"
  | Ast.TyFloat -> "float"   (* Phase 43.1: float fn signature tag *)
  | Ast.TyTuple ts -> "tuple_" ^ String.concat "_" (List.map ty_tag ts)
  | Ast.TyArrow (p, r) -> "closure_" ^ ty_tag p ^ "_" ^ ty_tag r
  | Ast.TyCon (name, []) -> name
  | Ast.TyCon (name, args) ->
    name ^ "_" ^ String.concat "_" (List.map ty_tag args)
  | Ast.TyRef (_, r, Ast.TyUnit) ->
    (* Region marker — use the region name itself as the tag (same as C / LLVM). *)
    r
  | Ast.TyRef (_, _, inner) ->
    (* Phase 19.x: borrow types use the inner type's tag as-is (same as C / LLVM). *)
    ty_tag inner
  | _ ->
    raise (Codegen_error (Loc.dummy,
      "unsupported Wasm codegen type for ty_tag"))

let rec ty_is_concrete (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyBytes | Ast.TyUnit | Ast.TyFloat -> true
  | Ast.TyTuple ts -> List.for_all ty_is_concrete ts
  | Ast.TyArrow (a, b) -> ty_is_concrete a && ty_is_concrete b
  | Ast.TyCon (_, args) -> List.for_all ty_is_concrete args
  | Ast.TyRef (_, _, inner) -> ty_is_concrete inner
  | Ast.TyVar _ | Ast.TyParam _ -> false  (* Phase 43.1: TyFloat was incorrectly listed as poly *)

(* Substitute TyParam → concrete throughout `t`. Used by add_show_type
   to specialize variant payloads / record fields against the actual
   args of a polymorphic instance. *)
let rec subst_params (mapping : (string * Ast.ty) list) (t : Ast.ty) : Ast.ty =
  match Ast.walk t with
  | Ast.TyParam p ->
    (try List.assoc p mapping with Not_found -> t)
  | Ast.TyArrow (a, b) ->
    Ast.TyArrow (subst_params mapping a, subst_params mapping b)
  | Ast.TyTuple ts -> Ast.TyTuple (List.map (subst_params mapping) ts)
  | Ast.TyCon (n, args) ->
    Ast.TyCon (n, List.map (subst_params mapping) args)
  | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, subst_params mapping inner)
  | other -> other

(* Register a type for show emission, then walk dependent types
   (tuple elems / record fields / variant payloads) recursively. The
   already-seen guard prevents infinite recursion on self-referential
   variants. *)
let rec add_type_into (tbl : (string, Ast.ty) Hashtbl.t) (t : Ast.ty) : unit =
  let t = Ast.walk t in
  if not (ty_is_concrete t) then ()
  else
    let tag = ty_tag t in
    if Hashtbl.mem tbl tag then ()
    else begin
      Hashtbl.add tbl tag t;
      match t with
      | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> ()
      | Ast.TyTuple ts -> List.iter (add_type_into tbl) ts
      | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
        let info = Hashtbl.find Typer.records n in
        let mapping =
          if info.Typer.r_params = [] then []
          else List.combine info.Typer.r_params args
        in
        List.iter (fun (_, ft) ->
          add_type_into tbl (subst_params mapping ft)) info.Typer.r_fields
      | Ast.TyCon (n, args) when Hashtbl.mem Typer.types n ->
        (match Hashtbl.find_opt Exhaustive.type_variants n with
         | None -> ()
         | Some vs ->
           let mapping =
             match vs with
             | (cname, _) :: _ ->
               (match Hashtbl.find_opt Typer.constructors cname with
                | Some info when info.Typer.params <> [] ->
                  List.combine info.Typer.params args
                | _ -> [])
             | [] -> []
           in
           List.iter (fun (_, arg_opt) ->
             match arg_opt with
             | Some t -> add_type_into tbl (subst_params mapping t)
             | None -> ()) vs)
      | _ -> ()
    end

(* ── v0.1.37: per-type deep-copy fns for region-block copy-out ──
   `$__mcopy_<tag> (param $v i64) (result i64)` copies a value into fresh
   bump allocations. Scalars pass through (they are raw i32s, not
   pointers); str copies bytes; float re-boxes; tuples / records /
   variant nodes copy structurally; containers / closures / channels
   pass through as pointers (region-block guards reject the cases where
   that would dangle). Mirrors emit_cmp_fn's specialization. *)
let wasm_copy_types : (string, Ast.ty) Hashtbl.t = Hashtbl.create 8

let rec add_wasm_copy_deps (t : Ast.ty) : unit =
  let t = Ast.walk t in
  let tag = ty_tag t in
  if Hashtbl.mem wasm_copy_types tag then ()
  else begin
    Hashtbl.add wasm_copy_types tag t;
    match t with
    | Ast.TyTuple ts -> List.iter add_wasm_copy_deps ts
    | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
      let info = Hashtbl.find Typer.records n in
      let mapping =
        if info.Typer.r_params = [] then []
        else List.combine info.Typer.r_params args in
      List.iter (fun (_, ft) -> add_wasm_copy_deps (subst_params mapping ft))
        info.Typer.r_fields
    | Ast.TyCon (n, args) when Hashtbl.mem Exhaustive.type_variants n ->
      let vs = Hashtbl.find Exhaustive.type_variants n in
      let mapping =
        match vs with
        | (cname, _) :: _ ->
          (match Hashtbl.find_opt Typer.constructors cname with
           | Some info when info.Typer.params <> [] ->
             List.combine info.Typer.params args
           | _ -> [])
        | [] -> []
      in
      List.iter (fun (_, arg_opt) ->
        match arg_opt with
        | Some pt -> add_wasm_copy_deps (subst_params mapping pt)
        | None -> ()) vs
    | _ -> ()
  end

(* Is a value of this type a raw i32 (no pointer to copy)? *)
let wasm_unboxed (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyUnit -> true
  | _ -> false

let add_show_type (t : Ast.ty) : unit = add_type_into show_types t

let collect_show_types (root : Ast.expr) (fns : fn_decl list) : unit =
  let rec walk_expr (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
       (match arg.Ast.ty with
        | Some t -> add_show_type t
        | None -> ())
     | Ast.App ({ node = Ast.Var "to_json"; _ }, arg) ->
       (match arg.Ast.ty with
        | Some t -> add_type_into to_json_types t
        | None -> ())
     | Ast.App ({ node = Ast.App ({ node = Ast.Var "of_json_like"; _ }, _); _ }, _) ->
       (* Same decoder as of_json; the target is this node's type, which is
          the witness's. Registered separately because the head is an App. *)
       (match e.Ast.ty with
        | Some t -> add_type_into of_json_types t
        | None -> ())
     | Ast.App ({ node = Ast.App ({ node = Ast.Var "of_json_opt_like"; _ }, _); _ }, _) ->
       (* Only when the target is known. Inside the generic setter's own
          skeleton it is still a variable, and `ty_tag` has no name for one;
          the instantiated copies are what register the real types. *)
       (match e.Ast.ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyCon ("option", [inner]) when ty_is_concrete (Ast.walk inner) ->
             add_type_into of_json_types inner;
             let it = Ast.walk inner in
             Hashtbl.replace of_json_opt_types (ty_tag it) it
           | _ -> ())
        | None -> ())
     | Ast.App ({ node = Ast.Var "of_json"; _ }, _) ->
       (match e.Ast.ty with
        | Some t -> add_type_into of_json_types t
        | None -> ())
     | Ast.App ({ node = Ast.Var "of_json_opt"; _ }, _) ->
       (match e.Ast.ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyCon ("option", [inner]) ->
             add_type_into of_json_types inner;
             let it = Ast.walk inner in
             Hashtbl.replace of_json_opt_types (ty_tag it) it
           | _ -> ())
        | None -> ())
     | Ast.Cmp ((Ast.Eq | Ast.Ne), a, _) ->
       (match a.Ast.ty with
        | Some t when needs_struct_eq t -> add_type_into eq_types t
        | _ -> ())
     | Ast.Cmp ((Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge), a, _) ->
       (match a.Ast.ty with
        | Some t when needs_struct_cmp t -> add_type_into cmp_types t
        | _ -> ())
     | Ast.App ({ node = Ast.Var "mk_metrics"; _ }, _) ->
       (* Phase 16.3: metrics.record uses show_int internally to format
          the integer payload, so register `int` ahead of show_fn_defs. *)
       add_show_type Ast.TyInt
     | Ast.App ({ node = Ast.Var ("str_of_int" | "print_int"); _ }, _) ->
       (* v0.1.42: str_of_int lowers to `call $show_int`, but only `show`
          registered the helper — `print (str_of_int x)` under a top-level
          let produced an undefined $show_int at wat2wasm time (found while
          smoke-testing the bitwise builtins). *)
       add_show_type Ast.TyInt
     | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk_expr a; walk_expr b
    | Ast.Neg a | Ast.Annot (a, _) -> walk_expr a
    | Ast.Let (_, v, b) -> walk_expr v; walk_expr b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk_expr v) bs; walk_expr b
    | Ast.With (_, v, b) -> walk_expr v; walk_expr b
    | Ast.If (c, t, e_) -> walk_expr c; walk_expr t; walk_expr e_
    | Ast.Fun (_, _, b) -> walk_expr b
    | Ast.Constr (_, Some a) -> walk_expr a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk_expr s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk_expr ge | None -> ()); walk_expr b) arms
    | Ast.Tuple es -> List.iter walk_expr es
    | Ast.Region_block (_, b) -> walk_expr b
    | Ast.Ref (_, _, a) -> walk_expr a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk_expr e) fs
    | Ast.Field_get (a, _) -> walk_expr a
    | Ast.Record_update (a, fs) -> walk_expr a; List.iter (fun (_, e) -> walk_expr e) fs
  in
  walk_expr root;
  List.iter (fun f -> walk_expr f.body) fns

let lift_fn_skels (e : Ast.expr) : fn_skel list * Ast.expr =
  (* Phase 26.5 (port of codegen_c Phase 24.4 / codegen_llvm Phase 25.9):
     walk through ALL top-level Let chains so a non-Fun Let
     (e.g., \`let path = "/tmp/x"\`) doesn't break the chain and block
     subsequent \`let rec\` from being lifted. Fun-valued P_var Lets →
     extract as skel + drop from body. Other Lets → keep in body + walk rest.
     Phase 37.A: `let _ = while ... ;` desugars to
     `Let (P_wild, Let_rec (bs, call_loop), rest)`. Lift the inner
     Let_rec as top-level skels and replace the value with its body. *)
  let rec go (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, rest) ->
      (match pat.Ast.pnode, value.Ast.node with
       | Ast.P_var name, Ast.Fun (param, _, fn_body) ->
         let more, rest' = go rest in
         { sname = name; sparam = param; sbody = fn_body; sfun = value }
         :: more, rest'
       | _, Ast.Let_rec (bindings, lr_body) ->
         let lr_skels =
           List.map (fun (n, v) ->
             match v.Ast.node with
             | Ast.Fun (p, _, fb) ->
               { sname = n; sparam = p; sbody = fb; sfun = v }
             | _ ->
               raise (Codegen_error (v.Ast.loc,
                 "let rec inside top-level let value must bind a single-arg function")))
             bindings
         in
         let more, rest' = go { e with Ast.node = Ast.Let (pat, lr_body, rest) } in
         lr_skels @ more, rest'
       | _ ->
         let more, rest' = go rest in
         more, { e with Ast.node = Ast.Let (pat, value, rest') })
    | Ast.Let_rec (bindings, rest) ->
      let skels =
        List.map (fun (n, v) ->
          match v.Ast.node with
          | Ast.Fun (p, _, fb) ->
            { sname = n; sparam = p; sbody = fb; sfun = v }
          | _ ->
            raise (Codegen_error (v.Ast.loc,
              "let rec binding must be a single-arg function in Wasm subset")))
          bindings
      in
      let more, rest' = go rest in
      skels @ more, rest'
    | _ -> [], e
  in
  go e

let find_concrete_arrow (name : string) (root : Ast.expr) : Ast.ty option =
  let found = ref None in
  let rec go (e : Ast.expr) =
    (if !found = None then
       match e.Ast.node with
       | Ast.Var n when n = name ->
         (match e.Ast.ty with
          | Some t ->
            let t = Ast.walk t in
            (match t with
             | Ast.TyArrow _ when ty_is_concrete t -> found := Some t
             | _ -> ())
          | _ -> ())
       | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a; go b
    | Ast.Neg a | Ast.Annot (a, _) -> go a
    | Ast.Let (_, v, b) -> go v; go b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
    | Ast.With (_, v, b) -> go v; go b
    | Ast.If (c, t, e_) -> go c; go t; go e_
    | Ast.Fun (_, _, b) -> go b
    | Ast.Constr (_, Some a) -> go a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      go s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> go ge | None -> ()); go b) arms
    | Ast.Tuple es -> List.iter go es
    | Ast.Region_block (_, b) -> go b
    | Ast.Ref (_, _, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  go root;
  !found

(* Phase 26.4: multi-instantiation specialization (Wasm version of LLVM
   Phase 25.5). Since Wasm IR uniformly uses i32, static specialization is
   technically unnecessary, but we set up the same infra as LLVM for future
   polymorphic `show`/`print`/etc. *)
let multi_inst_fns_wasm : (string, Ast.ty list) Hashtbl.t = Hashtbl.create 4

let mangled_inst_name_wasm (base : string) (arrow : Ast.ty) : string =
  let rec collect_tys t acc =
    match Ast.walk t with
    | Ast.TyArrow (a, b) -> collect_tys b (a :: acc)
    | _ -> List.rev (t :: acc)
  in
  let tys = collect_tys arrow [] in
  base ^ "__" ^ String.concat "__" (List.map ty_tag tys)

let find_all_concrete_arrows_in_wasm (name : string) (exprs : Ast.expr list)
  : Ast.ty list =
  let seen : (string, Ast.ty) Hashtbl.t = Hashtbl.create 4 in
  let rec go (e : Ast.expr) =
    (match e.Ast.node with
     | Ast.Var n when n = name ->
       (match e.Ast.ty with
        | Some t when ty_is_concrete (Ast.walk t) ->
          let walked = Ast.walk t in
          (match walked with
           | Ast.TyArrow _ ->
             let key = Ast.pp_ty walked in
             if not (Hashtbl.mem seen key) then Hashtbl.add seen key walked
           | _ -> ())
        | _ -> ())
     | _ -> ());
    match e.Ast.node with
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> go a; go b
    | Ast.Neg a | Ast.Annot (a, _) -> go a
    | Ast.Let (_, v, b) -> go v; go b
    | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
    | Ast.With (_, v, b) -> go v; go b
    | Ast.If (c, t, e_) -> go c; go t; go e_
    | Ast.Fun (_, _, b) -> go b
    | Ast.Constr (_, Some a) -> go a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      go s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> go ge | None -> ()); go b) arms
    | Ast.Tuple es -> List.iter go es
    | Ast.Region_block (_, b) -> go b
    | Ast.Ref (_, _, a) -> go a
    | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
    | Ast.Field_get (a, _) -> go a
    | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
  in
  List.iter go exprs;
  Hashtbl.fold (fun _ v acc -> v :: acc) seen []

let clone_with_fresh_tyvars_wasm (e : Ast.expr) : Ast.expr =
  let map : (int, Ast.ty) Hashtbl.t = Hashtbl.create 16 in
  let rec clone_ty t =
    match Ast.walk t with
    | Ast.TyVar v ->
      (match Hashtbl.find_opt map v.id with
       | Some fresh -> fresh
       | None ->
         let fresh = Typer.fresh_var () in
         Hashtbl.add map v.id fresh;
         fresh)
    | Ast.TyParam _ as t -> t
    | (Ast.TyInt | Ast.TyFloat | Ast.TyBool | Ast.TyStr | Ast.TyBytes | Ast.TyUnit) as t -> t
    | Ast.TyArrow (a, b) -> Ast.TyArrow (clone_ty a, clone_ty b)
    | Ast.TyTuple ts -> Ast.TyTuple (List.map clone_ty ts)
    | Ast.TyCon (n, args) -> Ast.TyCon (n, List.map clone_ty args)
    | Ast.TyRef (m, r, inner) -> Ast.TyRef (m, r, clone_ty inner)
  in
  let clone_ty_opt = function None -> None | Some t -> Some (clone_ty t) in
  let rec clone_expr (e : Ast.expr) : Ast.expr =
    { Ast.loc = e.Ast.loc;
      ty = clone_ty_opt e.Ast.ty;
      node = clone_node e.Ast.node }
  and clone_node = function
    | (Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _
       | Ast.Str_lit _ | Ast.Unit_lit | Ast.Var _) as n -> n
    | Ast.Bin (op, a, b) -> Ast.Bin (op, clone_expr a, clone_expr b)
    | Ast.Cmp (op, a, b) -> Ast.Cmp (op, clone_expr a, clone_expr b)
    | Ast.Logic (op, a, b) -> Ast.Logic (op, clone_expr a, clone_expr b)
    | Ast.Neg a -> Ast.Neg (clone_expr a)
    | Ast.Let (p, v, b) -> Ast.Let (clone_pattern p, clone_expr v, clone_expr b)
    | Ast.Let_rec (bs, b) ->
      Ast.Let_rec (List.map (fun (n, e) -> (n, clone_expr e)) bs, clone_expr b)
    | Ast.With (n, v, b) -> Ast.With (n, clone_expr v, clone_expr b)
    | Ast.If (c, t, e_) -> Ast.If (clone_expr c, clone_expr t, clone_expr e_)
    | Ast.Fun (n, t_opt, b) ->
      Ast.Fun (n, (match t_opt with None -> None | Some t -> Some (clone_ty t)),
        clone_expr b)
    | Ast.App (a, b) -> Ast.App (clone_expr a, clone_expr b)
    | Ast.Annot (a, t) -> Ast.Annot (clone_expr a, clone_ty t)
    | Ast.Constr (n, Some a) -> Ast.Constr (n, Some (clone_expr a))
    | Ast.Constr (n, None) -> Ast.Constr (n, None)
    | Ast.Match (s, arms) ->
      Ast.Match (clone_expr s,
        List.map (fun (p, g, b) ->
          (clone_pattern p,
           (match g with None -> None | Some e -> Some (clone_expr e)),
           clone_expr b)) arms)
    | Ast.Tuple es -> Ast.Tuple (List.map clone_expr es)
    | Ast.Region_block (n, b) -> Ast.Region_block (n, clone_expr b)
    | Ast.Ref (m, r, a) -> Ast.Ref (m, r, clone_expr a)
    | Ast.Record_lit (n, fs) ->
      Ast.Record_lit (n, List.map (fun (k, v) -> (k, clone_expr v)) fs)
    | Ast.Field_get (a, f) -> Ast.Field_get (clone_expr a, f)
    | Ast.Record_update (a, fs) ->
      Ast.Record_update (clone_expr a,
        List.map (fun (k, v) -> (k, clone_expr v)) fs)
  and clone_pattern p =
    { Ast.ploc = p.Ast.ploc; pnode = clone_pattern_node p.Ast.pnode }
  and clone_pattern_node = function
    | (Ast.P_wild | Ast.P_var _ | Ast.P_int _ | Ast.P_bool _
       | Ast.P_str _ | Ast.P_unit) as n -> n
    | Ast.P_constr (c, Some sub) -> Ast.P_constr (c, Some (clone_pattern sub))
    | Ast.P_constr (c, None) -> Ast.P_constr (c, None)
    | Ast.P_tuple ps -> Ast.P_tuple (List.map clone_pattern ps)
    | Ast.P_record (n, fs) ->
      Ast.P_record (n, List.map (fun (k, v) -> (k, clone_pattern v)) fs)
    | Ast.P_as (p, n) -> Ast.P_as (clone_pattern p, n)
    | Ast.P_or (a, b) -> Ast.P_or (clone_pattern a, clone_pattern b)
  in
  clone_expr e

let resolve_fn_types (skels : fn_skel list) (root : Ast.expr) : fn_decl list =
  (* Phase 21.2 multi-pass + Phase 26.4 multi-instantiation specialization
     (Wasm version of LLVM Phase 25.5). *)
  let resolved : (string, Ast.ty) Hashtbl.t = Hashtbl.create 16 in
  let progress = ref true in
  Hashtbl.reset multi_inst_fns_wasm;
  let multi_specs : (string, (Ast.ty * Ast.expr) list) Hashtbl.t =
    Hashtbl.create 4
  in
  (* Phase 43: re-scan support for chained poly inst (see codegen_c.ml for the explanation) *)
  let make_spec arrow s =
    let cloned_fun = clone_with_fresh_tyvars_wasm s.sfun in
    let clone_fun_ty =
      match cloned_fun.Ast.ty with
      | Some t -> Ast.walk t
      | None -> Ast.TyUnit
    in
    (* v0.1.179: this used to swallow the failure, and a spec whose clone
       will not take the target arrow is a spec whose body belongs to a
       different type. It was emitted anyway — the declaration got the right
       signature and the body kept the operations of whatever type the
       skeleton was already fixed at. Refusing is not the fix; it is the
       difference between a wrong program and a named one. See
       test/parity/poly_helper_fixed_and_free.mere. *)
    (try Typer.unify Loc.dummy clone_fun_ty arrow
     with _ ->
       unsupported s.sfun.Ast.loc (Printf.sprintf
         "unsupported: cannot instantiate `%s` at %s — its skeleton is \
          already fixed at %s, so this instance would be emitted with the \
          other one's body. A polymorphic helper called at both a fixed type \
          and a parameter-derived type, inside a fn used at two types, hits \
          this."
         s.sname (Ast.pp_ty (Ast.walk arrow))
         (Ast.pp_ty (Ast.walk clone_fun_ty))));
    let cloned_body =
      match cloned_fun.Ast.node with
      | Ast.Fun (_, _, b) -> b
      | _ ->
        raise (Codegen_error (s.sfun.Ast.loc,
          "multi-inst clone: expected Fun at root"))
    in
    (arrow, cloned_body)
  in
  while !progress do
    progress := false;
    List.iter (fun s ->
      let extra_exprs () =
        Hashtbl.fold (fun _ specs acc ->
          List.fold_left (fun acc (_, body) -> body :: acc) acc specs
        ) multi_specs []
      in
      if Hashtbl.mem resolved s.sname then ()
      else if Hashtbl.mem multi_specs s.sname then begin
        let all = find_all_concrete_arrows_in_wasm s.sname (root :: extra_exprs ()) in
        let existing = Hashtbl.find multi_specs s.sname in
        let existing_arrows = List.map fst existing in
        let new_arrows = List.filter (fun a ->
          let a_str = Ast.pp_ty (Ast.walk a) in
          not (List.exists (fun e -> Ast.pp_ty (Ast.walk e) = a_str) existing_arrows)) all
        in
        if new_arrows <> [] then begin
          let new_specs = List.map (fun a -> make_spec a s) new_arrows in
          Hashtbl.replace multi_specs s.sname (existing @ new_specs);
          Hashtbl.replace multi_inst_fns_wasm s.sname (existing_arrows @ new_arrows);
          progress := true
        end
      end
      else begin
        let fun_ty =
          match s.sfun.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
        in
        if ty_is_concrete fun_ty then begin
          Hashtbl.add resolved s.sname fun_ty;
          progress := true
        end else
          let all = find_all_concrete_arrows_in_wasm s.sname (root :: extra_exprs ()) in
          match all with
          | _ :: _ ->
            if List.length all > 1 then begin
              Hashtbl.add multi_inst_fns_wasm s.sname all;
              let specs = List.map (fun arrow -> make_spec arrow s) all in
              Hashtbl.add multi_specs s.sname specs;
              progress := true
            end else begin
              (try Typer.unify Loc.dummy fun_ty (List.hd all) with _ -> ());
              Hashtbl.add resolved s.sname (List.hd all);
              progress := true
            end
          | [] -> ()
      end
    ) skels
  done;
  let base = List.concat_map (fun s ->
    match Hashtbl.find_opt multi_specs s.sname with
    | Some specs ->
      List.map (fun (arrow, cloned_body) ->
        match Ast.walk arrow with
        | Ast.TyArrow (p, r) ->
          { name = mangled_inst_name_wasm s.sname arrow;
            param = s.sparam;
            body = cloned_body;
            param_ty = Ast.walk p;
            return_ty = Ast.walk r }
        | other ->
          raise (Codegen_error (s.sfun.Ast.loc,
            Printf.sprintf "function `%s` has non-arrow inferred type `%s`"
              s.sname (Ast.pp_ty other)))
      ) specs
    | None ->
      (match Hashtbl.find_opt resolved s.sname with
       | None -> []
       | Some (Ast.TyArrow (p, r)) ->
         [{ name = s.sname; param = s.sparam; body = s.sbody;
            param_ty = Ast.walk p; return_ty = Ast.walk r }]
       | Some _ ->
         raise (Codegen_error (s.sfun.Ast.loc,
           Printf.sprintf "function `%s` has non-arrow inferred type" s.sname)))
  ) skels in
  (* Recovery pass (port of codegen_c.ml's v0.1.70 recovery): a poly fn that
     never concretized is normally dropped, but if EMITTED code still
     references it (its arrow kept a residual tyvar at every use site) the
     direct call site emits `call $<name>` to a function that was never
     defined — an invalid module (Wasm/LLVM had this bug where C recovered).
     Scan the emitted spine for such live references and emit the fn with its
     tyvars erased to int. Fixpoint: a recovered body may reference another
     unresolved fn. Reuses the backend-agnostic scan/erase from codegen_c. *)
  let skel_names : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun s -> Hashtbl.replace skel_names s.sname ()) skels;
  let emitted_bodies =
    ref (root :: List.map (fun (f : fn_decl) -> f.body) base) in
  let recovered_names : (string, unit) Hashtbl.t = Hashtbl.create 4 in
  let recovered = ref [] in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter (fun s ->
      if not (Hashtbl.mem resolved s.sname)
         && not (Hashtbl.mem multi_specs s.sname)
         && not (Hashtbl.mem recovered_names s.sname) then begin
        let hit =
          List.fold_left (fun acc e ->
            match acc with
            | Some _ -> acc
            | None -> Codegen_c.find_live_arrow s.sname skel_names e) None !emitted_bodies
        in
        match hit with
        | Some ar ->
          (match Codegen_c.deep_erase_tyvars ar with
           | Ast.TyArrow (p, r) ->
             Hashtbl.replace recovered_names s.sname ();
             recovered := { name = s.sname; param = s.sparam; body = s.sbody;
                            param_ty = p; return_ty = r } :: !recovered;
             emitted_bodies := s.sbody :: !emitted_bodies;
             changed := true
           | _ -> ())
        | None -> ()
      end) skels
  done;
  base @ List.rev !recovered

(* Phase 26.3: lift inner Let-Fun / Let_rec to top-level Wasm fns.
   Mirrors codegen_llvm.lift_inner_fns_llvm. Populates inner_lifts_wasm /
   inner_lifts_by_host_wasm + lifted_fns_wasm. *)
let lift_inner_fns_wasm (toplevel_names : string list) (fns : fn_decl list)
    (main_body : Ast.expr) : unit =
  Hashtbl.reset inner_lifts_wasm;
  Hashtbl.reset inner_lifts_by_host_wasm;
  inner_fn_counter_wasm := 0;
  lifted_fns_wasm := [];
  let builtin_names = List.map fst Typer.initial_env in
  let extern_names =
    Hashtbl.fold (fun k _ acc -> k :: acc) extern_fn_decls_wasm []
  in
  let known = ref (toplevel_names @ builtin_names @ extern_names) in
  let current_host = ref "" in
  let lift_one _host_param host_locals n p fn_body =
    let effective_known =
      List.filter (fun k -> not (List.mem k host_locals)) !known
    in
    let body_fvs = free_vars fn_body (p :: effective_known) in
    let lifted_name = fresh_inner_name_wasm n in
    let lf = {
      l_name = lifted_name; l_captures = body_fvs;
      l_param = p; l_body = fn_body;
      l_host = !current_host;
    } in
    lifted_fns_wasm := lf :: !lifted_fns_wasm;
    let entry = { lifted_name; captures = body_fvs } in
    Hashtbl.replace inner_lifts_wasm n entry;
    let host_tbl =
      match Hashtbl.find_opt inner_lifts_by_host_wasm !current_host with
      | Some t -> t
      | None ->
        let t = Hashtbl.create 4 in
        Hashtbl.add inner_lifts_by_host_wasm !current_host t;
        t
    in
    Hashtbl.replace host_tbl n entry;
    known := lifted_name :: !known;
    fn_body
  in
  let rec walk (host_param : string) (host_locals : string list) (e : Ast.expr) =
    match e.Ast.node with
    | Ast.Let (pat, value, body) ->
      (match pat.Ast.pnode, value.Ast.node with
       | Ast.P_var n, Ast.Fun (p, _, fn_body) ->
         let fn_body = lift_one host_param host_locals n p fn_body in
         walk p [] fn_body;
         walk host_param (n :: host_locals) body
       | _ ->
         walk host_param host_locals value;
         walk host_param (pattern_vars pat @ host_locals) body)
    | Ast.Let_rec (bindings, body) ->
      let rec_names = List.map fst bindings in
      let fn_specs = List.map (fun (n, value) ->
        match value.Ast.node with
        | Ast.Fun (p, _, fn_body) -> (n, p, fn_body)
        | _ ->
          raise (Codegen_error (value.Ast.loc,
            "inner let-rec binding must be a single-arg fn"))) bindings
      in
      known := rec_names @ !known;
      List.iter (fun (n, p, fb) ->
        let _ = lift_one host_param host_locals n p fb in ()) fn_specs;
      List.iter (fun (_, p, fb) -> walk p [] fb) fn_specs;
      walk host_param (rec_names @ host_locals) body
    | Ast.Fun (_, _, b) -> walk host_param host_locals b
    | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
    | Ast.Unit_lit | Ast.Var _ -> ()
    | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
    | Ast.App (a, b) -> walk host_param host_locals a; walk host_param host_locals b
    | Ast.Neg a | Ast.Annot (a, _) -> walk host_param host_locals a
    | Ast.With (_, v, b) -> walk host_param host_locals v; walk host_param host_locals b
    | Ast.If (c, t, e_) ->
      walk host_param host_locals c;
      walk host_param host_locals t;
      walk host_param host_locals e_
    | Ast.Constr (_, Some a) -> walk host_param host_locals a
    | Ast.Constr (_, None) -> ()
    | Ast.Match (s, arms) ->
      walk host_param host_locals s;
      List.iter (fun (_, g, b) ->
        (match g with Some ge -> walk host_param host_locals ge | None -> ());
        walk host_param host_locals b) arms
    | Ast.Tuple es -> List.iter (walk host_param host_locals) es
    | Ast.Region_block (_, b) -> walk host_param host_locals b
    | Ast.Ref (_, _, a) -> walk host_param host_locals a
    | Ast.Record_lit (_, fs) ->
      List.iter (fun (_, e) -> walk host_param host_locals e) fs
    | Ast.Field_get (a, _) -> walk host_param host_locals a
    | Ast.Record_update (a, fs) ->
      walk host_param host_locals a;
      List.iter (fun (_, e) -> walk host_param host_locals e) fs
  in
  List.iter (fun (f : fn_decl) ->
    current_host := f.name;
    walk f.param [f.param] f.body) fns;
  (* Also lift inner `let rec` in the top-level program expression, under the
     synthetic host "$main" (mirrors codegen_c) — so a recursive helper in
     main is lifted rather than rejected. *)
  current_host := "$main";
  walk "" [] main_body;
  (* Phase 45 (DEFERRED §8): transitive capture closure for mutually-called
     inner-lifted fns. See the same-phase comment in codegen_c.ml for details *)
  let all_lifted = !lifted_fns_wasm in
  (* Build a per-host mere→lifted map. Using a single global map keyed
     only by raw name causes collisions when two different top-level
     fns each define an inner-lifted helper with the same source name
     (e.g. two separate `let rec walk = …` bodies) — the second
     silently overwrote the first, and the transitive-capture pass
     then attributed the wrong capture set to inter-sibling calls,
     surfacing as `inner-lifted capture X not in scope` at emit. *)
  let mere_to_lifted_by_host : (string, (string, string) Hashtbl.t) Hashtbl.t =
    Hashtbl.create 8
  in
  Hashtbl.iter (fun host tbl ->
    let m = Hashtbl.create 4 in
    Hashtbl.iter (fun mname entry -> Hashtbl.replace m mname entry.lifted_name) tbl;
    Hashtbl.replace mere_to_lifted_by_host host m
  ) inner_lifts_by_host_wasm;
  let mere_to_lifted_for host =
    match Hashtbl.find_opt mere_to_lifted_by_host host with
    | Some m -> m
    | None -> Hashtbl.create 0
  in
  (* Note that Wasm captures are a string list, so the type differs *)
  let captures_map : (string, string list) Hashtbl.t =
    Hashtbl.create 8
  in
  List.iter (fun lf ->
    let host_map = mere_to_lifted_for lf.l_host in
    let filtered = List.filter (fun n ->
      not (Hashtbl.mem host_map n)) lf.l_captures in
    Hashtbl.replace captures_map lf.l_name filtered) all_lifted;
  let rec scan_for_called host_map called_acc (e : Ast.expr) cur_name =
    let acc = ref called_acc in
    (match e.Ast.node with
     | Ast.Var n when Hashtbl.mem host_map n
                   && Hashtbl.find host_map n <> cur_name ->
       let cl_name = Hashtbl.find host_map n in
       if not (List.mem cl_name !acc) then acc := cl_name :: !acc
     | _ -> ());
    let recurse sub = acc := scan_for_called host_map !acc sub cur_name in
    (match e.Ast.node with
     | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
     | Ast.Unit_lit | Ast.Var _ -> ()
     | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
     | Ast.App (a, b) -> recurse a; recurse b
     | Ast.Neg a | Ast.Annot (a, _) -> recurse a
     | Ast.Let (_, v, b) -> recurse v; recurse b
     | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> recurse v) bs; recurse b
     | Ast.With (_, v, b) -> recurse v; recurse b
     | Ast.If (c, t, e_) -> recurse c; recurse t; recurse e_
     | Ast.Fun (_, _, b) -> recurse b
     | Ast.Constr (_, Some a) -> recurse a
     | Ast.Constr (_, None) -> ()
     | Ast.Match (s, arms) ->
       recurse s;
       List.iter (fun (_, g, b) ->
         (match g with Some ge -> recurse ge | None -> ()); recurse b) arms
     | Ast.Tuple es -> List.iter recurse es
     | Ast.Region_block (_, b) -> recurse b
     | Ast.Ref (_, _, a) -> recurse a
     | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> recurse e) fs
     | Ast.Field_get (a, _) -> recurse a
     | Ast.Record_update (a, fs) -> recurse a;
       List.iter (fun (_, e) -> recurse e) fs);
    !acc
  in
  (* v0.1.111 (port of codegen_c's v0.1.48 fix): names bound ANYWHERE inside a
     lifted fn's own body (let locals, nested-fn params, match-arm binders,
     with / region names). A callee's capture that is one of these is already
     in scope inside lf, so it must NOT be threaded into lf's captures —
     otherwise lf over-captures and, when lf is itself called, its host is
     asked to pass a name it never had (surfacing as `inner-lifted capture X
     not in scope`; found by sudoku, whose inner `cell` captures the match-arm
     variable `row` bound in its host `load`). *)
  let bound_names_in (e0 : Ast.expr) : string list =
    let acc = ref [] in
    let add n = acc := n :: !acc in
    let rec go (e : Ast.expr) =
      (match e.Ast.node with
       | Ast.Fun (p, _, _) -> add p
       | Ast.Let (pat, _, _) -> List.iter add (pattern_vars pat)
       | Ast.Let_rec (bs, _) -> List.iter (fun (n, _) -> add n) bs
       | Ast.With (n, _, _) -> add n
       | Ast.Region_block (n, _) -> add n
       | Ast.Match (_, arms) ->
         List.iter (fun (pat, _, _) -> List.iter add (pattern_vars pat)) arms
       | _ -> ());
      match e.Ast.node with
      | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
      | Ast.Unit_lit | Ast.Var _ -> ()
      | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
      | Ast.App (a, b) -> go a; go b
      | Ast.Neg a | Ast.Annot (a, _) -> go a
      | Ast.Let (_, v, b) -> go v; go b
      | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> go v) bs; go b
      | Ast.With (_, v, b) -> go v; go b
      | Ast.If (c, t, e_) -> go c; go t; go e_
      | Ast.Fun (_, _, b) -> go b
      | Ast.Constr (_, Some a) -> go a
      | Ast.Constr (_, None) -> ()
      | Ast.Match (s, arms) ->
        go s;
        List.iter (fun (_, g, b) ->
          (match g with Some ge -> go ge | None -> ()); go b) arms
      | Ast.Tuple es -> List.iter go es
      | Ast.Region_block (_, b) -> go b
      | Ast.Ref (_, _, a) -> go a
      | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> go e) fs
      | Ast.Field_get (a, _) -> go a
      | Ast.Record_update (a, fs) -> go a; List.iter (fun (_, e) -> go e) fs
    in
    go e0; !acc
  in
  let bound_map : (string, string list) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun lf ->
    Hashtbl.replace bound_map lf.l_name (bound_names_in lf.l_body)) all_lifted;
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter (fun lf ->
      let host_map = mere_to_lifted_for lf.l_host in
      let called_inner = scan_for_called host_map [] lf.l_body lf.l_name in
      let self_bound =
        match Hashtbl.find_opt bound_map lf.l_name with Some bs -> bs | None -> [] in
      let cur_caps = Hashtbl.find captures_map lf.l_name in
      let new_caps = ref cur_caps in
      List.iter (fun called_lifted_name ->
        let other_caps = Hashtbl.find captures_map called_lifted_name in
        List.iter (fun cap_n ->
          if cap_n = lf.l_param then ()
          else if Hashtbl.mem host_map cap_n then ()
          else if List.mem cap_n !new_caps then ()
          else if List.mem cap_n self_bound then ()
          else begin
            new_caps := !new_caps @ [cap_n];
            changed := true
          end
        ) other_caps
      ) called_inner;
      Hashtbl.replace captures_map lf.l_name !new_caps
    ) all_lifted
  done;
  lifted_fns_wasm := List.map (fun lf ->
    let new_caps = Hashtbl.find captures_map lf.l_name in
    { lf with l_captures = new_caps }) all_lifted;
  Hashtbl.iter (fun _host tbl ->
    Hashtbl.iter (fun mere_n entry ->
      let new_caps = Hashtbl.find captures_map entry.lifted_name in
      Hashtbl.replace tbl mere_n { entry with captures = new_caps }
    ) tbl) inner_lifts_by_host_wasm;
  Hashtbl.iter (fun mere_n entry ->
    let new_caps = Hashtbl.find captures_map entry.lifted_name in
    Hashtbl.replace inner_lifts_wasm mere_n { entry with captures = new_caps }
  ) inner_lifts_wasm

(* Map Lang binop / cmp / logic to Wasm opcodes. All operands are i32
   (bool also widens to i32). *)
let wasm_binop = function
  | Ast.Add -> "i64.add"
  | Ast.Sub -> "i64.sub"
  | Ast.Mul -> "i64.mul"
  | Ast.Div -> "i64.div_s"
  | Ast.Mod -> "i64.rem_s"
  | Ast.Concat -> raise Exit

(* Wasm comparisons yield i32; call sites extend back to the i64 value
   model (bools are values). *)
let wasm_cmp = function
  | Ast.Eq -> "i64.eq"
  | Ast.Ne -> "i64.ne"
  | Ast.Lt -> "i64.lt_s"
  | Ast.Le -> "i64.le_s"
  | Ast.Gt -> "i64.gt_s"
  | Ast.Ge -> "i64.ge_s"

(* float (f64) variants — operators overloaded on float (see typer). *)
let wasm_binop_float = function
  | Ast.Add -> "f64.add"
  | Ast.Sub -> "f64.sub"
  | Ast.Mul -> "f64.mul"
  | Ast.Div -> "f64.div"
  | Ast.Mod | Ast.Concat -> raise Exit

let wasm_cmp_float = function
  | Ast.Eq -> "f64.eq"
  | Ast.Ne -> "f64.ne"
  | Ast.Lt -> "f64.lt"
  | Ast.Le -> "f64.le"
  | Ast.Gt -> "f64.gt"
  | Ast.Ge -> "f64.ge"

(* Phase 15.10: In Wasm all values are i32 so per-V is unnecessary; only
   branch helpers on K (int / str). *)
let map_key_tag_of_wasm (ty_opt : Ast.ty option) (loc : Loc.t) : string =
  match ty_opt with
  | Some t ->
    (match Ast.walk t with
     | Ast.TyCon ("Map", [_; k_ty; _]) ->
       let k_ty = Ast.walk k_ty in
       let rec is_key_supported = function
         | Ast.TyInt | Ast.TyBool | Ast.TyStr -> true
         | Ast.TyTuple ts -> List.for_all is_key_supported ts
         | Ast.TyCon (rname, _) when Hashtbl.mem Typer.records rname ->
           let info = Hashtbl.find Typer.records rname in
           List.for_all (fun (_, ft) -> is_key_supported (Ast.walk ft))
             info.Typer.r_fields
         | Ast.TyCon (vname, _) when Hashtbl.mem Exhaustive.type_variants vname ->
           let ctors = Hashtbl.find Exhaustive.type_variants vname in
           List.for_all (fun (_, payload) ->
             match payload with
             | None -> true
             | Some pt -> is_key_supported (Ast.walk pt)) ctors
         | _ -> false
       in
       if not (is_key_supported k_ty) then
         raise (Codegen_error (loc,
           "Map key type must be int / bool / str / tuple / record / variant in Wasm codegen (Phase 15.10〜15.16)"));
       let tag = ty_tag k_ty in
       if not (Hashtbl.mem map_key_types tag) then
         Hashtbl.add map_key_types tag k_ty;
       tag
     | _ -> raise (Codegen_error (loc, "map_* expected a Map value")))
  | None -> raise (Codegen_error (loc, "map_*: missing type info"))

(* Phase 48.5: round `__lang_bump` up to the next 4-byte boundary.
   Wasm's `i32.store` / `i32.load` handle unaligned access transparently,
   so internal Mere code doesn't care, but host code that reads
   closure records via `Int32Array` would land on the wrong word if
   the record sat at an odd offset. Call this immediately before
   bump-allocating a closure record (8-byte { env, fn_idx } struct)
   so the pointer handed to host glue is always 4-byte aligned.
   See contrib/dom/dom.glue.js for the JS side (which now uses
   DataView anyway, but alignment is the proper Mere-side fix). *)
let emit_align_bump_4 () : unit =
  emit_instr "global.get $__lang_bump";
  emit_instr "i32.const 3";
  emit_instr "i32.add";
  emit_instr "i32.const -4";
  emit_instr "i32.and";
  emit_instr "global.set $__lang_bump"

(* Phase 34.3: Wasm float helper. Float values are **bump-alloc'd as 8 bytes
   (f64) and held as i32 pointers** (preserving the uniform i32 value model).
   `emit_float_alloc_from_f64_on_stack`: alloc + store the f64 value at the
   stack top, leaving an i32 ptr at the stack top. *)
let emit_float_alloc_from_f64_on_stack () : unit =
  (* Stack before: [..., f64] *)
  let tmp_f64 = fresh_local_f64 () in
  emit_instr (Printf.sprintf "local.set %d" tmp_f64);
  (* Stack: [...] — f64 saved in tmp local *)
  emit_instr "global.get $__lang_bump";
  emit_instr "i32.const 7";
  emit_instr "i32.add";
  emit_instr "i32.const -8";
  emit_instr "i32.and";
  emit_instr "global.set $__lang_bump";           (* align bump up to 8 *)
  emit_instr "global.get $__lang_bump";            (* push ptr (= aligned bump) *)
  emit_instr (Printf.sprintf "local.get %d" tmp_f64);
  emit_instr "f64.store offset=0 align=8";        (* memory[ptr] = f64 *)
  emit_instr "global.get $__lang_bump";            (* push ptr again (= return value) *)
  emit_instr "i64.extend_i32_u";                   (* ptr becomes a Mere value *)
  emit_instr "global.get $__lang_bump";
  emit_instr "i32.const 8";
  emit_instr "i32.add";
  emit_instr "global.set $__lang_bump"            (* bump += 8 *)
  (* Stack: [..., ptr as i64] *)

(* A host/stdlib builtin name (`run`, `time`, `args`, `exit`, …) is only a
   builtin when the user hasn't bound that name themselves. Mirrors
   codegen_c's `user_shadows`: a user's local OR top-level definition always
   wins over the builtin fallback. Without the top-level checks, a program
   with e.g. `let rec run = …` (a CPU-emulator loop) would collide with the
   subprocess `run` builtin and miscompile the call into `i64.const 127`.
   `toplevel_fn_names` / `fn_closure_table_idx` are populated before any body
   (fn or main) is emitted and survive `reset ()`, so they are reliable here. *)
let user_shadows_wasm name =
  (* Locals and lifted inner fns are lexically in scope by construction, so
     they decide on their own. For a top-level name the question is where we
     are in the file, and it has to be asked before the name-only tables:
     `fn_closure_table_idx` and `top_globals_wasm` also hold top-level fn
     names, and answering from those would put a binding in scope above its
     own declaration. *)
  List.mem_assoc name !locals
  || Hashtbl.mem inner_lifts_wasm name
  || (match Hashtbl.find_opt toplevel_fn_pos name with
      | Some p -> p <= !current_toplevel_pos
      | None ->
        Hashtbl.mem toplevel_fn_names name
        || Hashtbl.mem fn_closure_table_idx name
        || Hashtbl.mem top_globals_wasm name)

(* The head of an application spine: `f a b c` is App (App (App (f, a), b), c),
   so a three-argument builtin is matched at the outermost App with the name
   three levels down. A guard has to ask about the same name the builtin arms
   will match on, which is this one. *)
let rec app_spine_head_wasm (x : Ast.expr) : Ast.expr =
  match x.Ast.node with
  | Ast.App (g, _) -> app_spine_head_wasm g
  | _ -> x

let app_head_user_bound_wasm (x : Ast.expr) : bool =
  match (app_spine_head_wasm x).Ast.node with
  | Ast.Var n -> user_shadows_wasm n
  | _ -> false

(* Emit `expr` so its result lands on top of the Wasm operand stack. *)
let rec emit_expr (e : Ast.expr) : unit =
  (* Snapshot inbound tail-position + top-level-body flags. All
     descendant emit_expr calls default back to non-tail / non-top;
     tail-preserving nodes (If branches, Let body, Match arm bodies)
     reinstate `saved_tail`, and Let / Let_rec bodies additionally
     reinstate `saved_top` so a top-level let-spine stays top-level
     as it walks down. *)
  let saved_tail = !wasm_tail_pos in
  let saved_top = !wasm_in_top_level_body in
  wasm_tail_pos := false;
  wasm_in_top_level_body := false;
  match e.Ast.node with
  | Ast.Int_lit n ->
    (* v0.1.127: the Wasm value model is uniform i64 (the mclock/mdate
       trigger — epoch-ms exceeds 2^31). The old v0.1.41 rejection of
       literals outside i32 is gone; the full 64-bit range emits. *)
    emit_instr (Printf.sprintf "i64.const %d" n)
  | Ast.Float_lit f ->
    (* Phase 34.3: push the f64 literal, bump alloc to get a boxed ptr *)
    emit_instr (Printf.sprintf "f64.const %.17g" f);
    emit_float_alloc_from_f64_on_stack ()
  | Ast.Bool_lit b ->
    emit_instr (Printf.sprintf "i64.const %d" (if b then 1 else 0))
  | Ast.Unit_lit ->
    emit_instr "i64.const 0"
  | Ast.Str_lit s ->
    let off = fresh_str_offset s in
    emit_instr (Printf.sprintf "i64.const %d" off)
  | Ast.Var "pi" when not (user_shadows_wasm "pi") ->
    (* Phase 34.3: float constants — heap-alloc and push an i32 ptr *)
    emit_instr "f64.const 3.14159265358979323846";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.Var "e" when not (user_shadows_wasm "e") ->
    emit_instr "f64.const 2.7182818284590452354";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.Var name ->
    (* Phase 26.6 (port of codegen_c Phase 24.1 / codegen_llvm Phase 25.10):
       a local binding (locals) can shadow a stdlib builtin name like `len`.
       Treat as regular var if shadowed; only reject if it's the actual
       stdlib builtin as a value. *)
    let is_shadowed = List.mem_assoc name !locals in
    (* Phase 35.3: nullary factory builtins as first-class values via
       eta-wrap. Compute adapter slug + register a `(func $eta_<slug>` that
       will be emitted by emit_program. *)
    let is_nullary_factory = name = "vec_new" || name = "owned_vec_new"
                              || name = "strbuf_new" || name = "map_new" in
    let eta_table_idx_opt =
      if (not is_shadowed) && is_nullary_factory then
        match e.Ast.ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyArrow (_, ret_ty) when ty_is_concrete (Ast.walk ret_ty) ->
             let ret_ty = Ast.walk ret_ty in
             (* Pick adapter slug + set runtime usage flags *)
             let slug =
               match name, Ast.walk ret_ty with
               | "vec_new", _ -> vec_used := true; "vec_new"
               | "owned_vec_new", _ -> vec_used := true; "owned_vec_new"
               | "strbuf_new", _ -> strbuf_used := true; "strbuf_new"
               | "map_new", Ast.TyCon ("Map", [_; k_ty; _]) ->
                 let k_tag =
                   match Ast.walk k_ty with
                   | Ast.TyInt -> map_int_used := true; "int"
                   | Ast.TyStr -> map_str_used := true; "str"
                   | _ -> "?"
                 in
                 "map_new_" ^ k_tag
               | _ -> "?"
             in
             let idx =
               match Hashtbl.find_opt eta_adapters_wasm slug with
               | Some (_, _, i) -> i
               | None ->
                 let i = register_in_table ("eta_" ^ slug) in
                 Hashtbl.add eta_adapters_wasm slug (name, ret_ty, i);
                 i
             in
             Some idx
           | _ -> None)
        | None -> None
      else None
    in
    (* Phase 15.4: curried multi-arg builtins like vec_*, owned_vec_*,
       strbuf_*, map_* are still not first-class (eta is for nullary
       factories only). *)
    let is_curried_collection_builtin =
      name = "vec_push"
      || name = "vec_get" || name = "vec_len"
      || name = "vec_set" || name = "vec_iter" || name = "vec_fold"
      || name = "vec_reverse" || name = "vec_concat" || name = "vec_sort"
      || name = "vec_map" || name = "vec_filter"
      || name = "vec_to_owned" || name = "owned_vec_to_vec"
      || name = "owned_vec_push"
      || name = "owned_vec_get" || name = "owned_vec_len"
      || name = "strbuf_push"
      || name = "strbuf_to_str" || name = "strbuf_len"
      || name = "map_set" || name = "map_get" || name = "map_iter"
      || name = "map_has" || name = "map_len"
    in
    let is_phase38c_target =
      name = "owned_vec_push" || name = "owned_vec_get"
      || name = "vec_push" || name = "vec_get"
      || name = "strbuf_push"
      || name = "map_get" || name = "map_has"
      || name = "map_set" || name = "vec_set"
    in
    (* Phase 38.A1: value-ification of single-arg builtins *)
    let is_single_arg_value_builtin =
      name = "int_of_str" || name = "str_of_int"
      || name = "str_len" || name = "str_rev" || name = "str_trim"
      || name = "str_unescape"
      || name = "ord" || name = "chr"
      || name = "to_upper" || name = "to_lower"
      || name = "not" || name = "abs" || name = "even" || name = "odd"
      || name = "bool_of_str"
      || name = "float_of_int" || name = "int_of_float"
      || name = "str_of_float" || name = "float_of_str"
      || name = "f_neg" || name = "f_abs"
      || name = "sqrt" || name = "sin" || name = "cos" || name = "tan"
      || name = "print" || name = "fail"
      || name = "fst" || name = "snd"
    in
    let phase38c_emittable =
      let curried_ok =
        not is_shadowed && is_curried_collection_builtin && is_phase38c_target
      in
      let single_ok =
        not is_shadowed && is_single_arg_value_builtin
      in
      if curried_ok || single_ok then
        match e.Ast.ty with
        | Some t when ty_is_concrete (Ast.walk t) ->
          (match Ast.walk t with
           | Ast.TyArrow _ -> true
           | _ -> false)
        | _ -> false
      else false
    in
    if not is_shadowed && is_curried_collection_builtin && not phase38c_emittable then
      raise (Codegen_error (e.Ast.loc,
        "unsupported in Wasm codegen subset: " ^ name
        ^ " as a value (Phase 15.4-15.10: curried multi-arg builtin only supports direct application, partial support in progress in Phase 38.C)"));
    if not is_shadowed && is_single_arg_value_builtin && not phase38c_emittable then
      raise (Codegen_error (e.Ast.loc,
        "unsupported in Wasm codegen subset: " ^ name
        ^ " as a value: type is polymorphic (Phase 38.A1 MVP: wrap with `fn x -> " ^ name ^ " x`)"));
    if not is_shadowed && is_nullary_factory && eta_table_idx_opt = None then
      raise (Codegen_error (e.Ast.loc,
        "unsupported in Wasm codegen subset: " ^ name
        ^ " as a value: return type is polymorphic, can't monomorphize \
           (Phase 35.3 MVP: use direct app or manual eta `fn () -> " ^ name ^ " ()`)"));
    if not is_shadowed && (name = "len" || name = "vec_to_list") then
      raise (Codegen_error (e.Ast.loc,
        "unsupported in Wasm codegen subset: " ^ name
        ^ " as a value (Phase 15.11/15.12: len / vec_to_list only support direct application)"));
    if phase38c_emittable then begin
      (* Phase 38.C-5: emit the synthesized eta-expanded Fun chain.
         Inner App nodes hit the existing direct-call fast paths
         (line 1653+). *)
      let arrow =
        match e.Ast.ty with
        | Some t -> Ast.walk t
        | None -> assert false
      in
      emit_expr (synthesize_curried_eta_wasm name arrow e.Ast.loc)
    end else
    (match eta_table_idx_opt with
     | Some idx ->
       (* Allocate a closure value `{ env = 0, fn_idx = idx }` on the
          bump heap, just like the toplevel-fn case below. *)
       emit_align_bump_4 ();  (* Phase 48.5: 4-byte align for host glue *)
       let base = fresh_local_i32 () in
       emit_instr "global.get $__lang_bump";
       emit_instr (Printf.sprintf "local.set %d" base);
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr "i32.const 8";
       emit_instr "i32.add";
       emit_instr "global.set $__lang_bump";
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr "i32.const 0";
       emit_instr "i32.store offset=0";
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr (Printf.sprintf "i32.const %d" idx);
       emit_instr "i32.store offset=4";
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr "i64.extend_i32_u"
     | None ->
    (match List.assoc_opt name !locals with
     | Some slot -> emit_instr (Printf.sprintf "local.get %d" slot)
     | None when Hashtbl.mem fn_closure_table_idx name ->
       (* Top-level fn as a value: materialize a closure
          `{ env = 0, fn_idx = table_idx }`. *)
       let idx = Hashtbl.find fn_closure_table_idx name in
       emit_align_bump_4 ();  (* Phase 48.5: 4-byte align for host glue *)
       let base = fresh_local_i32 () in
       emit_instr "global.get $__lang_bump";
       emit_instr (Printf.sprintf "local.set %d" base);
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr "i32.const 8";
       emit_instr "i32.add";
       emit_instr "global.set $__lang_bump";
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr "i32.const 0";
       emit_instr "i32.store offset=0";
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr (Printf.sprintf "i32.const %d" idx);
       emit_instr "i32.store offset=4";
       emit_instr (Printf.sprintf "local.get %d" base);
       emit_instr "i64.extend_i32_u"
     | None when Hashtbl.mem top_globals_wasm name ->
       (* Phase 30.2c: top-level non-fn let as a Wasm global *)
       emit_instr (Printf.sprintf "global.get $%s" name)
     | None when Hashtbl.mem inner_lifts_wasm name ->
       (* Phase 39.A2: materialize inner-lifted fn at value position.
          Alloc env in the bump heap + store captures + write the closure
          value (env_offset, fn_idx) as an 8-byte struct to the bump heap. *)
       let li = Hashtbl.find inner_lifts_wasm name in
       let cap_count = List.length li.captures in
       let env_size = max 8 (cap_count * 8) in
       let table_idx =
         match Hashtbl.find_opt inner_lift_closures_emitted_wasm li.lifted_name with
         | Some idx -> idx
         | None ->
           let adapter_name = li.lifted_name ^ "_inner_closure_fn" in
           let idx = register_in_table adapter_name in
           Hashtbl.add inner_lift_closures_emitted_wasm li.lifted_name idx;
           inner_lift_closure_pending_wasm :=
             (li.lifted_name, li.captures, idx)
             :: !inner_lift_closure_pending_wasm;
           idx
       in
       (* Reserve the env area (8-byte value slots, v0.1.127) *)
       let env_base = fresh_local_i32 () in
       emit_instr "global.get $__lang_bump";
       emit_instr (Printf.sprintf "local.set %d" env_base);
       emit_instr (Printf.sprintf "local.get %d" env_base);
       emit_instr (Printf.sprintf "i32.const %d" env_size);
       emit_instr "i32.add";
       emit_instr "global.set $__lang_bump";
       (* Store each capture into an env field *)
       List.iteri (fun i cn ->
         let cv_slot =
           match List.assoc_opt cn !locals with
           | Some s -> s
           | None ->
             unsupported e.Ast.loc
               ("inner-lifted fn `" ^ name ^ "`: cannot resolve capture `" ^ cn
                ^ "` (Wasm Phase 39.A2 MVP — only locals are supported)")
         in
         emit_instr (Printf.sprintf "local.get %d" env_base);
         emit_instr (Printf.sprintf "local.get %d" cv_slot);
         emit_instr (Printf.sprintf "i64.store offset=%d" (i * 8))
       ) li.captures;
       (* closure value `{env_offset, fn_table_idx}` written to the bump heap.
          The record keeps i32 fields — host glue reads it with DataView. *)
       emit_align_bump_4 ();  (* Phase 48.5: 4-byte align for host glue *)
       let cl_base = fresh_local_i32 () in
       emit_instr "global.get $__lang_bump";
       emit_instr (Printf.sprintf "local.set %d" cl_base);
       emit_instr (Printf.sprintf "local.get %d" cl_base);
       emit_instr "i32.const 8";
       emit_instr "i32.add";
       emit_instr "global.set $__lang_bump";
       emit_instr (Printf.sprintf "local.get %d" cl_base);
       emit_instr (Printf.sprintf "local.get %d" env_base);
       emit_instr "i32.store offset=0";
       emit_instr (Printf.sprintf "local.get %d" cl_base);
       emit_instr (Printf.sprintf "i32.const %d" table_idx);
       emit_instr "i32.store offset=4";
       emit_instr (Printf.sprintf "local.get %d" cl_base);
       emit_instr "i64.extend_i32_u"
     | None ->
       if List.mem name host_builtins_without_wasm_lowering then
         unsupported e.Ast.loc
           (name ^ " has no Wasm lowering yet (host builtin; scope = interp + C)")
       else if Hashtbl.mem multi_inst_fns_wasm name then
         (* v0.1.173: the name IS bound — it is a polymorphic fn used at more
            than one type, so it exists only as mangled per-instantiation
            copies and there is no single function to hand out as a value.
            Saying "unbound variable" here sent the reader looking for a
            missing definition instead of at the real limitation. *)
         unsupported e.Ast.loc
           (name ^ " is used at several types, so it has no single value form \
                    on Wasm yet — call it directly, or give it one type")
       else if String.length name >= 5 && String.sub name 0 5 = "__pm_" then
         (* v0.1.228: `par_map f xs` is desugared at parse time into spawn +
            channel + list_map, binding helpers named `__pm_*`. Wasm cannot resolve
            the let-bound lambda from inside the nested closure the desugaring
            builds, and reported `unbound variable: __pm_f1` — a name the user never
            wrote, about a function they did not know exists. Name what they wrote. *)
         unsupported e.Ast.loc
           "par_map has no Wasm lowering yet: it desugars to spawn + channel + \
            list_map, and this backend cannot resolve the captured function from \
            inside that nesting. Map and spawn by hand, or use another backend"
       else
         unsupported e.Ast.loc ("unbound variable: " ^ name)))
  | Ast.Annot (inner, _) -> emit_expr inner
  | Ast.Neg inner ->
    (* v0.1.44: unary minus is numeric-overloaded like Bin (the typer
       stamps the operand type). Float values are boxed f64 pointers. *)
    (match inner.Ast.ty with
     | Some t when Ast.walk t = Ast.TyFloat ->
       emit_expr inner;
       emit_instr "i32.wrap_i64";
       emit_instr "f64.load offset=0 align=8";
       emit_instr "f64.neg";
       emit_float_alloc_from_f64_on_stack ()
     | _ ->
       emit_instr "i64.const 0";
       emit_expr inner;
       emit_instr "i64.sub")
  | Ast.Bin (Ast.Concat, a, b) ->
    emit_expr a;
    emit_expr b;
    emit_instr "call $__lang_str_concat"
  | Ast.Bin (op, a, b) ->
    (match a.Ast.ty with
     | Some t when Ast.walk t = Ast.TyFloat ->
       (* floats are boxed (i64-held ptr -> heap f64): wrap, load, op, re-box. *)
       emit_expr a; emit_instr "i32.wrap_i64"; emit_instr "f64.load offset=0 align=8";
       emit_expr b; emit_instr "i32.wrap_i64"; emit_instr "f64.load offset=0 align=8";
       emit_instr (wasm_binop_float op);
       emit_float_alloc_from_f64_on_stack ()
     | _ ->
       emit_expr a; emit_expr b; emit_instr (wasm_binop op))
  | Ast.Cmp (op, a, b) ->
    (* Phase 26.1: TyStr eq/ne via $__lang_streq; ordering (< <= > >=) via
       $__lang_str_compare (3-way, -1/0/1) compared to 0. *)
    let a_ty = match a.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyInt in
    (match a_ty, op with
     | Ast.TyStr, Ast.Eq ->
       (* runtime helpers speak the i64 value model: streq returns an
          i64 bool directly. *)
       emit_expr a; emit_expr b;
       emit_instr "call $__lang_streq"
     | Ast.TyStr, Ast.Ne ->
       emit_expr a; emit_expr b;
       emit_instr "call $__lang_streq";
       emit_instr "i64.eqz";
       emit_instr "i64.extend_i32_u"
     | Ast.TyStr, (Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge) ->
       emit_expr a; emit_expr b;
       emit_instr "call $__lang_str_compare";
       emit_instr "i64.const 0";
       emit_instr (wasm_cmp op);
       emit_instr "i64.extend_i32_u"
     | ty, Ast.Eq when needs_struct_eq ty ->
       emit_expr a; emit_expr b;
       emit_instr (Printf.sprintf "call $eq_%s" (ty_tag ty))
     | ty, Ast.Ne when needs_struct_eq ty ->
       emit_expr a; emit_expr b;
       emit_instr (Printf.sprintf "call $eq_%s" (ty_tag ty));
       emit_instr "i64.eqz";
       emit_instr "i64.extend_i32_u"
     | ty, (Ast.Lt | Ast.Le | Ast.Gt | Ast.Ge) when needs_struct_cmp ty ->
       (* v0.1.11 derive-ord: compound ordering via cmp_<tag> (-1/0/1) vs 0. *)
       emit_expr a; emit_expr b;
       emit_instr (Printf.sprintf "call $cmp_%s" (ty_tag ty));
       emit_instr "i64.const 0";
       emit_instr (wasm_cmp op);
       emit_instr "i64.extend_i32_u"
     | Ast.TyFloat, _ ->
       (* floats are boxed (i64-held ptr): wrap, load both f64, compare,
          extend the i32 comparison result back to an i64 bool *)
       emit_expr a; emit_instr "i32.wrap_i64"; emit_instr "f64.load offset=0 align=8";
       emit_expr b; emit_instr "i32.wrap_i64"; emit_instr "f64.load offset=0 align=8";
       emit_instr (wasm_cmp_float op);
       emit_instr "i64.extend_i32_u"
     | _ ->
       emit_expr a;
       emit_expr b;
       emit_instr (wasm_cmp op);
       emit_instr "i64.extend_i32_u")
  | Ast.Logic (op, a, b) ->
    (* v0.1.34: SHORT-CIRCUIT, matching the interpreter and the C
       backend. The old strict `i32.and` / `i32.or` evaluated both
       operands, so the bounds-guard idiom `i < len && vec_get v i == x`
       trapped on Wasm only — found by the 2048 dogfood's stuck
       detection, where 97% of live keypresses died silently. Lower to
       the If emission (which handles the tail flag correctly). *)
    let const_bool v =
      Ast.{ node = Ast.Bool_lit v; ty = Some Ast.TyBool; loc = e.Ast.loc } in
    (match op with
     | Ast.And -> emit_expr Ast.{ e with node = Ast.If (a, b, const_bool false) }
     | Ast.Or -> emit_expr Ast.{ e with node = Ast.If (a, const_bool true, b) })
  | Ast.If (cond, t, f) ->
    emit_expr cond;
    emit_instr "i32.wrap_i64";      (* i64 bool -> i32 condition *)
    emit_instr "if (result i64)";
    wasm_tail_pos := saved_tail;
    emit_expr t;
    emit_instr "else";
    wasm_tail_pos := saved_tail;
    emit_expr f;
    emit_instr "end"
  | Ast.Let (pat, value, body) ->
    (match pat.Ast.pnode with
     | Ast.P_var name when Hashtbl.mem inner_lifts_wasm name ->
       (* Phase 26.3: inner Let-bound Fun lifted to top-level. The Fun
          value has been pushed up; just emit the body, which will dispatch
          via App-Var to the lifted name. *)
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body
     | Ast.P_var name when saved_top && Hashtbl.mem top_globals_wasm name ->
       (* Phase 36 (DEFERRED §1.18 fix): file-scope global. Assign at
          source-order position so subsequent reads (via Var emit which
          does `global.get $name`) see the updated value.

          Gated on saved_top so a nested `let x = v in …` inside a fn
          body that happens to share a name with a top-level global
          does NOT overwrite the global — it becomes a plain local
          shadowing instead. *)
       emit_expr value;
       emit_instr (Printf.sprintf "global.set $%s" name);
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body
     | Ast.P_var name ->
       let slot = fresh_local () in
       emit_expr value;
       emit_instr (Printf.sprintf "local.set %d" slot);
       let prev = !locals in
       locals := (name, slot) :: prev;
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body;
       locals := prev
     | Ast.P_wild | Ast.P_unit ->
       (* Phase 22.1: evaluate RHS for side effects, drop, then body. *)
       emit_expr value;
       emit_instr "drop";
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body
     | Ast.P_tuple ps ->
       (* Phase 22.1: `let (a, b, ...) = E in B` — Wasm tuples are flat
          memory blocks of i32 cells, so emit a tuple-ptr local then
          `i32.load offset=N*4` per index. *)
       let tup_slot = fresh_local () in
       emit_expr value;
       emit_instr (Printf.sprintf "local.set %d" tup_slot);
       let value_ty =
         match value.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit
       in
       let elem_tys = match value_ty with
         | Ast.TyTuple ts -> ts
         | _ ->
           raise (Codegen_error (pat.Ast.ploc,
             "let-tuple pattern requires a tuple-typed RHS"))
       in
       if List.length ps <> List.length elem_tys then
         raise (Codegen_error (pat.Ast.ploc,
           "let-tuple arity mismatch"));
       let prev = !locals in
       let new_bindings = ref [] in
       List.iteri (fun i p ->
         match p.Ast.pnode with
         | Ast.P_var n ->
           let slot = fresh_local () in
           emit_instr (Printf.sprintf "local.get %d" tup_slot);
           emit_instr "i32.wrap_i64";
           emit_instr (Printf.sprintf "i64.load offset=%d" (i * 8));
           emit_instr (Printf.sprintf "local.set %d" slot);
           new_bindings := (n, slot) :: !new_bindings
         | Ast.P_wild -> ()
         | _ ->
           raise (Codegen_error (p.Ast.ploc,
             "nested let-tuple patterns not supported in Wasm codegen subset"))
       ) ps;
       locals := !new_bindings @ prev;
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body;
       locals := prev
     | _ ->
       (* General irrefutable pattern (constructor / record / as / …):
          desugar `let pat = value in body` to a single-arm
          `match value with | pat -> body`, reusing the full pattern
          compiler. Previously only P_var / P_tuple / P_wild were handled
          here (the interp accepted every pattern) — a backend parity gap
          surfaced by the mere-blog dogfood. Reinstate the Let-body tail /
          top-level flags so the synthesized match arm keeps tail position. *)
       wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr { e with Ast.node = Ast.Match (value, [(pat, None, body)]) })
  | Ast.Let_rec (bindings, body) ->
    (* Phase 26.3: inner let-rec lifting. If all bindings are registered
       in inner_lifts_wasm (= lifted to top level), just emit body. *)
    if List.for_all (fun (n, _) -> Hashtbl.mem inner_lifts_wasm n) bindings then
      (wasm_tail_pos := saved_tail;
       wasm_in_top_level_body := saved_top;
       emit_expr body)
    else
      unsupported e.Ast.loc "let rec inside an expression (only allowed at top level)"
  (* v0.1.172: a name the user bound is the user's, not the builtin's.
     Every arm below this one dispatches on a builtin name, and only 14 of
     the 139 asked whether the program had defined something of its own by
     that name — those guards had been added one incident at a time, after
     someone was bitten. This is the general form: if the head of the
     application spine is a name the program bound, the call goes straight
     to the ordinary call paths and never meets the builtin arms.

     Safe by construction: `app_head_user_bound_wasm` is false unless the
     program actually bound that name, so a program that shadows nothing
     reaches exactly the arms it reached before. *)
  | Ast.App _ when app_head_user_bound_wasm e -> emit_user_app saved_tail e
  | Ast.App ({ node = Ast.Var "show"; _ }, arg) ->
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "show: missing arg type"
    in
    let tag = ty_tag arg_ty in
    emit_expr arg;
    emit_instr (Printf.sprintf "call $show_%s" tag)
  | Ast.App ({ node = Ast.Var "to_json"; _ }, arg) ->
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "to_json: missing arg type"
    in
    emit_expr arg;
    emit_instr (Printf.sprintf "call $to_json_%s" (ty_tag arg_ty))
  (* v0.1.183: `of_json_like w s` is `of_json s` with the target type taken
     from the witness rather than from an annotation. Here that is the same
     type — the scheme is `'a -> str -> 'a`, so this node's type IS the
     witness's — and the only extra work is evaluating the witness for its
     effects and dropping it. *)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "of_json_opt_like"; _ }, w_e); _ }, arg) ->
    let inner =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon ("option", [inner]) when ty_is_concrete (Ast.walk inner) ->
           Ast.walk inner
         | _ -> unsupported e.Ast.loc "of_json_opt_like: cannot tell what to decode into")
      | None -> unsupported e.Ast.loc "of_json_opt_like: missing type info"
    in
    emit_expr w_e;
    emit_instr "drop";
    emit_expr arg;
    emit_instr (Printf.sprintf "call $of_json_opt_%s" (ty_tag inner))
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "of_json_like"; _ }, w_e); _ }, arg) ->
    let target_ty =
      match e.Ast.ty with
      | Some t when ty_is_concrete (Ast.walk t) -> Ast.walk t
      | _ ->
        unsupported e.Ast.loc
          "of_json_like: cannot tell what to decode into (the witness's type \
           is not concrete here)"
    in
    emit_expr w_e;
    emit_instr "drop";
    emit_expr arg;
    emit_instr (Printf.sprintf "call $of_json_%s" (ty_tag target_ty))
  | Ast.App ({ node = Ast.Var "of_json"; _ }, arg) ->
    let target_ty =
      match e.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "of_json: cannot infer target type"
    in
    emit_expr arg;
    emit_instr (Printf.sprintf "call $of_json_%s" (ty_tag target_ty))
  | Ast.App ({ node = Ast.Var "of_json_opt"; _ }, arg) ->
    let inner =
      match e.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon ("option", [inner]) -> Ast.walk inner
         | _ -> unsupported e.Ast.loc "of_json_opt: result type is not an option")
      | None -> unsupported e.Ast.loc "of_json_opt: cannot infer target type"
    in
    emit_expr arg;
    emit_instr (Printf.sprintf "call $of_json_opt_%s" (ty_tag inner))
  | Ast.App _ as outer_app when
    (let rec head_is_extern e =
       match e.Ast.node with
       | Ast.App (f, _) -> head_is_extern f
       | Ast.Var name -> Hashtbl.mem extern_fn_decls_wasm name
       | _ -> false
     in head_is_extern { Ast.node = outer_app; ty = e.Ast.ty; loc = e.Ast.loc }) ->
    (* Phase 32.6 (C1 FFI multi-arg Wasm): collect the curried App chain;
       push all args, then collapse into a single call $<name>. *)
    let rec collect e acc =
      match e.Ast.node with
      | Ast.App (f, a) -> collect f (a :: acc)
      | Ast.Var name -> name, acc
      | _ -> failwith "unreachable"
    in
    let name, args =
      collect { Ast.node = outer_app; ty = e.Ast.ty; loc = e.Ast.loc } []
    in
    (* v0.1.227: `tcp_set_timeout` had an in-module helper that did nothing and
       returned 0 — the same value the C version returns on success. A program that
       set a deadline was told it had one, and then blocked forever on the next
       read: worse than not having the capability, because a missing feature is a
       compile error and a silent no-op is a hang (measured at ten minutes before it
       was killed). Refused here, at the call, until WASI's poll is wired up. *)
    if name = "tcp_set_timeout" then
      unsupported e.Ast.loc
        "tcp_set_timeout has no Wasm lowering: WASI's sockets have no receive \
         deadline here, and this used to compile to a no-op that reported success \
         and left the next read blocking forever. A program that needs a bounded \
         wait needs the native backend";
    let rec result_ty t =
      match Ast.walk t with
      | Ast.TyArrow (_, r) -> result_ty r
      | t -> t
    in
    let decl_ty = Hashtbl.find extern_fn_decls_wasm name in
    let ret_ty = result_ty decl_ty in
    (* Arity from the declaration, not from the call site: an extern
       applied to fewer arguments is a value, not a call. *)
    let rec arg_types t =
      match Ast.walk t with
      | Ast.TyArrow (a, b) -> a :: arg_types b
      | _ -> []
    in
    let declared = arg_types decl_ty in
    let given = List.length args in
    if given < List.length declared then begin
      (* Drop the arguments already supplied and close over the rest. *)
      let rec drop n xs = if n <= 0 then xs else match xs with
        | [] -> [] | _ :: t -> drop (n - 1) t in
      let missing = drop given declared in
      emit_expr
        (eta_wrap_partial_extern
           { Ast.node = outer_app; ty = e.Ast.ty; loc = e.Ast.loc }
           missing ret_ty e.Ast.loc)
    end else begin
      List.iter (fun a ->
        match a.Ast.node with
        | Ast.Unit_lit -> ()
        | _ -> emit_expr a)
        args;
      emit_instr (Printf.sprintf "call $%s" name);
      (match ret_ty with
       | Ast.TyUnit -> emit_instr "i64.const 0"
       | _ -> ())
    end
  | Ast.App ({ node = Ast.Var "print"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $puts";
    emit_instr "i64.const 0"  (* unit *)
  (* print_int / print_bool: `print (str_of_int x)` already works here, so
     these are a rewrite rather than new host imports. They used to be refused
     as "no Wasm lowering", which left a documented builtin working only in the
     interpreter. *)
  | Ast.App ({ node = Ast.Var "print_int"; _ }, arg) ->
    emit_expr { arg with Ast.node =
                  Ast.App ({ arg with Ast.node = Ast.Var "str_of_int";
                                      Ast.ty = None }, arg);
                         Ast.ty = Some Ast.TyStr };
    emit_instr "call $puts";
    emit_instr "i64.const 0"
  | Ast.App ({ node = Ast.Var "print_bool"; _ }, arg) ->
    let str b = { arg with Ast.node = Ast.Str_lit b; Ast.ty = Some Ast.TyStr } in
    emit_expr { arg with Ast.node = Ast.If (arg, str "true", str "false");
                         Ast.ty = Some Ast.TyStr };
    emit_instr "call $puts";
    emit_instr "i64.const 0"
  | Ast.App ({ node = Ast.Var "print_no_nl"; _ }, arg)
    when not (user_shadows_wasm "print_no_nl") ->
    print_no_nl_used := true;
    emit_expr arg;
    emit_instr "call $__lang_print_no_nl";
    emit_instr "i64.const 0"  (* unit *)
  (* print_bytes: hand the host the data pointer and the length. A `bytes` is
     [i32 len][data...], so the data starts four bytes in. *)
  | Ast.App ({ node = Ast.Var "print_bytes"; _ }, arg)
    when not (user_shadows_wasm "print_bytes") ->
    bytes_used := true;
    print_bytes_used := true;
    emit_expr arg;
    emit_instr "call $__lang_print_bytes";
    emit_instr "i64.const 0"  (* unit *)
  (* Q-012: spawn a `unit -> unit` closure on a Wasm worker. The closure
     value is an i32 pointer to its { env_offset, fn_idx } record in the
     (shared) linear memory; the host reads it and runs the closure on a
     worker instance that shares the same module + memory. Returns the
     thread id (i32).

     2048-dogfood P2 (port of codegen_c's mk-P2 `join` fix, dd17b8a): only
     treat these names as the concurrency builtins when the program hasn't
     rebound them — a user `let spawn = ...` (e.g. a game's tile spawner)
     must fall through to ordinary application, or the module silently
     turns into a threaded one (shared-memory import + $mere_spawn). *)
  | Ast.App ({ node = Ast.Var "spawn"; _ }, clos)
    when not (List.mem_assoc "spawn" !locals
              || Hashtbl.mem toplevel_fn_names "spawn"
              || Hashtbl.mem inner_lifts_wasm "spawn") ->
    uses_threads := true;
    emit_expr clos;
    emit_instr "call $mere_spawn"
  | Ast.App ({ node = Ast.Var "join"; _ }, h)
    when not (List.mem_assoc "join" !locals
              || Hashtbl.mem toplevel_fn_names "join"
              || Hashtbl.mem inner_lifts_wasm "join") ->
    uses_threads := true;
    emit_expr h;
    emit_instr "call $mere_join"  (* returns i32 0 = unit *)
  (* Q-012: channels as host imports over the shared memory (the host does
     the atomic mutex/cond via JS Atomics on the shared buffer). Elements are
     i32 (Mere's Wasm value width). *)
  | Ast.App ({ node = Ast.Var "channel_new"; _ }, arg)
    when not (List.mem_assoc "channel_new" !locals
              || Hashtbl.mem toplevel_fn_names "channel_new"
              || Hashtbl.mem inner_lifts_wasm "channel_new") ->
    uses_threads := true;
    emit_expr arg;                (* unit; consumed by the import *)
    emit_instr "call $mere_channel_new"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "channel_send"; _ }, ch_e); _ }, v_e)
    when not (List.mem_assoc "channel_send" !locals
              || Hashtbl.mem toplevel_fn_names "channel_send"
              || Hashtbl.mem inner_lifts_wasm "channel_send") ->
    uses_threads := true;
    emit_expr ch_e;
    emit_expr v_e;
    emit_instr "call $mere_channel_send"  (* returns i32 0 = unit *)
  | Ast.App ({ node = Ast.Var "channel_recv"; _ }, ch_e)
    when not (List.mem_assoc "channel_recv" !locals
              || Hashtbl.mem toplevel_fn_names "channel_recv"
              || Hashtbl.mem inner_lifts_wasm "channel_recv") ->
    uses_threads := true;
    emit_expr ch_e;
    emit_instr "call $mere_channel_recv"
  (* v0.1.153: positioned file I/O. The handle is an opaque host index (the
     host owns the descriptor), and bytes cross in the mere_bytes layout the
     read_file_bytes path already uses, so no per-byte host crossing and no
     Vec layout knowledge on the host side.

     "Wasm has no filesystem" was true of the browser main thread only. A
     Worker gets synchronous positioned read / write / flush from an OPFS
     access handle, which is exactly this contract — so a store written
     against these builtins compiles to every backend unchanged. *)
  (* file_size belongs with the positioned group: a log-structured store
     needs the end of the file to append to, and reading the whole thing
     just to measure it is what the group exists to avoid. *)
  | Ast.App ({ node = Ast.Var "file_size"; _ }, path_e)
    when not (List.mem_assoc "file_size" !locals
              || Hashtbl.mem toplevel_fn_names "file_size"
              || Hashtbl.mem inner_lifts_wasm "file_size") ->
    file_pio_used := true;
    emit_expr path_e;
    emit_instr "call $file_size"
  | Ast.App ({ node = Ast.Var "file_openrw"; _ }, path_e)
    when not (List.mem_assoc "file_openrw" !locals
              || Hashtbl.mem toplevel_fn_names "file_openrw"
              || Hashtbl.mem inner_lifts_wasm "file_openrw") ->
    file_pio_used := true;
    emit_expr path_e;
    emit_instr "call $file_openrw"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "file_pread"; _ },
                                                ch_e); _ }, off_e); _ }, len_e)
    when not (List.mem_assoc "file_pread" !locals
              || Hashtbl.mem toplevel_fn_names "file_pread"
              || Hashtbl.mem inner_lifts_wasm "file_pread") ->
    file_pio_used := true; bytes_used := true; bytes_vec_used := true; vec_used := true;
    emit_expr ch_e;
    emit_expr off_e;
    emit_expr len_e;
    emit_instr "call $file_pread";
    emit_instr "call $__lang_vec_of_bytes"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "file_pwrite"; _ },
                                                ch_e); _ }, off_e); _ }, vec_e)
    when not (List.mem_assoc "file_pwrite" !locals
              || Hashtbl.mem toplevel_fn_names "file_pwrite"
              || Hashtbl.mem inner_lifts_wasm "file_pwrite") ->
    file_pio_used := true; bytes_used := true; bytes_vec_used := true; vec_used := true;
    emit_expr ch_e;
    emit_expr off_e;
    emit_expr vec_e;
    emit_instr "call $__lang_bytes_of_vec";
    emit_instr "call $file_pwrite"
  | Ast.App ({ node = Ast.App ({ node = Ast.App
                 ({ node = Ast.Var "file_pwrite_bytes"; _ }, ch_e); _ }, off_e); _ },
             b_e)
    when not (List.mem_assoc "file_pwrite_bytes" !locals
              || Hashtbl.mem toplevel_fn_names "file_pwrite_bytes"
              || Hashtbl.mem inner_lifts_wasm "file_pwrite_bytes") ->
    (* v0.1.222: the host import already takes a bytes pointer — the vec version
       just converts first. So this is the same call with nothing in between. *)
    file_pio_used := true; bytes_used := true;
    emit_expr ch_e;
    emit_expr off_e;
    emit_expr b_e;
    emit_instr "call $file_pwrite"
  | Ast.App ({ node = Ast.Var ("file_fsync" | "file_close" as fio); _ }, ch_e)
    when not (List.mem_assoc fio !locals
              || Hashtbl.mem toplevel_fn_names fio
              || Hashtbl.mem inner_lifts_wasm fio) ->
    file_pio_used := true;
    emit_expr ch_e;
    emit_instr (Printf.sprintf "call $%s" fio)
  | Ast.App ({ node = Ast.Var ("file_open" | "file_read_line" as fio); _ }, _)
    when not (List.mem_assoc fio !locals
              || Hashtbl.mem toplevel_fn_names fio
              || Hashtbl.mem inner_lifts_wasm fio) ->
    (* v0.1.59: streaming line input stays interp + C — it needs a decoder
       and a buffered cursor the host would have to own per handle. *)
    unsupported e.Ast.loc
      (fio ^ " is unsupported in Wasm codegen (v0.1.59 scope = interp + C)")
  | Ast.App ({ node = Ast.Var ("channel_close" | "channel_recv_opt" as cc); _ }, _)
    when not (List.mem_assoc cc !locals
              || Hashtbl.mem toplevel_fn_names cc
              || Hashtbl.mem inner_lifts_wasm cc) ->
    (* v0.1.47: graceful-shutdown primitives are interp + C only. *)
    unsupported e.Ast.loc
      "channel_close / channel_recv_opt are unsupported in Wasm codegen \
       (v0.1.47 scope = interp + C)"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "channel_recv_timeout"; _ }, _); _ }, _)
    when not (List.mem_assoc "channel_recv_timeout" !locals
              || Hashtbl.mem toplevel_fn_names "channel_recv_timeout"
              || Hashtbl.mem inner_lifts_wasm "channel_recv_timeout") ->
    (* v0.1.48 *)
    unsupported e.Ast.loc
      "channel_recv_timeout is unsupported in Wasm codegen \
       (v0.1.48 scope = interp + C)"
  | Ast.App ({ node = Ast.Var "mk_logger"; _ }, arg) ->
    (* Phase 16.3 / DEFERRED §1.5: build a Logger record in linear
       memory (3 closure ptrs, each pointing to an 8-byte { env=prefix,
       fn_idx } block). *)
    logger_used := true;
    emit_expr arg;
    emit_instr "call $__mere_mk_logger"
  | Ast.App ({ node = Ast.Var "mk_metrics"; _ }, arg) ->
    (* Phase 16.3: mk_metrics () — unit arg is consumed (still pushed
       so stack stays balanced) and `$__mere_mk_metrics` returns the
       Metrics record. *)
    metrics_used := true;
    emit_expr arg;
    emit_instr "drop";
    emit_instr "call $__mere_mk_metrics"
  | Ast.App ({ node = Ast.Var "str_len"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_strlen"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_index_of"; _ }, h_e); _ }, n_e) ->
    (* Phase 19.1.1: str_index_of h n — curried. *)
    emit_expr h_e;
    emit_expr n_e;
    emit_instr "call $__lang_str_index_of"
  (* Phase 36: str_trim / str_starts_with / str_replace — runtime helpers
     emitted unconditionally as part of the str runtime block. *)
  | Ast.App ({ node = Ast.Var "str_trim"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_str_trim"
  | Ast.App ({ node = Ast.Var "utf8_len"; _ }, arg) ->
    (* v0.1.38 (Unicode): codepoint count. *)
    str_split_used := true;   (* the helper lives in the list_str blob *)
    emit_expr arg;
    emit_instr "call $__lang_utf8_len"
  | Ast.App ({ node = Ast.Var "utf8_chars"; _ }, arg) ->
    str_split_used := true;   (* pulls in the list_str cell builders *)
    emit_expr arg;
    emit_instr "call $__lang_utf8_chars"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_starts_with"; _ }, s_e); _ }, p_e) ->
    emit_expr s_e;
    emit_expr p_e;
    emit_instr "call $__lang_str_starts_with"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "str_replace"; _ }, s_e); _ }, old_e); _ }, new_e) ->
    emit_expr s_e;
    emit_expr old_e;
    emit_expr new_e;
    emit_instr "call $__lang_str_replace"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_ends_with"; _ }, s_e); _ }, p_e) ->
    emit_expr s_e;
    emit_expr p_e;
    emit_instr "call $__lang_str_ends_with"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_contains"; _ }, h_e); _ }, n_e) ->
    (* Phase 36: str_contains h n — implement via str_index_of != -1 *)
    emit_expr h_e;
    emit_expr n_e;
    emit_instr "call $__lang_str_index_of";
    emit_instr "i64.const -1";
    emit_instr "i64.ne";
    emit_instr "i64.extend_i32_u"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_repeat"; _ }, s_e); _ }, n_e) ->
    emit_expr s_e;
    emit_expr n_e;
    emit_instr "call $__lang_str_repeat"
  (* v0.1.42 (bitwise): direct i32 ops. bit_shr is the arithmetic shift
     (i32.shr_s); wasm masks shift counts mod 32 by spec. *)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "bit_and"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e; emit_expr b_e; emit_instr "i64.and"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "bit_or"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e; emit_expr b_e; emit_instr "i64.or"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "bit_xor"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e; emit_expr b_e; emit_instr "i64.xor"
  | Ast.App ({ node = Ast.Var "bit_not"; _ }, a_e) ->
    emit_expr a_e; emit_instr "i64.const -1"; emit_instr "i64.xor"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "bit_shl"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e; emit_expr b_e; emit_instr "i64.shl"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "bit_shr"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e; emit_expr b_e; emit_instr "i64.shr_s"
  | Ast.App ({ node = Ast.Var "str_rev"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_str_rev"
  | Ast.App ({ node = Ast.Var "not"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i64.eqz";
    emit_instr "i64.extend_i32_u"
  | Ast.App ({ node = Ast.Var "abs"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_abs"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "min"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $__lang_min"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "max"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $__lang_max"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "clamp"; _ }, lo_e); _ }, hi_e); _ }, x_e) ->
    emit_expr lo_e;
    emit_expr hi_e;
    emit_expr x_e;
    emit_instr "call $__lang_clamp"
  | Ast.App ({ node = Ast.Var "chr"; _ }, arg) ->
    char_table_used := true;
    emit_expr arg;
    emit_instr "call $__lang_char_at_chr"
  | Ast.App ({ node = Ast.Var "ord"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i32.wrap_i64";
    emit_instr "i32.load8_u";
    emit_instr "i64.extend_i32_u"
  | Ast.App ({ node = Ast.Var "to_upper"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_to_upper"
  | Ast.App ({ node = Ast.Var "to_lower"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_to_lower"
  | Ast.App ({ node = Ast.Var "even"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i64.const 2";
    emit_instr "i64.rem_s";
    emit_instr "i64.eqz";
    emit_instr "i64.extend_i32_u"
  | Ast.App ({ node = Ast.Var "odd"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i64.const 2";
    emit_instr "i64.rem_s";
    emit_instr "i64.const 0";
    emit_instr "i64.ne";
    emit_instr "i64.extend_i32_u"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "gcd"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $__lang_gcd"
  | Ast.App ({ node = Ast.Var "bool_of_str"; _ }, arg) ->
    emit_expr arg;
    emit_instr "call $__lang_bool_of_str"
  (* Phase 26.1: fail / char / substring / int_of_str / str_of_int /
     str_unescape — Wasm version of LLVM Phase 25.1 / 25.4. *)
  | Ast.App ({ node = Ast.Var "fail"; _ }, arg) ->
    fail_used := true;
    emit_expr arg;
    emit_instr "call $__lang_fail"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "char_at"; _ }, s_e); _ }, i_e) ->
    char_table_used := true;
    emit_expr s_e;
    emit_expr i_e;
    emit_instr "call $__lang_char_at"
  (* Phase 30.0 (DEFERRED §1.12 fix): respect user-defined shadow *)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_compare"; _ }, a_e); _ }, b_e) ->
    (* Phase 31.0: str_compare a b — across all 3 backends, return the
       sign-normalized -1/0/1 that matches interp. *)
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $__lang_str_compare"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_eq"; _ }, a_e); _ }, b_e) ->
    (* Phase 54.17 (OCaml side): str_eq a b — explicit content-equality
       for two runtime str values. Uses the same $__lang_streq helper
       as the polymorphic ==/!= path. *)
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $__lang_streq"
  (* Phase 34.3: float arithmetic + comparison + unary + conversions.
     Values are i32 ptr (f64 in heap). Each op is load → op → alloc + store. *)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var fname; _ }, a_e); _ }, b_e)
    when fname = "f_add" || fname = "f_sub" || fname = "f_mul" || fname = "f_div" ->
    let op = match fname with
      | "f_add" -> "f64.add" | "f_sub" -> "f64.sub"
      | "f_mul" -> "f64.mul" | "f_div" -> "f64.div" | _ -> "f64.add"
    in
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_expr b_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr op;
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.App ({ node = Ast.Var fname; _ }, a_e); _ }, b_e)
    when fname = "f_lt" || fname = "f_le" || fname = "f_gt" || fname = "f_ge" ->
    let op = match fname with
      | "f_lt" -> "f64.lt" | "f_le" -> "f64.le"
      | "f_gt" -> "f64.gt" | "f_ge" -> "f64.ge" | _ -> "f64.lt"
    in
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_expr b_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr op;  (* f64.lt etc. return i32 (bool) *)
    emit_instr "i64.extend_i32_u"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var fname; _ }, a_e); _ }, b_e)
    when fname = "f_min" || fname = "f_max" ->
    let op = if fname = "f_min" then "f64.min" else "f64.max" in
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_expr b_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr op;
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "f_neg"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr "f64.neg";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "f_abs"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr "f64.abs";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "float_of_int"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "f64.convert_i64_s";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "int_of_float"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr "i64.trunc_f64_s"
  | Ast.App ({ node = Ast.Var "str_of_float"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr "call $__lang_str_of_float";  (* env import, returns i32 ptr to str *)
    emit_instr "i64.extend_i32_u"
  | Ast.App ({ node = Ast.Var "float_of_str"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "i32.wrap_i64";               (* env import takes an i32 ptr *)
    emit_instr "call $__lang_float_of_str";  (* env import, f64 *)
    emit_float_alloc_from_f64_on_stack ()
  (* Phase 34.4: libm functions — only sqrt is a Wasm intrinsic; others are host imports *)
  | Ast.App ({ node = Ast.Var "sqrt"; _ }, a_e) ->
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr "f64.sqrt";
    emit_float_alloc_from_f64_on_stack ()
  (* floor / ceil / round: refused rather than emitted.
     f64.floor and f64.ceil are instructions and looked like a five-line addition,
     but putting the names in the eta-expansion list above sent that machinery into
     an infinite expansion — a bare `floor` call never finished emitting. `round`
     is worse than missing: f64.nearest rounds half to even where C and the
     interpreter round half away from zero, and doing it properly needs a scratch
     f64 local, which this backend declares per function.
     A backend that says "no" is one a caller can work around; one that quietly
     rounds differently, or that hangs, is not. The C and LLVM backends have all
     three; scripts/host_matrix.sh records the gap. *)
  | Ast.App ({ node = Ast.Var fname; _ }, _)
    when fname = "floor" || fname = "ceil" || fname = "round" ->
    unsupported e.loc
      (fname ^ " is not supported in the wasm codegen subset")
  | Ast.App ({ node = Ast.Var fname; _ }, a_e)
    when fname = "sin" || fname = "cos" || fname = "tan" ->
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr (Printf.sprintf "call $__lang_%s" fname);
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "f_pow"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_expr b_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr "call $__lang_f_pow";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "atan2"; _ }, a_e); _ }, b_e) ->
    emit_expr a_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_expr b_e;
    emit_instr "i32.wrap_i64";
    emit_instr "f64.load offset=0 align=8";
    emit_instr "call $__lang_atan2";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "is_digit"; _ }, arg)
    when not (Hashtbl.mem toplevel_fn_names "is_digit") ->
    emit_expr arg;
    emit_instr "call $__lang_is_digit"
  | Ast.App ({ node = Ast.Var "is_alpha"; _ }, arg)
    when not (Hashtbl.mem toplevel_fn_names "is_alpha") ->
    emit_expr arg;
    emit_instr "call $__lang_is_alpha"
  | Ast.App ({ node = Ast.Var "is_space"; _ }, arg)
    when not (Hashtbl.mem toplevel_fn_names "is_space") ->
    emit_expr arg;
    emit_instr "call $__lang_is_space"
  (* bytes builtins. *)
  | Ast.App ({ node = Ast.Var "bytes_of_hex"; _ }, arg) ->
    bytes_used := true; emit_expr arg; emit_instr "call $__lang_bytes_of_hex"
  | Ast.App ({ node = Ast.Var "hex_of_bytes"; _ }, arg) ->
    bytes_used := true; emit_expr arg; emit_instr "call $__lang_hex_of_bytes"
  | Ast.App ({ node = Ast.Var "bytes_of_str"; _ }, arg) ->
    bytes_used := true; emit_expr arg; emit_instr "call $__lang_bytes_of_str"
  | Ast.App ({ node = Ast.Var "str_of_bytes"; _ }, arg) ->
    bytes_used := true; emit_expr arg; emit_instr "call $__lang_str_of_bytes"
  | Ast.App ({ node = Ast.Var "bytes_len"; _ }, arg) ->
    bytes_used := true; emit_expr arg;
    emit_instr "i32.wrap_i64"; emit_instr "i32.load"; emit_instr "i64.extend_i32_u"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "bytes_get"; _ }, b_e); _ }, i_e) ->
    bytes_used := true; emit_expr b_e; emit_expr i_e; emit_instr "call $__lang_bytes_get"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "bytes_concat"; _ }, a_e); _ }, b_e) ->
    bytes_used := true; emit_expr a_e; emit_expr b_e; emit_instr "call $__lang_bytes_concat"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "bytes_slice"; _ }, b_e); _ }, start_e); _ }, len_e) ->
    bytes_used := true; emit_expr b_e; emit_expr start_e; emit_expr len_e; emit_instr "call $__lang_bytes_slice"
  | Ast.App ({ node = Ast.Var "bytes_of_vec"; _ }, arg) ->
    bytes_used := true; bytes_vec_used := true; vec_used := true;
    emit_expr arg; emit_instr "call $__lang_bytes_of_vec"
  | Ast.App ({ node = Ast.Var "vec_of_bytes"; _ }, arg) ->
    bytes_used := true; bytes_vec_used := true; vec_used := true;
    emit_expr arg; emit_instr "call $__lang_vec_of_bytes"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "substring"; _ }, s_e); _ }, start_e); _ }, end_e) ->
    substring_used := true;
    emit_expr s_e;
    emit_expr start_e;
    emit_expr end_e;
    emit_instr "call $__lang_substring"
  | Ast.App ({ node = Ast.Var "int_of_str"; _ }, arg) ->
    (* v0.1.60: the helper now validates strict decimal — optional
       whitespace, optional sign, digits — and fails on anything else,
       matching the interpreter instead of atoi's silent 0. The message
       is interned here and passed in. *)
    int_of_str_used := true;
    fail_used := true;
    let msg_off = intern_show_str "int_of_str: not a valid int" in
    emit_expr arg;
    emit_instr (Printf.sprintf "i64.const %d" msg_off);
    emit_instr "call $__lang_int_of_str"
  | Ast.App ({ node = Ast.Var "str_of_int"; _ }, arg) ->
    (* str_of_int is an alias for show_int. *)
    emit_expr arg;
    emit_instr "call $show_int"
  | Ast.App ({ node = Ast.Var "str_unescape"; _ }, arg) ->
    str_unescape_used := true;
    emit_expr arg;
    emit_instr "call $__lang_str_unescape"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_split"; _ }, s_e); _ }, delim_e) ->
    (* Phase 26.5: str_split — returns list_str (boxed Cons cells). *)
    str_split_used := true;
    emit_expr s_e;
    emit_expr delim_e;
    emit_instr "call $__lang_str_split"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_join"; _ }, sep_e); _ }, xs_e) ->
    (* Phase 26.5: str_join — concatenate list_str separated by sep. *)
    str_join_used := true;
    emit_expr sep_e;
    emit_expr xs_e;
    emit_instr "call $__lang_str_join"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "str_count"; _ }, s_e); _ }, n_e) ->
    str_count_used := true;
    emit_expr s_e;
    emit_expr n_e;
    emit_instr "call $__lang_str_count"
  (* Wasm host stubs (browser/worker have no filesystem, argv or a real process
     exit). Constant stubs for the builtins — no host import needed. Guarded
     against a user rebinding the name, like the concurrency builtins above.
     `getenv` is a user `extern` and resolves through the host import object. *)
  | Ast.App ({ node = Ast.Var "file_exists"; _ }, path_e)
    when not (user_shadows_wasm "file_exists") ->
    (* no filesystem — File.exist? is always false. *)
    emit_expr path_e;
    emit_instr "drop";
    emit_instr "i64.const 0"
  | Ast.App ({ node = Ast.Var "random_int"; _ }, n_e)
    when not (user_shadows_wasm "random_int") ->
    (* no RNG wired on the Wasm host yet — deterministic 0 (refine to a host
       Math.random import later). *)
    emit_expr n_e;
    emit_instr "drop";
    emit_instr "i64.const 0"
  | Ast.App ({ node = Ast.Var "time"; _ }, _)
    when not (user_shadows_wasm "time") ->
    (* wall-clock epoch seconds as f64 via a host import (Date.now()/1000 in
       a browser). The unit arg is inert; the raw f64 is boxed like any float.
       Phase 2: in a command component, $__lang_time is backed by wasi
       clock_time_get (realtime) instead of the f64.const 0 stub. *)
    if !wasm_component_command then wasm_time_used := true;
    emit_instr "call $__lang_time";
    emit_float_alloc_from_f64_on_stack ()
  | Ast.App ({ node = Ast.Var "run"; _ }, cmd_e)
    when not (user_shadows_wasm "run") ->
    (* no subprocess on a browser/worker host — commands "fail" (nonzero). *)
    emit_expr cmd_e;
    emit_instr "drop";
    emit_instr "i64.const 127"
  | Ast.App ({ node = Ast.Var "args"; _ }, _)
    when not (user_shadows_wasm "args") ->
    if !wasm_component_command then begin
      (* Phase 2: a command component has real argv via the WASI adapter.
         $__lang_args builds a str list (argv[1..], skipping the program name
         to match the C backend) from wasi args_get. *)
      wasm_args_used := true;
      emit_instr "call $__lang_args"
    end else begin
      (* v0.1.159: build the list from the host's arg_count / arg_get. A
         browser host reports 0 and the loop yields Nil, which is what the
         old hardcoded empty list got right; under Node it now returns the
         arguments the runner was actually given, matching the C backend
         instead of silently disagreeing with it. *)
      wasm_args_host_used := true;
      emit_instr "call $__lang_args_host"
    end
  | Ast.App ({ node = Ast.Var "env_var"; _ }, name_e)
    when not (user_shadows_wasm "env_var") ->
    if !wasm_component_command then begin
      (* Phase 2: env_var name -> str option, via wasi environ_get. Returns
         Some value if an entry "name=value" exists, else None. *)
      wasm_env_used := true;
      emit_expr name_e;
      emit_instr "i32.wrap_i64";
      emit_instr "call $__lang_env_var"
    end else begin
      (* no environ on a browser/worker host — env_var is always None. *)
      emit_expr name_e;
      emit_instr "drop";
      emit_expr { e with Ast.node = Ast.Constr ("None", None) }
    end
  | Ast.App ({ node = Ast.Var "print_err"; _ }, arg)
    when not (user_shadows_wasm "print_err") ->
    (* stderr — route to the same host sink as print. *)
    emit_expr arg;
    emit_instr "call $puts";
    emit_instr "i64.const 0"
  | Ast.App ({ node = Ast.Var "exit"; _ }, code_e)
    when not (user_shadows_wasm "exit") ->
    (* no process to exit — evaluate the code for effect, then trap. *)
    emit_expr code_e;
    emit_instr "drop";
    emit_instr "unreachable"
  | Ast.App ({ node = Ast.Var "read_file"; _ }, path_e) ->
    (* Phase 26.5: WASI-lite — read_file delegated to host import. *)
    file_io_used := true;
    emit_expr path_e;
    emit_instr "call $__lang_read_file"
  | Ast.App ({ node = Ast.Var "read_stdin"; _ }, arg)
    when not (user_shadows_wasm "read_stdin") ->
    if !wasm_component_command then begin
      (* Phase 2: a command component reads all of stdin via wasi fd_read
         ($__lang_read_stdin returns a NUL-terminated Mere str). *)
      wasm_stdin_used := true;
      emit_expr arg;
      emit_instr "drop";
      emit_instr "call $__lang_read_stdin"
    end else begin
      (* A browser/worker host has no stdin — read_stdin is the empty string.
         (The unit arg is inert; evaluate it for effect, then drop.) *)
      emit_expr arg;
      emit_instr "drop";
      emit_instr (Printf.sprintf "i64.const %d" (intern_show_str ""))
    end
  | Ast.App ({ node = Ast.Var "read_line"; _ }, arg)
    when not (user_shadows_wasm "read_line") ->
    (* No stdin on a browser host — one line reads as the empty string. *)
    emit_expr arg;
    emit_instr "drop";
    emit_instr (Printf.sprintf "i64.const %d" (intern_show_str ""))
  | Ast.App ({ node = Ast.Var "read_file_bytes"; _ }, path_e) ->
    (* host returns a length-prefixed byte buffer (mere_bytes layout); convert
       it to a Vec[int] with the bytes bridge (all in-Wasm, no per-byte host
       crossing). *)
    file_bytes_io_used := true; bytes_used := true; bytes_vec_used := true; vec_used := true;
    emit_expr path_e;
    emit_instr "call $read_file_bytes";
    emit_instr "call $__lang_vec_of_bytes"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "write_file_bytes"; _ }, path_e); _ }, vec_e) ->
    file_bytes_io_used := true; bytes_used := true; bytes_vec_used := true; vec_used := true;
    emit_expr path_e;
    emit_expr vec_e;
    emit_instr "call $__lang_bytes_of_vec";  (* vec -> bytesPtr (top of stack) *)
    emit_instr "call $write_file_bytes"
  | Ast.App ({ node = Ast.Var "list_dir"; _ }, _path_e) ->
    unsupported e.Ast.loc
      "list_dir is unsupported in Wasm codegen (Phase 44 MVP scope = interp + C only)"
  | Ast.App ({ node = Ast.Var "mkdir_p"; _ }, _path_e) ->
    unsupported e.Ast.loc
      "mkdir_p is unsupported in Wasm codegen (Phase 44 MVP scope = interp + C only)"
  | Ast.App ({ node = Ast.Var "file_mtime"; _ }, _) ->
    unsupported e.Ast.loc
      "file_mtime is unsupported in Wasm codegen (Phase 44.6 MVP = interp + C only)"
  | Ast.App ({ node = Ast.Var "sleep_ms"; _ }, _) ->
    unsupported e.Ast.loc
      "sleep_ms is unsupported in Wasm codegen (Phase 44.6 MVP = interp + C only)"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "write_file"; _ }, path_e); _ }, content_e) ->
    file_io_used := true;
    emit_expr path_e;
    emit_expr content_e;
    emit_instr "call $__lang_write_file"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "try_or"; _ }, fn_e); _ }, default_e) ->
    (* Phase 26.2: try_or fn default — Wasm version. Since there's no
       setjmp/longjmp, switch fail to a flag-based non-trapping mode and
       manage the try_or scope with a global active counter. After calling
       the inner closure, check the flag; if set, return default. *)
    fail_used := true;
    (* Save active counter (depth) — using a fresh local. *)
    let saved_active = fresh_local_i32 () in
    let result_slot = fresh_local () in
    emit_instr "global.get $__lang_fail_active";
    emit_instr (Printf.sprintf "local.set %d" saved_active);
    emit_instr "i32.const 1";
    emit_instr "global.set $__lang_fail_active";
    emit_instr "i32.const 0";
    emit_instr "global.set $__lang_fail_flag";
    (* Call fn () via closure indirect — fn_e is a closure value. *)
    let cl_slot = fresh_local () in
    emit_expr fn_e;
    emit_instr (Printf.sprintf "local.set %d" cl_slot);
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i32.wrap_i64";
    emit_instr "i32.load offset=0";   (* env (i32 record field) *)
    emit_instr "i64.extend_i32_u";    (* … as an i64 value *)
    emit_instr "i64.const 0";          (* unit arg *)
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i32.wrap_i64";
    emit_instr "i32.load offset=4";   (* fn_idx (table index stays i32) *)
    emit_instr "call_indirect (type $cl)";
    emit_instr (Printf.sprintf "local.set %d" result_slot);
    (* Restore active counter. *)
    emit_instr (Printf.sprintf "local.get %d" saved_active);
    emit_instr "global.set $__lang_fail_active";
    (* If fail flag set, drop result + emit default; else use result. *)
    emit_instr "global.get $__lang_fail_flag";
    emit_instr "if (result i64)";
    emit_instr "i32.const 0";
    emit_instr "global.set $__lang_fail_flag";
    emit_expr default_e;
    emit_instr "else";
    emit_instr (Printf.sprintf "local.get %d" result_slot);
    emit_instr "end"
  | Ast.App ({ node = Ast.Var "vec_new"; _ }, _arg) ->
    (* Phase 15.4: vec_new () — ignore region (Wasm's bump is a single
       global), and since all elements are 4-byte i32 a single runtime
       suffices. arg is a unit literal so don't push it. *)
    vec_used := true;
    emit_instr "call $mere_vec_new"
  | Ast.App ({ node = Ast.Var "vec_len"; _ }, arg) ->
    vec_used := true;
    emit_expr arg;
    emit_instr "call $mere_vec_len"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_push"; _ }, vec_e); _ }, val_e) ->
    vec_used := true;
    emit_expr vec_e;
    emit_expr val_e;
    emit_instr "call $mere_vec_push"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_get"; _ }, vec_e); _ }, idx_e) ->
    vec_used := true;
    emit_expr vec_e;
    emit_expr idx_e;
    emit_instr "call $mere_vec_get"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_set"; _ }, vec_e); _ }, idx_e); _ }, val_e) ->
    (* Phase 15.5: vec_set v i x *)
    vec_used := true;
    emit_expr vec_e;
    emit_expr idx_e;
    emit_expr val_e;
    emit_instr "call $mere_vec_set"
  | Ast.App ({ node = Ast.Var "vec_reverse"; _ }, vec_e) ->
    (* Phase 19.3: vec_reverse v — in-place *)
    vec_used := true;
    emit_expr vec_e;
    emit_instr "call $mere_vec_reverse"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_concat"; _ }, a_e); _ }, b_e) ->
    (* Phase 19.3: vec_concat a b — new Vec *)
    vec_used := true;
    emit_expr a_e;
    emit_expr b_e;
    emit_instr "call $mere_vec_concat"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_sort"; _ }, vec_e); _ }, cmp_e) ->
    (* Phase 19.3: vec_sort v cmp — closure dispatch via call_indirect.
       In-place insertion sort with comparator returning int. *)
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr vec_e;
    emit_expr cmp_e;
    emit_instr "call $mere_vec_sort"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_iter"; _ }, vec_e); _ }, fn_e) ->
    (* Phase 15.5: vec_iter v f *)
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr vec_e;
    emit_expr fn_e;
    emit_instr "call $mere_vec_iter"
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_fold"; _ }, vec_e); _ }, acc_e); _ }, fn_e) ->
    (* Phase 15.5: vec_fold v acc f *)
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr vec_e;
    emit_expr acc_e;
    emit_expr fn_e;
    emit_instr "call $mere_vec_fold"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_map"; _ }, vec_e); _ }, fn_e) ->
    (* Phase 15.6: vec_map v f *)
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr vec_e;
    emit_expr fn_e;
    emit_instr "call $mere_vec_map"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "vec_filter"; _ }, vec_e); _ }, fn_e) ->
    (* Phase 15.6: vec_filter v f *)
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr vec_e;
    emit_expr fn_e;
    emit_instr "call $mere_vec_filter"
  | Ast.App ({ node = Ast.Var "owned_vec_new"; _ }, _arg) ->
    (* Phase 15.7: In Wasm, OwnedVec and Vec use the same bump runtime, so
       owned_vec_new = $mere_vec_new (alias). *)
    vec_used := true;
    emit_instr "call $mere_vec_new"
  | Ast.App ({ node = Ast.Var "owned_vec_len"; _ }, arg) ->
    vec_used := true;
    emit_expr arg;
    emit_instr "call $mere_vec_len"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "owned_vec_push"; _ }, vec_e); _ }, val_e) ->
    vec_used := true;
    emit_expr vec_e;
    emit_expr val_e;
    emit_instr "call $mere_vec_push"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "owned_vec_get"; _ }, vec_e); _ }, idx_e) ->
    vec_used := true;
    emit_expr vec_e;
    emit_expr idx_e;
    emit_instr "call $mere_vec_get"
  | Ast.App ({ node = Ast.Var "vec_to_owned"; _ }, vec_e) ->
    (* Phase 15.7: In Wasm the runtime representations of Vec and OwnedVec
       are the same, so just deep-copy with $mere_vec_clone. *)
    vec_used := true;
    emit_expr vec_e;
    emit_instr "call $mere_vec_clone"
  | Ast.App ({ node = Ast.Var "owned_vec_to_vec"; _ }, owned_e) ->
    vec_used := true;
    emit_expr owned_e;
    emit_instr "call $mere_vec_clone"
  | Ast.App ({ node = Ast.Var "len"; _ }, arg) ->
    (* Phase 15.11: len ad-hoc dispatch — route to the corresponding _len
       helper based on arg.ty. In Wasm all values are i32. *)
    let arg_ty =
      match arg.Ast.ty with
      | Some t -> Ast.walk t
      | None -> raise (Codegen_error (arg.Ast.loc, "len: missing arg type info"))
    in
    (match arg_ty with
     | Ast.TyCon ("Vec", _) | Ast.TyCon ("OwnedVec", _) ->
       vec_used := true;
       emit_expr arg;
       emit_instr "call $mere_vec_len"
     | Ast.TyCon ("StrBuf", _) ->
       strbuf_used := true;
       emit_expr arg;
       emit_instr "call $mere_strbuf_len"
     | Ast.TyCon ("Map", _) ->
       let k_tag = map_key_tag_of_wasm arg.Ast.ty arg.Ast.loc in
       (if k_tag = "int" then map_int_used := true else map_str_used := true);
       emit_expr arg;
       emit_instr (Printf.sprintf "call $mere_map_%s_len" k_tag)
     | Ast.TyStr ->
       emit_expr arg;
       emit_instr "call $__lang_strlen"
     | Ast.TyTuple ts ->
       (* Static arity. arg may be side-effectful, so drop it. *)
       emit_expr arg;
       emit_instr "drop";
       emit_instr (Printf.sprintf "i64.const %d" (List.length ts))
     | Ast.TyCon (n, _)
       when Hashtbl.mem Exhaustive.type_variants n
            && Hashtbl.mem variant_tags "Cons"
            && Hashtbl.mem variant_tags "Nil" ->
       (* Phase 15.12: `len` on `T list` — shared $mere_list_len. *)
       list_len_used := true;
       emit_expr arg;
       emit_instr "call $mere_list_len"
     | _ ->
       raise (Codegen_error (e.Ast.loc,
         "len: arg type has no codegen-defined length")))
  | Ast.App ({ node = Ast.Var "map_new"; _ }, _arg) ->
    (* Phase 15.10: map_new () — in Wasm ignore region, pick only the key type. *)
    let k_tag = map_key_tag_of_wasm e.Ast.ty e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_instr (Printf.sprintf "call $mere_map_%s_new" k_tag)
  | Ast.App ({ node = Ast.Var "map_len"; _ }, arg) ->
    let k_tag = map_key_tag_of_wasm arg.Ast.ty arg.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_expr arg;
    emit_instr (Printf.sprintf "call $mere_map_%s_len" k_tag)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_get"; _ }, m_e); _ }, k_e) ->
    let k_tag = map_key_tag_of_wasm m_e.Ast.ty m_e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_expr m_e;
    emit_expr k_e;
    emit_instr (Printf.sprintf "call $mere_map_%s_get" k_tag)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_has"; _ }, m_e); _ }, k_e) ->
    let k_tag = map_key_tag_of_wasm m_e.Ast.ty m_e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_expr m_e;
    emit_expr k_e;
    emit_instr (Printf.sprintf "call $mere_map_%s_has" k_tag)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_delete"; _ }, m_e); _ }, k_e) ->
    (* Phase 39.A' #2: map_delete m k *)
    let k_tag = map_key_tag_of_wasm m_e.Ast.ty m_e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_expr m_e;
    emit_expr k_e;
    emit_instr (Printf.sprintf "call $mere_map_%s_delete" k_tag)
  | Ast.App ({ node = Ast.App ({ node = Ast.App ({ node = Ast.Var "map_set"; _ }, m_e); _ }, k_e); _ }, v_e) ->
    let k_tag = map_key_tag_of_wasm m_e.Ast.ty m_e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    emit_expr m_e;
    emit_expr k_e;
    emit_expr v_e;
    emit_instr (Printf.sprintf "call $mere_map_%s_set" k_tag)
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "map_iter"; _ }, m_e); _ }, fn_e) ->
    (* Phase 19.2: map_iter m f — closure dispatch via call_indirect.
       Need both the table (vec_higher_order flag) and the basic vec
       helpers (since vec_higher_order_runtime contains vec_map / filter
       that call $mere_vec_new). Setting vec_used pulls them in. *)
    let k_tag = map_key_tag_of_wasm m_e.Ast.ty m_e.Ast.loc in
    (if k_tag = "int" then map_int_used := true else map_str_used := true);
    vec_used := true;
    vec_higher_order_used := true;
    emit_expr m_e;
    emit_expr fn_e;
    emit_instr (Printf.sprintf "call $mere_map_%s_iter" k_tag)
  | Ast.App ({ node = Ast.Var "vec_to_list"; _ }, vec_e) ->
    (* Phase 15.12: vec_to_list — shared $mere_vec_to_list helper. *)
    vec_used := true;
    vec_to_list_used := true;
    emit_expr vec_e;
    emit_instr "call $mere_vec_to_list"
  | Ast.App ({ node = Ast.Var "strbuf_new"; _ }, _arg) ->
    (* Phase 15.9: strbuf_new () — ignore region (Wasm's bump is a single
       global). *)
    strbuf_used := true;
    emit_instr "call $mere_strbuf_new"
  | Ast.App ({ node = Ast.Var "strbuf_len"; _ }, arg) ->
    strbuf_used := true;
    emit_expr arg;
    emit_instr "call $mere_strbuf_len"
  | Ast.App ({ node = Ast.Var "strbuf_to_str"; _ }, arg) ->
    strbuf_used := true;
    emit_expr arg;
    emit_instr "call $mere_strbuf_to_str"
  | Ast.App ({ node = Ast.App ({ node = Ast.Var "strbuf_push"; _ }, sb_e); _ }, str_e) ->
    strbuf_used := true;
    emit_expr sb_e;
    emit_expr str_e;
    emit_instr "call $mere_strbuf_push"
  | Ast.App ({ node = Ast.Var "fst"; _ }, arg) ->
    (* A 2-tuple is a pair of i64 slots at offsets 0 and 8 (same layout as a
       record). The tuple value is an i64 pointer, so wrap to i32 before the
       load and read the i64 field. (This previously emitted i32.load
       offset=0/4 — a stale layout that failed Wasm validation.) *)
    emit_expr arg;
    emit_instr "i32.wrap_i64";
    emit_instr "i64.load offset=0"
  | Ast.App ({ node = Ast.Var "snd"; _ }, arg) ->
    emit_expr arg;
    emit_instr "i32.wrap_i64";
    emit_instr "i64.load offset=8"
  (* v0.1.172: every call whose head the user bound lands here, whether it
     reached this point by falling past the builtin arms or by being sent
     past them from the guard above. *)
  | Ast.App _ -> emit_user_app saved_tail e
  | Ast.Record_lit (name, fields) when Hashtbl.mem Typer.views name ->
    (* View literal: same memory layout as a record (i32 per field),
       allocated from the active region's bump pointer. In Wasm all
       Lang regions share a single bump pointer so we use it directly. *)
    let info = Hashtbl.find Typer.views name in
    let decl_fields = info.Typer.v_fields in
    let n = List.length decl_fields in
    let base_slot = fresh_local_i32 () in
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" base_slot);
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr (Printf.sprintf "i32.const %d" (8 * n));
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    List.iteri (fun i (fname, _) ->
      let v_expr =
        match List.assoc_opt fname fields with
        | Some v -> v
        | None -> unsupported e.Ast.loc
                    (Printf.sprintf "missing field `%s` in view literal" fname)
      in
      emit_instr (Printf.sprintf "local.get %d" base_slot);
      emit_expr v_expr;
      emit_instr (Printf.sprintf "i64.store offset=%d" (8 * i))
    ) decl_fields;
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr "i64.extend_i32_u"
  | Ast.Record_lit (name, fields) ->
    let info =
      match Hashtbl.find_opt Typer.records name with
      | Some i -> i
      | None -> unsupported e.Ast.loc ("unknown record type: " ^ name)
    in
    (* Wasm layout is uniform (all fields are i32 / 4 bytes), so
       polymorphic records use the same code as monomorphic ones — no
       per-instance specialization needed unlike LLVM. *)
    let decl_fields = info.Typer.r_fields in
    let n = List.length decl_fields in
    let base_slot = fresh_local_i32 () in
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" base_slot);
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr (Printf.sprintf "i32.const %d" (8 * n));
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    List.iteri (fun i (fname, _) ->
      let v_expr =
        match List.assoc_opt fname fields with
        | Some v -> v
        | None -> unsupported e.Ast.loc
                    (Printf.sprintf "missing field `%s` in record literal" fname)
      in
      emit_instr (Printf.sprintf "local.get %d" base_slot);
      emit_expr v_expr;
      emit_instr (Printf.sprintf "i64.store offset=%d" (8 * i))
    ) decl_fields;
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr "i64.extend_i32_u"
  | Ast.Field_get (inner, fname) ->
    let raw_ty =
      match inner.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "field access: missing inner type"
    in
    (* Phase 19.x: field access through a borrow — unwrap TyRef and treat
       as the inner T's record. In Wasm everything is i32 (ptr) so the
       record's value representation is unchanged and field access uses
       the same steps. *)
    let inner_ty =
      match raw_ty with
      | Ast.TyRef (_, _, t) -> Ast.walk t
      | _ -> raw_ty
    in
    let rname, fields =
      match inner_ty with
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.views n ->
        (n, (Hashtbl.find Typer.views n).Typer.v_fields)
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
        (n, (Hashtbl.find Typer.records n).Typer.r_fields)
      | _ -> unsupported e.Ast.loc "field access on non-record/view"
    in
    let rec find_idx i = function
      | [] -> unsupported e.Ast.loc
                (Printf.sprintf "%s has no field `%s`" rname fname)
      | (n, _) :: _ when n = fname -> i
      | _ :: rest -> find_idx (i + 1) rest
    in
    let idx = find_idx 0 fields in
    emit_expr inner;
    emit_instr "i32.wrap_i64";
    (* Phase 19.x: if through a borrow (raw_ty is TyRef), Ref has added a
       box slot, so we need an extra load to unbox. *)
    (match raw_ty with
     | Ast.TyRef _ -> emit_instr "i64.load offset=0"; emit_instr "i32.wrap_i64"
     | _ -> ());
    emit_instr (Printf.sprintf "i64.load offset=%d" (8 * idx))
  | Ast.Record_update (base, updates) ->
    let base_ty =
      match base.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "record update: missing base type"
    in
    let rname =
      match base_ty with
      | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n -> n
      | _ -> unsupported e.Ast.loc "record update on non-record"
    in
    let info = Hashtbl.find Typer.records rname in
    let decl_fields = info.Typer.r_fields in
    let n = List.length decl_fields in
    let src_slot = fresh_local_i32 () in
    let dst_slot = fresh_local_i32 () in
    (* Evaluate base into src local (wrapped to its i32 address). *)
    emit_expr base;
    emit_instr "i32.wrap_i64";
    emit_instr (Printf.sprintf "local.set %d" src_slot);
    (* Reserve memory for new struct. *)
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" dst_slot);
    emit_instr (Printf.sprintf "local.get %d" dst_slot);
    emit_instr (Printf.sprintf "i32.const %d" (8 * n));
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    (* Fill in each field: from update if present, else load from src. *)
    List.iteri (fun i (fname, _) ->
      emit_instr (Printf.sprintf "local.get %d" dst_slot);
      (match List.assoc_opt fname updates with
       | Some v_expr -> emit_expr v_expr
       | None ->
         emit_instr (Printf.sprintf "local.get %d" src_slot);
         emit_instr (Printf.sprintf "i64.load offset=%d" (8 * i)));
      emit_instr (Printf.sprintf "i64.store offset=%d" (8 * i))
    ) decl_fields;
    emit_instr (Printf.sprintf "local.get %d" dst_slot);
    emit_instr "i64.extend_i32_u"
  | Ast.Constr (raw_cname, arg_opt) ->
    (* Phase 42: try raw qualified lookup first for disambiguation, fall back
       to canonical. variant_tags is keyed by bare names, so use canonical. *)
    let cname = Ast.canonical_ctor raw_cname in
    let info =
      match Hashtbl.find_opt Typer.constructors raw_cname with
      | Some i -> i
      | None ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some i -> i
         | None -> unsupported e.Ast.loc ("unknown constructor: " ^ raw_cname))
    in
    let type_name = info.Typer.type_name in
    let tag =
      match Hashtbl.find_opt variant_tags cname with
      | Some t -> t
      | None -> unsupported e.Ast.loc ("constructor without tag: " ^ raw_cname)
    in
    (* Phase 26.0: cell size is 8 bytes whenever the variant has any
       payload-bearing ctor (uniform layout `{i32 tag, i32 payload_i32}`).
       The payload_i32 holds either an inline value (int / bool / str ptr)
       or a pointer to a separately-allocated tuple/record (already a
       Wasm-side pointer, so no extra boxing is needed). *)
    let has_payload = variant_has_payload type_name in
    let n_bytes = if has_payload then 16 else 8 in
    let base_slot = fresh_local_i32 () in
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" base_slot);
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr (Printf.sprintf "i32.const %d" n_bytes);
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    (* Store tag at offset 0 (an 8-byte slot like every value). *)
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr (Printf.sprintf "i64.const %d" tag);
    emit_instr "i64.store offset=0";
    (match arg_opt with
     | None -> ()
     | Some arg ->
       emit_instr (Printf.sprintf "local.get %d" base_slot);
       emit_expr arg;
       emit_instr "i64.store offset=8");
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr "i64.extend_i32_u"
  | Ast.Match (scrut, arms) ->
    let scrut_ty =
      match scrut.Ast.ty with
      | Some t -> Ast.walk t
      | None -> unsupported e.Ast.loc "match: missing scrutinee type"
    in
    let scrut_slot = fresh_local () in
    emit_expr scrut;
    emit_instr (Printf.sprintf "local.set %d" scrut_slot);
    (* combine_and pushes both conds, runs i32.and, stores in a fresh local. *)
    (* condition plumbing is raw i32 (internal booleans, not Mere values) *)
    let combine_and (a : int) (b : int) : int =
      let slot = fresh_local_i32 () in
      emit_instr (Printf.sprintf "local.get %d" a);
      emit_instr (Printf.sprintf "local.get %d" b);
      emit_instr "i32.and";
      emit_instr (Printf.sprintf "local.set %d" slot);
      slot
    in
    let true_cond () =
      let slot = fresh_local_i32 () in
      emit_instr "i32.const 1";
      emit_instr (Printf.sprintf "local.set %d" slot);
      slot
    in
    (* Fully recursive pattern compile. Returns (cond local slot,
       (name, value-slot) bindings). *)
    let rec compile_pat (pat : Ast.pattern) (v_slot : int) (v_ty : Ast.ty)
      : int * (string * int) list =
      match pat.Ast.pnode with
      | Ast.P_wild -> (true_cond (), [])
      | Ast.P_var n -> (true_cond (), [(n, v_slot)])
      | Ast.P_unit -> (true_cond (), [])
      | Ast.P_int n ->
        let slot = fresh_local_i32 () in
        emit_instr (Printf.sprintf "local.get %d" v_slot);
        emit_instr (Printf.sprintf "i64.const %d" n);
        emit_instr "i64.eq";
        emit_instr (Printf.sprintf "local.set %d" slot);
        (slot, [])
      | Ast.P_bool b ->
        let slot = fresh_local_i32 () in
        emit_instr (Printf.sprintf "local.get %d" v_slot);
        emit_instr (Printf.sprintf "i64.const %d" (if b then 1 else 0));
        emit_instr "i64.eq";
        emit_instr (Printf.sprintf "local.set %d" slot);
        (slot, [])
      | Ast.P_str s ->
        let lit_off = fresh_str_offset s in
        let slot = fresh_local_i32 () in
        emit_instr (Printf.sprintf "local.get %d" v_slot);
        emit_instr (Printf.sprintf "i64.const %d" lit_off);
        emit_instr "call $__lang_streq";
        emit_instr "i32.wrap_i64";
        emit_instr (Printf.sprintf "local.set %d" slot);
        (slot, [])
      | Ast.P_as (inner, n) ->
        let (c, bs) = compile_pat inner v_slot v_ty in
        (c, (n, v_slot) :: bs)
      | Ast.P_tuple pats ->
        let elem_tys =
          match Ast.walk v_ty with Ast.TyTuple ts -> ts | _ ->
            unsupported pat.Ast.ploc "P_tuple on non-tuple"
        in
        let conds_bs = List.mapi (fun i p ->
          let elem_slot = fresh_local () in
          emit_instr (Printf.sprintf "local.get %d" v_slot);
          emit_instr "i32.wrap_i64";
          emit_instr (Printf.sprintf "i64.load offset=%d" (i * 8));
          emit_instr (Printf.sprintf "local.set %d" elem_slot);
          let elem_ty = try List.nth elem_tys i with _ -> Ast.TyInt in
          compile_pat p elem_slot elem_ty
        ) pats in
        let conds = List.map fst conds_bs in
        let cond = List.fold_left combine_and (true_cond ()) conds in
        let bs = List.concat_map snd conds_bs in
        (cond, bs)
      | Ast.P_record (_, sub_fields) ->
        let fields =
          match Ast.walk v_ty with
          | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
            (Hashtbl.find Typer.records n).Typer.r_fields
          | Ast.TyCon (n, _) when Hashtbl.mem Typer.views n ->
            (Hashtbl.find Typer.views n).Typer.v_fields
          | _ -> unsupported pat.Ast.ploc "P_record on non-record"
        in
        let idx_of fname =
          let rec find i = function
            | [] -> -1
            | (n, _) :: _ when n = fname -> i
            | _ :: rest -> find (i + 1) rest
          in find 0 fields
        in
        let ty_of fname = List.assoc fname fields in
        let conds_bs = List.map (fun (fname, sub_p) ->
          let i = idx_of fname in
          let ft = ty_of fname in
          let f_slot = fresh_local () in
          emit_instr (Printf.sprintf "local.get %d" v_slot);
          emit_instr "i32.wrap_i64";
          emit_instr (Printf.sprintf "i64.load offset=%d" (i * 8));
          emit_instr (Printf.sprintf "local.set %d" f_slot);
          compile_pat sub_p f_slot ft
        ) sub_fields in
        let conds = List.map fst conds_bs in
        let cond = List.fold_left combine_and (true_cond ()) conds in
        let bs = List.concat_map snd conds_bs in
        (cond, bs)
      | Ast.P_constr (raw_cname, sub) ->
        (* Phase 41 + 42: try raw qualified ctor lookup first for
           multi-module disambiguation, fall back to canonical. *)
        let cname = Ast.canonical_ctor raw_cname in
        let info =
          match Hashtbl.find_opt Typer.constructors raw_cname with
          | Some i -> i
          | None ->
            (match Hashtbl.find_opt Typer.constructors cname with
             | Some i -> i
             | None -> unsupported pat.Ast.ploc ("unknown ctor: " ^ raw_cname))
        in
        let _type_name = info.Typer.type_name in
        (* Phase 26.0: per-ctor payload type. For poly variants, walk
           the scrutinee type to extract concrete args and substitute
           the ctor's declared type params. *)
        let pty_opt =
          match info.Typer.arg with
          | None -> None
          | Some t ->
            (match Ast.walk v_ty, info.Typer.params with
             | Ast.TyCon (_n, args), params
               when List.length args = List.length params && params <> [] ->
               let args = List.map Ast.walk args in
               let mapping = List.combine params args in
               Some (Ast.walk (subst_params mapping t))
             | _ -> Some (Ast.walk t))
        in
        let tag =
          match Hashtbl.find_opt variant_tags cname with
          | Some t -> t
          | None -> unsupported pat.Ast.ploc ("ctor without tag: " ^ cname)
        in
        let tag_cond = fresh_local_i32 () in
        emit_instr (Printf.sprintf "local.get %d" v_slot);
        emit_instr "i32.wrap_i64";
        emit_instr "i64.load offset=0";
        emit_instr (Printf.sprintf "i64.const %d" tag);
        emit_instr "i64.eq";
        emit_instr (Printf.sprintf "local.set %d" tag_cond);
        (match sub, pty_opt with
         | None, _ -> (tag_cond, [])
         | Some sub_pat, Some pty ->
           (* Phase 38.C1 fix: guard the sub-pattern's payload deref with
              the outer tag check. An unconditional load offset=4 + deeper
              deref would read wrong memory and trap when the outer tag
              mismatches (discovered with `LApp (Lam (x, b), arg)` in
              lambda_calc.mere). With `if tag_cond then sub_cond else 0 end`,
              the sub-pattern's load / dereference runs only when the tag
              matches. *)
           let pl_slot = fresh_local () in
           let result_slot = fresh_local_i32 () in
           emit_instr (Printf.sprintf "local.get %d" tag_cond);
           emit_instr "if (result i32)";
           emit_instr (Printf.sprintf "local.get %d" v_slot);
           emit_instr "i32.wrap_i64";
           emit_instr "i64.load offset=8";
           emit_instr (Printf.sprintf "local.set %d" pl_slot);
           let (sub_cond, sub_bs) = compile_pat sub_pat pl_slot pty in
           emit_instr (Printf.sprintf "local.get %d" sub_cond);
           emit_instr "else";
           emit_instr "i32.const 0";
           emit_instr "end";
           emit_instr (Printf.sprintf "local.set %d" result_slot);
           (result_slot, sub_bs)
         | Some _, None ->
           unsupported pat.Ast.ploc
             ("pattern has payload but constructor `" ^ cname ^
              "` has no payload type"))
      | Ast.P_or _ ->
        unsupported pat.Ast.ploc "P_or should have been flattened"
    in
    (* Pre-flatten or-patterns into multiple arms. *)
    let rec expand_or (pat, guard, body) =
      match pat.Ast.pnode with
      | Ast.P_or (a, b) ->
        expand_or (a, guard, body) @ expand_or (b, guard, body)
      | _ -> [(pat, guard, body)]
    in
    let arms = List.concat_map expand_or arms in
    let rec emit_arms = function
      | [] -> emit_instr "unreachable"
      | (pat, guard, body) :: rest ->
        let (cond_slot, bindings) = compile_pat pat scrut_slot scrut_ty in
        (* Guard: evaluate within arm-bindings scope, AND with cond. If
           cond is false, short-circuit (don't even evaluate guard). *)
        let final_cond =
          match guard with
          | None -> cond_slot
          | Some g ->
            let g_slot = fresh_local_i32 () in
            emit_instr (Printf.sprintf "local.get %d" cond_slot);
            emit_instr "if (result i32)";
            let prev = !locals in
            locals := bindings @ prev;
            emit_expr g;
            locals := prev;
            emit_instr "i32.wrap_i64";
            emit_instr "else";
            emit_instr "i32.const 0";
            emit_instr "end";
            emit_instr (Printf.sprintf "local.set %d" g_slot);
            g_slot
        in
        emit_instr (Printf.sprintf "local.get %d" final_cond);
        emit_instr "if (result i64)";
        let prev = !locals in
        locals := bindings @ prev;
        wasm_tail_pos := saved_tail;
        emit_expr body;
        locals := prev;
        emit_instr "else";
        wasm_tail_pos := saved_tail;
        emit_arms rest;
        emit_instr "end"
    in
    emit_arms arms
  | Ast.Fun (param, _, fn_body) ->
    (* Anonymous Fun in expression position: register an adapter in the
       function table, build a closure value `{ env, fn_idx }`. Captures
       go into a memory-resident env struct (or env = 0 if there are
       none). *)
    let raw_fvs = free_vars fn_body [param] in
    let captures =
      List.filter_map (fun n ->
        match List.assoc_opt n !locals with
        | Some slot -> Some (n, slot)
        | None -> None) raw_fvs
    in
    let n = List.length captures in
    let adapter_name = fresh_anon_name () in
    let table_idx = register_in_table adapter_name in
    pending_closures :=
      { ce_adapter_name = adapter_name;
        ce_param = param;
        ce_body = fn_body;
        ce_captures = captures;
        ce_table_idx = table_idx;
        ce_host = !current_host_fn_wasm }
      :: !pending_closures;
    let env_slot = fresh_local_i32 () in
    let cl_slot = fresh_local_i32 () in
    if n = 0 then begin
      emit_instr "i32.const 0";
      emit_instr (Printf.sprintf "local.set %d" env_slot)
    end else begin
      emit_instr "global.get $__lang_bump";
      emit_instr (Printf.sprintf "local.set %d" env_slot);
      emit_instr (Printf.sprintf "local.get %d" env_slot);
      emit_instr (Printf.sprintf "i32.const %d" (n * 8));
      emit_instr "i32.add";
      emit_instr "global.set $__lang_bump";
      List.iteri (fun i (_, src_slot) ->
        emit_instr (Printf.sprintf "local.get %d" env_slot);
        emit_instr (Printf.sprintf "local.get %d" src_slot);
        emit_instr (Printf.sprintf "i64.store offset=%d" (i * 8))
      ) captures
    end;
    (* Build closure value: { env, fn_idx } (i32 record fields, host-read). *)
    emit_align_bump_4 ();  (* Phase 48.5: 4-byte align for host glue *)
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" cl_slot);
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i32.const 8";
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr (Printf.sprintf "local.get %d" env_slot);
    emit_instr "i32.store offset=0";
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr (Printf.sprintf "i32.const %d" table_idx);
    emit_instr "i32.store offset=4";
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i64.extend_i32_u"
  | Ast.Tuple elems ->
    (* All elements occupy 4 bytes (i32 / ptr-style offset). The tuple
       value is the base offset into linear memory. RESERVE the memory
       up-front (advance bump immediately) so nested tuples / concat
       inside element evaluation get their own non-overlapping memory. *)
    let n = List.length elems in
    let base_slot = fresh_local_i32 () in
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" base_slot);
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr (Printf.sprintf "i32.const %d" (8 * n));
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    List.iteri (fun i el ->
      emit_instr (Printf.sprintf "local.get %d" base_slot);
      emit_expr el;
      emit_instr (Printf.sprintf "i64.store offset=%d" (8 * i))
    ) elems;
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr "i64.extend_i32_u"
  | Ast.Region_block (_, body) ->
    (* v0.1.37: regions RECLAIM again — the safe version of the
       save / restore that Phase 16.4 removed as unsound. Three parts
       make it sound where the old version was not:
       1. the block's RESULT is deep-copied out (twice: once above the
          block's garbage, then — after the bump is restored — down
          into the enclosing allocation range; the two ranges cannot
          overlap because the first copy sits above everything the
          body allocated);
       2. escaping STORES are rejected up front (see the guard below):
          the Wasm backend has no per-container storage yet, so
          pushing a heap value into an outer container from inside a
          block would dangle — that is a compile error, not a leak;
       3. escaping CLOSURES are rejected via the result type and
          extern-callback checks (closure envs allocate in the block).
       Found by the 2048 dogfood: ~8.4 KB of per-move garbage hit the
       64 MB memory at move ~7,700. With a per-move region the game
       runs indefinitely. *)
    let result_ty =
      match e.Ast.ty with Some t -> Ast.walk t | None -> Ast.TyUnit in
    let rec ty_has_arrow t =
      match Ast.walk t with
      | Ast.TyArrow _ -> true
      | Ast.TyTuple ts -> List.exists ty_has_arrow ts
      | Ast.TyCon (_, args) -> List.exists ty_has_arrow args
      | _ -> false
    in
    let rec ty_has_container t =
      match Ast.walk t with
      | Ast.TyCon (("Vec" | "OwnedVec" | "Map" | "StrBuf" | "Channel"
                    | "ThreadHandle"), _) -> true
      | Ast.TyRef _ -> true
      | Ast.TyTuple ts -> List.exists ty_has_container ts
      | Ast.TyCon (_, args) -> List.exists ty_has_container args
      | _ -> false
    in
    if ty_has_arrow result_ty || ty_has_container result_ty then
      raise (Codegen_error (e.Ast.loc,
        "wasm: a region block cannot return a closure, container, or \
         borrow — its storage is reclaimed with the block (the Wasm \
         backend copies out plain values only; see memory-model.md section 3.5)"));
    (* Guard: no ESCAPING stores / callback registrations inside. A
       container CREATED inside the block is fine to mutate — its storage
       dies with the block (and the result-type check above stops it from
       escaping). What must be rejected is pushing block-allocated heap
       values into containers from OUTSIDE the block. *)
    let reject loc what =
      raise (Codegen_error (loc,
        Printf.sprintf
          "wasm: %s inside a region block is not supported yet (for a \
           container created outside the block) — the Wasm backend \
           reclaims the whole block on exit and has no per-container \
           storage to copy into (see memory-model.md section 3.5)"
          what))
    in
    let local_containers : (string, unit) Hashtbl.t = Hashtbl.create 4 in
    let rec app_spine (ex : Ast.expr) (acc : Ast.expr list) =
      match ex.Ast.node with
      | Ast.App (f, a) -> app_spine f (a :: acc)
      | Ast.Var n -> Some (n, acc)
      | _ -> None
    in
    let is_local_container (ex : Ast.expr) =
      match ex.Ast.node with
      | Ast.Var n -> Hashtbl.mem local_containers n
      | _ -> false
    in
    let elem_boxed (ve : Ast.expr) =
      match ve.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon (("Vec" | "OwnedVec"), [_; et])
         | Ast.TyCon (("Vec" | "OwnedVec"), [et]) ->
           (match Ast.walk et with
            | Ast.TyInt | Ast.TyBool | Ast.TyUnit -> false
            | _ -> true)
         | _ -> true)
      | None -> true
    in
    let rec guard (ex : Ast.expr) : unit =
      (match app_spine ex [] with
       | Some (("vec_push" | "owned_vec_push"), (ve :: _ as args))
         when List.length args >= 2 ->
         if not (is_local_container ve) && elem_boxed ve then
           reject ex.Ast.loc "vec_push of a heap value"
       | Some ("vec_set", (ve :: _ as args)) when List.length args >= 3 ->
         if not (is_local_container ve) && elem_boxed ve then
           reject ex.Ast.loc "vec_set of a heap value"
       | Some ("map_set", (me :: _ as args)) when List.length args >= 3 ->
         if not (is_local_container me) then reject ex.Ast.loc "map_set"
       | Some ("strbuf_push", (be :: _ as args)) when List.length args >= 2 ->
         if not (is_local_container be) then reject ex.Ast.loc "strbuf_push"
       | Some (("channel_send"), args) when List.length args >= 2 ->
         reject ex.Ast.loc "channel_send"
       | Some ("spawn", args) when List.length args >= 1 ->
         reject ex.Ast.loc "spawn"
       | Some (nm, args)
         when args <> []
              && Hashtbl.mem extern_fn_decls_wasm nm
              && (let rec has_arrow t =
                    match Ast.walk t with
                    | Ast.TyArrow _ -> true
                    | Ast.TyTuple ts -> List.exists has_arrow ts
                    | Ast.TyCon (_, ags) -> List.exists has_arrow ags
                    | _ -> false
                  in
                  let rec params t =
                    match Ast.walk t with
                    | Ast.TyArrow (a, b) -> a :: params b
                    | _ -> []
                  in
                  List.exists has_arrow
                    (params (Hashtbl.find extern_fn_decls_wasm nm))) ->
         reject ex.Ast.loc ("extern `" ^ nm ^ "` (registers a callback)")
       | _ -> ());
      (match ex.Ast.node with
       | Ast.Int_lit _ | Ast.Float_lit _ | Ast.Bool_lit _ | Ast.Str_lit _
       | Ast.Unit_lit | Ast.Var _ -> ()
       | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b)
       | Ast.App (a, b) -> guard a; guard b
       | Ast.Neg a | Ast.Annot (a, _) | Ast.Field_get (a, _)
       | Ast.Ref (_, _, a) | Ast.Region_block (_, a) -> guard a
       | Ast.Let (pat, v, b) ->
         guard v;
         (match pat.Ast.pnode, app_spine v [] with
          | Ast.P_var n, Some (("vec_new" | "map_new" | "strbuf_new"
                                | "owned_vec_new"), _) ->
            Hashtbl.replace local_containers n ()
          | _ -> ());
         guard b
       | Ast.With (_, v, b) -> guard v; guard b
       | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> guard v) bs; guard b
       | Ast.If (c, t, f) -> guard c; guard t; guard f
       | Ast.Fun (_, _, b) -> guard b
       | Ast.Constr (_, Some a) -> guard a
       | Ast.Constr (_, None) -> ()
       | Ast.Match (sc, arms) ->
         guard sc;
         List.iter (fun (_, g, b) ->
           (match g with Some ge -> guard ge | None -> ());
           guard b) arms
       | Ast.Tuple es -> List.iter guard es
       | Ast.Record_lit (_, fs) -> List.iter (fun (_, x) -> guard x) fs
       | Ast.Record_update (a, fs) ->
         guard a; List.iter (fun (_, x) -> guard x) fs)
    in
    guard body;
    add_wasm_copy_deps result_ty;
    let rtag = ty_tag result_ty in
    let unboxed =
      match result_ty with
      | Ast.TyInt | Ast.TyBool | Ast.TyUnit -> true
      | _ -> false
    in
    let saved = !wasm_tail_pos in
    wasm_tail_pos := false;
    emit_instr "global.get $__lang_bump";      (* mark *)
    emit_expr body;                             (* [mark, result] *)
    if not unboxed then
      emit_instr (Printf.sprintf "call $__mcopy_%s" rtag);  (* copy 1 (above garbage) *)
    emit_instr "global.set $__rgn_tmp";         (* [mark] *)
    emit_instr "global.set $__lang_bump";       (* release *)
    emit_instr "global.get $__rgn_tmp";
    if not unboxed then
      emit_instr (Printf.sprintf "call $__mcopy_%s" rtag);  (* copy 2 (into enclosing) *)
    wasm_tail_pos := saved
  | Ast.Ref (_, _, inner) ->
    (* `&R v` — region-alloc an 8-byte slot, store the value, return ptr. *)
    let base_slot = fresh_local_i32 () in
    emit_instr "global.get $__lang_bump";
    emit_instr (Printf.sprintf "local.set %d" base_slot);
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr "i32.const 8";
    emit_instr "i32.add";
    emit_instr "global.set $__lang_bump";
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_expr inner;
    emit_instr "i64.store offset=0";
    emit_instr (Printf.sprintf "local.get %d" base_slot);
    emit_instr "i64.extend_i32_u"
  | Ast.With (name, value, body) ->
    (* `with c = v in body` — bind v, run body, auto-invoke c.close
       if v has a `close: unit -> unit` field. *)
    let v_slot = fresh_local () in
    emit_expr value;
    emit_instr (Printf.sprintf "local.set %d" v_slot);
    let close_idx =
      match value.Ast.ty with
      | Some t ->
        (match Ast.walk t with
         | Ast.TyCon (n, _) when Hashtbl.mem Typer.records n ->
           let fields = (Hashtbl.find Typer.records n).Typer.r_fields in
           let rec find i = function
             | [] -> None
             | (fname, _) :: _ when fname = "close" -> Some i
             | _ :: rest -> find (i + 1) rest
           in find 0 fields
         | _ -> None)
      | _ -> None
    in
    let prev_locals = !locals in
    locals := (name, v_slot) :: prev_locals;
    emit_expr body;
    locals := prev_locals;
    (match close_idx with
     | None -> ()
     | Some idx ->
       (* Stash body's result, then call c.close(unit), restore result. *)
       let result_slot = fresh_local () in
       emit_instr (Printf.sprintf "local.set %d" result_slot);
       let cl_slot = fresh_local () in
       emit_instr (Printf.sprintf "local.get %d" v_slot);
       emit_instr (Printf.sprintf "i32.load offset=%d" (4 * idx));
       emit_instr (Printf.sprintf "local.set %d" cl_slot);
       emit_instr (Printf.sprintf "local.get %d" cl_slot);
       emit_instr "i32.load offset=0";  (* env *)
       emit_instr "i32.const 0";        (* unit arg *)
       emit_instr (Printf.sprintf "local.get %d" cl_slot);
       emit_instr "i32.load offset=4";  (* fn_idx *)
       emit_instr "call_indirect (type $cl)";
       emit_instr "drop";               (* discard close's return *)
       emit_instr (Printf.sprintf "local.get %d" result_slot))
  (* Phase 34.3: since the entire AST structure is now covered above, OCaml
     considers the fallback `| _ ->` redundant. We'd like to keep explicit
     unsupported errors tagged by node_name, but leaving a wildcard in each
     case would produce unused warnings — so completely removed. *)

and emit_user_app (saved_tail : bool) (e : Ast.expr) : unit =
  (* The three shapes an ordinary call can take: an inner-lifted fn, a
     top-level fn, or a closure value. Split out of emit_expr so that the
     shadowing guard has somewhere to send a call it must not let the
     builtin arms see. *)
  match e.Ast.node with
  | Ast.App ({ node = Ast.Var name; _ }, arg)
    when Hashtbl.mem inner_lifts_wasm name ->
    (* Phase 26.3: inner-lifted call — emit captures (looked up via
       current locals) + arg, then call $<lifted_name>. *)
    let li = Hashtbl.find inner_lifts_wasm name in
    List.iter (fun cap ->
      match List.assoc_opt cap !locals with
      | Some slot -> emit_instr (Printf.sprintf "local.get %d" slot)
      | None when Hashtbl.mem top_globals_wasm cap ->
        emit_instr (Printf.sprintf "global.get $%s" cap)
      | None -> unsupported e.Ast.loc
          (Printf.sprintf "inner-lifted capture `%s` not in scope" cap)
    ) li.captures;
    emit_expr arg;
    let call_op = if saved_tail then "return_call" else "call" in
    emit_instr (Printf.sprintf "%s $%s" call_op li.lifted_name)
  | Ast.App ({ node = Ast.Var name; ty = f_ty; _ }, arg)
    when Hashtbl.mem toplevel_fn_names name ->
    emit_expr arg;
    let dispatch_name =
      if Hashtbl.mem multi_inst_fns_wasm name then
        match f_ty with
        | Some t ->
          (match Ast.walk t with
           | Ast.TyArrow _ as arrow -> mangled_inst_name_wasm name arrow
           | _ -> name)
        | None -> name
      else name
    in
    let call_op = if saved_tail then "return_call" else "call" in
    emit_instr (Printf.sprintf "%s $%s" call_op dispatch_name)
  | Ast.App (f, arg) ->
    (* Indirect call via call_indirect on the closure value's table
       index. closure layout: { env @ offset 0, fn_idx @ offset 4 }
       (i32 record fields; env crosses as an i64 value). *)
    let cl_slot = fresh_local () in
    emit_expr f;
    emit_instr (Printf.sprintf "local.set %d" cl_slot);
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i32.wrap_i64";
    emit_instr "i32.load offset=0";
    emit_instr "i64.extend_i32_u";
    emit_expr arg;
    emit_instr (Printf.sprintf "local.get %d" cl_slot);
    emit_instr "i32.wrap_i64";
    emit_instr "i32.load offset=4";
    let call_op = if saved_tail then "return_call_indirect" else "call_indirect" in
    emit_instr (Printf.sprintf "%s (type $cl)" call_op)
  | _ -> failwith "emit_user_app: not an application"

(* Emit one top-level fn definition. Params are positional locals
   starting at slot 0; let-binding locals are mint-ed afterwards.
   Body's stack-top value is the function's return. *)
let emit_fn_def (f : fn_decl) : string =
  let saved_instrs = !instrs in
  let saved_local_counter = !local_counter in
  let saved_locals = !locals in
  let saved_local_types = !local_types in
  let saved_host = !current_host_fn_wasm in
  set_inner_lifts_for_host_wasm f.name;
  current_host_fn_wasm := f.name;
  instrs := [];
  (* Param sits at slot 0. let-bindings start from slot 1. *)
  local_counter := 1;
  (* v0.1.57: track extra-local types from here so Phase 34.3's f64 temp
     slots (float boxing) are DECLARED f64, not blanket i32. Params claim
     their slots directly (not via fresh_local), so local_types holds
     exactly the extra locals, in slot order. Found by a raytracer probe:
     any float-boxing temp inside a named fn produced invalid WAT
     (local.set of f64 into an i32 local) — the main-body emitter already
     read local_types, but the fn emitters hardcoded i32. *)
  local_types := [];
  locals := [(f.param, 0)];
  let saved_tail = !wasm_tail_pos in
  wasm_tail_pos := true;
  emit_expr f.body;
  wasm_tail_pos := saved_tail;
  let body_instrs = List.rev !instrs in
  let extra_locals = !local_counter - 1 in
  let extra_types = !local_types in
  instrs := saved_instrs;
  local_counter := saved_local_counter;
  locals := saved_locals;
  local_types := saved_local_types;
  current_host_fn_wasm := saved_host;
  let local_decl =
    if extra_locals <= 0 then ""
    else
      let types =
        if List.length extra_types = extra_locals then extra_types
        else List.init extra_locals (fun _ -> "i64")
      in
      Printf.sprintf "    (local%s)\n"
        (String.concat "" (List.map (fun t -> " " ^ t) types))
  in
  let indented_body =
    String.concat "\n" (List.map (fun s -> "    " ^ s) body_instrs)
  in
  ignore f.param_ty;
  ignore f.return_ty;
  record_fn_line f.name f.body.Ast.loc;
  Printf.sprintf
    "  (func $%s (param i64) (result i64)\n%s%s)"
    f.name local_decl indented_body

(* Phase 26.3: emit a lifted inner fn as top-level Wasm fn. Captures
   come before the original param as i32 locals (positional). The body
   resolves recursive lifted siblings via set_inner_lifts_for_host_wasm. *)
let emit_lifted_fn_wasm (lf : lifted_fn_wasm) : string =
  set_inner_lifts_for_host_wasm lf.l_host;
  let saved_instrs = !instrs in
  let saved_local_counter = !local_counter in
  let saved_locals = !locals in
  let saved_local_types = !local_types in
  let saved_host = !current_host_fn_wasm in
  instrs := [];
  current_host_fn_wasm := lf.l_host;
  (* Allocate slots: captures at 0..N-1, param at N. *)
  let n_caps = List.length lf.l_captures in
  local_counter := n_caps + 1;
  (* v0.1.57: typed extra locals (see emit_fn_def). *)
  local_types := [];
  let cap_locals = List.mapi (fun i n -> (n, i)) lf.l_captures in
  locals := (lf.l_param, n_caps) :: cap_locals;
  let saved_tail = !wasm_tail_pos in
  wasm_tail_pos := true;
  emit_expr lf.l_body;
  wasm_tail_pos := saved_tail;
  let body_instrs = List.rev !instrs in
  let extra_locals = !local_counter - (n_caps + 1) in
  let extra_types = !local_types in
  instrs := saved_instrs;
  local_counter := saved_local_counter;
  locals := saved_locals;
  local_types := saved_local_types;
  current_host_fn_wasm := saved_host;
  let param_decls =
    String.concat " "
      (List.init (n_caps + 1) (fun _ -> "(param i64)"))
  in
  let local_decl =
    if extra_locals <= 0 then ""
    else
      let types =
        if List.length extra_types = extra_locals then extra_types
        else List.init extra_locals (fun _ -> "i64")
      in
      Printf.sprintf "    (local%s)\n"
        (String.concat "" (List.map (fun t -> " " ^ t) types))
  in
  let indented_body =
    String.concat "\n" (List.map (fun s -> "    " ^ s) body_instrs)
  in
  Printf.sprintf
    "  (func $%s %s (result i64)\n%s%s)"
    lf.l_name param_decls local_decl indented_body

(* Env-ignoring adapter so top-level fn `f` can be used as a closure
   value: `(env, x) -> result` that just calls `$f(x)`. *)
let emit_top_adapter (f : fn_decl) : string =
  Printf.sprintf
    "  (func $%s_closure (param i64) (param i64) (result i64)\n\
     \    local.get 1\n\
     \    call $%s)" f.name f.name

(* Phase 35.3: eta adapter for a nullary factory builtin used as a value.
   `slug` is the registered key in [eta_adapters_wasm]; `builtin` is the
   underlying name (vec_new / owned_vec_new / strbuf_new / map_new). The
   adapter ignores both arguments (env, unit) and calls the appropriate
   runtime helper. *)
let emit_eta_adapter_wasm (slug : string) (builtin : string) : string =
  let body =
    match builtin with
    | "vec_new" | "owned_vec_new" -> "call $mere_vec_new"
    | "strbuf_new" -> "call $mere_strbuf_new"
    | "map_new" ->
      let k_tag =
        if String.length slug > 8
           && String.sub slug 0 8 = "map_new_"
        then String.sub slug 8 (String.length slug - 8)
        else "int"
      in
      Printf.sprintf "call $mere_map_%s_new" k_tag
    | _ -> "unreachable"
  in
  Printf.sprintf
    "  (func $eta_%s (param i64) (param i64) (result i64)\n\
     \    %s)" slug body

(* Adapter for an anonymous Fun. Slot 0 = env ptr, slot 1 = param;
   capture locals start at slot 2. Loads each capture from env at the
   appropriate offset, then evaluates the original Fun body. *)
let emit_anon_adapter (ce : closure_emission) : string =
  let saved_instrs = !instrs in
  let saved_local_counter = !local_counter in
  let saved_locals = !locals in
  let saved_local_types = !local_types in
  let saved_host = !current_host_fn_wasm in
  (* Phase 26.3: restore the host scope this closure was queued under so
     its body can resolve recursive calls into inner-lifted siblings. *)
  set_inner_lifts_for_host_wasm ce.ce_host;
  current_host_fn_wasm := ce.ce_host;
  instrs := [];
  let env_slot = 0 in
  let param_slot = 1 in
  let n = List.length ce.ce_captures in
  let capture_locals =
    List.mapi (fun i (cname, _) ->
      let slot = 2 + i in
      emit_instr (Printf.sprintf "local.get %d" env_slot);
      emit_instr "i32.wrap_i64";
      emit_instr (Printf.sprintf "i64.load offset=%d" (i * 8));
      emit_instr (Printf.sprintf "local.set %d" slot);
      (cname, slot)
    ) ce.ce_captures
  in
  local_counter := 2 + n;
  (* v0.1.57: typed extra locals (see emit_fn_def). The n capture-unpack
     locals at slots 2..2+n-1 are i32 (boxed values); fresh-minted temps
     after them may be f64. *)
  local_types := [];
  locals := (ce.ce_param, param_slot) :: capture_locals;
  let saved_tail = !wasm_tail_pos in
  wasm_tail_pos := true;
  emit_expr ce.ce_body;
  wasm_tail_pos := saved_tail;
  let body_instrs = List.rev !instrs in
  let extra_locals = !local_counter - 2 in
  let extra_types = !local_types in
  instrs := saved_instrs;
  local_counter := saved_local_counter;
  locals := saved_locals;
  local_types := saved_local_types;
  current_host_fn_wasm := saved_host;
  let local_decl =
    if extra_locals <= 0 then ""
    else
      (* first n slots = capture unpacks (i64 values), then the tracked temps *)
      let types =
        if n + List.length extra_types = extra_locals then
          List.init n (fun _ -> "i64") @ extra_types
        else List.init extra_locals (fun _ -> "i64")
      in
      Printf.sprintf "    (local%s)\n"
        (String.concat "" (List.map (fun t -> " " ^ t) types))
  in
  let indented_body =
    String.concat "\n" (List.map (fun s -> "    " ^ s) body_instrs)
  in
  Printf.sprintf
    "  (func $%s (param i64) (param i64) (result i64)\n%s%s)"
    ce.ce_adapter_name local_decl indented_body

(* Emit `show_<tag>(x: i32) -> i32` for one type. Returns the WAT
   function definition as a string. *)
let emit_show_fn (tag : string) (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt ->
    (* int → decimal string in a fresh 16-byte buffer, write digits
       right-to-left, return pointer to the first digit. *)
    {|  (func $show_int (param $n i64) (result i64)
    (local $buf i32) (local $i i32) (local $abs i64) (local $neg i32)
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (global.get $__lang_bump) (i32.const 24)))
    (local.set $i (i32.const 23))
    (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 0))
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then
        (local.set $neg (i32.const 1))
        ;; wraps at INT64_MIN; div_u/rem_u below read it as the correct
        ;; unsigned magnitude, so the full i64 range formats right.
        (local.set $abs (i64.sub (i64.const 0) (local.get $n))))
      (else
        (local.set $neg (i32.const 0))
        (local.set $abs (local.get $n))))
    (if (i64.eqz (local.get $abs))
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 48))
        (return (call $__lang_str_copyn (i64.extend_i32_u (i32.add (local.get $buf) (local.get $i))) (i64.extend_i32_u (i32.sub (i32.const 23) (local.get $i)))))))
    (block $end
      (loop $lp
        (br_if $end (i64.eqz (local.get $abs)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i))
          (i32.add (i32.const 48)
            (i32.wrap_i64 (i64.rem_u (local.get $abs) (i64.const 10)))))
        (local.set $abs (i64.div_u (local.get $abs) (i64.const 10)))
        (br $lp)))
    (if (local.get $neg)
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 45))))
    (call $__lang_str_copyn (i64.extend_i32_u (i32.add (local.get $buf) (local.get $i))) (i64.extend_i32_u (i32.sub (i32.const 23) (local.get $i)))))|}
  | Ast.TyBool ->
    let t_off = intern_show_str "true" in
    let f_off = intern_show_str "false" in
    Printf.sprintf
      "  (func $show_bool (param $b i64) (result i64)\n\
      \    (if (result i64) (i32.wrap_i64 (local.get $b))\n\
      \      (then (i64.const %d))\n\
      \      (else (i64.const %d))))"
      t_off f_off
  | Ast.TyStr ->
    let q_off = intern_show_str "\"" in
    (* Phase 26.6 (port of LLVM Phase 25.6): run %s through
       __lang_str_escape so output matches interp's show_str behavior. *)
    Printf.sprintf
      "  (func $show_str (param $s i64) (result i64)\n\
      \    (call $__lang_str_concat\n\
      \      (call $__lang_str_concat (i64.const %d) (call $__lang_str_escape (local.get $s)))\n\
      \      (i64.const %d)))"
      q_off q_off
  | Ast.TyUnit ->
    let off = intern_show_str "()" in
    Printf.sprintf
      "  (func $show_unit (param $u i64) (result i64)\n\
      \    (i64.const %d))"
      off
  | Ast.TyFloat ->
    (* Q-029 probe fallout: show on a float hit the `_ ->` fallback and
       printed "<?show_float?>", so the four backends were giving four
       different answers for the same program. A float value is an i64
       pointer here, so load the f64 and hand it to the shared formatter
       (an env import, which returns an i32 str pointer). *)
    "  (func $show_float (param $x i64) (result i64)\n    \    (i64.extend_i32_u\n    \      (call $__lang_str_of_float\n    \        (f64.load offset=0 align=8 (i32.wrap_i64 (local.get $x))))))"
  | Ast.TyTuple ts ->
    let comma = intern_show_str ", " in
    let lparen = intern_show_str "(" in
    let rparen = intern_show_str ")" in
    let lines = Buffer.create 256 in
    (* v0.1.153: fields are 8-byte i64 slots and a str value is an i64, so
       the accumulator and the interned constants are i64 and the loads are
       i64 at offset i*8. The i32-era shape here made `show` unassemblable
       for every composite type on this backend. *)
    Buffer.add_string lines
      (Printf.sprintf "  (func $show_%s (param $x i64) (result i64)\n" tag);
    Buffer.add_string lines "    (local $r i64)\n";
    Buffer.add_string lines
      (Printf.sprintf "    (local.set $r (i64.const %d))\n" lparen);
    List.iteri (fun i ety ->
      if i > 0 then
        Buffer.add_string lines
          (Printf.sprintf
             "    (local.set $r (call $__lang_str_concat (local.get $r) (i64.const %d)))\n"
             comma);
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) \
            (call $show_%s (i64.load offset=%d (i32.wrap_i64 (local.get $x))))))\n"
           (ty_tag ety) (i * 8))
    ) ts;
    Buffer.add_string lines
      (Printf.sprintf
         "    (call $__lang_str_concat (local.get $r) (i64.const %d)))"
         rparen);
    Buffer.contents lines
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
    let info = Hashtbl.find Typer.records n in
    let mapping =
      if info.Typer.r_params = [] then []
      else List.combine info.Typer.r_params args
    in
    let hdr = intern_show_str (n ^ " { ") in
    let suffix = intern_show_str " }" in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $show_%s (param $x i64) (result i64)\n" tag);
    Buffer.add_string lines "    (local $r i64)\n";
    Buffer.add_string lines
      (Printf.sprintf "    (local.set $r (i64.const %d))\n" hdr);
    List.iteri (fun i (fname, ft) ->
      let ft = subst_params mapping ft in
      let sep =
        if i = 0 then intern_show_str (fname ^ " = ")
        else intern_show_str (", " ^ fname ^ " = ")
      in
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) (i64.const %d)))\n"
           sep);
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) \
            (call $show_%s (i64.load offset=%d (i32.wrap_i64 (local.get $x))))))\n"
           (ty_tag ft) (i * 8))
    ) info.Typer.r_fields;
    Buffer.add_string lines
      (Printf.sprintf
         "    (call $__lang_str_concat (local.get $r) (i64.const %d)))"
         suffix);
    Buffer.contents lines
  | Ast.TyCon ("list", [elem_ty]) ->
    (* `'a list = Nil | Cons of 'a * 'a list` special-case: render as
       `[a, b, c]`. Walk via cur/acc/first locals; for each Cons node
       at offset 0 the tag is 1 and offset 4 holds the (head, tail)
       tuple offset. *)
    let lb = intern_show_str "[" in
    let rb = intern_show_str "]" in
    let comma = intern_show_str ", " in
    (* v0.1.153: rebuilt for the i64 value model. This walker still read
       8-byte cells with i32 fields and kept the accumulator str in an i32
       local, so `show` applied to ANY list emitted WAT that wat2wasm
       rejected — `print (show [1, 2, 3])` could not be assembled at all.
       Cells are 16 bytes: tag at 0, payload pointer at 8; the payload
       tuple holds head at 0 and tail at 8, both i64. *)
    Printf.sprintf
      "  (func $show_%s (param $x i64) (result i64)\n\
      \    (local $cur i32) (local $acc i64) (local $first i32)\n\
      \    (local $pl i32)\n\
      \    (local.set $acc (i64.const %d))\n\
      \    (local.set $cur (i32.wrap_i64 (local.get $x)))\n\
      \    (local.set $first (i32.const 1))\n\
      \    (block $end\n\
      \      (loop $lp\n\
      \        (br_if $end (i64.eqz (i64.load offset=0 (local.get $cur))))\n\
      \        (local.set $pl (i32.wrap_i64 (i64.load offset=8 (local.get $cur))))\n\
      \        (if (i32.eqz (local.get $first))\n\
      \          (then\n\
      \            (local.set $acc (call $__lang_str_concat (local.get $acc) (i64.const %d)))))\n\
      \        (local.set $acc (call $__lang_str_concat (local.get $acc)\n\
      \          (call $show_%s (i64.load offset=0 (local.get $pl)))))\n\
      \        (local.set $first (i32.const 0))\n\
      \        (local.set $cur (i32.wrap_i64 (i64.load offset=8 (local.get $pl))))\n\
      \        (br $lp)))\n\
      \    (call $__lang_str_concat (local.get $acc) (i64.const %d)))"
      tag lb comma (ty_tag elem_ty) rb
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.types n ->
    let vs =
      match Hashtbl.find_opt Exhaustive.type_variants n with
      | Some vs -> vs
      | None -> []
    in
    let mapping =
      match vs with
      | (cname, _) :: _ ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some info when info.Typer.params <> [] ->
           List.combine info.Typer.params args
         | _ -> [])
      | [] -> []
    in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $show_%s (param $x i64) (result i64)\n" tag);
    Buffer.add_string lines "    (local $tag i32)\n";
    Buffer.add_string lines
      "    (local.set $tag (i32.wrap_i64 (i64.load offset=0 (i32.wrap_i64 (local.get $x)))))\n";
    (* Nested if/else chain over each ctor's tag. *)
    let rec emit_branches = function
      | [] -> "(unreachable)"
      | (cname, arg_opt) :: rest ->
        let ctor_tag =
          match Hashtbl.find_opt variant_tags cname with
          | Some t -> t
          | None -> raise (Codegen_error (Loc.dummy,
            "ctor without tag in show_fn: " ^ cname))
        in
        let arm_body =
          match arg_opt with
          | None ->
            Printf.sprintf "(i64.const %d)" (intern_show_str cname)
          | Some pty ->
            let pty = subst_params mapping pty in
            let prefix = intern_show_str (cname ^ " ") in
            Printf.sprintf
              "(call $__lang_str_concat (i64.const %d) \
               (call $show_%s (i64.load offset=8 (i32.wrap_i64 (local.get $x)))))"
              prefix (ty_tag pty)
        in
        Printf.sprintf
          "(if (result i64) (i32.eq (local.get $tag) (i32.const %d))\n\
          \      (then %s)\n\
          \      (else %s))"
          ctor_tag arm_body (emit_branches rest)
    in
    Buffer.add_string lines (Printf.sprintf "    %s)" (emit_branches vs));
    Buffer.contents lines
  | _ ->
    let off = intern_show_str ("<?show_" ^ tag ^ "?>") in
    (* Str offsets are i64 values in this backend (cf. show_bool / show_str,
       which push i64.const). The fallback previously emitted `i32.const`,
       producing a function that fails validation (result i64, body i32) —
       latent because a closure/opaque-typed program value is rarely compiled
       to Wasm. Surfaced by the component-model func(string)->string slice,
       whose top-level value is a closure. *)
    Printf.sprintf
      "  (func $show_%s (param $x i64) (result i64)\n\
      \    (i64.const %d))"
      tag off

(* JSON sibling of emit_show_fn (derive slice, Wasm). Emits `to_json_<tag>`
   producing JSON: records -> objects (quoted field names, no type tag),
   lists/tuples -> arrays, nullary ctor -> "Name", payload ctor ->
   {"Name": payload}. int/bool/str are byte-identical to show so their
   bodies are copied; the rest use JSON delimiters. Recursive calls go to
   to_json_<tag>. Kept in sync with eval.ml / codegen_c.ml. *)
let emit_to_json_fn (tag : string) (t : Ast.ty) : string =
  match Ast.walk t with
  | Ast.TyInt ->
    {|  (func $to_json_int (param $n i64) (result i64)
    (local $buf i32) (local $i i32) (local $abs i64) (local $neg i32)
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (global.get $__lang_bump) (i32.const 24)))
    (local.set $i (i32.const 23))
    (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 0))
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then
        (local.set $neg (i32.const 1))
        (local.set $abs (i64.sub (i64.const 0) (local.get $n))))
      (else
        (local.set $neg (i32.const 0))
        (local.set $abs (local.get $n))))
    (if (i64.eqz (local.get $abs))
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 48))
        (return (call $__lang_str_copyn (i64.extend_i32_u (i32.add (local.get $buf) (local.get $i))) (i64.extend_i32_u (i32.sub (i32.const 23) (local.get $i)))))))
    (block $end
      (loop $lp
        (br_if $end (i64.eqz (local.get $abs)))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i))
          (i32.add (i32.const 48)
            (i32.wrap_i64 (i64.rem_u (local.get $abs) (i64.const 10)))))
        (local.set $abs (i64.div_u (local.get $abs) (i64.const 10)))
        (br $lp)))
    (if (local.get $neg)
      (then
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.const 45))))
    (call $__lang_str_copyn (i64.extend_i32_u (i32.add (local.get $buf) (local.get $i))) (i64.extend_i32_u (i32.sub (i32.const 23) (local.get $i)))))|}
  | Ast.TyBool ->
    let t_off = intern_show_str "true" in
    let f_off = intern_show_str "false" in
    Printf.sprintf
      "  (func $to_json_bool (param $b i64) (result i64)\n\
      \    (if (result i64) (i32.wrap_i64 (local.get $b))\n\
      \      (then (i64.const %d))\n\
      \      (else (i64.const %d))))"
      t_off f_off
  | Ast.TyStr ->
    let q_off = intern_show_str "\"" in
    Printf.sprintf
      "  (func $to_json_str (param $s i64) (result i64)\n\
      \    (call $__lang_str_concat\n\
      \      (call $__lang_str_concat (i64.const %d) (call $__lang_str_escape (local.get $s)))\n\
      \      (i64.const %d)))"
      q_off q_off
  | Ast.TyUnit ->
    let off = intern_show_str "null" in
    Printf.sprintf
      "  (func $to_json_unit (param $u i64) (result i64) (i64.const %d))" off
  | Ast.TyArrow _ ->
    let off = intern_show_str "null" in
    Printf.sprintf
      "  (func $to_json_%s (param $u i64) (result i64) (i64.const %d))" tag off
  | Ast.TyTuple ts ->
    let comma = intern_show_str "," in
    let lb = intern_show_str "[" in
    let rb = intern_show_str "]" in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $to_json_%s (param $x i64) (result i64)\n" tag);
    Buffer.add_string lines "    (local $r i64)\n";
    Buffer.add_string lines
      (Printf.sprintf "    (local.set $r (i64.const %d))\n" lb);
    List.iteri (fun i ety ->
      if i > 0 then
        Buffer.add_string lines
          (Printf.sprintf
             "    (local.set $r (call $__lang_str_concat (local.get $r) (i64.const %d)))\n"
             comma);
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) \
            (call $to_json_%s (i64.load offset=%d (i32.wrap_i64 (local.get $x))))))\n"
           (ty_tag ety) (i * 8))
    ) ts;
    Buffer.add_string lines
      (Printf.sprintf
         "    (call $__lang_str_concat (local.get $r) (i64.const %d)))" rb);
    Buffer.contents lines
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
    let info = Hashtbl.find Typer.records n in
    let mapping =
      if info.Typer.r_params = [] then []
      else List.combine info.Typer.r_params args
    in
    let hdr = intern_show_str "{" in
    let suffix = intern_show_str "}" in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $to_json_%s (param $x i64) (result i64)\n" tag);
    Buffer.add_string lines "    (local $r i64)\n";
    Buffer.add_string lines
      (Printf.sprintf "    (local.set $r (i64.const %d))\n" hdr);
    List.iteri (fun i (fname, ft) ->
      let ft = subst_params mapping ft in
      let sep =
        if i = 0 then intern_show_str ("\"" ^ fname ^ "\":")
        else intern_show_str (",\"" ^ fname ^ "\":")
      in
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) (i64.const %d)))\n"
           sep);
      Buffer.add_string lines
        (Printf.sprintf
           "    (local.set $r (call $__lang_str_concat (local.get $r) \
            (call $to_json_%s (i64.load offset=%d (i32.wrap_i64 (local.get $x))))))\n"
           (ty_tag ft) (i * 8))
    ) info.Typer.r_fields;
    Buffer.add_string lines
      (Printf.sprintf
         "    (call $__lang_str_concat (local.get $r) (i64.const %d)))" suffix);
    Buffer.contents lines
  | Ast.TyCon ("list", [elem_ty]) ->
    let lb = intern_show_str "[" in
    let rb = intern_show_str "]" in
    let comma = intern_show_str "," in
    Printf.sprintf
      "  (func $to_json_%s (param $x i64) (result i64)\n\
      \    (local $cur i32) (local $acc i64) (local $first i32)\n\
      \    (local $pl i32)\n\
      \    (local.set $acc (i64.const %d))\n\
      \    (local.set $cur (i32.wrap_i64 (local.get $x)))\n\
      \    (local.set $first (i32.const 1))\n\
      \    (block $end\n\
      \      (loop $lp\n\
      \        (br_if $end (i64.eqz (i64.load offset=0 (local.get $cur))))\n\
      \        (local.set $pl (i32.wrap_i64 (i64.load offset=8 (local.get $cur))))\n\
      \        (if (i32.eqz (local.get $first))\n\
      \          (then\n\
      \            (local.set $acc (call $__lang_str_concat (local.get $acc) (i64.const %d)))))\n\
      \        (local.set $acc (call $__lang_str_concat (local.get $acc)\n\
      \          (call $to_json_%s (i64.load offset=0 (local.get $pl)))))\n\
      \        (local.set $first (i32.const 0))\n\
      \        (local.set $cur (i32.wrap_i64 (i64.load offset=8 (local.get $pl))))\n\
      \        (br $lp)))\n\
      \    (call $__lang_str_concat (local.get $acc) (i64.const %d)))"
      tag lb comma (ty_tag elem_ty) rb
  | Ast.TyCon ("option", [inner]) ->
    (* option is a transparent JSON nullable: None -> null, Some x -> x.
       Kept in sync with codegen_c / eval so to_json round-trips. *)
    let none_tag = try Hashtbl.find variant_tags "None" with Not_found -> 0 in
    let null_off = intern_show_str "null" in
    Printf.sprintf
      "  (func $to_json_%s (param $x i64) (result i64)\n\
      \    (if (result i64)\n\
      \        (i64.eq (i64.load offset=0 (i32.wrap_i64 (local.get $x))) (i64.const %d))\n\
      \      (then (i64.const %d))\n\
      \      (else (call $to_json_%s (i64.load offset=8 (i32.wrap_i64 (local.get $x)))))))"
      tag none_tag null_off (ty_tag (Ast.walk inner))
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.types n ->
    let vs =
      match Hashtbl.find_opt Exhaustive.type_variants n with
      | Some vs -> vs | None -> []
    in
    let mapping =
      match vs with
      | (cname, _) :: _ ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some info when info.Typer.params <> [] ->
           List.combine info.Typer.params args
         | _ -> [])
      | [] -> []
    in
    let lines = Buffer.create 256 in
    Buffer.add_string lines
      (Printf.sprintf "  (func $to_json_%s (param $x i64) (result i64)\n" tag);
    Buffer.add_string lines "    (local $tag i32)\n";
    Buffer.add_string lines
      "    (local.set $tag (i32.wrap_i64 (i64.load offset=0 (i32.wrap_i64 (local.get $x)))))\n";
    let rec emit_branches = function
      | [] -> "(unreachable)"
      | (cname, arg_opt) :: rest ->
        let ctor_tag =
          match Hashtbl.find_opt variant_tags cname with
          | Some t -> t
          | None -> raise (Codegen_error (Loc.dummy,
            "ctor without tag in to_json_fn: " ^ cname))
        in
        let arm_body =
          match arg_opt with
          | None ->
            Printf.sprintf "(i64.const %d)" (intern_show_str ("\"" ^ cname ^ "\""))
          | Some pty ->
            let pty = subst_params mapping pty in
            let prefix = intern_show_str ("{\"" ^ cname ^ "\":") in
            let suffix = intern_show_str "}" in
            Printf.sprintf
              "(call $__lang_str_concat (call $__lang_str_concat (i64.const %d) \
               (call $to_json_%s (i64.load offset=8 (i32.wrap_i64 (local.get $x))))) (i64.const %d))"
              prefix (ty_tag pty) suffix
        in
        Printf.sprintf
          "(if (result i64) (i32.eq (local.get $tag) (i32.const %d))\n\
          \      (then %s)\n\
          \      (else %s))"
          ctor_tag arm_body (emit_branches rest)
    in
    Buffer.add_string lines (Printf.sprintf "    %s)" (emit_branches vs));
    Buffer.contents lines
  | _ ->
    let off = intern_show_str "null" in
    Printf.sprintf
      "  (func $to_json_%s (param $x i64) (result i64) (i64.const %d))" tag off

(* Structural equality for compound types on Wasm. A compound value is a
   linear-memory offset, so `i32.eq` would compare offsets, not contents —
   `eq_<tag>` compares field/element/payload-wise instead. Mirrors show /
   to_json; kept in sync with codegen_c / eval. *)
let emit_eq_fn (tag : string) (t : Ast.ty) : string =
  (* i64 value model: params are values; addresses wrap to i32, fields are
     8-byte slots. eq_* returns an i64 bool. *)
  let and_chain items =
    List.fold_right (fun e acc -> Printf.sprintf "(i32.and %s %s)" e acc)
      items "(i32.const 1)"
  in
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool ->
    Printf.sprintf
      "  (func $eq_%s (param $a i64) (param $b i64) (result i64)\n\
      \    (i64.extend_i32_u (i64.eq (local.get $a) (local.get $b))))" tag
  | Ast.TyStr ->
    Printf.sprintf
      "  (func $eq_%s (param $a i64) (param $b i64) (result i64)\n\
      \    (call $__lang_streq (local.get $a) (local.get $b)))" tag
  | Ast.TyUnit ->
    Printf.sprintf
      "  (func $eq_%s (param $a i64) (param $b i64) (result i64) (i64.const 1))" tag
  | Ast.TyArrow _ ->
    Printf.sprintf
      "  (func $eq_%s (param $a i64) (param $b i64) (result i64) (i64.const 0))" tag
  | Ast.TyTuple ts ->
    let elems =
      List.mapi (fun i et ->
        Printf.sprintf
          "(i32.wrap_i64 (call $eq_%s (i64.load offset=%d (i32.wrap_i64 (local.get $a))) (i64.load offset=%d (i32.wrap_i64 (local.get $b)))))"
          (ty_tag et) (i * 8) (i * 8)) ts
    in
    Printf.sprintf
      "  (func $eq_%s (param $a i64) (param $b i64) (result i64)\n    (i64.extend_i32_u %s))"
      tag (and_chain elems)
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
    let info = Hashtbl.find Typer.records n in
    let mapping =
      if info.Typer.r_params = [] then []
      else List.combine info.Typer.r_params args
    in
    let elems =
      List.mapi (fun i (_, ft) ->
        let _ = subst_params mapping ft in
        Printf.sprintf
          "(i32.wrap_i64 (call $eq_%s (i64.load offset=%d (i32.wrap_i64 (local.get $a))) (i64.load offset=%d (i32.wrap_i64 (local.get $b)))))"
          (ty_tag (subst_params mapping ft)) (i * 8) (i * 8)) info.Typer.r_fields
    in
    Printf.sprintf
      "  (func $eq_%s (param $a i64) (param $b i64) (result i64)\n    (i64.extend_i32_u %s))"
      tag (and_chain elems)
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.types n || n = "list" ->
    let vs =
      match Hashtbl.find_opt Exhaustive.type_variants n with
      | Some vs -> vs | None -> []
    in
    let mapping =
      match vs with
      | (cname, _) :: _ ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some info when info.Typer.params <> [] ->
           List.combine info.Typer.params args
         | _ -> [])
      | [] -> []
    in
    let rec payload_dispatch = function
      | [] -> "(i64.const 1)"
      | (cname, arg_opt) :: rest ->
        (match arg_opt with
         | None -> payload_dispatch rest
         | Some pty ->
           let pty = subst_params mapping pty in
           let ctag =
             match Hashtbl.find_opt variant_tags cname with
             | Some t -> t | None -> 0
           in
           Printf.sprintf
             "(if (result i64) (i32.eq (local.get $ta) (i32.const %d))\n\
             \      (then (call $eq_%s (i64.load offset=8 (i32.wrap_i64 (local.get $a))) (i64.load offset=8 (i32.wrap_i64 (local.get $b)))))\n\
             \      (else %s))"
             ctag (ty_tag pty) (payload_dispatch rest))
    in
    Printf.sprintf
      "  (func $eq_%s (param $a i64) (param $b i64) (result i64)\n\
      \    (local $ta i32)\n\
      \    (local.set $ta (i32.wrap_i64 (i64.load offset=0 (i32.wrap_i64 (local.get $a)))))\n\
      \    (if (result i64) (i32.ne (local.get $ta) (i32.wrap_i64 (i64.load offset=0 (i32.wrap_i64 (local.get $b)))))\n\
      \      (then (i64.const 0))\n\
      \      (else %s)))"
      tag (payload_dispatch vs)
  | _ ->
    Printf.sprintf
      "  (func $eq_%s (param $a i64) (param $b i64) (result i64) (i64.const 0))" tag

(* v0.1.11 derive-ord: structural compare returning -1/0/1, the ordering
   sibling of emit_eq_fn. Lexicographic first-non-zero via `local.tee $c`
   chains. Variants order by tag (declaration order) then payload — matching
   the interpreter's value_compare and the C backend's cmp_<tag>. *)
let emit_cmp_fn (tag : string) (t : Ast.ty) : string =
  (* i64 value model: cmp_* takes i64 values and returns -1/0/1 as i64.
     Internal chains work in i32 and extend at the boundary. *)
  let rec chain = function
    | [] -> "(i32.const 0)"
    | [last] -> last
    | ci :: rest ->
      Printf.sprintf
        "(if (result i32) (i32.eqz (local.tee $c %s))\n      (then %s)\n      (else (local.get $c)))"
        ci (chain rest)
  in
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool ->
    Printf.sprintf
      "  (func $cmp_%s (param $a i64) (param $b i64) (result i64)\n\
      \    (i64.extend_i32_s (i32.sub (i64.gt_s (local.get $a) (local.get $b)) (i64.lt_s (local.get $a) (local.get $b)))))" tag
  | Ast.TyFloat ->
    Printf.sprintf
      "  (func $cmp_%s (param $a i64) (param $b i64) (result i64)\n\
      \    (i64.extend_i32_s (i32.sub\n\
      \      (f64.gt (f64.load offset=0 align=8 (i32.wrap_i64 (local.get $a))) (f64.load offset=0 align=8 (i32.wrap_i64 (local.get $b))))\n\
      \      (f64.lt (f64.load offset=0 align=8 (i32.wrap_i64 (local.get $a))) (f64.load offset=0 align=8 (i32.wrap_i64 (local.get $b)))))))" tag
  | Ast.TyStr ->
    Printf.sprintf
      "  (func $cmp_%s (param $a i64) (param $b i64) (result i64)\n\
      \    (call $__lang_str_compare (local.get $a) (local.get $b)))" tag
  | Ast.TyUnit | Ast.TyArrow _ ->
    Printf.sprintf
      "  (func $cmp_%s (param $a i64) (param $b i64) (result i64) (i64.const 0))" tag
  | Ast.TyTuple ts ->
    let elems =
      List.mapi (fun i et ->
        Printf.sprintf
          "(i32.wrap_i64 (call $cmp_%s (i64.load offset=%d (i32.wrap_i64 (local.get $a))) (i64.load offset=%d (i32.wrap_i64 (local.get $b)))))"
          (ty_tag et) (i * 8) (i * 8)) ts
    in
    Printf.sprintf
      "  (func $cmp_%s (param $a i64) (param $b i64) (result i64)\n    (local $c i32)\n    (i64.extend_i32_s %s))"
      tag (chain elems)
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
    let info = Hashtbl.find Typer.records n in
    let mapping =
      if info.Typer.r_params = [] then [] else List.combine info.Typer.r_params args
    in
    let elems =
      List.mapi (fun i (_, ft) ->
        Printf.sprintf
          "(i32.wrap_i64 (call $cmp_%s (i64.load offset=%d (i32.wrap_i64 (local.get $a))) (i64.load offset=%d (i32.wrap_i64 (local.get $b)))))"
          (ty_tag (subst_params mapping ft)) (i * 8) (i * 8)) info.Typer.r_fields
    in
    Printf.sprintf
      "  (func $cmp_%s (param $a i64) (param $b i64) (result i64)\n    (local $c i32)\n    (i64.extend_i32_s %s))"
      tag (chain elems)
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.types n || n = "list" ->
    let vs =
      match Hashtbl.find_opt Exhaustive.type_variants n with Some vs -> vs | None -> []
    in
    let mapping =
      match vs with
      | (cname, _) :: _ ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some info when info.Typer.params <> [] -> List.combine info.Typer.params args
         | _ -> [])
      | [] -> []
    in
    let rec payload_dispatch = function
      | [] -> "(i64.const 0)"
      | (cname, arg_opt) :: rest ->
        (match arg_opt with
         | None -> payload_dispatch rest
         | Some pty ->
           let pty = subst_params mapping pty in
           let ctag = match Hashtbl.find_opt variant_tags cname with Some t -> t | None -> 0 in
           Printf.sprintf
             "(if (result i64) (i32.eq (local.get $ta) (i32.const %d))\n\
             \      (then (call $cmp_%s (i64.load offset=8 (i32.wrap_i64 (local.get $a))) (i64.load offset=8 (i32.wrap_i64 (local.get $b)))))\n\
             \      (else %s))"
             ctag (ty_tag pty) (payload_dispatch rest))
    in
    Printf.sprintf
      "  (func $cmp_%s (param $a i64) (param $b i64) (result i64)\n\
      \    (local $ta i32) (local $tb i32)\n\
      \    (local.set $ta (i32.wrap_i64 (i64.load offset=0 (i32.wrap_i64 (local.get $a)))))\n\
      \    (local.set $tb (i32.wrap_i64 (i64.load offset=0 (i32.wrap_i64 (local.get $b)))))\n\
      \    (if (result i64) (i32.ne (local.get $ta) (local.get $tb))\n\
      \      (then (i64.extend_i32_s (i32.sub (i32.gt_s (local.get $ta) (local.get $tb)) (i32.lt_s (local.get $ta) (local.get $tb)))))\n\
      \      (else %s)))"
      tag (payload_dispatch vs)
  | _ ->
    Printf.sprintf
      "  (func $cmp_%s (param $a i64) (param $b i64) (result i64) (i64.const 0))" tag

let emit_copy_fn_wasm (tag : string) (t : Ast.ty) : string =
  let header = Printf.sprintf "  (func $__mcopy_%s (param $v i64) (result i64)" tag in
  let field_copy src_expr ft =
    if wasm_unboxed ft then src_expr
    else Printf.sprintf "(call $__mcopy_%s %s)" (ty_tag ft) src_expr
  in
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyUnit ->
    header ^ " (local.get $v))"
  | Ast.TyStr ->
    header ^ " (call $__mcopy_str (local.get $v)))"
  | Ast.TyFloat ->
    (* floats are 8-byte boxes; keep the 8-alignment convention *)
    header ^ "\n" ^
    "    (local $p i32)\n\
    \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
    \    (local.set $p (global.get $__lang_bump))\n\
    \    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 8)))\n\
    \    (f64.store offset=0 align=8 (local.get $p) (f64.load offset=0 align=8 (local.get $v)))\n\
    \    (local.get $p))"
  | Ast.TyTuple ts ->
    let n = List.length ts in
    let stores =
      List.mapi (fun i ft ->
        Printf.sprintf
          "    (i32.store offset=%d (local.get $p) %s)"
          (i * 4)
          (field_copy (Printf.sprintf "(i32.load offset=%d (local.get $v))" (i * 4)) ft))
        ts
    in
    Printf.sprintf
      "%s\n    (local $p i32)\n    (local.set $p (global.get $__lang_bump))\n    (global.set $__lang_bump (i32.add (local.get $p) (i32.const %d)))\n%s\n    (local.get $p))"
      header (n * 4) (String.concat "\n" stores)
  | Ast.TyCon (n, args) when Hashtbl.mem Typer.records n ->
    let info = Hashtbl.find Typer.records n in
    let mapping =
      if info.Typer.r_params = [] then []
      else List.combine info.Typer.r_params args in
    let fields = List.map (fun (_, ft) -> subst_params mapping ft) info.Typer.r_fields in
    let nf = List.length fields in
    let stores =
      List.mapi (fun i ft ->
        Printf.sprintf
          "    (i32.store offset=%d (local.get $p) %s)"
          (i * 4)
          (field_copy (Printf.sprintf "(i32.load offset=%d (local.get $v))" (i * 4)) ft))
        fields
    in
    Printf.sprintf
      "%s\n    (local $p i32)\n    (local.set $p (global.get $__lang_bump))\n    (global.set $__lang_bump (i32.add (local.get $p) (i32.const %d)))\n%s\n    (local.get $p))"
      header (nf * 4) (String.concat "\n" stores)
  | Ast.TyCon (n, args) when Hashtbl.mem Exhaustive.type_variants n ->
    let vs = Hashtbl.find Exhaustive.type_variants n in
    let mapping =
      match vs with
      | (cname, _) :: _ ->
        (match Hashtbl.find_opt Typer.constructors cname with
         | Some info when info.Typer.params <> [] ->
           List.combine info.Typer.params args
         | _ -> [])
      | [] -> []
    in
    (* node = [tag][payload]; copy payload per-ctor when boxed *)
    let rec payload_dispatch = function
      | [] -> "(i32.load offset=4 (local.get $v))"
      | (cname, arg_opt) :: rest ->
        (match arg_opt with
         | None -> payload_dispatch rest
         | Some pty ->
           let pty = subst_params mapping pty in
           if wasm_unboxed pty then payload_dispatch rest
           else
             let ctag =
               match Hashtbl.find_opt variant_tags cname with
               | Some t -> t | None -> 0 in
             Printf.sprintf
               "(if (result i64) (i32.eq (local.get $t) (i32.const %d))\n\
               \      (then (call $__mcopy_%s (i32.load offset=4 (local.get $v))))\n\
               \      (else %s))"
               ctag (ty_tag pty) (payload_dispatch rest))
    in
    Printf.sprintf
      "%s\n    (local $p i32) (local $t i32)\n    (local.set $t (i32.load offset=0 (local.get $v)))\n    (local.set $p (global.get $__lang_bump))\n    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 8)))\n    (i32.store offset=0 (local.get $p) (local.get $t))\n    (i32.store offset=4 (local.get $p) %s)\n    (local.get $p))"
      header (payload_dispatch vs)
  | _ ->
    (* containers / closures / channels: pointer passthrough (guards
       reject the escaping-store cases) *)
    header ^ " (local.get $v))"

(* Static runtime helpers emitted into the Wasm module: strlen and
   str_concat both work on the linear memory. The bump pointer is a
   mutable global; concat advances it after copying the result. *)
let runtime_helpers = {|
  ;; byte-safe str: linear-memory layout is [i32 len][len bytes]['\0'].
  ;; A `str` value is the address of byte0; the 4-byte length header sits
  ;; immediately before it (addr-4). NUL-free strings stay C/host-interop
  ;; compatible (the trailing '\0' is preserved); embedded NULs survive
  ;; because length comes from the header, not a NUL scan. Wasm permits
  ;; unaligned i32 access, so the header needs no alignment.
  (func $__lang_str_alloc (param $len8 i64) (result i64)
    (local $len i32) (local $p i32)
    (local.set $len (i32.wrap_i64 (local.get $len8)))
    (i32.store (global.get $__lang_bump) (local.get $len))          ;; header
    (local.set $p (i32.add (global.get $__lang_bump) (i32.const 4))) ;; byte0
    (i32.store8 (i32.add (local.get $p) (local.get $len)) (i32.const 0)) ;; NUL
    (global.set $__lang_bump
      (i32.add (local.get $p) (i32.add (local.get $len) (i32.const 1))))
    (i64.extend_i32_u (local.get $p)))
  ;; str length = i32 header at addr-4 (byte-safe: counts embedded NULs).
  (func $__lang_strlen (param $s8 i64) (result i64)
    (i64.extend_i32_u
      (i32.load (i32.sub (i32.wrap_i64 (local.get $s8)) (i32.const 4)))))
  ;; Copy `len` raw bytes into a fresh header'd str. Used to finalize
  ;; right-to-left digit buffers (show_int / to_json_int) whose result
  ;; pointer floats inside a scratch region with no room for a header.
  (func $__lang_str_copyn (param $src8 i64) (param $len8 i64) (result i64)
    (local $src i32) (local $len i32) (local $dst i32) (local $i i32)
    (local.set $src (i32.wrap_i64 (local.get $src8)))
    (local.set $len (i32.wrap_i64 (local.get $len8)))
    (local.set $dst (i32.wrap_i64 (call $__lang_str_alloc (i64.extend_i32_u (local.get $len)))))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $len)))
      (i32.store8 (i32.add (local.get $dst) (local.get $i))
                  (i32.load8_u (i32.add (local.get $src) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i64.extend_i32_u (local.get $dst)))
  (func $__lang_str_concat (param $a8 i64) (param $b8 i64) (result i64)
    (local $la i32) (local $lb i32) (local $r i32) (local $i i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $la (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $a)))))
    (local.set $lb (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $b)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end_a
      (loop $lp_a
        (br_if $end_a (i32.eq (local.get $i) (local.get $la)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $a) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_a)))
    (local.set $i (i32.const 0))
    (block $end_b
      (loop $lp_b
        (br_if $end_b (i32.eq (local.get $i) (local.get $lb)))
        (i32.store8 (i32.add (i32.add (local.get $r) (local.get $la)) (local.get $i))
                    (i32.load8_u (i32.add (local.get $b) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_b)))
    (i32.store8 (i32.add (i32.add (local.get $r) (local.get $la)) (local.get $lb))
                (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (i32.add (local.get $r) (local.get $la)) (local.get $lb))
               (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; v0.1.37: deep-copy a NUL-terminated str into fresh bump space.
  ;; Region blocks copy their result out before releasing the block's
  ;; allocations (the safe version of the save/restore that Phase 16.4
  ;; removed as unsound).
  (func $__mcopy_str (param $s8 i64) (result i64)
    (local $l i32) (local $r i32) (local $i i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $l (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.gt_s (local.get $i) (local.get $l)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $l)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; byte-safe: compare lengths (from header) then bytes over that length,
  ;; so embedded NULs count instead of terminating the scan.
  (func $__lang_streq (param $a8 i64) (param $b8 i64) (result i64)
    (local $la i32) (local $lb i32) (local $i i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $la (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $a)))))
    (local.set $lb (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $b)))))
    (if (i32.ne (local.get $la) (local.get $lb))
      (then (return (i64.extend_i32_s (i32.const 0)))))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $la)))
        (if (i32.ne (i32.load8_u (i32.add (local.get $a) (local.get $i)))
                    (i32.load8_u (i32.add (local.get $b) (local.get $i))))
          (then (return (i64.extend_i32_s (i32.const 0)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (i32.const 1)))
  ;; Phase 31.0: str_compare — returns -1 / 0 / 1 (sign-normalized, matches
  ;; interp's `compare s t` from OCaml stdlib).
  ;; byte-safe: memcmp over min(la,lb), then length tiebreak.
  (func $__lang_str_compare (param $a8 i64) (param $b8 i64) (result i64)
    (local $la i32) (local $lb i32) (local $n i32) (local $i i32)
    (local $ba i32) (local $bb i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $la (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $a)))))
    (local.set $lb (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $b)))))
    (local.set $n (select (local.get $la) (local.get $lb) (i32.lt_u (local.get $la) (local.get $lb))))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $n)))
        (local.set $ba (i32.load8_u (i32.add (local.get $a) (local.get $i))))
        (local.set $bb (i32.load8_u (i32.add (local.get $b) (local.get $i))))
        (if (i32.lt_u (local.get $ba) (local.get $bb))
          (then (return (i64.extend_i32_s (i32.const -1)))))
        (if (i32.gt_u (local.get $ba) (local.get $bb))
          (then (return (i64.extend_i32_s (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (if (i32.lt_u (local.get $la) (local.get $lb))
      (then (return (i64.extend_i32_s (i32.const -1)))))
    (if (i32.gt_u (local.get $la) (local.get $lb))
      (then (return (i64.extend_i32_s (i32.const 1)))))
    (i64.extend_i32_s (i32.const 0)))
  ;; Phase 19.1.1: str_index_of — returns position of needle in haystack,
  ;; -1 if not found. Empty needle returns 0.
  (func $__lang_str_index_of (param $h8 i64) (param $n8 i64) (result i64)
    (local $hlen i32) (local $nlen i32) (local $i i32) (local $j i32)
    (local $match i32)
    (local $h i32)
    (local $n i32)
    (local.set $h (i32.wrap_i64 (local.get $h8)))
    (local.set $n (i32.wrap_i64 (local.get $n8)))
    (local.set $hlen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $h)))))
    (local.set $nlen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $n)))))
    (if (i32.eqz (local.get $nlen)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (local.set $i (i32.const 0))
    (block $end_outer
      (loop $lp_outer
        ;; if i + nlen > hlen → not found
        (br_if $end_outer
               (i32.gt_s (i32.add (local.get $i) (local.get $nlen))
                         (local.get $hlen)))
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $nlen)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $h)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $n) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (if (local.get $match) (then (return (i64.extend_i32_s (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i64.extend_i32_s (i32.const -1)))
  ;; Phase 36: __lang_is_ws — ASCII whitespace test (space/tab/lf/cr/ff)
  (func $__lang_is_ws (param $c8 i64) (result i64)
    (local $c i32)
    (local.set $c (i32.wrap_i64 (local.get $c8)))
    (i64.extend_i32_s (i32.or
      (i32.or
        (i32.or (i32.eq (local.get $c) (i32.const 32))
                (i32.eq (local.get $c) (i32.const 9)))
        (i32.or (i32.eq (local.get $c) (i32.const 10))
                (i32.eq (local.get $c) (i32.const 13))))
      (i32.eq (local.get $c) (i32.const 12)))))
  ;; Phase 36: str_starts_with — bool (i32 0/1)
  ;; byte-safe: bound the compare by the prefix length (header), not a NUL.
  (func $__lang_str_starts_with (param $s8 i64) (param $p8 i64) (result i64)
    (local $i i32) (local $sl i32) (local $pl i32)
    (local $s i32)
    (local $p i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $p (i32.wrap_i64 (local.get $p8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $pl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $p)))))
    (if (i32.gt_u (local.get $pl) (local.get $sl))
      (then (return (i64.extend_i32_s (i32.const 0)))))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $pl)))
        (if (i32.ne (i32.load8_u (i32.add (local.get $s) (local.get $i)))
                    (i32.load8_u (i32.add (local.get $p) (local.get $i))))
          (then (return (i64.extend_i32_s (i32.const 0)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (i32.const 1)))
  ;; Phase 36: str_trim — strip leading + trailing whitespace
  (func $__lang_str_trim (param $s8 i64) (result i64)
    (local $p i32) (local $len i32) (local $r i32) (local $i i32) (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $p (local.get $s))
    ;; skip leading whitespace
    (block $end_lead
      (loop $lp_lead
        (local.set $c (i32.load8_u (local.get $p)))
        (br_if $end_lead (i32.eqz (local.get $c)))
        (br_if $end_lead (i32.eqz (i32.wrap_i64 (call $__lang_is_ws (i64.extend_i32_s (local.get $c))))))
        (local.set $p (i32.add (local.get $p) (i32.const 1)))
        (br $lp_lead)))
    ;; compute remaining length
    (local.set $len (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $p)))))
    ;; trim trailing
    (block $end_trail
      (loop $lp_trail
        (br_if $end_trail (i32.eqz (local.get $len)))
        (local.set $c (i32.load8_u (i32.add (local.get $p)
                                            (i32.sub (local.get $len) (i32.const 1)))))
        (br_if $end_trail (i32.eqz (i32.wrap_i64 (call $__lang_is_ws (i64.extend_i32_s (local.get $c))))))
        (local.set $len (i32.sub (local.get $len) (i32.const 1)))
        (br $lp_trail)))
    ;; copy [p, p+len) to bump
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end_copy
      (loop $lp_copy
        (br_if $end_copy (i32.eq (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $p) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_copy)))
    (i32.store8 (i32.add (local.get $r) (local.get $len)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $len)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 36: str_ends_with — bool (i32 0/1)
  (func $__lang_str_ends_with (param $s8 i64) (param $p8 i64) (result i64)
    (local $sl i32) (local $pl i32) (local $i i32)
    (local $s i32)
    (local $p i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $p (i32.wrap_i64 (local.get $p8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $pl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $p)))))
    (if (i32.gt_s (local.get $pl) (local.get $sl)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (local.set $i (i32.const 0))
    (loop $lp
      (if (i32.eq (local.get $i) (local.get $pl)) (then (return (i64.extend_i32_s (i32.const 1)))))
      (if (i32.ne
            (i32.load8_u (i32.add (i32.add (local.get $s)
                                           (i32.sub (local.get $sl) (local.get $pl)))
                                  (local.get $i)))
            (i32.load8_u (i32.add (local.get $p) (local.get $i))))
        (then (return (i64.extend_i32_s (i32.const 0)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp))
    (unreachable))
  ;; Phase 36: str_repeat s n
  (func $__lang_str_repeat (param $s8 i64) (param $n8 i64) (result i64)
    (local $sl i32) (local $r i32) (local $i i32) (local $j i32)
    (local $s i32)
    (local $n i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (local.get $n8)))
    (if (i32.le_s (local.get $n) (i32.const 0))
      (then
        (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
        (i32.store8 (local.get $r) (i32.const 0))
        (global.set $__lang_bump (i32.add (local.get $r) (i32.const 1)))
        (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.const 0))
        (return (i64.extend_i32_s (local.get $r)))))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end_outer
      (loop $lp_outer
        (br_if $end_outer (i32.eq (local.get $i) (local.get $n)))
        (local.set $j (i32.const 0))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $sl)))
            (i32.store8 (i32.add (local.get $r)
                                 (i32.add (i32.mul (local.get $i) (local.get $sl))
                                          (local.get $j)))
                        (i32.load8_u (i32.add (local.get $s) (local.get $j))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i32.store8 (i32.add (local.get $r) (i32.mul (local.get $n) (local.get $sl)))
                (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (i32.mul (local.get $n) (local.get $sl)))
               (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 36: str_rev
  (func $__lang_str_rev (param $s8 i64) (result i64)
    (local $sl i32) (local $r i32) (local $i i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $sl)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $s)
                                          (i32.sub (i32.sub (local.get $sl) (local.get $i))
                                                   (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $sl)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $sl)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 36: chr n — return char_table entry pointer for byte n.
  ;; Mask to a single byte (n & 0xFF) so out-of-range input can't index
  ;; past the 256-entry table into adjacent memory. Matches the C backend
  ;; ((unsigned char)n) and the self-host $chr (i32.store8 truncation).
  (func $__lang_char_at_chr (param $n8 i64) (result i64)
    (local $n i32)
    (local.set $n (i32.wrap_i64 (local.get $n8)))
    (call $__lang_char_at_setup)
    (i64.extend_i32_s (i32.add (i32.add (global.get $__lang_char_table)
      (i32.mul (i32.and (local.get $n) (i32.const 255)) (i32.const 6))) (i32.const 4))))
  ;; Phase 36: abs / min / max / clamp
  (func $__lang_abs (param $n i64) (result i64)
    (if (i64.lt_s (local.get $n) (i64.const 0))
      (then (return (i64.sub (i64.const 0) (local.get $n)))))
    (local.get $n))
  (func $__lang_min (param $a i64) (param $b i64) (result i64)
    (if (i64.lt_s (local.get $a) (local.get $b))
      (then (return (local.get $a))))
    (local.get $b))
  (func $__lang_max (param $a i64) (param $b i64) (result i64)
    (if (i64.gt_s (local.get $a) (local.get $b))
      (then (return (local.get $a))))
    (local.get $b))
  (func $__lang_clamp (param $lo i64) (param $hi i64) (param $x i64) (result i64)
    (if (i64.lt_s (local.get $x) (local.get $lo))
      (then (return (local.get $lo))))
    (if (i64.gt_s (local.get $x) (local.get $hi))
      (then (return (local.get $hi))))
    (local.get $x))
  ;; Phase 36: to_upper / to_lower — ASCII case conversion
  (func $__lang_to_upper (param $s8 i64) (result i64)
    (local $sl i32) (local $r i32) (local $i i32) (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $sl)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (if (i32.and (i32.ge_u (local.get $c) (i32.const 97))
                     (i32.le_u (local.get $c) (i32.const 122)))
          (then (local.set $c (i32.sub (local.get $c) (i32.const 32)))))
        (i32.store8 (i32.add (local.get $r) (local.get $i)) (local.get $c))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $sl)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $sl)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  (func $__lang_to_lower (param $s8 i64) (result i64)
    (local $sl i32) (local $r i32) (local $i i32) (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $sl)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (if (i32.and (i32.ge_u (local.get $c) (i32.const 65))
                     (i32.le_u (local.get $c) (i32.const 90)))
          (then (local.set $c (i32.add (local.get $c) (i32.const 32)))))
        (i32.store8 (i32.add (local.get $r) (local.get $i)) (local.get $c))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $sl)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $sl)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 36: gcd via iterative Euclid on |a|, |b|
  (func $__lang_gcd (param $a0 i64) (param $b0 i64) (result i64)
    (local $a i64) (local $b i64) (local $t i64)
    (local.set $a (local.get $a0))
    (local.set $b (local.get $b0))
    (if (i64.lt_s (local.get $a) (i64.const 0))
      (then (local.set $a (i64.sub (i64.const 0) (local.get $a)))))
    (if (i64.lt_s (local.get $b) (i64.const 0))
      (then (local.set $b (i64.sub (i64.const 0) (local.get $b)))))
    (block $end
      (loop $lp
        (br_if $end (i64.eqz (local.get $b)))
        (local.set $t (local.get $b))
        (local.set $b (i64.rem_s (local.get $a) (local.get $b)))
        (local.set $a (local.get $t))
        (br $lp)))
    (local.get $a))
  ;; Phase 36: bool_of_str — "true" → 1, otherwise → 0
  (func $__lang_bool_of_str (param $s8 i64) (result i64)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (if (i32.ne (i32.load8_u (local.get $s)) (i32.const 116)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 1))) (i32.const 114)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 2))) (i32.const 117)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 3))) (i32.const 101)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (if (i32.ne (i32.load8_u (i32.add (local.get $s) (i32.const 4))) (i32.const 0)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (i64.extend_i32_s (i32.const 1)))
  ;; Phase 36: str_replace s old new — replace all non-overlapping occurrences
  (func $__lang_str_replace (param $s8 i64) (param $old8 i64) (param $new8 i64) (result i64)
    (local $slen i32) (local $olen i32) (local $nlen i32)
    (local $r i32) (local $bi i32) (local $i i32) (local $j i32) (local $match i32)
    (local $s i32)
    (local $old i32)
    (local $new i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $old (i32.wrap_i64 (local.get $old8)))
    (local.set $new (i32.wrap_i64 (local.get $new8)))
    (local.set $olen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $old)))))
    (if (i32.eqz (local.get $olen)) (then (return (i64.extend_i32_s (local.get $s)))))
    (local.set $slen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $nlen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $new)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $bi (i32.const 0))
    (local.set $i (i32.const 0))
    (block $end_outer
      (loop $lp_outer
        (br_if $end_outer (i32.ge_s (local.get $i) (local.get $slen)))
        ;; check if remainder fits old
        (if (i32.le_s (i32.add (local.get $i) (local.get $olen)) (local.get $slen))
          (then
            (local.set $j (i32.const 0))
            (local.set $match (i32.const 1))
            (block $end_inner
              (loop $lp_inner
                (br_if $end_inner (i32.eq (local.get $j) (local.get $olen)))
                (if (i32.ne (i32.load8_u (i32.add (local.get $s)
                                                  (i32.add (local.get $i) (local.get $j))))
                            (i32.load8_u (i32.add (local.get $old) (local.get $j))))
                  (then (local.set $match (i32.const 0)) (br $end_inner)))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $lp_inner)))
            (if (local.get $match)
              (then
                ;; copy new
                (local.set $j (i32.const 0))
                (block $end_cn
                  (loop $lp_cn
                    (br_if $end_cn (i32.eq (local.get $j) (local.get $nlen)))
                    (i32.store8 (i32.add (local.get $r) (i32.add (local.get $bi) (local.get $j)))
                                (i32.load8_u (i32.add (local.get $new) (local.get $j))))
                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $lp_cn)))
                (local.set $bi (i32.add (local.get $bi) (local.get $nlen)))
                (local.set $i (i32.add (local.get $i) (local.get $olen)))
                (br $lp_outer)))))
        ;; no match — copy one char
        (i32.store8 (i32.add (local.get $r) (local.get $bi))
                    (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (local.set $bi (i32.add (local.get $bi) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i32.store8 (i32.add (local.get $r) (local.get $bi)) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (local.get $bi)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 26.1/26.2: fail msg — if a try_or scope is active, set the
  ;; failure flag and return 0 (the caller's expected result type is i32
  ;; for everything in Wasm). Otherwise print + trap. The flag /
  ;; active-counter globals are declared at module level.
  (func $__lang_fail (param $msg8 i64) (result i64)
    (local $msg i32)
    (local.set $msg (i32.wrap_i64 (local.get $msg8)))
    (if (global.get $__lang_fail_active)
      (then
        (global.set $__lang_fail_flag (i32.const 1))
        (return (i64.extend_i32_s (i32.const 0)))))
    (call $puts_h (local.get $msg))
    (unreachable))
  ;; Phase 26.1: char_at s i — return pointer to a single-byte string
  ;; (preallocated 256-entry static char_table). Mirrors C/LLVM.
  ;; The table itself is set up at module-init by storing 256 pairs of
  ;; (char, \0) starting at the global offset $__lang_char_table.
  (func $__lang_char_at_setup
    (local $k i32) (local $base i32)
    (if (i32.eqz (global.get $__lang_char_table_initialized))
      (then
        (global.set $__lang_char_table_initialized (i32.const 1))
        (local.set $base (global.get $__lang_char_table))
        (local.set $k (i32.const 0))
        (block $end
          (loop $lp
            (br_if $end (i32.eq (local.get $k) (i32.const 256)))
            ;; byte-safe entry: stride 6 = [i32 len=1][char][NUL]; the str
            ;; pointer returned is base + k*6 + 4 (header at base + k*6).
            (i32.store   (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 6)))
                         (i32.const 1))
            (i32.store8 (i32.add (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 6))) (i32.const 4))
                        (local.get $k))
            (i32.store8 (i32.add (i32.add (local.get $base) (i32.mul (local.get $k) (i32.const 6))) (i32.const 5))
                        (i32.const 0))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br $lp))))))
  (func $__lang_char_at (param $s8 i64) (param $i8 i64) (result i64)
    (local $s i32)
    (local $i i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $i (i32.wrap_i64 (local.get $i8)))
    (call $__lang_char_at_setup)
    (i64.extend_i32_s (i32.add (i32.add (global.get $__lang_char_table)
             (i32.mul (i32.load8_u (i32.add (local.get $s) (local.get $i))) (i32.const 6))) (i32.const 4))))
  (func $__lang_is_digit (param $s8 i64) (result i64)
    (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $c (i32.load8_u (local.get $s)))
    (i64.extend_i32_s (i32.and (i32.ge_s (local.get $c) (i32.const 48))
             (i32.le_s (local.get $c) (i32.const 57)))))
  (func $__lang_is_alpha (param $s8 i64) (result i64)
    (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $c (i32.load8_u (local.get $s)))
    (i64.extend_i32_s (i32.or
      (i32.and (i32.ge_s (local.get $c) (i32.const 97))
               (i32.le_s (local.get $c) (i32.const 122)))
      (i32.and (i32.ge_s (local.get $c) (i32.const 65))
               (i32.le_s (local.get $c) (i32.const 90))))))
  (func $__lang_is_space (param $s8 i64) (result i64)
    (local $c i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $c (i32.load8_u (local.get $s)))
    (i64.extend_i32_s (i32.or
      (i32.or (i32.eq (local.get $c) (i32.const 32))
              (i32.eq (local.get $c) (i32.const 9)))
      (i32.or (i32.eq (local.get $c) (i32.const 10))
              (i32.eq (local.get $c) (i32.const 13))))))
  ;; Phase 26.1: substring s start end_ — region alloc + memcpy.
  (func $__lang_substring (param $s8 i64) (param $start8 i64) (param $end_8 i64) (result i64)
    (local $len i32) (local $r i32) (local $i i32)
    (local $s i32)
    (local $start i32)
    (local $end_ i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $start (i32.wrap_i64 (local.get $start8)))
    (local.set $end_ (i32.wrap_i64 (local.get $end_8)))
    (local.set $len (i32.sub (local.get $end_) (local.get $start)))
    (if (i32.lt_s (local.get $len) (i32.const 0))
      (then (local.set $len (i32.const 0))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (i32.store8 (i32.add (local.get $r) (local.get $i))
                    (i32.load8_u (i32.add (local.get $s)
                                          (i32.add (local.get $start) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $len)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $len)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; v0.1.60: int_of_str s msg — strict decimal parse
  ;; (WS* [+-]? DIGIT+ WS*); anything else calls $__lang_fail with the
  ;; interned msg (try_or-able), matching the interpreter instead of the
  ;; old atoi semantics that silently returned 0 / a partial prefix.
  (func $__lang_int_of_str (param $s8 i64) (param $msg i64) (result i64)
    (local $s i32)
    (local $i i32) (local $sign i64) (local $acc i64) (local $c i32)
    (local $nd i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $i (i32.const 0))
    (local.set $sign (i64.const 1))
    (local.set $acc (i64.const 0))
    (local.set $nd (i32.const 0))
    (block $lead_done                       ;; skip leading whitespace
      (loop $lead
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (br_if $lead_done (i32.eqz (i32.or (i32.or
          (i32.eq (local.get $c) (i32.const 32))
          (i32.eq (local.get $c) (i32.const 9)))
          (i32.or
            (i32.eq (local.get $c) (i32.const 13))
            (i32.eq (local.get $c) (i32.const 10))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lead)))
    (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
    (if (i32.eq (local.get $c) (i32.const 45))  ;; '-'
      (then
        (local.set $sign (i64.const -1))
        (local.set $i (i32.add (local.get $i) (i32.const 1))))
      (else
        (if (i32.eq (local.get $c) (i32.const 43))  ;; '+'
          (then (local.set $i (i32.add (local.get $i) (i32.const 1)))))))
    (block $end
      (loop $lp
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (br_if $end (i32.or
          (i32.lt_s (local.get $c) (i32.const 48))
          (i32.gt_s (local.get $c) (i32.const 57))))
        (local.set $acc (i64.add
          (i64.mul (local.get $acc) (i64.const 10))
          (i64.extend_i32_s (i32.sub (local.get $c) (i32.const 48)))))
        (local.set $nd (i32.add (local.get $nd) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (block $trail_done                      ;; skip trailing whitespace
      (loop $trail
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (br_if $trail_done (i32.eqz (i32.or (i32.or
          (i32.eq (local.get $c) (i32.const 32))
          (i32.eq (local.get $c) (i32.const 9)))
          (i32.or
            (i32.eq (local.get $c) (i32.const 13))
            (i32.eq (local.get $c) (i32.const 10))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $trail)))
    (if (i32.or
          (i32.eqz (local.get $nd))          ;; no digits
          (i32.ne (local.get $c) (i32.const 0)))  ;; junk after
      (then
        (drop (call $__lang_fail (local.get $msg)))
        (return (i64.const 0))))
    (i64.mul (local.get $acc) (local.get $sign)))
  ;; Phase 26.1: str_unescape s — replace backslash-escape sequences
  ;; (\n, \t, \r, \\ , \", \/) with the actual byte. Region-allocated.
  (func $__lang_str_unescape (param $s8 i64) (result i64)
    (local $n i32) (local $r i32) (local $i i32) (local $j i32)
    (local $c i32) (local $ec i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (local.set $j (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (if (i32.and
              (i32.eq (local.get $c) (i32.const 92))  ;; '\\'
              (i32.lt_s (i32.add (local.get $i) (i32.const 1)) (local.get $n)))
          (then
            (local.set $ec (i32.load8_u (i32.add (local.get $s) (i32.add (local.get $i) (i32.const 1)))))
            (if (i32.eq (local.get $ec) (i32.const 110))      ;; 'n'
              (then (local.set $ec (i32.const 10)))
              (else (if (i32.eq (local.get $ec) (i32.const 116))  ;; 't'
                (then (local.set $ec (i32.const 9)))
                (else (if (i32.eq (local.get $ec) (i32.const 114))  ;; 'r'
                  (then (local.set $ec (i32.const 13))))))))
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $ec))
            (local.set $i (i32.add (local.get $i) (i32.const 2)))
            (local.set $j (i32.add (local.get $j) (i32.const 1))))
          (else
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $c))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $j)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $j)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; Phase 26.6: str_escape s — backslash-escape newline / tab / cr / backslash
  ;; / quote. show_str pipes through this so output matches interp. Worst-case
  ;; 2x byte expansion, region-allocated.
  (func $__lang_str_escape (param $s8 i64) (result i64)
    (local $n i32) (local $r i32) (local $i i32) (local $j i32) (local $c i32) (local $ec i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (local.set $j (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        ;; if c is special (10/9/13/92/34), emit backslash + replacement
        (if (i32.or
              (i32.or (i32.eq (local.get $c) (i32.const 10))
                      (i32.eq (local.get $c) (i32.const 9)))
              (i32.or (i32.or (i32.eq (local.get $c) (i32.const 13))
                              (i32.eq (local.get $c) (i32.const 92)))
                      (i32.eq (local.get $c) (i32.const 34))))
          (then
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (i32.const 92))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (local.set $ec (local.get $c))
            (if (i32.eq (local.get $c) (i32.const 10))
              (then (local.set $ec (i32.const 110))))
            (if (i32.eq (local.get $c) (i32.const 9))
              (then (local.set $ec (i32.const 116))))
            (if (i32.eq (local.get $c) (i32.const 13))
              (then (local.set $ec (i32.const 114))))
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $ec)))
          (else
            (i32.store8 (i32.add (local.get $r) (local.get $j)) (local.get $c))))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $j)) (i32.const 0))
    (global.set $__lang_bump
      (i32.add (i32.add (local.get $r) (local.get $j)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))|}

(* Phase 26.5: list_str cell builders + str_split / str_join / str_count.
   Cells layout (Phase 26.0 boxed): {i32 tag, i32 payload_ptr}. For Cons,
   payload_ptr points to a 2-word tuple {str_ptr, list_str_ptr}. *)
let list_str_runtime_wasm = {|
  (func $__lang_list_str_nil (result i64)
    (local $p i32)
    (local.set $p (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 16)))
    (i64.store offset=0 (local.get $p) (i64.const 0))
    (i64.extend_i32_u (local.get $p)))
  (func $__lang_list_str_cons (param $head i64) (param $tail i64) (result i64)
    (local $p i32) (local $box i32)
    ;; Tuple payload box: 16 bytes (str value + list value, 8-byte slots).
    (local.set $box (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $box) (i32.const 16)))
    (i64.store offset=0 (local.get $box) (local.get $head))
    (i64.store offset=8 (local.get $box) (local.get $tail))
    ;; Cons cell: 16 bytes (tag=1 + payload value).
    (local.set $p (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 16)))
    (i64.store offset=0 (local.get $p) (i64.const 1))
    (i64.store offset=8 (local.get $p) (i64.extend_i32_u (local.get $box)))
    (i64.extend_i32_u (local.get $p)))
  ;; list back-to-front by scanning for sequence starts from the end.
  (func $__lang_utf8_len (param $s8 i64) (result i64)
    (local $n i32) (local $i i32) (local $c i32) (local $b i32) (local $l i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $i (i32.const 0))
    (local.set $c (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $b (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (local.set $l
          (if (result i32) (i32.lt_u (local.get $b) (i32.const 128))
            (then (i32.const 1))
            (else (if (result i32) (i32.and (i32.ge_u (local.get $b) (i32.const 192)) (i32.le_u (local.get $b) (i32.const 223)))
              (then (i32.const 2))
              (else (if (result i32) (i32.and (i32.ge_u (local.get $b) (i32.const 224)) (i32.le_u (local.get $b) (i32.const 239)))
                (then (i32.const 3))
                (else (if (result i32) (i32.and (i32.ge_u (local.get $b) (i32.const 240)) (i32.le_u (local.get $b) (i32.const 247)))
                  (then (i32.const 4))
                  (else (i32.const 1))))))))))
        (if (i32.gt_s (local.get $l) (i32.sub (local.get $n) (local.get $i)))
          (then (local.set $l (i32.sub (local.get $n) (local.get $i)))))
        (local.set $i (i32.add (local.get $i) (local.get $l)))
        (local.set $c (i32.add (local.get $c) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (local.get $c)))
  (func $__lang_utf8_chars (param $s8 i64) (result i64)
    (local $n i32) (local $end i32) (local $st i32) (local $l i32)
    (local $tok i32) (local $j i32) (local $acc i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $acc (i32.wrap_i64 (call $__lang_list_str_nil)))
    (local.set $end (local.get $n))
    (block $done
      (loop $outer
        (br_if $done (i32.le_s (local.get $end) (i32.const 0)))
        ;; scan backward to this character's lead byte
        (local.set $st (i32.sub (local.get $end) (i32.const 1)))
        (block $found
          (loop $back
            (br_if $found (i32.le_s (local.get $st) (i32.const 0)))
            (br_if $found
              (i32.ne (i32.and (i32.load8_u (i32.add (local.get $s) (local.get $st))) (i32.const 192))
                      (i32.const 128)))
            (local.set $st (i32.sub (local.get $st) (i32.const 1)))
            (br $back)))
        (local.set $l (i32.sub (local.get $end) (local.get $st)))
        ;; copy the char bytes into a fresh NUL-terminated str
        (local.set $tok (i32.add (global.get $__lang_bump) (i32.const 4)))
        (global.set $__lang_bump (i32.add (i32.add (local.get $tok) (local.get $l)) (i32.const 1)))
        (i32.store (i32.sub (local.get $tok) (i32.const 4)) (local.get $l))
        (local.set $j (i32.const 0))
        (block $cend
          (loop $clp
            (br_if $cend (i32.ge_s (local.get $j) (local.get $l)))
            (i32.store8 (i32.add (local.get $tok) (local.get $j))
                        (i32.load8_u (i32.add (i32.add (local.get $s) (local.get $st)) (local.get $j))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $clp)))
        (i32.store8 (i32.add (local.get $tok) (local.get $l)) (i32.const 0))
        (local.set $acc (i32.wrap_i64 (call $__lang_list_str_cons (i64.extend_i32_s (local.get $tok)) (i64.extend_i32_s (local.get $acc)))))
        (local.set $end (local.get $st))
        (br $outer)))
    (i64.extend_i32_s (local.get $acc)))
  ;; str_split s delim — 2-pass: count tokens, then build list back-to-front.
  (func $__lang_str_split (param $s8 i64) (param $delim8 i64) (result i64)
    (local $sl i32) (local $dl i32) (local $i i32) (local $cnt i32)
    (local $starts i32) (local $lens i32) (local $tstart i32) (local $tidx i32)
    (local $tlen i32) (local $tk i32) (local $j i32) (local $match i32)
    (local $nil i32) (local $tail i32) (local $bi i32) (local $b_off i32)
    (local $s i32)
    (local $delim i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $delim (i32.wrap_i64 (local.get $delim8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $dl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $delim)))))
    ;; Empty delim: return Cons(s, Nil) (matches interp / C / LLVM).
    (if (i32.eqz (local.get $dl))
      (then
        (local.set $nil (i32.wrap_i64 (call $__lang_list_str_nil)))
        (return (call $__lang_list_str_cons (i64.extend_i32_s (local.get $s)) (i64.extend_i32_s (local.get $nil))))))
    ;; Pass 1: count delim occurrences (non-overlapping).
    (local.set $i (i32.const 0))
    (local.set $cnt (i32.const 0))
    (block $end_c
      (loop $lp_c
        (br_if $end_c
               (i32.gt_s (i32.add (local.get $i) (local.get $dl))
                         (local.get $sl)))
        ;; Compare delim bytes.
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $dl)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $s)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $delim) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (if (local.get $match)
          (then
            (local.set $cnt (i32.add (local.get $cnt) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (local.get $dl))))
          (else
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $lp_c)))
    ;; Allocate parallel (start, len) arrays — n = cnt + 1 tokens.
    (local.set $starts (global.get $__lang_bump))
    (global.set $__lang_bump
      (i32.add (global.get $__lang_bump)
               (i32.mul (i32.add (local.get $cnt) (i32.const 1)) (i32.const 4))))
    (local.set $lens (global.get $__lang_bump))
    (global.set $__lang_bump
      (i32.add (global.get $__lang_bump)
               (i32.mul (i32.add (local.get $cnt) (i32.const 1)) (i32.const 4))))
    ;; Pass 2: extract tokens into (start, len) arrays.
    (local.set $i (i32.const 0))
    (local.set $tstart (i32.const 0))
    (local.set $tidx (i32.const 0))
    (block $end_f
      (loop $lp_f
        (br_if $end_f
               (i32.gt_s (i32.add (local.get $i) (local.get $dl))
                         (local.get $sl)))
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner2
          (loop $lp_inner2
            (br_if $end_inner2 (i32.eq (local.get $j) (local.get $dl)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $s)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $delim) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner2)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner2)))
        (if (local.get $match)
          (then
            (i32.store
              (i32.add (local.get $starts) (i32.mul (local.get $tidx) (i32.const 4)))
              (local.get $tstart))
            (i32.store
              (i32.add (local.get $lens) (i32.mul (local.get $tidx) (i32.const 4)))
              (i32.sub (local.get $i) (local.get $tstart)))
            (local.set $tidx (i32.add (local.get $tidx) (i32.const 1)))
            (local.set $tstart (i32.add (local.get $i) (local.get $dl)))
            (local.set $i (i32.add (local.get $i) (local.get $dl))))
          (else
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $lp_f)))
    ;; Last token: (tstart, sl - tstart) at index $tidx.
    (i32.store
      (i32.add (local.get $starts) (i32.mul (local.get $tidx) (i32.const 4)))
      (local.get $tstart))
    (i32.store
      (i32.add (local.get $lens) (i32.mul (local.get $tidx) (i32.const 4)))
      (i32.sub (local.get $sl) (local.get $tstart)))
    ;; Build Cons list back-to-front from index $cnt down to 0.
    (local.set $nil (i32.wrap_i64 (call $__lang_list_str_nil)))
    (local.set $tail (local.get $nil))
    (local.set $bi (local.get $cnt))
    (block $end_b
      (loop $lp_b
        (local.set $b_off (i32.mul (local.get $bi) (i32.const 4)))
        (local.set $tstart (i32.load (i32.add (local.get $starts) (local.get $b_off))))
        (local.set $tlen (i32.load (i32.add (local.get $lens) (local.get $b_off))))
        (local.set $tk (i32.add (global.get $__lang_bump) (i32.const 4)))
        (global.set $__lang_bump
          (i32.add (local.get $tk) (i32.add (local.get $tlen) (i32.const 1))))
        (i32.store (i32.sub (local.get $tk) (i32.const 4)) (local.get $tlen))
        ;; memcpy
        (local.set $j (i32.const 0))
        (block $end_cp
          (loop $lp_cp
            (br_if $end_cp (i32.eq (local.get $j) (local.get $tlen)))
            (i32.store8
              (i32.add (local.get $tk) (local.get $j))
              (i32.load8_u (i32.add (local.get $s)
                                    (i32.add (local.get $tstart) (local.get $j)))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_cp)))
        (i32.store8 (i32.add (local.get $tk) (local.get $tlen)) (i32.const 0))
        (local.set $tail (i32.wrap_i64 (call $__lang_list_str_cons (i64.extend_i32_s (local.get $tk)) (i64.extend_i32_s (local.get $tail)))))
        (br_if $end_b (i32.eqz (local.get $bi)))
        (local.set $bi (i32.sub (local.get $bi) (i32.const 1)))
        (br $lp_b)))
    (i64.extend_i32_s (local.get $tail)))
  ;; str_join sep xs — walk list_str, concat with sep.
  (func $__lang_str_join (param $sep8 i64) (param $xs8 i64) (result i64)
    (local $sl i32) (local $cur i32) (local $box i32) (local $head i32)
    (local $total i32) (local $first i32) (local $r i32) (local $pos i32)
    (local $hl i32)
    (local $sep i32)
    (local $xs i32)
    (local.set $sep (i32.wrap_i64 (local.get $sep8)))
    (local.set $xs (i32.wrap_i64 (local.get $xs8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $sep)))))
    ;; Pass 1: total length.
    (local.set $cur (local.get $xs))
    (local.set $total (i32.const 0))
    (local.set $first (i32.const 1))
    (block $end_len
      (loop $lp_len
        (br_if $end_len (i64.eqz (i64.load offset=0 (local.get $cur))))
        (local.set $box (i32.wrap_i64 (i64.load offset=8 (local.get $cur))))
        (local.set $head (i32.wrap_i64 (i64.load offset=0 (local.get $box))))
        (if (i32.eqz (local.get $first))
          (then (local.set $total (i32.add (local.get $total) (local.get $sl)))))
        (local.set $total
          (i32.add (local.get $total)
                   (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $head))))))
        (local.set $first (i32.const 0))
        (local.set $cur (i32.wrap_i64 (i64.load offset=8 (local.get $box))))
        (br $lp_len)))
    ;; Allocate result + null terminator.
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (global.set $__lang_bump
      (i32.add (local.get $r) (i32.add (local.get $total) (i32.const 1))))
    ;; Pass 2: write.
    (local.set $cur (local.get $xs))
    (local.set $pos (i32.const 0))
    (local.set $first (i32.const 1))
    (block $end_w
      (loop $lp_w
        (br_if $end_w (i64.eqz (i64.load offset=0 (local.get $cur))))
        (local.set $box (i32.wrap_i64 (i64.load offset=8 (local.get $cur))))
        (local.set $head (i32.wrap_i64 (i64.load offset=0 (local.get $box))))
        (if (i32.eqz (local.get $first))
          (then
            ;; memcpy sep.
            (local.set $hl (i32.const 0))
            (block $end_cs
              (loop $lp_cs
                (br_if $end_cs (i32.eq (local.get $hl) (local.get $sl)))
                (i32.store8
                  (i32.add (local.get $r) (i32.add (local.get $pos) (local.get $hl)))
                  (i32.load8_u (i32.add (local.get $sep) (local.get $hl))))
                (local.set $hl (i32.add (local.get $hl) (i32.const 1)))
                (br $lp_cs)))
            (local.set $pos (i32.add (local.get $pos) (local.get $sl)))))
        ;; memcpy head.
        (local.set $hl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $head)))))
        (local.set $first (i32.const 0))
        (block $end_ch
          (local.set $first (i32.const 0))
          (loop $lp_ch
            (local.tee $first (i32.const 0))
            (drop)
            (br_if $end_ch (i32.eqz (local.get $hl)))
            (i32.store8
              (i32.add (local.get $r) (local.get $pos))
              (i32.load8_u (local.get $head)))
            (local.set $head (i32.add (local.get $head) (i32.const 1)))
            (local.set $pos (i32.add (local.get $pos) (i32.const 1)))
            (local.set $hl (i32.sub (local.get $hl) (i32.const 1)))
            (br $lp_ch)))
        (local.set $first (i32.const 0))
        (local.set $cur (i32.wrap_i64 (i64.load offset=8 (local.get $box))))
        (br $lp_w)))
    (i32.store8 (i32.add (local.get $r) (local.get $total)) (i32.const 0))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  ;; str_count s n — non-overlapping count of n in s.
  (func $__lang_str_count (param $s8 i64) (param $n8 i64) (result i64)
    (local $sl i32) (local $nl i32) (local $i i32) (local $j i32)
    (local $acc i32) (local $match i32)
    (local $s i32)
    (local $n i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (local.get $n8)))
    (local.set $sl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $nl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $n)))))
    (if (i32.eqz (local.get $nl)) (then (return (i64.extend_i32_s (i32.const 0)))))
    (local.set $i (i32.const 0))
    (local.set $acc (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end
               (i32.gt_s (i32.add (local.get $i) (local.get $nl))
                         (local.get $sl)))
        (local.set $j (i32.const 0))
        (local.set $match (i32.const 1))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.eq (local.get $j) (local.get $nl)))
            (if (i32.ne
                  (i32.load8_u (i32.add (local.get $s)
                                        (i32.add (local.get $i) (local.get $j))))
                  (i32.load8_u (i32.add (local.get $n) (local.get $j))))
              (then (local.set $match (i32.const 0)) (br $end_inner)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        (if (local.get $match)
          (then
            (local.set $acc (i32.add (local.get $acc) (i32.const 1)))
            (local.set $i (i32.add (local.get $i) (local.get $nl))))
          (else
            (local.set $i (i32.add (local.get $i) (i32.const 1)))))
        (br $lp)))
    (i64.extend_i32_s (local.get $acc)))|}

(* Phase 15.4: Vec[R, T] runtime — all element types share one
   implementation because every Mere value lowers to a 4-byte i32 in
   Wasm (scalars direct, structured types are memory offsets).
   Layout: 16 bytes per vec — { data_ptr:i32, len:i32, cap:i32, _pad:i32 }.
   `_pad` keeps the struct 16-byte-aligned (matches C / LLVM layout).
   Push reallocates by appending a fresh buffer at the bump pointer
   (arena semantics — old buffers leak until process exit). *)
let vec_runtime = {|
  (func $mere_vec_new (result i64)
    (local $v i32) (local $buf i32)
    (local.set $v (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $v) (i32.const 16)))
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $buf) (i32.const 32)))
    (i32.store offset=0 (local.get $v) (local.get $buf))
    (i32.store offset=4 (local.get $v) (i32.const 0))
    (i32.store offset=8 (local.get $v) (i32.const 4))
    (i64.extend_i32_s (local.get $v)))
  (func $mere_vec_push (param $v8 i64) (param $x i64) (result i64)
    (local $len i32) (local $cap i32) (local $buf i32)
    (local $new_buf i32) (local $i i32)
    (local $v i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $cap (i32.load offset=8 (local.get $v)))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_buf (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_buf)
                   (i32.mul (local.get $cap) (i32.const 8))))
        (local.set $buf (i32.load offset=0 (local.get $v)))
        (local.set $i (i32.const 0))
        (block $copy_end
          (loop $copy_lp
            (br_if $copy_end (i32.eq (local.get $i) (local.get $len)))
            (i64.store
              (i32.add (local.get $new_buf)
                       (i32.mul (local.get $i) (i32.const 8)))
              (i64.load
                (i32.add (local.get $buf)
                         (i32.mul (local.get $i) (i32.const 8)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $copy_lp)))
        (i32.store offset=0 (local.get $v) (local.get $new_buf))
        (i32.store offset=8 (local.get $v) (local.get $cap))))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i64.store
      (i32.add (local.get $buf)
               (i32.mul (local.get $len) (i32.const 8)))
      (local.get $x))
    (i32.store offset=4 (local.get $v) (i32.add (local.get $len) (i32.const 1)))
    (i64.extend_i32_s (i32.const 0)))
  (func $mere_vec_get (param $v8 i64) (param $i8 i64) (result i64)
    (local $len i32) (local $buf i32)
    (local $v i32)
    (local $i i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $i (i32.wrap_i64 (local.get $i8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (local.get $len)))
      (then (unreachable)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i64.load
      (i32.add (local.get $buf)
               (i32.mul (local.get $i) (i32.const 8)))))
  (func $mere_vec_len (param $v8 i64) (result i64)
    (local $v i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (i64.extend_i32_s (i32.load offset=4 (local.get $v))))
  (func $mere_vec_set (param $v8 i64) (param $i8 i64) (param $x i64) (result i64)
    (local $len i32) (local $buf i32)
    (local $v i32)
    (local $i i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $i (i32.wrap_i64 (local.get $i8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (local.get $len)))
      (then (unreachable)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (i64.store
      (i32.add (local.get $buf) (i32.mul (local.get $i) (i32.const 8)))
      (local.get $x))
    (i64.extend_i32_s (i32.const 0)))
  ;; Phase 15.7: OwnedVec helpers — in Wasm all values are i32 and the
  ;; bump allocator is also shared, so the runtime representations of Vec
  ;; and OwnedVec are the same. owned_vec_* aliases as a thin wrapper to
  ;; $mere_vec_*. Deep copy (vec_to_owned / owned_vec_to_vec) uses $mere_vec_clone.
  (func $mere_vec_clone (param $src8 i64) (result i64)
    (local $new i32) (local $i i32) (local $len i32) (local $buf i32)
    (local $src i32)
    (local.set $src (i32.wrap_i64 (local.get $src8)))
    (local.set $new (i32.wrap_i64 (call $mere_vec_new)))
    (local.set $len (i32.load offset=4 (local.get $src)))
    (local.set $buf (i32.load offset=0 (local.get $src)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (drop (i32.wrap_i64 (call $mere_vec_push (i64.extend_i32_s (local.get $new)) (i64.load (i32.add (local.get $buf)
                                    (i32.mul (local.get $i) (i32.const 8)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (local.get $new)))
  ;; Phase 19.3: vec_reverse — in-place swap, returns 0 (unit).
  (func $mere_vec_reverse (param $v8 i64) (result i64)
    (local $lo i32) (local $hi i32) (local $buf i32) (local $tmp i64)
    (local $v i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $lo (i32.const 0))
    (local.set $hi (i32.sub (i32.load offset=4 (local.get $v)) (i32.const 1)))
    (block $end
      (loop $lp
        (br_if $end (i32.ge_s (local.get $lo) (local.get $hi)))
        (local.set $tmp (i64.load
          (i32.add (local.get $buf) (i32.mul (local.get $lo) (i32.const 8)))))
        (i64.store
          (i32.add (local.get $buf) (i32.mul (local.get $lo) (i32.const 8)))
          (i64.load (i32.add (local.get $buf)
                             (i32.mul (local.get $hi) (i32.const 8)))))
        (i64.store
          (i32.add (local.get $buf) (i32.mul (local.get $hi) (i32.const 8)))
          (local.get $tmp))
        (local.set $lo (i32.add (local.get $lo) (i32.const 1)))
        (local.set $hi (i32.sub (local.get $hi) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_s (i32.const 0)))
  ;; Phase 19.3: vec_sort — in-place insertion sort.
  ;; cmp: closure_T_(closure_T_int). outer_fn(env, a) → inner closure_T_int,
  ;; inner_fn(inner.env, b) → i32 (negative/0/positive).
  (func $mere_vec_sort (param $v8 i64) (param $cmp i64) (result i64)
    (local $i i32) (local $j i32) (local $len i32) (local $buf i32)
    (local $outer_env i32) (local $outer_fn i32)
    (local $key i64) (local $j_val i64)
    (local $inner_cl i32) (local $inner_env i32) (local $inner_fn i32)
    (local $cmp_res i64)
    (local $v i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $outer_env (i32.load offset=0 (i32.wrap_i64 (local.get $cmp))))
    (local.set $outer_fn  (i32.load offset=4 (i32.wrap_i64 (local.get $cmp))))
    (local.set $i (i32.const 1))
    (block $end_outer
      (loop $lp_outer
        (br_if $end_outer (i32.ge_s (local.get $i) (local.get $len)))
        (local.set $key (i64.load
          (i32.add (local.get $buf) (i32.mul (local.get $i) (i32.const 8)))))
        (local.set $j (i32.sub (local.get $i) (i32.const 1)))
        (block $end_inner
          (loop $lp_inner
            (br_if $end_inner (i32.lt_s (local.get $j) (i32.const 0)))
            (local.set $j_val (i64.load
              (i32.add (local.get $buf) (i32.mul (local.get $j) (i32.const 8)))))
            (local.set $inner_cl (i32.wrap_i64
              (call_indirect (type $cl)
                (i64.extend_i32_u (local.get $outer_env)) (local.get $j_val)
                (local.get $outer_fn))))
            (local.set $inner_env (i32.load offset=0 (local.get $inner_cl)))
            (local.set $inner_fn  (i32.load offset=4 (local.get $inner_cl)))
            (local.set $cmp_res
              (call_indirect (type $cl)
                (i64.extend_i32_u (local.get $inner_env)) (local.get $key)
                (local.get $inner_fn)))
            (br_if $end_inner (i64.le_s (local.get $cmp_res) (i64.const 0)))
            ;; shift: data[j+1] = data[j]
            (i64.store
              (i32.add (local.get $buf)
                       (i32.mul (i32.add (local.get $j) (i32.const 1))
                                (i32.const 8)))
              (local.get $j_val))
            (local.set $j (i32.sub (local.get $j) (i32.const 1)))
            (br $lp_inner)))
        ;; place key at j+1
        (i64.store
          (i32.add (local.get $buf)
                   (i32.mul (i32.add (local.get $j) (i32.const 1))
                            (i32.const 8)))
          (local.get $key))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_outer)))
    (i64.const 0))
  (func $mere_vec_concat (param $a8 i64) (param $b8 i64) (result i64)
    (local $new i32) (local $i i32) (local $alen i32) (local $blen i32)
    (local $abuf i32) (local $bbuf i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $new (i32.wrap_i64 (call $mere_vec_new)))
    (local.set $alen (i32.load offset=4 (local.get $a)))
    (local.set $blen (i32.load offset=4 (local.get $b)))
    (local.set $abuf (i32.load offset=0 (local.get $a)))
    (local.set $bbuf (i32.load offset=0 (local.get $b)))
    (local.set $i (i32.const 0))
    (block $end_a
      (loop $lp_a
        (br_if $end_a (i32.eq (local.get $i) (local.get $alen)))
        (drop (i32.wrap_i64 (call $mere_vec_push (i64.extend_i32_s (local.get $new)) (i64.extend_i32_s (i32.load (i32.add (local.get $abuf)
                                   (i32.mul (local.get $i) (i32.const 8))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_a)))
    (local.set $i (i32.const 0))
    (block $end_b
      (loop $lp_b
        (br_if $end_b (i32.eq (local.get $i) (local.get $blen)))
        (drop (i32.wrap_i64 (call $mere_vec_push (i64.extend_i32_s (local.get $new)) (i64.extend_i32_s (i32.load (i32.add (local.get $bbuf)
                                   (i32.mul (local.get $i) (i32.const 8))))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp_b)))
    (i64.extend_i32_s (local.get $new)))|}

(* Phase 15.5: vec_iter / vec_fold helpers. References (type $cl) and
   uses call_indirect, so the module must declare a funcref table when
   this block is emitted (even if no closure entries exist). *)
let vec_higher_order_runtime = {|
  (func $mere_vec_iter (param $v8 i64) (param $cl8 i64) (result i64)
    (local $i i32) (local $len i32) (local $buf i32)
    (local $env i32) (local $fn i32) (local $v i32) (local $cl i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $cl (i32.wrap_i64 (local.get $cl8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $env (i32.load offset=0 (local.get $cl)))
    (local.set $fn (i32.load offset=4 (local.get $cl)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (drop
          (call_indirect (type $cl)
            (i64.extend_i32_u (local.get $env))
            (i64.load (i32.add (local.get $buf)
                               (i32.mul (local.get $i) (i32.const 8))))
            (local.get $fn)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.const 0))
  (func $mere_vec_fold (param $v8 i64) (param $init_acc i64) (param $outer_cl8 i64) (result i64)
    (local $i i32) (local $len i32) (local $buf i32) (local $acc i64)
    (local $outer_env i32) (local $outer_fn i32) (local $v i32) (local $outer_cl i32)
    (local $inner_cl i32) (local $inner_env i32) (local $inner_fn i32) (local $elem i64)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $outer_cl (i32.wrap_i64 (local.get $outer_cl8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $outer_env (i32.load offset=0 (local.get $outer_cl)))
    (local.set $outer_fn (i32.load offset=4 (local.get $outer_cl)))
    (local.set $acc (local.get $init_acc))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (local.set $elem
          (i64.load (i32.add (local.get $buf)
                             (i32.mul (local.get $i) (i32.const 8)))))
        ;; inner = outer(env, acc)
        (local.set $inner_cl (i32.wrap_i64
          (call_indirect (type $cl)
            (i64.extend_i32_u (local.get $outer_env))
            (local.get $acc)
            (local.get $outer_fn))))
        (local.set $inner_env (i32.load offset=0 (local.get $inner_cl)))
        (local.set $inner_fn (i32.load offset=4 (local.get $inner_cl)))
        ;; acc = inner(inner_env, elem)
        (local.set $acc
          (call_indirect (type $cl)
            (i64.extend_i32_u (local.get $inner_env))
            (local.get $elem)
            (local.get $inner_fn)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (local.get $acc))
  (func $mere_vec_map (param $v8 i64) (param $cl8 i64) (result i64)
    (local $new i32) (local $i i32) (local $len i32) (local $buf i32)
    (local $env i32) (local $fn i32) (local $mapped i64) (local $v i32) (local $cl i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $cl (i32.wrap_i64 (local.get $cl8)))
    (local.set $new (i32.wrap_i64 (call $mere_vec_new)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $env (i32.load offset=0 (local.get $cl)))
    (local.set $fn (i32.load offset=4 (local.get $cl)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (local.set $mapped
          (call_indirect (type $cl)
            (i64.extend_i32_u (local.get $env))
            (i64.load (i32.add (local.get $buf)
                               (i32.mul (local.get $i) (i32.const 8))))
            (local.get $fn)))
        (drop (call $mere_vec_push (i64.extend_i32_u (local.get $new)) (local.get $mapped)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_u (local.get $new)))
  (func $mere_vec_filter (param $v8 i64) (param $cl8 i64) (result i64)
    (local $new i32) (local $i i32) (local $len i32) (local $buf i32)
    (local $env i32) (local $fn i32) (local $elem i64) (local $keep i64)
    (local $v i32) (local $cl i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $cl (i32.wrap_i64 (local.get $cl8)))
    (local.set $new (i32.wrap_i64 (call $mere_vec_new)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    (local.set $buf (i32.load offset=0 (local.get $v)))
    (local.set $env (i32.load offset=0 (local.get $cl)))
    (local.set $fn (i32.load offset=4 (local.get $cl)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (local.set $elem
          (i64.load (i32.add (local.get $buf)
                             (i32.mul (local.get $i) (i32.const 8)))))
        (local.set $keep
          (call_indirect (type $cl)
            (i64.extend_i32_u (local.get $env))
            (local.get $elem)
            (local.get $fn)))
        (if (i32.wrap_i64 (local.get $keep))
          (then
            (drop (call $mere_vec_push (i64.extend_i32_u (local.get $new)) (local.get $elem)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_u (local.get $new)))|}

(* bytes runtime. A bytes value is an i32 pointer to
   [i32 len][bytes...] in linear memory (fits the uniform i32 value model like
   str). bytes_alloc aligns the bump to 4 so the len header is aligned. *)
let bytes_runtime_wasm = {|
  (func $__lang_bytes_alloc (param $len8 i64) (result i64)
    (local $b i32)
    (local $len i32)
    (local.set $len (i32.wrap_i64 (local.get $len8)))
    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 3)) (i32.const -4)))
    (local.set $b (global.get $__lang_bump))
    (i32.store (local.get $b) (local.get $len))
    (global.set $__lang_bump (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $len)))
    (i64.extend_i32_s (local.get $b)))
  (func $__lang_bytes_get (param $b8 i64) (param $i8 i64) (result i64)
    (local $b i32)
    (local $i i32)
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $i (i32.wrap_i64 (local.get $i8)))
    (if (i32.or (i32.lt_s (local.get $i) (i32.const 0))
                (i32.ge_s (local.get $i) (i32.load (local.get $b))))
      (then (unreachable)))
    (i64.extend_i32_s (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i)))))
  (func $__lang_bytes_of_str (param $s8 i64) (result i64)
    (local $n i32) (local $b i32) (local $i i32)
    (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $n (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (local.set $b (i32.wrap_i64 (call $__lang_bytes_alloc (i64.extend_i32_s (local.get $n)))))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))
                  (i32.load8_u (i32.add (local.get $s) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i64.extend_i32_s (local.get $b)))
  (func $__lang_str_of_bytes (param $b8 i64) (result i64)
    (local $n i32) (local $r i32) (local $i i32)
    (local $b i32)
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $n (i32.load (local.get $b)))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (i32.store8 (i32.add (local.get $r) (local.get $i))
                  (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $n)) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (local.get $n)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  (func $__lang_hexchar (param $d8 i64) (result i64)
    (local $d i32)
    (local.set $d (i32.wrap_i64 (local.get $d8)))
    (i64.extend_i32_s (if (result i32) (i32.lt_s (local.get $d) (i32.const 10))
      (then (i32.add (local.get $d) (i32.const 48)))
      (else (i32.add (local.get $d) (i32.const 87))))))
  (func $__lang_hex_of_bytes (param $b8 i64) (result i64)
    (local $n i32) (local $r i32) (local $i i32) (local $byte i32)
    (local $b i32)
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $n (i32.load (local.get $b)))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (local.set $byte (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))))
      (i32.store8 (i32.add (local.get $r) (i32.mul (local.get $i) (i32.const 2)))
                  (i32.wrap_i64 (call $__lang_hexchar (i64.extend_i32_s (i32.shr_u (local.get $byte) (i32.const 4))))))
      (i32.store8 (i32.add (i32.add (local.get $r) (i32.mul (local.get $i) (i32.const 2))) (i32.const 1))
                  (i32.wrap_i64 (call $__lang_hexchar (i64.extend_i32_s (i32.and (local.get $byte) (i32.const 15))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i32.store8 (i32.add (local.get $r) (i32.mul (local.get $n) (i32.const 2))) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (i32.mul (local.get $n) (i32.const 2))) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (i64.extend_i32_s (local.get $r)))
  (func $__lang_hexval (param $c8 i64) (result i64)
    (local $c i32)
    (local.set $c (i32.wrap_i64 (local.get $c8)))
    (i64.extend_i32_s (if (result i32) (i32.and (i32.ge_s (local.get $c) (i32.const 48)) (i32.le_s (local.get $c) (i32.const 57)))
      (then (i32.sub (local.get $c) (i32.const 48)))
      (else (if (result i32) (i32.and (i32.ge_s (local.get $c) (i32.const 97)) (i32.le_s (local.get $c) (i32.const 102)))
        (then (i32.sub (local.get $c) (i32.const 87)))
        (else (if (result i32) (i32.and (i32.ge_s (local.get $c) (i32.const 65)) (i32.le_s (local.get $c) (i32.const 70)))
          (then (i32.sub (local.get $c) (i32.const 55)))
          (else (unreachable)))))))))
  (func $__lang_bytes_of_hex (param $h8 i64) (result i64)
    (local $half i32) (local $b i32) (local $i i32)
    (local $h i32)
    (local.set $h (i32.wrap_i64 (local.get $h8)))
    (local.set $half (i32.div_u (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $h)))) (i32.const 2)))
    (local.set $b (i32.wrap_i64 (call $__lang_bytes_alloc (i64.extend_i32_s (local.get $half)))))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $half)))
      (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))
        (i32.add
          (i32.mul (i32.wrap_i64 (call $__lang_hexval (i64.extend_i32_s (i32.load8_u (i32.add (local.get $h) (i32.mul (local.get $i) (i32.const 2))))))) (i32.const 16))
          (i32.wrap_i64 (call $__lang_hexval (i64.extend_i32_s (i32.load8_u (i32.add (local.get $h) (i32.add (i32.mul (local.get $i) (i32.const 2)) (i32.const 1)))))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i64.extend_i32_s (local.get $b)))
  (func $__lang_bytes_slice (param $b8 i64) (param $start8 i64) (param $len8 i64) (result i64)
    (local $o i32) (local $i i32)
    (local $b i32)
    (local $start i32)
    (local $len i32)
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $start (i32.wrap_i64 (local.get $start8)))
    (local.set $len (i32.wrap_i64 (local.get $len8)))
    (local.set $o (i32.wrap_i64 (call $__lang_bytes_alloc (i64.extend_i32_s (local.get $len)))))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $len)))
      (i32.store8 (i32.add (i32.add (local.get $o) (i32.const 4)) (local.get $i))
                  (i32.load8_u (i32.add (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $start)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i64.extend_i32_s (local.get $o)))
  (func $__lang_bytes_concat (param $a8 i64) (param $b8 i64) (result i64)
    (local $alen i32) (local $blen i32) (local $o i32) (local $i i32)
    (local $a i32)
    (local $b i32)
    (local.set $a (i32.wrap_i64 (local.get $a8)))
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $alen (i32.load (local.get $a)))
    (local.set $blen (i32.load (local.get $b)))
    (local.set $o (i32.wrap_i64 (call $__lang_bytes_alloc (i64.extend_i32_s (i32.add (local.get $alen) (local.get $blen))))))
    (local.set $i (i32.const 0))
    (block $ea (loop $la
      (br_if $ea (i32.eq (local.get $i) (local.get $alen)))
      (i32.store8 (i32.add (i32.add (local.get $o) (i32.const 4)) (local.get $i))
                  (i32.load8_u (i32.add (i32.add (local.get $a) (i32.const 4)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $la)))
    (local.set $i (i32.const 0))
    (block $eb (loop $lb
      (br_if $eb (i32.eq (local.get $i) (local.get $blen)))
      (i32.store8 (i32.add (i32.add (i32.add (local.get $o) (i32.const 4)) (local.get $alen)) (local.get $i))
                  (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lb)))
    (i64.extend_i32_s (local.get $o)))|}

(* bytes <-> Vec[int] bridge. Wasm vecs are untyped (single $mere_vec_*
   runtime, global bump — no region arg). Wasm allows forward refs, so calling
   $mere_vec_new / _push / _get / _len by name needs no ordering. *)
let bytes_vec_bridge_runtime_wasm = {|
  (func $__lang_bytes_of_vec (param $v i64) (result i64)
    (local $n i32) (local $b i32) (local $i i32)
    (local.set $n (i32.wrap_i64 (call $mere_vec_len (local.get $v))))
    (local.set $b (i32.wrap_i64 (call $__lang_bytes_alloc (i64.extend_i32_s (local.get $n)))))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (i32.store8 (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))
                  (i32.and (i32.wrap_i64 (call $mere_vec_get (local.get $v) (i64.extend_i32_s (local.get $i)))) (i32.const 255)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i64.extend_i32_u (local.get $b)))
  (func $__lang_vec_of_bytes (param $b8 i64) (result i64)
    (local $n i32) (local $v i32) (local $i i32) (local $b i32)
    (local.set $b (i32.wrap_i64 (local.get $b8)))
    (local.set $n (i32.load (local.get $b)))
    (local.set $v (i32.wrap_i64 (call $mere_vec_new)))
    (local.set $i (i32.const 0))
    (block $end (loop $lp
      (br_if $end (i32.eq (local.get $i) (local.get $n)))
      (drop (call $mere_vec_push (i64.extend_i32_u (local.get $v))
              (i64.extend_i32_u (i32.load8_u (i32.add (i32.add (local.get $b) (i32.const 4)) (local.get $i))))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $lp)))
    (i64.extend_i32_u (local.get $v)))|}

(* Phase 15.9: StrBuf[R] runtime — single non-polymorphic helper set.
   Uses Wasm's bump allocator ($__lang_bump). Layout:
   { data_ptr:i32, len:i32, cap:i32, _pad:i32 } = 16 bytes (same as Vec). *)
let strbuf_runtime_wasm = {|
  (func $mere_strbuf_new (result i64)
    (local $sb i32) (local $buf i32)
    (local.set $sb (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $sb) (i32.const 16)))
    (local.set $buf (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $buf) (i32.const 16)))
    (i32.store offset=0 (local.get $sb) (local.get $buf))
    (i32.store offset=4 (local.get $sb) (i32.const 0))
    (i32.store offset=8 (local.get $sb) (i32.const 16))
    (i64.extend_i32_s (local.get $sb)))
  (func $mere_strbuf_push (param $sb8 i64) (param $s8 i64) (result i64)
    (local $slen i32) (local $len i32) (local $cap i32) (local $buf i32)
    (local $new_buf i32) (local $i i32)
    (local $sb i32)
    (local $s i32)
    (local.set $sb (i32.wrap_i64 (local.get $sb8)))
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $slen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))
    (block $resize_end
      (loop $resize_lp
        (local.set $len (i32.load offset=4 (local.get $sb)))
        (local.set $cap (i32.load offset=8 (local.get $sb)))
        (br_if $resize_end
          (i32.le_s (i32.add (local.get $len) (local.get $slen))
                    (local.get $cap)))
        ;; grow
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_buf (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_buf) (local.get $cap)))
        (local.set $buf (i32.load offset=0 (local.get $sb)))
        (local.set $i (i32.const 0))
        (block $cp_end
          (loop $cp_lp
            (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
            (i32.store8
              (i32.add (local.get $new_buf) (local.get $i))
              (i32.load8_u (i32.add (local.get $buf) (local.get $i))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp_lp)))
        (i32.store offset=0 (local.get $sb) (local.get $new_buf))
        (i32.store offset=8 (local.get $sb) (local.get $cap))
        (br $resize_lp)))
    ;; copy s into the buffer at offset len
    (local.set $buf (i32.load offset=0 (local.get $sb)))
    (local.set $len (i32.load offset=4 (local.get $sb)))
    (local.set $i (i32.const 0))
    (block $cp2_end
      (loop $cp2_lp
        (br_if $cp2_end (i32.eq (local.get $i) (local.get $slen)))
        (i32.store8
          (i32.add (i32.add (local.get $buf) (local.get $len)) (local.get $i))
          (i32.load8_u (i32.add (local.get $s) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cp2_lp)))
    (i32.store offset=4 (local.get $sb)
      (i32.add (local.get $len) (local.get $slen)))
    (i64.extend_i32_s (i32.const 0)))
  (func $mere_strbuf_to_str (param $sb8 i64) (result i64)
    (local $len i32) (local $out i32) (local $buf i32) (local $i i32)
    (local $sb i32)
    (local.set $sb (i32.wrap_i64 (local.get $sb8)))
    (local.set $len (i32.load offset=4 (local.get $sb)))
    (local.set $buf (i32.load offset=0 (local.get $sb)))
    ;; Allocate through $__lang_str_alloc so the result carries the
    ;; `[i32 len]` header that $__lang_strlen reads from addr-4. Hand
    ;; rolling the bump here (as this did) produced a str whose length
    ;; was whatever preceded it on the heap — usually 0, so every
    ;; strbuf_to_str result read back as "" on this backend only.
    (local.set $out
      (i32.wrap_i64 (call $__lang_str_alloc (i64.extend_i32_u (local.get $len)))))
    (local.set $i (i32.const 0))
    (block $cp_end
      (loop $cp_lp
        (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
        (i32.store8
          (i32.add (local.get $out) (local.get $i))
          (i32.load8_u (i32.add (local.get $buf) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $cp_lp)))
    (i32.store8 (i32.add (local.get $out) (local.get $len)) (i32.const 0))
    (i64.extend_i32_s (local.get $out)))
  (func $mere_strbuf_len (param $sb8 i64) (result i64)
    (local $sb i32)
    (local.set $sb (i32.wrap_i64 (local.get $sb8)))
    (i64.extend_i32_s (i32.load offset=4 (local.get $sb))))|}

(* Phase 15.10: Map[R, K, V] runtime — per-K only (V is i32 for all).
   Layout: { keys:i32, values:i32, len:i32, cap:i32 } = 16 bytes.
   Linear scan; on reaching cap, allocate a new array via bump
   (arena semantics). *)

(* Phase 15.14: emit a key-equality WAT function for K type. K can be
   int / bool / str / tuple (recursive over tuple). Result is `i32`
   (0/1). Tuple elements are i32 stored at offset 4*i within the
   tuple's memory block. *)
let emit_map_key_eq_wasm (k_ty : Ast.ty) : string =
  (* i64 value model: a/b are i64 values; `build` yields an i32 condition,
     extended to an i64 bool at the function boundary. Compound keys hold
     wrapped i32 addresses in locals; fields are 8-byte slots. *)
  let k_tag = ty_tag k_ty in
  let local_counter = ref 0 in
  let fresh_loc prefix =
    incr local_counter;
    Printf.sprintf "$%s%d" prefix !local_counter
  in
  let locals = ref [] in
  let emit_eq_for_atom ty a_expr b_expr =
    match Ast.walk ty with
    | Ast.TyInt | Ast.TyBool ->
      Printf.sprintf "(i64.eq %s %s)" a_expr b_expr
    | Ast.TyStr ->
      Printf.sprintf "(i32.wrap_i64 (call $__lang_streq %s %s))" a_expr b_expr
    | _ -> Printf.sprintf "(i64.eq %s %s)" a_expr b_expr
  in
  let compound_eq fields_offsets a_expr b_expr =
    let a_loc = fresh_loc "ta" in
    let b_loc = fresh_loc "tb" in
    locals := (a_loc, "i32") :: !locals;
    locals := (b_loc, "i32") :: !locals;
    let setup =
      Printf.sprintf "(local.set %s (i32.wrap_i64 %s)) (local.set %s (i32.wrap_i64 %s))"
        a_loc a_expr b_loc b_expr
    in
    let parts = List.map (fun (off, t) ->
      let fa = Printf.sprintf "(i64.load offset=%d (local.get %s))" off a_loc in
      let fb = Printf.sprintf "(i64.load offset=%d (local.get %s))" off b_loc in
      t, fa, fb) fields_offsets in
    parts, setup, a_loc, b_loc
  in
  let rec build ty a_expr b_expr =
    match Ast.walk ty with
    | Ast.TyTuple ts ->
      let fields_off = List.mapi (fun i t -> (i * 8, t)) ts in
      let parts, setup, _, _ = compound_eq fields_off a_expr b_expr in
      let combined =
        match parts with
        | [] -> "(i32.const 1)"
        | (t, a, b) :: rest ->
          let first = build t a b in
          List.fold_left (fun acc (t, a, b) ->
            Printf.sprintf "(i32.and %s %s)" acc (build t a b)) first rest
      in
      Printf.sprintf "(block (result i32) %s %s)" setup combined
    | Ast.TyCon (rname, _) when Hashtbl.mem Typer.records rname ->
      let info = Hashtbl.find Typer.records rname in
      let fields_off = List.mapi (fun i (_, ft) -> (i * 8, ft))
        info.Typer.r_fields in
      let parts, setup, _, _ = compound_eq fields_off a_expr b_expr in
      let combined =
        match parts with
        | [] -> "(i32.const 1)"
        | (t, a, b) :: rest ->
          let first = build t a b in
          List.fold_left (fun acc (t, a, b) ->
            Printf.sprintf "(i32.and %s %s)" acc (build t a b)) first rest
      in
      Printf.sprintf "(block (result i32) %s %s)" setup combined
    | Ast.TyCon (vname, _) when Hashtbl.mem Exhaustive.type_variants vname ->
      let ctors = Hashtbl.find Exhaustive.type_variants vname in
      let has_payload = List.exists (fun (_, p) -> p <> None) ctors in
      if not has_payload then
        Printf.sprintf
          "(i64.eq (i64.load offset=0 (i32.wrap_i64 %s)) (i64.load offset=0 (i32.wrap_i64 %s)))"
          a_expr b_expr
      else begin
        let a_loc = fresh_loc "va" in
        let b_loc = fresh_loc "vb" in
        locals := (a_loc, "i32") :: !locals;
        locals := (b_loc, "i32") :: !locals;
        let setup =
          Printf.sprintf "(local.set %s (i32.wrap_i64 %s)) (local.set %s (i32.wrap_i64 %s))"
            a_loc a_expr b_loc b_expr
        in
        let tag_a = Printf.sprintf "(i32.wrap_i64 (i64.load offset=0 (local.get %s)))" a_loc in
        let tag_b = Printf.sprintf "(i32.wrap_i64 (i64.load offset=0 (local.get %s)))" b_loc in
        let pl_a = Printf.sprintf "(i64.load offset=8 (local.get %s))" a_loc in
        let pl_b = Printf.sprintf "(i64.load offset=8 (local.get %s))" b_loc in
        let tags_eq =
          Printf.sprintf "(i32.eq %s %s)" tag_a tag_b
        in
        let branches = List.filter_map (fun (cname, payload) ->
          match payload with
          | None -> None
          | Some pt ->
            let tv = Hashtbl.find variant_tags cname in
            Some (tv, Ast.walk pt)
        ) ctors in
        let rec emit_dispatch = function
          | [] -> "(i32.const 1)"
          | (tv, pt) :: rest ->
            let eq_pl = build pt pl_a pl_b in
            Printf.sprintf
              "(if (result i32) (i32.eq %s (i32.const %d)) (then %s) (else %s))"
              tag_a tv eq_pl (emit_dispatch rest)
        in
        Printf.sprintf
          "(block (result i32) %s (if (result i32) %s (then %s) (else (i32.const 0))))"
          setup tags_eq (emit_dispatch branches)
      end
    | _ -> emit_eq_for_atom ty a_expr b_expr
  in
  let body_expr = build k_ty "(local.get $a)" "(local.get $b)" in
  let local_decls =
    if !locals = [] then ""
    else
      "    " ^ String.concat " "
        (List.rev_map (fun (n, t) -> Printf.sprintf "(local %s %s)" n t) !locals)
      ^ "\n"
  in
  Printf.sprintf "  (func $mere_map_key_eq_%s (param $a i64) (param $b i64) (result i64)\n%s    (i64.extend_i32_u %s))"
    k_tag local_decls body_expr

(* Phase 15.14: emit one Wasm map runtime per K type (new/set/get/has/len),
   each delegating to `$mere_map_key_eq_<K>`. Replaces the hardcoded
   map_int_runtime_wasm / map_str_runtime_wasm. *)
let emit_map_runtime_wasm (k_ty : Ast.ty) : string =
  let k_tag = ty_tag k_ty in
  Printf.sprintf "
  (func $mere_map_%s_new (result i64)
    (local $m i32) (local $keys i32) (local $values i32)
    (local.set $m (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $m) (i32.const 16)))
    (local.set $keys (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $keys) (i32.const 32)))
    (local.set $values (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $values) (i32.const 32)))
    (i32.store offset=0 (local.get $m) (local.get $keys))
    (i32.store offset=4 (local.get $m) (local.get $values))
    (i32.store offset=8 (local.get $m) (i32.const 0))
    (i32.store offset=12 (local.get $m) (i32.const 4))
    (i64.extend_i32_u (local.get $m)))
  (func $mere_map_%s_set (param $m8 i64) (param $k i64) (param $v i64) (result i64)
    (local $m i32)
    (local $i i32) (local $len i32) (local $cap i32)
    (local $keys i32) (local $values i32)
    (local $new_keys i32) (local $new_values i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.wrap_i64 (call $mere_map_key_eq_%s
              (i64.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 8))))
              (local.get $k)))
          (then
            (i64.store
              (i32.add (local.get $values)
                       (i32.mul (local.get $i) (i32.const 8)))
              (local.get $v))
            (return (i64.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (local.set $cap (i32.load offset=12 (local.get $m)))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_keys (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_keys)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $new_values (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_values)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $i (i32.const 0))
        (block $cp_end
          (loop $cp_lp
            (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
            (i64.store
              (i32.add (local.get $new_keys)
                       (i32.mul (local.get $i) (i32.const 8)))
              (i64.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 8)))))
            (i64.store
              (i32.add (local.get $new_values)
                       (i32.mul (local.get $i) (i32.const 8)))
              (i64.load (i32.add (local.get $values)
                                 (i32.mul (local.get $i) (i32.const 8)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp_lp)))
        (i32.store offset=0 (local.get $m) (local.get $new_keys))
        (i32.store offset=4 (local.get $m) (local.get $new_values))
        (i32.store offset=12 (local.get $m) (local.get $cap))
        (local.set $keys (local.get $new_keys))
        (local.set $values (local.get $new_values))))
    (i64.store
      (i32.add (local.get $keys) (i32.mul (local.get $len) (i32.const 8)))
      (local.get $k))
    (i64.store
      (i32.add (local.get $values) (i32.mul (local.get $len) (i32.const 8)))
      (local.get $v))
    (i32.store offset=8 (local.get $m)
      (i32.add (local.get $len) (i32.const 1)))
    (i64.const 0))
  (func $mere_map_%s_get (param $m8 i64) (param $k i64) (result i64)
    (local $m i32)
    (local $i i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.wrap_i64 (call $mere_map_key_eq_%s
              (i64.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 8))))
              (local.get $k)))
          (then
            (return (i64.load (i32.add (local.get $values)
                                       (i32.mul (local.get $i) (i32.const 8)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (unreachable))
  (func $mere_map_%s_has (param $m8 i64) (param $k i64) (result i64)
    (local $m i32)
    (local $i i32) (local $len i32) (local $keys i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.wrap_i64 (call $mere_map_key_eq_%s
              (i64.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 8))))
              (local.get $k)))
          (then (return (i64.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (i64.const 0))
  (func $mere_map_%s_len (param $m8 i64) (result i64)
    (i64.extend_i32_s (i32.load offset=8 (i32.wrap_i64 (local.get $m8)))))
  ;; Phase 19.2: map_iter — call outer(k) → inner closure, then inner(v).
  ;; outer closure: { env@0, fn_idx@4 }; outer(env, k) returns inner closure ptr.
  (func $mere_map_%s_iter (param $m8 i64) (param $cl8 i64) (result i64)
    (local $m i32) (local $cl i32)
    (local $i i32) (local $len i32)
    (local $keys i32) (local $values i32)
    (local $outer_env i32) (local $outer_fn i32)
    (local $k i64) (local $v i64) (local $inner_cl i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $cl (i32.wrap_i64 (local.get $cl8)))
    (local.set $len    (i32.load offset=8 (local.get $m)))
    (local.set $keys   (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $outer_env (i32.load offset=0 (local.get $cl)))
    (local.set $outer_fn  (i32.load offset=4 (local.get $cl)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (local.set $k (i64.load (i32.add (local.get $keys)
                                  (i32.mul (local.get $i) (i32.const 8)))))
        (local.set $v (i64.load (i32.add (local.get $values)
                                  (i32.mul (local.get $i) (i32.const 8)))))
        (local.set $inner_cl (i32.wrap_i64
          (call_indirect (type $cl) (i64.extend_i32_u (local.get $outer_env)) (local.get $k)
                         (local.get $outer_fn))))
        (drop (call_indirect (type $cl)
                (i64.extend_i32_u (i32.load offset=0 (local.get $inner_cl)))
                (local.get $v)
                (i32.load offset=4 (local.get $inner_cl))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.const 0))
  ;; Phase 39.A' #2: map_delete — when the key matches, shift keys/values down
  (func $mere_map_%s_delete (param $m8 i64) (param $k i64) (result i64)
    (local $m i32)
    (local $i i32) (local $j i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $i (i32.const 0))
    (block $find_done
      (loop $find_lp
        (br_if $find_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.wrap_i64 (call $mere_map_key_eq_%s
              (i64.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 8))))
              (local.get $k)))
          (then
            (local.set $j (local.get $i))
            (block $shift_done
              (loop $shift_lp
                (br_if $shift_done (i32.ge_s (i32.add (local.get $j) (i32.const 1)) (local.get $len)))
                (i64.store
                  (i32.add (local.get $keys) (i32.mul (local.get $j) (i32.const 8)))
                  (i64.load (i32.add (local.get $keys) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 8)))))
                (i64.store
                  (i32.add (local.get $values) (i32.mul (local.get $j) (i32.const 8)))
                  (i64.load (i32.add (local.get $values) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 8)))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $shift_lp)))
            (i32.store offset=8 (local.get $m) (i32.sub (local.get $len) (i32.const 1)))
            (return (i64.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $find_lp)))
    (i64.const 0))"
    k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag

(* O(1) Wasm map for scalar keys (int / bool / str / unit): open-addressing
   hash index over the insertion-order keys/values arrays, mirroring the C
   backend. Scoped to scalar keys — compound keys (tuple/record/variant) keep
   the linear runtime above (correct, O(n), but rare). *)
let wasm_key_hashable (t : Ast.ty) : bool =
  match Ast.walk t with
  | Ast.TyInt | Ast.TyBool | Ast.TyStr | Ast.TyUnit -> true
  | _ -> false

(* Emitted once when any scalar-key map exists: a 32-bit integer avalanche
   mix and an FNV-1a byte hash (str is NUL-terminated, like $__lang_streq). *)
let map_hash_primitives_wasm =
  (* v0.1.127: hash the full i64 key (fold hi into lo first), mix in i32. *)
  {|  (func $__lang_hash_u32 (param $x8 i64) (result i64)
    (local $x i32)
    (local.set $x (i32.xor (i32.wrap_i64 (local.get $x8))
                           (i32.wrap_i64 (i64.shr_u (local.get $x8) (i64.const 32)))))
    (local.set $x (i32.xor (i32.xor (local.get $x) (i32.const 61)) (i32.shr_u (local.get $x) (i32.const 16))))
    (local.set $x (i32.add (local.get $x) (i32.shl (local.get $x) (i32.const 3))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 4))))
    (local.set $x (i32.mul (local.get $x) (i32.const 668265261)))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 15))))
    (i64.extend_i32_u (local.get $x)))
  (func $__lang_hash_str (param $s8 i64) (result i64)
    (local $h i32) (local $c i32) (local $s i32)
    (local.set $s (i32.wrap_i64 (local.get $s8)))
    (local.set $h (i32.const 2166136261))
    (loop $lp
      (local.set $c (i32.load8_u (local.get $s)))
      (if (i32.eqz (local.get $c)) (then (return (i64.extend_i32_u (local.get $h)))))
      (local.set $h (i32.mul (i32.xor (local.get $h) (local.get $c)) (i32.const 16777619)))
      (local.set $s (i32.add (local.get $s) (i32.const 1)))
      (br $lp))
    (unreachable))|}

(* Per-K hash helper delegating to the right primitive. *)
let emit_map_key_hash_wasm (k_ty : Ast.ty) : string =
  let k_tag = ty_tag k_ty in
  let prim = match Ast.walk k_ty with
    | Ast.TyStr -> "$__lang_hash_str"
    | _ -> "$__lang_hash_u32" in
  Printf.sprintf
    "  (func $mere_map_key_hash_%s (param $a i64) (result i64)\n    (call %s (local.get $a)))"
    k_tag prim

let emit_map_runtime_wasm_hashed (k_ty : Ast.ty) : string =
  let k_tag = ty_tag k_ty in
  Printf.sprintf {|
  (func $mere_map_%s_new (result i64)
    (local $m i32) (local $keys i32) (local $values i32) (local $idx i32) (local $i i32)
    (local.set $m (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $m) (i32.const 24)))
    (local.set $keys (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $keys) (i32.const 32)))
    (local.set $values (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $values) (i32.const 32)))
    (local.set $idx (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $idx) (i32.const 32)))
    (i32.store offset=0 (local.get $m) (local.get $keys))
    (i32.store offset=4 (local.get $m) (local.get $values))
    (i32.store offset=8 (local.get $m) (i32.const 0))
    (i32.store offset=12 (local.get $m) (i32.const 4))
    (i32.store offset=16 (local.get $m) (local.get $idx))
    (i32.store offset=20 (local.get $m) (i32.const 8))
    (local.set $i (i32.const 0))
    (block $fend (loop $fl
      (br_if $fend (i32.eq (local.get $i) (i32.const 8)))
      (i32.store (i32.add (local.get $idx) (i32.mul (local.get $i) (i32.const 4))) (i32.const -1))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $fl)))
    (i64.extend_i32_u (local.get $m)))
  (func $mere_map_%s_reindex (param $m i32) (param $newcap i32)
    (local $ni i32) (local $i i32) (local $s i32) (local $len i32) (local $keys i32) (local $ncm1 i32) (local $h i32)
    (local.set $ni (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $ni) (i32.mul (local.get $newcap) (i32.const 4))))
    (local.set $i (i32.const 0))
    (block $fend (loop $fl
      (br_if $fend (i32.eq (local.get $i) (local.get $newcap)))
      (i32.store (i32.add (local.get $ni) (i32.mul (local.get $i) (i32.const 4))) (i32.const -1))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $fl)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $ncm1 (i32.sub (local.get $newcap) (i32.const 1)))
    (local.set $i (i32.const 0))
    (block $pend (loop $pl
      (br_if $pend (i32.eq (local.get $i) (local.get $len)))
      (local.set $h (i32.wrap_i64 (call $mere_map_key_hash_%s
        (i64.load (i32.add (local.get $keys) (i32.mul (local.get $i) (i32.const 8)))))))
      (local.set $s (i32.and (local.get $h) (local.get $ncm1)))
      (block $placed (loop $probe
        (if (i32.eq (i32.load (i32.add (local.get $ni) (i32.mul (local.get $s) (i32.const 4)))) (i32.const -1))
          (then
            (i32.store (i32.add (local.get $ni) (i32.mul (local.get $s) (i32.const 4))) (local.get $i))
            (br $placed)))
        (local.set $s (i32.and (i32.add (local.get $s) (i32.const 1)) (local.get $ncm1)))
        (br $probe)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $pl)))
    (i32.store offset=16 (local.get $m) (local.get $ni))
    (i32.store offset=20 (local.get $m) (local.get $newcap)))
  (func $mere_map_%s_set (param $m8 i64) (param $k i64) (param $v i64) (result i64)
    (local $m i32)
    (local $h i32) (local $s i32) (local $idx i32) (local $idxcap i32) (local $icm1 i32)
    (local $keys i32) (local $values i32) (local $len i32) (local $cap i32) (local $occ i32)
    (local $nk i32) (local $nv i32) (local $i i32) (local $newlen i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $h (i32.wrap_i64 (call $mere_map_key_hash_%s (local.get $k))))
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $idx (i32.load offset=16 (local.get $m)))
    (local.set $idxcap (i32.load offset=20 (local.get $m)))
    (local.set $icm1 (i32.sub (local.get $idxcap) (i32.const 1)))
    (local.set $s (i32.and (local.get $h) (local.get $icm1)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (block $done_probe (loop $probe
      (local.set $occ (i32.load (i32.add (local.get $idx) (i32.mul (local.get $s) (i32.const 4)))))
      (br_if $done_probe (i32.eq (local.get $occ) (i32.const -1)))
      (if (i32.wrap_i64 (call $mere_map_key_eq_%s
            (i64.load (i32.add (local.get $keys) (i32.mul (local.get $occ) (i32.const 8))))
            (local.get $k)))
        (then
          (i64.store (i32.add (local.get $values) (i32.mul (local.get $occ) (i32.const 8))) (local.get $v))
          (return (i64.const 0))))
      (local.set $s (i32.and (i32.add (local.get $s) (i32.const 1)) (local.get $icm1)))
      (br $probe)))
    (local.set $len (i32.load offset=8 (local.get $m)))
    (local.set $cap (i32.load offset=12 (local.get $m)))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $nk (global.get $__lang_bump))
        (global.set $__lang_bump (i32.add (local.get $nk) (i32.mul (local.get $cap) (i32.const 8))))
        (local.set $nv (global.get $__lang_bump))
        (global.set $__lang_bump (i32.add (local.get $nv) (i32.mul (local.get $cap) (i32.const 8))))
        (local.set $i (i32.const 0))
        (block $cend (loop $cl
          (br_if $cend (i32.eq (local.get $i) (local.get $len)))
          (i64.store (i32.add (local.get $nk) (i32.mul (local.get $i) (i32.const 8)))
                     (i64.load (i32.add (local.get $keys) (i32.mul (local.get $i) (i32.const 8)))))
          (i64.store (i32.add (local.get $nv) (i32.mul (local.get $i) (i32.const 8)))
                     (i64.load (i32.add (local.get $values) (i32.mul (local.get $i) (i32.const 8)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $cl)))
        (i32.store offset=0 (local.get $m) (local.get $nk))
        (i32.store offset=4 (local.get $m) (local.get $nv))
        (i32.store offset=12 (local.get $m) (local.get $cap))
        (local.set $keys (local.get $nk))
        (local.set $values (local.get $nv))))
    (i64.store (i32.add (local.get $keys) (i32.mul (local.get $len) (i32.const 8))) (local.get $k))
    (i64.store (i32.add (local.get $values) (i32.mul (local.get $len) (i32.const 8))) (local.get $v))
    (local.set $newlen (i32.add (local.get $len) (i32.const 1)))
    (i32.store offset=8 (local.get $m) (local.get $newlen))
    (if (i32.ge_s (i32.mul (local.get $newlen) (i32.const 10)) (i32.mul (local.get $idxcap) (i32.const 7)))
      (then (call $mere_map_%s_reindex (local.get $m) (i32.mul (local.get $idxcap) (i32.const 2))))
      (else (i32.store (i32.add (local.get $idx) (i32.mul (local.get $s) (i32.const 4)))
                       (i32.sub (local.get $newlen) (i32.const 1)))))
    (i64.const 0))
  (func $mere_map_%s_get (param $m8 i64) (param $k i64) (result i64)
    (local $m i32)
    (local $s i32) (local $idx i32) (local $icm1 i32) (local $keys i32) (local $values i32) (local $occ i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $idx (i32.load offset=16 (local.get $m)))
    (local.set $icm1 (i32.sub (i32.load offset=20 (local.get $m)) (i32.const 1)))
    (local.set $s (i32.and (i32.wrap_i64 (call $mere_map_key_hash_%s (local.get $k))) (local.get $icm1)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (block $fail (loop $probe
      (local.set $occ (i32.load (i32.add (local.get $idx) (i32.mul (local.get $s) (i32.const 4)))))
      (br_if $fail (i32.eq (local.get $occ) (i32.const -1)))
      (if (i32.wrap_i64 (call $mere_map_key_eq_%s
            (i64.load (i32.add (local.get $keys) (i32.mul (local.get $occ) (i32.const 8))))
            (local.get $k)))
        (then (return (i64.load (i32.add (local.get $values) (i32.mul (local.get $occ) (i32.const 8)))))))
      (local.set $s (i32.and (i32.add (local.get $s) (i32.const 1)) (local.get $icm1)))
      (br $probe)))
    (unreachable))
  (func $mere_map_%s_has (param $m8 i64) (param $k i64) (result i64)
    (local $m i32)
    (local $s i32) (local $idx i32) (local $icm1 i32) (local $keys i32) (local $occ i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $idx (i32.load offset=16 (local.get $m)))
    (local.set $icm1 (i32.sub (i32.load offset=20 (local.get $m)) (i32.const 1)))
    (local.set $s (i32.and (i32.wrap_i64 (call $mere_map_key_hash_%s (local.get $k))) (local.get $icm1)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (block $notf (loop $probe
      (local.set $occ (i32.load (i32.add (local.get $idx) (i32.mul (local.get $s) (i32.const 4)))))
      (br_if $notf (i32.eq (local.get $occ) (i32.const -1)))
      (if (i32.wrap_i64 (call $mere_map_key_eq_%s
            (i64.load (i32.add (local.get $keys) (i32.mul (local.get $occ) (i32.const 8))))
            (local.get $k)))
        (then (return (i64.const 1))))
      (local.set $s (i32.and (i32.add (local.get $s) (i32.const 1)) (local.get $icm1)))
      (br $probe)))
    (i64.const 0))
  (func $mere_map_%s_len (param $m8 i64) (result i64)
    (i64.extend_i32_s (i32.load offset=8 (i32.wrap_i64 (local.get $m8)))))
  (func $mere_map_%s_iter (param $m8 i64) (param $cl8 i64) (result i64)
    (local $m i32) (local $cl i32)
    (local $i i32) (local $len i32)
    (local $keys i32) (local $values i32)
    (local $outer_env i32) (local $outer_fn i32)
    (local $k i64) (local $v i64) (local $inner_cl i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $cl (i32.wrap_i64 (local.get $cl8)))
    (local.set $len    (i32.load offset=8 (local.get $m)))
    (local.set $keys   (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (local.set $outer_env (i32.load offset=0 (local.get $cl)))
    (local.set $outer_fn  (i32.load offset=4 (local.get $cl)))
    (local.set $i (i32.const 0))
    (block $end
      (loop $lp
        (br_if $end (i32.eq (local.get $i) (local.get $len)))
        (local.set $k (i64.load (i32.add (local.get $keys)
                                  (i32.mul (local.get $i) (i32.const 8)))))
        (local.set $v (i64.load (i32.add (local.get $values)
                                  (i32.mul (local.get $i) (i32.const 8)))))
        (local.set $inner_cl (i32.wrap_i64
          (call_indirect (type $cl) (i64.extend_i32_u (local.get $outer_env)) (local.get $k)
                         (local.get $outer_fn))))
        (drop (call_indirect (type $cl)
                (i64.extend_i32_u (i32.load offset=0 (local.get $inner_cl)))
                (local.get $v)
                (i32.load offset=4 (local.get $inner_cl))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.const 0))
  (func $mere_map_%s_delete (param $m8 i64) (param $k i64) (result i64)
    (local $m i32)
    (local $s i32) (local $idx i32) (local $idxcap i32) (local $icm1 i32)
    (local $keys i32) (local $values i32) (local $occ i32) (local $len i32) (local $j i32)
    (local.set $m (i32.wrap_i64 (local.get $m8)))
    (local.set $idx (i32.load offset=16 (local.get $m)))
    (local.set $idxcap (i32.load offset=20 (local.get $m)))
    (local.set $icm1 (i32.sub (local.get $idxcap) (i32.const 1)))
    (local.set $s (i32.and (i32.wrap_i64 (call $mere_map_key_hash_%s (local.get $k))) (local.get $icm1)))
    (local.set $keys (i32.load offset=0 (local.get $m)))
    (local.set $values (i32.load offset=4 (local.get $m)))
    (block $notf (loop $probe
      (local.set $occ (i32.load (i32.add (local.get $idx) (i32.mul (local.get $s) (i32.const 4)))))
      (br_if $notf (i32.eq (local.get $occ) (i32.const -1)))
      (if (i32.wrap_i64 (call $mere_map_key_eq_%s
            (i64.load (i32.add (local.get $keys) (i32.mul (local.get $occ) (i32.const 8))))
            (local.get $k)))
        (then
          (local.set $len (i32.load offset=8 (local.get $m)))
          (local.set $j (local.get $occ))
          (block $sdone (loop $sl
            (br_if $sdone (i32.ge_s (i32.add (local.get $j) (i32.const 1)) (local.get $len)))
            (i64.store (i32.add (local.get $keys) (i32.mul (local.get $j) (i32.const 8)))
              (i64.load (i32.add (local.get $keys) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 8)))))
            (i64.store (i32.add (local.get $values) (i32.mul (local.get $j) (i32.const 8)))
              (i64.load (i32.add (local.get $values) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 8)))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $sl)))
          (i32.store offset=8 (local.get $m) (i32.sub (local.get $len) (i32.const 1)))
          (call $mere_map_%s_reindex (local.get $m) (local.get $idxcap))
          (return (i64.const 0))))
      (local.set $s (i32.and (i32.add (local.get $s) (i32.const 1)) (local.get $icm1)))
      (br $probe)))
    (i64.const 0))|}
    k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag
    k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag k_tag

let map_int_runtime_wasm = {|
  (func $mere_map_int_new (result i64)
    (local $m i32) (local $keys i32) (local $values i32)
    (local.set $m (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $m) (i32.const 16)))
    (local.set $keys (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $keys) (i32.const 32)))
    (local.set $values (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $values) (i32.const 32)))
    (i32.store offset=0 (i32.wrap_i64 (local.get $m)) (local.get $keys))
    (i32.store offset=4 (i32.wrap_i64 (local.get $m)) (local.get $values))
    (i32.store offset=8 (i32.wrap_i64 (local.get $m)) (i32.const 0))
    (i32.store offset=12 (i32.wrap_i64 (local.get $m)) (i32.const 4))
    (local.get $m))
  (func $mere_map_int_set (param $m i64) (param $k i64) (param $v i64) (result i64)
    (local $i i32) (local $len i32) (local $cap i32)
    (local $keys i32) (local $values i32)
    (local $new_keys i32) (local $new_values i32)
    (local.set $len (i32.load offset=8 (i32.wrap_i64 (local.get $m))))
    (local.set $keys (i32.load offset=0 (i32.wrap_i64 (local.get $m))))
    (local.set $values (i32.load offset=4 (i32.wrap_i64 (local.get $m))))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.eq (i32.load (i32.add (local.get $keys)
                                       (i32.mul (local.get $i) (i32.const 4))))
                    (local.get $k))
          (then
            (i32.store
              (i32.add (local.get $values)
                       (i32.mul (local.get $i) (i32.const 4)))
              (local.get $v))
            (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    ;; not found: append, grow if full
    (local.set $cap (i32.load offset=12 (i32.wrap_i64 (local.get $m))))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_keys (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_keys)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $new_values (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_values)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $i (i32.const 0))
        (block $cp_end
          (loop $cp_lp
            (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
            (i32.store
              (i32.add (local.get $new_keys)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4)))))
            (i32.store
              (i32.add (local.get $new_values)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load (i32.add (local.get $values)
                                 (i32.mul (local.get $i) (i32.const 4)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp_lp)))
        (i32.store offset=0 (i32.wrap_i64 (local.get $m)) (local.get $new_keys))
        (i32.store offset=4 (i32.wrap_i64 (local.get $m)) (local.get $new_values))
        (i32.store offset=12 (i32.wrap_i64 (local.get $m)) (local.get $cap))
        (local.set $keys (local.get $new_keys))
        (local.set $values (local.get $new_values))))
    (i32.store
      (i32.add (local.get $keys) (i32.mul (local.get $len) (i32.const 4)))
      (local.get $k))
    (i32.store
      (i32.add (local.get $values) (i32.mul (local.get $len) (i32.const 4)))
      (local.get $v))
    (i32.store offset=8 (i32.wrap_i64 (local.get $m))
      (i32.add (local.get $len) (i32.const 1)))
    (i32.const 0))
  (func $mere_map_int_get (param $m i64) (param $k i64) (result i64)
    (local $i i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $len (i32.load offset=8 (i32.wrap_i64 (local.get $m))))
    (local.set $keys (i32.load offset=0 (i32.wrap_i64 (local.get $m))))
    (local.set $values (i32.load offset=4 (i32.wrap_i64 (local.get $m))))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.eq (i32.load (i32.add (local.get $keys)
                                       (i32.mul (local.get $i) (i32.const 4))))
                    (local.get $k))
          (then
            (return (i32.load (i32.add (local.get $values)
                                       (i32.mul (local.get $i) (i32.const 4)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (unreachable))
  (func $mere_map_int_has (param $m i64) (param $k i64) (result i64)
    (local $i i32) (local $len i32) (local $keys i32)
    (local.set $len (i32.load offset=8 (i32.wrap_i64 (local.get $m))))
    (local.set $keys (i32.load offset=0 (i32.wrap_i64 (local.get $m))))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.eq (i32.load (i32.add (local.get $keys)
                                       (i32.mul (local.get $i) (i32.const 4))))
                    (local.get $k))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (i32.const 0))
  (func $mere_map_int_len (param $m i64) (result i64)
    (i32.load offset=8 (i32.wrap_i64 (local.get $m))))
  ;; Phase 39.A' #2: map_delete (int-key variant)
  (func $mere_map_int_delete (param $m i64) (param $k i64) (result i64)
    (local $i i32) (local $j i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $len (i32.load offset=8 (i32.wrap_i64 (local.get $m))))
    (local.set $keys (i32.load offset=0 (i32.wrap_i64 (local.get $m))))
    (local.set $values (i32.load offset=4 (i32.wrap_i64 (local.get $m))))
    (local.set $i (i32.const 0))
    (block $find_done
      (loop $find_lp
        (br_if $find_done (i32.eq (local.get $i) (local.get $len)))
        (if (i32.eq
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            (local.set $j (local.get $i))
            (block $shift_done
              (loop $shift_lp
                (br_if $shift_done (i32.ge_s (i32.add (local.get $j) (i32.const 1)) (local.get $len)))
                (i32.store
                  (i32.add (local.get $keys) (i32.mul (local.get $j) (i32.const 4)))
                  (i32.load (i32.add (local.get $keys) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)))))
                (i32.store
                  (i32.add (local.get $values) (i32.mul (local.get $j) (i32.const 4)))
                  (i32.load (i32.add (local.get $values) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $shift_lp)))
            (i32.store offset=8 (i32.wrap_i64 (local.get $m)) (i32.sub (local.get $len) (i32.const 1)))
            (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $find_lp)))
    (i32.const 0))|}

(* Same shape with $__lang_streq for key comparison (str keys). *)
let map_str_runtime_wasm = {|
  (func $mere_map_str_new (result i64)
    (local $m i32) (local $keys i32) (local $values i32)
    (local.set $m (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $m) (i32.const 16)))
    (local.set $keys (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $keys) (i32.const 32)))
    (local.set $values (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $values) (i32.const 32)))
    (i32.store offset=0 (i32.wrap_i64 (local.get $m)) (local.get $keys))
    (i32.store offset=4 (i32.wrap_i64 (local.get $m)) (local.get $values))
    (i32.store offset=8 (i32.wrap_i64 (local.get $m)) (i32.const 0))
    (i32.store offset=12 (i32.wrap_i64 (local.get $m)) (i32.const 4))
    (local.get $m))
  (func $mere_map_str_set (param $m i64) (param $k i64) (param $v i64) (result i64)
    (local $i i32) (local $len i32) (local $cap i32)
    (local $keys i32) (local $values i32)
    (local $new_keys i32) (local $new_values i32)
    (local.set $len (i32.load offset=8 (i32.wrap_i64 (local.get $m))))
    (local.set $keys (i32.load offset=0 (i32.wrap_i64 (local.get $m))))
    (local.set $values (i32.load offset=4 (i32.wrap_i64 (local.get $m))))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $__lang_streq
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            (i32.store
              (i32.add (local.get $values)
                       (i32.mul (local.get $i) (i32.const 4)))
              (local.get $v))
            (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (local.set $cap (i32.load offset=12 (i32.wrap_i64 (local.get $m))))
    (if (i32.eq (local.get $len) (local.get $cap))
      (then
        (local.set $cap (i32.mul (local.get $cap) (i32.const 2)))
        (local.set $new_keys (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_keys)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $new_values (global.get $__lang_bump))
        (global.set $__lang_bump
          (i32.add (local.get $new_values)
                   (i32.mul (local.get $cap) (i32.const 4))))
        (local.set $i (i32.const 0))
        (block $cp_end
          (loop $cp_lp
            (br_if $cp_end (i32.eq (local.get $i) (local.get $len)))
            (i32.store
              (i32.add (local.get $new_keys)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4)))))
            (i32.store
              (i32.add (local.get $new_values)
                       (i32.mul (local.get $i) (i32.const 4)))
              (i32.load (i32.add (local.get $values)
                                 (i32.mul (local.get $i) (i32.const 4)))))
            (local.set $i (i32.add (local.get $i) (i32.const 1)))
            (br $cp_lp)))
        (i32.store offset=0 (i32.wrap_i64 (local.get $m)) (local.get $new_keys))
        (i32.store offset=4 (i32.wrap_i64 (local.get $m)) (local.get $new_values))
        (i32.store offset=12 (i32.wrap_i64 (local.get $m)) (local.get $cap))
        (local.set $keys (local.get $new_keys))
        (local.set $values (local.get $new_values))))
    (i32.store
      (i32.add (local.get $keys) (i32.mul (local.get $len) (i32.const 4)))
      (local.get $k))
    (i32.store
      (i32.add (local.get $values) (i32.mul (local.get $len) (i32.const 4)))
      (local.get $v))
    (i32.store offset=8 (i32.wrap_i64 (local.get $m))
      (i32.add (local.get $len) (i32.const 1)))
    (i32.const 0))
  (func $mere_map_str_get (param $m i64) (param $k i64) (result i64)
    (local $i i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $len (i32.load offset=8 (i32.wrap_i64 (local.get $m))))
    (local.set $keys (i32.load offset=0 (i32.wrap_i64 (local.get $m))))
    (local.set $values (i32.load offset=4 (i32.wrap_i64 (local.get $m))))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $__lang_streq
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            (return (i32.load (i32.add (local.get $values)
                                       (i32.mul (local.get $i) (i32.const 4)))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (unreachable))
  (func $mere_map_str_has (param $m i64) (param $k i64) (result i64)
    (local $i i32) (local $len i32) (local $keys i32)
    (local.set $len (i32.load offset=8 (i32.wrap_i64 (local.get $m))))
    (local.set $keys (i32.load offset=0 (i32.wrap_i64 (local.get $m))))
    (local.set $i (i32.const 0))
    (block $scan_done
      (loop $scan_lp
        (br_if $scan_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $__lang_streq
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then (return (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $scan_lp)))
    (i32.const 0))
  (func $mere_map_str_len (param $m i64) (result i64)
    (i32.load offset=8 (i32.wrap_i64 (local.get $m))))
  ;; Phase 39.A' #2: map_delete (str-key variant) — when the key matches, shift keys/values
  (func $mere_map_str_delete (param $m i64) (param $k i64) (result i64)
    (local $i i32) (local $j i32) (local $len i32) (local $keys i32) (local $values i32)
    (local.set $len (i32.load offset=8 (i32.wrap_i64 (local.get $m))))
    (local.set $keys (i32.load offset=0 (i32.wrap_i64 (local.get $m))))
    (local.set $values (i32.load offset=4 (i32.wrap_i64 (local.get $m))))
    (local.set $i (i32.const 0))
    (block $find_done
      (loop $find_lp
        (br_if $find_done (i32.eq (local.get $i) (local.get $len)))
        (if (call $__lang_streq
              (i32.load (i32.add (local.get $keys)
                                 (i32.mul (local.get $i) (i32.const 4))))
              (local.get $k))
          (then
            ;; shift from i to len-1
            (local.set $j (local.get $i))
            (block $shift_done
              (loop $shift_lp
                (br_if $shift_done (i32.ge_s (i32.add (local.get $j) (i32.const 1)) (local.get $len)))
                (i32.store
                  (i32.add (local.get $keys) (i32.mul (local.get $j) (i32.const 4)))
                  (i32.load (i32.add (local.get $keys) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)))))
                (i32.store
                  (i32.add (local.get $values) (i32.mul (local.get $j) (i32.const 4)))
                  (i32.load (i32.add (local.get $values) (i32.mul (i32.add (local.get $j) (i32.const 1)) (i32.const 4)))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $shift_lp)))
            (i32.store offset=8 (i32.wrap_i64 (local.get $m)) (i32.sub (local.get $len) (i32.const 1)))
            (return (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $find_lp)))
    (i32.const 0))|}

(* ===== of_json (Wasm): JSON parser runtime + type-directed decoders =====
   A generic JSON tree is built in linear memory as 16-byte cells
   [kind@0, a@4, b@8, c@12]: NULL=0, BOOL=1(a=val), NUM=2(a=lexeme str),
   STR=3(a=str), ARR=4(a=count, b=head of {item@0,next@4} list),
   OBJ=5(a=count, b=head of {key@0,val@4,next@8} list). Parse errors set the
   global $__mj_err; strict of_json traps (unreachable), of_json_opt returns
   None. Mirrors the C backend (codegen_c). *)
let of_json_runtime_wasm : string = {ojw|
  (global $__mj_p (mut i32) (i32.const 0))
  (global $__mj_err (mut i32) (i32.const 0))
  (func $__oj_alloc (param $n i32) (result i32)
    (local $r i32)
    (local.set $r (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $r) (local.get $n)))
    (local.get $r))
  (func $__mj_ws
    (local $c i32)
    (block $end (loop $lp
      (local.set $c (i32.load8_u (global.get $__mj_p)))
      (br_if $end (i32.eqz (i32.or
        (i32.or (i32.eq (local.get $c) (i32.const 32)) (i32.eq (local.get $c) (i32.const 9)))
        (i32.or (i32.eq (local.get $c) (i32.const 10)) (i32.eq (local.get $c) (i32.const 13))))))
      (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
      (br $lp))))
  (func $__mj_cell (param $kind i32) (result i32)
    (local $r i32)
    (local.set $r (call $__oj_alloc (i32.const 16)))
    (i32.store offset=0 (local.get $r) (local.get $kind))
    (i32.store offset=4 (local.get $r) (i32.const 0))
    (i32.store offset=8 (local.get $r) (i32.const 0))
    (i32.store offset=12 (local.get $r) (i32.const 0))
    (local.get $r))
  (func $__mj_atoi (param $s i32) (result i64)
    (local $r i64) (local $neg i32) (local $c i32)
    (local.set $r (i64.const 0)) (local.set $neg (i32.const 0))
    (if (i32.eq (i32.load8_u (local.get $s)) (i32.const 45))
      (then (local.set $neg (i32.const 1)) (local.set $s (i32.add (local.get $s) (i32.const 1)))))
    (block $end (loop $lp
      (local.set $c (i32.load8_u (local.get $s)))
      (br_if $end (i32.lt_u (local.get $c) (i32.const 48)))
      (br_if $end (i32.gt_u (local.get $c) (i32.const 57)))
      (local.set $r (i64.add (i64.mul (local.get $r) (i64.const 10)) (i64.extend_i32_u (i32.sub (local.get $c) (i32.const 48)))))
      (local.set $s (i32.add (local.get $s) (i32.const 1)))
      (br $lp)))
    (if (result i64) (local.get $neg) (then (i64.sub (i64.const 0) (local.get $r))) (else (local.get $r))))
  (func $__mj_pstr (result i32)
    (local $r i32) (local $len i32) (local $c i32) (local $e i32)
    (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $len (i32.const 0))
    (block $end (loop $lp
      (local.set $c (i32.load8_u (global.get $__mj_p)))
      (if (i32.eqz (local.get $c)) (then (global.set $__mj_err (i32.const 1)) (br $end)))
      (if (i32.eq (local.get $c) (i32.const 34))
        (then (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1))) (br $end)))
      (if (i32.eq (local.get $c) (i32.const 92))
        (then
          (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
          (local.set $e (i32.load8_u (global.get $__mj_p)))
          (local.set $c
            (if (result i32) (i32.eq (local.get $e) (i32.const 110)) (then (i32.const 10))
            (else (if (result i32) (i32.eq (local.get $e) (i32.const 116)) (then (i32.const 9))
            (else (if (result i32) (i32.eq (local.get $e) (i32.const 114)) (then (i32.const 13))
            (else (local.get $e))))))))))
      (i32.store8 (i32.add (local.get $r) (local.get $len)) (local.get $c))
      (local.set $len (i32.add (local.get $len) (i32.const 1)))
      (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
      (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $len)) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (local.get $len)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (local.get $r))
  (func $__mj_num (result i32)
    (local $r i32) (local $len i32) (local $c i32)
    (local.set $r (i32.add (global.get $__lang_bump) (i32.const 4)))
    (local.set $len (i32.const 0))
    (block $end (loop $lp
      (local.set $c (i32.load8_u (global.get $__mj_p)))
      (br_if $end (i32.eqz (i32.or
        (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 57)))
        (i32.or (i32.eq (local.get $c) (i32.const 46))
        (i32.or (i32.eq (local.get $c) (i32.const 101))
        (i32.or (i32.eq (local.get $c) (i32.const 69))
        (i32.or (i32.eq (local.get $c) (i32.const 43))
                (i32.eq (local.get $c) (i32.const 45)))))))))
      (i32.store8 (i32.add (local.get $r) (local.get $len)) (local.get $c))
      (local.set $len (i32.add (local.get $len) (i32.const 1)))
      (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
      (br $lp)))
    (i32.store8 (i32.add (local.get $r) (local.get $len)) (i32.const 0))
    (global.set $__lang_bump (i32.add (i32.add (local.get $r) (local.get $len)) (i32.const 1)))
    (i32.store (i32.sub (local.get $r) (i32.const 4)) (i32.sub (i32.sub (global.get $__lang_bump) (local.get $r)) (i32.const 1)))
    (local.get $r))
  (func $__mj_value (result i32)
    (local $c i32) (local $cell i32)
    (call $__mj_ws)
    (local.set $c (i32.load8_u (global.get $__mj_p)))
    (if (i32.eq (local.get $c) (i32.const 123)) (then (return (call $__mj_object))))
    (if (i32.eq (local.get $c) (i32.const 91)) (then (return (call $__mj_array))))
    (if (i32.eq (local.get $c) (i32.const 34))
      (then
        (local.set $cell (call $__mj_cell (i32.const 3)))
        (i32.store offset=4 (local.get $cell) (call $__mj_pstr))
        (return (local.get $cell))))
    (if (i32.eq (local.get $c) (i32.const 116))
      (then
        (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 4)))
        (local.set $cell (call $__mj_cell (i32.const 1)))
        (i32.store offset=4 (local.get $cell) (i32.const 1))
        (return (local.get $cell))))
    (if (i32.eq (local.get $c) (i32.const 102))
      (then
        (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 5)))
        (local.set $cell (call $__mj_cell (i32.const 1)))
        (i32.store offset=4 (local.get $cell) (i32.const 0))
        (return (local.get $cell))))
    (if (i32.eq (local.get $c) (i32.const 110))
      (then
        (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 4)))
        (return (call $__mj_cell (i32.const 0)))))
    (if (i32.or (i32.eq (local.get $c) (i32.const 45))
                (i32.and (i32.ge_u (local.get $c) (i32.const 48)) (i32.le_u (local.get $c) (i32.const 57))))
      (then
        (local.set $cell (call $__mj_cell (i32.const 2)))
        (i32.store offset=4 (local.get $cell) (call $__mj_num))
        (return (local.get $cell))))
    (global.set $__mj_err (i32.const 1))
    (call $__mj_cell (i32.const 0)))
  (func $__mj_array (result i32)
    (local $cell i32) (local $head i32) (local $tail i32) (local $count i32)
    (local $node i32) (local $item i32) (local $c i32)
    (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
    (local.set $head (i32.const 0)) (local.set $tail (i32.const 0)) (local.set $count (i32.const 0))
    (call $__mj_ws)
    (if (i32.eq (i32.load8_u (global.get $__mj_p)) (i32.const 93))
      (then
        (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
        (return (call $__mj_cell (i32.const 4)))))
    (block $done (loop $lp
      (local.set $item (call $__mj_value))
      (br_if $done (global.get $__mj_err))
      (local.set $node (call $__oj_alloc (i32.const 8)))
      (i32.store offset=0 (local.get $node) (local.get $item))
      (i32.store offset=4 (local.get $node) (i32.const 0))
      (if (i32.eqz (local.get $head))
        (then (local.set $head (local.get $node)) (local.set $tail (local.get $node)))
        (else (i32.store offset=4 (local.get $tail) (local.get $node)) (local.set $tail (local.get $node))))
      (local.set $count (i32.add (local.get $count) (i32.const 1)))
      (call $__mj_ws)
      (local.set $c (i32.load8_u (global.get $__mj_p)))
      (if (i32.eq (local.get $c) (i32.const 44))
        (then (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1))) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 93))
        (then (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1))) (br $done)))
      (global.set $__mj_err (i32.const 1)) (br $done)))
    (local.set $cell (call $__mj_cell (i32.const 4)))
    (i32.store offset=4 (local.get $cell) (local.get $count))
    (i32.store offset=8 (local.get $cell) (local.get $head))
    (local.get $cell))
  (func $__mj_object (result i32)
    (local $cell i32) (local $head i32) (local $tail i32) (local $count i32)
    (local $node i32) (local $key i32) (local $val i32) (local $c i32)
    (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
    (local.set $head (i32.const 0)) (local.set $tail (i32.const 0)) (local.set $count (i32.const 0))
    (call $__mj_ws)
    (if (i32.eq (i32.load8_u (global.get $__mj_p)) (i32.const 125))
      (then
        (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
        (return (call $__mj_cell (i32.const 5)))))
    (block $done (loop $lp
      (call $__mj_ws)
      (if (i32.ne (i32.load8_u (global.get $__mj_p)) (i32.const 34))
        (then (global.set $__mj_err (i32.const 1)) (br $done)))
      (local.set $key (call $__mj_pstr))
      (call $__mj_ws)
      (if (i32.ne (i32.load8_u (global.get $__mj_p)) (i32.const 58))
        (then (global.set $__mj_err (i32.const 1)) (br $done)))
      (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1)))
      (local.set $val (call $__mj_value))
      (br_if $done (global.get $__mj_err))
      (local.set $node (call $__oj_alloc (i32.const 12)))
      (i32.store offset=0 (local.get $node) (local.get $key))
      (i32.store offset=4 (local.get $node) (local.get $val))
      (i32.store offset=8 (local.get $node) (i32.const 0))
      (if (i32.eqz (local.get $head))
        (then (local.set $head (local.get $node)) (local.set $tail (local.get $node)))
        (else (i32.store offset=8 (local.get $tail) (local.get $node)) (local.set $tail (local.get $node))))
      (local.set $count (i32.add (local.get $count) (i32.const 1)))
      (call $__mj_ws)
      (local.set $c (i32.load8_u (global.get $__mj_p)))
      (if (i32.eq (local.get $c) (i32.const 44))
        (then (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1))) (br $lp)))
      (if (i32.eq (local.get $c) (i32.const 125))
        (then (global.set $__mj_p (i32.add (global.get $__mj_p) (i32.const 1))) (br $done)))
      (global.set $__mj_err (i32.const 1)) (br $done)))
    (local.set $cell (call $__mj_cell (i32.const 5)))
    (i32.store offset=4 (local.get $cell) (local.get $count))
    (i32.store offset=8 (local.get $cell) (local.get $head))
    (local.get $cell))
  (func $__mj_parse (param $s i32) (result i32)
    (global.set $__mj_p (local.get $s))
    (global.set $__mj_err (i32.const 0))
    (call $__mj_value))
  (func $__mj_field (param $obj i32) (param $key i32) (result i32)
    (local $node i32)
    (if (i32.ne (i32.load offset=0 (local.get $obj)) (i32.const 5))
      (then (global.set $__mj_err (i32.const 1)) (return (i32.const 0))))
    (local.set $node (i32.load offset=8 (local.get $obj)))
    (block $done (loop $lp
      (br_if $done (i32.eqz (local.get $node)))
      (if (i32.wrap_i64 (call $__lang_streq (i64.extend_i32_u (i32.load offset=0 (local.get $node))) (i64.extend_i32_u (local.get $key))))
        (then (return (i32.load offset=4 (local.get $node)))))
      (local.set $node (i32.load offset=8 (local.get $node)))
      (br $lp)))
    (global.set $__mj_err (i32.const 1))
    (i32.const 0))
  (func $__mj_index (param $arr i32) (param $i i32) (result i32)
    (local $node i32)
    (local.set $node (i32.load offset=8 (local.get $arr)))
    (block $done (loop $lp
      (br_if $done (i32.eqz (local.get $i)))
      (br_if $done (i32.eqz (local.get $node)))
      (local.set $node (i32.load offset=4 (local.get $node)))
      (local.set $i (i32.sub (local.get $i) (i32.const 1)))
      (br $lp)))
    (if (result i32) (i32.eqz (local.get $node)) (then (i32.const 0)) (else (i32.load offset=0 (local.get $node)))))
|ojw}

(* Emit `$__ojnode_<tag>` (mj_node -> value) + `$of_json_<tag>` (str ->
   value; strict: traps on error). *)
let emit_of_json_fn (tag : string) (t : Ast.ty) : string =
  let b = Buffer.create 512 in
  let node = Printf.sprintf "$__ojnode_%s" tag in
  (* v0.1.156: `$j` is a JSON-tree cell — an i32 address private to the
     parser — and the result is a Mere value, so i64. Everything this
     builds is in the i64 value model: record and tuple fields are 8-byte
     slots, and variant cells are 16 bytes { tag, payload }. The previous
     shape built 4-byte fields and 8-byte cells, so a decoded record was
     unreadable by the rest of the program even when it assembled. *)
  Buffer.add_string b (Printf.sprintf "  (func %s (param $j i32) (result i64)\n" node);
  let bad = "(then (global.set $__mj_err (i32.const 1)) (return (i64.const 0)))" in
  (match Ast.walk t with
   | Ast.TyInt ->
     Buffer.add_string b
       (Printf.sprintf
          "    (if (i32.ne (i32.load offset=0 (local.get $j)) (i32.const 2)) %s)\n\
          \    (call $__mj_atoi (i32.load offset=4 (local.get $j))))\n" bad)
   | Ast.TyBool ->
     Buffer.add_string b
       (Printf.sprintf
          "    (if (i32.ne (i32.load offset=0 (local.get $j)) (i32.const 1)) %s)\n\
          \    (i64.extend_i32_u (i32.load offset=4 (local.get $j))))\n" bad)
   | Ast.TyStr ->
     Buffer.add_string b
       (Printf.sprintf
          "    (if (i32.ne (i32.load offset=0 (local.get $j)) (i32.const 3)) %s)\n\
          \    (i64.extend_i32_u (i32.load offset=4 (local.get $j))))\n" bad)
   | Ast.TyUnit ->
     Buffer.add_string b "    (drop (local.get $j)) (i64.const 0))\n"
   | Ast.TyTuple ts ->
     let n = List.length ts in
     Buffer.add_string b "    (local $r i32)\n";
     Buffer.add_string b
       (Printf.sprintf
          "    (if (i32.ne (i32.load offset=0 (local.get $j)) (i32.const 4)) %s)\n" bad);
     Buffer.add_string b
       (Printf.sprintf "    (local.set $r (call $__oj_alloc (i32.const %d)))\n" (8 * n));
     List.iteri (fun i et ->
       Buffer.add_string b
         (Printf.sprintf
            "    (i64.store offset=%d (local.get $r) (call $__ojnode_%s (call $__mj_index (local.get $j) (i32.const %d))))\n"
            (8 * i) (ty_tag (Ast.walk et)) i)) ts;
     Buffer.add_string b "    (i64.extend_i32_u (local.get $r)))\n"
   | Ast.TyCon ("list", [elem]) ->
     let elem_tag = ty_tag (Ast.walk elem) in
     let nil_tag = try Hashtbl.find variant_tags "Nil" with Not_found -> 0 in
     let cons_tag = try Hashtbl.find variant_tags "Cons" with Not_found -> 1 in
     Buffer.add_string b
       "    (local $it i32) (local $rev i32) (local $rn i32) (local $acc i32) (local $pl i32) (local $node i32)\n";
     Buffer.add_string b
       (Printf.sprintf
          "    (if (i32.ne (i32.load offset=0 (local.get $j)) (i32.const 4)) %s)\n" bad);
     (* Reverse the parser's item list first, so the fold below builds the
        Mere list front-to-back. Those scratch nodes stay in the parser's
        own 8-byte i32 shape; only what the fold produces is a Mere value. *)
     Buffer.add_string b "    (local.set $rev (i32.const 0))\n";
     Buffer.add_string b "    (local.set $it (i32.load offset=8 (local.get $j)))\n";
     Buffer.add_string b
       "    (block $r1 (loop $l1\n\
       \      (br_if $r1 (i32.eqz (local.get $it)))\n\
       \      (local.set $rn (call $__oj_alloc (i32.const 8)))\n\
       \      (i32.store offset=0 (local.get $rn) (i32.load offset=0 (local.get $it)))\n\
       \      (i32.store offset=4 (local.get $rn) (local.get $rev))\n\
       \      (local.set $rev (local.get $rn))\n\
       \      (local.set $it (i32.load offset=4 (local.get $it)))\n\
       \      (br $l1)))\n";
     Buffer.add_string b
       (Printf.sprintf
          "    (local.set $acc (call $__oj_alloc (i32.const 16)))\n\
          \    (i64.store offset=0 (local.get $acc) (i64.const %d))\n" nil_tag);
     Buffer.add_string b
       (Printf.sprintf
       "    (block $r2 (loop $l2\n\
       \      (br_if $r2 (i32.eqz (local.get $rev)))\n\
       \      (local.set $pl (call $__oj_alloc (i32.const 16)))\n\
       \      (i64.store offset=0 (local.get $pl) (call $__ojnode_%s (i32.load offset=0 (local.get $rev))))\n\
       \      (i64.store offset=8 (local.get $pl) (i64.extend_i32_u (local.get $acc)))\n\
       \      (local.set $node (call $__oj_alloc (i32.const 16)))\n\
       \      (i64.store offset=0 (local.get $node) (i64.const %d))\n\
       \      (i64.store offset=8 (local.get $node) (i64.extend_i32_u (local.get $pl)))\n\
       \      (local.set $acc (local.get $node))\n\
       \      (local.set $rev (i32.load offset=4 (local.get $rev)))\n\
       \      (br $l2)))\n"
       elem_tag cons_tag);
     Buffer.add_string b "    (i64.extend_i32_u (local.get $acc)))\n"
   | Ast.TyCon ("option", [inner]) ->
     let inner_tag = ty_tag (Ast.walk inner) in
     let none_tag = try Hashtbl.find variant_tags "None" with Not_found -> 0 in
     let some_tag = try Hashtbl.find variant_tags "Some" with Not_found -> 1 in
     Buffer.add_string b "    (local $r i32)\n";
     Buffer.add_string b
       (Printf.sprintf
       "    (if (result i64) (i32.eq (i32.load offset=0 (local.get $j)) (i32.const 0))\n\
       \      (then\n\
       \        (local.set $r (call $__oj_alloc (i32.const 16)))\n\
       \        (i64.store offset=0 (local.get $r) (i64.const %d))\n\
       \        (i64.extend_i32_u (local.get $r)))\n\
       \      (else\n\
       \        (local.set $r (call $__oj_alloc (i32.const 16)))\n\
       \        (i64.store offset=0 (local.get $r) (i64.const %d))\n\
       \        (i64.store offset=8 (local.get $r) (call $__ojnode_%s (local.get $j)))\n\
       \        (i64.extend_i32_u (local.get $r)))))\n"
       none_tag some_tag inner_tag)
   | Ast.TyCon (name, args) when Hashtbl.mem Typer.records name ->
     let info = Hashtbl.find Typer.records name in
     let mapping = if info.Typer.r_params = [] then [] else List.combine info.Typer.r_params args in
     let n = List.length info.Typer.r_fields in
     Buffer.add_string b "    (local $r i32)\n";
     Buffer.add_string b
       (Printf.sprintf "    (local.set $r (call $__oj_alloc (i32.const %d)))\n" (8 * n));
     List.iteri (fun i (fname, ft) ->
       let ft = subst_params mapping ft in
       let key = intern_show_str fname in
       Buffer.add_string b
         (Printf.sprintf
            "    (i64.store offset=%d (local.get $r) (call $__ojnode_%s (call $__mj_field (local.get $j) (i32.const %d))))\n"
            (8 * i) (ty_tag (Ast.walk ft)) key)) info.Typer.r_fields;
     Buffer.add_string b "    (i64.extend_i32_u (local.get $r)))\n"
   | Ast.TyCon (name, args) ->
     (* general variant: STR -> nullary; OBJ{1} -> payload ctor *)
     let vs =
       match Hashtbl.find_opt Exhaustive.type_variants name with
       | Some vs -> vs | None -> []
     in
     let mapping =
       match vs with
       | (cname, _) :: _ ->
         (match Hashtbl.find_opt Typer.constructors cname with
          | Some info when info.Typer.params <> [] -> List.combine info.Typer.params args
          | _ -> [])
       | [] -> []
     in
     let variants =
       List.map (fun (cname, arg_opt) ->
         (cname, match arg_opt with Some t -> Some (subst_params mapping t) | None -> None)) vs
     in
     Buffer.add_string b "    (local $r i32) (local $k i32) (local $v i32)\n";
     Buffer.add_string b "    (if (i32.eq (i32.load offset=0 (local.get $j)) (i32.const 3)) (then\n";
     List.iter (fun (cname, arg_opt) ->
       match arg_opt with
       | None ->
         let tag_n = try Hashtbl.find variant_tags cname with Not_found -> 0 in
         let nm = intern_show_str cname in
         Buffer.add_string b
           (Printf.sprintf
              "      (if (i32.wrap_i64 (call $__lang_streq (i64.extend_i32_u (i32.load offset=4 (local.get $j))) (i64.const %d))) (then\n\
              \        (local.set $r (call $__oj_alloc (i32.const 16))) (i64.store offset=0 (local.get $r) (i64.const %d)) (return (i64.extend_i32_u (local.get $r)))))\n"
              nm tag_n)
       | Some _ -> ()) variants;
     Buffer.add_string b "      ))\n";
     Buffer.add_string b "    (if (i32.eq (i32.load offset=0 (local.get $j)) (i32.const 5)) (then\n";
     Buffer.add_string b "      (local.set $k (i32.load offset=0 (i32.load offset=8 (local.get $j))))\n";
     Buffer.add_string b "      (local.set $v (i32.load offset=4 (i32.load offset=8 (local.get $j))))\n";
     List.iter (fun (cname, arg_opt) ->
       match arg_opt with
       | Some ty ->
         let tag_n = try Hashtbl.find variant_tags cname with Not_found -> 0 in
         let nm = intern_show_str cname in
         Buffer.add_string b
           (Printf.sprintf
              "      (if (i32.wrap_i64 (call $__lang_streq (i64.extend_i32_u (local.get $k)) (i64.const %d))) (then\n\
              \        (local.set $r (call $__oj_alloc (i32.const 16))) (i64.store offset=0 (local.get $r) (i64.const %d))\n\
              \        (i64.store offset=8 (local.get $r) (call $__ojnode_%s (local.get $v))) (return (i64.extend_i32_u (local.get $r)))))\n"
              nm tag_n (ty_tag (Ast.walk ty)))
       | None -> ()) variants;
     Buffer.add_string b "      ))\n";
     Buffer.add_string b "    (global.set $__mj_err (i32.const 1)) (i64.const 0))\n"
   | _ ->
     Buffer.add_string b "    (drop (local.get $j)) (global.set $__mj_err (i32.const 1)) (i64.const 0))\n");
  (* strict string entry: trap on error *)
  Buffer.add_string b
    (Printf.sprintf
       "  (func $of_json_%s (param $s i64) (result i64)\n\
       \    (local $v i64)\n\
       \    (local.set $v (call $__ojnode_%s (call $__mj_parse (i32.wrap_i64 (local.get $s)))))\n\
       \    (if (global.get $__mj_err) (then unreachable))\n\
       \    (local.get $v))\n"
       tag tag);
  Buffer.contents b

(* of_json_opt_<inner>: parse + decode; None on error, else Some. *)
let emit_of_json_opt_fn (inner_tag : string) (_inner_t : Ast.ty) : string =
  let none_tag = try Hashtbl.find variant_tags "None" with Not_found -> 0 in
  let some_tag = try Hashtbl.find variant_tags "Some" with Not_found -> 1 in
  Printf.sprintf
    "  (func $of_json_opt_%s (param $s i64) (result i64)\n\
    \    (local $v i64) (local $r i32)\n\
    \    (local.set $v (call $__ojnode_%s (call $__mj_parse (i32.wrap_i64 (local.get $s)))))\n\
    \    (local.set $r (call $__oj_alloc (i32.const 16)))\n\
    \    (if (result i64) (global.get $__mj_err)\n\
    \      (then (i64.store offset=0 (local.get $r) (i64.const %d)) (i64.extend_i32_u (local.get $r)))\n\
    \      (else (i64.store offset=0 (local.get $r) (i64.const %d)) (i64.store offset=8 (local.get $r) (local.get $v)) (i64.extend_i32_u (local.get $r)))))\n"
    inner_tag inner_tag none_tag some_tag


let emit_program ?(main_ty = Ast.TyInt) ?(component = false) (prog : Ast.program) : string =
  ignore main_ty;
  debug_fn_lines := [];
  wasm_component_command :=
    component && (match Ast.walk main_ty with Ast.TyUnit | Ast.TyInt -> true | _ -> false);
  wasm_args_used := false;
  wasm_args_host_used := false;
  wasm_time_used := false;
  wasm_env_used := false;
  wasm_stdin_used := false;
  wasm_socket_ffi := false;
  reset ();
  Hashtbl.reset toplevel_fn_names;
  Hashtbl.reset variant_tags;
  Hashtbl.reset wasm_copy_types;
  Hashtbl.reset fn_closure_table_idx;
  Hashtbl.reset eta_adapters_wasm;
  Hashtbl.reset show_types;
  Hashtbl.reset to_json_types;
  Hashtbl.reset of_json_types;
  Hashtbl.reset of_json_opt_types;
  Hashtbl.reset eq_types;
  Hashtbl.reset cmp_types;
  Hashtbl.reset show_str_offsets;
  table_entries := [];
  pending_closures := [];
  anon_counter := 0;
  Hashtbl.reset inner_lifts_wasm;
  Hashtbl.reset inner_lifts_by_host_wasm;
  inner_fn_counter_wasm := 0;
  lifted_fns_wasm := [];
  current_host_fn_wasm := "";
  Hashtbl.reset inner_lift_closures_emitted_wasm;
  inner_lift_closure_pending_wasm := [];
  Hashtbl.reset multi_inst_fns_wasm;
  str_data_decls := [];
  str_offset_counter := str_initial_offset;
  vec_used := false;
  vec_higher_order_used := false;
  strbuf_used := false;
  logger_used := false;
  metrics_used := false;
  uses_threads := false;
  char_table_used := false;
  fail_used := false;
  substring_used := false;
  int_of_str_used := false;
  str_unescape_used := false;
  str_split_used := false;
  str_join_used := false;
  str_count_used := false;
  file_io_used := false;
  file_bytes_io_used := false;
  file_pio_used := false;
  map_int_used := false;
  map_str_used := false;
  Hashtbl.reset map_key_types;
  vec_to_list_used := false;
  list_len_used := false;
  (* Pre-register variant tags from Exhaustive's registry. *)
  Hashtbl.iter (fun _name vs ->
    List.iteri (fun i (cname, _) ->
      Hashtbl.replace variant_tags cname i) vs
  ) Exhaustive.type_variants;
  let main_expr = Ast.desugar_program prog in
  (* Phase 15.4: resolve let-bound Vec element types. Same trick as
     codegen_c / codegen_llvm — Mere's let-poly generalizes
     `let v = vec_new () in body` to `forall T. Vec[..., T]`, so each
     use of v in body gets a fresh element tyvar. Walk the typed AST
     and unify the binding-site element with each `Var name`.ty.
     Wasm doesn't need monomorphic types (everything is i32) but we
     still want the binding's recorded type to be concrete so
     downstream tooling / show / typed annotations behave consistently. *)
  let resolve_vec_let_types (root : Ast.expr) : unit =
    let unify_with_value (vt : Ast.ty) (ut : Ast.ty) : unit =
      try Typer.unify Loc.dummy vt ut with _ -> ()
    in
    let rec scan_uses name vt body =
      (match body.Ast.node with
       | Ast.Var n when n = name ->
         (match body.Ast.ty with
          | Some t -> unify_with_value vt t
          | None -> ())
       | _ -> ());
      let recur b = scan_uses name vt b in
      match body.Ast.node with
      | Ast.App (a, b) -> recur a; recur b
      | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b) | Ast.Logic (_, a, b) ->
        recur a; recur b
      | Ast.Neg a | Ast.Annot (a, _) | Ast.Field_get (a, _)
      | Ast.Ref (_, _, a) | Ast.Region_block (_, a) -> recur a
      | Ast.Let (pat, v, b) ->
        recur v;
        (match pat.Ast.pnode with
         | Ast.P_var n when n = name -> ()
         | _ -> recur b)
      | Ast.Let_rec (bs, b) ->
        let shadowed = List.exists (fun (n, _) -> n = name) bs in
        List.iter (fun (_, v) -> recur v) bs;
        if not shadowed then recur b
      | Ast.If (c, t, e_) -> recur c; recur t; recur e_
      | Ast.Tuple es -> List.iter recur es
      | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> recur e) fs
      | Ast.Record_update (a, fs) ->
        recur a; List.iter (fun (_, e) -> recur e) fs
      | Ast.With (n, v, b) -> recur v; if n <> name then recur b
      | Ast.Fun (n, _, b) -> if n <> name then recur b
      | Ast.Match (s, arms) ->
        recur s;
        List.iter (fun (_, g, b) ->
          (match g with Some ge -> recur ge | None -> ()); recur b) arms
      | Ast.Constr (_, Some a) -> recur a
      | _ -> ()
    in
    let rec walk e =
      (match e.Ast.node with
       | Ast.Let (pat, value, body) ->
         (match pat.Ast.pnode, value.Ast.ty with
          | Ast.P_var name, Some vt ->
            (match Ast.walk vt with
             | Ast.TyCon ("Vec", _) | Ast.TyCon ("OwnedVec", _)
             | Ast.TyCon ("Map", _) | Ast.TyCon ("StrBuf", _) ->
               scan_uses name vt body
             | _ -> ())
          | _ -> ())
       | Ast.With (name, value, body) ->
         (match value.Ast.ty with
          | Some vt ->
            (match Ast.walk vt with
             | Ast.TyCon ("Vec", _) | Ast.TyCon ("OwnedVec", _)
             | Ast.TyCon ("Map", _) | Ast.TyCon ("StrBuf", _) ->
               scan_uses name vt body
             | _ -> ())
          | None -> ())
       | _ -> ());
      walk_subs e
    and walk_subs e =
      match e.Ast.node with
      | Ast.Let (_, v, b) -> walk v; walk b
      | Ast.Let_rec (bs, b) -> List.iter (fun (_, v) -> walk v) bs; walk b
      | Ast.App (a, b) | Ast.Bin (_, a, b) | Ast.Cmp (_, a, b)
      | Ast.Logic (_, a, b) -> walk a; walk b
      | Ast.Neg a | Ast.Annot (a, _) | Ast.Field_get (a, _)
      | Ast.Ref (_, _, a) | Ast.Region_block (_, a) | Ast.Fun (_, _, a) ->
        walk a
      | Ast.If (c, t, e_) -> walk c; walk t; walk e_
      | Ast.Tuple es -> List.iter walk es
      | Ast.Record_lit (_, fs) -> List.iter (fun (_, e) -> walk e) fs
      | Ast.Record_update (a, fs) ->
        walk a; List.iter (fun (_, e) -> walk e) fs
      | Ast.With (_, v, b) -> walk v; walk b
      | Ast.Match (s, arms) ->
        walk s;
        List.iter (fun (_, g, b) ->
          (match g with Some ge -> walk ge | None -> ()); walk b) arms
      | Ast.Constr (_, Some a) -> walk a
      | _ -> ()
    in
    walk root
  in
  resolve_vec_let_types main_expr;
  (* Phase 32.4 (C1 FFI): walk prog.decls to register extern fn names. *)
  Hashtbl.reset extern_fn_decls_wasm;
  List.iter (fun decl ->
    match decl with
    | Ast.Top_extern (name, ty) ->
      Hashtbl.replace extern_fn_decls_wasm name (Ast.walk ty)
    | _ -> ()
  ) prog.decls;
  let skels, body_expr = lift_fn_skels main_expr in
  List.iter (fun s -> Hashtbl.replace toplevel_fn_names s.sname ()) skels;
  (* v0.1.172: source order, so the shadowing guard can tell a binding that
     is already in scope from one that appears further down the file. *)
  Hashtbl.reset toplevel_fn_pos;
  List.iteri (fun i s ->
    if not (Hashtbl.mem toplevel_fn_pos s.sname) then
      Hashtbl.add toplevel_fn_pos s.sname i) skels;
  current_toplevel_pos := max_int;
  (* Phase 30.2c (DEFERRED §1.10): make those top-level non-fn lets that are
     referenced from skels' fn bodies into Wasm `(global $name (mut i32))`. *)
  let fvs_used_in_skels_wasm =
    List.fold_left (fun acc s ->
      let fvs = free_vars s.sbody [s.sparam] in
      List.sort_uniq compare (fvs @ acc))
      [] skels
  in
  let needs_global_wasm name = List.mem name fvs_used_in_skels_wasm in
  (* Phase 36 (DEFERRED §1.18 fix): keep Let bindings in body so global
     init happens at source-order position. emit_expr Let emits
     `global.set $name` for top_globals_wasm names. *)
  let top_globals_list =
    let rec go e =
      match e.Ast.node with
      | Ast.Let (pat, value, rest) ->
        (match pat.Ast.pnode with
         | Ast.P_var name when needs_global_wasm name ->
           (match value.Ast.node with
            | Ast.Fun _ -> go rest
            | _ -> (name, value) :: go rest)
         | _ -> go rest)
      | _ -> []
    in
    go body_expr
  in
  Hashtbl.reset top_globals_wasm;
  List.iter (fun (n, _) -> Hashtbl.add top_globals_wasm n ()) top_globals_list;
  let fns = resolve_fn_types skels main_expr in
  (* Phase 26.3 (port of LLVM Phase 25.7): dedupe by name, keeping the
     LAST occurrence — when user defines a name that's also in stdlib
     prelude, user's def (later in chain) should shadow. *)
  let fns =
    let seen : (string, unit) Hashtbl.t = Hashtbl.create 16 in
    List.rev (
      List.fold_left (fun acc f ->
        if Hashtbl.mem seen f.name then acc
        else begin Hashtbl.add seen f.name (); f :: acc end
      ) [] (List.rev fns)
    )
  in
  collect_show_types main_expr fns;
  (* Phase 27.2: register show_<main_ty> so the auto-print at end of main
     has the right helper available. *)
  add_show_type main_ty;
  (* Phase 26.3: lift inner fns to top-level. Must run BEFORE emit_fn_def.
     Phase 26.4: include multi-inst base names so inner free_var analysis
     treats them as known toplevels (not captured). Call sites get
     rewritten to mangled spec at emit time. *)
  let mangled_names = List.map (fun f -> f.name) fns in
  let multi_base_names =
    Hashtbl.fold (fun k _ acc -> k :: acc) multi_inst_fns_wasm []
  in
  let toplevel_names = mangled_names @ multi_base_names in
  lift_inner_fns_wasm toplevel_names fns body_expr;
  (* Phase 36 (DEFERRED §1.19 fix): register top-level closure adapter
     table indices BEFORE emit_fn_def so that fn bodies (and nested
     lambdas) can resolve `Var <top_fn>` as a closure value via
     fn_closure_table_idx. The actual adapter WAT is still emitted after
     the fn_defs (top_adapters / lifted_defs), but the index registry must
     be populated up front. *)
  let top_adapters =
    List.map (fun f ->
      let idx = register_in_table (f.name ^ "_closure") in
      Hashtbl.replace fn_closure_table_idx f.name idx;
      emit_top_adapter f
    ) fns
  in
  let fn_defs = List.map emit_fn_def fns in
  let lifted_defs = List.map emit_lifted_fn_wasm !lifted_fns_wasm in
  (* Emit one specialized `show_<tag>` function per registered type. *)
  let show_fn_defs =
    Hashtbl.fold (fun tag t acc -> emit_show_fn tag t :: acc) show_types []
  in
  let to_json_fn_defs =
    Hashtbl.fold (fun tag t acc -> emit_to_json_fn tag t :: acc) to_json_types []
  in
  let of_json_used =
    Hashtbl.length of_json_types > 0 || Hashtbl.length of_json_opt_types > 0
  in
  let of_json_fn_defs =
    (if of_json_used then [of_json_runtime_wasm] else [])
    @ Hashtbl.fold (fun tag t acc -> emit_of_json_fn tag t :: acc) of_json_types []
    @ Hashtbl.fold (fun tag t acc -> emit_of_json_opt_fn tag t :: acc) of_json_opt_types []
  in
  let eq_fn_defs =
    Hashtbl.fold (fun tag t acc -> emit_eq_fn tag t :: acc) eq_types []
  in
  let cmp_fn_defs =
    Hashtbl.fold (fun tag t acc -> emit_cmp_fn tag t :: acc) cmp_types []
  in
  (* Reset counters for the main body. *)
  reset ();
  (* Phase 36 (DEFERRED §1.18 fix): globals are initialized inline in
     body_expr via emit_expr Let emitting `global.set $name`. The
     top-level flag gates that behavior — nested let bindings inside
     fn bodies (imported modules etc.) that happen to share a name
     with a top-level global are plain locals. *)
  ignore top_globals_list;
  (* main's own inner-lifted fns live under host "$main" (see lift_inner_fns_wasm). *)
  set_inner_lifts_for_host_wasm "$main";
  wasm_in_top_level_body := true;
  emit_expr body_expr;
  wasm_in_top_level_body := false;
  (* Phase 27.2: print main's result to stdout via $puts so wasm runtime
     output matches interp's `Pipeline.process s |> print_endline`. The
     stack-top has body's i32 result; pipe through show_<tag> if needed,
     then puts. Unit main: drop result, call puts on "()" literal. *)
  let main_ty_walked = Ast.walk main_ty in
  (* Component target: for value-returning reactor exports (TyStr,
     TyArrow) $main returns the top-level value's raw pointer as an i32 (no
     show_str quote-wrapping — a component value is raw, not interp display),
     which $run then lowers/dispatches to the canonical ABI. Command-style
     programs (TyUnit; Phase 2) and unsupported types fall through to the
     normal epilogue so the program's prints and the trailing "()" still reach
     stdout via $puts -> fd_write. *)
  let component_reactor =
    component && (match main_ty_walked with Ast.TyStr | Ast.TyArrow _ -> true | _ -> false)
  in
  if component_reactor then emit_instr "i32.wrap_i64"
  else
  (match main_ty_walked with
   | Ast.TyInt ->
     emit_instr "call $show_int";
     emit_instr "call $puts";
     emit_instr "i32.const 0"
   | Ast.TyBool ->
     emit_instr "call $show_bool";
     emit_instr "call $puts";
     emit_instr "i32.const 0"
   | Ast.TyStr ->
     (* show_str wraps in quotes; here we want raw print of the main expr,
        but interp's Eval.to_string for V_str wraps in quotes too. *)
     emit_instr "call $show_str";
     emit_instr "call $puts";
     emit_instr "i32.const 0"
   | Ast.TyUnit ->
     emit_instr "drop";
     let unit_off = intern_show_str "()" in
     emit_instr (Printf.sprintf "i64.const %d" unit_off);
     emit_instr "call $puts";
     emit_instr "i32.const 0"
   | Ast.TyFloat ->
     (* Phase 34.3: float main result — load f64 from ptr, str_of_float via
        env import (JS formats like OCaml's string_of_float), then puts.
        The host import returns an i32 str ptr; extend for $puts (i64). *)
     emit_instr "i32.wrap_i64";
     emit_instr "f64.load offset=0 align=8";
     emit_instr "call $__lang_str_of_float";
     emit_instr "i64.extend_i32_u";
     emit_instr "call $puts";
     emit_instr "i32.const 0"
   | _ ->
     (* Best-effort: drop body and return 0. *)
     emit_instr "drop";
     emit_instr "i32.const 0");
  let body_instrs = List.rev !instrs in
  let local_count = !local_counter in
  let local_decl =
    if local_count = 0 then "" else
      (* Phase 34.3: declare typed locals (i32 / f64) via local_types *)
      let types =
        if List.length !local_types = local_count then !local_types
        else List.init local_count (fun _ -> "i64")
      in
      Printf.sprintf "    (local%s)\n"
        (String.concat "" (List.map (fun t -> " " ^ t) types))
  in
  let indented_body =
    String.concat "\n" (List.map (fun s -> "    " ^ s) body_instrs)
  in
  (* Drain pending anonymous-Fun adapters (Fun emits can nest, so
     adapter emission may push more — iterate to a fixpoint). *)
  let anon_adapters = ref [] in
  let rec drain () =
    match !pending_closures with
    | [] -> ()
    | ce :: rest ->
      pending_closures := rest;
      anon_adapters := emit_anon_adapter ce :: !anon_adapters;
      drain ()
  in
  drain ();
  let anon_adapters = List.rev !anon_adapters in
  (* Phase 39.A2: generate adapters for Inner-lifted fns as WAT.
     The adapter takes env_offset + arg, loads caps from env, and calls the
     lifted fn with caps... + arg. *)
  let inner_lift_adapter_strs =
    List.rev_map (fun (lifted_name, captures, _idx) ->
      let load_caps =
        List.mapi (fun i _ ->
          Printf.sprintf
            "    local.get 0\n    i32.wrap_i64\n    i64.load offset=%d"
            (i * 8))
          captures
        |> String.concat "\n"
      in
      Printf.sprintf
        "  (func $%s_inner_closure_fn (param i64) (param i64) (result i64)\n%s\n    local.get 1\n    call $%s)"
        lifted_name load_caps lifted_name
    ) !inner_lift_closure_pending_wasm
  in
  (* Phase 16.3 / DEFERRED §1.5: Logger / Metrics runtime — register
     helper fns in the table now (after main body has populated
     table_entries with user closures), so their indices are stable.
     The runtime body is built with the indices interpolated. *)
  let logger_runtime_section =
    if not !logger_used then "" else begin
      let info_idx  = register_in_table "__mere_logger_info_fn" in
      let warn_idx  = register_in_table "__mere_logger_warn_fn" in
      let error_idx = register_in_table "__mere_logger_error_fn" in
      let info_prefix_off  = fresh_str_offset " [INFO] " in
      let warn_prefix_off  = fresh_str_offset " [WARN] " in
      let error_prefix_off = fresh_str_offset " [ERROR] " in
      Printf.sprintf {|
  (func $__mere_logger_info_fn (param $env i64) (param $msg i64) (result i64)
    (local $tmp i32)
    (local.set $tmp (call $__lang_str_concat (local.get $env) (i32.const %d)))
    (local.set $tmp (call $__lang_str_concat (local.get $tmp) (local.get $msg)))
    (call $puts (local.get $tmp))
    (i32.const 0))
  (func $__mere_logger_warn_fn (param $env i64) (param $msg i64) (result i64)
    (local $tmp i32)
    (local.set $tmp (call $__lang_str_concat (local.get $env) (i32.const %d)))
    (local.set $tmp (call $__lang_str_concat (local.get $tmp) (local.get $msg)))
    (call $puts (local.get $tmp))
    (i32.const 0))
  (func $__mere_logger_error_fn (param $env i64) (param $msg i64) (result i64)
    (local $tmp i32)
    (local.set $tmp (call $__lang_str_concat (local.get $env) (i32.const %d)))
    (local.set $tmp (call $__lang_str_concat (local.get $tmp) (local.get $msg)))
    (call $puts (local.get $tmp))
    (i32.const 0))
  (func $__mere_mk_logger (param $prefix i64) (result i64)
    (local $logger i32) (local $cl i32)
    ;; Logger record: 3 ptrs to closures = 12 bytes
    (local.set $logger (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $logger) (i32.const 12)))
    ;; info closure (8 bytes: env, fn_idx)
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (local.get $prefix))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (i32.store offset=0 (local.get $logger) (local.get $cl))
    ;; warn
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (local.get $prefix))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (i32.store offset=4 (local.get $logger) (local.get $cl))
    ;; error
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (local.get $prefix))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (i32.store offset=8 (local.get $logger) (local.get $cl))
    (local.get $logger))|}
        info_prefix_off warn_prefix_off error_prefix_off
        info_idx warn_idx error_idx
    end
  in
  let metrics_runtime_section =
    if not !metrics_used then "" else begin
      let inc_idx   = register_in_table "__mere_metrics_inc_fn" in
      let rec_outer = register_in_table "__mere_metrics_record_outer_fn" in
      let rec_inner = register_in_table "__mere_metrics_record_inner_fn" in
      let inc_prefix_off = fresh_str_offset "[METRIC] inc " in
      let rec_prefix_off = fresh_str_offset "[METRIC] " in
      let eq_off         = fresh_str_offset "=" in
      Printf.sprintf {|
  (func $__mere_metrics_inc_fn (param $env i64) (param $name i64) (result i64)
    (local $tmp i32)
    (local.set $tmp (call $__lang_str_concat (i32.const %d) (local.get $name)))
    (call $puts (local.get $tmp))
    (i32.const 0))
  (func $__mere_metrics_record_inner_fn (param $env i64) (param $n i64) (result i64)
    (local $tmp i32) (local $ns i32)
    (local.set $ns (call $show_int (local.get $n)))
    (local.set $tmp (call $__lang_str_concat (i32.const %d) (local.get $env)))
    (local.set $tmp (call $__lang_str_concat (local.get $tmp) (i32.const %d)))
    (local.set $tmp (call $__lang_str_concat (local.get $tmp) (local.get $ns)))
    (call $puts (local.get $tmp))
    (i32.const 0))
  (func $__mere_metrics_record_outer_fn (param $env i64) (param $name i64) (result i64)
    (local $cl i32)
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (local.get $name))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (local.get $cl))
  (func $__mere_mk_metrics (result i64)
    (local $m i32) (local $cl i32)
    ;; Metrics record: 2 ptrs = 8 bytes
    (local.set $m (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $m) (i32.const 8)))
    ;; inc closure
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (i32.const 0))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (i32.store offset=0 (local.get $m) (local.get $cl))
    ;; record outer closure
    (local.set $cl (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $cl) (i32.const 8)))
    (i32.store offset=0 (local.get $cl) (i32.const 0))
    (i32.store offset=4 (local.get $cl) (i32.const %d))
    (i32.store offset=4 (local.get $m) (local.get $cl))
    (local.get $m))|}
        inc_prefix_off rec_prefix_off eq_off rec_inner inc_idx rec_outer
    end
  in
  (* Phase 30.2c: declare top-level non-fn lets as Wasm globals (mut i32).
     All Mere values are i32 in Wasm (literal int or ptr into linear memory),
     so a single uniform i32 global per let works. *)
  let top_globals_section =
    if top_globals_list = [] then ""
    else
      String.concat "\n"
        (List.map (fun (name, _) ->
          Printf.sprintf "  (global $%s (mut i64) (i64.const 0))" name)
          top_globals_list) ^ "\n"
  in
  let eta_adapters =
    Hashtbl.fold (fun slug (builtin, _ret_ty, _idx) acc ->
      emit_eta_adapter_wasm slug builtin :: acc)
      eta_adapters_wasm []
  in
  let fn_section =
    (* v0.1.37: __mcopy fns are collected during emission (region blocks
       register their result types), so compute the defs here — after
       both the fn bodies and main have been emitted. Sorted for
       byte-stable output. *)
    let copy_fn_defs =
      List.sort compare
        (Hashtbl.fold (fun tag t acc ->
           (* "str" is provided by the static runtime ($__mcopy_str) *)
           if tag = "str" then acc
           else emit_copy_fn_wasm tag t :: acc)
           wasm_copy_types [])
    in
    let all = fn_defs @ lifted_defs @ top_adapters @ anon_adapters @ eta_adapters @ show_fn_defs @ to_json_fn_defs @ of_json_fn_defs @ eq_fn_defs @ cmp_fn_defs @ copy_fn_defs @ inner_lift_adapter_strs in
    let all =
      if logger_runtime_section <> "" then all @ [logger_runtime_section]
      else all
    in
    let all =
      if metrics_runtime_section <> "" then all @ [metrics_runtime_section]
      else all
    in
    if all = [] then "" else String.concat "\n" all ^ "\n"
  in
  let data_section =
    if !str_data_decls = [] then ""
    else String.concat "\n" (List.rev !str_data_decls) ^ "\n"
  in
  let table_section =
    if !table_entries <> [] then begin
      let n = List.length !table_entries in
      let elem_names =
        String.concat " " (List.map (fun s -> "$" ^ s) !table_entries)
      in
      (* Phase 48.2 (C2 Stage 2): export the table as
         `__indirect_function_table` so JS host glue can pull a Mere
         closure out of the table and call it back. The export name
         matches the wasm-bindgen / LLVM convention. *)
      Printf.sprintf
        "  (table %d funcref)\n\
        \  (export \"__indirect_function_table\" (table 0))\n\
        \  (elem (i32.const 0) %s)\n"
        n elem_names
    end
    else if !vec_higher_order_used then
      (* No closure adapters in the table but the higher-order Vec
         helpers reference (type $cl) + call_indirect, which require a
         table. Declare a zero-element one. *)
      "  (table 0 funcref)\n\
      \  (export \"__indirect_function_table\" (table 0))\n"
    else ""
  in
  (* Phase 26.1: reserve bytes for __lang_char_table. Byte-safe strings use
     6-byte cells [i32 len=1][char][NUL], so 256 * 6 = 1536 bytes.
     Always reserved (low overhead) so the char_at helper can lazy-init it
     on first call without needing per-module conditional layout. *)
  let char_table_offset = !str_offset_counter in
  let bump_init = !str_offset_counter + 1536 in
  (* Phase 26.5: list_str runtime + file I/O host imports — conditional. *)
  let list_str_runtime_section =
    if !str_split_used || !str_join_used || !str_count_used
    then list_str_runtime_wasm else ""
  in
  (* v0.1.127 boundary: host imports keep the 32-bit JS-friendly ABI
     (pointers / small ints as i32); each is imported under $<name>_h and
     an i64 shim with the internal name adapts to the uniform i64 value
     model. Imports must precede all definitions, so the shim funcs are
     collected separately (boundary_shims) and emitted after them. *)
  let file_io_imports =
    (if !print_no_nl_used then
      "  (import \"env\" \"print_no_nl\" (func $__lang_print_no_nl_h (param i32)))\n"
    else "")
    ^ (if !print_bytes_used then
      "  (import \"env\" \"print_bytes\" (func $__lang_print_bytes_h (param i32) (param i32)))\n"
    else "")
    ^ (if !file_io_used then
      "  (import \"env\" \"read_file\" (func $__lang_read_file_h (param i32) (result i32)))\n\
      \  (import \"env\" \"write_file\" (func $__lang_write_file_h (param i32) (param i32) (result i32)))\n"
    else "")
    ^ (if !file_bytes_io_used then
      "  (import \"env\" \"read_file_bytes\" (func $read_file_bytes_h (param i32) (result i32)))\n\
      \  (import \"env\" \"write_file_bytes\" (func $write_file_bytes_h (param i32) (param i32) (result i32)))\n"
    else "")
    ^ (if !wasm_args_host_used then
      "  (import \"env\" \"arg_count\" (func $arg_count_h (result i32)))\n\
      \  (import \"env\" \"arg_get\" (func $arg_get_h (param i32) (result i32)))\n"
    else "")
    ^ (if !file_pio_used then
      "  (import \"env\" \"file_openrw\" (func $file_openrw_h (param i32) (result i32)))\n\
      \  (import \"env\" \"file_pread\" (func $file_pread_h (param i32) (param i32) (param i32) (result i32)))\n\
      \  (import \"env\" \"file_pwrite\" (func $file_pwrite_h (param i32) (param i32) (param i32) (result i32)))\n\
      \  (import \"env\" \"file_fsync\" (func $file_fsync_h (param i32) (result i32)))\n\
      \  (import \"env\" \"file_close\" (func $file_close_h (param i32) (result i32)))\n\
      \  (import \"env\" \"file_size\" (func $file_size_h (param i32) (result i32)))\n"
    else "")
  in
  let boundary_shims =
    "  (func $puts (param i64) (call $puts_h (i32.wrap_i64 (local.get 0))))\n"
    ^ (if !print_no_nl_used then
      "  (func $__lang_print_no_nl (param i64) (call $__lang_print_no_nl_h (i32.wrap_i64 (local.get 0))))\n"
    else "")
    ^ (if !print_bytes_used then
      "  (func $__lang_print_bytes (param i64)\n\
      \    (call $__lang_print_bytes_h\n\
      \      (i32.add (i32.wrap_i64 (local.get 0)) (i32.const 4))\n\
      \      (i32.load (i32.wrap_i64 (local.get 0)))))\n"
    else "")
    ^ (if !file_io_used then
      "  (func $__lang_read_file (param i64) (result i64)\n\
      \    (i64.extend_i32_u (call $__lang_read_file_h (i32.wrap_i64 (local.get 0)))))\n\
      \  (func $__lang_write_file (param i64) (param i64) (result i64)\n\
      \    (i64.extend_i32_u (call $__lang_write_file_h (i32.wrap_i64 (local.get 0)) (i32.wrap_i64 (local.get 1)))))\n"
    else "")
    ^ (if !file_bytes_io_used then
      "  (func $read_file_bytes (param i64) (result i64)\n\
      \    (i64.extend_i32_u (call $read_file_bytes_h (i32.wrap_i64 (local.get 0)))))\n\
      \  (func $write_file_bytes (param i64) (param i64) (result i64)\n\
      \    (i64.extend_i32_u (call $write_file_bytes_h (i32.wrap_i64 (local.get 0)) (i32.wrap_i64 (local.get 1)))))\n"
    else "")
    ^ (if !file_pio_used then
      "  (func $file_openrw (param i64) (result i64)\n\
      \    (i64.extend_i32_u (call $file_openrw_h (i32.wrap_i64 (local.get 0)))))\n\
      \  (func $file_pread (param i64) (param i64) (param i64) (result i64)\n\
      \    (i64.extend_i32_u (call $file_pread_h (i32.wrap_i64 (local.get 0))\n\
      \      (i32.wrap_i64 (local.get 1)) (i32.wrap_i64 (local.get 2)))))\n\
      \  (func $file_pwrite (param i64) (param i64) (param i64) (result i64)\n\
      \    (i64.extend_i32_u (call $file_pwrite_h (i32.wrap_i64 (local.get 0))\n\
      \      (i32.wrap_i64 (local.get 1)) (i32.wrap_i64 (local.get 2)))))\n\
      \  (func $file_fsync (param i64) (result i64)\n\
      \    (i64.extend_i32_u (call $file_fsync_h (i32.wrap_i64 (local.get 0)))))\n\
      \  (func $file_close (param i64) (result i64)\n\
      \    (i64.extend_i32_u (call $file_close_h (i32.wrap_i64 (local.get 0)))))\n\
      \  (func $file_size (param i64) (result i64)\n\
      \    (i64.extend_i32_u (call $file_size_h (i32.wrap_i64 (local.get 0)))))\n"
    else "")
  in
  (* Phase 34.3: float runtime imports (str_of_float / float_of_str).
     Conditional emit would require a check, so always import (harmless
     even when unused). *)
  let float_io_imports =
    "  (import \"env\" \"__lang_str_of_float\" (func $__lang_str_of_float (param f64) (result i32)))\n\
    \  (import \"env\" \"__lang_float_of_str\" (func $__lang_float_of_str (param i32) (result f64)))\n\
    \  (import \"env\" \"time\" (func $__lang_time (result f64)))\n"
  in
  (* Phase 34.4: libm host imports (sin / cos / tan / pow / atan2). sqrt
     uses the Wasm intrinsic, so no host import is needed. *)
  let libm_imports =
    "  (import \"env\" \"__lang_sin\" (func $__lang_sin (param f64) (result f64)))\n\
    \  (import \"env\" \"__lang_cos\" (func $__lang_cos (param f64) (result f64)))\n\
    \  (import \"env\" \"__lang_tan\" (func $__lang_tan (param f64) (result f64)))\n\
    \  (import \"env\" \"__lang_f_pow\" (func $__lang_f_pow (param f64) (param f64) (result f64)))\n\
    \  (import \"env\" \"__lang_atan2\" (func $__lang_atan2 (param f64) (param f64) (result f64)))\n"
  in
  let file_io_imports =
    if component then
      (* Component target: a WebAssembly component must not carry
         ambient `env` imports. Replace the float/time/libm host imports with
         in-module stubs so a pure run()->string program has zero imports and
         is componentizable. Math/time are not yet routed through WASI (later
         slices); a pure Slice-1 program never calls them, so trapping stubs
         (time returns 0) are safe. Programs that actually use these under
         --component will trap — a documented Slice-1 limitation. *)
      "  (func $__lang_str_of_float (param f64) (result i32) unreachable)\n\
      \  (func $__lang_float_of_str (param i32) (result f64) unreachable)\n"
      ^ (if !wasm_component_command && !wasm_time_used then ""
         (* command + time(): the real wasi-backed $__lang_time is emitted in
            puts_decl (with the clock_time_get import); skip the stub here. *)
         else "  (func $__lang_time (result f64) (f64.const 0))\n")
      ^ "  (func $__lang_sin (param f64) (result f64) unreachable)\n\
      \  (func $__lang_cos (param f64) (result f64) unreachable)\n\
      \  (func $__lang_tan (param f64) (result f64) unreachable)\n\
      \  (func $__lang_f_pow (param f64) (param f64) (result f64) unreachable)\n\
      \  (func $__lang_atan2 (param f64) (param f64) (result f64) unreachable)\n"
      (* In component mode the env host imports ($<name>_h) are dropped, but
         the boundary shim wrappers ($__lang_read_file etc.) that call them are
         still emitted. Provide the referenced _h hosts so the module
         validates. A command component gets a real WASI-backed read_file (in
         puts_decl, Phase 3); reactor exports (no WASI adapter) get trapping
         stubs — a file op traps, the value path works. *)
      ^ (if !file_io_used && not !wasm_component_command then
           "  (func $__lang_read_file_h (param i32) (result i32) unreachable)\n\
           \  (func $__lang_write_file_h (param i32) (param i32) (result i32) unreachable)\n"
         else "")
      ^ (if !file_bytes_io_used then
           "  (func $read_file_bytes_h (param i32) (result i32) unreachable)\n\
           \  (func $write_file_bytes_h (param i32) (param i32) (result i32) unreachable)\n"
         else "")
      ^ (if !wasm_args_host_used then
           "  (func $arg_count_h (result i32) unreachable)\n\
           \  (func $arg_get_h (param i32) (result i32) unreachable)\n"
         else "")
      ^ (if !file_pio_used then
           "  (func $file_openrw_h (param i32) (result i32) unreachable)\n\
           \  (func $file_pread_h (param i32) (param i32) (param i32) (result i32) unreachable)\n\
           \  (func $file_pwrite_h (param i32) (param i32) (param i32) (result i32) unreachable)\n\
           \  (func $file_fsync_h (param i32) (result i32) unreachable)\n\
           \  (func $file_close_h (param i32) (result i32) unreachable)\n\
           \  (func $file_size_h (param i32) (result i32) unreachable)\n"
         else "")
      ^ (if !print_no_nl_used then
           "  (func $__lang_print_no_nl_h (param i32) unreachable)\n"
         else "")
      ^ (if !print_bytes_used then
           "  (func $__lang_print_bytes_h (param i32) (param i32) unreachable)\n"
         else "")
    else file_io_imports ^ float_io_imports ^ libm_imports
  in
  (* Phase 32.4 (C1 FFI): declare extern fns as env host imports.
     Represent str / bool / int / unit all as i32. Unit arguments produce
     no param; unit return produces no result. *)
  let extern_imports =
    Hashtbl.fold (fun name ty acc ->
      let rec flatten t =
        match Ast.walk t with
        | Ast.TyArrow (p, r) ->
          let args, ret = flatten r in
          Ast.walk p :: args, ret
        | _ -> [], Ast.walk t
      in
      let args, ret = flatten ty in
      let n_params =
        args |> List.filter (fun t -> t <> Ast.TyUnit) |> List.length in
      (* Host ABI stays 32-bit (pointers / numbers as JS-friendly i32):
         import the host function as $<name>_h and emit an i64 shim under
         the internal name, wrapping each arg and extending the result. *)
      let h_params =
        String.concat "" (List.init n_params (fun _ -> " (param i32)")) in
      let h_result = match ret with Ast.TyUnit -> "" | _ -> " (result i32)" in
      let s_params =
        String.concat "" (List.init n_params (fun _ -> " (param i64)")) in
      let s_result = match ret with Ast.TyUnit -> "" | _ -> " (result i64)" in
      let call_args =
        String.concat "" (List.init n_params (fun i ->
          Printf.sprintf " (i32.wrap_i64 (local.get %d))" i)) in
      let call =
        Printf.sprintf "(call $%s_h%s)" name call_args in
      let body = match ret with
        | Ast.TyUnit -> call
        | _ -> Printf.sprintf "(i64.extend_i32_u %s)" call in
      (* Phase 3 sockets: in a command component, the mhttp-style socket /
         raw-memory externs are backed by in-module _h helpers (p2 wasi:sockets
         + linear memory), not an env import. Keep the i64 shim; drop the import. *)
      let import_str =
        if !wasm_component_command && List.mem name socket_ffi_externs then begin
          wasm_socket_ffi := true; ""
        end else
          Printf.sprintf "  (import \"env\" \"%s\" (func $%s_h%s%s))\n"
            name name h_params h_result
      in
      (import_str,
       Printf.sprintf "  (func $%s%s%s\n    %s)\n"
         name s_params s_result body)
      :: acc)
      extern_fn_decls_wasm []
  in
  let extern_shims = String.concat "" (List.map snd extern_imports) in
  let extern_imports = String.concat "" (List.map fst extern_imports) in
  let file_io_imports = file_io_imports ^ extern_imports in
  let boundary_shims = boundary_shims ^ extern_shims in
  (* Q-012: threading imports + memory mode. When the program spawns, the
     module imports one host-created shared memory (so every worker instance
     shares it) and pulls the spawn/join host functions; otherwise it keeps
     its own exported unshared memory. *)
  let file_io_imports =
    if !uses_threads then
      file_io_imports
      ^ "  (import \"env\" \"mere_spawn\" (func $mere_spawn_h (param i32) (result i32)))\n\
        \  (import \"env\" \"mere_join\" (func $mere_join_h (param i32) (result i32)))\n\
        \  (import \"env\" \"mere_channel_new\" (func $mere_channel_new_h (param i32) (result i32)))\n\
        \  (import \"env\" \"mere_channel_send\" (func $mere_channel_send_h (param i32) (param i64) (result i32)))\n\
        \  (import \"env\" \"mere_channel_recv\" (func $mere_channel_recv_h (param i32) (result i64)))\n"
    else file_io_imports
  in
  let boundary_shims =
    if !uses_threads then
      boundary_shims
      ^ "  (func $mere_spawn (param i64) (result i64)\n\
        \    (i64.extend_i32_u (call $mere_spawn_h (i32.wrap_i64 (local.get 0)))))\n\
        \  (func $mere_join (param i64) (result i64)\n\
        \    (i64.extend_i32_u (call $mere_join_h (i32.wrap_i64 (local.get 0)))))\n\
        \  (func $mere_channel_new (param i64) (result i64)\n\
        \    (i64.extend_i32_u (call $mere_channel_new_h (i32.wrap_i64 (local.get 0)))))\n\
        \  (func $mere_channel_send (param i64) (param i64) (result i64)\n\
        \    (i64.extend_i32_u (call $mere_channel_send_h (i32.wrap_i64 (local.get 0)) (local.get 1))))\n\
        \  (func $mere_channel_recv (param i64) (result i64)\n\
        \    (call $mere_channel_recv_h (i32.wrap_i64 (local.get 0))))\n"
    else boundary_shims
  in
  let memory_section =
    (if !uses_threads then
      "  (import \"env\" \"memory\" (memory 1024 65536 shared))\n\
      \  (export \"memory\" (memory 0))\n"
    else "  (memory (export \"memory\") 1024)\n")
    ^ boundary_shims
  in
  let vec_runtime_section = if !vec_used then vec_runtime else "" in
  let vec_higher_order_section =
    if !vec_higher_order_used then vec_higher_order_runtime else ""
  in
  (* strbuf + bytes share one template slot; both are independent WAT func
     blocks and Wasm allows forward refs (bytes helpers call $__lang_strlen). *)
  let strbuf_section =
    (if !strbuf_used then strbuf_runtime_wasm else "")
    ^ (if !bytes_used then bytes_runtime_wasm else "")
    ^ (if !bytes_vec_used then bytes_vec_bridge_runtime_wasm else "") in
  (* Phase 15.14: emit per-K key-eq helper + per-K map runtime for each K
     in map_key_types. *)
  let map_key_eq_section =
    String.concat "\n"
      (Hashtbl.fold (fun _tag k_ty acc ->
         emit_map_key_eq_wasm k_ty :: acc) map_key_types [])
  in
  (* Scalar-key maps use the O(1) hash-index runtime; compound-key maps keep
     the linear one. The hash primitives + per-K hash helper are emitted only
     when at least one scalar-key map exists. *)
  let any_hashable =
    Hashtbl.fold (fun _tag k_ty acc -> acc || wasm_key_hashable k_ty)
      map_key_types false
  in
  let map_hash_helper_section =
    if not any_hashable then ""
    else
      map_hash_primitives_wasm ^ "\n" ^
      String.concat "\n"
        (Hashtbl.fold (fun _tag k_ty acc ->
           if wasm_key_hashable k_ty then emit_map_key_hash_wasm k_ty :: acc
           else acc) map_key_types [])
  in
  let map_runtime_section =
    map_hash_helper_section ^ "\n" ^
    String.concat "\n"
      (Hashtbl.fold (fun _tag k_ty acc ->
         let rt =
           if wasm_key_hashable k_ty then emit_map_runtime_wasm_hashed k_ty
           else emit_map_runtime_wasm k_ty in
         rt :: acc) map_key_types [])
  in
  (* Legacy flags (for tests that still toggle them) — no-op effect since
     the table is the authoritative source. *)
  let _ = !map_int_used and _ = !map_str_used in
  ignore map_int_runtime_wasm; ignore map_str_runtime_wasm;
  (* Phase 15.12: vec_to_list / list_len helpers. Tag values are taken from
     variant_tags at codegen time and baked-in. *)
  let cons_tag_v =
    try Hashtbl.find variant_tags "Cons" with Not_found -> 1
  in
  let nil_tag_v =
    try Hashtbl.find variant_tags "Nil" with Not_found -> 0
  in
  (* v0.1.159: args() on a plain (non-component) host. The runners have
     supplied arg_count / arg_get for a long time; only the builtin was
     never wired to them, so a CLI compiled to Wasm silently saw no
     arguments while the same source on C saw them all. A browser host
     reports 0 and this yields Nil, which is the behaviour the hardcoded
     empty list got right. *)
  let args_host_section =
    if not !wasm_args_host_used then "" else
    Printf.sprintf
      "  (func $__lang_args_host (result i64)\n\
      \    (local $n i32) (local $i i32) (local $acc i32) (local $tup i32) (local $cell i32)\n\
      \    (local.set $n (call $arg_count_h))\n\
      \    (local.set $acc (global.get $__lang_bump))\n\
      \    (global.set $__lang_bump (i32.add (local.get $acc) (i32.const 16)))\n\
      \    (i64.store offset=0 (local.get $acc) (i64.const %d))\n\
      \    (local.set $i (local.get $n))\n\
      \    (block $done (loop $lp\n\
      \      (br_if $done (i32.le_s (local.get $i) (i32.const 0)))\n\
      \      (local.set $i (i32.sub (local.get $i) (i32.const 1)))\n\
      \      (local.set $tup (global.get $__lang_bump))\n\
      \      (global.set $__lang_bump (i32.add (local.get $tup) (i32.const 16)))\n\
      \      (i64.store offset=0 (local.get $tup)\n\
      \        (i64.extend_i32_u (call $arg_get_h (local.get $i))))\n\
      \      (i64.store offset=8 (local.get $tup) (i64.extend_i32_u (local.get $acc)))\n\
      \      (local.set $cell (global.get $__lang_bump))\n\
      \      (global.set $__lang_bump (i32.add (local.get $cell) (i32.const 16)))\n\
      \      (i64.store offset=0 (local.get $cell) (i64.const %d))\n\
      \      (i64.store offset=8 (local.get $cell) (i64.extend_i32_u (local.get $tup)))\n\
      \      (local.set $acc (local.get $cell))\n\
      \      (br $lp)))\n\
      \    (i64.extend_i32_u (local.get $acc)))\n"
      nil_tag_v cons_tag_v
  in
  let vec_to_list_section =
    if not !vec_to_list_used then "" else
    Printf.sprintf "
  ;; v0.1.153: rebuilt for the i64 value model. This helper still assumed
  ;; the old 4-byte one — it loaded the Vec header straight off an i64
  ;; local and packed 8-byte cells with i32 fields, so any program that
  ;; called vec_to_list emitted WAT that wat2wasm rejected outright. Cells
  ;; are 16 bytes with i64 fields, matching $__lang_args.
  (func $mere_vec_to_list (param $v8 i64) (result i64)
    (local $v i32) (local $len i32) (local $i i32) (local $acc i32)
    (local $tup i32) (local $node i32)
    (local.set $v (i32.wrap_i64 (local.get $v8)))
    (local.set $len (i32.load offset=4 (local.get $v)))
    ;; Nil cell (16 bytes): { tag }
    (local.set $acc (global.get $__lang_bump))
    (global.set $__lang_bump (i32.add (local.get $acc) (i32.const 16)))
    (i64.store offset=0 (local.get $acc) (i64.const %d))  ;; nil_tag
    (local.set $i (i32.sub (local.get $len) (i32.const 1)))
    (block $end
      (loop $lp
        (br_if $end (i32.lt_s (local.get $i) (i32.const 0)))
        ;; tuple (16 bytes): { f0 = vec[i], f1 = acc }
        (local.set $tup (global.get $__lang_bump))
        (global.set $__lang_bump (i32.add (local.get $tup) (i32.const 16)))
        (i64.store offset=0 (local.get $tup)
          (call $mere_vec_get (local.get $v8) (i64.extend_i32_s (local.get $i))))
        (i64.store offset=8 (local.get $tup) (i64.extend_i32_u (local.get $acc)))
        ;; Cons cell (16 bytes): { tag, payload }
        (local.set $node (global.get $__lang_bump))
        (global.set $__lang_bump (i32.add (local.get $node) (i32.const 16)))
        (i64.store offset=0 (local.get $node) (i64.const %d))  ;; cons_tag
        (i64.store offset=8 (local.get $node) (i64.extend_i32_u (local.get $tup)))
        (local.set $acc (local.get $node))
        (local.set $i (i32.sub (local.get $i) (i32.const 1)))
        (br $lp)))
    (i64.extend_i32_u (local.get $acc)))" nil_tag_v cons_tag_v
  in
  let list_len_section =
    if not !list_len_used then "" else
    Printf.sprintf "
  (func $mere_list_len (param $l i64) (result i64)
    (local $n i32) (local $tag i32) (local $payload i32)
    (local.set $n (i32.const 0))
    (block $end
      (loop $lp
        (local.set $tag (i32.load offset=0 (local.get $l)))
        (br_if $end (i32.ne (local.get $tag) (i32.const %d)))  ;; not Cons
        (local.set $n (i32.add (local.get $n) (i32.const 1)))
        (local.set $payload (i32.load offset=4 (local.get $l)))
        ;; tuple.f1 (next list) at offset 4 of payload
        (local.set $l (i32.load offset=4 (local.get $payload)))
        (br $lp)))
    (local.get $n))" cons_tag_v
  in
  (* Phase(component): opt-in WebAssembly Component Model export shape.
     Emits cabi_realloc (wrapping the bump allocator) + a `run` export that
     calls $main (which yields a str ptr for a string-typed program) and
     lowers it to the canonical ABI string: retptr -> [ptr, len]. *)
  (* Under --component, the ambient `env.puts` import is replaced by a no-op
     in-module stub (pure Slice-1 programs do not print). *)
  let puts_decl =
    if not component then
      "  (import \"env\" \"puts\" (func $puts_h (param i32)))\n"
    else if main_ty_walked = Ast.TyUnit || main_ty_walked = Ast.TyInt then
      (* Phase 2: a unit/CLI program prints via WASI. Import
         Preview 1 fd_write and write the NUL-terminated Mere string plus a
         trailing newline (matching C's puts) to stdout (fd 1). Componentized
         with the wasi_snapshot_preview1 command adapter, this yields a
         wasi:cli/run component that `wasmtime run` executes.
         NB: the command adapter's fd_write only honors the FIRST iovec entry
         (a scatter write of 2 iovecs silently drops the 2nd), so we issue two
         single-iovec writes: the string, then the newline. Scratch (16 bytes
         bump): iovec @0..7, nwritten @8..11, newline byte @12. *)
      (* args() support (opt-in via wasm_args_used, set during emit_expr):
         import wasi args_sizes_get/args_get and emit $__lang_args, which
         builds a str list of argv[1..] (skipping the program name, matching
         the C backend). Cons cell = { tag:i64 @0, payload:i64 @8 -> tuple };
         tuple = { head:i64 @0, tail:i64 @8 }; Nil = { tag:i64 @0 }. Each
         argv[i] (and each env value) is a bare NUL-terminated buffer with no
         length header, so it is copied into a proper header'd Mere str via
         $__lang_cstr_to_str before use (strlen reads the i32 header at ptr-4). *)
      let args_imports =
        if not !wasm_args_used then "" else
        "  (import \"wasi_snapshot_preview1\" \"args_sizes_get\" (func $args_sizes_get (param i32 i32) (result i32)))\n\
        \  (import \"wasi_snapshot_preview1\" \"args_get\" (func $args_get (param i32 i32) (result i32)))\n"
      in
      (* Copy a bare NUL-terminated C string into a fresh length-header'd Mere
         str ([len:i32 @-4][bytes][NUL]); return the data pointer. Shared by
         args() and env_var(), whose WASI-provided strings lack the header. *)
      let cstr_to_str_fn =
        if not (!wasm_args_used || !wasm_env_used) then "" else
        "  (func $__lang_cstr_to_str (param $c i32) (result i32)\n\
        \    (local $n i32) (local $start i32) (local $i i32)\n\
        \    (block $e (loop $l\n\
        \      (br_if $e (i32.eqz (i32.load8_u (i32.add (local.get $c) (local.get $n)))))\n\
        \      (local.set $n (i32.add (local.get $n) (i32.const 1)))\n\
        \      (br $l)))\n\
        \    (local.set $start (i32.add (global.get $__lang_bump) (i32.const 4)))\n\
        \    (global.set $__lang_bump (i32.add (local.get $start) (i32.add (local.get $n) (i32.const 1))))\n\
        \    (local.set $i (i32.const 0))\n\
        \    (block $ce (loop $cl\n\
        \      (br_if $ce (i32.ge_u (local.get $i) (local.get $n)))\n\
        \      (i32.store8 (i32.add (local.get $start) (local.get $i)) (i32.load8_u (i32.add (local.get $c) (local.get $i))))\n\
        \      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n\
        \      (br $cl)))\n\
        \    (i32.store8 (i32.add (local.get $start) (local.get $n)) (i32.const 0))\n\
        \    (i32.store (i32.sub (local.get $start) (i32.const 4)) (local.get $n))\n\
        \    (local.get $start))\n"
      in
      let args_fn =
        if not !wasm_args_used then "" else
        let cons_t = (try Hashtbl.find variant_tags "Cons" with Not_found -> 1) in
        let nil_t = (try Hashtbl.find variant_tags "Nil" with Not_found -> 0) in
        Printf.sprintf
          "  (func $__lang_args (result i64)\n\
          \    (local $argc i32) (local $bufsz i32) (local $argv i32) (local $buf i32)\n\
          \    (local $i i32) (local $acc i32) (local $tup i32) (local $cell i32) (local $sz i32)\n\
          \    (local.set $sz (global.get $__lang_bump))\n\
          \    (global.set $__lang_bump (i32.add (local.get $sz) (i32.const 8)))\n\
          \    (drop (call $args_sizes_get (local.get $sz) (i32.add (local.get $sz) (i32.const 4))))\n\
          \    (local.set $argc (i32.load (local.get $sz)))\n\
          \    (local.set $bufsz (i32.load offset=4 (local.get $sz)))\n\
          \    (local.set $argv (global.get $__lang_bump))\n\
          \    (global.set $__lang_bump (i32.add (local.get $argv) (i32.mul (local.get $argc) (i32.const 4))))\n\
          \    (local.set $buf (global.get $__lang_bump))\n\
          \    (global.set $__lang_bump (i32.add (local.get $buf) (local.get $bufsz)))\n\
          \    (drop (call $args_get (local.get $argv) (local.get $buf)))\n\
          \    (local.set $acc (global.get $__lang_bump))\n\
          \    (global.set $__lang_bump (i32.add (local.get $acc) (i32.const 16)))\n\
          \    (i64.store offset=0 (local.get $acc) (i64.const %d))\n\
          \    (local.set $i (local.get $argc))\n\
          \    (block $done (loop $lp\n\
          \      (br_if $done (i32.le_s (local.get $i) (i32.const 1)))\n\
          \      (local.set $i (i32.sub (local.get $i) (i32.const 1)))\n\
          \      (local.set $tup (global.get $__lang_bump))\n\
          \      (global.set $__lang_bump (i32.add (local.get $tup) (i32.const 16)))\n\
          \      (i64.store offset=0 (local.get $tup) (i64.extend_i32_u (call $__lang_cstr_to_str (i32.load (i32.add (local.get $argv) (i32.mul (local.get $i) (i32.const 4)))))))\n\
          \      (i64.store offset=8 (local.get $tup) (i64.extend_i32_u (local.get $acc)))\n\
          \      (local.set $cell (global.get $__lang_bump))\n\
          \      (global.set $__lang_bump (i32.add (local.get $cell) (i32.const 16)))\n\
          \      (i64.store offset=0 (local.get $cell) (i64.const %d))\n\
          \      (i64.store offset=8 (local.get $cell) (i64.extend_i32_u (local.get $tup)))\n\
          \      (local.set $acc (local.get $cell))\n\
          \      (br $lp)))\n\
          \    (i64.extend_i32_u (local.get $acc)))\n"
          nil_t cons_t
      in
      (* time() support: import wasi clock_time_get and emit a real
         $__lang_time (realtime epoch nanoseconds -> f64 seconds) in place of
         the f64.const 0 stub. Gated on wasm_time_used. *)
      let clock_import =
        if not !wasm_time_used then "" else
        "  (import \"wasi_snapshot_preview1\" \"clock_time_get\" (func $clock_time_get (param i32 i64 i32) (result i32)))\n"
      in
      let clock_fn =
        if not !wasm_time_used then "" else
        "  (func $__lang_time (result f64)\n\
        \    (local $t i32)\n\
        \    (local.set $t (global.get $__lang_bump))\n\
        \    (global.set $__lang_bump (i32.add (local.get $t) (i32.const 8)))\n\
        \    (drop (call $clock_time_get (i32.const 0) (i64.const 0) (local.get $t)))\n\
        \    (f64.div (f64.convert_i64_u (i64.load (local.get $t))) (f64.const 1000000000)))\n"
      in
      (* env_var support: import wasi environ_sizes_get/environ_get and emit
         $__lang_env_var, which scans "KEY=VALUE" entries for one matching the
         name and returns Some (value ptr, NUL-terminated so usable directly)
         or None. Gated on wasm_env_used. *)
      let env_imports =
        if not !wasm_env_used then "" else
        "  (import \"wasi_snapshot_preview1\" \"environ_sizes_get\" (func $environ_sizes_get (param i32 i32) (result i32)))\n\
        \  (import \"wasi_snapshot_preview1\" \"environ_get\" (func $environ_get (param i32 i32) (result i32)))\n"
      in
      let env_fn =
        if not !wasm_env_used then "" else
        let some_t = (try Hashtbl.find variant_tags "Some" with Not_found -> 1) in
        let none_t = (try Hashtbl.find variant_tags "None" with Not_found -> 0) in
        Printf.sprintf
          "  (func $__lang_env_var (param $name i32) (result i64)\n\
          \    (local $nl i32) (local $cnt i32) (local $bufsz i32) (local $envp i32) (local $buf i32)\n\
          \    (local $i i32) (local $e i32) (local $j i32) (local $ok i32) (local $sz i32) (local $cell i32)\n\
          \    (local.set $nl (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $name)))))\n\
          \    (local.set $sz (global.get $__lang_bump))\n\
          \    (global.set $__lang_bump (i32.add (local.get $sz) (i32.const 8)))\n\
          \    (drop (call $environ_sizes_get (local.get $sz) (i32.add (local.get $sz) (i32.const 4))))\n\
          \    (local.set $cnt (i32.load (local.get $sz)))\n\
          \    (local.set $bufsz (i32.load offset=4 (local.get $sz)))\n\
          \    (local.set $envp (global.get $__lang_bump))\n\
          \    (global.set $__lang_bump (i32.add (local.get $envp) (i32.mul (local.get $cnt) (i32.const 4))))\n\
          \    (local.set $buf (global.get $__lang_bump))\n\
          \    (global.set $__lang_bump (i32.add (local.get $buf) (local.get $bufsz)))\n\
          \    (drop (call $environ_get (local.get $envp) (local.get $buf)))\n\
          \    (local.set $i (i32.const 0))\n\
          \    (block $done (loop $lp\n\
          \      (br_if $done (i32.ge_u (local.get $i) (local.get $cnt)))\n\
          \      (local.set $e (i32.load (i32.add (local.get $envp) (i32.mul (local.get $i) (i32.const 4)))))\n\
          \      (local.set $j (i32.const 0))\n\
          \      (local.set $ok (i32.const 1))\n\
          \      (block $cend (loop $clp\n\
          \        (br_if $cend (i32.ge_u (local.get $j) (local.get $nl)))\n\
          \        (if (i32.ne (i32.load8_u (i32.add (local.get $e) (local.get $j))) (i32.load8_u (i32.add (local.get $name) (local.get $j))))\n\
          \          (then (local.set $ok (i32.const 0)) (br $cend)))\n\
          \        (local.set $j (i32.add (local.get $j) (i32.const 1)))\n\
          \        (br $clp)))\n\
          \      (if (i32.and (local.get $ok) (i32.eq (i32.load8_u (i32.add (local.get $e) (local.get $nl))) (i32.const 61)))\n\
          \        (then\n\
          \          (local.set $cell (global.get $__lang_bump))\n\
          \          (global.set $__lang_bump (i32.add (local.get $cell) (i32.const 16)))\n\
          \          (i64.store offset=0 (local.get $cell) (i64.const %d))\n\
          \          (i64.store offset=8 (local.get $cell) (i64.extend_i32_u (call $__lang_cstr_to_str (i32.add (i32.add (local.get $e) (local.get $nl)) (i32.const 1)))))\n\
          \          (return (i64.extend_i32_u (local.get $cell)))))\n\
          \      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n\
          \      (br $lp)))\n\
          \    (local.set $cell (global.get $__lang_bump))\n\
          \    (global.set $__lang_bump (i32.add (local.get $cell) (i32.const 16)))\n\
          \    (i64.store offset=0 (local.get $cell) (i64.const %d))\n\
          \    (i64.extend_i32_u (local.get $cell)))\n"
          some_t none_t
      in
      (* read_stdin support: import wasi fd_read and emit $__lang_read_stdin,
         which reads all of fd 0 in 4KB chunks into contiguous bump memory,
         NUL-terminates, and returns the Mere str ptr. Gated on wasm_stdin_used. *)
      let stdin_import =
        (* fd_read is shared by read_stdin (fd 0) and read_file (opened fd). *)
        if not (!wasm_stdin_used || !file_io_used) then "" else
        "  (import \"wasi_snapshot_preview1\" \"fd_read\" (func $fd_read (param i32 i32 i32 i32) (result i32)))\n"
      in
      (* Phase 3: file reads via WASI Preview 1 path_open + fd_read + fd_close
         (through the command adapter), sidestepping the p2 resource/stream
         model. path_open resolves relative to preopen fd 3
         (`wasmtime run --dir <d>::/`). read_file builds a length-header'd Mere
         str exactly like read_stdin; a missing file traps (matching interp's
         eval error). write_file is not yet componentized -> trap. *)
      let file_imports =
        if not !file_io_used then "" else
        "  (import \"wasi_snapshot_preview1\" \"path_open\" (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))\n\
        \  (import \"wasi_snapshot_preview1\" \"fd_close\" (func $fd_close (param i32) (result i32)))\n"
      in
      let file_fn =
        if not !file_io_used then "" else
        "  (func $__lang_read_file_h (param $path i32) (result i32)\n\
        \    (local $plen i32) (local $fd i32) (local $iov i32) (local $start i32) (local $p i32) (local $nread i32)\n\
        \    (local.set $plen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $path)))))\n\
        \    (local.set $iov (global.get $__lang_bump))\n\
        \    (global.set $__lang_bump (i32.add (local.get $iov) (i32.const 16)))\n\
        \    (if (call $path_open (i32.const 3) (i32.const 1) (local.get $path) (local.get $plen) (i32.const 0) (i64.const 6) (i64.const 6) (i32.const 0) (i32.add (local.get $iov) (i32.const 12)))\n\
        \      (then unreachable))\n\
        \    (local.set $fd (i32.load offset=12 (local.get $iov)))\n\
        \    (local.set $start (i32.add (global.get $__lang_bump) (i32.const 4)))\n\
        \    (local.set $p (local.get $start))\n\
        \    (block $eof (loop $lp\n\
        \      (i32.store offset=0 (local.get $iov) (local.get $p))\n\
        \      (i32.store offset=4 (local.get $iov) (i32.const 4096))\n\
        \      (drop (call $fd_read (local.get $fd) (local.get $iov) (i32.const 1) (i32.add (local.get $iov) (i32.const 8))))\n\
        \      (local.set $nread (i32.load offset=8 (local.get $iov)))\n\
        \      (br_if $eof (i32.eqz (local.get $nread)))\n\
        \      (local.set $p (i32.add (local.get $p) (local.get $nread)))\n\
        \      (global.set $__lang_bump (local.get $p))\n\
        \      (br $lp)))\n\
        \    (drop (call $fd_close (local.get $fd)))\n\
        \    (i32.store8 (local.get $p) (i32.const 0))\n\
        \    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 1)))\n\
        \    (i32.store (i32.sub (local.get $start) (i32.const 4)) (i32.sub (local.get $p) (local.get $start)))\n\
        \    (local.get $start))\n\
        \  (func $__lang_write_file_h (param $path i32) (param $content i32) (result i32)\n\
        \    (local $plen i32) (local $clen i32) (local $fd i32) (local $iov i32)\n\
        \    (local.set $plen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $path)))))\n\
        \    (local.set $clen (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $content)))))\n\
        \    (local.set $iov (global.get $__lang_bump))\n\
        \    (global.set $__lang_bump (i32.add (local.get $iov) (i32.const 16)))\n\
        \    (if (call $path_open (i32.const 3) (i32.const 1) (local.get $path) (local.get $plen) (i32.const 9) (i64.const 64) (i64.const 64) (i32.const 0) (i32.add (local.get $iov) (i32.const 12)))\n\
        \      (then unreachable))\n\
        \    (local.set $fd (i32.load offset=12 (local.get $iov)))\n\
        \    (i32.store offset=0 (local.get $iov) (local.get $content))\n\
        \    (i32.store offset=4 (local.get $iov) (local.get $clen))\n\
        \    (drop (call $fd_write (local.get $fd) (local.get $iov) (i32.const 1) (i32.add (local.get $iov) (i32.const 8))))\n\
        \    (drop (call $fd_close (local.get $fd)))\n\
        \    (i32.const 0))\n"
      in
      let stdin_fn =
        if not !wasm_stdin_used then "" else
        "  (func $__lang_read_stdin (result i64)\n\
        \    (local $iov i32) (local $start i32) (local $p i32) (local $nread i32)\n\
        \    (local.set $iov (global.get $__lang_bump))\n\
        \    (global.set $__lang_bump (i32.add (local.get $iov) (i32.const 12)))\n\
        \    (local.set $start (i32.add (global.get $__lang_bump) (i32.const 4)))\n\
        \    (local.set $p (local.get $start))\n\
        \    (block $eof (loop $lp\n\
        \      (i32.store offset=0 (local.get $iov) (local.get $p))\n\
        \      (i32.store offset=4 (local.get $iov) (i32.const 4096))\n\
        \      (drop (call $fd_read (i32.const 0) (local.get $iov) (i32.const 1) (i32.add (local.get $iov) (i32.const 8))))\n\
        \      (local.set $nread (i32.load offset=8 (local.get $iov)))\n\
        \      (br_if $eof (i32.eqz (local.get $nread)))\n\
        \      (local.set $p (i32.add (local.get $p) (local.get $nread)))\n\
        \      (global.set $__lang_bump (local.get $p))\n\
        \      (br $lp)))\n\
        \    (i32.store8 (local.get $p) (i32.const 0))\n\
        \    (global.set $__lang_bump (i32.add (local.get $p) (i32.const 1)))\n\
        \    (i32.store (i32.sub (local.get $start) (i32.const 4)) (i32.sub (local.get $p) (local.get $start)))\n\
        \    (i64.extend_i32_u (local.get $start)))\n"
      in
      (* Phase 3 sockets: p2 wasi:sockets imports + in-module _h helpers for
         the mhttp-style socket / raw-memory externs. TCP client only (IPv4
         literal host, no DNS); build with `wasm-tools component embed --world
         <w> <wasi.wit>` (extracted from the command adapter) then
         `component new --adapt`, and run `wasmtime -S inherit-network=y`. *)
      let socket_imports =
        if not !wasm_socket_ffi then "" else
        "  (import \"wasi:sockets/instance-network@0.2.3\" \"instance-network\" (func $sock_instnet (result i32)))\n\
        \  (import \"wasi:sockets/tcp-create-socket@0.2.3\" \"create-tcp-socket\" (func $sock_create (param i32 i32)))\n\
        \  (import \"wasi:sockets/tcp@0.2.3\" \"[method]tcp-socket.start-connect\" (func $sock_connect (param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)))\n\
        \  (import \"wasi:sockets/tcp@0.2.3\" \"[method]tcp-socket.start-bind\" (func $sock_bind (param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)))\n\
        \  (import \"wasi:sockets/tcp@0.2.3\" \"[method]tcp-socket.finish-bind\" (func $sock_fbind (param i32 i32)))\n\
        \  (import \"wasi:sockets/tcp@0.2.3\" \"[method]tcp-socket.start-listen\" (func $sock_listen (param i32 i32)))\n\
        \  (import \"wasi:sockets/tcp@0.2.3\" \"[method]tcp-socket.finish-listen\" (func $sock_flisten (param i32 i32)))\n\
        \  (import \"wasi:sockets/tcp@0.2.3\" \"[method]tcp-socket.accept\" (func $sock_accept (param i32 i32)))\n\
        \  (import \"wasi:sockets/tcp@0.2.3\" \"[method]tcp-socket.subscribe\" (func $sock_subscribe (param i32) (result i32)))\n\
        \  (import \"wasi:sockets/tcp@0.2.3\" \"[method]tcp-socket.finish-connect\" (func $sock_finish (param i32 i32)))\n\
        \  (import \"wasi:sockets/tcp@0.2.3\" \"[resource-drop]tcp-socket\" (func $sock_drop (param i32)))\n\
        \  (import \"wasi:io/poll@0.2.3\" \"[method]pollable.block\" (func $sock_block (param i32)))\n\
        \  (import \"wasi:io/poll@0.2.3\" \"[resource-drop]pollable\" (func $poll_drop (param i32)))\n\
        \  (import \"wasi:sockets/ip-name-lookup@0.2.3\" \"resolve-addresses\" (func $sock_resolve (param i32 i32 i32 i32)))\n\
        \  (import \"wasi:sockets/ip-name-lookup@0.2.3\" \"[method]resolve-address-stream.subscribe\" (func $sock_rsub (param i32) (result i32)))\n\
        \  (import \"wasi:sockets/ip-name-lookup@0.2.3\" \"[method]resolve-address-stream.resolve-next-address\" (func $sock_rnext (param i32 i32)))\n\
        \  (import \"wasi:sockets/ip-name-lookup@0.2.3\" \"[resource-drop]resolve-address-stream\" (func $rstream_drop (param i32)))\n\
        \  (import \"wasi:sockets/udp-create-socket@0.2.3\" \"create-udp-socket\" (func $ucreate (param i32 i32)))\n\
        \  (import \"wasi:sockets/udp@0.2.3\" \"[method]udp-socket.start-bind\" (func $ubind (param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)))\n\
        \  (import \"wasi:sockets/udp@0.2.3\" \"[method]udp-socket.finish-bind\" (func $ufbind (param i32 i32)))\n\
        \  (import \"wasi:sockets/udp@0.2.3\" \"[method]udp-socket.stream\" (func $ustream (param i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32)))\n\
        \  (import \"wasi:sockets/udp@0.2.3\" \"[resource-drop]udp-socket\" (func $udrop (param i32)))\n\
        \  (import \"wasi:sockets/udp@0.2.3\" \"[method]outgoing-datagram-stream.check-send\" (func $ucheck (param i32 i32)))\n\
        \  (import \"wasi:sockets/udp@0.2.3\" \"[method]outgoing-datagram-stream.send\" (func $usend (param i32 i32 i32 i32)))\n\
        \  (import \"wasi:sockets/udp@0.2.3\" \"[resource-drop]outgoing-datagram-stream\" (func $odrop (param i32)))\n\
        \  (import \"wasi:sockets/udp@0.2.3\" \"[method]incoming-datagram-stream.subscribe\" (func $insub (param i32) (result i32)))\n\
        \  (import \"wasi:sockets/udp@0.2.3\" \"[method]incoming-datagram-stream.receive\" (func $ureceive (param i32 i64 i32)))\n\
        \  (import \"wasi:sockets/udp@0.2.3\" \"[resource-drop]incoming-datagram-stream\" (func $idrop (param i32)))\n\
        \  (import \"wasi:io/streams@0.2.3\" \"[method]output-stream.blocking-write-and-flush\" (func $sock_swrite (param i32 i32 i32 i32)))\n\
        \  (import \"wasi:io/streams@0.2.3\" \"[method]input-stream.blocking-read\" (func $sock_sread (param i32 i64 i32)))\n\
        \  (import \"wasi:io/streams@0.2.3\" \"[resource-drop]input-stream\" (func $in_drop (param i32)))\n\
        \  (import \"wasi:io/streams@0.2.3\" \"[resource-drop]output-stream\" (func $out_drop (param i32)))\n"
      in
      let socket_helpers =
        if not !wasm_socket_ffi then "" else
        "  (func $cabi_realloc (export \"cabi_realloc\") (param i32 i32 i32 i32) (result i32) (local $p i32)\n\
        \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.sub (local.get 2) (i32.const 1))) (i32.sub (i32.const 0) (local.get 2))))\n\
        \    (local.set $p (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $p) (local.get 3))) (local.get $p))\n\
        \  (func $mem_alloc_h (param $n i32) (result i32) (local $p i32)\n\
        \    (local.set $p (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $p) (local.get $n))) (local.get $p))\n\
        \  (func $mem_get_u8_h (param $p i32) (param $o i32) (result i32) (i32.load8_u (i32.add (local.get $p) (local.get $o))))\n\
        \  (func $mem_set_u8_h (param $p i32) (param $o i32) (param $v i32) (result i32)\n\
        \    (i32.store8 (i32.add (local.get $p) (local.get $o)) (local.get $v)) (local.get $v))\n\
        \  (func $mem_get_u16be_h (param $p i32) (param $o i32) (result i32)\n\
        \    (i32.or (i32.shl (i32.load8_u (i32.add (local.get $p) (local.get $o))) (i32.const 8))\n\
        \            (i32.load8_u (i32.add (i32.add (local.get $p) (local.get $o)) (i32.const 1)))))\n\
        \  (func $mem_set_u16be_h (param $p i32) (param $o i32) (param $v i32) (result i32)\n\
        \    (i32.store8 (i32.add (local.get $p) (local.get $o)) (i32.shr_u (local.get $v) (i32.const 8)))\n\
        \    (i32.store8 (i32.add (i32.add (local.get $p) (local.get $o)) (i32.const 1)) (i32.and (local.get $v) (i32.const 255)))\n\
        \    (local.get $v))\n\
        \  (func $tcp_set_timeout_h (param $fd i32) (param $ms i32) (result i32) (i32.const 0))\n\
        \  (func $str_ptr_h (param $s i32) (result i32) (local.get $s))\n\
        \  (func $mem_copy_str_h (param $p i32) (param $o i32) (param $s i32) (result i32) (local $len i32) (local $i i32)\n\
        \    (local.set $len (i32.load (i32.sub (local.get $s) (i32.const 4))))\n\
        \    (block $e (loop $l (br_if $e (i32.ge_u (local.get $i) (local.get $len)))\n\
        \      (i32.store8 (i32.add (i32.add (local.get $p) (local.get $o)) (local.get $i)) (i32.load8_u (i32.add (local.get $s) (local.get $i))))\n\
        \      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))) (local.get $len))\n\
        \  (func $mem_to_str_h (param $p i32) (param $len i32) (result i32) (local $st i32) (local $i i32)\n\
        \    (local.set $st (i32.add (global.get $__lang_bump) (i32.const 4)))\n\
        \    (global.set $__lang_bump (i32.add (local.get $st) (i32.add (local.get $len) (i32.const 1))))\n\
        \    (block $e (loop $l (br_if $e (i32.ge_u (local.get $i) (local.get $len)))\n\
        \      (i32.store8 (i32.add (local.get $st) (local.get $i)) (i32.load8_u (i32.add (local.get $p) (local.get $i))))\n\
        \      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l)))\n\
        \    (i32.store8 (i32.add (local.get $st) (local.get $len)) (i32.const 0))\n\
        \    (i32.store (i32.sub (local.get $st) (i32.const 4)) (local.get $len)) (local.get $st))\n\
        \  (func $__parse_ipv4 (param $s i32) (param $out i32) (local $i i32) (local $oct i32) (local $b i32) (local $c i32)\n\
        \    (block $done (loop $lp\n\
        \      (local.set $c (i32.load8_u (i32.add (local.get $s) (local.get $i))))\n\
        \      (if (i32.or (i32.eqz (local.get $c)) (i32.eq (local.get $c) (i32.const 46)))\n\
        \        (then (i32.store8 (i32.add (local.get $out) (local.get $oct)) (local.get $b))\n\
        \              (local.set $oct (i32.add (local.get $oct) (i32.const 1))) (local.set $b (i32.const 0))\n\
        \              (br_if $done (i32.eqz (local.get $c))))\n\
        \        (else (local.set $b (i32.add (i32.mul (local.get $b) (i32.const 10)) (i32.sub (local.get $c) (i32.const 48))))))\n\
        \      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $lp))))\n\
        \  (func $__resolve_ipv4 (param $net i32) (param $host i32) (param $out i32)\n\
        \    (local $strm i32) (local $poll i32) (local $r i32) (local $hlen i32)\n\
        \    (local.set $hlen (i32.load (i32.sub (local.get $host) (i32.const 4))))\n\
        \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
        \    (local.set $r (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $r) (i32.const 64)))\n\
        \    (call $sock_resolve (local.get $net) (local.get $host) (local.get $hlen) (local.get $r))\n\
        \    (local.set $strm (i32.load (i32.add (local.get $r) (i32.const 4))))\n\
        \    (local.set $poll (call $sock_rsub (local.get $strm))) (call $sock_block (local.get $poll)) (call $poll_drop (local.get $poll))\n\
        \    (block $done (loop $lp\n\
        \      (call $sock_rnext (local.get $strm) (i32.add (local.get $r) (i32.const 8)))\n\
        \      (br_if $done (i32.load8_u (i32.add (local.get $r) (i32.const 8))))\n\
        \      (br_if $done (i32.eqz (i32.load8_u (i32.add (local.get $r) (i32.const 10)))))\n\
        \      (if (i32.eqz (i32.load8_u (i32.add (local.get $r) (i32.const 12))))\n\
        \        (then (i32.store8 offset=0 (local.get $out) (i32.load8_u (i32.add (local.get $r) (i32.const 14))))\n\
        \              (i32.store8 offset=1 (local.get $out) (i32.load8_u (i32.add (local.get $r) (i32.const 15))))\n\
        \              (i32.store8 offset=2 (local.get $out) (i32.load8_u (i32.add (local.get $r) (i32.const 16))))\n\
        \              (i32.store8 offset=3 (local.get $out) (i32.load8_u (i32.add (local.get $r) (i32.const 17))))\n\
        \              (br $done)))\n\
        \      (br $lp)))\n\
        \    (call $rstream_drop (local.get $strm)))\n\
        \  (func $tcp_connect_h (param $host i32) (param $port i32) (result i32)\n\
        \    (local $net i32) (local $sock i32) (local $poll i32) (local $fd i32) (local $s i32)\n\
        \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
        \    (local.set $s (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $s) (i32.const 64)))\n\
        \    (local.set $net (call $sock_instnet))\n\
        \    (if (i32.and (i32.ge_u (i32.load8_u (local.get $host)) (i32.const 48)) (i32.le_u (i32.load8_u (local.get $host)) (i32.const 57)))\n\
        \      (then (call $__parse_ipv4 (local.get $host) (local.get $s)))\n\
        \      (else (call $__resolve_ipv4 (local.get $net) (local.get $host) (local.get $s))))\n\
        \    (call $sock_create (i32.const 0) (i32.add (local.get $s) (i32.const 8)))\n\
        \    (local.set $sock (i32.load (i32.add (local.get $s) (i32.const 12))))\n\
        \    (call $sock_connect (local.get $sock) (local.get $net) (i32.const 0) (local.get $port)\n\
        \      (i32.load8_u (local.get $s)) (i32.load8_u (i32.add (local.get $s) (i32.const 1))) (i32.load8_u (i32.add (local.get $s) (i32.const 2))) (i32.load8_u (i32.add (local.get $s) (i32.const 3)))\n\
        \      (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.add (local.get $s) (i32.const 24)))\n\
        \    (local.set $poll (call $sock_subscribe (local.get $sock))) (call $sock_block (local.get $poll))\n\
        \    (call $poll_drop (local.get $poll))\n\
        \    (call $sock_finish (local.get $sock) (i32.add (local.get $s) (i32.const 32)))\n\
        \    (local.set $fd (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $fd) (i32.const 16)))\n\
        \    (i32.store offset=0 (local.get $fd) (local.get $sock))\n\
        \    (i32.store offset=4 (local.get $fd) (i32.load (i32.add (local.get $s) (i32.const 36))))\n\
        \    (i32.store offset=8 (local.get $fd) (i32.load (i32.add (local.get $s) (i32.const 40))))\n\
        \    (local.get $fd))\n\
        \  (func $tcp_read_h (param $fd i32) (param $buf i32) (param $len i32) (result i32)\n\
        \    (local $in i32) (local $s i32) (local $dp i32) (local $dl i32) (local $i i32) (local $n i32)\n\
        \    (local.set $in (i32.load offset=4 (local.get $fd)))\n\
        \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
        \    (local.set $s (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $s) (i32.const 16)))\n\
        \    (call $sock_sread (local.get $in) (i64.extend_i32_u (local.get $len)) (local.get $s))\n\
        \    (if (i32.load8_u (local.get $s)) (then (return (i32.const 0))))\n\
        \    (local.set $dp (i32.load (i32.add (local.get $s) (i32.const 4))))\n\
        \    (local.set $dl (i32.load (i32.add (local.get $s) (i32.const 8))))\n\
        \    (local.set $n (select (local.get $len) (local.get $dl) (i32.lt_u (local.get $len) (local.get $dl))))\n\
        \    (block $e (loop $l (br_if $e (i32.ge_u (local.get $i) (local.get $n)))\n\
        \      (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.load8_u (i32.add (local.get $dp) (local.get $i))))\n\
        \      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))) (local.get $n))\n\
        \  (func $tcp_write_h (param $fd i32) (param $buf i32) (param $len i32) (result i32) (local $out i32) (local $s i32)\n\
        \    (local.set $out (i32.load offset=8 (local.get $fd)))\n\
        \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
        \    (local.set $s (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $s) (i32.const 16)))\n\
        \    (call $sock_swrite (local.get $out) (local.get $buf) (local.get $len) (local.get $s)) (local.get $len))\n\
        \  (func $tcp_listen_h (param $port i32) (result i32)\n\
        \    (local $net i32) (local $sock i32) (local $fd i32) (local $s i32)\n\
        \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
        \    (local.set $s (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $s) (i32.const 64)))\n\
        \    (local.set $net (call $sock_instnet))\n\
        \    (call $sock_create (i32.const 0) (i32.add (local.get $s) (i32.const 8)))\n\
        \    (local.set $sock (i32.load (i32.add (local.get $s) (i32.const 12))))\n\
        \    (call $sock_bind (local.get $sock) (local.get $net) (i32.const 0) (local.get $port)\n\
        \      (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0)\n\
        \      (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.add (local.get $s) (i32.const 24)))\n\
        \    (call $sock_fbind (local.get $sock) (i32.add (local.get $s) (i32.const 32)))\n\
        \    (call $sock_listen (local.get $sock) (i32.add (local.get $s) (i32.const 40)))\n\
        \    (call $sock_flisten (local.get $sock) (i32.add (local.get $s) (i32.const 48)))\n\
        \    (local.set $fd (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $fd) (i32.const 16)))\n\
        \    (i32.store offset=0 (local.get $fd) (local.get $sock))\n\
        \    (i32.store offset=4 (local.get $fd) (i32.const 0)) (i32.store offset=8 (local.get $fd) (i32.const 0))\n\
        \    (local.get $fd))\n\
        \  (func $tcp_accept_h (param $lfd i32) (result i32)\n\
        \    (local $sock i32) (local $poll i32) (local $fd i32) (local $s i32)\n\
        \    (local.set $sock (i32.load offset=0 (local.get $lfd)))\n\
        \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
        \    (local.set $s (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $s) (i32.const 32)))\n\
        \    (local.set $poll (call $sock_subscribe (local.get $sock))) (call $sock_block (local.get $poll)) (call $poll_drop (local.get $poll))\n\
        \    (call $sock_accept (local.get $sock) (local.get $s))\n\
        \    (local.set $fd (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $fd) (i32.const 16)))\n\
        \    (i32.store offset=0 (local.get $fd) (i32.load (i32.add (local.get $s) (i32.const 4))))\n\
        \    (i32.store offset=4 (local.get $fd) (i32.load (i32.add (local.get $s) (i32.const 8))))\n\
        \    (i32.store offset=8 (local.get $fd) (i32.load (i32.add (local.get $s) (i32.const 12))))\n\
        \    (local.get $fd))\n\
        \  (func $udp_open_h (param $host i32) (param $port i32) (result i32)\n\
        \    (local $net i32) (local $sock i32) (local $fd i32) (local $s i32)\n\
        \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
        \    (local.set $s (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $s) (i32.const 128)))\n\
        \    (local.set $net (call $sock_instnet))\n\
        \    (if (i32.and (i32.ge_u (i32.load8_u (local.get $host)) (i32.const 48)) (i32.le_u (i32.load8_u (local.get $host)) (i32.const 57)))\n\
        \      (then (call $__parse_ipv4 (local.get $host) (local.get $s)))\n\
        \      (else (call $__resolve_ipv4 (local.get $net) (local.get $host) (local.get $s))))\n\
        \    (call $ucreate (i32.const 0) (i32.add (local.get $s) (i32.const 8)))\n\
        \    (local.set $sock (i32.load (i32.add (local.get $s) (i32.const 12))))\n\
        \    (call $ubind (local.get $sock) (local.get $net) (i32.const 0) (i32.const 0)\n\
        \      (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0)\n\
        \      (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.add (local.get $s) (i32.const 24)))\n\
        \    (call $ufbind (local.get $sock) (i32.add (local.get $s) (i32.const 32)))\n\
        \    (call $ustream (local.get $sock) (i32.const 1) (i32.const 0) (local.get $port)\n\
        \      (i32.load8_u (local.get $s)) (i32.load8_u (i32.add (local.get $s) (i32.const 1))) (i32.load8_u (i32.add (local.get $s) (i32.const 2))) (i32.load8_u (i32.add (local.get $s) (i32.const 3)))\n\
        \      (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.const 0) (i32.add (local.get $s) (i32.const 40)))\n\
        \    (local.set $fd (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $fd) (i32.const 16)))\n\
        \    (i32.store offset=0 (local.get $fd) (local.get $sock))\n\
        \    (i32.store offset=4 (local.get $fd) (i32.load (i32.add (local.get $s) (i32.const 44))))\n\
        \    (i32.store offset=8 (local.get $fd) (i32.load (i32.add (local.get $s) (i32.const 48))))\n\
        \    (i32.store offset=12 (local.get $fd) (i32.const 1))\n\
        \    (local.get $fd))\n\
        \  (func $udp_send_h (param $fd i32) (param $buf i32) (param $len i32) (result i32)\n\
        \    (local $out i32) (local $s i32)\n\
        \    (local.set $out (i32.load offset=8 (local.get $fd)))\n\
        \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
        \    (local.set $s (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $s) (i32.const 128)))\n\
        \    (call $ucheck (local.get $out) (local.get $s))\n\
        \    (i32.store offset=0 (i32.add (local.get $s) (i32.const 16)) (local.get $buf))\n\
        \    (i32.store offset=4 (i32.add (local.get $s) (i32.const 16)) (local.get $len))\n\
        \    (i32.store8 offset=8 (i32.add (local.get $s) (i32.const 16)) (i32.const 0))\n\
        \    (call $usend (local.get $out) (i32.add (local.get $s) (i32.const 16)) (i32.const 1) (i32.add (local.get $s) (i32.const 64)))\n\
        \    (local.get $len))\n\
        \  (func $udp_recv_h (param $fd i32) (param $buf i32) (param $len i32) (result i32)\n\
        \    (local $in i32) (local $s i32) (local $poll i32) (local $rec i32) (local $dp i32) (local $dl i32) (local $n i32) (local $i i32)\n\
        \    (local.set $in (i32.load offset=4 (local.get $fd)))\n\
        \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
        \    (local.set $s (global.get $__lang_bump)) (global.set $__lang_bump (i32.add (local.get $s) (i32.const 64)))\n\
        \    (local.set $poll (call $insub (local.get $in))) (call $sock_block (local.get $poll)) (call $poll_drop (local.get $poll))\n\
        \    (call $ureceive (local.get $in) (i64.const 1) (local.get $s))\n\
        \    (if (i32.eqz (i32.load (i32.add (local.get $s) (i32.const 8)))) (then (return (i32.const 0))))\n\
        \    (local.set $rec (i32.load (i32.add (local.get $s) (i32.const 4))))\n\
        \    (local.set $dp (i32.load (local.get $rec)))\n\
        \    (local.set $dl (i32.load (i32.add (local.get $rec) (i32.const 4))))\n\
        \    (local.set $n (select (local.get $len) (local.get $dl) (i32.lt_u (local.get $len) (local.get $dl))))\n\
        \    (block $e (loop $l (br_if $e (i32.ge_u (local.get $i) (local.get $n)))\n\
        \      (i32.store8 (i32.add (local.get $buf) (local.get $i)) (i32.load8_u (i32.add (local.get $dp) (local.get $i))))\n\
        \      (local.set $i (i32.add (local.get $i) (i32.const 1))) (br $l))) (local.get $n))\n\
        \  (func $tcp_close_h (param $fd i32) (local $in i32) (local $out i32)\n\
        \    (if (i32.load offset=12 (local.get $fd))\n\
        \      (then\n\
        \        (call $idrop (i32.load offset=4 (local.get $fd)))\n\
        \        (call $odrop (i32.load offset=8 (local.get $fd)))\n\
        \        (call $udrop (i32.load offset=0 (local.get $fd))))\n\
        \      (else\n\
        \        (local.set $in (i32.load offset=4 (local.get $fd))) (local.set $out (i32.load offset=8 (local.get $fd)))\n\
        \        (if (local.get $in) (then (call $in_drop (local.get $in))))\n\
        \        (if (local.get $out) (then (call $out_drop (local.get $out))))\n\
        \        (call $sock_drop (i32.load offset=0 (local.get $fd))))))\n"
      in
      "  (import \"wasi_snapshot_preview1\" \"fd_write\" (func $fd_write (param i32 i32 i32 i32) (result i32)))\n"
      ^ socket_imports
      ^ args_imports
      ^ clock_import
      ^ env_imports
      ^ stdin_import
      ^ file_imports
      ^ "  (func $puts_h (param $p i32)\n\
        \    (local $len i32) (local $b i32)\n\
        \    (local.set $len (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $p)))))\n\
        \    (local.set $b (global.get $__lang_bump))\n\
        \    (global.set $__lang_bump (i32.add (local.get $b) (i32.const 16)))\n\
        \    (i32.store offset=0 (local.get $b) (local.get $p))\n\
        \    (i32.store offset=4 (local.get $b) (local.get $len))\n\
        \    (drop (call $fd_write (i32.const 1) (local.get $b) (i32.const 1) (i32.add (local.get $b) (i32.const 8))))\n\
        \    (i32.store8 offset=12 (local.get $b) (i32.const 10))\n\
        \    (i32.store offset=0 (local.get $b) (i32.add (local.get $b) (i32.const 12)))\n\
        \    (i32.store offset=4 (local.get $b) (i32.const 1))\n\
        \    (drop (call $fd_write (i32.const 1) (local.get $b) (i32.const 1) (i32.add (local.get $b) (i32.const 8)))))\n"
      ^ cstr_to_str_fn
      ^ args_fn
      ^ clock_fn
      ^ env_fn
      ^ stdin_fn
      ^ file_fn
      ^ socket_helpers
    else
      "  (func $puts_h (param i32))\n"
  in
  let component_section =
    if not component then "" else
    let cabi_realloc =
      "  (func $cabi_realloc (export \"cabi_realloc\") (param $o i32) (param $os i32) (param $al i32) (param $ns i32) (result i32)\n\
      \    (local $p i32)\n\
      \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.sub (local.get $al) (i32.const 1))) (i32.sub (i32.const 0) (local.get $al))))\n\
      \    (local.set $p (global.get $__lang_bump))\n\
      \    (global.set $__lang_bump (i32.add (local.get $p) (local.get $ns)))\n\
      \    (local.get $p))\n"
    in
    (* Given a Mere str ptr in local $s, allocate an 8-byte return area
       (align 4) and store the canonical ABI string [ptr, len]; leave the
       retptr as the result. Shared by every run shape returning a string. *)
    let lower_str_tail =
      "    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 3)) (i32.const -4)))\n\
      \    (local.set $ret (global.get $__lang_bump))\n\
      \    (global.set $__lang_bump (i32.add (local.get $ret) (i32.const 8)))\n\
      \    (i32.store offset=0 (local.get $ret) (local.get $s))\n\
      \    (i32.store offset=4 (local.get $ret) (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (local.get $s)))))\n\
      \    (local.get $ret))\n"
    in
    if main_ty_walked = Ast.TyUnit || main_ty_walked = Ast.TyInt then
      (* Phase 2: command component (unit or int/exit-code main). No
         cabi_realloc/run — export _start,
         which runs $main (its prints, and the trailing "()", reach stdout
         via $puts -> fd_write). Feed to `wasm-tools component new --adapt
         wasi_snapshot_preview1=<command adapter>` for a wasi:cli/run comp. *)
      "  (func (export \"_start\") (drop (call $main)))\n"
    else
    cabi_realloc ^
    (match main_ty_walked with
     (* Slice 1: func() -> string. $main returns the raw str ptr; lower it. *)
     | Ast.TyStr ->
       "  (func $run (export \"run\") (result i32)\n\
       \    (local $s i32) (local $ret i32)\n\
       \    (local.set $s (call $main))\n" ^ lower_str_tail
     (* Slice 2: func(string) -> string. The top-level value is a closure
        (record { env @0, fn_idx @4 }). Lift the incoming (ptr,len) into a
        fresh NUL-terminated Mere str (manual byte copy — no bulk-memory
        dependency), call the closure via call_indirect (env, arg, fn_idx),
        then lower the result string. *)
     | Ast.TyArrow (a, b) when Ast.walk a = Ast.TyStr && Ast.walk b = Ast.TyStr ->
       "  (func $run (export \"run\") (param $p i32) (param $n i32) (result i32)\n\
       \    (local $arg i32) (local $cl i32) (local $s i32) (local $ret i32) (local $i i32)\n\
       \    (local.set $arg (global.get $__lang_bump))\n\
       \    (global.set $__lang_bump (i32.add (local.get $arg) (i32.add (local.get $n) (i32.const 1))))\n\
       \    (block $done (loop $lp\n\
       \      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))\n\
       \      (i32.store8 (i32.add (local.get $arg) (local.get $i)) (i32.load8_u (i32.add (local.get $p) (local.get $i))))\n\
       \      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n\
       \      (br $lp)))\n\
       \    (i32.store8 (i32.add (local.get $arg) (local.get $n)) (i32.const 0))\n\
       \    (local.set $cl (call $main))\n\
       \    (local.set $s (i32.wrap_i64 (call_indirect (type $cl)\n\
       \      (i64.extend_i32_u (i32.load offset=0 (local.get $cl)))\n\
       \      (i64.extend_i32_u (local.get $arg))\n\
       \      (i32.load offset=4 (local.get $cl)))))\n" ^ lower_str_tail
     (* Slice 3: func(string) -> result<f64, string> (the eval shape). The
        closure returns a Mere variant record { tag:i64 @0, payload:i64 @8 }
        (Ok=tag 0, Err=tag 1). Ok's payload is a boxed-float ptr (points to an
        f64); Err's payload is a Mere str ptr. Re-lower to the canonical
        result<f64,string>: a 16-byte, 8-aligned return area with disc:u8 @0
        (0=ok,1=err) and payload @8 (ok: f64; err: string (ptr @8, len @12)). *)
     | Ast.TyArrow (a, b)
       when Ast.walk a = Ast.TyStr
            && (match Ast.walk b with
                | Ast.TyCon ("result", [x; y]) ->
                  Ast.walk x = Ast.TyFloat && Ast.walk y = Ast.TyStr
                | _ -> false) ->
       "  (func $run (export \"run\") (param $p i32) (param $n i32) (result i32)\n\
       \    (local $arg i32) (local $cl i32) (local $rec i32) (local $ret i32) (local $i i32)\n\
       \    (local.set $arg (global.get $__lang_bump))\n\
       \    (global.set $__lang_bump (i32.add (local.get $arg) (i32.add (local.get $n) (i32.const 1))))\n\
       \    (block $done (loop $lp\n\
       \      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))\n\
       \      (i32.store8 (i32.add (local.get $arg) (local.get $i)) (i32.load8_u (i32.add (local.get $p) (local.get $i))))\n\
       \      (local.set $i (i32.add (local.get $i) (i32.const 1)))\n\
       \      (br $lp)))\n\
       \    (i32.store8 (i32.add (local.get $arg) (local.get $n)) (i32.const 0))\n\
       \    (local.set $cl (call $main))\n\
       \    (local.set $rec (i32.wrap_i64 (call_indirect (type $cl)\n\
       \      (i64.extend_i32_u (i32.load offset=0 (local.get $cl)))\n\
       \      (i64.extend_i32_u (local.get $arg))\n\
       \      (i32.load offset=4 (local.get $cl)))))\n\
       \    (global.set $__lang_bump (i32.and (i32.add (global.get $__lang_bump) (i32.const 7)) (i32.const -8)))\n\
       \    (local.set $ret (global.get $__lang_bump))\n\
       \    (global.set $__lang_bump (i32.add (local.get $ret) (i32.const 16)))\n\
       \    (if (i32.eqz (i32.load offset=0 (local.get $rec)))\n\
       \      (then\n\
       \        (i32.store8 offset=0 (local.get $ret) (i32.const 0))\n\
       \        (f64.store offset=8 align=8 (local.get $ret)\n\
       \          (f64.load offset=0 align=8 (i32.wrap_i64 (i64.load offset=8 (local.get $rec))))))\n\
       \      (else\n\
       \        (i32.store8 offset=0 (local.get $ret) (i32.const 1))\n\
       \        (i32.store offset=8 (local.get $ret) (i32.wrap_i64 (i64.load offset=8 (local.get $rec))))\n\
       \        (i32.store offset=12 (local.get $ret)\n\
       \          (i32.wrap_i64 (call $__lang_strlen (i64.extend_i32_s (i32.wrap_i64 (i64.load offset=8 (local.get $rec))))))))) \n\
       \    (local.get $ret))\n"
     (* Not yet supported under --component (later slices). *)
     | _ -> "  (func $run (export \"run\") (result i32) unreachable)\n")
  in
  Printf.sprintf
    "(module\n\
     \  (type $cl (func (param i64) (param i64) (result i64)))\n\
     %s\
     %s\
     %s\
     %s\
     \  (global $__mere_abi (export \"__mere_abi\") i32 (i32.const 1))\n\
     \  (global $__lang_bump (export \"__lang_bump\") (mut i32) (i32.const %d))\n\
  (global $__rgn_tmp (mut i64) (i64.const 0))\n\
     \  (global $__lang_char_table i32 (i32.const %d))\n\
     \  (global $__lang_char_table_initialized (mut i32) (i32.const 0))\n\
     \  (global $__lang_fail_flag (mut i32) (i32.const 0))\n\
     \  (global $__lang_fail_active (mut i32) (i32.const 0))\n\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     %s\
     \  (func $main (export \"main\") (result i32)\n%s%s)\n\
     )\n"
    puts_decl
    file_io_imports
    memory_section
    table_section bump_init char_table_offset
    top_globals_section
    data_section runtime_helpers
    list_str_runtime_section
    vec_runtime_section
    vec_higher_order_section strbuf_section map_key_eq_section map_runtime_section
    (args_host_section ^ vec_to_list_section) list_len_section
    fn_section component_section local_decl indented_body

(* The table `mere -wg` prints: which Mere line each Wasm function came from.
   A tool with the assembled binary turns this into a source map, matching the
   names against the binary's name section. *)
let emit_debug_map ?(main_ty = Ast.TyInt) ?(component = false)
    ~(source : string) (prog : Ast.program) : string =
  ignore (emit_program ~main_ty ~component prog);
  let buf = Buffer.create 256 in
  Buffer.add_string buf
    (Printf.sprintf "# mere-wasm debug map v1 source=%s\n" source);
  List.iter (fun (name, line) ->
    Buffer.add_string buf (Printf.sprintf "F %s %d\n" name line))
    (List.rev !debug_fn_lines);
  Buffer.contents buf
