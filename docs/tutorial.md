# Tutorial (mere)

ML 系言語の経験がある読者を想定。15 分くらいで一通り読める分量。

## 0. インストールと起動

```sh
git clone git@github.com:284km/mere
cd mere
dune build
dune exec ./bin/mere.exe -- -e '1 + 2 * 3'   # → 7
dune exec ./bin/mere.exe -- -r               # REPL
```

以降 `mere` と書いたら `dune exec ./bin/mere.exe --` のショートカット。

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

`'X'` は単に長さ 1 の str (Mere は別 char 型を持たない)。`'a` 等の型変数構文との区別は閉じ quote の有無で。

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

## 8.5. 型エラー UX

型エラーは Rust 風 code frame で表示される (`error: ...` ヘッダ / `-->`
ロケーション / コード行 + caret / `help:` / `note:`)。よくある typo は
Levenshtein で近い候補を提案:

```
let factorial = ... in factrial 5
// type error: unbound variable: factrial
//   help: did you mean `factorial`?

type Pt = { name: str, value: int };
let p = Pt { name = "a", value = 1 } in p.namee
// type error: record Pt has no field: namee
//   help: did you mean `name`?

module M { let rec fact = ...; }; M.fct 5
// type error: unbound variable: M.fct
//   help: did you mean `M.fact`?
```

カバーしている提案: unbound variable / unknown constructor / unknown
record type / record / view field typo / qualified module-path typo。

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

**Phase 11.3 から `&R T` を介した field access の auto-deref が動く**:

```
let logger = mk_logger "app" in
region R {
  let lg_ref = &shared write R logger in
  lg_ref.info "hi"     // → "app [INFO] hi" を print
}
```

borrow mode は静的契約のままで、runtime は元の record の field を直接呼ぶ
(現状の interpreter / 3 backend 全部対応)。

**Phase 11.4: borrow checker (同一変数の衝突 borrow 拒否)**

同じ region 内で同じ変数を、衝突する 2 つの mode で借りようとすると
static error:

```
region R {
  let v = 5 in
  let a = &R v in        // shared read
  let b = &mut R v in    // ← exclusive write を要求 → 拒否
  42
}
// type error: borrow conflict: `v` is already borrowed as `&R v` here,
//   cannot reborrow as `&mut R v`
//   note: previous borrow at line N, col N
```

並存可能なペアは shared read 同士 (`&R` + `&R`) と shared write 同士
(`&shared write R` + `&shared write R`) のみ。それ以外の組合せは衝突。
動く失敗例は [`examples/borrow_conflict.mere`](../examples/borrow_conflict.mere)。

**Phase 11.5 から複雑な place expression も追跡対象** — `&R p.x` のような
field access path も識別子 (`"p.x"`、`"p.q.r"` 等) として比較される。
異なる field を別 mode で借りるのは OK、同じ field を非互換 mode で
借りると静的拒否:

```
type Pt = { x: int, y: int };
region R {
  let p = Pt { x = 3, y = 4 } in
  let a = &R p.x in
  let b = &mut R p.x in 42   // 衝突: borrow conflict: `p.x` is already ...
}

region R {
  let p = Pt { x = 3, y = 4 } in
  let a = &R p.x in
  let b = &mut R p.y in 42   // OK: 別 field
}
```

`p` 全体と `p.x` は別 place として扱われる (現状の単純比較)。本格的な
place subset 解析は別 slice。

**Phase 11.6 から if 分岐を介した borrow 伝播も追跡される** — `let r = if c then &R x else &R y in body` のように if expression の結果として
borrow が漏れ出すケースで、両分岐の borrow を union として body の active set に追加。runtime 依存で結果が決まるので保守的に両方とも active と見なす:

```
region R {
  let x = 1 in let y = 2 in
  let r = if 1 < 2 then &R x else &R y in
  let m = &mut R y in 0
  // type error: borrow conflict: `y` is already borrowed as `&R y` here,
  //   cannot reborrow as `&mut R y` (else 分岐 from y)
}
```

