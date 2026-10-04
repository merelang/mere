(* rv_prelude.ml — a Mere-source runtime prelude injected only on the RV32I
   backend. The self-hosted compiler leans on a tail of "derived" builtins
   (string helpers, char classification, Map) that the interpreter and the
   C/LLVM/Wasm backends provide natively. Rather than hand-assemble each one,
   we DEFINE them in Mere on top of the primitives codegen_riscv already emits
   (char_at / ord / chr / substring / str_len / str_eq / ++ / Vec / Cons /
   tuples). These top-level bindings shadow the builtins of the same name
   (compile_app resolves user bindings first), and only the ones the program
   actually reaches are emitted.

   Injected by prepending to the user source in the -rv path, so everything
   goes through the normal typer + desugar. Semantics mirror lib/eval.ml so
   output stays byte-identical to the interpreter. `substring s a b` is
   end-exclusive (b is the stop index). *)

let contents = {mere|
// --- integer builtins this backend never had -----------------------------
// These are not scaffolding: they are the definitions, in Mere, on top of
// primitives codegen_riscv already emits. They were on the refused list only
// because nothing had written them.
let abs = fn (n: int) -> if n < 0 then 0 - n else n;
let max = fn (a: int) -> fn (b: int) -> if a > b then a else b;
let min = fn (a: int) -> fn (b: int) -> if a < b then a else b;
let clamp = fn (lo: int) -> fn (hi: int) -> fn (n: int) ->
  if n < lo then lo else if n > hi then hi else n;
let even = fn (n: int) -> n % 2 == 0;
let odd = fn (n: int) -> n % 2 != 0;
let rec gcd = fn (a: int) -> fn (b: int) ->
  let x = if a < 0 then 0 - a else a in
  let y = if b < 0 then 0 - b else b in
  if y == 0 then x else gcd y (x % y);

// substring's range check, with the message the C backend gives: naming the
// range and the length is what lets a caller see WHICH argument was nonsense,
// and "out of bounds" (the assembly helper's backstop message) names neither.
// A wrapper here rather than message-building in assembly: the check is three
// compares and the message is one concat, both of which are Mere's job. The
// slice itself stays in the helper, reached through the private raw name.
let substring = fn (s: str) -> fn (a: int) -> fn (b: int) ->
  let n = str_len s in
  if a < 0 || b > n || a > b then
    fail ("substring: range [" ++ str_of_int a ++ ", " ++ str_of_int b
          ++ ") invalid for str of length " ++ str_of_int n)
  else __rv_substring_raw s a b;

// --- host services --------------------------------------------------------
// The hosted target HAS a host: the same Linux-numbered ecall mechanism that
// carries print and exit also answers openat/read/write/close/faccessat, so
// read_file, write_file, file_exists and read_stdin below are real. `--bare`
// refuses each of those at compile time, by name, in codegen -- a machine has
// devices, not syscalls, and that half of the old reasoning is still true.
//
// What remains on the refused list is refused for its own stated reason, not
// as leftovers:
//
//   run          PERMANENT. `run` hands a command line to a shell and inherits
//                its stdio. There is no shell on the other side of an ecall --
//                the emulator could only fake one by running commands ITSELF,
//                on the host, with the emulator's own privileges, which makes
//                every guest program a host program. An interpreter that wants
//                `system` on this target should say the target cannot, which
//                is what the catchable stop below lets it do.
//   bytes        the `bytes` TYPE has no representation on this backend at
//                all; not a host service, same catchable stop for the same
//                "a program that never builds one runs" reason.
//
// These stop with a message rather than being refused at compile time, for the
// reason the `extern fn` calls do -- refusing refuses the whole program for a
// call it may never make, and the program this backend is carried for is an
// interpreter whose scripts mostly touch none of them.
//
// `random_int` is answered by the host's getrandom (see __rv_urandom32), never
// faked: a deterministic sequence returned from something named random is the
// kind of wrong that stays quiet.
// The machine is named by width (`RV32I:` is what host_matrix.sh keys on), and
// the reason is the one that holds on both paths: hosted, the emulator answers
// a fixed set of Linux calls and these are not among them; under --bare there
// is no host at all. It used to say "--bare" on the hosted path too.
let __h_todo = fn (n: str) ->
  fail ((if __rv_xlen () == 64 then "RV64I: " else "RV32I: ") ++ n
        ++ " needs a host service this target does not provide (a hosted run answers a fixed set of Linux calls; --bare answers none)");
let run = fn (c: str) -> (__h_todo "run" : int);

// read_file / file_exists ARE answered here, through openat/read/close and
// faccessat -- the same Linux-numbered ecall mechanism `print` and `exit`
// already use. They were on the list above on the strength of `--bare`, which
// is true of --bare and was never true of the hosted target, and the cost was
// specific: the interpreter this backend is carried for could only be handed a
// program with `-e`, because reading a script off disk went through read_file.
// Under --bare the codegen refuses these by name, so the machine-only target
// keeps the property the list was protecting.
//
// The error is a `fail` and therefore catchable, which is what an interpreter
// needs in order to turn it into its own exception -- ruby raises Errno::ENOENT
// here, and it cannot do that if the process is simply gone. The negative
// return IS the errno, so the message can say which one.
let read_file = fn (p: str) ->
  let fd = __rv_open_rd p in
  if fd < 0 then fail ("read_file: cannot open " ++ p ++ " (errno " ++ str_of_int (0 - fd) ++ ")")
  else __rv_read_all fd;
let file_exists = fn (p: str) -> __rv_access p == 0;

// write_file: openat(O_WRONLY|O_CREAT|O_TRUNC) + a short-write-safe loop +
// close, all Linux-numbered -- the same reasoning as read_file above, and the
// same catchability: mere-ruby turns this fail into Errno::EACCES/ENOENT.
let write_file = fn (p: str) -> fn (c: str) ->
  let fd = __rv_open_wr p in
  if fd < 0 then fail ("write_file: cannot open " ++ p ++ " (errno " ++ str_of_int (0 - fd) ++ ")")
  else
    let r = __rv_write_all fd c in
    if r < 0 then fail ("write_file: the host stopped taking bytes for " ++ p ++ " (errno " ++ str_of_int (0 - r) ++ ")")
    else ();
// `args` is the one host service on this list that is not a host service here:
// the loader leaves the arguments in RAM and this walks them. A program built
// with -rv therefore reads its own command line, and one started by a loader
// that left the block untouched sees Nil -- which is the true answer, not an
// error, because it really was given no arguments.
let rec __rv_args_go = fn (i: int) -> fn (n: int) ->
  if i >= n then (Nil : str list) else Cons (__rv_argstr i, __rv_args_go (i + 1) n);
let args = fn (u: unit) -> __rv_args_go 0 (__rv_argc ());

// read_stdin: fd 0 through the same slurp read_file uses. The emulator serves
// read(0) from its own stdin; the close(0) the slurp ends with answers -EBADF
// there and the slurp ignores close's answer, which is the right amount of
// caring about closing stdin.
let read_stdin = fn (u: unit) -> __rv_read_all 0;
// Q-110: `bytes` IS represented here since v0.1.426 -- the str block layout
// ([len word][bytes], word-padded) -- and bytes_of_str / str_of_bytes /
// bytes_len / bytes_get / bytes_slice / bytes_concat / bytes_of_hex lower in
// codegen_riscv. What remains below are the ones that need a host.
// (was:) `bytes` has no representation on this backend at all -- these are not a host
// service but the type itself, and they are here for the same reason: a program
// that never builds one runs.
// print_bytes is the str write: a bytes value IS a str block here, and the
// write goes by the length word, so a NUL is written like any other byte.
let print_bytes = fn (b: bytes) -> print_no_nl (str_of_bytes b);
// Q-110 (v0.1.428): a bytes value IS a str block here, so reading a file as
// bytes is reading it as a str -- the same openat / read / close path.
let read_bytes = fn (p: str) -> bytes_of_str (read_file p);

// --- floats: a scaffold, and it says so -----------------------------------
// A float on this target is a two-word block (the two halves of the IEEE 754
// pattern), which codegen_riscv builds for a literal and takes apart for
// `float_bits_hi` / `float_bits_lo`. The ARITHMETIC is not lowered yet.
//
// contrib/softfloat computes all of it in integers and is gated bit-for-bit
// against the hardware; what is missing is the wiring, which has to map
// `float` operations onto that library's record type across the typer
// boundary. Until then these shadow the builtins and stop with a message.
//
// EVERY ONE IS ANNOTATED at the builtin's own type. Without the annotations
// inference makes them `'a -> 'b`, which unifies with anything and moves the
// failure somewhere else entirely: mere-ruby stopped with `expected float, got
// int` on a line whose two operands were both these shims, because a fresh
// type variable let `/` resolve as integer division.
//
// Only the ones a program actually reaches are emitted, so a program that never
// touches floats pays nothing.
// What is left after softfloat: the transcendentals, `f_pow`, and
// `f_min`/`f_max`. The message used to say softfloat "is not yet
// injected into the -rv prelude", which stopped being true the day it was --
// and would have gone on telling every user to go and do the thing that had
// already been done.



// --- misc ----------------------------------------------------------------
let not = fn b -> if b then false else true;

// --- character classification (str -> bool, single char) -----------------
let is_digit = fn s -> if str_len s == 1 then (let c = ord s in c >= 48 && c <= 57) else false;
let is_alpha = fn s -> if str_len s == 1 then (let c = ord s in (c >= 97 && c <= 122) || (c >= 65 && c <= 90)) else false;
let is_space = fn s -> if str_len s == 1 then (let c = ord s in c == 32 || c == 9 || c == 10 || c == 13) else false;

// --- string helpers ------------------------------------------------------
let str_starts_with = fn s -> fn p ->
  let pl = str_len p in if pl > str_len s then false else str_eq (substring s 0 pl) p;
let str_ends_with = fn s -> fn p ->
  let sl = str_len s in let pl = str_len p in
  if pl > sl then false else str_eq (substring s (sl - pl) sl) p;

let str_index_of = fn h -> fn n ->
  let hl = str_len h in let nl = str_len n in
  if nl == 0 then 0
  else
    let rec scan = fn i ->
      if i + nl > hl then 0 - 1
      else if str_eq (substring h i (i + nl)) n then i
      else scan (i + 1) in
    scan 0;
let str_contains = fn h -> fn n -> str_index_of h n >= 0;

// The builders go through StrBuf, which is a real byte buffer on this backend
// (amortized O(1) push). They used to fold `++` over an accumulator: correct,
// and O(n^2) in total allocation -- a 200KB str_repeat allocated ~2GB of dead
// intermediates on a bump allocator that never frees, which is how
// str_edges@64 ran out of a 128MB machine.
let str_repeat = fn s -> fn n ->
  let b = strbuf_new () in
  let rec go = fn (i: int) -> if i <= 0 then () else let _ = strbuf_push b s in go (i - 1) in
  let _ = go n in
  strbuf_to_str b;

let str_rev = fn s ->
  let b = strbuf_new () in
  let rec go = fn (i: int) -> if i < 0 then () else let _ = strbuf_push b (char_at s i) in go (i - 1) in
  let _ = go (str_len s - 1) in
  strbuf_to_str b;

let _lc1 = fn c -> let o = ord c in if o >= 65 && o <= 90 then chr (o + 32) else c;
let to_lower = fn s ->
  let b = strbuf_new () in
  let n = str_len s in
  let rec go = fn (i: int) -> if i >= n then () else let _ = strbuf_push b (_lc1 (char_at s i)) in go (i + 1) in
  let _ = go 0 in
  strbuf_to_str b;
let _uc1 = fn c -> let o = ord c in if o >= 97 && o <= 122 then chr (o - 32) else c;
let to_upper = fn s ->
  let b = strbuf_new () in
  let n = str_len s in
  let rec go = fn (i: int) -> if i >= n then () else let _ = strbuf_push b (_uc1 (char_at s i)) in go (i + 1) in
  let _ = go 0 in
  strbuf_to_str b;

// whitespace for trim: ' ' \t \n \r \f  (matches OCaml String.trim)
let _wst = fn c -> let o = ord c in o == 32 || o == 9 || o == 10 || o == 13 || o == 12;
let rec _triml = fn s -> fn i -> if i < str_len s && _wst (char_at s i) then _triml s (i + 1) else i;
let rec _trimr = fn s -> fn i -> if i > 0 && _wst (char_at s (i - 1)) then _trimr s (i - 1) else i;
let str_trim = fn s -> let a = _triml s 0 in let b = _trimr s (str_len s) in if a >= b then "" else substring s a b;

let rec _sj = fn sep -> fn lst -> fn first -> fn acc ->
  match lst with
  | Nil -> acc
  | Cons (x, rest) -> _sj sep rest false (if first then acc ++ x else acc ++ sep ++ x);
let str_join = fn sep -> fn lst -> _sj sep lst true "";

// find d in s at or after i, WITHOUT materializing the tail: the old shape
// took `substring s start (str_len s)` per piece, which copies the whole
// remainder -- splitting a 200KB string into 20001 pieces copied ~2GB of
// tails. The same quadratic the string builders had, in a different dress.
let rec _smatch = fn s -> fn d -> fn i -> fn j ->
  if j >= str_len d then true
  else if str_eq (char_at s (i + j)) (char_at d j) then _smatch s d i (j + 1)
  else false;
let rec _sfind = fn s -> fn d -> fn i ->
  if i + str_len d > str_len s then 0 - 1
  else if _smatch s d i 0 then i
  else _sfind s d (i + 1);
let rec _ssplit = fn s -> fn d -> fn start ->
  let idx = _sfind s d start in
  if idx < 0 then Cons (substring s start (str_len s), Nil)
  else Cons (substring s start idx, _ssplit s d (idx + str_len d));
let str_split = fn s -> fn d -> if str_len d == 0 then Cons (s, Nil) else _ssplit s d 0;

// str_replace through the byte buffer and the offset finder, for both of the
// old shape's quadratics at once (tail copies AND `acc ++` growth)
let str_replace = fn s -> fn old -> fn nw ->
  if str_len old == 0 then s else
  let b = strbuf_new () in
  let rec go = fn (start: int) ->
    let idx = _sfind s old start in
    if idx < 0 then strbuf_push b (substring s start (str_len s))
    else
      let _ = strbuf_push b (substring s start idx) in
      let _ = strbuf_push b nw in
      go (idx + str_len old) in
  let _ = go 0 in
  strbuf_to_str b;

let str_unescape = fn s ->
  let n = str_len s in
  let rec go = fn i -> fn acc ->
    if i >= n then acc
    else
      let c = char_at s i in
      if str_eq c "\\" && i + 1 < n then
        (let d = char_at s (i + 1) in
         let r = if str_eq d "n" then chr 10
                 else if str_eq d "t" then chr 9
                 else if str_eq d "r" then chr 13
                 else if str_eq d "\\" then chr 92
                 else if str_eq d "\"" then chr 34
                 else if str_eq d "/" then chr 47
                 else fail "str_unescape: unknown escape" in
         go (i + 2) (acc ++ r))
      else go (i + 1) (acc ++ c) in
  go 0 "";

let int_of_str = fn s ->
  let t = str_trim s in
  let n = str_len t in
  if n == 0 then fail "int_of_str: empty"
  else
    let neg = str_eq (char_at t 0) "-" in
    let sgn = neg || str_eq (char_at t 0) "+" in
    let start = if sgn then 1 else 0 in
    let rec go = fn i -> fn acc ->
      if i >= n then acc
      else (let c = ord (char_at t i) in
            if c >= 48 && c <= 57 then go (i + 1) (acc * 10 + (c - 48))
            else fail "int_of_str: bad digit") in
    let v = go start 0 in
    if neg then 0 - v else v;

// --- Map: a mutable cell (Vec[1]) holding a Cons-list of (key,value) pairs.
// set prepends (last write wins); str_eq key comparison. Mirrors the
// self-hosted Wasm backend's assoc-list Map. Keys are strings. These use the
// `rvmap_` prefix (not `map_`): the typer special-cases the `map_new` name to
// force the Map type, so codegen_riscv intercepts the map_* builtins and
// dispatches here instead of shadowing them. --------------------------------
let rvmap_new = fn (u : unit) -> let c = vec_new () in let _ = vec_push c Nil in c;
let rvmap_set = fn m -> fn k -> fn v -> vec_set m 0 (Cons ((k, v), vec_get m 0));
let rec _mfind = fn node -> fn k ->
  match node with
  | Nil -> None
  | Cons ((kk, vv), rest) -> if str_eq kk k then Some vv else _mfind rest k;
let rvmap_get = fn m -> fn k ->
  match _mfind (vec_get m 0) k with Some v -> v | None -> fail "map_get: key not found";
let rvmap_has = fn m -> fn k -> match _mfind (vec_get m 0) k with Some v -> true | None -> false;
let rec _mdel = fn node -> fn k ->
  match node with
  | Nil -> Nil
  | Cons ((kk, vv), rest) -> if str_eq kk k then _mdel rest k else Cons ((kk, vv), _mdel rest k);
let rvmap_delete = fn m -> fn k -> vec_set m 0 (_mdel (vec_get m 0) k);
// map_iter: visit each distinct key ONCE, in the order the keys were FIRST
// inserted, carrying that key's most recent value. That is what every other
// backend does, and what a program written against them expects: mere-ruby's
// Hash is ruby's Hash, which is insertion-ordered, and `h[k] = v` on a key that
// is already there keeps its place.
//
// `rvmap_set` PREPENDS, so the list runs newest-first and the naive walk visited
// keys in reverse insertion order -- measured against the C backend, which
// answers `a=99 b=2 c=3` where this answered `a=99 c=3 b=2`. The values were
// right; only the order was backwards, which is why nothing caught it until an
// interpreter printed a Hash.
//
// So: walk the list REVERSED (oldest first, which is first-insertion order),
// and take each key's value from the ORIGINAL list, where the newest write is
// nearest the head. Reversing alone would have paired each key with its OLDEST
// value -- the right order and the wrong values, a trade for the worse.
let rec _mrev = fn node -> fn acc ->
  match node with Nil -> acc | Cons (p, rest) -> _mrev rest (Cons (p, acc));
let rec _mseen = fn seen -> fn k -> match seen with Nil -> false | Cons (x, rest) -> if str_eq x k then true else _mseen rest k;
let rec _miter = fn node -> fn orig -> fn f -> fn seen ->
  match node with
  | Nil -> ()
  | Cons ((kk, vv), rest) ->
    if _mseen seen kk then _miter rest orig f seen
    else
      // vv is this occurrence's value; the live one is whatever _mfind reaches
      // first from the head. They differ exactly when the key was written twice.
      let cur = match _mfind orig kk with Some v -> v | None -> vv in
      let _ = f kk cur in _miter rest orig f (Cons (kk, seen));
let rvmap_iter = fn m -> fn f -> let l = vec_get m 0 in _miter (_mrev l Nil) l f Nil;
// The number of DISTINCT keys. `rvmap_set` prepends, so a key set twice is in
// the list twice and the newer one shadows the older; counting nodes would count
// the shadowed ones. This is the same walk `_miter` does, with a counter instead
// of a callback.
// The reclamation API, for a map that has no arena. `map_compact` returns
// bytes an arena is holding after entries were overwritten or deleted, and
// KEEPS the entries; this representation is an assoc list of ordinary values,
// so there is nothing behind it to return and a no-op is the honest answer.
//
// `map_recycle` is NOT that: its contract is `map_clear` plus the arena
// wind-back (docs/changelog v0.1.300 -- "semantically map_clear, and on the C
// backend it also winds the arena back"). This backend had it as a no-op too,
// reasoning from the half it cannot do to skipping the half it can -- and the
// cost surfaced a long way off: mere-ruby pools its call frames and cleans a
// dead frame with ONE map_recycle, so on this backend every recycled frame
// came back still holding the previous call's locals. A bare identifier in a
// method then resolved to another method's variable: `def f(v); q = v; end`
// left `q` visible to the next call, and a Comparable's `n <=> o.n` read both
// sides from the same leaked slot and answered 0. The wrongness was silent --
// nothing crashed; values were merely someone else's.
//
// `map_bytes` is different again: it asks HOW MANY bytes the arena holds, and
// answering 0 would read as "this map uses no memory" rather than "the
// question does not apply here". So it stops and says which it is.
let rvmap_clear = fn m -> vec_set m 0 Nil;
let rvmap_compact = fn m -> ();
let rvmap_recycle = fn m -> vec_set m 0 Nil;   // clear; the arena half has nothing to do
let rvvec_bytes = fn v -> fail "RV32I: vec_bytes measures an arena, and a Vec here is a plain block with none -- there is no number to give";
let rvmap_bytes = fn m -> fail "RV32I: map_bytes measures an arena, and this target's Map is an assoc list with none -- there is no number to give";

let rvmap_len = fn m ->
  let rec go = fn node -> fn seen -> fn acc ->
    match node with
    | Nil -> acc
    | Cons ((kk, vv), rest) ->
      if _mseen seen kk then go rest seen acc
      else go rest (Cons (kk, seen)) (acc + 1) in
  go (vec_get m 0) Nil 0;
// v0.1.599: the same Map with `int` (or `bool`) keys, compared as words.
// `str_eq` read an int key's value as a string's address and length, which is
// why such a key was refused (codegen_riscv's check_map_key); mere-ruby's object
// table is keyed by object id. codegen_riscv sends a Map whose key type is int
// or bool here, by the Map's own type, so map_len and map_iter -- which take no
// key -- go to the same family as map_set.
let rec _mfind_i = fn node -> fn (k : int) ->
  match node with
  | Nil -> None
  | Cons ((kk, vv), rest) -> if kk == k then Some vv else _mfind_i rest k;
let rvmap_get_i = fn m -> fn k ->
  match _mfind_i (vec_get m 0) k with Some v -> v | None -> fail "map_get: key not found";
let rvmap_has_i = fn m -> fn k -> match _mfind_i (vec_get m 0) k with Some v -> true | None -> false;
let rec _mdel_i = fn node -> fn (k : int) ->
  match node with
  | Nil -> Nil
  | Cons ((kk, vv), rest) -> if kk == k then _mdel_i rest k else Cons ((kk, vv), _mdel_i rest k);
let rvmap_delete_i = fn m -> fn k -> vec_set m 0 (_mdel_i (vec_get m 0) k);
let rec _mseen_i = fn seen -> fn (k : int) -> match seen with Nil -> false | Cons (x, rest) -> if x == k then true else _mseen_i rest k;
let rec _miter_i = fn node -> fn orig -> fn f -> fn seen ->
  match node with
  | Nil -> ()
  | Cons ((kk, vv), rest) ->
    if _mseen_i seen kk then _miter_i rest orig f seen
    else
      let cur = match _mfind_i orig kk with Some v -> v | None -> vv in
      let _ = f kk cur in _miter_i rest orig f (Cons (kk, seen));
let rvmap_iter_i = fn m -> fn f -> let l = vec_get m 0 in _miter_i (_mrev l Nil) l f Nil;
// (top-level, not an inner `let rec`: an inner function would renumber every
// later program's lifted helpers, and change their bytes for nothing)
let rec _mlen_i = fn node -> fn seen -> fn acc ->
  match node with
  | Nil -> acc
  | Cons ((kk, vv), rest) ->
    if _mseen_i seen kk then _mlen_i rest seen acc
    else _mlen_i rest (Cons (kk, seen)) (acc + 1);
let rvmap_len_i = fn m -> _mlen_i (vec_get m 0) Nil 0;
// --- softfloat, for float arithmetic on a backend with no float ----------
// Spliced in HERE, at the end, and not next to the other host-service shims:
// top-level order matters in Mere, and this library calls `not`, which the
// prelude itself defines further down. Placed earlier it referred to a name that
// did not exist yet -- and the failure named `not`, not the placement.
|mere} ^ Rv_softfloat.contents ^ {mere|
// --- float arithmetic ------------------------------------------------------
// This backend has no float unit and no 64-bit word. A float value here is the
// two 32-bit halves of its IEEE 754 pattern, which is enough to HOLD one and
// not enough to compute with: a product of two 32-bit halves does not fit a
// signed 32-bit int. So each operator decodes both operands into 15-bit limbs,
// works there, and re-encodes.
//
// It is slow, and that is the honest trade. The alternative on a target with no
// float unit is to refuse, which is what this did before: mere-ruby carries
// float code on paths a script never reaches, and `1 + 1` reached one anyway.
//
// The names are `__sf_`-prefixed because this file is prepended to the user's
// program, so a program with its own top-level `add` would otherwise supply what
// `+` on floats calls.
// --- RV64: a double as ONE 64-bit word --------------------------------------
// On RV64 the int is 64 bits, so the whole IEEE pattern fits one and the 53-bit
// significand fits with room to spare: everything below is plain integer
// arithmetic on words, with no record built on the way. The limb library above
// built a record per operand per step -- about 2 KB of heap per `+`, and a
// region gives nothing back on this target, so mere-ruby's `**` cost ~600 KB.
// Here an operation allocates only its result's two-word block.
//
// It is the SAME algorithm as contrib/softfloat, transcribed: the working
// significand is shifted left 3 (guard, round, sticky), a value is
// `s * 2^(e - 1078)` in `pack`, every NaN rule is the limb library's (which was
// measured against the hardware), and int_of_float keeps the limb library's
// answers out of range too. Only the representation differs, and the RV64 run
// of test/float/rv_float_ops.mere holds the two to the same bits as the
// hardware. `if __rv_xlen () == 64` is decided at compile time
// (codegen_riscv's xlen_test), so none of this is compiled for RV32, where an
// int cannot hold the word.
//
// No tuples and no closures: each step is a top-level function of ints, so a
// call allocates nothing. Constants are built by shifting; no literal here is
// 2^31 or more.
let __f64_bits = fn (x: float) ->
  let m32 = bit_shl 1 32 - 1 in
  bit_or (bit_shl (bit_and (float_bits_hi x) m32) 32) (bit_and (float_bits_lo x) m32);
let __f64_float = fn (b: int) ->
  let m32 = bit_shl 1 32 - 1 in
  float_of_bits (bit_and (bit_shr b 32) m32) (bit_and b m32);
let __f64_exp = fn (b: int) -> bit_and (bit_shr b 52) 2047;
let __f64_frac = fn (b: int) -> bit_and b (bit_shl 1 52 - 1);
let __f64_sign = fn (b: int) -> bit_and (bit_shr b 63) 1;
let __f64_mag = fn (b: int) -> bit_and b (bit_shl 1 63 - 1);
let __f64_mk = fn (sign: int) -> fn (e: int) -> fn (f: int) ->
  bit_or (bit_or (bit_shl sign 63) (bit_shl e 52)) f;
let __f64_is_nan = fn (b: int) -> __f64_exp b == 2047 && __f64_frac b != 0;
let __f64_is_snan = fn (b: int) -> __f64_is_nan b && bit_and b (bit_shl 1 51) == 0;
let __f64_is_inf = fn (b: int) -> __f64_exp b == 2047 && __f64_frac b == 0;
let __f64_is_zero = fn (b: int) -> __f64_mag b == 0;
let __f64_quiet = fn (b: int) -> bit_or b (bit_shl 1 51);
let __f64_nan = fn (u: unit) -> __f64_mk 0 2047 (bit_shl 1 51);
let __f64_inf = fn (sign: int) -> __f64_mk sign 2047 0;
let __f64_eff = fn (b: int) -> if __f64_exp b == 0 then 1 else __f64_exp b;
// the significand with its hidden bit, unshifted (53 bits for a normal)
let __f64_sig = fn (b: int) ->
  if __f64_exp b == 0 then __f64_frac b else bit_or (__f64_frac b) (bit_shl 1 52);
// bit length of a non-negative int, by halving steps
let rec __f64_bl = fn (x: int) -> fn (n: int) -> fn (k: int) ->
  if k == 0 then (if x > 0 then n + 1 else n)
  else if bit_shr x k > 0 then __f64_bl (bit_shr x k) (n + k) (k / 2)
  else __f64_bl x n (k / 2);
let __f64_blen = fn (x: int) -> __f64_bl x 0 32;
// x >> n, and whether any of the n bits shifted out was set (0 <= n <= 62)
let __f64_lost = fn (x: int) -> fn (n: int) ->
  if n <= 0 then 0 else if bit_and x (bit_shl 1 n - 1) != 0 then 1 else 0;

// pack: s carries the 3 extra bits, value s * 2^(e - 1078); round to nearest,
// ties to even. Four steps, each a function of ints: down (a carry above bit
// 55), underflow (an exponent below 1 shifts into a subnormal), up (leading
// zeros, stopping at e = 1), round.
let __f64_pk_round = fn (sign: int) -> fn (s1: int) -> fn (e1: int) -> fn (st: int) ->
  let lsb = bit_and (bit_shr s1 3) 1 in
  let rnd = bit_and (bit_shr s1 2) 1 in
  let sticky = if bit_and s1 3 != 0 || st != 0 then 1 else 0 in
  let s2 = if rnd == 1 && (sticky == 1 || lsb == 1) then s1 + 8 else s1 in
  let carry = s2 >= bit_shl 1 56 in
  let sr = if carry then bit_shr s2 1 else s2 in
  let e3 = if carry then e1 + 1 else e1 in
  let s3 = bit_shr sr 3 in
  if e3 >= 2047 then __f64_inf sign
  else if bit_and (bit_shr s3 52) 1 == 1 then __f64_mk sign e3 (bit_and s3 (bit_shl 1 52 - 1))
  else if s3 == 0 then __f64_mk sign 0 0
  else __f64_mk sign 0 s3;
let __f64_pk_up = fn (sign: int) -> fn (s: int) -> fn (e: int) -> fn (st: int) ->
  if e <= 1 || s == 0 || s >= bit_shl 1 55 then __f64_pk_round sign s e st
  else
    let want = 56 - __f64_blen s in
    let sh = if want < e - 1 then want else e - 1 in
    __f64_pk_round sign (bit_shl s sh) (e - sh) st;
let __f64_pk_uf = fn (sign: int) -> fn (s: int) -> fn (e: int) -> fn (st: int) ->
  if e >= 1 then __f64_pk_up sign s e st
  else
    let n = if 1 - e > 60 then 60 else 1 - e in
    let s2 = bit_shr s n in
    let st2 = if st != 0 || __f64_lost s n != 0 || s2 == 0 then 1 else 0 in
    __f64_pk_up sign s2 1 st2;
let __f64_pack = fn (sign: int) -> fn (s: int) -> fn (e: int) -> fn (st: int) ->
  if s < bit_shl 1 56 then __f64_pk_uf sign s e st
  else
    let n = __f64_blen s - 56 in
    __f64_pk_uf sign (bit_shr s n) (e + n) (if st != 0 || __f64_lost s n != 0 then 1 else 0);

let __f64_add_mag = fn (a: int) -> fn (b: int) ->
  let ea = __f64_eff a in let eb = __f64_eff b in
  let sa = bit_shl (__f64_sig a) 3 in let sb = bit_shl (__f64_sig b) 3 in
  let a_first = if ea != eb then ea > eb else sa >= sb in
  let hs = if a_first then __f64_sign a else __f64_sign b in
  let ls = if a_first then __f64_sign b else __f64_sign a in
  let he = if a_first then ea else eb in
  let le = if a_first then eb else ea in
  let hv = if a_first then sa else sb in
  let lv = if a_first then sb else sa in
  let d = he - le in
  let lv2 = if d > 60 then 0 else bit_shr lv d in
  let st = if d > 60 then (if lv != 0 then 1 else 0) else __f64_lost lv d in
  if hs == ls then __f64_pack hs (hv + lv2) he st
  else
    let diff = if st == 1 then hv - lv2 - 1 else hv - lv2 in
    if diff == 0 && st == 0 then 0
    else __f64_pack hs diff he st;
let __f64_add = fn (a: int) -> fn (b: int) ->
  if __f64_is_snan a then __f64_quiet a
  else if __f64_is_snan b then __f64_quiet b
  else if __f64_is_nan a then __f64_quiet a
  else if __f64_is_nan b then __f64_quiet b
  else if __f64_is_inf a then
    (if __f64_is_inf b && __f64_sign a != __f64_sign b then __f64_nan () else a)
  else if __f64_is_inf b then b
  else if __f64_is_zero a && __f64_is_zero b then
    (if __f64_sign a == 1 && __f64_sign b == 1 then __f64_mk 1 0 0 else 0)
  else if __f64_is_zero a then b
  else if __f64_is_zero b then a
  else __f64_add_mag a b;
let __f64_neg = fn (b: int) -> bit_xor b (bit_shl 1 63);
let __f64_sub = fn (a: int) -> fn (b: int) ->
  if __f64_is_nan a then __f64_quiet a
  else if __f64_is_nan b then __f64_quiet b
  else __f64_add a (__f64_neg b);

// the product of two 53-bit significands as hi * 2^54 + lo, lo < 2^54, exactly:
// each is split 26/27 so every partial product fits a signed 64-bit int
let __f64_mul_fin = fn (sign: int) -> fn (h: int) -> fn (l: int) -> fn (e0: int) ->
  let len = if h > 0 then 54 + __f64_blen h else __f64_blen l in
  let k = if len > 56 then len - 56 else 0 in
  // k <= 50 (len <= 106), so the top 56 bits are h << (54 - k) plus l >> k
  let s = bit_shl h (54 - k) + bit_shr l k in
  __f64_pack sign s (e0 + k - 1072) (__f64_lost l k);
let __f64_mul_mag = fn (sign: int) -> fn (a: int) -> fn (b: int) ->
  let m27 = bit_shl 1 27 - 1 in
  let ma = __f64_sig a in let mb = __f64_sig b in
  let ah = bit_shr ma 27 in let al = bit_and ma m27 in
  let bh = bit_shr mb 27 in let bl = bit_and mb m27 in
  let mid = ah * bl + al * bh in
  let low = al * bl + bit_shl (bit_and mid m27) 27 in
  let hi = ah * bh + bit_shr mid 27 + bit_shr low 54 in
  let lo = bit_and low (bit_shl 1 54 - 1) in
  __f64_mul_fin sign hi lo (__f64_eff a + __f64_eff b);
let __f64_mul = fn (a: int) -> fn (b: int) ->
  let sign = bit_xor (__f64_sign a) (__f64_sign b) in
  if __f64_is_snan a then __f64_quiet a
  else if __f64_is_snan b then __f64_quiet b
  else if __f64_is_nan a then a
  else if __f64_is_nan b then b
  else if __f64_is_inf a then (if __f64_is_zero b then __f64_nan () else __f64_inf sign)
  else if __f64_is_inf b then (if __f64_is_zero a then __f64_nan () else __f64_inf sign)
  else if __f64_is_zero a || __f64_is_zero b then __f64_mk sign 0 0
  else __f64_mul_mag sign a b;

// a subnormal's significand shifted up to 53 bits, and the exponent paid for it
let __f64_norm_sig = fn (b: int) ->
  let m = __f64_sig b in bit_shl m (53 - __f64_blen m);
let __f64_norm_exp = fn (b: int) ->
  __f64_eff b - (53 - __f64_blen (__f64_sig b));
// long division, one quotient bit per round (contrib/softfloat/div's `divide`)
let rec __f64_div_go = fn (i: int) -> fn (rem: int) -> fn (q: int) -> fn (d: int) -> fn (sign: int) -> fn (e: int) ->
  if i <= 0 then __f64_pack sign q e (if rem == 0 then 0 else 1)
  else
    let r1 = bit_shl rem 1 in
    if r1 >= d then __f64_div_go (i - 1) (r1 - d) (bit_shl q 1 + 1) d sign e
    else __f64_div_go (i - 1) r1 (bit_shl q 1) d sign e;
let __f64_div = fn (a: int) -> fn (b: int) ->
  let sign = bit_xor (__f64_sign a) (__f64_sign b) in
  if __f64_is_snan a then __f64_quiet a
  else if __f64_is_snan b then __f64_quiet b
  else if __f64_is_nan a then a
  else if __f64_is_nan b then b
  else if __f64_is_inf a then (if __f64_is_inf b then __f64_nan () else __f64_inf sign)
  else if __f64_is_inf b then __f64_mk sign 0 0
  else if __f64_is_zero a then (if __f64_is_zero b then __f64_nan () else __f64_mk sign 0 0)
  else if __f64_is_zero b then __f64_inf sign
  else
    let na = __f64_norm_sig a in let nb = __f64_norm_sig b in
    let e = __f64_norm_exp a - __f64_norm_exp b + 1022 in
    if na >= nb then __f64_div_go 56 (na - nb) 1 nb sign e
    else __f64_div_go 56 na 0 nb sign e;

// square root, digit by digit (contrib/softfloat/sqrt): the radicand is m << 58,
// consumed two bits a round from the top; rem and root stay below 2^59
let rec __f64_sq_go = fn (i: int) -> fn (m: int) -> fn (rem: int) -> fn (root: int) -> fn (u: int) ->
  if i < 0 then __f64_pack 0 root (u + 1049) (if rem == 0 then 0 else 1)
  else
    let j1 = 2 * i + 1 in
    let j0 = 2 * i in
    let b1 = if j1 < 58 then 0 else bit_and (bit_shr m (j1 - 58)) 1 in
    let b0 = if j0 < 58 then 0 else bit_and (bit_shr m (j0 - 58)) 1 in
    let rem2 = bit_shl rem 2 + (b1 + b1 + b0) in
    let cand = bit_shl root 2 + 1 in
    if rem2 >= cand then __f64_sq_go (i - 1) m (rem2 - cand) (bit_shl root 1 + 1) u
    else __f64_sq_go (i - 1) m rem2 (bit_shl root 1) u;
let __f64_sqrt = fn (a: int) ->
  if __f64_is_snan a then __f64_quiet a
  else if __f64_is_nan a then a
  else if __f64_is_zero a then a
  else if __f64_sign a == 1 then __f64_nan ()
  else if __f64_is_inf a then __f64_inf 0
  else
    let m0 = __f64_norm_sig a in
    let t0 = __f64_norm_exp a - 1075 in
    let odd = if t0 - (t0 / 2) * 2 == 0 then 0 else 1 in
    let m = if odd == 1 then bit_shl m0 1 else m0 in
    __f64_sq_go 55 m 0 0 ((t0 - odd) / 2);

// int -> double, rounding: the magnitude is 2 * (n / 2) + (the odd bit), which
// exists for the most negative int too (contrib/softfloat/conv's reason)
let __f64_of_int = fn (n: int) ->
  if n == 0 then 0
  else
    let sign = if n < 0 then 1 else 0 in
    let mh = if n < 0 then 0 - (n / 2) else n / 2 in
    let odd = bit_and n 1 in
    if mh < bit_shl 1 59 then __f64_pack sign (bit_shl (mh + mh + odd) 3) 1075 0
    else __f64_pack sign (bit_shr mh 3) 1082 (if odd != 0 || bit_and mh 7 != 0 then 1 else 0);
// double -> int, truncating; out of range it answers what the limb library
// answered on this width (a 64-bit wrap of the shifted significand, or the bare
// significand past 2^73), so nothing a program saw before changes
let __f64_to_int = fn (a: int) ->
  if __f64_is_nan a || __f64_is_zero a then 0
  else
    let s = __f64_sig a in
    let sh = 1075 - __f64_eff a in
    let v = if sh >= 0 then (if sh > 75 then 0 else (if sh > 62 then 0 else bit_shr s sh))
            else (if 0 - sh > 20 then s else bit_shl s (0 - sh)) in
    if __f64_sign a == 1 then 0 - v else v;

// IEEE comparison: NaN is unordered, and -0.0 equals +0.0
let __f64_eq = fn (a: int) -> fn (b: int) ->
  if __f64_is_nan a || __f64_is_nan b then false
  else if __f64_is_zero a && __f64_is_zero b then true
  else a == b;
let __f64_lt = fn (a: int) -> fn (b: int) ->
  if __f64_is_nan a || __f64_is_nan b then false
  else if __f64_is_zero a && __f64_is_zero b then false
  else if __f64_sign a != __f64_sign b then __f64_sign a == 1
  else if __f64_sign a == 0 then __f64_mag a < __f64_mag b
  else __f64_mag a > __f64_mag b;
let __f64_le = fn (a: int) -> fn (b: int) ->
  if __f64_is_nan a || __f64_is_nan b then false else not (__f64_lt b a);
let __f64_ge = fn (a: int) -> fn (b: int) ->
  if __f64_is_nan a || __f64_is_nan b then false else not (__f64_lt a b);

let __fadd = fn (a: float) -> fn (b: float) ->
  if __rv_xlen () == 64 then __f64_float (__f64_add (__f64_bits a) (__f64_bits b))
  else __sf_float_of_sf (__sf_add (__sf_sf_of_float a) (__sf_sf_of_float b));
let __fsub = fn (a: float) -> fn (b: float) ->
  if __rv_xlen () == 64 then __f64_float (__f64_sub (__f64_bits a) (__f64_bits b))
  else __sf_float_of_sf (__sf_sub (__sf_sf_of_float a) (__sf_sf_of_float b));
let __fmul = fn (a: float) -> fn (b: float) ->
  if __rv_xlen () == 64 then __f64_float (__f64_mul (__f64_bits a) (__f64_bits b))
  else __sf_float_of_sf (__sf_mul (__sf_sf_of_float a) (__sf_sf_of_float b));
let __fdiv = fn (a: float) -> fn (b: float) ->
  if __rv_xlen () == 64 then __f64_float (__f64_div (__f64_bits a) (__f64_bits b))
  else __sf_float_of_sf (__sf_fdiv (__sf_sf_of_float a) (__sf_sf_of_float b));
// Negation is a sign-bit flip and is defined on NaN too, which is why it goes
// through the library rather than through `0.0 - x`: that is a different
// operation on -0.0 and on NaN.
let __fneg = fn (a: float) ->
  if __rv_xlen () == 64 then __f64_float (__f64_neg (__f64_bits a))
  else __sf_float_of_sf (__sf_neg (__sf_sf_of_float a));
// `eq` and `lt` are not bit comparisons: -0.0 equals +0.0, and a NaN equals
// nothing, itself included. Neither falls out of comparing the fields, and
// neither falls out of comparing the two halves as ints.
let __feq = fn (a: float) -> fn (b: float) ->
  if __rv_xlen () == 64 then __f64_eq (__f64_bits a) (__f64_bits b)
  else __sf_eq (__sf_sf_of_float a) (__sf_sf_of_float b);
let __fne = fn (a: float) -> fn (b: float) -> not (__feq a b);
let __flt = fn (a: float) -> fn (b: float) ->
  if __rv_xlen () == 64 then __f64_lt (__f64_bits a) (__f64_bits b)
  else __sf_lt (__sf_sf_of_float a) (__sf_sf_of_float b);
let __fle = fn (a: float) -> fn (b: float) ->
  if __rv_xlen () == 64 then __f64_le (__f64_bits a) (__f64_bits b)
  else __sf_le (__sf_sf_of_float a) (__sf_sf_of_float b);
let __fgt = fn (a: float) -> fn (b: float) ->
  if __rv_xlen () == 64 then __f64_lt (__f64_bits b) (__f64_bits a)
  else __sf_gt (__sf_sf_of_float a) (__sf_sf_of_float b);
let __fge = fn (a: float) -> fn (b: float) ->
  if __rv_xlen () == 64 then __f64_ge (__f64_bits a) (__f64_bits b)
  else __sf_ge (__sf_sf_of_float a) (__sf_sf_of_float b);

// The named forms of the same operations. They are the operators' spelling for
// code that passes them around, so they share the implementation rather than
// getting a second one that could disagree with `+`.
let f_add = fn (a: float) -> fn (b: float) -> __fadd a b;
let f_sub = fn (a: float) -> fn (b: float) -> __fsub a b;
let f_mul = fn (a: float) -> fn (b: float) -> __fmul a b;
let f_div = fn (a: float) -> fn (b: float) -> __fdiv a b;
let f_neg = fn (a: float) -> __fneg a;
let f_abs = fn (a: float) ->
  if __rv_xlen () == 64 then __f64_float (__f64_mag (__f64_bits a))
  else __sf_float_of_sf (__sf_abs (__sf_sf_of_float a));
let f_lt = fn (a: float) -> fn (b: float) -> __flt a b;
let f_le = fn (a: float) -> fn (b: float) -> __fle a b;
let f_gt = fn (a: float) -> fn (b: float) -> __fgt a b;
let f_ge = fn (a: float) -> fn (b: float) -> __fge a b;
let float_of_int = fn (n: int) ->
  if __rv_xlen () == 64 then __f64_float (__f64_of_int n)
  else __sf_float_of_sf (__sf_of_int n);
let int_of_float = fn (x: float) ->
  if __rv_xlen () == 64 then __f64_to_int (__f64_bits x)
  else __sf_to_int (__sf_sf_of_float x);
// The two host services the emulator answers with Linux syscall numbers --
// clock_gettime64 (403) and getrandom (278) -- so these are REAL on the hosted
// -rv path, not shims. Under --bare the intrinsics they call refuse at compile
// time: a machine has devices, not syscalls.
let time = fn (u: unit) ->
  // The kernel writes Linux's timespec64 and the CELLS differ by width: on
  // rv32 they are 32-bit halves (sec lo, sec hi, nsec lo, nsec hi), on rv64
  // two native words (sec, nsec) and the last two cells are dead. Same
  // prelude, both machines, one branch on a compile-time constant.
  let (c0, c1, c2, _) = __rv_clock 0 in
  if __rv_xlen () == 64 then
    float_of_int c0 + float_of_int c1 / 1000000000.0
  else
    // sec is two unsigned 32-bit halves; this int is signed 32-bit, so the low
    // half is corrected into float space rather than reassembled as an int --
    // which also keeps the answer right past 2038, where the low half goes
    // negative here.
    let lo = float_of_int c0 + (if c0 < 0 then 4294967296.0 else 0.0) in
    let hi = float_of_int c1 * 4294967296.0 in
    hi + lo + float_of_int c2 / 1000000000.0;
let random_int = fn (n: int) ->
  if n <= 0 then fail ("random_int: bound must be positive (got " ++ str_of_int n ++ ")")
  else
    // rejection sampling over the 31-bit pool: plain `r % n` favours the low
    // residues whenever n does not divide 2^31, and a random that is measurably
    // unfair is a bug someone gets to find in production
    let lim = (2147483647 / n) * n in
    let rec draw = fn (u: unit) ->
      let r = bit_and (__rv_urandom32 ()) 2147483647 in
      if r >= lim then draw () else r % n in
    draw ();

// The decimal conversions, from contrib/softfloat/dec: exact digit arrays, so
// `str_of_float` prints the same shortest-round-trip spelling the interpreter
// and the C runtime print, and `float_of_str` rounds the same way strtod does.
let float_of_str = fn (s: str) -> __sf_float_of_sf (__sf_sf_of_dec s);

// --- the float library, computed here -----------------------------------
// sqrt goes through contrib/softfloat's integer digit-by-digit root and is
// CORRECTLY ROUNDED -- the same bits as the hardware, checked by
// scripts/softfloat_check.sh probe for probe. The transcendentals are computed
// below in double arithmetic (which softfloat provides on this target) with
// DOCUMENTED accuracy, measured against libm on 10k-point sweeps:
//
//   exp, log, f_pow <= 1 ulp from libm, and equal to it on all but 2, 4 and 47
//   of 6000-point sweeps (v0.1.606; f_pow's worst against the true value is
//   0.71 ulp): each is built from exact two_sum / two_prod pieces and rounded
//   once -- a HEAD+TAIL log, an exp that takes a pair, and integer powers
//   |y| <= 32 walked as pairs. Before, exp was 1 ulp off libm on 10% of
//   points, log up to 2, and f_pow up to 20, growing with |y ln x|.
//   test/float/rv_libm_points.mere holds points of each to libm's bits. |
//   sin/cos <= ~10 ulp and tan <= ~14 for |x| <= 1.6e6 (the 3-term
//   reduction's exact range; beyond it they degrade and huge-argument
//   reduction is out of scope) | atan2 <= 3 ulp
//
// floor / ceil / round / f_min / f_max are EXACT: bit surgery and compares.
// They cannot follow the libm-linked backends' spelling because there is no
// libm here; they follow their answers instead, probe for probe, in
// test/parity/float_lib_edges.mere.
//
// Everything is written for BOTH widths: no integer literal at or above 2^31
// (the 32-bit target refuses it), sign bits made by shifting rather than
// masking with one, and low-bit clearing via (x >> k) << k, which is fill-
// agnostic. bit_shr is arithmetic, and every use here is behind a mask or a
// shift-back, so the fill never reaches a value.
let __fp_hi_exp = fn (hi: int) -> bit_and (bit_shr hi 20) 2047;
let __fp_hi_sign = fn (hi: int) -> bit_and (bit_shr hi 31) 1;
let __fp_is_inf = fn (x: float) -> x == x && x + x == x && (if x == 0.0 then false else true);

// truncate toward zero by clearing fraction bits below the binary point
let __fp_trunc = fn (x: float) ->
  let hi = float_bits_hi x in
  let lo = float_bits_lo x in
  let e = __fp_hi_exp hi in
  if e >= 1075 then x
  else if e < 1023 then float_of_bits (bit_shl (__fp_hi_sign hi) 31) 0
  else
    let dropn = 1075 - e in
    if dropn >= 32 then float_of_bits (bit_shl (bit_shr hi (dropn - 32)) (dropn - 32)) 0
    else float_of_bits hi (bit_shl (bit_shr lo dropn) dropn);
let __fp_has_frac = fn (x: float) ->
  let t = __fp_trunc x in
  if float_bits_hi t == float_bits_hi x && float_bits_lo t == float_bits_lo x then false else true;

let floor = fn (x: float) ->
  let t = __fp_trunc x in
  if __fp_hi_sign (float_bits_hi x) == 1 && __fp_has_frac x then t - 1.0 else t;
let ceil = fn (x: float) ->
  let t = __fp_trunc x in
  if __fp_hi_sign (float_bits_hi x) == 0 && __fp_has_frac x then t + 1.0 else t;
// half away from zero, decided on the true fraction rather than on x + 0.5,
// which can round UP in float and push a value below the half over it
let round = fn (x: float) ->
  let t = __fp_trunc x in
  let f = f_abs (x - t) in
  if f < 0.5 then t
  else if __fp_hi_sign (float_bits_hi x) == 1 then t - 1.0 else t + 1.0;

// v0.1.538 (Q-177): the interpreter's Float.min / Float.max, transcribed
// step for step from OCaml's stdlib, so that even the NaN that comes back is
// the same one. This used to copy the C backend's `a < b ? a : b`, which
// answered the OTHER operand when the NaN came first and returned equal zeros
// in argument order; the C backend was the one that was wrong, and both
// changed together. The sign is read from the bits, NaN's included.
let __fp_sign_bit = fn (x: float) -> __fp_hi_sign (float_bits_hi x) == 1;
let f_min = fn (x: float) -> fn (y: float) ->
  if y > x || (not (__fp_sign_bit y) && __fp_sign_bit x) then (if y != y then y else x)
  else (if x != x then x else y);
let f_max = fn (x: float) -> fn (y: float) ->
  if y > x || (not (__fp_sign_bit y) && __fp_sign_bit x) then (if x != x then x else y)
  else (if y != y then y else x);

let sqrt = fn (a: float) ->
  if __rv_xlen () == 64 then __f64_float (__f64_sqrt (__f64_bits a))
  else __sf_float_of_sf (__sf_fsqrt (__sf_sf_of_float a));

// the two float constants the host builtins provide elsewhere; double literals
// here, which the decimal reader turns into the same bits libm's M_PI has
let pi = 3.141592653589793;
let e = 2.718281828459045;

// 2^k by building the exponent field; normal range only, callers split
let __fp_pow2i = fn (k: int) -> float_of_bits (bit_shl (k + 1023) 20) 0;

// The exact pieces the rest is built from. A Dekker split cuts a double into two
// halves of <= 26 bits, so a product of halves is exact and x * y can be had as
// a HEAD+TAIL pair whose sum is the true product. The split multiplies by
// 2^27 + 1, so the argument has to stay below ~2^996; every caller here checks
// its range first.
let __fp_split = fn (x: float) ->
  let c = x * 134217729.0 in
  let h = c - (c - x) in
  (h, x - h);
let __fp_two_prod = fn (x: float) -> fn (y: float) ->
  let p = x * y in
  let (xh, xl) = __fp_split x in
  let (yh, yl) = __fp_split y in
  (p, ((xh * yh - p) + xh * yl + xl * yh) + xl * yl);
let __fp_two_sum = fn (x: float) -> fn (y: float) ->
  let s = x + y in
  let bb = s - x in
  (s, (x - (s - bb)) + (y - bb));

// e^(zh + zl), rounded ONCE. k = round(zh / ln 2) and r = zh - k ln2 as a
// pair (Cody-Waite: ln2_hi has 33 bits, so k * ln2_hi is exact for every k
// this range allows, and the subtraction is exact by Sterbenz). Then
// e^r = 1 + r + r^2/2 + r^3 P(r): the first three terms are summed exactly --
// r^2 by two_prod -- and everything else is below 0.008, where a few ulps of
// its own are a hundredth of an ulp of the result. The input's tail rides in
// as zl e^r: the pair is what lets f_pow pass y log x without rounding it
// first.
let __fp_exp2 = fn (zh: float) -> fn (zl: float) ->
  let kf = round (zh * 1.4426950408889634) in
  let k = int_of_float kf in
  let r1 = zh - kf * 0.6931471803691238 in
  let (rh, re) = __fp_two_sum r1 (0.0 - kf * 1.9082149292705877e-10) in
  let rl = re + zl in
  let p = 7.647163731819816e-13 in
  let p = p * rh + 1.1470745597729725e-11 in
  let p = p * rh + 1.6059043836821613e-10 in
  let p = p * rh + 2.08767569878681e-9 in
  let p = p * rh + 2.505210838544172e-8 in
  let p = p * rh + 2.755731922398589e-7 in
  let p = p * rh + 0.0000027557319223985893 in
  let p = p * rh + 0.0000248015873015873 in
  let p = p * rh + 0.0001984126984126984 in
  let p = p * rh + 0.001388888888888889 in
  let p = p * rh + 0.008333333333333333 in
  let p = p * rh + 0.041666666666666664 in
  let p = p * rh + 0.16666666666666666 in
  let (sh, sl) = __fp_two_prod rh rh in
  let c3 = (sh * rh) * p in
  let (a, ea) = __fp_two_sum 1.0 rh in
  let (b, eb) = __fp_two_sum a (sh * 0.5) in
  // rl scales by e^r, all of it: rl is y log x's rounding in f_pow, up to
  // ~1e-14, and stopping at rl (1 + r) dropped r^2/2 of that -- six ulps.
  let lo = ((ea + eb) + (sl * 0.5 + rl * (b + c3))) + c3 in
  let m = b + lo in
  if k >= 0 - 1021 && k <= 1023 then m * __fp_pow2i k
  else if k < 0 - 1021 then (m * __fp_pow2i (k + 512)) * __fp_pow2i (0 - 512)
  else (m * __fp_pow2i (k - 512)) * __fp_pow2i 512;

let exp = fn (x: float) ->
  if x != x then x
  else if x > 709.782712893384 then 1.0 / 0.0
  else if x < 0.0 - 745.1332191019412 then 0.0
  else __fp_exp2 x 0.0;

// log as a HEAD+TAIL pair, renormalized so |tail| <= ulp(head): f_pow needs the
// pair (a 1-ulp log error, magnified by y, is the whole ballgame there), and
// `log` itself is head + tail rounded once
let __fp_log2p = fn (x: float) ->
  // subnormals scale into the normal range first, and k pays for it
  let sub = __fp_hi_exp (float_bits_hi x) == 0 in
  let x1 = if sub then x * 18014398509481984.0 else x in
  let k0 = if sub then 0 - 54 else 0 in
  let hi = float_bits_hi x1 in
  let lo = float_bits_lo x1 in
  let e = __fp_hi_exp hi in
  // m in [1/sqrt2, sqrt2): exponent bits swapped for 1023, halved if high
  let m0 = float_of_bits (bit_or (bit_and hi 1048575) (bit_shl 1023 20)) lo in
  let (m, k) = if m0 >= 1.4142135623730951
               then (m0 * 0.5, k0 + e - 1022)
               else (m0, k0 + e - 1023) in
  // s = (m - 1) / (m + 1) carries its rounding as a tail: m - 1 is exact
  // (Sterbenz), m + 1 is a two_sum, and the division's remainder is exact
  // through two_prod. Without it 2s was off by up to 4e-17 -- a whole ulp of
  // log for x near 1, and y times that in f_pow.
  let u = m - 1.0 in
  let (v, vt) = __fp_two_sum m 1.0 in
  let s = u / v in
  let (q, qe) = __fp_two_prod s v in
  let st = (((u - q) - qe) - s * vt) / v in
  let w = s * s in
  // atanh series: log m = 2s (1 + w/3 + ... + w^11/23), last term ~6e-19 rel
  let p = 0.043478260869565216 in
  let p = p * w + 0.047619047619047616 in
  let p = p * w + 0.05263157894736842 in
  let p = p * w + 0.058823529411764705 in
  let p = p * w + 0.06666666666666667 in
  let p = p * w + 0.07692307692307693 in
  let p = p * w + 0.09090909090909091 in
  let p = p * w + 0.1111111111111111 in
  let p = p * w + 0.14285714285714285 in
  let p = p * w + 0.2 in
  let p = p * w + 0.3333333333333333 in
  let lm_tail = 2.0 * s * (w * p) in
  let kf = float_of_int k in
  let (h0, e0) = __fp_two_sum (kf * 0.6931471803691238) (2.0 * s) in
  let t0 = e0 + ((2.0 * st + kf * 1.9082149292705877e-10) + lm_tail) in
  let head = h0 + t0 in
  let tail = h0 - head + t0 in
  (head, tail);
let log = fn (x: float) ->
  if x != x then x
  else if x < 0.0 then 0.0 / 0.0
  else if x == 0.0 then 0.0 - 1.0 / 0.0
  else if __fp_is_inf x then x
  else
    let (h, t) = __fp_log2p x in h + t;

let __fp_is_int_f = fn (x: float) ->
  let t = __fp_trunc x in
  if float_bits_hi t == float_bits_hi x && float_bits_lo t == float_bits_lo x then true else false;
let __fp_is_odd_int_f = fn (x: float) ->
  if __fp_is_int_f x then
    (let h = x * 0.5 in if __fp_is_int_f h then false else true)
  else false;
let rec f_pow = fn (x: float) -> fn (y: float) ->
  if y == 0.0 then 1.0
  else if x == 1.0 then 1.0
  else if x != x then x
  else if y != y then y
  else if y == 1.0 then x
  else
    let ax = f_abs x in
    let inf = 1.0 / 0.0 in
    if x == inf then (if y > 0.0 then inf else 0.0)
    else if y == inf then (if ax > 1.0 then inf else if ax < 1.0 then 0.0 else 1.0)
    else if y == 0.0 - inf then (if ax > 1.0 then 0.0 else if ax < 1.0 then inf else 1.0)
    else if x == 0.0 - inf then
      (if y > 0.0 then (if __fp_is_odd_int_f y then 0.0 - inf else inf)
       else (if __fp_is_odd_int_f y then 0.0 - 0.0 else 0.0))
    else if x == 0.0 then
      (if y > 0.0 then (if __fp_is_odd_int_f y && __fp_hi_sign (float_bits_hi x) == 1 then 0.0 - 0.0 else 0.0)
       else (if __fp_is_odd_int_f y && __fp_hi_sign (float_bits_hi x) == 1 then 0.0 - inf else inf))
    else if x < 0.0 then
      (if __fp_is_int_f y then
         (let m = f_pow ax y in if __fp_is_odd_int_f y then 0.0 - m else m)
       else 0.0 / 0.0)
    else if y == 0.5 then sqrt x
    // y = +/-0.5 routes through the CORRECTLY ROUNDED sqrt: pow(9, 0.5) must
    // print 3.0, and exp(0.5 log 9) is a couple of ulps shy of it. libm's pow
    // answers the same bits for these (a correctly rounded pow agrees with a
    // correctly rounded sqrt wherever they overlap).
    else if y == 0.0 - 0.5 then 1.0 / sqrt x
    else if __fp_is_int_f y && f_abs y <= 32.0 then
      // small integer exponent: binary exponentiation, carried as HEAD+TAIL
      // pairs and rounded once at the end. Plain doubles rounded at every
      // product: 2.3 ** 3 came out 12.166999999999996, where libm (and ruby)
      // answer the correctly rounded 12.166999999999998. The plain walk is
      // still the first step -- it is exact where the result is exact, and it
      // tells whether the pair can be split without overflowing; outside
      // [2^-960, 2^960] its answer stands.
      (let rec go = fn (b: float) -> fn (n: int) -> fn (acc: float) ->
         if n == 0 then acc
         else if n - (n / 2) * 2 == 1 then go (b * b) (n / 2) (acc * b)
         else go (b * b) (n / 2) acc in
       let n = int_of_float (f_abs y) in
       let m = go x n 1.0 in
       let big = __fp_pow2i 960 in
       if m != m || m > big || m < 1.0 / big then (if y < 0.0 then 1.0 / m else m)
       else
         // (h, l) * (h2, l2), renormalized
         (let mul = fn (h: float) -> fn (l: float) -> fn (h2: float) -> fn (l2: float) ->
            let (p, pe) = __fp_two_prod h h2 in
            __fp_two_sum p (pe + (h * l2 + l * h2)) in
          let rec gd = fn (bh: float) -> fn (bl: float) -> fn (k: int) -> fn (ah: float) -> fn (al: float) ->
            if k == 0 then (ah, al)
            else
              let (ah2, al2) = (if k - (k / 2) * 2 == 1 then mul ah al bh bl else (ah, al)) in
              if k / 2 == 0 then (ah2, al2)
              else (let (bh2, bl2) = mul bh bl bh bl in gd bh2 bl2 (k / 2) ah2 al2) in
          let (rh, rl) = gd x 0.0 n 1.0 0.0 in
          if y > 0.0 then rh + rl
          else
            // 1 / (rh + rl): the quotient's remainder is exact through two_prod
            (let q = 1.0 / rh in
             let (qp, qe) = __fp_two_prod q rh in
             q + q * (((1.0 - qp) - qe) - q * rl))))
    else
      // exp(y log x) with the product done EXACTLY (Dekker split) over the
      // two-piece log, so the only inherited error is the log's own
      let (lh, lt) = __fp_log2p x in
      let c = lh * 134217729.0 in
      let lhh = c - (c - lh) in
      let lhl = lh - lhh in
      let cy = y * 134217729.0 in
      let yh = cy - (cy - y) in
      let yl = y - yh in
      let ph = y * lh in
      let perr = yh * lhh - ph + yh * lhl + yl * lhh + yl * lhl in
      let pl = perr + y * lt in
      if ph > 710.0 then inf
      else if ph < 0.0 - 746.0 then 0.0
      else __fp_exp2 ph pl;

// pi/2 in four ~33-bit pieces (fdlibm's): n * piece is exact for n < 2^20,
// which is the documented full-quality range. The subtractions carry their
// tails through two-sums, so the reduced angle is a PAIR and a near-zero
// crossing of a large argument keeps its accuracy instead of dying at the
// double's edge.
let __fp_pio2_1 = 1.5707963267341256;
let __fp_pio2_2 = 6.07710050630396e-11;
let __fp_pio2_2t = 2.0222662487959506e-21;
let __fp_pio2_3 = 2.0222662487111665e-21;
let __fp_pio2_3t = 8.4784276603689e-32;
let __fp_trig_reduce = fn (x: float) ->
  let nf = round (x * 0.6366197723675814) in
  let z1 = x - nf * __fp_pio2_1 in
  let t2 = nf * __fp_pio2_2 in
  let z2 = z1 - t2 in
  let e2 = (z1 - z2) - t2 in
  let t3 = nf * __fp_pio2_3 in
  let z3 = z2 - t3 in
  let e3 = (z2 - z3) - t3 in
  let tail = (e2 + e3) - nf * __fp_pio2_3t in
  let y0 = z3 + tail in
  let y1 = z3 - y0 + tail in
  let n4 = int_of_float (nf - __fp_trunc (nf * 0.25) * 4.0) in
  (y0, y1, if n4 < 0 then n4 + 4 else n4);
let __fp_sin_poly = fn (r: float) ->
  let z = r * r in
  let p = 2.8114572543455208e-15 in
  let p = p * z - 7.647163731819816e-13 in
  let p = p * z + 1.6059043836821613e-10 in
  let p = p * z - 2.505210838544172e-8 in
  let p = p * z + 0.0000027557319223985893 in
  let p = p * z - 0.0001984126984126984 in
  let p = p * z + 0.008333333333333333 in
  let p = p * z - 0.16666666666666666 in
  r + r * (z * p);
let __fp_cos_poly = fn (r: float) ->
  let z = r * r in
  let p = 0.0 - 1.1470745597729725e-11 in
  let p = p * z + 2.08767569878681e-9 in
  let p = p * z - 2.755731922398589e-7 in
  let p = p * z + 0.0000248015873015873 in
  let p = p * z - 0.001388888888888889 in
  let p = p * z + 0.041666666666666664 in
  let p = p * z - 0.5 in
  1.0 + z * p;
// sin(y0 + y1) = sin y0 + y1 cos y0 to first order in the tail; the pair
// matters exactly when the result is TINY (x near a multiple of pi), where the
// head alone would carry the reduction's rounding as thousands of ulps
let __fp_sin_pair = fn (y0: float) -> fn (y1: float) ->
  __fp_sin_poly y0 + y1 * (1.0 - y0 * y0 * 0.5);
let __fp_cos_pair = fn (y0: float) -> fn (y1: float) ->
  __fp_cos_poly y0 - y1 * y0;
let sin = fn (x: float) ->
  if x != x then x
  else if __fp_is_inf x then 0.0 / 0.0
  else if f_abs x < 1.0e-8 then x
  else
    let (y0, y1, q) = __fp_trig_reduce x in
    if q == 0 then __fp_sin_pair y0 y1
    else if q == 1 then __fp_cos_pair y0 y1
    else if q == 2 then 0.0 - __fp_sin_pair y0 y1
    else 0.0 - __fp_cos_pair y0 y1;
let cos = fn (x: float) ->
  if x != x then x
  else if __fp_is_inf x then 0.0 / 0.0
  else
    let (y0, y1, q) = __fp_trig_reduce x in
    if q == 0 then __fp_cos_pair y0 y1
    else if q == 1 then 0.0 - __fp_sin_pair y0 y1
    else if q == 2 then 0.0 - __fp_cos_pair y0 y1
    else __fp_sin_pair y0 y1;
let tan = fn (x: float) -> sin x / cos x;

// atan by two half-angle reductions, then the alternating series through u^23
let __fp_atan_core = fn (t: float) ->
  let big = t > 1.0 in
  let t1 = if big then 1.0 / t else t in
  let u1 = t1 / (1.0 + sqrt (1.0 + t1 * t1)) in
  let u = u1 / (1.0 + sqrt (1.0 + u1 * u1)) in
  let z = u * u in
  let q = 0.043478260869565216 in
  let q = 0.0 - q * z + 0.047619047619047616 in
  let q = 0.0 - q * z + 0.05263157894736842 in
  let q = 0.0 - q * z + 0.058823529411764705 in
  let q = 0.0 - q * z + 0.06666666666666667 in
  let q = 0.0 - q * z + 0.07692307692307693 in
  let q = 0.0 - q * z + 0.09090909090909091 in
  let q = 0.0 - q * z + 0.1111111111111111 in
  let q = 0.0 - q * z + 0.14285714285714285 in
  let q = 0.0 - q * z + 0.2 in
  let q = 0.0 - q * z + 0.3333333333333333 in
  let a = 4.0 * (u - u * (z * q)) in
  if big then 1.5707963267948966 - a else a;
let atan2 = fn (y: float) -> fn (x: float) ->
  let pi = 3.141592653589793 in
  if y != y then y else if x != x then x
  else
    let ysign = __fp_hi_sign (float_bits_hi y) in
    let xsign = __fp_hi_sign (float_bits_hi x) in
    if y == 0.0 then
      (if xsign == 0 then (if ysign == 1 then 0.0 - 0.0 else 0.0)
       else (if ysign == 1 then 0.0 - pi else pi))
    else if x == 0.0 then (if ysign == 1 then 0.0 - 1.5707963267948966 else 1.5707963267948966)
    else if __fp_is_inf y && __fp_is_inf x then
      (let base = if xsign == 0 then 0.7853981633974483 else 2.356194490192345 in
       if ysign == 1 then 0.0 - base else base)
    else if __fp_is_inf y then (if ysign == 1 then 0.0 - 1.5707963267948966 else 1.5707963267948966)
    else if __fp_is_inf x then
      (if xsign == 0 then (if ysign == 1 then 0.0 - 0.0 else 0.0)
       else (if ysign == 1 then 0.0 - pi else pi))
    else
      let a = __fp_atan_core (f_abs (y / x)) in
      if xsign == 0 then (if ysign == 1 then 0.0 - a else a)
      else (if ysign == 1 then a - pi else pi - a);
let str_of_float = fn (x: float) -> __sf_dec_of_sf (__sf_sf_of_float x);
|mere}

(* Lines the prelude occupies once it is glued ahead of the user source, so a
   position in the concatenation can be turned back into the line the person
   actually wrote. Counted the way the driver builds that text: the prelude,
   then one newline, then the source.

   Every position the -rv path produces — a type error's, the debug map's —
   arrives in concatenated coordinates, which is why a three-line file used to
   report a type error at "line 133". *)
let lines () =
  let n = ref 1 in
  String.iter (fun c -> if c = '\n' then incr n) contents;
  !n

(* Where a concatenated position really is. `Prelude` means the diagnostic is
   about code the user did not write: reporting it against their file would
   point at a line that either does not exist or says something unrelated, so
   the caller shows the prelude's own text instead. *)
type origin = User of Loc.t | Prelude of Loc.t

let origin_of (loc : Loc.t) : origin =
  let n = lines () in
  if loc.Loc.line > n then User { loc with Loc.line = loc.Loc.line - n }
  else Prelude loc
