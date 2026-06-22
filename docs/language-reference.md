# Language reference (mere)

現在実装されている Mere の構文と意味論 (2026-06-22 / Phase 36 時点)。
`&T` 参照 / `region` / `view` / effect / FFI / 4 backend codegen はすべて
実装済。Phase 36 で 13 種の syntactic sugar (range / op section / `::` /
`<|` / `@@` / `\` lambda / string interp / `?` / `?!` / list comp / `if let` /
`for-in-do` / `while-do`) が入り、ML 系として書きやすさが大きく向上。

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

文字リテラル `'X'` は単に長さ 1 の str (Mere は独立した char 型を持たない)。`match c with | 'n' -> ...` 等のディスパッチで便利。`'a opt` 等の型変数構文と曖昧にならないように、lexer は `'X'` (閉じ quote あり) か `'NAME` (閉じ quote なし、英字始まり) かで分岐する。

### 識別子
- 先頭が小文字 or `_`、続きは英数 / `_`
- 大文字始まりは「コンストラクタ / レコード / 型名」として parser が区別
- 型変数: `'a`、`'b` 等 (`'` + 小文字始まり ident)

### キーワード
```
let rec and in if then else true false fn type signature
match with when of as _ for do while
module open import extern using region view drop
```

### 演算子・記号
```
+ - * / %                算術
== != < <= > >=          比較
&& ||                    論理 (短絡)
++                       文字列結合
|> << >>                 パイプ・関数合成
<|                       逆パイプ (Phase 36): f <| x = f x
@@                       低優先度 apply (Phase 36): f @@ x = f x
::                       cons 演算子 (Phase 36): h :: t = Cons (h, t)
..                       range literal (Phase 36): a..b = [a, ..., b-1]
?                        Option 早期 return (Phase 36)
?!                       Result 早期 return (Phase 36)
<-                       list comprehension generator (Phase 36)
\                        lambda shorthand (Phase 36): \x -> e
->                       関数型・arm 区切り
=                        束縛
: ; , .                  注釈・終端・区切り・field
( ) { } [ ]              グルーピング
...                      signature spread / list tail
|                        match 区切り・variant 区切り・record update・list comp
```

### 文字列補間 (Phase 36)

文字列リテラル中 `{expr}` は補間: lexer が再帰的にトークン化し、parser
では `"a {x} b"` を `"a " ++ show_or_str x ++ " b"` 相当に展開 (実際は
`expr` の型に応じて `++` chain)。リテラル中の `\{` で escape、ネストした
文字列リテラルは禁止 (一度 let で束縛して回避)。
```
let n = 42 in print "answer = {show n}"        // "answer = 42"
print "escape: \{not interpolated\}"            // "escape: {not interpolated}"
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
&R t             region 付き参照型 (Phase 1: 構文のみ、semantic check は将来)
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

### Phase 36 syntactic sugar 概要

すべて parser または lexer で desugar されるため、AST 以降は影響なし。
各形式の優先度は §6 参照。

```
0..5                     // range: [0, 1, 2, 3, 4] (= list_iota だが parser 直接生成)
1 :: 2 :: []             // cons: Cons (1, Cons (2, Nil))
(+ 1)                    // op section: fn x -> x + 1
(* 2)                    // (- 1) は単項 - と曖昧なので括弧優先
(< 10)                   // 比較系の section も OK
\x -> x + 1              // lambda shorthand: = fn x -> x + 1
\(a, b) -> a + b         // tuple destructure 可
f <| x                   // 逆 pipe: = f x
f @@ x                   // 低優先度 apply: = f x、改行跨ぎで読みやすい
"x = {show n}"           // 文字列補間 (lexer level、§1 参照)

[expr | x <- xs, p x]                       // list comprehension (single gen + filter)
[expr | x <- xs, y <- ys, p x y]            // multi-generator (cartesian)
                                            // desugar: list_map / list_flat_map

if let pat = e then yes_branch else no_branch
  // = match e with | pat -> yes_branch | _ -> no_branch
  // (else は省略不可、両 branch 同型)

for x in xs do body                         // = list_iter xs (\x -> body)
                                            // body は unit 型必須
while cond do body                          // = let rec __while_N = fn () ->
                                            //     if cond then (body; __while_N ()) else () in
                                            //   __while_N ()
                                            // 注: 現状 fn body 内のみ動作 (top-level は codegen 非対応)
```

### Option / Result 早期 return (`?` / `?!`、Phase 36)

`let pat = e? in body` 形式で:
- `e?` (Option): `e` が `Some v` なら `pat` に `v` を束縛して `body`、`None` なら enclosing fn から `None` を即 return
- `e?!` (Result): `e` が `Ok v` なら束縛、`Err e` なら enclosing fn から `Err e` を即 return

両者は parser が Match に展開する:
```
let v = parse_int s ? in body
  ≈ match parse_int s with | Some v -> body | None -> None
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

### with (Drop ありリソースのスコープ束縛、Phase 3.1)

`with c = v in body` は **Drop ありリソース** (DB connection / file handle / mutex 等) 用。bound value の型は `drop type ...` で宣言された Drop 型でなければならない (Trivial 値は `let`)。スコープ末で値の `close: unit -> unit` field が呼ばれる (field が無ければ no-op)。複数 binding は **LIFO 順** で close 実行。
```
drop type Conn = { id: int, close: unit -> unit };
let mk_conn = fn id ->
  Conn { id = id, close = fn () -> print ("close " ++ show id) };

with c = mk_conn 1 in c.id
// 結果: 1。scope 末で "close 1" が出力される

with c1 = mk_conn 1, c2 = mk_conn 2 in c1.id + c2.id
// 結果: 3。"close 2" → "close 1" の順で出力 (LIFO)

with x = 5 in x + 1    // ERROR: int は Drop 型ではない。`let` を使う
```

設計 doc: `internal design notes` の案 (i)「region は Trivial 厳格、Drop ありは `with` で管理」を実装。

### region (Phase 2: 構文 + 値式 `&R v` + escape check)

メモリ管理の概念・比較・Mere 全体の戦略は [memory-model.md](memory-model.md) を参照。
```
region R { body }                   // R を region 名としてスコープに導入、body を評価
region R { region S { ... } }       // ネスト可

fn (x: &R int) -> x                  // `&R T` 参照型 (R が region 名)
&R 5                                 // 値式: 5 を `&R int` として tag
let x: &R int = &R 5 in ...          // 明示注釈と組合せ
```

**現状の意味論 (Phase 2)**:
- `region R { body }` は R を内部スコープに束縛して body を評価。R 自体は unit 値の placeholder。
- `&R T` は region 付き参照型として型システムに表現される。
- `&R v` は値式で、v を `&R T` 型にラップする (interpreter は値そのまま)。
- **escape check 有効**: `region R { body }` の body の型に R が現れていたらコンパイル時エラー — region 外に `&R T` 値が漏れない。
- 将来 (Phase 3 以降) に: `r.alloc(v)` method 形式 (`&R v` の sugar)、`Trivial[R]` 制約、`with` + Drop の統合、子 region と promote 等が乗る。

**escape check の例**:
```
region R { 42 }                      // OK: int は R を含まない
region R { let x = &R 5 in 42 }      // OK: 内部で `&R int` 使うが結果は int
region R { &R 5 }                    // ERROR: 結果が `&R int`、R が外に漏れる
region R { (&R 1, 2) }               // ERROR: tuple 内に `&R int`
```

**`R.alloc(v)` sugar (Phase 2.5)**: region 内で `R.alloc(expr)` は `&R expr` の糖衣構文。R が lexically enclosing な region 名のときだけ desugar される (通常の `obj.alloc(...)` field access はそのまま動く)。
```
region R {
  let x = R.alloc(5) in              // == let x = &R 5 in ...
  let p = R.alloc((1, 2)) in
  42
}
```

**`Trivial[R]` 制約 (Phase 2.6)**: region に置ける値は **Drop semantics を持たない型** (Trivial) のみ。Drop 型は `drop type Name = ...` で宣言し、region 配置 (`&R v` / `R.alloc(v)` / view フィールド) で Drop 型を含むと型エラーになる。これは「region の一括解放を可能にするための制約」で、Drop が必要な cap (DB connection / file handle 等) は将来の `with` 式で別途管理する。
```
drop type Conn = { id: int };

let c = Conn { id = 1 } in c.id      // OK: region 外なら Drop 型も普通に使える

region R {
  &R Conn { id = 1 }                  // ERROR: Trivial[R] violated
}

view Holder[R] { c: Conn };
region S { Holder { c = ... } }       // ERROR: view field has Drop type

region R {
  &R (fn (c: Conn) -> c.id)           // OK: function 型は closure 値として Trivial
}
```

### view (Phase 2.4: 宣言 + region 強制 + 型 tag 伝播)

```
view V[R] of T { f1: T1, f2: T2, ... };   // region R 上の view 型 (内部型 T 指定)
view V[R] { f1: T1, ... };                // `of T` は省略可
```

`view V[R] of T { ... }` は **region パラメータ付きのデータ宣言**。Phase 2.4 では:

- view 構築は `region { ... }` block 内でのみ可能 (region 外で `V { ... }` を書くと型エラー)
- 構築時、view の region パラメータ `R` は最内側の active region 名に置換され、view 値の型は `V[<region>]` 形式になる
- フィールドアクセス `v.f1` と record update `{ v | f1 = e1 }` は record と同じく使え、`&R T` 型のフィールドも構築時 region に substitute された型として取り出せる
- view 値自体は escape check の対象 — 構築 region 外には出せない

```
view Node[R] of int { value: int, next: int };
region R { let n = Node { value = 1, next = 0 } in n.value }       // 1
region MyArena { let n = Node { value = 7, next = 0 } in n.value } // 7 (R → MyArena)
let n = Node { value = 1, next = 0 } in ...                        // ERROR: must be inside a region block

view Slot[R] { item: &R int };
region S { 
  let s = Slot { item = &S 42 } in     // s : Slot[S]
  let take_s = fn (x: &S int) -> 99 in
  take_s s.item                         // s.item : &S int → 99
}

region S { Slot { item = &T 42 } }     // ERROR (region 不一致)
region S { Cell { v = 1 } }            // ERROR: Cell[S] cannot leave region S
```

**将来 Phase で厳格化される予定**:
- 同一 region 内の循環構築 (mutable な構築 phase + immutable な使用 phase の二段階)
- Q-009 の "structural identity by region" 公理 (同一 region 内の同型 view を同一視)

詳細は [memory-model.md](memory-model.md) と `internal design notes` 参照。

### 関数 + `using [cap]` 構文糖

`using [cap1, cap2, ...]` は cap-passing スタイルで頻発する partial application パターンを緩和する構文糖。caps は outer-most curried args として展開される。
```
fn x using [logger] -> body
// ≡ fn logger -> fn x -> body
```

これにより caller は `f cap` で cap を embedding した `T -> U` を即座に得られ、`map` 等の高階関数に渡せる:
```
let log_x = fn x using [logger] -> logger (show x);
let bound = log_x my_logger;    // bound : int -> unit
iter bound [1, 2, 3];
```

- 型注釈可: `fn x using [c: int -> int] -> c x`
- 複数 cap: `fn x using [logger: Logger, metrics: Metrics] -> ...`
- 通常 params と組合せ: `fn (x: int) using [c: Logger] -> c.info (show x)`
- 空 `using []` は parse error

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
| 1 (低) | `let`, `if`, `fn`, `match`, `with`, `for`, `while` | - |
| 2 | `@@` (低優先度 apply、Phase 36) | 右 |
| 3 | `|>` / `<|` (Phase 36) | 左 / 右 |
| 4 | `<<`, `>>` | 右 |
| 5 | `||` | 左 |
| 6 | `&&` | 左 |
| 7 | `==`, `!=`, `<`, `<=`, `>`, `>=` | 非結合 |
| 8 | `::` (cons、Phase 36) | 右 |
| 9 | `..` (range、Phase 36) | 非結合 |
| 10 | `+`, `-`, `++` | 左 |
| 11 | `*`, `/`, `%` | 左 |
| 12 | unary `-` | - |
| 13 | `?` / `?!` (postfix、Phase 36) | postfix |
| 14 | function application | 左 |
| 15 (高) | atom / `(...)` / `[...]` / `{...}` / `.field` / op section `(+ N)` / `\x -> e` / `"...{expr}..."` | - |

`expr : type` (annotation) は最外で 1 回適用される。

---

## 7. 評価モデル

- **正格評価** (call-by-value)、ただし `&&` と `||` は短絡
- **可変なし** (immutable)、再代入できない、`with` も新しいバインディングを作る
- **closure 取り込み** は値参照 (環境を closure に閉じ込める)
- **エラー**: 型エラーは compile-time、`fail`/`assert`/`div by zero`/`unmatched match` 等は実行時 `Eval_error`

---

## 8. 既知の制約 (2026-06-22)

旧版で「未実装」だった項目は Phase 14-36 で順次実装され、現状は以下のみ残る:

- **網羅性検査は Phase 1** (bool + variant types のみ): 非網羅は **warning** を stderr に出力、評価は継続 (case 漏れは runtime fallthrough エラー)
- **int / str / float / tuple / record の網羅性**は wildcard arm が必要 (精密な検査は将来)
- **文字列 escape** は `\n \t \\ \"` + Phase 36 で `\{` (補間の中括弧 escape) のみ。Unicode escape (`\uXXXX`) なし
- **整数は固定幅**: int は OCaml の `int` (host 依存、通常 63 bit)、任意精度なし。LLVM/Wasm では i64 / i32
- **float は MVP**: IEEE 754 倍精度、`f_add` 系の関数 prefix。`+.` のような中置版は未実装
- **文字列補間でネスト文字列リテラル禁止**: `"x = {show \"abc\"}"` は lexer エラー (let 経由で回避)
- **`while` は fn body 内のみ**: top-level main で `while` を直接書くと codegen 非対応 (top-level Let_rec 制約)
- **REPL の `:type EXPR` は値式のみ**: top-level decl の型表示は `:show NAME` で可能
- **FFI 型範囲は MVP**: `int / bool / str / unit` のみ (float / tuple / record / variant / callback は defer、Phase 32)
- **ポリモーフィズム**: HM 推論 + let-polymorphism + 多相 user let-rec の per-instantiation 特殊化 (Phase 23.3 / 25.5 / 26.4)。Phase 36 で **narrow value restriction** 導入 (mutable container を含む型は let-bind 時に generalize しない)

## 9. ステータス概要

- **1529 tests passing** (test/test_basic.ml)
- **4 backend feature parity**: interpreter + C / LLVM IR / Wasm runtime
- 16 realistic examples (~1500 LoC + toy_sql 1165 LoC) で **diff = 0 PERFECT 一致**
- 詳細は [Changelog](changelog.md) / [Codegen](codegen.md) を参照

---

詳細な動作確認は `examples/` と `test/test_basic.ml` を参照。
