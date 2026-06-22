# Patterns / cookbook (mere)

実際に Mere でプログラムを書く時に頻出するイディオム集。

---

## 1. ガード付き defensive プログラミング

```
let safe_div = fn (a: int, b: int) ->
  if b == 0 then fail "div by zero"
  else a / b;
```

`fail` は多相 (`str -> 'a`) なので分岐合流で正しく統合される。`assert (cond) "msg"` も同様の用途。

---

## 2. Result 型でエラーを値として扱う

```
type ('a, 'b) result = Ok of 'a | Err of 'b;

let parse_age = fn (s: str) ->
  let n = try_or (fn () -> int_of_str s) (- 1) in
  if n < 0 then Err ("invalid: " ++ s)
  else if n > 150 then Err "unrealistic age"
  else Ok n;

match parse_age "42" with
| Ok n  -> "age: " ++ show n
| Err e -> "error: " ++ e
```

`try_or` で panic を catch し、Result 型に詰め替える。

---

## 3. リストの典型操作 (再帰)

```
type 'a list = Nil | Cons of 'a * 'a list;

// 合計
let rec sum = fn xs -> match xs with
  | [] -> 0
  | [h, ...t] -> h + sum t;

// 長さ
let rec len = fn xs -> match xs with
  | [] -> 0
  | [_, ...t] -> 1 + len t;

// map (人手で書く)
let rec map = fn (f, xs) -> match xs with
  | [] -> []
  | [h, ...t] -> Cons (f h, map f t);

map (fn x -> x * x) [1, 2, 3, 4]    // [1, 4, 9, 16]
```

注: Phase 36 で `list_filter` / `list_map` / `list_fold` / `list_sum` / `list_max`
等の汎用 list helper が prelude に入った (累計 34 entry)。詳細は
[stdlib-reference.md](stdlib-reference.md) を参照。

---

## 4. accumulator-style 再帰 (tail-recursive 風)

直接再帰だと逆順蓄積になる場合、最後に `rev` で順番を戻す:
```
let rec rev_aux = fn (xs, acc) -> match xs with
  | [] -> acc
  | [h, ...t] -> rev_aux t (Cons (h, acc));

let rev = fn xs -> rev_aux xs [];

let rec map_acc = fn (f, xs, acc) -> match xs with
  | [] -> rev acc
  | [h, ...t] -> map_acc f t (Cons (f h, acc));
```

---

## 5. パイプで読みやすい変換チェーン

```
"  42  "
  |> str_trim       // "42"
  |> int_of_str     // 42
  |> incr           // 43
  |> show           // "43"
```

`|>` は左結合・最低優先度なので、let/if 等の上に括弧なしで乗る。

---

## 6. 関数合成でポイントフリー

```
let show_inc = str_of_int << (fn x -> x + 1);
show_inc 41                                  // "42"

let process = str_trim >> to_upper >> (str_replace " " "_");
process "  hello world  "                    // "HELLO_WORLD"
```

`<<` は右から左、`>>` は左から右。両方右結合。

---

## 7. cap-passing (capability) パターン

複数の依存をひとまとめに渡す:
```
signature ctx = (db: int, log: int);

let save_user = fn (...ctx, name: str) ->
  // db, log がスコープに入る
  print ("saving " ++ name ++ " (db=" ++ show db ++ ", log=" ++ show log ++ ")");

let log_event = fn (...ctx, evt: str) ->
  print ("event: " ++ evt ++ " (log=" ++ show log ++ ")");

// 呼び出し時は curry で展開
save_user 100 10 "alice";
log_event 100 10 "logged-in";
```

`signature` 宣言は parse-time で展開されるので、関数呼び出しは普通の curry。

---

## 8. レコードの immutable update

```
type Config = { name: str, port: int, debug: bool };

let default_cfg = Config { name = "app", port = 8080, debug = false };

let dev_cfg = { default_cfg | debug = true, port = 3000 };
let prod_cfg = { default_cfg | name = "app-prod" };
```

