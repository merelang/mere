# Stdlib reference (mere)

`initial_env` で常に使える 106 個の builtin。型は `mere -te NAME` で確認可。

凡例:
- ⚡ = `Eval_error` を raise する可能性あり
- ★ = 多相 (let-poly に乗らない、builtin-level 多相)
- 🌐 = 4 backend (interp + C + LLVM + Wasm) で動作 (Phase 22-31 で順次対応)

---

## I/O (10)

| 名前 | 型 | 説明 |
|---|---|---|
| `print` | `str -> unit` | stdout に書き出し + 改行 |
| `print_no_nl` | `str -> unit` | 改行なし + flush (prompt 用) |
| `print_int` | `int -> unit` | 整数を改行付きで出力 |
| `print_bool` | `bool -> unit` | bool を改行付きで出力 |
| `print_err` | `str -> unit` | stderr に書き出し + 改行 |
| `read_line` | `unit -> str` | stdin から 1 行、EOF は空文字 |
| `read_file` ⚡ | `str -> str` | ファイル全体を読む、失敗で raise |
| `write_file` ⚡ | `str -> str -> unit` | path → content をファイルに書く (上書き)、失敗で raise |
| `read_lines` ⚡ ★ | `str -> str list` | 行単位で読み込み、`str list` 返却 (Phase 19.6、prelude 依存) |
| `file_exists` ★ | `str -> bool` | path が存在するか (Phase 19.6) |
| `env_var` ★ | `str -> str option` | 環境変数取得、未設定は `None` (Phase 19.6、prelude 依存) |
| `args` ★ | `unit -> str list` | program 起動時 argv[1..] (Phase 19.6) |

```
file_exists "/etc/hosts"            // → true
env_var "PATH"                      // → Some "..."
env_var "BOGUS"                     // → None
read_lines "data.txt"               // → ["line1", "line2", ...]
args ()                             // → ["foo", "bar"] (mere prog -- foo bar)
```

**★ codegen 状況**: `print` / `print_no_nl` / `print_int` / `print_bool` /
`print_err` / `read_file` / `write_file` は 3 backend で動作 (Wasm は host
imports 経由、`scripts/run_wasm.js` で puts / read_file / write_file を提供)。
`read_lines` / `args` / `env_var` / `file_exists` は **interpreter のみ**
(codegen で `'a list` / `'a option` 構築 + 系統的に外界アクセスが必要、
Phase 22-31 では未着手)。

```
let _ = print "Hello";
let _ = print_no_nl "Name: ";
let name = read_line () in print ("Hi, " ++ name);

// ファイル round-trip
let _ = write_file "/tmp/out.txt" "hello lang";
let content = read_file "/tmp/out.txt" in print content;
```

---

## 値変換 (3)

| 名前 | 型 | 説明 |
|---|---|---|
| `str_of_int` | `int -> str` | 整数を文字列に |
| `int_of_str` ⚡ | `str -> int` | trim 後パース、不正で raise |
| `bool_of_str` ⚡ | `str -> bool` | trim 後 `"true"`/`"false"` のみ、他は raise |
| `float_of_int` | `int -> float` | int → float (精度損失なし) |
| `int_of_float` | `float -> int` | float → int (切り捨て) |
| `str_of_float` | `float -> str` | float を文字列に (OCaml semantics) |
| `float_of_str` ⚡ | `str -> float` | trim 後パース、不正で raise |

```
str_of_int 42        // "42"
int_of_str "  -7  "  // -7
bool_of_str "true"   // true
```

---

## 文字列操作 (22)

