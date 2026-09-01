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

// --- host services this target does not have ------------------------------
// Not a scaffold: `--bare` hands the program the machine, and there is no host
// to read a file from, run a command through, or draw entropy out of. These stop
// with a message rather than being refused at compile time, for the reason the
// `extern fn` calls do -- refusing refuses the whole program for a call it may
// never make, and the program this backend is being carried for is an
// interpreter whose scripts mostly touch none of them.
//
// `random_int` is here rather than implemented because a deterministic sequence
// returned from something named random is the kind of wrong that stays quiet.
let __h_todo = fn (n: str) -> fail ("RV32I: " ++ n ++ " needs a host, and --bare hands the program the machine instead");
let run = fn (c: str) -> (__h_todo "run" : int);
let read_file = fn (p: str) -> (__h_todo "read_file" : str);
let file_exists = fn (p: str) -> (__h_todo "file_exists" : bool);
let random_int = fn (n: int) -> (__h_todo "random_int" : int);
// A clock needs a host to ask. Returning a fixed number would make a program
// that measures elapsed time report 0 rather than say it cannot measure.
let time = fn (u: unit) -> (__h_todo "time" : float);
let write_file = fn (p: str) -> fn (c: str) -> (__h_todo "write_file" : unit);
// `args` is the one host service on this list that is not a host service here:
// the loader leaves the arguments in RAM and this walks them. A program built
// with -rv therefore reads its own command line, and one started by a loader
// that left the block untouched sees Nil -- which is the true answer, not an
// error, because it really was given no arguments.
let rec __rv_args_go = fn (i: int) -> fn (n: int) ->
  if i >= n then (Nil : str list) else Cons (__rv_argstr i, __rv_args_go (i + 1) n);
let args = fn (u: unit) -> __rv_args_go 0 (__rv_argc ());

let read_stdin = fn (u: unit) -> (__h_todo "read_stdin" : str);
// `bytes` has no representation on this backend at all -- these are not a host
// service but the type itself, and they are here for the same reason: a program
// that never builds one runs.
let bytes_of_str = fn (s: str) -> (__h_todo "bytes_of_str" : bytes);
let print_bytes = fn (b: bytes) -> (__h_todo "print_bytes" : unit);

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
// What is left after softfloat: the transcendentals, `f_pow`, `f_min`/`f_max`,
// and the decimal conversions. The message used to say softfloat "is not yet
// injected into the -rv prelude", which stopped being true the day it was --
// and would have gone on telling every user to go and do the thing that had
// already been done.
let __f_todo = fn (n: str) -> fail ("RV32I: " ++ n ++ " is not computed on this backend -- contrib/softfloat is injected and does the four arithmetic operators, the comparisons and int conversion, but not this");
let f_min = fn (a: float) -> fn (b: float) -> (__f_todo "f_min" : float);
let f_max = fn (a: float) -> fn (b: float) -> (__f_todo "f_max" : float);
// f_add / f_sub / f_mul / f_div / f_neg / f_abs / the four f_ comparisons and
// float_of_int / int_of_float are real now, at the bottom of this file, next to
// the softfloat library they call. What stays a stub here is what softfloat does
// not compute: the transcendentals, `f_pow`, and the decimal conversions. f_min
// and f_max stay too -- `if a < b then a else b` is *a* definition, but the
// host's is fmin/fmax with their own NaN rules, and guessing which would put a
// wrong answer where an honest refusal is.
let f_pow = fn (a: float) -> fn (b: float) -> (__f_todo "f_pow" : float);
let atan2 = fn (a: float) -> fn (b: float) -> (__f_todo "atan2" : float);
let sqrt = fn (a: float) -> (__f_todo "sqrt" : float);
let sin = fn (a: float) -> (__f_todo "sin" : float);
let cos = fn (a: float) -> (__f_todo "cos" : float);
let tan = fn (a: float) -> (__f_todo "tan" : float);
let log = fn (a: float) -> (__f_todo "log" : float);
let exp = fn (a: float) -> (__f_todo "exp" : float);
let floor = fn (a: float) -> (__f_todo "floor" : float);
let ceil = fn (a: float) -> (__f_todo "ceil" : float);
let round = fn (a: float) -> (__f_todo "round" : float);
let float_of_str = fn (s: str) -> (__f_todo "float_of_str" : float);
let str_of_float = fn (x: float) -> (__f_todo "str_of_float" : str);

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

let rec _srep = fn s -> fn n -> fn acc -> if n <= 0 then acc else _srep s (n - 1) (acc ++ s);
let str_repeat = fn s -> fn n -> _srep s n "";

let rec _srev = fn s -> fn i -> fn acc -> if i < 0 then acc else _srev s (i - 1) (acc ++ char_at s i);
let str_rev = fn s -> _srev s (str_len s - 1) "";

let _lc1 = fn c -> let o = ord c in if o >= 65 && o <= 90 then chr (o + 32) else c;
let rec _lc = fn s -> fn i -> fn acc -> if i >= str_len s then acc else _lc s (i + 1) (acc ++ _lc1 (char_at s i));
let to_lower = fn s -> _lc s 0 "";
let _uc1 = fn c -> let o = ord c in if o >= 97 && o <= 122 then chr (o - 32) else c;
let rec _uc = fn s -> fn i -> fn acc -> if i >= str_len s then acc else _uc s (i + 1) (acc ++ _uc1 (char_at s i));
let to_upper = fn s -> _uc s 0 "";

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