これにより `if` を介した借用漏れも防げる。残る borrow checker DEFERRED は
§2.3 NLL (使われなくなった borrow を解放する flow analysis)。
動く実例は [`examples/borrow_modes.mere`](../examples/borrow_modes.mere)、
意図的に型エラーを起こす side は
[`examples/borrow_modes_typeerror.mere`](../examples/borrow_modes_typeerror.mere)。

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
// lib_list_ops.mere
type 'a list = Nil | Cons of 'a * 'a list;
module ListOps {
  let rec sum = fn xs -> match xs with
    | Nil -> 0
    | Cons (h, t) -> h + sum t;
};
```

```
// main.mere
import "lib_list_ops.mere";
ListOps.sum [1, 2, 3, 4, 5]    // 15
```

同じパスが直接 / 間接で複数回 import されても 1 回だけ取り込まれる
(cycle guard)。パスは cwd 基準で解決する (slice 1)。

**Phase 9.3 から入れ子 module と `open M;` が使える**:

```
module Math {
  let inc = fn x -> x + 1;
  module Adv {
    let square = fn x -> x * x;
  };
  let inc_then_square = fn x -> Adv.square (inc x);
};

Math.Adv.square 7              // 49 (qualified nested access)

open Math;                      // direct bindings を unqualified に
inc 5                           // 6 (open 後)
Math.Adv.cube 2                 // 8 (nested は qualified のまま)
```

`open M;` は M の direct (非 nested) binding ごとに `let name = M.name;`
の alias を展開する糖衣。nested module の export は qualified access で
そのまま使う設計。

**Phase 9.4 から module 内で `type` / `record` / `variant` を declare できる**:

```
module M {
  type Pt = { x: int, y: int };
  type 'a opt = MyNone | MySome of 'a;
  let mk = fn p -> Pt { x = fst p, y = snd p };
  let unwrap = fn o -> match o with | MyNone -> 0 | MySome n -> n;
};

let p = M.mk (3, 4) in p.x + p.y          // 7
M.unwrap (MySome 35)                       // 35
```

現状の制約 (slice 1 範囲):
- module 内 declare された type / record / constructor 名は **M-prefix されず global registry に入る** ため、同名の型を異なる module で declare すると衝突する。M-prefix scoping は今後の slice で
- `open M;` は M の direct binding のみ (`open M.N;` はまだ)

**Phase 9.5 から import パスは importer 相対**: `./foo.mere` のような
relative path は **import 文があるファイルからの相対パス** として解決
される (cwd 相対ではない)。`Unix.realpath` で canonicalize されるので、
異なる relative form で同じファイルを指しても cycle guard が正しく動く。

```
// sub/lib.mere
let helper = fn x -> x * 7;
```

```
// main.mere (sub/ と同じディレクトリの上)
import "./sub/lib.mere";       // main.mere からの相対パス
helper 6                       // → 42
```

## 10.6. 可変長 Vector (`'a Vec`)

Mere の最初の **region-aware standard collection**。`'a list` が再帰的な
不変リストなのに対し、`'a Vec` は可変長の growable vector (内部は array)。

```
let nums = vec_new () in
{
  vec_push nums 10;
  vec_push nums 20;
  vec_push nums 30;
  vec_len nums              // → 3
}
```

builtin API:

| 関数 | 型 | 動作 |
|---|---|---|
| `vec_new` | `unit -> 'a Vec` | 空の Vec を作る |
| `vec_push` | `'a Vec -> 'a -> unit` | 末尾に push (in-place) |
| `vec_get` | `'a Vec -> int -> 'a` | index 取得 (範囲外は eval error) |
| `vec_len` | `'a Vec -> int` | 要素数 |

**region に置ける**: `'a` が Trivial[R] (drop type を含まない) なら、
Vec は region に置ける:

```
region R {
  let v = vec_new () in
  { vec_push v 1; vec_push v 2; &R v }   // OK
}
```

Drop 型 (`drop type Conn = { ... }`) を要素にすると Trivial[R] が破れる
ので region に置けない:

```
region R {
  let v = (vec_new () : Conn Vec) in &R v
}
// type error: Trivial[R] violated: cannot place value of type `Conn Vec`
//   into region — type contains a Drop type
```

**Phase 12.3 から `Vec[R, T]` 構文に region が意味を持つ**:

```
fn (v: Vec[R, int]) -> vec_len v    // 型: (Vec[R, int] -> int)

region R {
  let v = vec_new () in              // 型: Vec[R, int] (R に自動 bind!)
  { vec_push v 1; vec_push v 2; vec_len v }
}

vec_new ()                           // 型: Vec[__heap, 'a] (default region)
```

`vec_new ()` を呼ぶと、内側の `region R { ... }` があれば自動的に
`Vec[R, T]` 型 (region 注釈付き) を返し、なければ default 名 `__heap` の
region marker を持つ。region 越えで escape しようとすると静的拒否:

