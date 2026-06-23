# contrib/csv — CSV parser / writer

RFC 4180 縮小版の CSV パーサと writer。 quote (`"..."`) と escape (`""` →
literal `"`) を support、 改行は `\n` のみ (CRLF 未対応)。 外部依存ゼロ、
stdlib (`str_*` / `char_at` / `is_*`) だけで完結。

## ファイル

| file | export | 行数 |
|---|---|---|
| `parser.mere` | `module Csv { parse_csv: str -> str list list }` | 約 140 行 |
| `writer.mere` | `type Person` + `module CsvWriter { needs_quote, escape_field, row_of, render }` | 約 60 行 |

## 使い方

```mere
import "contrib/csv/parser.mere";

let rows = Csv.parse_csv "id,name\n1,alice\n2,bob" in
match rows with
| Cons (header, body) -> ...
| Nil -> "empty"
```

または copy-paste:

```sh
cp contrib/csv/parser.mere my_project/
```

## サポート範囲

- field 区切り: `,`
- 行区切り: `\n` (CRLF は当面 unsupported)
- quoted field: `"foo,bar"` の中で `,` `\n` を field 値に含める
- escaped quote: `""` で literal `"` を表す
- bare field: trim しない (空白は保持)

## 既知の制約

- CRLF (`\r\n`) 非対応
- `writer.mere` は `Person { name; age; city }` 固定 record にバインド — 汎用化は将来 (record 単位の polymorphism 未実装、 `record_to_csv` のような generic API は trait / row poly 待ち)。 Phase 42 で record type in module の C codegen が解禁されたため、 helpers は `module CsvWriter` で wrap 済

## 位置付け

stage 2 contrib (incubation)。 [contrib/README.md](../README.md) 参照。
graduation 先は `mere-csv` (別 repo)、 公開 + pkg manager 完成後。