| 名前 | 型 | 説明 |
|---|---|---|
| `str_len` | `str -> int` | バイト長 |
| `str_contains` | `str -> str -> bool` | 部分文字列を含むか |
| `str_starts_with` | `str -> str -> bool` | prefix 判定 |
| `str_ends_with` | `str -> str -> bool` | suffix 判定 |
| `str_count` | `str -> str -> int` | 非オーバーラップ出現回数 |
| `str_index_of` ★ | `str -> str -> int` | needle の最初の位置、無ければ -1。empty needle は 0 (Phase 19.1) |
| `str_split` ★ | `str -> str -> str list` | delimiter で分割、`str list` 返却。`type 'a list = ...` の declare が必要。empty delimiter は単一要素 list を返す (Phase 19.1) |
| `str_join` ★ | `str -> str list -> str` | separator で結合。空 list は空文字列 (Phase 19.1) |
| `str_compare` 🌐 | `str -> str -> int` | 辞書順 -1 / 0 / 1 (Phase 31.0 で 3 backend に移植、sign-normalized) |
| `str_repeat` ⚡ | `str -> int -> str` | N 回繰り返し、N<0 で raise |
| `str_replace` | `str -> str -> str -> str` | 全置換、empty needle は変化なし |
| `str_rev` | `str -> str` | 文字列反転 |
| `str_trim` | `str -> str` | 前後空白除去 |
| `str_unescape` ⚡ | `str -> str` | `\n` `\t` `\r` `\\` `\"` `\/` を decode、未知 escape で raise |
| `substring` ⚡ | `str -> int -> int -> str` | `s[start:end_excl]`、範囲外で raise |
| `char_at` ⚡ | `str -> int -> str` | index アクセス (長さ 1 の str)、OOB で raise |
| `chr` ⚡ | `int -> str` | 0..255 の int を 1 文字 str に、範囲外で raise |
| `ord` ⚡ | `str -> int` | 単一文字 str を int code point に、長さ != 1 で raise |
| `to_upper` | `str -> str` | ASCII 大文字化 |
| `to_lower` | `str -> str` | ASCII 小文字化 |
| `is_digit` | `str -> bool` | 単一文字で `'0'..'9'` なら true、他は false |
| `is_alpha` | `str -> bool` | 単一文字で letter なら true |
| `is_space` | `str -> bool` | 単一文字で space/tab/\n/\r なら true |

```
type 'a list = Nil | Cons of 'a * 'a list;
str_split "a,b,c" ","                          // ["a", "b", "c"]
str_join "-" ["alpha", "beta", "gamma"]        // "alpha-beta-gamma"
str_index_of "hello world" "world"             // 6
str_index_of "hello" "xyz"                     // -1
```

**★ codegen 状況**: `str_index_of` / `str_split` / `str_join` / `str_count` /
`str_compare` はすべて **4 backend 全部で動く** (Phase 19.1.1 で str_index_of、
Phase 22 で str_split / str_join、Phase 26.5 で Wasm 全 str ops、Phase 31.0
で str_compare 移植 sign-normalize 完了)。

```
str_replace "foo bar foo" "foo" "X"           // "X bar X"
substring "hello world" 6 11                  // "world"
char_at "abcdef" 2                            // "c"
"world" |> str_contains "hello world"         // true (pipe + curry)
str_unescape "a\\nb"                          // a + newline + b (3 chars)
```

---

## 数値演算 (17)

| 名前 | 型 | 説明 |
|---|---|---|
| `min` | `int -> int -> int` | 小さい方 |
| `max` | `int -> int -> int` | 大きい方 |
| `abs` | `int -> int` | 絶対値 |
| `sign` | `int -> int` | -1 / 0 / 1 |
| `clamp` | `int -> int -> int -> int` | `clamp lo hi x` で `[lo, hi]` に制限 |
| `pow` ⚡ | `int -> int -> int` | base^exp、負 exp で raise |
| `square` | `int -> int` | x * x |
| `cube` | `int -> int` | x * x * x |
| `incr` | `int -> int` | +1 |
| `decr` | `int -> int` | -1 |
| `even` | `int -> bool` | n mod 2 == 0 |
| `odd` | `int -> bool` | n mod 2 != 0 |
| `gcd` | `int -> int -> int` | Euclid (負と 0 も正しく) |
| `lcm` | `int -> int -> int` | `|a/gcd * b|`、0 を含むと 0 |
| `divmod` ⚡ | `int -> int -> (int * int)` | (商, 剰余)、0 div で raise |
| `sum_range` | `int -> int -> int` | `lo..hi` 総和 (Gauss 公式、O(1)) |
| `not` | `bool -> bool` | 論理否定 |

### Float 算術 (4)