```
region R { vec_new () }
// type error: region escape: value of type `Vec[R, 'a]` cannot leave region `R`
```

legacy `T Vec` (1-arg postfix) も書けて、内部的には `Vec[__heap, T]` に
展開される (forward-compat)。

**Phase 12.6 で polymorphic `len`** — 単一の名前で複数のコレクション型に
対応する ad-hoc polymorphic builtin (`show` と同じ枠):

```
len "hello world"                              // 11 (str)
let v = vec_new () in
  { vec_push v 1; vec_push v 2; len v }        // 2 (Vec[R, T])
let w = owned_vec_new () in
  { owned_vec_push w "x"; len w }              // 1 (OwnedVec[T])
len (1, 2, 3, 4)                               // 4 (tuple)
len (Cons (1, Cons (2, Cons (3, Nil))))        // 3 ('a list)
```

型は `'a -> int`、runtime dispatch で値の variant を見て対応する長さを
返す。trait システムの代わりに「同じ名前で多くの型に効く」最小実装。

**Phase 12.5 で `OwnedVec[T]` を追加** — Vec[R, T] が region 内 Trivial
なのに対し、`OwnedVec[T]` は heap-allocated で Drop 型扱い。region に置こう
とすると静的拒否:

```
let lasting = owned_vec_new () in   // 型: int OwnedVec
{
  owned_vec_push lasting 100;
  owned_vec_len lasting              // → 1
}

region R {
  let v = owned_vec_new () in &R v
  // type error: Trivial[R] violated: cannot place value of type
  // `'a OwnedVec` into region — type contains a Drop type
}
```

「短命 / region scope」と「長期保持 / heap」が同じ Vector で書き分けられる。
動く対比 demo は [`examples/vec_vs_owned_vec.mere`](../examples/vec_vs_owned_vec.mere)。
内部実装は両者とも同じ可変配列 — 型システム上の区別のみ。

**Phase 12.10 で `Map[R, K, V]`** — region-aware mutable map (連想配列)。
Vec[R, T] / StrBuf[R] と同じ construction-time binding パターン:

```
let counts = map_new () in
{
  map_set counts "apple" 3;
  map_set counts "banana" 5;
  map_get counts "apple"        // → 3
  + (if map_has counts "absent" then map_get counts "absent" else 0)
}

region R {
  let acc = map_new () in       // Map[R, str, int]
  map_set acc "k" 42;
  len acc                       // → 1 (polymorphic len も対応)
}
```

| API | 型 |
|---|---|
| `map_new` | `unit -> Map[R, K, V]` |
| `map_set` | `Map[R, K, V] -> K -> V -> unit` |
| `map_get` | `Map[R, K, V] -> K -> V` (キー不在は eval error) |
| `map_has` | `Map[R, K, V] -> K -> bool` |
| `map_len` | `Map[R, K, V] -> int` |

内部は OCaml Hashtbl (polymorphic hash/eq) なので、key には primitive
(int / str / bool / tuple of primitives) を使う想定。closure / ref を
含む key は識別が ref 単位になるので注意。実例:
[`examples/map_basics.mere`](../examples/map_basics.mere)。

**Phase 12.9 で Vec の高階 API** — `vec_iter` / `vec_map` / `vec_fold` /
`vec_set`。`vec_map` の結果 Vec は source と同じ region に置かれる
(region-preserving):

```
let xs = vec_new () in
{
  vec_push xs 1; vec_push xs 2; vec_push xs 3;
  let squared = vec_map xs (fn x -> x * x) in    // Vec[R, int]
  let sum = vec_fold xs 0 (fn acc -> fn x -> acc + x) in  // 6
  vec_set xs 1 99;                                // in-place mutation
  vec_iter xs (fn x -> print (show x))            // side effect
}
```

| API | 型 |
|---|---|
| `vec_iter` | `Vec[R, T] -> (T -> unit) -> unit` |
| `vec_map` | `Vec[R, T] -> (T -> U) -> Vec[R, U]` |
| `vec_fold` | `Vec[R, T] -> U -> (U -> T -> U) -> U` |
| `vec_set` | `Vec[R, T] -> int -> T -> unit` |
| `vec_filter` (Phase 12.11) | `Vec[R, T] -> (T -> bool) -> Vec[R, T]` (region-preserving) |
| `vec_to_list` (Phase 12.11) | `Vec[R, T] -> T list` (要素を `'a list` の Nil/Cons chain に) |
| `vec_to_owned` (Phase 12.11) | `Vec[R, T] -> T OwnedVec` (region 内 → heap への deep copy) |
| `owned_vec_to_vec` (Phase 12.12) | `T OwnedVec -> Vec[R, T]` (heap → region 内 deep copy、R は active region に bind) |