元レコードは変わらない (immutable)。複数フィールドを 1 回で update できる。

---

## 8.5. コレクション内 record の「1 要素だけ更新」

`Vec` / `OwnedVec` は append-only、record は immutable なので、コレクション
内の特定 record だけを書き換える直接手段はない。代わりに **`vec_map` +
`{ t | f = v }` で「条件に合う要素だけ差し替えた新コレクション」を作る**:

```mere
type Task = { id: int, text: str, done: bool };

let mark_done = fn tasks -> fn target_id ->
  region R {
    let src = owned_vec_to_vec tasks in
    let dst = vec_map src (fn (t: Task) ->
      if t.id == target_id then { t | done = true }   // ← 差分更新
      else t) in
    vec_to_owned dst
  };
```

ポイント:

- `{ t | done = true }` は `Task { id = t.id, text = t.text, done = true }`
  と等価だが、変更しない field を書かなくて済むので update 意図が明確
- 結果は **新 `OwnedVec`** なので caller が受け取って bind し直す必要がある
  (次節 8.6 の同名 rebinding を併用)
- `fn (t: Task) -> ...` の **明示注釈は必須**。HM は closure 引数が
  どの record か (field 名から) 逆引きしないので、`t.done` で型エラーに
  なる

---

## 8.6. 不変更新の連鎖は同名 rebinding で書く

`mark_done` のように新コレクションを返す関数を続けて使うときは、
**同じ名前で rebinding** すれば自然に書ける:

```mere
let tasks = owned_vec_new () in
let __ = owned_vec_push tasks (Task { id = 1, text = "buy milk", done = false }) in
let __ = owned_vec_push tasks (Task { id = 2, text = "write report", done = false }) in

// 同名 rebinding で「タスク 1 と 2 を完了に」
let tasks = mark_done tasks 1 in
let tasks = mark_done tasks 2 in
```

これは ML 系の自然な書き方で、interpreter / C / LLVM / Wasm の 4 backend
すべてで動く (codegen は内部的に 2-step 形に展開して C の `__auto_type`
self-init 制約を回避している)。

---

## 9. リスト構築の慣用句

```
// 構文糖
let xs = [1, 2, 3, 4];

// プログラム生成
let rec range = fn (lo: int, hi: int) ->
  if lo > hi then []
  else Cons (lo, range (lo + 1) hi);

range 1 5                                    // [1, 2, 3, 4, 5]
```

---

## 10. ネスト構造の destructure

```
type 'a list = Nil | Cons of 'a * 'a list;
type 'a opt  = None | Some of 'a;

match [Some 1, None, Some 3] with
| [Some a, _, Some b] -> a + b              // 単一 arm で深く分解
| _                   -> -1
```

`as-pattern` で部分構造と全体を同時に bind:
```
match [1, 2, 3, 4] with
| [a, b, ...rest] as whole -> (a + b, whole)
| _                        -> (0, [])
```

---

## 11. パーサで「次の位置」を引き回す

```
// パーサは (str, int) を取り (value, next_int) を返す
let parse_num = fn (s: str, i: int) ->
  let rec scan = fn (j: int) ->
    if j >= str_len s || not (is_digit (char_at s j)) then j
    else scan (j + 1)
  in
  let end_pos = scan i in
  if end_pos == i then fail "expected digit"
  else (int_of_str (substring s i end_pos), end_pos);

// destructure で「次の位置」を更新しながらチェーン
let (a, i) = parse_num s 0 in
let (b, i) = parse_num s (i + 1) in
a + b
```

`examples/json_parser.mere` で実際にこのパターンを使っている。

---

## 12. デバッグ出力は `show` 一本

```
let _ = print ("xs = " ++ show xs);              // "xs = [1, 2, 3]"
let _ = print ("user = " ++ show user);          // "user = User { name = ..., age = ... }"
let _ = print ("result = " ++ show (parse_json input));
```

`show : 'a -> str` は多相なので、record/sum/list/tuple なんでも内部の `to_string` で文字列化する。Cons/Nil chain は `[a, b, c]` 形式で短く出力される。

