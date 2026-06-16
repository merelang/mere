# Language reference (lang-ml)

現在実装されている Lang の構文と意味論。将来予定の機能 (`&T` 参照 / `region` / `view` / effect 等) は含まない。

---

## 1. 字句

### コメント
```
// 行コメント (改行まで)
```

### リテラル
| 種類 | 例 |
|---|---|
| 整数 | `0`、`42`、`-5` (構文上は `Neg (Int_lit 5)`) |
| 浮動小数 | `1.5`、`3.14`、`0.0` (digits.digits、bare `1.` は不可) |
| 真偽 | `true`、`false` |
| 文字列 | `"hello"`、escape は `\n` `\t` `\\` `\"` |
| 文字 (length-1 str) | `'X'`、escape は `'\n'` `'\t'` `'\\'` `'\''` `'\"'` |
| ユニット | `()` |

文字リテラル `'X'` は単に長さ 1 の str (Lang は独立した char 型を持たない)。`match c with | 'n' -> ...` 等のディスパッチで便利。`'a opt` 等の型変数構文と曖昧にならないように、lexer は `'X'` (閉じ quote あり) か `'NAME` (閉じ quote なし、英字始まり) かで分岐する。

### 識別子
- 先頭が小文字 or `_`、続きは英数 / `_`
- 大文字始まりは「コンストラクタ / レコード / 型名」として parser が区別
- 型変数: `'a`、`'b` 等 (`'` + 小文字始まり ident)

### キーワード
```
let rec and in if then else true false fn type signature
match with when of as _
```

### 演算子・記号
```
+ - * / %                算術
== != < <= > >=          比較
&& ||                    論理 (短絡)
++                       文字列結合
|> << >>                 パイプ・関数合成
->                       関数型・arm 区切り
=                        束縛
: ; , .                  注釈・終端・区切り・field
( ) { } [ ]              グルーピング
...                      signature spread / list tail
|                        match 区切り・variant 区切り・record update
```

---

## 2. 型

### プリミティブ
```
int   float   bool   str   unit
```

`float` は IEEE 754 倍精度。リテラルは `1.5` のように小数点 + 数字を含むものが float、`1` は int (bare `1.` は float ではなく `1` + `.field` 候補)。`int` と `float` は別の型で、暗黙変換なし — `float_of_int` / `int_of_float` で明示変換、算術は `f_add` / `f_sub` / `f_mul` / `f_div` を使う。

### 合成型
```
t1 -> t2         関数型 (右結合: a -> b -> c == a -> (b -> c))
t1 * t2 * ...    タプル型
t list           型コンストラクタ (postfix application)
(t1, t2) result  多 type-arg
'a               型パラメータ (declaration 内、annotation 内)
```

---

## 3. 式

### リテラル / 識別子
```
42   true   "hi"   ()
x    (変数参照)
```

### 算術 / 比較 / 論理
```
1 + 2 * 3                7         (* / 優先)
10 / 3                   3         (整数除算、0 div で Eval_error)
10 % 3                   1         (剰余、0 div で Eval_error)
"a" ++ "b"               "ab"      (文字列結合)
5 <= 5                   true
1 != 2                   true
true && false            false     (短絡: 左 false なら右 評価しない)
false || true            true
not true                 false     (builtin)
```

### let バインディング
```
let x = 5 in x + 1                 // ident
let _ = side_effect in 1           // wildcard
let (a, b) = (3, 4) in a + b       // tuple destructure
let (a, (b, c)) = (1, (2, 3)) in a + b + c
```

### let rec / 相互再帰
```
let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 5

let rec is_even = fn n -> if n == 0 then true else is_odd (n - 1)
and is_odd     = fn n -> if n == 0 then false else is_even (n - 1)
in is_even 10
```

### if-then-else / if-then
```
if cond then a else b               // 通常の if、a と b は同型
if cond then print "msg"            // 副作用専用、body は unit 型必須
```

### with (スコープ束縛、将来 Drop と統合予定)
```
with logger = 100, db = 200 in
  logger + db
```

### 関数
```
fn x -> x + 1                       // 単引数 (型推論)
fn (x: int) -> x + 1                // 単引数 (型注釈)
fn (x: int, y: int) -> x + y        // 多引数 (curry に desugar)
fn (a, b, c) -> a + b * c           // 多引数、無注釈
fn () -> 42                         // 引数なし (内部で _u : unit)
```

### 適用 / 部分適用
```
inc 5
add 3 4                             // = (add 3) 4
let inc1 = (+) 1 in ...             // 演算子の funct 化は未対応 (今は curry fn で代替)
```

### タプル / レコード / リスト
```
(1, 2, 3)                           // tuple

type Point = { x: int, y: int };
let p = Point { x = 3, y = 4 } in p.x + p.y           // record
let p2 = { p | x = 100 } in p2.x                       // record update

type 'a list = Nil | Cons of 'a * 'a list;
[1, 2, 3]                           // list 構文糖 = Cons (1, Cons (2, Cons (3, Nil)))
[]                                  // = Nil
```

