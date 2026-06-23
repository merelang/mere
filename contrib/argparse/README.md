# contrib/argparse — minimal CLI argument parser

Mere の `args()` builtin が返す `str list` を flags / options / positional に
分解する最小実装。 `module Argparse { ... }` で名前空間化。

## ファイル

| file | export | 行数 |
|---|---|---|
| `argparse.mere` | `module Argparse { parse, has_flag, get_opt, get_pos }` | 約 130 行 |

## 使い方

```mere
import "contrib/argparse/argparse.mere";

let argv = args () in
let flag_specs = Cons ("verbose", Cons ("dry-run", Nil)) in
let opt_specs = Cons ("output", Cons ("config", Nil)) in
let r = Argparse.parse flag_specs opt_specs argv in

if Argparse.has_flag r "verbose" then print "verbose mode" else ();
let out = Argparse.get_opt r "output" "default.bin" in
let positional = Argparse.get_pos r in
...
```

## サポート構文

| 構文 | 意味 |
|---|---|
| `--verbose` | flag (spec で flag_specs に含まれていれば) |
| `--name value` | option (spec で opt_specs、 次 token を値に) |
| `--name=value` | option (= 区切り) |
| `--` | 区切り以降を全 positional 扱い (POSIX convention) |
| `foo.txt` | positional |

## 戻り値 (tuple)

```
(flags: Map[__heap, str, int],     // entry あり = flag 立っている (値は 1)
 opts:  Map[__heap, str, str],     // option name -> 値
 pos:   str list)                  // positional 順序維持
```

## MVP 限定

- 短名 (`-v`) 未対応 — long name (`--verbose`) のみ
- 型変換は user 側で (`int_of_str (Argparse.get_opt r "n" "0")` 等)
- help message 自動生成なし
- 未知 `--foo` は positional 扱い (将来 error 化)

## 実装メモ

当初 `let push_pos = fn s -> strbuf_push pos s` の inner helper を作っていたが、
DEFERRED §8 (inner-lifted fn の closure capture が anonymous Fun 経由で漏れる)
の影響で C codegen で fail。 strbuf_push を inline 呼出に書き戻して回避済。

また `default` を関数パラメータ名にすると C 予約語衝突で codegen fail
([docs/reserved-names.md](../../docs/reserved-names.md) §1.1)。 本 lib では
`get_opt` の引数を `dflt` にしてある。

## 位置付け

stage 2 contrib (incubation)。 [contrib/README.md](../README.md) 参照。
graduation 先は `mere-argparse` (別 repo、 pkg manager 完成後)。
将来 `mere-argparse` で短名 / help 自動生成 / sub-command などを追加予定。
