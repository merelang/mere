(* Phase 19.4/19.5 + 21.2 + 23.2: 自動 import される prelude。
   全 Mere プログラムの parse 開始時に、ここの decls が
   ユーザのソースの **先頭** に挿入される。

   方針:
   - **型宣言**: `type 'a list` / `'a option` / `('a, 'e) result` の 3 つ。
   - **list helpers** (Phase 21.2): list_iter / list_map / list_fold
     / list_len / list_rev。
   - **option helpers** (Phase 23.2): option_map / option_default /
     option_is_some。
   - **result helpers** (Phase 23.2): result_map / result_and_then /
     result_or_else / result_default / result_is_ok。
   - 多相 let-rec の codegen 部分解決 (Phase 21.1 §1.7 fix) で **単一
     instantiation** の codegen が動くようになったのと、resolve_fn_types
     で **unused poly fn を skip** するようにした (Phase 21.2) ことを
     前提に、ユーザの program が helpers を使わない場合は codegen から
     除外される設計。
   - 多 instantiation (同じ helper を 2 つ以上の concrete 型で呼ぶ) は
     Phase 23.1 で codegen error 化される (silent miscompile より安全)。
   - ユーザが同じ型を再宣言しても破綻しないように (typer は
     `Hashtbl.replace` で上書き、ctor も同様)。 *)

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
// b < a → 空 list。逆向きが必要なら `list_rev (range b a)`。
let rec range = fn (a: int) -> fn (b: int) ->
  if a > b then Nil
  else Cons (a, range (a + 1) b);

// Phase 36: 述語で list を絞り込み (list_map / list_iter と対称)
let rec list_filter = fn xs -> fn p ->
  match xs with
  | Nil -> Nil
  | Cons (h, t) ->
    if p h then Cons (h, list_filter t p)
    else list_filter t p;

// Phase 36: 最初の n 要素を取る (n が len 超なら全部)
let rec list_take = fn xs -> fn n ->
  if n <= 0 then Nil
  else
    match xs with
    | Nil -> Nil
    | Cons (h, t) -> Cons (h, list_take t (n - 1));

// Phase 36: 最初の n 要素を捨てる
let rec list_drop = fn xs -> fn n ->
  if n <= 0 then xs
  else
    match xs with
    | Nil -> Nil
    | Cons (_, t) -> list_drop t (n - 1);

// Phase 36: 述語に最初に一致する要素を Some で返す、無ければ None
let rec list_find = fn xs -> fn p ->
  match xs with
  | Nil -> None
  | Cons (h, t) -> if p h then Some h else list_find t p;

// Phase 36: list 連結 (a ++ b)。Mere の `++` は str only なので別関数。
let rec list_append = fn xs -> fn ys ->
  match xs with
  | Nil -> ys
  | Cons (h, t) -> Cons (h, list_append t ys);

// Phase 36: 'a list list を flatten して 'a list に
let rec list_concat = fn xss ->
  match xss with
  | Nil -> Nil
  | Cons (h, t) -> list_append h (list_concat t);

// Phase 36: list_map した結果を flatten (multi-gen comprehension の desugar 対象)
let rec list_flat_map = fn xs -> fn f ->
  match xs with
  | Nil -> Nil
  | Cons (h, t) -> list_append (f h) (list_flat_map t f);

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

// Phase 33.1: monadic bind / flat_map。Option chain で None を伝搬。
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
|}