### sum types / コンストラクタ / match
```
type 'a opt = None | Some of 'a;

match Some 42 with
| None -> 0
| Some n when n > 10 -> 1000
| Some n -> n + 1

match xs with
| []          -> "empty"
| [h, ...t]   -> "head + rest"
| [a, b, c]   -> "exactly three"

match x with
| (a, b) as p when a < b -> p         // as-pattern: whole を p に bind
| _                      -> (0, 0)

match day with
| 1 | 2 | 3 | 4 | 5 -> "weekday"     // or-pattern
| 6 | 7             -> "weekend"
| _                 -> "invalid"
```

### ブロック / 副作用シーケンス
```
{ }                                 // → unit
{ e1; e2; e3 }                      // → eN、e1..e_(N-1) は捨てる (let _ = ... in chain)
```

### 関数合成 / パイプ
```
5 |> inc |> dbl                     // = dbl (inc 5)、左結合、最低優先
inc << dbl                          // = fn x -> inc (dbl x)、右結合
inc >> dbl                          // = fn x -> dbl (inc x)、右結合
```

### 型注釈 (annotation)
```
(42 : int)                          // 表現的だが既存型と一致必須
((fn x -> x + 1) : int -> int) 5    // 関数の型注釈
```

### Signature alias (関数引数束ね)
```
signature ctx = (db: int, log: int);

let save = fn (...ctx, order: int) -> db + log + order in
save 100 10 5                       // 115
```

---

## 4. パターン

| 種類 | 構文 | 例 |
|---|---|---|
| ワイルドカード | `_` | `_` |
| 変数 | `name` | `n`、`xs` |
| 整数 | `N` | `0`、`42` |
| 真偽 | `true` / `false` | |
| 文字列 | `"..."` | `"foo"` |
| unit | `()` | |
| タプル | `(p1, p2, ...)` | `(a, b)`、`(a, (b, c))` |
| コンストラクタ | `Name` or `Name sub_pat` | `None`、`Some x`、`Cons (h, t)` |
| リスト | `[]` / `[a, b, c]` / `[h, ...t]` / `[..._]` | |
| レコード | `Name { f1 = p1, f2 = p2 }` | `Point { x = 0, y = py }`、partial OK |
| as | `pat as name` | `Cons (h, t) as whole` |
| or | `p1 | p2` | `1 | 2 | 3`、両 branch は同 names + 同型を bind |

### ガード (in match)
```
match x with
| n when n > 0 -> "positive"
| _            -> "non-positive"
```

---

## 5. Top-level 宣言

### let / let rec
```
let x = 5;                          // ident 形
let (a, b) = (3, 4);                // pattern 形
let _ = print "init";               // wildcard でも OK

let rec fact = fn n -> ... ;
let rec is_even = ... and is_odd = ... ;
```

### type 宣言

```
// 1. Sum type (variant)
type 'a opt = None | Some of 'a;
type ('a, 'b) result = Ok of 'a | Err of 'b;

// 2. Record
type Point = { x: int, y: int };
type 'a Box = { value: 'a };

// 3. Type alias
type UserId = int;
type Pair = int * int;
type 'a Stack = 'a list;
```

判別:
- `=` の直後が `{` → record
- 先頭 `|`、または大文字 ident + (`|`/`of`) → variant
- それ以外 → alias

### signature

```
signature ctx = (db: int, log: int);
// fn (...ctx, x: int) -> ... で展開される (parse-time)
```

---

## 6. 演算子優先度 (低 → 高)

| 優先度 | 演算子 | 結合性 |
|---|---|---|
| 1 (低) | `let`, `if`, `fn`, `match`, `with` | - |
| 2 | `|>` | 左 |
| 3 | `<<`, `>>` | 右 |
| 4 | `||` | 左 |
| 5 | `&&` | 左 |
| 6 | `==`, `!=`, `<`, `<=`, `>`, `>=` | 非結合 |
| 7 | `+`, `-`, `++` | 左 |
| 8 | `*`, `/`, `%` | 左 |
| 9 | unary `-` | - |
| 10 | function application | 左 |
| 11 (高) | atom / `(...)` / `[...]` / `{...}` / `.field` | - |

`expr : type` (annotation) は最外で 1 回適用される。

---

## 7. 評価モデル

- **正格評価** (call-by-value)、ただし `&&` と `||` は短絡
- **可変なし** (immutable)、再代入できない、`with` も新しいバインディングを作る
- **closure 取り込み** は値参照 (環境を closure に閉じ込める)
- **エラー**: 型エラーは compile-time、`fail`/`assert`/`div by zero`/`unmatched match` 等は実行時 `Eval_error`

---

## 8. 既知の制約

- float / 任意ビット幅整数なし
- 文字列 escape は `\n \t \\ \"` のみ
- 網羅性検査は **Phase 1** (bool + variant types) — 非網羅は **warning** を stderr に出力、評価は継続 (case 漏れは runtime fallthrough エラー)
- int/str/float/tuple/record の網羅性は wildcard arm が必要 (より精密な検査は将来)
- ネイティブ codegen なし (全てインタプリタ)
- メモリモデル / region / view / effect は未実装 (設計は `internal design notes` で進行)
- REPL は単一行入力のみ

---

詳細な動作確認は `examples/` と `test/test_basic.ml` を参照。