実例: [`examples/vec_higher_order.mere`](../examples/vec_higher_order.mere)。

**closure 引数の型注釈イディオム** — `vec_map` / `vec_iter` / `vec_fold` の
closure 引数 が **record の場合は `(t: T) -> ...` と明示注釈する**。HM 推論は
closure 引数の型を field アクセスから逆引きしないので、注釈なしだと
`t.done` のような field 参照で型エラーになる:

```
type Task = { id: int, text: str, done: bool };

vec_fold tasks 0 (fn acc -> fn (t: Task) ->         // ← (t: Task) 明示
  if t.done then acc else acc + 1)
```

同じことが「record cap (Logger / Metrics / 自前 cap) を引数に取る関数」
にも当てはまる:

```
let dump_tasks = fn (lg: Logger) -> fn tasks ->     // ← (lg: Logger) 明示
  vec_iter tasks (fn (t: Task) ->
    lg.info (show t.id ++ ": " ++ t.text))
```

具体的な使い方は [`examples/todo_app.mere`](../examples/todo_app.mere)
が参考になる (OwnedVec + Logger + vec_map / fold を組み合わせた小さな
TODO アプリ)。

**Phase 12.7 で `StrBuf[R]` を追加** — region 内可変文字列バッファ。
`Vec[R, T]` と同じ construction-time binding パターンで動く:

```
region R {
  let buf = strbuf_new () in    // 型: StrBuf[R]
  {
    strbuf_push buf "Hello";
    strbuf_push buf ", ";
    strbuf_push buf "world!";
    strbuf_to_str buf            // → "Hello, world!" (str として取り出し)
  }
}

strbuf_new ()                    // 型: StrBuf[__heap] (default region)
```

API: `strbuf_new`, `strbuf_push`, `strbuf_to_str`, `strbuf_len`。polymorphic
`len` も StrBuf に効く。実例は [`examples/strbuf_basics.mere`](../examples/strbuf_basics.mere)。

**Phase 15 で 3 backend codegen 対応** — Vec / OwnedVec / StrBuf / Map +
全高階 API + 変換 + len ad-hoc polymorphism + with-OwnedVec scope-Drop が
すべて C / LLVM IR / Wasm で動くようになった。`vec_codegen_c.mere` /
`owned_vec_codegen.mere` / `strbuf_codegen.mere` / `map_codegen.mere` /
`vec_higher_order_codegen.mere` 等の例で `-c` / `-ll` / `-w` flag で
codegen を試せる:

```sh
# Vec[R, int] を C codegen して native binary 化
mere -c examples/vec_codegen_c.mere | clang -x c - -o vec && ./vec   # → 95

# Map[R, str, int] を LLVM IR codegen
mere -ll examples/map_codegen.mere | clang -x ir - -o map && ./map   # → 640

# Wasm codegen (要 wabt / Node.js)
mere -w examples/vec_codegen_wasm_typed.mere > v.wat
wat2wasm v.wat -o v.wasm
node -e 'WebAssembly.instantiate(require("fs").readFileSync("v.wasm"),
  { env: { puts: () => 0 } }).then(r => console.log(r.instance.exports.main()))'
# → 252
```

残課題 (DEFERRED §1.2 / §1.3 参照):

- **builtin の first-class value 用法** (`let f = vec_new in ...`) は
  まだ codegen 未対応 — interpreter のみ。回避策: `fn v -> vec_push v x`
  のような wrapper を書く
- **OwnedVec の自動 scope-bound Drop** は未対応 — `with v = owned_vec_new
  () in body` と明示すれば scope 末で free、明示しなければ main 末で一括 free
- **borrow checker は Vec 内部の要素単位までは追跡しない** — Vec を borrow
  した時点での mode は機械検証されるが、`vec_get` の結果を borrow するなどの
  細部は今後
- **LLVM / Wasm の Map K に payload-mixed variant** は MVP 制約で uniform
  payload 型のみ (C は mixed OK)

設計 Q-010 の全貌は internal design notes
を参照 (private repo)。

動く実例: [`examples/vec_basics.mere`](../examples/vec_basics.mere)。

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