let rec _ssplit = fn s -> fn d -> fn start ->
  let rest = substring s start (str_len s) in
  let idx = str_index_of rest d in
  if idx < 0 then Cons (rest, Nil)
  else Cons (substring rest 0 idx, _ssplit s d (start + idx + str_len d));
let str_split = fn s -> fn d -> if str_len d == 0 then Cons (s, Nil) else _ssplit s d 0;

let rec _srep2 = fn s -> fn old -> fn nw -> fn acc ->
  let idx = str_index_of s old in
  if idx < 0 then acc ++ s
  else _srep2 (substring s (idx + str_len old) (str_len s)) old nw (acc ++ substring s 0 idx ++ nw);
let str_replace = fn s -> fn old -> fn nw -> if str_len old == 0 then s else _srep2 s old nw "";

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
// map_iter: visit each distinct key's (most recent) value. Dedup via a seen list.
let rec _mseen = fn seen -> fn k -> match seen with Nil -> false | Cons (x, rest) -> if str_eq x k then true else _mseen rest k;
let rec _miter = fn node -> fn f -> fn seen ->
  match node with
  | Nil -> ()
  | Cons ((kk, vv), rest) ->
    if _mseen seen kk then _miter rest f seen
    else let _ = f kk vv in _miter rest f (Cons (kk, seen));
let rvmap_iter = fn m -> fn f -> _miter (vec_get m 0) f Nil;
// The number of DISTINCT keys. `rvmap_set` prepends, so a key set twice is in
// the list twice and the newer one shadows the older; counting nodes would count
// the shadowed ones. This is the same walk `_miter` does, with a counter instead
// of a callback.
// The reclamation API, for a map that has no arena. `map_compact` and
// `map_recycle` exist to return bytes an arena is holding after entries were
// overwritten or deleted; this representation is an assoc list of ordinary
// values, so there is nothing behind it to return and a no-op is the honest
// answer, not a stub. `map_clear` does have work to do.
//
// `map_bytes` is different: it asks HOW MANY bytes the arena holds, and
// answering 0 would read as "this map uses no memory" rather than "the question
// does not apply here". So it stops and says which it is.
let rvmap_clear = fn m -> vec_set m 0 Nil;
let rvmap_compact = fn m -> ();
let rvmap_recycle = fn m -> ();
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
let __fadd = fn (a: float) -> fn (b: float) ->
  __sf_float_of_sf (__sf_add (__sf_sf_of_float a) (__sf_sf_of_float b));
let __fsub = fn (a: float) -> fn (b: float) ->
  __sf_float_of_sf (__sf_sub (__sf_sf_of_float a) (__sf_sf_of_float b));
let __fmul = fn (a: float) -> fn (b: float) ->
  __sf_float_of_sf (__sf_mul (__sf_sf_of_float a) (__sf_sf_of_float b));
let __fdiv = fn (a: float) -> fn (b: float) ->
  __sf_float_of_sf (__sf_fdiv (__sf_sf_of_float a) (__sf_sf_of_float b));
// Negation is a sign-bit flip and is defined on NaN too, which is why it goes
// through the library rather than through `0.0 - x`: that is a different
// operation on -0.0 and on NaN.
let __fneg = fn (a: float) -> __sf_float_of_sf (__sf_neg (__sf_sf_of_float a));
// `eq` and `lt` are not bit comparisons: -0.0 equals +0.0, and a NaN equals
// nothing, itself included. Neither falls out of comparing the fields, and
// neither falls out of comparing the two halves as ints.
let __feq = fn (a: float) -> fn (b: float) ->
  __sf_eq (__sf_sf_of_float a) (__sf_sf_of_float b);
let __fne = fn (a: float) -> fn (b: float) -> not (__feq a b);
let __flt = fn (a: float) -> fn (b: float) ->
  __sf_lt (__sf_sf_of_float a) (__sf_sf_of_float b);
let __fle = fn (a: float) -> fn (b: float) ->
  __sf_le (__sf_sf_of_float a) (__sf_sf_of_float b);
let __fgt = fn (a: float) -> fn (b: float) ->
  __sf_gt (__sf_sf_of_float a) (__sf_sf_of_float b);
let __fge = fn (a: float) -> fn (b: float) ->
  __sf_ge (__sf_sf_of_float a) (__sf_sf_of_float b);

// The named forms of the same operations. They are the operators' spelling for
// code that passes them around, so they share the implementation rather than
// getting a second one that could disagree with `+`.
let f_add = fn (a: float) -> fn (b: float) -> __fadd a b;
let f_sub = fn (a: float) -> fn (b: float) -> __fsub a b;
let f_mul = fn (a: float) -> fn (b: float) -> __fmul a b;
let f_div = fn (a: float) -> fn (b: float) -> __fdiv a b;
let f_neg = fn (a: float) -> __fneg a;
let f_abs = fn (a: float) -> __sf_float_of_sf (__sf_abs (__sf_sf_of_float a));
let f_lt = fn (a: float) -> fn (b: float) -> __flt a b;
let f_le = fn (a: float) -> fn (b: float) -> __fle a b;
let f_gt = fn (a: float) -> fn (b: float) -> __fgt a b;
let f_ge = fn (a: float) -> fn (b: float) -> __fge a b;
let float_of_int = fn (n: int) -> __sf_float_of_sf (__sf_of_int n);
let int_of_float = fn (x: float) -> __sf_to_int (__sf_sf_of_float x);
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
