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

注: stdlib に汎用 `map`/`filter`/`fold` は未提供 (list 型が user-defined のため)。

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

---

## 関連ドキュメント

- 全構文の参照: [language-reference.md](language-reference.md)
- 全 builtin: [stdlib-reference.md](stdlib-reference.md)
- 起動の手順: [tutorial.md](tutorial.md)
