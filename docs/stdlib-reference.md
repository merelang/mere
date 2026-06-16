# Stdlib reference (lang-ml)

`initial_env` で常に使える 56 個の builtin。型は `lang-ml -te NAME` で確認可。

凡例:
- ⚡ = `Eval_error` を raise する可能性あり
- ★ = 多相 (let-poly に乗らない、builtin-level 多相)

---

## I/O (6)

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

## 文字列操作 (19)

| 名前 | 型 | 説明 |
|---|---|---|
| `str_len` | `str -> int` | バイト長 |
| `str_contains` | `str -> str -> bool` | 部分文字列を含むか |
| `str_starts_with` | `str -> str -> bool` | prefix 判定 |
| `str_ends_with` | `str -> str -> bool` | suffix 判定 |
| `str_count` | `str -> str -> int` | 非オーバーラップ出現回数 |
| `str_compare` | `str -> str -> int` | 辞書順 -1 / 0 / 1 |
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

```
iter_n 3 (fn () -> print "===")   // === を 3 回出力
```

---

## 全 builtin 一覧 (アルファベット順、56 個)

```
abs assert bool_of_str char_at chr clamp const cube
decr divmod even f_add f_div f_mul f_sub fail flip
float_of_int float_of_str fst gcd id incr int_of_float
int_of_str is_alpha is_digit is_space iter_n lcm max
min not odd ord pair pow print print_bool print_err
print_int print_no_nl read_file read_line show sign snd
square str_compare str_contains str_count str_ends_with
str_len str_of_float str_of_int str_repeat str_replace
str_rev str_starts_with str_trim str_unescape substring
sum_range swap to_lower to_upper try_or write_file
```

---

## 関連

- 演算子 (`+ * == ++ |> << >>` 等) は **builtin ではなく言語構文** で、参照は [language-reference.md](language-reference.md)
- 使用イディオムは [patterns.md](patterns.md)
- 実例: `examples/json_parser.lang` で stdlib 多数を組み合わせて 140 行の JSON パーサを書いている
