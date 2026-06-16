# Tutorial (lang-ml)

ML 系言語の経験がある読者を想定。15 分くらいで一通り読める分量。

## 0. インストールと起動

```sh
git clone git@github.com:284km/lang-ml
cd lang-ml
dune build
dune exec ./bin/main.exe -- -e '1 + 2 * 3'   # → 7
dune exec ./bin/main.exe -- -r               # REPL
```

以降 `lang-ml` と書いたら `dune exec ./bin/main.exe --` のショートカット。

## 1. 式と評価

```
> 1 + 2 * 3
- : int = 7

> "Hello, " ++ "World"
- : str = "Hello, World"

> if 1 < 2 then "yes" else "no"
- : str = "yes"

> 3.14 |> f_mul 2.0
- : float = 6.28
```

整数算術、文字列結合 `++`、比較、論理 `&& ||`、`if-then-else` は普通の ML 流。`int` と `float` は別の型で、float 算術は `f_add`/`f_sub`/`f_mul`/`f_div` builtin を使う (`float_of_int` / `int_of_float` で明示変換)。

## 2. 変数 (`let`) と関数 (`fn`)

```
> let x = 5 in x * 2
- : int = 10

> let inc = fn x -> x + 1 in inc 41
- : int = 42

> let add = fn (a: int, b: int) -> a + b in add 3 4
- : int = 7
```

`fn (a, b) -> ...` は curry に展開される (`a -> b -> result`)。

部分適用も自然に動く:
```
> let add5 = add 5 in add5 10
- : int = 15
```

## 3. 再帰と相互再帰

```
> let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10
- : int = 3628800

> let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)
  and     is_odd  = fn n -> if n == 0 then false else is_even (n - 1)
  in is_even 100
- : bool = true
```

## 4. 型推論

注釈なしでも HM 推論が走る:
```
> fn x -> x
- : ('a -> 'a)                 # 多相 id

> fn f -> fn g -> fn x -> f (g x)
- : (('a -> 'b) -> (('c -> 'a) -> ('c -> 'b)))

> let id = fn x -> x in if id true then id 1 else id 2
- : int = 1                    # let-poly: 同じ id が bool と int で使える
```

## 5. パターンマッチ

### 整数 / リテラル / ガード
```
match n with
| 0            -> "zero"
| x when x < 0 -> "negative"
| _            -> "positive"
```

### コンストラクタ (sum type)
```
type 'a opt = None | Some of 'a;

match Some 42 with
| None   -> 0
| Some n -> n + 1
```

### タプル
```
match (1, 2) with
| (0, 0) -> "origin"
| (x, _) -> "x = " ++ show x
```

### リスト
```
type 'a list = Nil | Cons of 'a * 'a list;

match [1, 2, 3] with
| []          -> "empty"
| [a]         -> "single"
| [h, ...t]   -> "head: " ++ show h
```

### or-pattern / as-pattern
```
match day with
| 6 | 7              -> "weekend"          // or-pattern
| _                  -> "weekday"

match (1, 2) with
| (a, b) as whole    -> show whole         // as-pattern: tuple 全体を whole に
```

### 文字リテラル (length-1 str)
```
'A'                  // length-1 str "A"
'\n'                 // newline as length-1 str

match char_at s i with
| 'a' | 'e' | 'i' | 'o' | 'u' -> "vowel"
| c when is_digit c           -> "digit"
| _                            -> "other"
```

`'X'` は単に長さ 1 の str (Lang は別 char 型を持たない)。`'a` 等の型変数構文との区別は閉じ quote の有無で。

## 6. データ型

### Sum type (variant)
```
type ('a, 'b) result = Ok of 'a | Err of 'b;

let safe_div = fn (a: int, b: int) ->
  if b == 0 then Err "div by zero"
  else Ok (a / b);

match safe_div 10 3 with
| Ok n  -> show n
| Err e -> "error: " ++ e
```

### Record
```
type Point = { x: int, y: int };

let p = Point { x = 3, y = 4 };
let dist_sq = p.x * p.x + p.y * p.y;

let p2 = { p | x = 100 };           // immutable update
```

### Type alias
```
type UserId = int;
type Pair = int * int;
type 'a Stack = 'a list;
```

## 7. リスト

リストは「user-defined」だが構文糖と stdlib で快適:
```
type 'a list = Nil | Cons of 'a * 'a list;

let xs = [1, 2, 3, 4, 5];

let rec sum = fn xs -> match xs with
  | [] -> 0
  | [h, ...t] -> h + sum t;

sum xs                              // 15
```

## 8. 高階関数 / パイプ / 合成

### Pipe `|>`
```
5 |> (fn x -> x + 1) |> (fn x -> x * 2)     // 12
42 |> str_of_int                            // "42"
```

### Compose `<<` / `>>`
```
let show_inc = str_of_int << (fn x -> x + 1);
show_inc 41                                 // "42"

(fn x -> x * 2) >> str_of_int               // = fn x -> str_of_int (x * 2)
```

## 9. エラー処理

```
fail "panic message"                // 任意の型に統合
assert (x > 0) "x must be positive";

let safe_parse = fn s ->
  try_or (fn () -> int_of_str s) (- 1);

safe_parse "42"                     // 42
safe_parse "abc"                    // -1
```

## 9.5. ファイル I/O

```
let content = read_file "input.txt";       // ファイル全体を str に
let _ = write_file "out.txt" "hello lang"; // 上書き

// プロセス入力もある
let line = read_line ();                   // stdin から 1 行
let _ = print_no_nl "Name: ";              // プロンプト (改行なし)
let _ = print_err "error message";         // stderr
```

ファイル存在しない等のエラーは `Eval_error` を raise。`try_or` で safe parse パターンが書ける。

## 10. Signature alias (cap-passing パターン)

複数の引数を 1 つの「束」として再利用:
```
signature ctx = (db: int, log: int);

let save_order = fn (...ctx, order: int) -> db + log + order;
let log_event  = fn (...ctx, evt: int)   -> log + evt;

save_order 100 10 5 + log_event 100 10 7    // 132
```

## 11. ブロック式 (副作用シーケンス)

```
{
  print "step 1";
  print "step 2";
  42
}
```

`let _ = ...; ...; 最後の式` の構文糖。

## 12. 動く実例を読む

`examples/` から:
- **`factorial.lang`** — 単純な再帰
- **`fibonacci.lang`** — 同上
- **`fizzbuzz.lang`** — 演算子・条件分岐
- **`options.lang`** — sum types + match
- **`list_literal.lang`** — list 構文糖 + 再帰
- **`records.lang`** — record + パターン
- **`signature.lang`** — signature alias
- **`mutual_rec.lang`** — `let rec ... and ...`
- **`pipe.lang`** — `|>` `<<` `>>` 連結
- **`word_count.lang`** — file I/O + str_count を使った `wc` 風スクリプト
- **`json_parser.lang`** — 140 行で完動する JSON パーサ (atoms + array + object + ネスト + escape + エラー、文字 dispatch 含む)
- **`csv_parser.lang`** — 110 行で完動する CSV パーサ (RFC 4180 縮小版、quoted field + `""` escape + 空 field + file round-trip)
- **`mini_calc.lang`** — 100 行の算術式評価器 (precedence climbing parser + AST + eval、括弧 / 単項マイナス / div-by-zero エラー対応)

REPL で対話的に試したいときは:
```sh
lang-ml -r
```

## 次のステップ

- 全機能の参照は [language-reference.md](language-reference.md)
- builtin の一覧は [stdlib-reference.md](stdlib-reference.md)
- よくあるイディオムは [patterns.md](patterns.md)