---

## 13. 副作用ループは `iter_n`

```
iter_n 5 (fn () -> print "===");

// 何かを print して何回繰り返すか
let echo = fn (n: int, s: str) ->
  iter_n n (fn () -> print s);

echo 3 "hello"
```

---

## 14. ブロック式で順序付き副作用

```
{
  print_no_nl "Name: ";
  let n = read_line () in
  print ("Hi, " ++ n ++ "!");
  0
}
```

`{ e1; e2; ...; eN }` は `let _ = e1 in let _ = e2 in ... in eN` の構文糖。最後の式が値。

---

## 14.5. Phase 36 sugar の慣用句

### `?` / `?!` で nested match を flat に

```mere
// 旧: nested match で None / Err を伝播
let safe = fn x ->
  match parse x with
  | None -> None
  | Some a ->
    match step1 a with
    | None -> None
    | Some b ->
      match step2 b with
      | None -> None
      | Some c -> Some (a + b + c);

// 新: ? で early-return
let safe = fn x ->
  let a = parse x ? in
  let b = step1 a ? in
  let c = step2 b ? in
  Some (a + b + c);
```

Result 版は `?!` で同じパターン。`examples/calc.mere` の parser が
良い実例 (138 行 / `?!` chain 5 箇所)。

### list comprehension で filter + map をまとめる

```mere
// 旧: 二段
let xs = list_map (1..100) (fn x -> x * x) in
let ys = list_filter xs (fn x -> x % 2 == 0);

// 新: 一発で
let ys = [x * x | x <- 1..100, (x * x) % 2 == 0];

// multi-gen で cartesian
let pairs = [(a, b) | a <- 1..5, b <- 1..5, a + b == 6];
```

### `for-in-do` で副作用ループ、`while-do` で fn body 内の loop

```mere
// 出力だけしたい
for x in 1..10 do print (show x);

// 累積ループは map_set / owned_vec_push 等で
for x in xs do
  let _ = owned_vec_push buf (transform x) in ();

// while: fn body 内なら使える
let consume_stream = fn stream ->
  while !(stream_eof stream) do
    let x = stream_next stream in
    let _ = process x in ();
```

注: `while` は現状 fn body 内のみ codegen 対応 (top-level main で
直接書くと unsupported)。

### `if let` で `Option` の単発取り出し

```mere
if let Some n = map_get config "timeout" then
  use_timeout n
else
  use_default ();
```

### 文字列補間でログ出力をシンプルに

```mere
// 旧: ++ chain
print ("user=" ++ name ++ ", age=" ++ show age ++ ", role=" ++ role);

// 新: 補間
print "user={name}, age={show age}, role={role}";
```

注意点:
- ネストした文字列リテラルは禁止 (`"x = {show \"abc\"}"` → エラー)。
  一度 let に逃がせば OK
- `\{` で literal 中括弧を escape
- `{}` の中身は任意の expr (関数適用 / 演算 / match も OK)

### 範囲 + ::, <|, @@ で式を読みやすく

```mere
// range + list_map
list_map (1..10) (* 2)                       // op section
0 :: 1 :: 2 :: 3 :: []                       // explicit list construction
print <| "result: " ++ show answer           // 逆 pipe
print @@ "lengthy message that goes way " ++
  "over one line — @@ avoids needing parens"
```

---

## 15. 多相 helper の活用

```
fst (pair "hello" 42)            // "hello"
snd (pair "hello" 42)            // 42
swap (1, 2)                      // (2, 1)
const "constant" "anything"      // "constant"
flip (fn a -> fn b -> a - b) 3 10   // 7 (= sub 10 3)
```

---

## アンチパターン / 罠

### 1. リテラル `-1` を関数引数で渡したい時
```
abs -1               // 構文上は (abs - 1) と読まれる (引き算)
abs (- 1)            // OK: 括弧で囲む (空白を 1 つ入れる)
abs (-1)             // 現在の lexer は `-` の後の数字を負数 lit にしない
```