`mere -r` で対話起動。multi-line 入力、code frame 付き型エラー、env
管理コマンドが揃っている。

```
$ mere -r
mere REPL. Type :help for commands, :quit to exit.

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
- **`factorial.mere`** — 単純な再帰
- **`fibonacci.mere`** — 同上
- **`fizzbuzz.mere`** — 演算子・条件分岐
- **`options.mere`** — sum types + match
- **`list_literal.mere`** — list 構文糖 + 再帰
- **`records.mere`** — record + パターン
- **`signature.mere`** — signature alias
- **`mutual_rec.mere`** — `let rec ... and ...`
- **`pipe.mere`** — `|>` `<<` `>>` 連結
- **`word_count.mere`** — file I/O + str_count を使った `wc` 風スクリプト
- **`json_parser.mere`** — 140 行で完動する JSON パーサ (atoms + array + object + ネスト + escape + エラー、文字 dispatch 含む)
- **`csv_parser.mere`** — 110 行で完動する CSV パーサ (RFC 4180 縮小版、quoted field + `""` escape + 空 field + file round-trip)
- **`mini_calc.mere`** — 160 行の式評価器 (算術 + 括弧 + 単項マイナス + let バインディング + 変数 + env-based eval、shadowing 動作)
- **`list_lib.mere`** — Mere 自身で実装した list ユーティリティ集 (map/filter/fold_left/fold_right/length/rev/take/drop/range/replicate/for_all/any)、stdlib に builtin として入れない哲学の見本
- **`module_basic.mere`** — `module M { ... }` + qualified 参照 `M.f` のミニ実例
- **`lib_list_ops.mere`** + **`import_demo.mere`** — decls-only ライブラリと、それを `import "path";` で取り込む側のペア
- **`repl_session.md`** — REPL の使い方を対話セッション形式で示したドキュメント
- **`borrow_modes.mere`** — 4 種類の借用注釈 (`&R T` / `&mut R T` / `&shared write R T` / `&exclusive R T`) を組み合わせて使うデモ
- **`borrow_modes_typeerror.mere`** — borrow mode mismatch が型エラーで捕捉される様子 (意図的に失敗する demo)
- **`borrow_conflict.mere`** — borrow checker (Phase 11.4) が同一変数への衝突 borrow を拒否する demo (意図的に失敗)
- **`vec_basics.mere`** — `'a Vec` の基本操作 + region 配置 (Phase 12.1)
- **`vec_vs_owned_vec.mere`** — `Vec[R, T]` (region) vs `OwnedVec[T]` (heap, Drop) の対比 demo (Phase 12.5)
- **`strbuf_basics.mere`** — `StrBuf[R]` の基本操作 + region 配置 (Phase 12.7)
- **`vec_higher_order.mere`** — `vec_iter` / `vec_map` / `vec_fold` / `vec_set` の高階 API デモ (Phase 12.9)
- **`map_basics.mere`** — `Map[R, K, V]` の基本操作 + region 配置 (Phase 12.10)
- **`module_nested.mere`** — 入れ子 module (`M.N.f`) + `open M;` のデモ (Phase 9.3)

REPL で対話的に試したいときは:
```sh
mere -r
```

## 12.5. 外部 C 関数 (FFI、Phase 32)

Mere は `extern fn` 構文で **libc / libm / OS の関数を直接呼べる**。
1 行 `extern fn time: ...;` と書くだけで、4 backend いずれでも呼出可能。

```mere
extern fn getpid:  unit -> int;
extern fn setenv:  str -> str -> int -> int;   // multi-arg curried
extern fn getenv:  str -> str;

let _ = setenv "MERE_VAR" "hello" 1 in
print (getenv "MERE_VAR")                       // → "hello"
```

backend ごとの仕組み:
- **interpreter**: `eval.ml` の `lookup_extern` に OCaml ミラー実装
  (Unix module 経由)。4 backend parity を取るため hardcoded mock
- **C codegen**: `extern <ret> <name>(<args>);` 宣言 + direct call、
  clang が libc から自動リンク
- **LLVM codegen**: `declare <ret> @<name>(<args>)` + LLVM call instruction
- **Wasm codegen**: `(import "env" <name> ...)` env host import 経由、
  `scripts/run_wasm.js` (Node.js host harness) が JS 実装を注入

MVP 型範囲: `int` / `bool` / `str` / `unit` の組合せ (arrow chain)。
`float` / `tuple` / `record` / `variant` / callback は次 phase 以降に defer。

