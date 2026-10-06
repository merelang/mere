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

let builtin_contents = {mere|
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
let file_delete = fn (p: str) -> __rv_unlink p == 0;

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

// --- Map: a hash table (v0.1.611) ---------------------------------------------
// It was an assoc list: map_set PREPENDED even over an existing key (the list
// grew with every write), map_get walked it, and map_iter walked it once more
// per element to skip keys it had seen -- the square of its length. Measured
// on mere-ruby running on the RV64 emulator: 64% of its startup and 85-98% of
// the corpus files that timed out were those walks (`_mseen`, `_mfind`,
// `__str_eq`). C, LLVM and Wasm have had an O(1) Map since note 147.
//
// Now: the ENTRIES in insertion order -- keys, values and a live flag, three
// Vecs -- and an open-addressing INDEX over them (a power-of-two Vec of ints:
// 0 empty, -1 a tombstone, n entry n-1), probed linearly. The Map's meaning is
// the one the assoc list had, which is every other backend's: map_iter visits
// each live key once, in the order it was first set, with its latest value;
// setting an existing key changes the value in place and keeps its position;
// a deleted key set again goes to the end. A str key is hashed by the runtime's
// `__rv_str_hash` (FNV-1a over its bytes), an int or bool key by mixing its
// bits; codegen_riscv sends a Map to the `_i` family by its key type, as before.
//
// The map value is a tuple (index, keys, values, live, meta); meta holds the
// live count, the entries used, the tombstones and the index mask. Growing the
// index never moves an entry, so a map_iter that sets values keeps its place.
// The entries are packed only by map_compact (and emptied by map_clear /
// map_recycle): a deleted entry holds its slot in the order until then.
let _mput = fn v -> fn (i: int) -> fn x ->
  if i < vec_len v then vec_set v i x else vec_push v x;
let rec _mfill = fn (v: int Vec) -> fn (n: int) -> fn (cap: int) ->
  if n >= cap then () else let _ = vec_push v 0 in _mfill v (n + 1) cap;
let rec _mzero = fn (v: int Vec) -> fn (i: int) -> fn (cap: int) ->
  if i >= cap then () else let _ = vec_set v i 0 in _mzero v (i + 1) cap;
let _mhash_i = fn (k: int) ->
  let a = bit_xor k (bit_shr k 31) in
  let b = bit_xor a (bit_shr a 15) * 73244475 in
  bit_xor b (bit_shr b 13);
let rvmap_new = fn (u: unit) ->
  let idx = vec_new () in
  let _ = _mfill idx 0 8 in
  let meta = vec_new () in
  let _ = vec_push meta 0 in let _ = vec_push meta 0 in
  let _ = vec_push meta 0 in let _ = vec_push meta 7 in
  (idx, vec_new (), vec_new (), vec_new (), meta);
let rec _miter = fn keys -> fn vals -> fn (live: int Vec) -> fn f -> fn (j: int) -> fn (used: int) ->
  if j >= used then ()
  else
    let _ = (if vec_get live j == 1 then f (vec_get keys j) (vec_get vals j) else ()) in
    _miter keys vals live f (j + 1) used;
// the entries as they were when the walk began: a key the callback adds is not
// visited, and one it deletes before its turn is skipped
let rvmap_iter = fn m -> fn f ->
  let (_, keys, vals, live, meta) = m in
  _miter keys vals live f 0 (vec_get meta 1);
let rvmap_len = fn m -> let (_, _, _, _, meta) = m in vec_get meta 0;
let rvmap_clear = fn m ->
  let (idx, _, _, _, meta) = m in
  let _ = _mzero idx 0 (vec_get meta 3 + 1) in
  let _ = vec_set meta 0 0 in let _ = vec_set meta 1 0 in vec_set meta 2 0;
// map_recycle is codegen_riscv's (__mrecycle, v0.1.614): the clear AND the
// Map's arena wound back, as on C. It must clear: mere-ruby cleans a pooled call
// frame with one map_recycle, and when this was a no-op every recycled frame
// came back holding the previous call's locals.

// probe for k: the index slot holding it, or the first free slot to put it in
// (a tombstone on the way if there was one) as -(slot + 1)
let rec _mprobe = fn (idx: int Vec) -> fn keys -> fn (k) -> fn (mask: int) -> fn (i: int) -> fn (tomb: int) ->
  let e = vec_get idx i in
  if e == 0 then 0 - ((if tomb >= 0 then tomb else i) + 1)
  else if e < 0 then _mprobe idx keys k mask (bit_and (i + 1) mask) (if tomb >= 0 then tomb else i)
  else if str_eq (vec_get keys (e - 1)) k then i
  else _mprobe idx keys k mask (bit_and (i + 1) mask) tomb;
let _mslot = fn m -> fn k ->
  let (idx, keys, _, _, meta) = m in
  let mask = vec_get meta 3 in
  _mprobe idx keys k mask (bit_and (__rv_str_hash k) mask) (0 - 1);
let rec _mreindex = fn (idx: int Vec) -> fn keys -> fn (live: int Vec) -> fn (mask: int) -> fn (j: int) -> fn (used: int) ->
  if j >= used then ()
  else
    let _ = (if vec_get live j == 1 then
               (let s = _mprobe idx keys (vec_get keys j) mask (bit_and (__rv_str_hash (vec_get keys j)) mask) (0 - 1) in
                vec_set idx (0 - s - 1) (j + 1))
             else ()) in
    _mreindex idx keys live mask (j + 1) used;
// grow (or only sweep the tombstones out of) the index; entries stay put, so a
// map_iter in progress keeps its place
let _mgrow = fn m ->
  let (idx, keys, _, live, meta) = m in
  let count = vec_get meta 0 in
  let cap0 = vec_get meta 3 + 1 in
  let cap = if (count + 1) * 2 >= cap0 then cap0 * 2 else cap0 in
  let _ = _mfill idx cap0 cap in
  let _ = _mzero idx 0 cap in
  let _ = vec_set meta 3 (cap - 1) in
  let _ = vec_set meta 2 0 in
  _mreindex idx keys live (cap - 1) 0 (vec_get meta 1);
// v0.1.615: `set` is find + update / insert, so that codegen_riscv can copy the
// value -- and, for a new key, the key -- into the Map's arena between the two:
// it knows their types at the call site, and this file does not.
let rvmap_upd = fn m -> fn (s: int) -> fn v ->
  let (idx, _, vals, _, _) = m in
  vec_set vals (vec_get idx s - 1) v;
let rvmap_ins = fn m -> fn (s: int) -> fn k -> fn v ->
  let (idx, keys, vals, live, meta) = m in
    // a new key: appended to the entries (its place in iteration order)
    let used = vec_get meta 1 in
    let _ = _mput keys used k in
    let _ = _mput vals used v in
    let _ = _mput live used 1 in
    let slot = 0 - s - 1 in
    let _ = (if vec_get idx slot < 0 then vec_set meta 2 (vec_get meta 2 - 1) else ()) in
    let _ = vec_set idx slot (used + 1) in
    let _ = vec_set meta 1 (used + 1) in
    let _ = vec_set meta 0 (vec_get meta 0 + 1) in
    // keep the index at most 3/4 full, tombstones counted
    if (vec_get meta 0 + vec_get meta 2) * 4 >= (vec_get meta 3 + 1) * 3 then _mgrow m else ();
let rvmap_set = fn m -> fn k -> fn v ->
  let s = _mslot m k in
  if s >= 0 then rvmap_upd m s v else rvmap_ins m s k v;
let rvmap_get = fn m -> fn k ->
  let (idx, _, vals, _, _) = m in
  let s = _mslot m k in
  if s >= 0 then vec_get vals (vec_get idx s - 1) else fail "map_get: key not found in Map (use map_has to check first)";
let rvmap_has = fn m -> fn k -> _mslot m k >= 0;
let rvmap_delete = fn m -> fn k ->
  let (idx, _, _, live, meta) = m in
  let s = _mslot m k in
  if s < 0 then ()
  else
    let _ = vec_set live (vec_get idx s - 1) 0 in
    let _ = vec_set idx s (0 - 1) in
    let _ = vec_set meta 2 (vec_get meta 2 + 1) in
    vec_set meta 0 (vec_get meta 0 - 1);
// probe for k: the index slot holding it, or the first free slot to put it in
// (a tombstone on the way if there was one) as -(slot + 1)
let rec _mprobe_i = fn (idx: int Vec) -> fn keys -> fn (k) -> fn (mask: int) -> fn (i: int) -> fn (tomb: int) ->
  let e = vec_get idx i in
  if e == 0 then 0 - ((if tomb >= 0 then tomb else i) + 1)
  else if e < 0 then _mprobe_i idx keys k mask (bit_and (i + 1) mask) (if tomb >= 0 then tomb else i)
  else if _meq_i (vec_get keys (e - 1)) k then i
  else _mprobe_i idx keys k mask (bit_and (i + 1) mask) tomb;
let _mslot_i = fn m -> fn k ->
  let (idx, keys, _, _, meta) = m in
  let mask = vec_get meta 3 in
  _mprobe_i idx keys k mask (bit_and (_mhash_i k) mask) (0 - 1);
let rec _mreindex_i = fn (idx: int Vec) -> fn keys -> fn (live: int Vec) -> fn (mask: int) -> fn (j: int) -> fn (used: int) ->
  if j >= used then ()
  else
    let _ = (if vec_get live j == 1 then
               (let s = _mprobe_i idx keys (vec_get keys j) mask (bit_and (_mhash_i (vec_get keys j)) mask) (0 - 1) in
                vec_set idx (0 - s - 1) (j + 1))
             else ()) in
    _mreindex_i idx keys live mask (j + 1) used;
// grow (or only sweep the tombstones out of) the index; entries stay put, so a
// map_iter in progress keeps its place
let _mgrow_i = fn m ->
  let (idx, keys, _, live, meta) = m in
  let count = vec_get meta 0 in
  let cap0 = vec_get meta 3 + 1 in
  let cap = if (count + 1) * 2 >= cap0 then cap0 * 2 else cap0 in
  let _ = _mfill idx cap0 cap in
  let _ = _mzero idx 0 cap in
  let _ = vec_set meta 3 (cap - 1) in
  let _ = vec_set meta 2 0 in
  _mreindex_i idx keys live (cap - 1) 0 (vec_get meta 1);
let rvmap_ins_i = fn m -> fn (s: int) -> fn k -> fn v ->
  let (idx, keys, vals, live, meta) = m in
    // a new key: appended to the entries (its place in iteration order)
    let used = vec_get meta 1 in
    let _ = _mput keys used k in
    let _ = _mput vals used v in
    let _ = _mput live used 1 in
    let slot = 0 - s - 1 in
    let _ = (if vec_get idx slot < 0 then vec_set meta 2 (vec_get meta 2 - 1) else ()) in
    let _ = vec_set idx slot (used + 1) in
    let _ = vec_set meta 1 (used + 1) in
    let _ = vec_set meta 0 (vec_get meta 0 + 1) in
    // keep the index at most 3/4 full, tombstones counted
    if (vec_get meta 0 + vec_get meta 2) * 4 >= (vec_get meta 3 + 1) * 3 then _mgrow_i m else ();
let rvmap_set_i = fn m -> fn k -> fn v ->
  let s = _mslot_i m k in
  if s >= 0 then rvmap_upd m s v else rvmap_ins_i m s k v;
let rvmap_get_i = fn m -> fn k ->
  let (idx, _, vals, _, _) = m in
  let s = _mslot_i m k in
  if s >= 0 then vec_get vals (vec_get idx s - 1) else fail "map_get: key not found in Map (use map_has to check first)";
let rvmap_has_i = fn m -> fn k -> _mslot_i m k >= 0;
let rvmap_delete_i = fn m -> fn k ->
  let (idx, _, _, live, meta) = m in
  let s = _mslot_i m k in
  if s < 0 then ()
  else
    let _ = vec_set live (vec_get idx s - 1) 0 in
    let _ = vec_set idx s (0 - 1) in
    let _ = vec_set meta 2 (vec_get meta 2 + 1) in
    vec_set meta 0 (vec_get meta 0 - 1);
let _meq_i = fn (a: int) -> fn (b: int) -> a == b;
// int / bool keys: the same table, compared as words and hashed by _mhash_i;
// iteration and length need no key, so they are the same functions
let rvmap_iter_i = fn m -> fn f -> rvmap_iter m f;
let rvmap_len_i = fn m -> rvmap_len m;
// map_compact packs the live entries to the front, in order, and points the
// index's slots at their new places -- no key is hashed again, so one function
// serves both key families. (Its contract on the arena backends is the same:
// return what dead entries hold, keep the live ones.)
let rec _mpack = fn keys -> fn vals -> fn (live: int Vec) -> fn (np: int Vec) -> fn (j: int) -> fn (n: int) -> fn (used: int) ->
  if j >= used then n
  else if vec_get live j == 1 then
    (let _ = vec_set np j n in
     let _ = vec_set keys n (vec_get keys j) in
     let _ = vec_set vals n (vec_get vals j) in
     let _ = vec_set live n 1 in
     _mpack keys vals live np (j + 1) (n + 1) used)
  else (let _ = vec_set np j (0 - 1) in _mpack keys vals live np (j + 1) n used);
let rec _mrepoint = fn (idx: int Vec) -> fn (np: int Vec) -> fn (s: int) -> fn (cap: int) ->
  if s >= cap then ()
  else
    let e = vec_get idx s in
    let _ = (if e > 0 then vec_set idx s (vec_get np (e - 1) + 1) else ()) in
    _mrepoint idx np (s + 1) cap;
let rvmap_compact = fn m ->
  let (idx, keys, vals, live, meta) = m in
  let used = vec_get meta 1 in
  if vec_get meta 0 == used then ()
  else
    let np = vec_new () in
    let _ = _mfill np 0 used in
    let n = _mpack keys vals live np 0 0 used in
    let _ = _mrepoint idx np 0 (vec_get meta 3 + 1) in
    vec_set meta 1 n;
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
// built a record per operand per step -- about 2 KB of heap per `+`, and until
// v0.1.613 a region gave nothing back on this target, so mere-ruby's `**` cost
// ~600 KB.
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
// ---- RV64: decimal conversions on 64-bit words (v0.1.612) -------------------
// A bignum is a Vec of ints: v[0] is the number of 30-bit limbs in use, v[1..n]
// the limbs, least significant first; zero is n = 0. Capacity 104 limbs (3120
// bits): the largest value the parser builds is about 2700 bits; the printer's
// stay under 1130, and it asks for 42.
let rec __bn_fill = fn (v: int Vec) -> fn (i: int) -> fn (n: int) ->
  if i >= n then () else let _ = vec_push v 0 in __bn_fill v (i + 1) n;
let __bn_new_cap = fn (cap: int) -> let v = vec_new () in let _ = __bn_fill v 0 (cap + 1) in v;
let __bn_new = fn (u: unit) -> __bn_new_cap 104;
let __bn_mask = fn (u: unit) -> bit_shl 1 30 - 1;
let rec __bn_trim = fn (v: int Vec) ->
  let n = vec_get v 0 in
  if n > 0 && vec_get v n == 0 then (let _ = vec_set v 0 (n - 1) in __bn_trim v) else ();
let __bn_set_int = fn (v: int Vec) -> fn (x: int) ->
  let m = __bn_mask () in
  let _ = vec_set v 1 (bit_and x m) in
  let _ = vec_set v 2 (bit_and (bit_shr x 30) m) in
  let _ = vec_set v 3 (bit_shr x 60) in
  let _ = vec_set v 0 3 in
  __bn_trim v;
let rec __bn_copy_go = fn (d: int Vec) -> fn (s: int Vec) -> fn (i: int) -> fn (n: int) ->
  if i > n then () else let _ = vec_set d i (vec_get s i) in __bn_copy_go d s (i + 1) n;
let __bn_copy = fn (d: int Vec) -> fn (s: int Vec) -> __bn_copy_go d s 0 (vec_get s 0);
// v = v * m + a, m and a below 2^30
let rec __bn_mac_go = fn (v: int Vec) -> fn (m: int) -> fn (i: int) -> fn (n: int) -> fn (c: int) ->
  if i > n then
    (if c == 0 then () else (let _ = vec_set v i (bit_and c (__bn_mask ())) in
                             let _ = vec_set v 0 i in __bn_mac_go v m (i + 1) i (bit_shr c 30)))
  else
    let t = vec_get v i * m + c in
    let _ = vec_set v i (bit_and t (__bn_mask ())) in
    __bn_mac_go v m (i + 1) n (bit_shr t 30);
let __bn_mul_add = fn (v: int Vec) -> fn (m: int) -> fn (a: int) ->
  __bn_mac_go v m 1 (vec_get v 0) a;
let rec __bn_mul_pow10 = fn (v: int Vec) -> fn (k: int) ->
  if k <= 0 then ()
  else if k >= 9 then (let _ = __bn_mul_add v 1000000000 0 in __bn_mul_pow10 v (k - 9))
  else
    let rec p10 = fn (i: int) -> fn (a: int) -> if i == 0 then a else p10 (i - 1) (a * 10) in
    __bn_mul_add v (p10 k 1) 0;
let rec __bn_mul_pow5 = fn (v: int Vec) -> fn (k: int) ->
  if k <= 0 then ()
  else if k >= 12 then (let _ = __bn_mul_add v 244140625 0 in __bn_mul_pow5 v (k - 12))
  else
    let rec p5 = fn (i: int) -> fn (a: int) -> if i == 0 then a else p5 (i - 1) (a * 5) in
    __bn_mul_add v (p5 k 1) 0;
// v = v * 2^k, in place
let rec __bn_shl_words = fn (v: int Vec) -> fn (i: int) -> fn (q: int) ->
  if i < 1 then () else let _ = vec_set v (i + q) (vec_get v i) in __bn_shl_words v (i - 1) q;
let rec __bn_zero_low = fn (v: int Vec) -> fn (i: int) -> fn (q: int) ->
  if i > q then () else let _ = vec_set v i 0 in __bn_zero_low v (i + 1) q;
let rec __bn_shl_bits = fn (v: int Vec) -> fn (i: int) -> fn (n: int) -> fn (r: int) -> fn (c: int) ->
  if i > n then (if c == 0 then () else (let _ = vec_set v i c in vec_set v 0 i))
  else
    let t = vec_get v i in
    let _ = vec_set v i (bit_and (bit_or (bit_shl t r) c) (__bn_mask ())) in
    __bn_shl_bits v (i + 1) n r (bit_shr t (30 - r));
let __bn_shl = fn (v: int Vec) -> fn (k: int) ->
  let n = vec_get v 0 in
  if n == 0 || k == 0 then ()
  else
    let q = k / 30 in
    let r = k - q * 30 in
    let _ = (if q > 0 then (let _ = __bn_shl_words v n q in
                            let _ = __bn_zero_low v 1 q in vec_set v 0 (n + q)) else ()) in
    if r > 0 then __bn_shl_bits v (q + 1) (vec_get v 0) r 0 else ();
// v = v / 2 (floor), in place
let rec __bn_shr1_go = fn (v: int Vec) -> fn (i: int) -> fn (c: int) ->
  if i < 1 then ()
  else
    let t = vec_get v i in
    let _ = vec_set v i (bit_or (bit_shr t 1) (bit_shl c 29)) in
    __bn_shr1_go v (i - 1) (bit_and t 1);
let __bn_shr1 = fn (v: int Vec) -> let _ = __bn_shr1_go v (vec_get v 0) 0 in __bn_trim v;
let rec __bn_cmp_go = fn (a: int Vec) -> fn (b: int Vec) -> fn (i: int) ->
  if i < 1 then 0
  else
    let x = vec_get a i in let y = vec_get b i in
    if x != y then (if x < y then 0 - 1 else 1) else __bn_cmp_go a b (i - 1);
let __bn_cmp = fn (a: int Vec) -> fn (b: int Vec) ->
  let na = vec_get a 0 in let nb = vec_get b 0 in
  if na != nb then (if na < nb then 0 - 1 else 1) else __bn_cmp_go a b na;
// a = a - b, a >= b
let rec __bn_sub_go = fn (a: int Vec) -> fn (b: int Vec) -> fn (i: int) -> fn (n: int) -> fn (nb: int) -> fn (br: int) ->
  if i > n then ()
  else
    let t = vec_get a i - (if i <= nb then vec_get b i else 0) - br in
    if t < 0 then (let _ = vec_set a i (t + bit_shl 1 30) in __bn_sub_go a b (i + 1) n nb 1)
    else (let _ = vec_set a i t in __bn_sub_go a b (i + 1) n nb 0);
let __bn_sub = fn (a: int Vec) -> fn (b: int Vec) ->
  let _ = __bn_sub_go a b 1 (vec_get a 0) (vec_get b 0) 0 in __bn_trim a;
// d = a + b (d may be a)
let rec __bn_add_go = fn (d: int Vec) -> fn (a: int Vec) -> fn (b: int Vec) -> fn (i: int) -> fn (n: int) -> fn (c: int) ->
  if i > n then (if c == 0 then vec_set d 0 n else (let _ = vec_set d i c in vec_set d 0 i))
  else
    let t = (if i <= vec_get a 0 then vec_get a i else 0) + (if i <= vec_get b 0 then vec_get b i else 0) + c in
    let _ = vec_set d i (bit_and t (__bn_mask ())) in
    __bn_add_go d a b (i + 1) n (bit_shr t 30);
let __bn_add = fn (d: int Vec) -> fn (a: int Vec) -> fn (b: int Vec) ->
  let na = vec_get a 0 in let nb = vec_get b 0 in
  __bn_add_go d a b 1 (if na > nb then na else nb) 0;
let rec __bn_bl = fn (t: int) -> fn (n: int) -> if t == 0 then n else __bn_bl (bit_shr t 1) (n + 1);
let __bn_bitlen = fn (v: int Vec) ->
  let n = vec_get v 0 in if n == 0 then 0 else (n - 1) * 30 + __bn_bl (vec_get v n) 0;
// bits [lo, lo + cnt) of v as an int, cnt <= 60
let __bn_bits = fn (v: int Vec) -> fn (lo: int) -> fn (cnt: int) ->
  let rec go = fn (b: int) -> fn (acc: int) ->
    if b < lo then acc
    else
      let w = b / 30 + 1 in
      let bit = if w <= vec_get v 0 then bit_and (bit_shr (vec_get v w) (b - (w - 1) * 30)) 1 else 0 in
      go (b - 1) (acc * 2 + bit) in
  go (lo + cnt - 1) 0;
// any bit below lo set?
let __bn_any_below = fn (v: int Vec) -> fn (lo: int) ->
  let rec go = fn (w: int) ->
    if (w - 1) * 30 >= lo || w > vec_get v 0 then false
    else
      let top = w * 30 in
      let lim = if top <= lo then 30 else lo - (w - 1) * 30 in
      if bit_and (vec_get v w) (bit_shl 1 lim - 1) != 0 then true else go (w + 1) in
  go 1;

// ---- str_of_float: Dragon4 (Burger & Dybvig, free format) --------------------
// The contract is %.{p}g for the first p in 12..17 whose output reads back to
// the same double. That is the SHORTEST round-tripping digit string D (closest
// to the value among the shortest) printed with p = max(12, len D): a p-digit
// rounding of the value round-trips exactly when some p-digit decimal does, and
// below 12 digits the 12-digit rounding is D padded with zeros, which %g drops.
let rec __d64_gen = fn (r: int Vec) -> fn (s: int Vec) -> fn (mp: int Vec) -> fn (mm: int Vec) ->
                     fn (ok: bool) -> fn (out: int Vec) -> fn (t: int Vec) ->
  let _ = __bn_mul_add r 10 0 in
  let _ = __bn_mul_add mp 10 0 in
  let _ = __bn_mul_add mm 10 0 in
  let rec digit = fn (d: int) -> if __bn_cmp r s >= 0 then (let _ = __bn_sub r s in digit (d + 1)) else d in
  let d = digit 0 in
  let c1 = __bn_cmp r mm in
  let tc1 = if ok then c1 <= 0 else c1 < 0 in
  let _ = __bn_add t r mp in
  let c2 = __bn_cmp t s in
  let tc2 = if ok then c2 >= 0 else c2 > 0 in
  if not tc1 && not tc2 then (let _ = vec_push out d in __d64_gen r s mp mm ok out t)
  else if tc1 && not tc2 then vec_push out d
  else if tc2 && not tc1 then vec_push out (d + 1)
  else
    // both: the nearer; a tie goes to the even digit
    let _ = __bn_add t r r in
    let c3 = __bn_cmp t s in
    vec_push out (if c3 < 0 then d else if c3 > 0 then d + 1 else (if bit_and d 1 == 0 then d else d + 1));
// (digits msb first, k): value = 0.d1 d2 ... * 10^k
let __d64_shortest = fn (f: int) -> fn (e: int) -> fn (subn: bool) ->
  // every value here stays under ~1130 bits (38 limbs)
  let r = __bn_new_cap 42 in let s = __bn_new_cap 42 in
  let mp = __bn_new_cap 42 in let mm = __bn_new_cap 42 in
  let pow2 = bit_shl 1 52 in
  let unequal = f == pow2 && not subn in
  let _ = (if e >= 0 then
             (if not unequal then
                (let _ = __bn_set_int r f in let _ = __bn_shl r (e + 1) in
                 let _ = __bn_set_int s 2 in
                 let _ = __bn_set_int mp 1 in let _ = __bn_shl mp e in
                 let _ = __bn_set_int mm 1 in __bn_shl mm e)
              else
                (let _ = __bn_set_int r f in let _ = __bn_shl r (e + 2) in
                 let _ = __bn_set_int s 4 in
                 let _ = __bn_set_int mp 1 in let _ = __bn_shl mp (e + 1) in
                 let _ = __bn_set_int mm 1 in __bn_shl mm e))
           else
             (if not unequal then
                (let _ = __bn_set_int r (f * 2) in
                 let _ = __bn_set_int s 1 in let _ = __bn_shl s (1 - e) in
                 let _ = __bn_set_int mp 1 in __bn_set_int mm 1)
              else
                (let _ = __bn_set_int r (f * 4) in
                 let _ = __bn_set_int s 1 in let _ = __bn_shl s (2 - e) in
                 let _ = __bn_set_int mp 2 in __bn_set_int mm 1))) in
  let ok = bit_and f 1 == 0 in
  // k estimate: ceil(log10 v), at most one low
  let lf = __bn_bl f 0 in
  let est0 = float_of_int (e + lf - 1) * 0.30102999566398114 - 0.0000000001 in
  let est = int_of_float est0 + (if est0 > float_of_int (int_of_float est0) then 1 else 0) in
  let _ = (if est >= 0 then __bn_mul_pow10 s est
           else (let _ = __bn_mul_pow10 r (0 - est) in
                 let _ = __bn_mul_pow10 mp (0 - est) in __bn_mul_pow10 mm (0 - est))) in
  let t = __bn_new_cap 42 in
  let _ = __bn_add t r mp in
  let c = __bn_cmp t s in
  let low = if ok then c >= 0 else c > 0 in
  let k = if low then est + 1 else est in
  let _ = (if low then __bn_mul_add s 10 0 else ()) in
  let out = vec_new () in
  let _ = __d64_gen r s mp mm ok out t in
  (out, k);
// exactly p significant digits of v = f 2^e, correctly rounded (half to even on
// the exact remainder): %.{p}g's digits. Needed beside the shortest string when
// that is under 12 digits: there %.12g prints the exact value's 12-digit
// rounding, which is the shortest string padded with zeros only while the
// double's own precision is far finer than 12 digits. A subnormal's is not:
// the smallest prints 4.94065645841e-324, where the shortest is 5e-324.
let __d64_fixed = fn (f: int) -> fn (e: int) -> fn (p: int) ->
  let r = __bn_new_cap 42 in let s = __bn_new_cap 42 in
  let _ = __bn_set_int r f in let _ = __bn_set_int s 1 in
  let _ = (if e >= 0 then __bn_shl r e else __bn_shl s (0 - e)) in
  let lf = __bn_bl f 0 in
  let est0 = float_of_int (e + lf - 1) * 0.30102999566398114 - 0.0000000001 in
  let est = int_of_float est0 + (if est0 > float_of_int (int_of_float est0) then 1 else 0) in
  let _ = (if est >= 0 then __bn_mul_pow10 s est else __bn_mul_pow10 r (0 - est)) in
  // r / s = v / 10^est, below 1 unless the estimate was one low
  let up = __bn_cmp r s >= 0 in
  let _ = (if up then __bn_mul_add s 10 0 else ()) in
  let k = if up then est + 1 else est in
  let out = vec_new () in
  let rec gen = fn (i: int) ->
    if i >= p then ()
    else
      let _ = __bn_mul_add r 10 0 in
      let rec digit = fn (d: int) -> if __bn_cmp r s >= 0 then (let _ = __bn_sub r s in digit (d + 1)) else d in
      let _ = vec_push out (digit 0) in
      gen (i + 1) in
  let _ = gen 0 in
  let t = __bn_new_cap 42 in
  let _ = __bn_add t r r in
  let c = __bn_cmp t s in
  let roundup = c > 0 || (c == 0 && bit_and (vec_get out (p - 1)) 1 == 1) in
  let rec carry = fn (i: int) ->
    if i < 0 then true
    else if vec_get out i == 9 then (let _ = vec_set out i 0 in carry (i - 1))
    else (let _ = vec_set out i (vec_get out i + 1) in false) in
  let over = if roundup then carry (p - 1) else false in
  if over then
    (let o2 = vec_new () in
     let _ = vec_push o2 1 in
     let rec zs = fn (i: int) -> if i >= p - 1 then () else let _ = vec_push o2 0 in zs (i + 1) in
     let _ = zs 0 in (o2, k + 1))
  else (out, k);
// the digits without their trailing zeros (at least one kept)
let __d64_strip = fn (d: int Vec) ->
  let rec last = fn (i: int) -> if i <= 0 then 0 else if vec_get d i != 0 then i else last (i - 1) in
  let n = last (vec_len d - 1) + 1 in
  let o = vec_new () in
  let rec cp = fn (i: int) -> if i >= n then () else let _ = vec_push o (vec_get d i) in cp (i + 1) in
  let _ = cp 0 in o;
let __d64_exp_str = fn (x: int) ->
  let mag = if x < 0 then 0 - x else x in
  "e" ++ (if x < 0 then "-" else "+") ++ (if mag < 10 then "0" else "") ++ str_of_int mag;
let __d64_digits = fn (dig: int Vec) -> fn (i: int) -> fn (j: int) ->
  // digits i .. j-1 as text, zeros past the end
  let b = strbuf_new () in
  let rec go = fn (k: int) ->
    if k >= j then ()
    else let _ = strbuf_push b (chr (48 + (if k < vec_len dig then vec_get dig k else 0))) in go (k + 1) in
  let _ = go i in
  strbuf_to_str b;
let __d64_str_of_float = fn (x: float) ->
  // read through the two 32-bit halves, so this holds on any int of 63 bits or more
  let m32 = bit_shl 1 32 - 1 in
  let hi = bit_and (float_bits_hi x) m32 in
  let lo = bit_and (float_bits_lo x) m32 in
  let neg = bit_and (bit_shr hi 31) 1 == 1 in
  let ex = bit_and (bit_shr hi 20) 2047 in
  let frac = bit_or (bit_shl (bit_and hi 1048575) 32) lo in
  if ex == 2047 then (if frac != 0 then "nan" else if neg then "-inf" else "inf")
  else if ex == 0 && frac == 0 then (if neg then "-0.0" else "0.0")
  else
    let f = if ex == 0 then frac else bit_or frac (bit_shl 1 52) in
    let e = if ex == 0 then 0 - 1074 else ex - 1075 in
    let (dig0, k0) = __d64_shortest f e (ex <= 1) in
    let (dig, k) = if vec_len dig0 >= 12 then (dig0, k0)
                   else (let (d12, k12) = __d64_fixed f e 12 in (__d64_strip d12, k12)) in
    let n = vec_len dig in
    let p = if vec_len dig0 > 12 then vec_len dig0 else 12 in
    let xx = k - 1 in
    let body =
      if xx < 0 - 4 || xx >= p then
        __d64_digits dig 0 1 ++ (if n > 1 then "." ++ __d64_digits dig 1 n else "") ++ __d64_exp_str xx
      else if xx >= 0 then
        __d64_digits dig 0 (xx + 1) ++ (if n > xx + 1 then "." ++ __d64_digits dig (xx + 1) n else ".0")
      else
        let zb = strbuf_new () in
        let rec zs = fn (i: int) -> if i >= 0 - xx - 1 then () else let _ = strbuf_push zb "0" in zs (i + 1) in
        let _ = zs 0 in
        "0." ++ strbuf_to_str zb ++ __d64_digits dig 0 n in
    (if neg then "-" else "") ++ body;

// ---- float_of_str: the decimal case on words -----------------------------------
// The lexical rules are the limb parser's (trim, ndrop '_', sign, digits with one
// '.', an optional e/E exponent, the whole string); anything that is not that --
// hex, inf, nan, or not a number -- is handed to it, so its answers and its
// failure messages are the same ones. The value: D * 10^k with D the digits (the
// first 800 significant ones; any further nonzero digit becomes one sticky '1'
// below them, which cannot change a rounding). k >= 0: D 10^k exactly, its top
// 57 bits and a sticky bit to pack. k < 0: 57-58 quotient bits of D 2^j / 5^-k by
// long division, the remainder as sticky; pack rounds once either way.
let __d64_is_ws = fn (c: int) -> c == 32 || c == 9 || c == 10 || c == 13 || c == 12;
let __d64_parse = fn (s: str) -> fn (old: str -> float) ->
  let n = str_len s in
  let ch = fn (i: int) -> ord (char_at s i) in
  let rec lead = fn (i: int) -> if i < n && __d64_is_ws (ch i) then lead (i + 1) else i in
  let rec trail = fn (i: int) -> if i > 0 && __d64_is_ws (ch (i - 1)) then trail (i - 1) else i in
  let a = lead 0 in
  let bnd = trail n in
  // the next non-'_' position at or after i
  let rec nx = fn (i: int) -> if i < bnd && ch i == 95 then nx (i + 1) else i in
  let i0 = nx a in
  let neg = i0 < bnd && ch i0 == 45 in
  let i1 = if i0 < bnd && (ch i0 == 45 || ch i0 == 43) then nx (i0 + 1) else i0 in
  // only digits, '.', 'e', 'E', '+', '-' from here; a letter means hex / inf / nan / bad
  let dig = vec_new () in
  let rec mant = fn (i: int) -> fn (dot: bool) -> fn (seen: int) -> fn (sig: int) -> fn (fdig: int) -> fn (ndrop: int) -> fn (sticky: bool) ->
    if i >= bnd then (i, seen, sig, fdig, ndrop, sticky)
    else
      let c = ch i in
      if c == 46 && not dot then mant (nx (i + 1)) true seen sig fdig ndrop sticky
      else if c >= 48 && c <= 57 then
        let d = c - 48 in
        let fd = if dot then fdig + 1 else fdig in
        if sig == 0 && d == 0 then mant (nx (i + 1)) dot (seen + 1) 0 fd ndrop sticky
        else if sig < 800 then (let _ = vec_push dig d in mant (nx (i + 1)) dot (seen + 1) (sig + 1) fd ndrop sticky)
        else mant (nx (i + 1)) dot (seen + 1) (sig + 1) fd (ndrop + 1) (sticky || d != 0)
      else (i, seen, sig, fdig, ndrop, sticky) in
  let (i2, seen, sig, fdig, ndrop, sticky) = mant i1 false 0 0 0 0 false in
  // one sign at most: "1e+-5" is not a number (strtod stops at the 'e')
  let rec pexp = fn (i: int) -> fn (acc: int) -> fn (any: int) -> fn (sg: int) -> fn (signed: bool) ->
    if i >= bnd then (if any == 0 then (0 - 1, 0) else (i, sg * acc))
    else
      let c = ch i in
      if any == 0 && not signed && c == 45 then pexp (nx (i + 1)) acc 0 (0 - 1) true
      else if any == 0 && not signed && c == 43 then pexp (nx (i + 1)) acc 0 sg true
      else if c >= 48 && c <= 57 then pexp (nx (i + 1)) (if acc > 1000000 then acc else acc * 10 + (c - 48)) (any + 1) sg signed
      else (if any == 0 then (0 - 1, 0) else (i, sg * acc)) in
  let (i3, dexp) = if i2 < bnd && (ch i2 == 101 || ch i2 == 69) then pexp (nx (i2 + 1)) 0 0 1 false else (i2, 0) in
  if seen == 0 || i3 != bnd || i3 < 0 then old s
  else
    let sgn = fn (v: float) -> if neg then f_neg v else v in
    // the packed word is positive (sign 0): its top half masked to 31 bits, so
    // an int of only 63 bits (the interpreter's) builds it too
    let pos = fn (w: int) -> float_of_bits (bit_and (bit_shr w 32) 2147483647) (bit_and w (bit_shl 1 32 - 1)) in
    if sig == 0 then (if neg then f_neg 0.0 else 0.0)
    else
      let top10 = (sig - 1) + (dexp - fdig) in
      if top10 >= 310 then (if neg then 0.0 - 1.0 / 0.0 else 1.0 / 0.0)
      else if top10 <= 0 - 330 then (if neg then f_neg 0.0 else 0.0)
      else
        // D, with the sticky digit
        let dd = __bn_new () in
        let rec acc = fn (i: int) -> if i >= vec_len dig then () else let _ = __bn_mul_add dd 10 (vec_get dig i) in acc (i + 1) in
        let _ = acc 0 in
        let _ = (if sticky then __bn_mul_add dd 10 1 else ()) in
        let k = dexp - fdig + ndrop - (if sticky then 1 else 0) in
        if k >= 0 then
          let _ = __bn_mul_pow10 dd k in
          let l = __bn_bitlen dd in
          if l <= 57 then sgn (pos (__f64_pack 0 (__bn_bits dd 0 l) 1078 0))
          else
            sgn (pos (__f64_pack 0 (__bn_bits dd (l - 57) 57) (1078 + (l - 57))
                                         (if __bn_any_below dd (l - 57) then 1 else 0)))
        else
          let q5 = __bn_new () in
          let _ = __bn_set_int q5 1 in
          let _ = __bn_mul_pow5 q5 (0 - k) in
          let j = 57 - __bn_bitlen dd + __bn_bitlen q5 in
          let _ = (if j >= 0 then __bn_shl dd j else __bn_shl q5 (0 - j)) in
          let _ = __bn_shl q5 57 in
          let rec div = fn (b: int) -> fn (q: int) ->
            if b < 0 then q
            else if __bn_cmp dd q5 >= 0 then
              (let _ = __bn_sub dd q5 in let _ = __bn_shr1 q5 in div (b - 1) (bit_or q (bit_shl 1 b)))
            else (let _ = __bn_shr1 q5 in div (b - 1) q) in
          let q = div 57 0 in
          sgn (pos (__f64_pack 0 q (1078 - j + k) (if vec_get dd 0 == 0 then 0 else 1)));

let float_of_str = fn (s: str) ->
  if __rv_xlen () == 64 then __d64_parse s (fn (t: str) -> __sf_float_of_sf (__sf_sf_of_dec t))
  else __sf_float_of_sf (__sf_sf_of_dec s);

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
// double-double: a pair (h, l) whose sum carries ~106 bits, |l| <= ulp(h)/2.
// v0.1.609 builds the libm on these (lib/rv_libm.ml); they are the textbook
// Dekker / Knuth constructions, and every one is a few float operations.
let __dd_fast = fn (a: float) -> fn (b: float) -> let s = a + b in (s, b - (s - a));
let __dd_add = fn (ah: float) -> fn (al: float) -> fn (bh: float) -> fn (bl: float) ->
  let (s, e) = __fp_two_sum ah bh in
  let (t, f) = __fp_two_sum al bl in
  let (s2, e2) = __dd_fast s (e + t) in
  __dd_fast s2 (e2 + f);
let __dd_mul = fn (ah: float) -> fn (al: float) -> fn (bh: float) -> fn (bl: float) ->
  let (p, e) = __fp_two_prod ah bh in
  __dd_fast p (e + (ah * bl + al * bh));
let __dd_mul_d = fn (ah: float) -> fn (al: float) -> fn (b: float) ->
  let (p, e) = __fp_two_prod ah b in
  __dd_fast p (e + al * b);
// three quotient digits, each from the exact remainder
let __dd_div = fn (ah: float) -> fn (al: float) -> fn (bh: float) -> fn (bl: float) ->
  let q1 = ah / bh in
  let (ph, pl) = __dd_mul_d bh bl q1 in
  let (rh, rl) = __dd_add ah al (0.0 - ph) (0.0 - pl) in
  let q2 = rh / bh in
  let (ph2, pl2) = __dd_mul_d bh bl q2 in
  let (rh2, _) = __dd_add rh rl (0.0 - ph2) (0.0 - pl2) in
  let q3 = rh2 / bh in
  let (qh, ql) = __dd_fast q1 q2 in
  __dd_add qh ql q3 0.0;
// one Newton step from the correctly rounded sqrt; ah > 0
let __dd_sqrt = fn (ah: float) -> fn (al: float) ->
  let s = sqrt ah in
  let (p, pe) = __fp_two_prod s s in
  __dd_fast s ((((ah - p) - pe) + al) / (2.0 * s));

// e^(zh + zl). k = round(zh / ln 2) and r = zh - k ln2 as a pair (Cody-Waite:
// ln2_hi has 33 bits, so k * ln2_hi is exact for every k this range allows,
// and the subtraction is exact by Sterbenz). Then e^r = 1 + r + r^2/2 + r^3/6
// + r^4 P(r): the first four terms are summed in pairs -- r^2 by two_prod,
// r^3/6 by __dd_mul -- and the rest is below 6e-4, where its own rounding is
// 1e-20 of the result. The input's tail rides in as zl e^r: the pair is what
// lets f_pow pass y log x without rounding it first. The core hands back
// (b, lo, k) with e^z = (b + lo) 2^k unrounded; __fp_exp2 rounds it once and
// __dd_exp keeps it as a pair (v0.1.609: r^3/6 was in double before, a 1e-18
// error that is invisible in one rounding and not in erfc = 1 - erf).
let __fp_exp_core = fn (zh: float) -> fn (zl: float) ->
  let kf = round (zh * 1.4426950408889634) in
  let k = int_of_float kf in
  let r1 = zh - kf * 0.6931471803691238 in
  let (rh, re) = __fp_two_sum r1 (0.0 - kf * 1.9082149292705877e-10) in
  let rl = re + zl in
  let p = 7.647163731819816e-13 in
  let p = p * rh + 1.1470745597729725e-11 in
  let p = p * rh + 1.6059043836821613e-10 in
  let p = p * rh + 2.08767569878681e-09 in
  let p = p * rh + 2.505210838544172e-08 in
  let p = p * rh + 2.755731922398589e-07 in
  let p = p * rh + 2.7557319223985893e-06 in
  let p = p * rh + 2.48015873015873e-05 in
  let p = p * rh + 0.0001984126984126984 in
  let p = p * rh + 0.001388888888888889 in
  let p = p * rh + 0.008333333333333333 in
  let p = p * rh + 0.041666666666666664 in
  let (sh, sl) = __fp_two_prod rh rh in
  let (ch, cl) = __dd_mul_d sh sl rh in
  let (th, tl) = __dd_mul ch cl 0.16666666666666666 9.25185853854297e-18 in
  let c4 = (ch * rh) * p in
  let (a, ea) = __fp_two_sum 1.0 rh in
  let (b, eb) = __fp_two_sum a (sh * 0.5) in
  let (b2, eb2) = __fp_two_sum b th in
  let lo = ((ea + eb) + eb2) + ((sl * 0.5 + tl) + (c4 + rl * (b2 + c4))) in
  (b2, lo, k);
let __fp_scale = fn (m: float) -> fn (k: int) ->
  if k >= 0 - 1021 && k <= 1023 then m * __fp_pow2i k
  else if k < 0 - 1021 then (m * __fp_pow2i (k + 512)) * __fp_pow2i (0 - 512)
  else (m * __fp_pow2i (k - 512)) * __fp_pow2i 512;
let __fp_exp2 = fn (zh: float) -> fn (zl: float) ->
  let (b, lo, k) = __fp_exp_core zh zl in
  __fp_scale (b + lo) k;
let __dd_exp = fn (zh: float) -> fn (zl: float) ->
  let (b, lo, k) = __fp_exp_core zh zl in
  let (h, l) = __dd_fast b lo in
  if k >= 0 - 1021 && k <= 1023 then (let s = __fp_pow2i k in (h * s, l * s))
  else (__fp_scale h k, __fp_scale l k);

let exp = fn (x: float) ->
  if x != x then x
  else if x > 709.782712893384 then 1.0 / 0.0
  else if x < 0.0 - 745.1332191019412 then 0.0
  else __fp_exp2 x 0.0;

// log as a HEAD+TAIL pair, good to ~1e-21 relative: f_pow needs the pair (a
// 1-ulp log error, magnified by y, is the whole ballgame there), the libm
// builds on it (lib/rv_libm.ml), and `log` itself is head + tail rounded once.
// m in [1/sqrt2, sqrt2), s = (m-1)/(m+1) with its rounding kept as a tail, and
// log m = 2 atanh s = 2s + (2/3)s^3 + (2/5)s^5 + 2s^7 (1/7 + ...): the first
// three terms in pairs (v0.1.609; before, everything past 2s was in double, a
// 2e-19 error), s's tail scaled by the derivative 2/(1 - s^2), and the series
// through s^29.
let __fp_log2p = fn (x: float) ->
  // subnormals scale into the normal range first, and k pays for it
  let sub = __fp_hi_exp (float_bits_hi x) == 0 in
  let x1 = if sub then x * 18014398509481984.0 else x in
  let k0 = if sub then 0 - 54 else 0 in
  let hi = float_bits_hi x1 in
  let lo = float_bits_lo x1 in
  let e = __fp_hi_exp hi in
  let m0 = float_of_bits (bit_or (bit_and hi 1048575) (bit_shl 1023 20)) lo in
  let (m, k) = if m0 >= 1.4142135623730951
               then (m0 * 0.5, k0 + e - 1022)
               else (m0, k0 + e - 1023) in
  let u = m - 1.0 in
  let (v, vt) = __fp_two_sum m 1.0 in
  let s = u / v in
  let (q, qe) = __fp_two_prod s v in
  let st = (((u - q) - qe) - s * vt) / v in
  let w = s * s in
  let p = 0.034482758620689655 in
  let p = p * w + 0.037037037037037035 in
  let p = p * w + 0.04 in
  let p = p * w + 0.043478260869565216 in
  let p = p * w + 0.047619047619047616 in
  let p = p * w + 0.05263157894736842 in
  let p = p * w + 0.058823529411764705 in
  let p = p * w + 0.06666666666666667 in
  let p = p * w + 0.07692307692307693 in
  let p = p * w + 0.09090909090909091 in
  let p = p * w + 0.1111111111111111 in
  let p = p * w + 0.14285714285714285 in
  let (s2h, s2l) = __fp_two_prod s s in
  let (s3h, s3l) = __dd_mul_d s2h s2l s in
  let (ch, cl) = __dd_mul s3h s3l 0.6666666666666666 3.700743415417188e-17 in
  let (s5h, s5l) = __dd_mul s3h s3l s2h s2l in
  let (fh, fl) = __dd_mul s5h s5l 0.4 (0.0 - 2.2204460492503132e-17) in
  let rest = 2.0 * s5h * w * p in
  let kf = float_of_int k in
  let (h0, e0) = __fp_two_sum (kf * 0.6931471803691238) (2.0 * s) in
  let (h1, e1) = __fp_two_sum h0 ch in
  let (h2, e2) = __fp_two_sum h1 fh in
  let t0 = ((e0 + e1) + e2)
           + ((2.0 * st / (1.0 - w) + kf * 1.9082149292705877e-10) + ((cl + fl) + rest)) in
  __dd_fast h2 t0;
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
// (v0.1.609: this one was written 6.07710050630396e-11 -- fifteen digits, not
// the double fdlibm's 6.07710050630396597660e-11 names -- so the four pieces
// summed to pi/2 - 6.5e-26, and tan of the double nearest pi/2 was 1e-9 off)
let __fp_pio2_2 = 6.077100506303966e-11;
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
// sin / cos / tan / atan2 and the libm: lib/rv_libm.ml, appended to this.
let str_of_float = fn (x: float) ->
  if __rv_xlen () == 64 then __d64_str_of_float x
  else __sf_dec_of_sf (__sf_sf_of_float x);

// --- coroutines (v0.1.623) -------------------------------------------------
// The runtime the C backend writes in C, written in Mere on raw words: a table
// of records, one per coroutine (slot 0 is the main stack), a free list of
// slots, and __rv_cswap to move between stacks. Every coroutine runs in the
// same region, its stack copied in when it is entered and out when it is left
// (see __rv_cswap), so a suspended coroutine costs the words its stack holds.
// A handle is gen * 65536 + slot: a handle to a finished coroutine whose slot
// was reused is told apart from the new one, as the C backend's generations do.
// Record words: 0 state (0 new, 1 running, 2 suspended, 3 finished, 4 free),
// 1 gen, 2 sp, 3 buffer, 4 its capacity in words, 5 floor, 6 body closure,
// 7 message, 8..11 the stack's own runtime words (try_or record, region depth,
// block mark, outermost block mark), 12 the next free slot + 1, 13 gp when it
// last stopped.
// Runtime words: 34 the sp just left, 35..39 the switch's parameters, 40 the
// table, 41 its capacity, 42 slots in use, 43 free list (slot + 1), 44 running,
// 45 previous, 46 finished and waiting to be reaped (slot + 1), 47 how many
// coroutines exist, 48 set once the table is made.
let __cw = fn (u: unit) -> if __rv_xlen () == 64 then 8 else 4;
let __crec = fn (s: int) -> __rv_peek (__rv_rtw 40 + s * __cw ());
let __cget = fn (s: int) -> fn (k: int) -> __rv_peek (__crec s + k * __cw ());
let __cset = fn (s: int) -> fn (k: int) -> fn (v: int) -> __rv_poke (__crec s + k * __cw ()) v;
let rec __czero = fn (a: int) -> fn (n: int) ->
  if n == 0 then () else (let _ = __rv_poke a 0 in __czero (a + __cw ()) (n - 1));
let __cnew_rec = fn (s: int) ->
  let r = __rv_alloc_keep 16 in
  let _ = __czero r 16 in
  __rv_poke (__rv_rtw 40 + s * __cw ()) r;
let __cinit = fn (u: unit) ->
  if __rv_rtw 48 != 0 then () else
  let _ = __rv_rtw_set 40 (__rv_alloc_keep 64) in
  let _ = __rv_rtw_set 41 64 in
  let _ = __rv_rtw_set 42 1 in
  let _ = __rv_rtw_set 43 0 in
  let _ = __cnew_rec 0 in
  let _ = __cset 0 0 1 in
  let _ = __cset 0 1 1 in
  let _ = __cset 0 5 (__rv_main_lo ()) in
  let _ = __rv_rtw_set 44 0 in
  __rv_rtw_set 48 1;
let __chandle = fn (s: int) -> __cget s 1 * 65536 + s;
// the slot of a live coroutine's handle, or -1
let __cslot = fn (h: int) ->
  let s = h % 65536 in
  if h <= 0 || s >= __rv_rtw 42 then 0 - 1
  else if __cget s 1 != h / 65536 then 0 - 1
  else (let st = __cget s 0 in if st == 3 || st == 4 then 0 - 1 else s);
let rvcoro_root = fn (u: unit) -> let _ = __cinit () in __chandle 0;
let rec __ccopy = fn (dst: int) -> fn (src: int) -> fn (n: int) ->
  if n == 0 then ()
  else (let _ = __rv_poke dst (__rv_peek src) in __ccopy (dst + __cw ()) (src + __cw ()) (n - 1));
// a slot for a new coroutine: a reaped one, or the next, the table doubled
let __ctake = fn (u: unit) ->
  let f = __rv_rtw 43 in
  if f != 0 then (let s = f - 1 in let _ = __rv_rtw_set 43 (__cget s 12) in s)
  else
    let n = __rv_rtw 42 in
    let cap = __rv_rtw 41 in
    let _ = (if n < cap then () else
             (let nt = __rv_alloc_keep (cap * 2) in
              let _ = __ccopy nt (__rv_rtw 40) cap in
              let _ = __rv_rtw_set 40 nt in
              __rv_rtw_set 41 (cap * 2))) in
    let _ = __rv_rtw_set 42 (n + 1) in
    let _ = __cnew_rec n in
    n;
let rvcoro_new_sized = fn (size: int) -> fn (f: int) ->
  let _ = __cinit () in
  if size <= 0 then fail "coro_new_sized: a stack size must be between 1 byte and 1 GiB"
  else if size > 1073741824 then fail "coro_new_sized: a stack bigger than 1 GiB"
  else
    let s = __ctake () in
    let w = __cw () in
    let hi = __rv_co_hi () in
    let lo = __rv_co_lo () in
    let _ = (if __cget s 4 >= 64 then () else
             (let _ = __cset s 3 (__rv_alloc_keep 64) in __cset s 4 64)) in
    let buf = __cget s 3 in
    // the frame __rv_cswap pops: ra = __rv_coro_boot, every saved register 0
    let _ = __czero buf 14 in
    let _ = __rv_poke buf (__rv_boot_addr ()) in
    let _ = __cset s 0 0 in
    let _ = __cset s 1 (__cget s 1 % 32767 + 1) in
    let _ = __cset s 2 (hi - 14 * w) in
    let _ = __cset s 5 (if hi - size < lo then lo else hi - size) in
    let _ = __cset s 6 f in
    let _ = __cset s 7 0 in
    let _ = __czero (__crec s + 8 * w) 5 in
    let _ = __rv_rtw_set 47 (__rv_rtw 47 + 1) in
    // the body's closure, and whatever it captured, outlive any region block
    let _ = __rv_hwm_raise () in
    __chandle s;
let rvcoro_new = fn (f: int) -> rvcoro_new_sized (__rv_co_hi () - __rv_co_lo ()) f;
// on the stack just entered: the stack left gets its sp, this one its runtime
// words back, and a coroutine that finished on the way here is reaped
let __carrived = fn (u: unit) ->
  let me = __rv_rtw 44 in
  let p = __rv_rtw 45 in
  let _ = (if p == 0 then () else __cset p 2 (__rv_rtw 34)) in
  let _ = __rv_rtw_set 0 (__cget me 8) in
  let _ = __rv_rtw_set 1 (__cget me 9) in
  let _ = __rv_rtw_set 2 (__cget me 10) in
  let _ = __rv_rtw_set 4 (__cget me 11) in
  let z = __rv_rtw 46 in
  let _ = (if z == 0 then () else
           (let zs = z - 1 in
            let _ = __cset zs 0 4 in
            let _ = __cset zs 12 (__rv_rtw 43) in
            let _ = __rv_rtw_set 43 z in
            let _ = __rv_rtw_set 46 0 in
            __rv_rtw_set 47 (__rv_rtw 47 - 1))) in
  __cget me 7;
let __cswitch = fn (to: int) -> fn (v: int) -> fn (setmsg: bool) ->
  let from = __rv_rtw 44 in
  if to == from then v
  else
    let _ = (if setmsg then __cset to 7 v else ()) in
    let _ = __cset from 8 (__rv_rtw 0) in
    let _ = __cset from 9 (__rv_rtw 1) in
    let _ = __cset from 10 (__rv_rtw 2) in
    let _ = __cset from 11 (__rv_rtw 4) in
    // where the heap stood when this stack stopped (see __cwalk)
    let _ = __cset from 13 (__rv_gp ()) in
    let w = __cw () in
    let fin = __cget from 0 == 3 in
    // room to copy this stack out, with what the switch itself pushes
    let _ = (if from == 0 || fin then () else
             (let need = (__rv_co_hi () - __rv_sp ()) / w + 64 in
              if __cget from 4 >= need then ()
              else (let _ = __cset from 3 (__rv_alloc_keep (need * 2)) in __cset from 4 (need * 2)))) in
    let _ = __rv_rtw_set 35 (if from == 0 then 0 else if fin then 2 else 1) in
    let _ = __rv_rtw_set 36 (__cget from 3) in
    let _ = __rv_rtw_set 37 (if to == 0 then 0 else __cget to 3) in
    let _ = __rv_rtw_set 38 (__cget to 2) in
    let _ = __rv_rtw_set 39 (__cget to 5) in
    let _ = (if fin then () else __cset from 0 2) in
    let _ = __cset to 0 1 in
    let _ = __rv_rtw_set 45 from in
    let _ = __rv_rtw_set 44 to in
    // nothing allocated before this switch is rolled back by a region block
    // that closes on another stack
    let _ = __rv_hwm_raise () in
    let _ = __rv_cswap () in
    __carrived ();
// a coroutine's first return lands in __rv_coro_boot, which calls this
let rvcoro_boot = fn (u: unit) ->
  let me = __rv_rtw 44 in
  let _ = __carrived () in
  let next = __rv_call1 (__cget me 6) (__chandle me) in
  let ns = __cslot next in
  if ns < 0 || ns == me then fail "coro: a finished coroutine must hand over to another live coroutine"
  else
    let _ = __cset me 0 3 in
    let _ = __rv_rtw_set 46 (me + 1) in
    let _ = __cswitch ns 0 false in
    0;
let rvcoro_msg = fn (c: int) ->
  let s = __cslot c in
  if s < 0 || s != __rv_rtw 44 then fail "coro: a message is read by the coroutine it was sent to"
  else __cget s 7;
let rvcoro_switch = fn (c: int) ->
  let _ = __cinit () in
  let s = __cslot c in
  if s < 0 then fail "coro_switch: that coroutine has finished"
  else (let _ = __cswitch s 0 true in ());
let rvcoro_transfer = fn (c: int) -> fn (v: int) -> fn (me: int) ->
  let _ = __cinit () in
  if __cslot me != __rv_rtw 44 then fail "coro_transfer: the third argument must be the running coroutine"
  else
    let s = __cslot c in
    if s < 0 then fail "coro_transfer: that coroutine has finished"
    else __cswitch s v true;
// The walk under coro_scan_ints and the release of retired blocks: every word
// stack s can reach, handed to visit. The stack's words are read (a stopped
// coroutine's from its buffer, a stopped main stack from its saved sp up, the
// running one's from sp up with the saved registers spilled first, since a
// caller's value may be in one), and a word that points into the heap is
// followed: the 16 words from it are read in turn, up to three hops -- and
// without a limit inside the stack's own region values: from its innermost open
// block's mark up to where the heap stood when it stopped (the C backend's
// contract: unlimited inside the coroutine's own regions). Not from the
// outermost block's mark, and not up to the heap's current top: every
// allocation shares one bump pointer here, and mere-ruby keeps a block open for
// its whole run and collects on a coroutine of its own while its main stack
// waits -- either way most of the heap counted as "its own" and was walked.
// The walk allocates nothing per call (a Map and a Vec per walk were garbage
// no region block reclaimed, inside mere-ruby's collector): its visited set is
// an open-addressing table of [address, stamp] pairs kept across walks
// (runtime words 64 table, 65 capacity in pairs, 66 the stamp -- a pair with
// another walk's stamp is empty, so nothing is cleared) and its work list a
// reused array (67, 68 capacity in words; 69, 70 this walk's counts). Both
// grow and never shrink. `budget` caps the addresses followed (0: no cap), and
// the answer is false when the walk stopped at the cap.
let __cw_buf = fn (k: int) -> fn (ck: int) -> fn (want: int) ->
  // the buffer in runtime word k (capacity in ck), at least `want` words
  if __rv_rtw ck >= want then __rv_rtw k
  else (let n = if want < 1024 then 1024 else want * 2 in
        let b = __rv_alloc_keep n in
        let _ = __ccopy b (__rv_rtw k) (__rv_rtw ck) in
        let _ = __rv_rtw_set k b in
        let _ = __rv_rtw_set ck n in
        b);
// true when v was not yet in this walk's set (and is now)
let __cw_add = fn (v: int) ->
  let w = __cw () in
  let cap = __rv_rtw 65 in
  let tbl = __rv_rtw 64 in
  let st = __rv_rtw 66 in
  let rec probe = fn (i: int) ->
    let a = tbl + (i % cap) * 2 * w in
    if __rv_peek (a + w) != st then (let _ = __rv_poke a v in let _ = __rv_poke (a + w) st in true)
    else if __rv_peek a == v then false
    else probe (i + 1) in
  probe ((v / w) * 40503 % cap);
// a table twice the size, this walk's entries moved over
let __cw_rehash = fn (u: unit) ->
  let w = __cw () in
  let oldt = __rv_rtw 64 in
  let oldc = __rv_rtw 65 in
  let st = __rv_rtw 66 in
  let nc = oldc * 2 in
  let nt = __rv_alloc_keep (nc * 2) in
  let _ = __czero nt (nc * 2) in
  let _ = __rv_rtw_set 64 nt in
  let _ = __rv_rtw_set 65 nc in
  let rec mv = fn (i: int) ->
    if i == oldc then ()
    else (let a = oldt + i * 2 * w in
          let _ = (if __rv_peek (a + w) == st then (let _ = __cw_add (__rv_peek a) in ()) else ()) in
          mv (i + 1)) in
  mv 0;
let __cwalk = fn (s: int) -> fn (budget: int) -> fn (visit: int -> unit) ->
  let w = __cw () in
  let me = __rv_rtw 44 in
  let hlo = __rv_heap_lo () in
  let ghi = __rv_gp () in
  let own = (if s == me then (if __rv_rtw 1 > 0 then __rv_rtw 2 else ghi)
             else (if __cget s 9 > 0 then __cget s 10 else ghi)) in
  let own_hi = (if s == me then ghi else __cget s 13) in
  let _ = (if __rv_rtw 65 > 0 then () else
           (let t = __rv_alloc_keep 8192 in
            let _ = __czero t 8192 in
            let _ = __rv_rtw_set 64 t in
            __rv_rtw_set 65 4096)) in
  let _ = __rv_rtw_set 66 (__rv_rtw 66 + 1) in
  let _ = __rv_rtw_set 69 0 in
  let _ = __rv_rtw_set 70 0 in
  let look = fn (v: int) -> fn (d: int) ->
    let top = __rv_rtw 69 in
    let seen = __rv_rtw 70 in
    let _ = visit v in
    if v >= hlo && v < ghi && v % w == 0 && (d < 3 || (v >= own && v < own_hi))
       && (budget == 0 || seen < budget) then
      (let _ = (if seen * 2 >= __rv_rtw 65 then __cw_rehash () else ()) in
       if __cw_add v then
         (let b = __cw_buf 67 68 (top + 2) in
          let _ = __rv_poke (b + top * w) v in
          let _ = __rv_poke (b + (top + 1) * w) (d + 1) in
          let _ = __rv_rtw_set 69 (top + 2) in
          __rv_rtw_set 70 (seen + 1))
       else ())
    else () in
  let rec words = fn (a: int) -> fn (n: int) -> fn (d: int) ->
    if n == 0 then () else (let _ = look (__rv_peek a) d in words (a + w) (n - 1) d) in
  let _ = (if s == me then
             (let _ = __rv_spill () in
              let rec regs = fn (k: int) -> if k == 62 then () else (let _ = look (__rv_rtw k) 0 in regs (k + 1)) in
              let _ = regs 50 in
              let top = if s == 0 then __rv_stack_top () else __rv_co_hi () in
              let sp = __rv_sp () in
              words sp ((top - sp) / w) 0)
           else if s == 0 then
             (let sp = __rv_rtw 33 in words sp ((__rv_stack_top () - sp) / w) 0)
           else words (__cget s 3) ((__rv_co_hi () - __cget s 2) / w) 0) in
  // breadth first: the work list is read front to back while it grows
  let rec drain = fn (i: int) ->
    if i >= __rv_rtw 69 then ()
    else
      let b = __rv_rtw 67 in
      let p = __rv_peek (b + i * w) in
      let d = __rv_peek (b + (i + 1) * w) in
      let n = (if p + 16 * w > ghi then (ghi - p) / w else 16) in
      let _ = words p n d in
      drain (i + 2) in
  let _ = drain 0 in
  budget == 0 || __rv_rtw 70 < budget;
// coro_scan_ints: every word in [lo, hi) the coroutine's stack can still
// reach, reported to f -- conservatively: a number that is not a handle may be
// reported, a held one may not be missed. f is called after the whole walk, as
// on C, so it may allocate: called from inside the walk, it ran mere-ruby's
// collector code, whose region blocks ran a release, whose walk reset this
// one's state halfway through (word 71 is set while a walk runs, and a
// release does not start then).
let rvcoro_scan_ints = fn (c: int) -> fn (lo: int) -> fn (hi: int) -> fn (f: int -> unit) ->
  let _ = __cinit () in
  let s = __cslot c in
  if s < 0 then () else
  let found = vec_new () in
  let _ = __rv_rtw_set 71 1 in
  let _ = __cwalk s 0 (fn (v: int) -> if lo <= v && v < hi then vec_push found v else ()) in
  let _ = __rv_rtw_set 71 0 in
  let rec give = fn (i: int) -> if i == vec_len found then () else (let _ = f (vec_get found i) in give (i + 1)) in
  give 0;
// v0.1.624: blocks a compaction handed back while coroutines exist wait on the
// retired list (word 49, chained through their first word; word 62 counts the
// bytes retired since the last release). Once a megabyte waits -- checked after a compaction and at a
// region block's exit -- the ones no stopped stack can reach (the walk above,
// every stack but the running one) go back to the free lists, the rest wait
// for the next time. A walk that reaches its cap has not seen everything, and
// then every block is kept: mere-ruby's main stack, stopped while its
// collector runs on a coroutine, reaches most of the heap, and gets nothing
// back until it is running again, as if no release had run.
let rvcoro_release = fn (u: unit) ->
  if __rv_rtw 71 != 0 then () else
  let _ = __rv_rtw_set 71 1 in
  let w = __cw () in
  let starts = vec_new () in
  let ends = vec_new () in
  let rec take = fn (b: int) ->
    if b == 0 then ()
    else (let nx = __rv_peek b in
          let _ = vec_push starts b in
          let _ = vec_push ends (b + __rv_peek (b + w)) in
          take nx) in
  let _ = take (__rv_rtw 49) in
  let _ = __rv_rtw_set 49 0 in
  let _ = __rv_rtw_set 62 0 in
  let n = vec_len starts in
  let pinned = vec_new () in
  let rec zero = fn (i: int) -> if i == n then () else (let _ = vec_push pinned 0 in zero (i + 1)) in
  let _ = zero 0 in
  let rec pin_all = fn (i: int) -> if i == n then () else (let _ = vec_set pinned i 1 in pin_all (i + 1)) in
  let mark = fn (v: int) ->
    let rec find = fn (i: int) ->
      if i == n then ()
      else if v >= vec_get starts i && v < vec_get ends i then vec_set pinned i 1
      else find (i + 1) in
    find 0 in
  let me = __rv_rtw 44 in
  let rec each = fn (s: int) ->
    if s >= __rv_rtw 42 then ()
    else (let _ = (if s != me && __cget s 0 == 2
                   then (if __cwalk s 65536 mark then () else pin_all 0)
                   else ()) in
          each (s + 1)) in
  let _ = (if __rv_rtw 47 > 0 then each 0 else ()) in
  let rec back = fn (i: int) ->
    if i == n then ()
    else (let b = vec_get starts i in
          // a pinned block waits again, but is not counted again: word 62 is
          // what was retired since the last release, so the next one comes
          // after another megabyte (counted, a stack that pins a megabyte ran
          // a release -- and its allocations -- at every block exit)
          let _ = (if vec_get pinned i == 0 then __rv_blk_free b
                   else (let _ = __rv_poke b (__rv_rtw 49) in
                         __rv_rtw_set 49 b)) in
          back (i + 1)) in
  let _ = back 0 in
  __rv_rtw_set 71 0;
// sleep_ms: there is no sleep to ask the emulator for, so this waits on the
// clock (v0.1.624; mere-ruby's Fiber scheduler sleeps)
let sleep_ms = fn (ms: int) ->
  if ms <= 0 then () else
  let t0 = time () in
  let lim = float_of_int ms / 1000.0 in
  let rec spin = fn (u: unit) -> if time () - t0 >= lim then () else spin () in
  spin ();
let rvcoro_exit = fn (c: int) -> fn (v: int) ->
  let s = __cslot c in
  let _ = (if s < 0 then () else __cset s 7 v) in
  c;
|mere} ^ Rv_libm.contents

(* v0.1.623: the text glued ahead of an -rv program. MERE_RV_PRELUDE_FILE names
   another one to use instead -- a gate that has to show its fixtures go red
   without a piece of the prelude's runtime (scripts/coro_check.sh --poison)
   edits the text that `mere --rv-prelude` prints and points this at it. *)
let contents =
  match Sys.getenv_opt "MERE_RV_PRELUDE_FILE" with
  | Some f when f <> "" ->
    let ic = open_in_bin f in
    let n = in_channel_length ic in
    let t = really_input_string ic n in
    close_in ic; t
  | _ -> builtin_contents

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