| 名前 | 型 | 説明 |
|---|---|---|
| `f_add` | `float -> float -> float` | 加算 |
| `f_sub` | `float -> float -> float` | 減算 |
| `f_mul` | `float -> float -> float` | 乗算 |
| `f_div` | `float -> float -> float` | 除算 (IEEE 754: 0 div は inf/nan) |
| `f_lt` | `float -> float -> bool` | 小なり |
| `f_le` | `float -> float -> bool` | 以下 |
| `f_gt` | `float -> float -> bool` | 大なり |
| `f_ge` | `float -> float -> bool` | 以上 |
| `f_neg` | `float -> float` | 単項マイナス (`Neg` は int 専用なので float はこっち) |
| `f_abs` | `float -> float` | 絶対値 |
| `sqrt` | `float -> float` | 平方根 (負数は NaN) |
| `floor` | `float -> float` | 切り捨て |
| `ceil` | `float -> float` | 切り上げ |
| `round` | `float -> float` | 四捨五入 |
| `f_min` ★ | `float -> float -> float` | 小さい方 (Phase 19.7) |
| `f_max` ★ | `float -> float -> float` | 大きい方 (Phase 19.7) |
| `f_pow` ★ | `float -> float -> float` | 累乗 `base ^ exp` (Phase 19.7) |
| `log` ★ | `float -> float` | 自然対数 (Phase 19.7) |
| `exp` ★ | `float -> float` | e^x (Phase 19.7) |
| `sin` ★ | `float -> float` | 正弦 (radians、Phase 19.7) |
| `cos` ★ | `float -> float` | 余弦 (Phase 19.7) |
| `tan` ★ | `float -> float` | 正接 (Phase 19.7) |
| `atan2` ★ | `float -> float -> float` | `atan2 y x` で角度 (Phase 19.7) |
| `random_int` ★ ⚡ | `int -> int` | `random_int n` で `0..n-1` の int、n<=0 で raise (Phase 19.7) |
| `random_float` ★ | `unit -> float` | `[0.0, 1.0)` の float (Phase 19.7) |
| `pi` | `float` | 円周率 ≈ 3.14159265 (定数 builtin) |
| `e` | `float` | ネイピア数 ≈ 2.71828183 (定数 builtin) |

**★ codegen 状況**: Phase 19.7 で追加した 11 個は **interpreter のみ**。
codegen 対応は libm のリンク or 各 backend で組込み数学関数の wiring が
必要で、follow-up slice (19.7.1) で対応予定。

```
f_add 1.5 2.5                    // 4.0
f_div 10.0 4.0                   // 2.5
3.14 |> f_mul 2.0                // 6.28
```

```
clamp 0 100 150                  // 100
pow 2 10                         // 1024
gcd 12 18                        // 6
sum_range 1 100                  // 5050
fst (divmod 100 7) + snd (divmod 100 7)   // 14 + 2
```

---

## 制御 / エラー (3)

| 名前 | 型 | 説明 |
|---|---|---|
| `fail` ⚡ ★ | `str -> 'a` | 任意の型に統合する panic |
| `assert` ⚡ | `bool -> str -> unit` | false なら "assertion failed: MSG" で raise |
| `try_or` ★ | `(unit -> 'a) -> 'a -> 'a` | thunk 評価、`Eval_error` を catch して default |

```
let safe = fn s -> try_or (fn () -> int_of_str s) (- 1);
safe "42"      // 42
safe "abc"     // -1

if x < 0 then fail "negative" else x
```

`fail` は polymorphic なので、分岐合流で正しく型推論される (`if c then fail msg else int_val` → int)。

---

## 多相 helper (8 ★)

| 名前 | 型 | 説明 |
|---|---|---|
| `show` ★ | `'a -> str` | 任意の値を to_string で文字列化 |
| `id` ★ | `'a -> 'a` | 恒等関数 |
| `fst` ★ | `('a * 'b) -> 'a` | tuple の 1 番目 |
| `snd` ★ | `('a * 'b) -> 'b` | tuple の 2 番目 |
| `pair` ★ | `'a -> 'b -> ('a * 'b)` | tuple 構築 curry |
| `swap` ★ | `('a * 'b) -> ('b * 'a)` | tuple 入れ替え |
| `const` ★ | `'a -> 'b -> 'a` | 第 2 引数を捨てて第 1 を返す |
| `flip` ★ | `('a -> 'b -> 'c) -> ('b -> 'a -> 'c)` | curry 関数の引数順反転 (higher-order) |

