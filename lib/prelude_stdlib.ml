(* Phase 19.4/19.5 + 21.2: 自動 import される prelude。
   全 Mere プログラムの parse 開始時に、ここの decls が
   ユーザのソースの **先頭** に挿入される。

   方針:
   - **型宣言**: `type 'a list` / `'a option` / `('a, 'e) result` の 3 つ。
   - **list helpers** (Phase 21.2 で追加): list_iter / list_map / list_fold
     / list_len / list_rev。多相 let-rec の codegen 部分解決 (Phase 21.1
     §1.7 fix) で **単一 instantiation** の codegen が動くようになったの
     と、resolve_fn_types で **unused poly fn を skip** するようにした
     (Phase 21.2) ことを前提に、ユーザの program が helpers を使わない
     場合は codegen から除外される設計。
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
|}
