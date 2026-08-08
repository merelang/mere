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
|mere}