```
show 42                          // "42"
show (Some 5)                    // "Some 5"
show [1, 2, 3]                   // "[1, 2, 3]"   (Cons/Nil chain は [..] で表示)
show [Some 1, None, Some 3]      // "[Some 1, None, Some 3]"

fst (pair "hi" 42)               // "hi"
let always_7 = const 7 in always_7 "anything"   // 7
let sub = fn a -> fn b -> a - b in (flip sub) 3 10   // 7 (= sub 10 3)
```

---

## ループ helper (1 ★)

| 名前 | 型 | 説明 |
|---|---|---|
| `iter_n` ★ | `int -> (unit -> unit) -> unit` | thunk を N 回適用 (副作用ループ)、N≤0 で no-op |

---

## Capability (2 + 2 builtin record types)

エフェクトシステム ([effects.mere](../examples/effects.mere) 参照) で使う cap 型のうち、`Logger` と `Metrics` は builtin として事前登録済み。ユーザは `type Logger = ...` で上書きすることもできる。

```
type Logger  = { info: str -> unit, warn: str -> unit, error: str -> unit };
type Metrics = { inc: str -> unit, record: str -> int -> unit };
```

| 名前 | 型 | 説明 |
|---|---|---|
| `mk_logger`  | `str -> Logger`   | prefix 付き Logger を作成。各 field は `prefix [LEVEL] msg` 形式で print する |
| `mk_metrics` | `unit -> Metrics` | Metrics を作成。`inc` / `record` は `[METRIC] ...` 形式で print する |

```
let lg = mk_logger "app" in
{ lg.info "started";
  lg.warn "slow query";
  lg.error "abort" }

let m = mk_metrics () in
{ m.inc "users";
  m.record "latency_ms" 23 }
```

cap-passing パターンの完全な例は [examples/effects.mere](../examples/effects.mere) を参照。

---

## システム / 定数 (4)

| 名前 | 型 | 説明 |
|---|---|---|
| `time` | `unit -> float` | Unix epoch 秒数 (gettimeofday)。ベンチマーク・タイムスタンプ用 |
| `exit` ★ | `int -> 'a` | プロセスを exit code で終了 (never returns、polymorphic 返り型) |
| `int_max` | `int` | int の最大値 (OCaml runtime 依存、64-bit で 2^62-1) — 定数 builtin |
| `int_min` | `int` | int の最小値 — 定数 builtin |

```
let start = time () in
{ run_heavy_computation ();
  print ("elapsed: " ++ str_of_float (f_sub (time ()) start) ++ " sec") }

if config_invalid then exit 1 else continue ()
```

```
iter_n 3 (fn () -> print "===")   // === を 3 回出力
```

---

## 全 builtin 一覧 (アルファベット順、106 個)

```
abs args assert atan2 bool_of_str ceil char_at chr clamp const
cos cube decr divmod e env_var even exit exp f_abs f_add
f_div f_ge f_gt f_le f_lt f_max f_min f_mul f_neg f_pow
f_sub fail file_exists flip float_of_int float_of_str floor
fst gcd id incr int_max int_min int_of_float int_of_str
is_alpha is_digit is_space iter_n lcm log max min mk_logger
mk_metrics not odd ord pair pi pow print print_bool
print_err print_int print_no_nl random_float random_int
read_file read_line read_lines round show sign sin snd sqrt
square str_compare str_contains str_count str_ends_with
str_index_of str_join str_len str_of_float str_of_int
str_repeat str_replace str_rev str_split str_starts_with
str_trim str_unescape substring sum_range swap tan time
to_lower to_upper try_or write_file
```

Q-010 collection builtins (`vec_*` / `owned_vec_*` / `strbuf_*` /
`map_*` / `len`) は本表とは別枠の registered builtin として
language-reference / tutorial を参照。Phase 19.2 で **`map_iter :
Map[R, K, V] -> (K -> V -> unit) -> unit`** を追加 (4 backend 全部で動く)。

---

## 関連

- 演算子 (`+ * == ++ |> << >>` 等) は **builtin ではなく言語構文** で、参照は [language-reference.md](language-reference.md)
- 使用イディオムは [patterns.md](patterns.md)
- 実例: `examples/json_parser.mere` で stdlib 多数を組み合わせて 140 行の JSON パーサを書いている
