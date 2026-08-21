(* Phase 19.4/19.5 + 21.2 + 23.2: the auto-imported prelude.
   At the start of every Mere program's parse, the decls here are
   inserted at the **front** of the user's source.

   Design:
   - **Type declarations**: the three `type 'a list` / `'a option` / `('a, 'e) result`.
   - **list helpers** (Phase 21.2): list_iter / list_map / list_fold
     / list_len / list_rev.
   - **option helpers** (Phase 23.2): option_map / option_default /
     option_is_some.
   - **result helpers** (Phase 23.2): result_map / result_and_then /
     result_or_else / result_default / result_is_ok.
   - Built on top of the partial codegen resolution for polymorphic
     let-rec (Phase 21.1 §1.7 fix), which made **single-instantiation**
     codegen work, and resolve_fn_types now **skips unused poly fns**
     (Phase 21.2); helpers are excluded from codegen when the user
     program does not use them.
   - Multi-instantiation (calling the same helper at two or more
     concrete types) is turned into a codegen error in Phase 23.1
     (safer than a silent miscompile).
   - Users redeclaring the same type does not break things (the typer
     overrides with `Hashtbl.replace`, and ctors behave the same way). *)

let contents = {|
type 'a list = Nil | Cons of 'a * 'a list;
type 'a option = None | Some of 'a;
type ('a, 'e) result = Ok of 'a | Err of 'e;
// The protocol of `region R loop x { ... }`: Continue carries the loop's
// state into the next arena (deep-copied); Done leaves the loop with a value.
type ('c, 'd) region_flow = Continue of 'c | Done of 'd;

let rec list_iter = fn xs -> fn f ->
  match xs with
  | Nil -> ()
  | Cons (h, t) -> let __ = f h in list_iter t f;

let rec list_rev_into = fn acc -> fn xs ->
  match xs with
  | Nil -> acc
  | Cons (h, t) -> list_rev_into (Cons (h, acc)) t;

// 'let rec' (not 'let') so the test-side helper codegen_with_decls —
// which processes Top_let but skips Top_let_rec — doesn't try to infer
// this binding's body under an env that lacks list_rev_into.
let rec list_rev = fn xs -> list_rev_into Nil xs;

// v0.1.39: accumulator + reverse — the naive Cons (f h, recurse) shape
// overflows the stack near a million elements (found by the scale probe).
let rec _lmap_into = fn xs -> fn f -> fn acc ->
  match xs with
  | Nil -> acc
  | Cons (h, t) -> _lmap_into t f (Cons (f h, acc));
let rec list_map = fn xs -> fn f -> list_rev_into Nil (_lmap_into xs f Nil);

let rec list_fold = fn xs -> fn acc -> fn f ->
  match xs with
  | Nil -> acc
  | Cons (h, t) -> list_fold t (f acc h) f;

let rec _llen = fn xs -> fn (acc: int) ->
  match xs with
  | Nil -> acc
  | Cons (_, t) -> _llen t (acc + 1);
let rec list_len = fn xs -> _llen xs 0;



// Phase 36: range literal `a..b` desugars to `range a b`.
// Inclusive lower / inclusive upper: `range 1 5` = [1, 2, 3, 4, 5].
// b < a -> empty list. Use `list_rev (range b a)` for the reverse direction.
let rec _range_down = fn (a: int) -> fn (i: int) -> fn acc ->
  if i < a then acc else _range_down a (i - 1) (Cons (i, acc));
let rec range = fn (a: int) -> fn (b: int) -> _range_down a b Nil;

// Phase 36: narrow a list by a predicate (symmetric with list_map / list_iter)
// v0.1.268: accumulate and reverse, like list_map -- the recursive form
// (`Cons (h, list_filter t p)`) recurses to the LENGTH of the list, so a
// filter over 100,000 elements overflowed the stack on the C backend while
// the map beside it, written with an accumulator, did not. Every other list
// helper here was already in this shape; this was the one that was not.
let rec _lfilter_into = fn xs -> fn p -> fn acc ->
  match xs with
  | Nil -> acc
  | Cons (h, t) -> _lfilter_into t p (if p h then Cons (h, acc) else acc);
let rec list_filter = fn xs -> fn p -> list_rev_into Nil (_lfilter_into xs p Nil);

// Phase 36: take the first n elements (returns all if n exceeds len)
let rec _ltake_into = fn xs -> fn (n: int) -> fn acc ->
  if n <= 0 then acc
  else
    match xs with
    | Nil -> acc
    | Cons (h, t) -> _ltake_into t (n - 1) (Cons (h, acc));
let rec list_take = fn xs -> fn n -> list_rev_into Nil (_ltake_into xs n Nil);

// Phase 36: drop the first n elements
let rec list_drop = fn xs -> fn n ->
  if n <= 0 then xs
  else
    match xs with
    | Nil -> Nil
    | Cons (_, t) -> list_drop t (n - 1);

// Phase 36: return the first element matching the predicate as Some, or None if none match
let rec list_find = fn xs -> fn p ->
  match xs with
  | Nil -> None
  | Cons (h, t) -> if p h then Some h else list_find t p;

// Phase 36: list concatenation (a ++ b). Since Mere's `++` is str-only, this is a separate function.
let rec list_append = fn xs -> fn ys ->
  list_rev_into ys (list_rev_into Nil xs);

// Phase 36: flatten 'a list list into 'a list
let rec _lconcat_into = fn xss -> fn acc ->
  match xss with
  | Nil -> acc
  | Cons (h, t) -> _lconcat_into t (list_rev_into acc h);
let rec list_concat = fn xss -> list_rev_into Nil (_lconcat_into xss Nil);

// Phase 36: flatten the result of list_map (the desugar target for multi-gen comprehensions)
let rec _lfm_into = fn xs -> fn f -> fn acc ->
  match xs with
  | Nil -> acc
  | Cons (h, t) -> _lfm_into t f (list_rev_into acc (f h));
let rec list_flat_map = fn xs -> fn f -> list_rev_into Nil (_lfm_into xs f Nil);

// Phase 36: zip two lists into tuples. When the lengths differ, align with the shorter one.
let rec _lzip_into = fn xs -> fn ys -> fn acc ->
  match xs with
  | Nil -> acc
  | Cons (a, ta) ->
    (match ys with
     | Nil -> acc
     | Cons (b, tb) -> _lzip_into ta tb (Cons ((a, b), acc)));
let rec list_zip = fn xs -> fn ys -> list_rev_into Nil (_lzip_into xs ys Nil);

// Phase 36: whether all elements satisfy the predicate
let rec list_for_all = fn xs -> fn p ->
  match xs with
  | Nil -> true
  | Cons (h, t) -> if p h then list_for_all t p else false;

// Phase 36: whether at least one element satisfies the predicate
let rec list_any = fn xs -> fn p ->
  match xs with
  | Nil -> false
  | Cons (h, t) -> if p h then true else list_any t p;

// Phase 36: whether an equal element is contained (compared with ==)
let rec list_member = fn xs -> fn v ->
  match xs with
  | Nil -> false
  | Cons (h, t) -> if h == v then true else list_member t v;

// Phase 36: sum / product of an int list. The reason for using `let rec`
// is that the test codegen_with_decls helper skips Top_let_rec while
// processing Top_let, so this preserves an order where the list_fold
// reference (already defined with let rec) can be resolved.
let rec list_sum = fn xs -> list_fold xs 0 (fn a -> fn x -> a + x);
let rec list_product = fn xs -> list_fold xs 1 (fn a -> fn x -> a * x);

// Phase 36: max / min (fail on empty list)
let rec _lmax_from = fn xs -> fn m ->
  match xs with
  | Nil -> m
  | Cons (h, t) -> _lmax_from t (if h > m then h else m);
let rec list_max = fn xs ->
  match xs with
  | Nil -> fail "list_max: empty list"
  | Cons (h, t) -> _lmax_from t h;

let rec _lmin_from = fn xs -> fn m ->
  match xs with
  | Nil -> m
  | Cons (h, t) -> _lmin_from t (if h < m then h else m);
let rec list_min = fn xs ->
  match xs with
  | Nil -> fail "list_min: empty list"
  | Cons (h, t) -> _lmin_from t h;

// Phase 39.A' #4: insertion sort with a comparator. cmp is a total-order
// predicate returning true if "a should come before b". Stable (order is
// preserved when cmp is false).
//
//   list_sort_by (fn a b -> a < b) [3, 1, 2] = [1, 2, 3]
//   list_sort_by (fn a b -> a > b) [3, 1, 2] = [3, 2, 1]
//
// Removes the chore of writing a hand-rolled insertion sort each time in
// task_scheduler.mere and the like.
// v0.1.270: accumulate the prefix and reverse it onto the rest, rather than
// rebuilding it through the return path. The recursive form
// (`Cons (h, list_sort_insert cmp t x)`) recurses once per element it walks
// past, so inserting into a 50,000-long sorted list overflowed the stack on
// the compiled backends -- the same shape list_filter had, in the one helper
// the merge sort left behind.
let rec _lsi_into = fn cmp -> fn xs -> fn x -> fn acc ->
  match xs with
  | Nil -> list_rev_into (Cons (x, Nil)) acc
  | Cons (h, t) ->
    if cmp x h then list_rev_into (Cons (x, xs)) acc
    else _lsi_into cmp t x (Cons (h, acc));
let rec list_sort_insert = fn cmp -> fn xs -> fn x -> _lsi_into cmp xs x Nil;

// v0.1.39: merge sort — stable, O(n log n), stack-safe (the merge is
// tail-recursive via a reversed accumulator; the recursion depth of the
// sort itself is log n). The insertion sort above turned out to be the
// bottleneck at scale: 20k elements took ~2 s natively. list_sort_insert
// stays for direct users.
let rec _ms_rev = fn xs -> fn acc ->
  match xs with
  | Nil -> acc
  | Cons (h, t) -> _ms_rev t (Cons (h, acc));
// (returns the reversed prefix only — a tuple-returning splitter compiles
// to an sret struct return in C, which defeats clang's sibling-call
// optimization and overflowed the stack at ~200k elements. The suffix
// comes from the existing tail-recursive list_drop.)
let rec _ms_take_rev = fn (i: int) -> fn xs -> fn acc ->
  if i == 0 then acc
  else
    match xs with
    | Nil -> acc
    | Cons (h, t) -> _ms_take_rev (i - 1) t (Cons (h, acc));
// Merges a and b, producing the result REVERSED onto acc. On ties the
// element from `a` (the earlier half) goes first — stability.
let rec _ms_merge_rev = fn cmp -> fn a -> fn b -> fn acc ->
  match a with
  | Nil -> _ms_rev b acc
  | Cons (ha, ta) ->
    (match b with
     | Nil -> _ms_rev a acc
     | Cons (hb, tb) ->
       if cmp hb ha then _ms_merge_rev cmp a tb (Cons (hb, acc))
       else _ms_merge_rev cmp ta b (Cons (ha, acc)));
let rec _ms_sort = fn cmp -> fn xs -> fn (len: int) ->
  if len <= 1 then xs
  else
    let half = len / 2 in
    let revpre = _ms_take_rev half xs Nil in
    let suf = list_drop xs half in
    let sa = _ms_sort cmp (_ms_rev revpre Nil) half in
    let sb = _ms_sort cmp suf (len - half) in
    _ms_rev (_ms_merge_rev cmp sa sb Nil) Nil;
let rec list_sort_by = fn cmp -> fn xs -> _ms_sort cmp xs (list_len xs);

// shorthand: natural-order sort for int / str / float.
// The reason for using `let rec` is that test/test_basic.ml's
// codegen_with_decls helper skips Top_let_rec, so if list_sort (let)
// referenced list_sort_by (let rec) it would be unbound in the test
// environment. We unify the whole prelude to let rec.
let rec list_sort = fn xs -> list_sort_by (fn a -> fn b -> a < b) xs;

// === Option helpers ===

let rec option_map = fn opt -> fn f ->
  match opt with
  | None -> None
  | Some v -> Some (f v);

let rec option_default = fn opt -> fn d ->
  match opt with
  | None -> d
  | Some v -> v;

let rec option_is_some = fn opt ->
  match opt with
  | None -> false
  | Some _ -> true;

// Phase 33.1: monadic bind / flat_map. Propagates None through an Option chain.
let rec option_and_then = fn opt -> fn f ->
  match opt with
  | None -> None
  | Some v -> f v;

// === Result helpers ===

let rec result_map = fn r -> fn f ->
  match r with
  | Err e -> Err e
  | Ok v -> Ok (f v);

let rec result_and_then = fn r -> fn f ->
  match r with
  | Err e -> Err e
  | Ok v -> f v;

let rec result_or_else = fn r -> fn f ->
  match r with
  | Ok v -> Ok v
  | Err e -> f e;

let rec result_default = fn r -> fn d ->
  match r with
  | Err _ -> d
  | Ok v -> v;

let rec result_is_ok = fn r ->
  match r with
  | Err _ -> false
  | Ok _ -> true;

// v0.1.38 (Unicode): the codepoint view of a byte string, composed from
// the utf8_chars builtin. str_len / substring / char_at stay byte-indexed
// (documented); use these for text.
let rec _u8_nth = fn cs -> fn (i: int) ->
  match cs with
  | Nil -> ""
  | Cons (h, t) -> if i == 0 then h else _u8_nth t (i - 1);
let rec utf8_at = fn (s: str) -> fn (i: int) -> _u8_nth (utf8_chars s) i;

// Q-014's deferred sliver: the codepoint integer <-> str pair. Written here
// rather than as builtins because the codepoint layer above `str` has been
// prelude-composed since v0.1.38/45 (utf8_at, utf8_sub, utf8_width), and a
// definition in Mere is the same on all four backends by construction — no
// chance of the divergence `chr` still carries, where out-of-range raises on
// the interpreter and masks on wasm and llvm.
//
// `chr` / `ord` stay byte-shaped: the redis, pg and http drivers build 0..255
// bytes with them. These are separate names, not a widening of those.
//
// A Unicode scalar value is 0..0x10FFFF less the surrogate range. A caller who
// wants U+FFFD for a bad value says so; this fails.
let _cp_bad = fn (n: int) -> n < 0 || n > 1114111 || (n >= 55296 && n <= 57343);

let str_of_codepoint = fn (n: int) ->
  if _cp_bad n then fail "str_of_codepoint: not a Unicode scalar value"
  else if n < 128 then chr n
  else if n < 2048 then
    chr (bit_or 192 (bit_shr n 6)) ++ chr (bit_or 128 (bit_and n 63))
  else if n < 65536 then
    chr (bit_or 224 (bit_shr n 12))
    ++ chr (bit_or 128 (bit_and (bit_shr n 6) 63))
    ++ chr (bit_or 128 (bit_and n 63))
  else
    chr (bit_or 240 (bit_shr n 18))
    ++ chr (bit_or 128 (bit_and (bit_shr n 12) 63))
    ++ chr (bit_or 128 (bit_and (bit_shr n 6) 63))
    ++ chr (bit_or 128 (bit_and n 63));

// The span the leading byte claims. 1 for a continuation or an invalid lead,
// which then fails the length check below rather than reading past the end.
let _cp_span = fn (b: int) ->
  if b < 128 then 1
  else if b >= 192 && b <= 223 then 2
  else if b >= 224 && b <= 239 then 3
  else if b >= 240 && b <= 247 then 4
  else 1;

let _cp_cont = fn (s: str) -> fn (i: int) -> bit_and (ord (char_at s i)) 63;

// The exact inverse of str_of_codepoint: the str must hold one codepoint and
// nothing else, so a truncated or overlong encoding is an error rather than a
// value. Rejecting overlongs matters for anything security-relevant — two
// spellings of the same character is how filters get walked past.
let codepoint_of = fn (s: str) ->
  let n = str_len s in
  if n == 0 then fail "codepoint_of: expected a single-codepoint str"
  else
    let b0 = ord (char_at s 0) in
    let span = _cp_span b0 in
    if span != n then fail "codepoint_of: expected a single-codepoint str"
    else
      let cp =
        if span == 1 then b0
        else if span == 2 then bit_or (bit_shl (bit_and b0 31) 6) (_cp_cont s 1)
        else if span == 3 then
          bit_or (bit_or (bit_shl (bit_and b0 15) 12) (bit_shl (_cp_cont s 1) 6))
                 (_cp_cont s 2)
        else
          bit_or (bit_or (bit_shl (bit_and b0 7) 18) (bit_shl (_cp_cont s 1) 12))
                 (bit_or (bit_shl (_cp_cont s 2) 6) (_cp_cont s 3)) in
      let shortest =
        if span == 1 then cp < 128
        else if span == 2 then cp >= 128
        else if span == 3 then cp >= 2048
        else cp >= 65536 in
      if _cp_bad cp || not shortest then
        fail "codepoint_of: expected a single-codepoint str"
      else cp;

// `let rec` like its neighbours, not for the recursion but because the decl
// loops that tests keep miniature copies of bind Top_let_rec and Top_let
// separately, and a plain `let` here that reaches back to `let rec utf8_at`
// is unbound in those copies (note: the same duplication that made the
// quadratic-inference fix land in six places).
let rec codepoint_at = fn (s: str) -> fn (i: int) -> codepoint_of (utf8_at s i);
let rec _u8_slice = fn cs -> fn (start: int) -> fn (len: int) -> fn (acc: str) ->
  match cs with
  | Nil -> acc
  | Cons (h, t) ->
    if start > 0 then _u8_slice t (start - 1) len acc
    else if len > 0 then _u8_slice t 0 (len - 1) (acc ++ h)
    else acc;
let rec utf8_sub = fn (s: str) -> fn (start: int) -> fn (len: int) ->
  _u8_slice (utf8_chars s) start len "";
let rec _u8_rev_join = fn cs -> fn (acc: str) ->
  match cs with
  | Nil -> acc
  | Cons (h, t) -> _u8_rev_join t (h ++ acc);
let rec utf8_rev = fn (s: str) -> _u8_rev_join (utf8_chars s) "";

// v0.1.45 (aligned-table probe): DISPLAY width, not codepoint count.
// Terminals draw CJK / fullwidth / emoji at 2 columns and combining
// marks at 0 — utf8_len says 5 for a greeting the terminal draws in 10.
// East Asian Width, wcwidth-lite: the major W/F ranges (decimal, since
// the lexer has no hex literals). Ambiguous-width characters count 1.
let rec _eaw_width = fn (cp: int) ->
  if cp >= 768 && cp <= 879 then 0            // combining marks (0300-036F)
  else if cp == 12351 then 1                  // 303F, the hole in 2E80-A4CF
  else if (cp >= 4352 && cp <= 4447)          // 1100-115F  Hangul Jamo
       || (cp >= 11904 && cp <= 42191)        // 2E80-A4CF  CJK radicals..Yi
       || (cp >= 43360 && cp <= 43391)        // A960-A97F  Jamo ext-A
       || (cp >= 44032 && cp <= 55203)        // AC00-D7A3  Hangul syllables
       || (cp >= 63744 && cp <= 64255)        // F900-FAFF  CJK compat
       || (cp >= 65040 && cp <= 65049)        // FE10-FE19  vertical forms
       || (cp >= 65072 && cp <= 65135)        // FE30-FE6F  compat forms
       || (cp >= 65280 && cp <= 65376)        // FF00-FF60  fullwidth forms
       || (cp >= 65504 && cp <= 65510)        // FFE0-FFE6  fullwidth signs
       || (cp >= 127744 && cp <= 128767)      // 1F300-1F6FF emoji blocks
       || (cp >= 129280 && cp <= 129535)      // 1F900-1F9FF emoji supplement
       || (cp >= 131072 && cp <= 262141)      // 20000-3FFFD CJK ext B..
  then 2 else 1;
// UTF-8 decode by arithmetic (2-byte: cp = b0%32*64 + b1%64, etc.);
// truncated / stray sequences count as width 1 per byte.
let rec _u8w_go = fn (s: str) -> fn (i: int) -> fn (n: int) -> fn (acc: int) ->
  if i >= n then acc
  else
    let b0 = ord (char_at s i) in
    if b0 < 194 then _u8w_go s (i + 1) n (acc + 1)
    else if b0 < 224 then
      (if i + 1 < n then
         _u8w_go s (i + 2) n
           (acc + _eaw_width ((b0 % 32) * 64 + (ord (char_at s (i + 1)) % 64)))
       else acc + 1)
    else if b0 < 240 then
      (if i + 2 < n then
         _u8w_go s (i + 3) n
           (acc + _eaw_width ((b0 % 16) * 4096
                              + (ord (char_at s (i + 1)) % 64) * 64
                              + (ord (char_at s (i + 2)) % 64)))
       else acc + 1)
    else
      (if i + 3 < n then
         _u8w_go s (i + 4) n
           (acc + _eaw_width ((b0 % 8) * 262144
                              + (ord (char_at s (i + 1)) % 64) * 4096
                              + (ord (char_at s (i + 2)) % 64) * 64
                              + (ord (char_at s (i + 3)) % 64)))
       else acc + 1);
let rec utf8_width = fn (s: str) -> _u8w_go s 0 (str_len s) 0;
// column padding on display width — the aligned-table primitives.
let rec pad_right = fn (s: str) -> fn (w: int) ->
  let d = w - utf8_width s in
  if d <= 0 then s else s ++ str_repeat " " d;
let rec pad_left = fn (s: str) -> fn (w: int) ->
  let d = w - utf8_width s in
  if d <= 0 then s else str_repeat " " d ++ s;

// --- small integer helpers -------------------------------------------------
// These were interpreter builtins with no lowering on any compiled backend:
// `mere -c` emitted a reference to a name the C compiler had never heard of, so
// they worked in the REPL and failed at link time, and no test used them.
// Defining them here as Mere source gives all five backends the same one, which
// is cheaper than five codegen cases and cannot drift between them.
//
// Each reproduces exactly what the interpreter builtin did, including the two
// failures: `pow` with a negative exponent and a false `assert` both raise the
// message they always raised. "Exactly" had to be checked rather than assumed —
// the obvious Mere one-liner was the wrong function four times out of ten:
// `sum_range` and `pow` recursed where the builtin was closed-form and O(log e),
// which is a stack overflow rather than a slow answer; `lcm` multiplied before
// dividing, which overflows for operands whose lcm fits but whose product does
// not; and `divmod` left its documented zero failure to `/`, which does not mean
// the same thing on every backend.
//
// `int_max` and `int_min` are deliberately NOT here. They cannot be a portable
// literal: the interpreter's int is OCaml's 63-bit native int and the C backend's
// is a 64-bit long long, so `4611686018427387903 + 1` is negative on one and
// positive on the other. That is a language question, not a missing definition.
let sign = fn (n: int) -> if n > 0 then 1 else if n < 0 then 0 - 1 else 0;
let incr = fn (n: int) -> n + 1;
let decr = fn (n: int) -> n - 1;
let square = fn (n: int) -> n * n;
let cube = fn (n: int) -> n * n * n;
// Gauss, with the halving moved inside the product. `(b - a + 1) * (a + b) / 2`
// forms an intermediate twice the size of its own answer, which made the range
// where this is portable half the range of the result: summing -3037000493..0 has
// an answer both int widths hold and an intermediate only the 64-bit one does, so
// the interpreter and the compiled backends disagreed. Exactly one of the two
// factors is even — an odd count means the endpoints share parity — so one of them
// can always be halved first.
let sum_range = fn (a: int) -> fn (b: int) ->
  if a > b then 0
  else
    let n = b - a + 1 in
    if n % 2 == 0 then n / 2 * (a + b) else n * ((a + b) / 2);
// Square-and-multiply, the builtin's algorithm rather than one that agrees with
// it on small inputs: the squaring order is what fixes the wraparound on an
// overflowing exponent, so a linear version would be a different function past
// the int width as well as O(e) deep.
// The accumulator is a top-level `_` helper rather than an inner `let rec`, which
// is what the rest of this file does and now has a demonstrated reason: an inner
// fn in the prelude takes `__lifted_helper_0` away from the first inner fn in the
// user's program, and seven codegen tests assert generated names by index.
let rec _pow_go = fn (acc: int) -> fn (sq: int) -> fn (n: int) ->
  if n == 0 then acc
  else if n % 2 == 1 then _pow_go (acc * sq) (sq * sq) (n / 2)
  else _pow_go acc (sq * sq) (n / 2);
let pow = fn (b: int) -> fn (e: int) ->
  if e < 0 then fail ("pow: negative exponent " ++ show e) else _pow_go 1 b e;
// Via gcd, which already had lowerings. Zero is absorbing rather than a division
// by zero, and the division comes before the multiplication.
let lcm = fn (a: int) -> fn (b: int) ->
  if a == 0 || b == 0 then 0 else abs (a / gcd a b * b);
// Truncated division, matching `/` and `%`: divmod (0 - 17) 5 is (-3, -2). The
// zero check is written out rather than left to `/`, which is still worth it for
// the message: bare `/` raises `division by zero` and this names the caller. When
// this was written `/` by zero was not one thing across the backends at all — the
// interpreter raised, the compiled ones had undefined behaviour or a silent trap.
// That is fixed (v0.1.247), and the check stays because a named failure is better
// than an unnamed one.
let divmod = fn (a: int) -> fn (b: int) ->
  if b == 0 then fail "divmod: division by zero" else (a / b, a % b);
let assert = fn (cond: bool) -> fn (msg: str) ->
  if cond then () else fail ("assertion failed: " ++ msg);
|}
