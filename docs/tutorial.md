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

## 10.4. 借用注釈 (`&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T`)

`&R T` は region R の中の値への参照。**借用 mode** を付けて「どんな
access か」を型に書ける (Phase 11.1 で導入)。

| 構文 | mode | 意図 |
|---|---|---|
| `&R T` (省略 = default) | borrowed (shared read) | 設定値・読み取り cap |
| `&shared write R T` | shared write | Logger・Metrics 等、複数 caller が並行書き込み (cap 内部で安全) |
| `&exclusive R T` | exclusive read | 排他 read (稀) |
| `&mut R T` | exclusive write | Database 接続の transaction 等、Rust の `&mut` 相当 |

```
type DbHandle = { id: int };

let db_exec = fn (db: &mut R DbHandle) -> fn (sql: str) ->
  "[exclusive] " ++ sql;

region R {
  let db = DbHandle { id = 1 } in
  let db_ref = &mut R db in
  db_exec db_ref "UPDATE ..."
}
```

mode が違うと unify が拒否:

```
let db_ref = &R db in           // shared read
db_exec db_ref "X"               // ← &mut を要求 → 型エラー
// expected `&mut R DbHandle`, got `&R DbHandle`
```

これで設計の **Logger 問題** (`&borrowed` だと write 意図が出ない、
`&mut` だと並行不可) が `&shared write` で型として書ける。

現状 (Phase 11.1) は型として認識できる段階で、**借用機構の排他規則**
(同じ region から `&shared` と `&exclusive` を同時取得拒否など) と
**`&R T` を介した field access の auto-deref** は今後の slice。
動く実例は [`examples/borrow_modes.lang`](../examples/borrow_modes.lang)、
意図的に型エラーを起こす side は
[`examples/borrow_modes_typeerror.lang`](../examples/borrow_modes_typeerror.lang)。

## 10.5. モジュールと import

複数の関連 binding を `module M { ... }` でくくれる。bindings は `M.name`
で外から参照する。

```
module Math {
  let inc = fn x -> x + 1;
  let square = fn x -> x * x;
  let inc_then_square = fn x -> square (inc x);
};

Math.inc_then_square 4    // 25
```

モジュール内の短縮名 (`inc`, `square`) は parse 時に `Math.inc`, `Math.square`
に書き換わるので、相互参照 (上の `inc_then_square` が `square (inc x)`
として書ける) は自然に動く。`let rec` の自己参照も同様。

別ファイルに切り出した decls は `import "path";` で取り込む。

```
// lib_list_ops.lang
type 'a list = Nil | Cons of 'a * 'a list;
module ListOps {
  let rec sum = fn xs -> match xs with
    | Nil -> 0
    | Cons (h, t) -> h + sum t;
};
```

```
// main.lang
import "lib_list_ops.lang";
ListOps.sum [1, 2, 3, 4, 5]    // 15
```

同じパスが直接 / 間接で複数回 import されても 1 回だけ取り込まれる
(cycle guard)。パスは cwd 基準で解決する (slice 1)。

現状 slice 1 の制約:
- module 内では `let` / `let rec` のみ (type / record は module の外で declare)
- 入れ子 module / `open M` 構文は今後
- import パス resolution は cwd 相対 (importer 相対は今後)

## 11. ブロック式 (副作用シーケンス)

```
{
  print "step 1";
  print "step 2";
  42
}
```

`let _ = ...; ...; 最後の式` の構文糖。

## 11.5. REPL を使う

`lang-ml -r` で対話起動。multi-line 入力、code frame 付き型エラー、env
管理コマンドが揃っている。

```
$ lang-ml -r
lang-ml REPL. Type :help for commands, :quit to exit.

> let rec fact = fn n ->
..>   if n < 1 then 1
..>   else n * fact (n - 1);
val fact : (int -> int)

> :show fact
val fact : (int -> int)
  = <closure:n>

> fact 10
- : int = 3628800
```

主要コマンド:

