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

let rec list_iter = fn xs -> fn f ->
  match xs with
  | Nil -> ()
  | Cons (h, t) -> let __ = f h in list_iter t f;

let rec list_map = fn xs -> fn f ->
  match xs with
  | Nil -> Nil
  | Cons (h, t) -> Cons (f h, list_map t f);

let rec list_fold = fn xs -> fn acc -> fn f ->
  match xs with
  | Nil -> acc
  | Cons (h, t) -> list_fold t (f acc h) f;

let rec list_len = fn xs ->
  match xs with
  | Nil -> 0
  | Cons (_, t) -> 1 + list_len t;

let rec list_rev_into = fn acc -> fn xs ->
  match xs with
  | Nil -> acc
  | Cons (h, t) -> list_rev_into (Cons (h, acc)) t;

// 'let rec' (not 'let') so the test-side helper codegen_with_decls —
// which processes Top_let but skips Top_let_rec — doesn't try to infer
// this binding's body under an env that lacks list_rev_into.
let rec list_rev = fn xs -> list_rev_into Nil xs;

// Phase 36: range literal `a..b` desugars to `range a b`.
// Inclusive lower / inclusive upper: `range 1 5` = [1, 2, 3, 4, 5].
// b < a -> empty list. Use `list_rev (range b a)` for the reverse direction.
let rec range = fn (a: int) -> fn (b: int) ->
  if a > b then Nil
  else Cons (a, range (a + 1) b);

// Phase 36: narrow a list by a predicate (symmetric with list_map / list_iter)
let rec list_filter = fn xs -> fn p ->
  match xs with
  | Nil -> Nil
  | Cons (h, t) ->
    if p h then Cons (h, list_filter t p)
    else list_filter t p;

// Phase 36: take the first n elements (returns all if n exceeds len)
let rec list_take = fn xs -> fn n ->
  if n <= 0 then Nil
  else
    match xs with
    | Nil -> Nil
    | Cons (h, t) -> Cons (h, list_take t (n - 1));

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
  match xs with
  | Nil -> ys
  | Cons (h, t) -> Cons (h, list_append t ys);

// Phase 36: flatten 'a list list into 'a list
let rec list_concat = fn xss ->
  match xss with
  | Nil -> Nil
  | Cons (h, t) -> list_append h (list_concat t);

// Phase 36: flatten the result of list_map (the desugar target for multi-gen comprehensions)
let rec list_flat_map = fn xs -> fn f ->
  match xs with
  | Nil -> Nil
  | Cons (h, t) -> list_append (f h) (list_flat_map t f);

// Phase 36: zip two lists into tuples. When the lengths differ, align with the shorter one.
let rec list_zip = fn xs -> fn ys ->
  match xs with
  | Nil -> Nil
  | Cons (a, ta) ->
    match ys with
    | Nil -> Nil
    | Cons (b, tb) -> Cons ((a, b), list_zip ta tb);

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
let rec list_max = fn xs ->
  match xs with
  | Nil -> fail "list_max: empty list"
  | Cons (h, t) ->
    match t with
    | Nil -> h
    | Cons _ ->
      let m = list_max t in
      if h > m then h else m;

let rec list_min = fn xs ->
  match xs with
  | Nil -> fail "list_min: empty list"
  | Cons (h, t) ->
    match t with
    | Nil -> h
    | Cons _ ->
      let m = list_min t in
      if h < m then h else m;

// Phase 39.A' #4: insertion sort with a comparator. cmp is a total-order
// predicate returning true if "a should come before b". Stable (order is
// preserved when cmp is false).
//
//   list_sort_by (fn a b -> a < b) [3, 1, 2] = [1, 2, 3]
//   list_sort_by (fn a b -> a > b) [3, 1, 2] = [3, 2, 1]
//
// Removes the chore of writing a hand-rolled insertion sort each time in
// task_scheduler.mere and the like.
let rec list_sort_insert = fn cmp -> fn xs -> fn x ->
  match xs with
  | Nil -> Cons (x, Nil)
  | Cons (h, t) ->
    if cmp x h then Cons (x, xs)
    else Cons (h, list_sort_insert cmp t x);

let rec list_sort_by = fn cmp -> fn xs ->
  match xs with
  | Nil -> Nil
  | Cons (h, t) -> list_sort_insert cmp (list_sort_by cmp t) h;

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
|}
