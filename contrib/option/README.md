# contrib/option — Option type の追加 helpers

Mere prelude には `option_map` / `option_default` / `option_is_some` /
`option_and_then` が既にあるが、 contrib/option は **prelude を補完する**
追加 helpers を `module Option { ... }` でまとめる。

## ファイル

| file | export | 行数 |
|---|---|---|
| `option.mere` | `module Option { zip, filter, or_else, is_none, unwrap_or_fail }` | 約 130 行 |

## API (prelude にない補完 helpers)

| fn | signature | 用途 |
|---|---|---|
| `Option.zip` | `'a opt -> 'b opt -> ('a * 'b) opt` | 両方 Some なら tuple、 どちらか None なら None |
| `Option.filter` | `'a opt -> ('a -> bool) -> 'a opt` | 述語不一致なら None に倒す |
| `Option.or_else` | `'a opt -> 'a opt -> 'a opt` | 左が None なら右を返す |
| `Option.is_none` | `'a opt -> bool` | inverse of `option_is_some` |
| `Option.unwrap_or_fail` | `'a opt -> str -> 'a` | None なら `fail msg`、 Some なら取り出す |

## 使い方

```mere
import "contrib/option/option.mere";

// 両方 Some なら tuple
let result = Option.zip (Some 1) (Some "a") in
match result with
| Some (n, s) -> ...
| None -> ...

// 述語で絞り込み
let big = Option.filter (Some 5) (fn n -> n > 3);   // Some 5
let no = Option.filter (Some 2) (fn n -> n > 3);    // None

// fallback chain
let val = Option.or_else (try1 ()) (try2 ());

// invariant check
let value = Option.unwrap_or_fail maybe_value "invariant violated";
```

## 既知の注意点

- **annotation が必要な None**: `None` 単独で型がない場合、 codegen 環境で
  多 instantiation が解決できず `'a leak` になることがある。 demo では
  `(None : int option)` のように明示 annotation を付けて回避。
  例:
  ```mere
  Option.is_none None              // C codegen で fail (型不定)
  Option.is_none (None: int option)  // OK
  ```

## backend サポート

| backend | 状態 |
|---|---|
| interp | ✓ |
| C | ✓ |
| LLVM | ✓ |
| Wasm | ✓ |

## 位置付け

stage 2 contrib (incubation)。 [contrib/README.md](../README.md) 参照。
graduation 先は `mere-option` (別 repo) — または prelude に取り込んで lib 化
不要にする選択肢もある (`zip` / `filter` / `or_else` は他の関数型言語で標準)。