### 2. ~~文字単一比較が冗長~~ → 解消 (文字リテラル + match)
```
// 旧:
if char_at s i == "n" then ... else if char_at s i == "t" then ...

// 新: char literal `'X'` + match
match char_at s i with
| 'n' -> ...
| 't' -> ...
| _   -> ...
```

### 3. ~~`match` 網羅性は実行時チェック~~ → Phase 1 で警告対応
```
match opt with
| Some n -> n
// stderr: "line X, col Y: warning: non-exhaustive match (missing None)"
// 評価は継続するが、None が来たら runtime Eval_error
```
bool と variant type 関する網羅性は compile-time に warning として検出される。int/str/tuple/record はまだ wildcard arm が必要。完全網羅化したければ `| _ -> default` か `| None -> fail "..."` を書く。

### 4. record update には base の型が必要
```
fn p -> { p | x = 0 }                   // p の型が不明で型エラー
fn (p: Point) -> { p | x = 0 }          // 注釈で OK
```
row polymorphism がないので、関数引数の record は注釈必須。

### 5. top-level fn 名が libc / libm のシンボルと衝突する (C codegen)

C codegen は top-level fn を C 関数として直接 emit するため、 macOS / Linux
の libc / libm にすでに存在する名前と被ると compile error になる。 衝突した
例 (Phase 32 〜 38 で実際にぶつかったもの):

| Mere の名前 | 衝突先 |
|---|---|
| `div` | `stdlib.h` の `div(int, int)` (商と剰余を返す) |
| `mergesort` | macOS BSD `stdlib.h` の `mergesort(...)` |
| `pow` / `sqrt` / `sin` / `cos` / `exp` / `log` | `math.h` の libm 関数 |
| `system` / `getenv` / `setenv` / `rand` / `srand` | `stdlib.h` |
| `time` / `clock` | `time.h` |
| `read` / `write` / `open` / `close` | POSIX I/O |

**回避策**: 1-2 文字短くする (`mergesort` → `msort`、 `div` → `divi`)、 動詞句に
する (`sort_list` / `power_int`)、 接頭辞 (`mere_sort`) など。 interpreter は
影響を受けないので動作確認はできるが、 codegen を試した時に発覚する。

### 6. 空 list literal `[]` は polymorphic `'a list` で codegen NG

```mere
let xs = [];          // 推論: 'a list
let _ = some_use xs;  // 後で int に推論されても、 codegen は xs の型を見て 'a leak
```

C / LLVM codegen は concrete element type が要るが、 narrow value restriction
(Phase 36) が空 list に対しても generalize するため leak する。 **回避**:

```mere
let xs = (Nil: int list);                     // 推奨: explicit annotation
let xs: int list = Nil;                       // 同等 (片方が動けば良い)
```

empty list を bind するときは「最初の要素の型」を annotation で固定する。
非空 list (`[1, 2, 3]`) は要素から推論されるため annotation 不要。

### 7. `Map[K, V]` は 2 つしか書けない、 必要なのは `Map[R, K, V]` (3 引数)

Mere の Map は region パラメータを持つ。 だから type annotation には R を
入れる必要がある:

```mere
// NG
let f = fn (m: Map[str, int]) -> map_get m "k";
// type error: expected `Map['c, 'b, 'a]`, got `(str, int) Map`

// 通る (R は型変数として書く)
let f = fn (m: Map[R, str, int]) -> map_get m "k";
// → ただし R が actual region に合わないと別の型エラーになるケースも

// 一番楽: 注釈を書かず推論に任せる
let f = fn m -> map_get m "k";
```

ML 系の経験者は K と V だけで書きがちだが、 Mere は region 必須なので
3 引数。 公開時に user の最初の躓きどころなので、 patterns / tutorial に
明記しておく。

---

## 関連ドキュメント

- 全構文の参照: [language-reference.md](language-reference.md)
- 全 builtin: [stdlib-reference.md](stdlib-reference.md)
- 起動の手順: [tutorial.md](tutorial.md)