| コマンド | 用途 |
|---|---|
| `:type EXPR` | 型推論結果のみ表示 (eval しない) |
| `:env` | 現在の user bindings 一覧 |
| `:show NAME` | NAME の型 + 値を同時に表示 |
| `:load FILE` | FILE の decls を REPL env に取り込み |
| `:reset` | 全 user bindings をクリア |
| `:quit` / `:q` | exit |

multi-line 入力中に空行 / `:` 始まりの行で `(input aborted)` で buffer
破棄。詳細なセッション例は [examples/repl_session.md](../examples/repl_session.md)。

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
- **`mini_calc.lang`** — 160 行の式評価器 (算術 + 括弧 + 単項マイナス + let バインディング + 変数 + env-based eval、shadowing 動作)
- **`list_lib.lang`** — Lang 自身で実装した list ユーティリティ集 (map/filter/fold_left/fold_right/length/rev/take/drop/range/replicate/for_all/any)、stdlib に builtin として入れない哲学の見本
- **`module_basic.lang`** — `module M { ... }` + qualified 参照 `M.f` のミニ実例
- **`lib_list_ops.lang`** + **`import_demo.lang`** — decls-only ライブラリと、それを `import "path";` で取り込む側のペア
- **`repl_session.md`** — REPL の使い方を対話セッション形式で示したドキュメント
- **`borrow_modes.lang`** — 4 種類の借用注釈 (`&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T`) を組み合わせて使うデモ
- **`borrow_modes_typeerror.lang`** — borrow mode mismatch が型エラーで捕捉される様子 (意図的に失敗する demo)

REPL で対話的に試したいときは:
```sh
lang-ml -r
```

## 13. ネイティブコンパイル (C / LLVM / Wasm の 3 backend)

Lang プログラムは 3 つの backend で codegen できる。すべて feature parity
で動き、同じ Lang ソースから 3 種のネイティブ / portable バイナリを出せる。

| flag | backend | 出力 |
|---|---|---|
| `-c` / `-ce` | C source | `clang` で native binary 化 |
| `-ll` / `-lle` | LLVM IR | `llc` + `clang` で native binary 化 |
| `-w` / `-we` | Wasm (WAT) | `wat2wasm` で `.wasm`、Node.js などで実行 |

`*.lang` ファイルから C を出す例:

```sh
lang-ml -ce 'let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10' > fact.c
clang fact.c -o fact
./fact   # → 3628800
```

サポート範囲は広く、主要な構文がすべて native compile できる:

```sh
# closure + 高階関数
lang-ml -ce 'let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10' > a.c
clang a.c -o a && ./a   # → 15

# 多相 variant + 再帰 + pattern match
lang-ml -ce "type 'a list = Nil | Cons of 'a * 'a list;
  let rec sum = fn xs -> match xs with
    | Nil -> 0
    | Cons (h, t) -> h + sum t
  in sum [1, 2, 3]" > sum.c
clang sum.c -o sum && ./sum   # → 6

# show 汎用 builtin + list 表示
lang-ml -ce "type 'a list = Nil | Cons of 'a * 'a list;
  print (show [1, 2, 3])" > sh.c
clang sh.c -o sh && ./sh   # → [1, 2, 3]
```

LLVM / Wasm 用は flag を差し替え:

```sh
# LLVM IR → native
lang-ml -ll examples/factorial.lang | llc - -o fact.s && clang fact.s -o fact

# Wasm (WAT)
lang-ml -w examples/factorial.lang > fact.wat
wat2wasm fact.wat -o fact.wasm    # 別途 wabt が必要
```

詳細は [codegen.md](codegen.md) を参照。

interpreter モード (`lang-ml file.lang`) と codegen の出力は同じプログラム
なら一致する (`[1, 2, 3]` 等の整形も同じ)。3 backend は feature parity で、
int / 関数 / 文字列 / tuple / record / variant / closure / 多相 / 再帰 variant /
複雑 pattern / show / region / view / `with` Drop / list pretty-print まで
すべて動く。

## 次のステップ

- 全機能の参照は [language-reference.md](language-reference.md)
- builtin の一覧は [stdlib-reference.md](stdlib-reference.md)
- よくあるイディオムは [patterns.md](patterns.md)
- C codegen の詳細・残課題は [codegen.md](codegen.md)