```mere
extern fn getppid: unit -> int;
let pid  = getpid () in
let ppid = getppid () in
print (show pid ++ " " ++ show ppid)             // → "<pid> <ppid>"
```

詳細・設計判断は [internal design notes] (private repo) を参照。

## 13. ネイティブコンパイル (C / LLVM / Wasm — interp と合わせて 4 backend feature parity)

Mere プログラムは 3 codegen backend で出力でき、interpreter と合わせて
**4 backend (interp + C + LLVM + Wasm)** で feature parity 動作。
Phase 24-27 で 12 examples、Phase 28 で +4 examples、**16 realistic
examples (~2500 LoC; toy_sql.mere 単独で 1165 LoC)** が diff = 0 で
完全一致する状態に到達 (2026-06-21〜22)。

| flag | backend | 出力 |
|---|---|---|
| `-c` / `-ce` | C source | `clang` で native binary 化 |
| `-ll` / `-lle` | LLVM IR | `clang` (or `llc` + `clang`) で native binary 化 |
| `-w` / `-we` | Wasm (WAT) | `wat2wasm` で `.wasm`、`scripts/run_wasm.js` (Node.js) で実行 |

`*.mere` ファイルから C を出す例:

```sh
mere -ce 'let rec fact = fn n -> if n < 1 then 1 else n * fact (n - 1) in fact 10' > fact.c
clang fact.c -o fact
./fact   # → 3628800
```

サポート範囲は広く、主要な構文がすべて native compile できる:

```sh
# closure + 高階関数
mere -ce 'let make_adder = fn n -> fn x -> x + n in (make_adder 5) 10' > a.c
clang a.c -o a && ./a   # → 15

# 多相 variant + 再帰 + pattern match
mere -ce "type 'a list = Nil | Cons of 'a * 'a list;
  let rec sum = fn xs -> match xs with
    | Nil -> 0
    | Cons (h, t) -> h + sum t
  in sum [1, 2, 3]" > sum.c
clang sum.c -o sum && ./sum   # → 6

# show 汎用 builtin + list 表示
mere -ce "type 'a list = Nil | Cons of 'a * 'a list;
  print (show [1, 2, 3])" > sh.c
clang sh.c -o sh && ./sh   # → [1, 2, 3]
```

LLVM / Wasm 用は flag を差し替え:

```sh
# LLVM IR → native
mere -ll examples/factorial.mere | llc - -o fact.s && clang fact.s -o fact

# Wasm (WAT)
mere -w examples/factorial.mere > fact.wat
wat2wasm fact.wat -o fact.wasm    # 別途 wabt が必要
```

詳細は [codegen.md](codegen.md) を参照。

interpreter モード (`mere file.mere`) と codegen の出力は同じプログラム
なら一致する (`[1, 2, 3]` 等の整形も同じ)。**4 backend feature parity** で、
int / 関数 / 文字列 / tuple / record / variant / closure / 多相 / 再帰
variant / 複雑 pattern / show / region / view / `with` Drop / list
pretty-print / Q-010 collection (Vec / OwnedVec / StrBuf / Map) +
高階 API + 変換 + len + with-Drop / signature spread / Result helpers /
try_or / inner-fn lifting / top-level 値 binding global 化 / str_compare /
FFI (extern fn) までが動く (Phase 15 〜 32 で段階的に到達)。

interpreter / 3 codegen backend の **feature parity ギャップ** は現在
ほぼ無く、残るのは:
- builtin の **first-class value 用法** (`let f = vec_new in ...`) は
  interpreter のみ (DEFERRED §1.2、将来対応予定)
- **OwnedVec の自動 scope-bound Drop** は未対応 (`with` 明示か main 末
  一括 free のみ。DEFERRED §1.3、B1 NLL/Linear types の paper trial 段階)
- `float` / `'a list`-typed builtin (`read_lines` / `args` / `env_var` /
  `file_exists` 等) は **interpreter のみ** (codegen は別 phase)
- LLVM / Wasm の **Map K の payload-mixed variant** は uniform payload
  のみ受理 (C は mixed OK)

## 次のステップ

- 全機能の参照は [language-reference.md](language-reference.md)
- builtin の一覧は [stdlib-reference.md](stdlib-reference.md)
- よくあるイディオムは [patterns.md](patterns.md)
- C codegen の詳細・残課題は [codegen.md](codegen.md)
