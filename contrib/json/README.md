# contrib/json — JSON parser / writer

Mere で書かれた JSON parse / serialize ライブラリ。 stdlib (`str_*` /
`is_digit` / `try_or` / `fail` / `StrBuf`) + 再帰 variant + pattern matching の
組み合わせで実装、 外部依存ゼロ。

## ファイル

| file | export | 行数 |
|---|---|---|
| `json.mere` | `module Json { type json = JNull \| JBool \| JNum \| JStr \| JArr \| JObj; parse_json: str -> json }` | 約 180 行 |
| `writer.mere` | `type json` (top-level) + `module JsonWriter { to_json_str, to_pretty_str }` | 約 135 行 |

## 使い方 (pkg manager 完成前)

```mere
// import で取り込み (Phase 9.5 から動く)
import "contrib/json/json.mere";

let v = Json.parse_json "[1, 2, 3]" in
match v with
| Json.JArr xs -> ...
| Json.JNull -> ...
| _ -> ...
```

または **copy-paste** で project に取り込み:

```sh
cp contrib/json/json.mere    my_project/
cp contrib/json/writer.mere  my_project/
```

各ファイル末尾の self-test ブロック (`run_case` で始まる demo / `let doc = …` 等)
は実 use 時に削除して良い。

`writer.mere` は Phase 43 で `module JsonWriter { ... }` で wrap 完了。 ただし
`type json` は **module の外側** に置いている (parser の `module Json
{ type json = ... }` と単一 file 内で共存はできないが、 別 file としては独立に
使える)。 parser + writer を 1 program で round-trip させる場合は user 側で
`type json` 衝突を回避する必要あり (parser だけ or writer だけ either-or の運用
が当面 expected)。

## サポート範囲

- atoms: `null` / `true` / `false` / int (negative OK) / string
- composite: array / object
- escape: `\"` `\\` `\n` `\t` `\r` `\/` を `str_unescape` 経由で復元
- **非対応** (issue 駆動で拡張): float / unicode `\uXXXX` / exponential notation

## 既知の制約

- **`{` を含む文字列リテラル**: Phase 36 string interpolation の仕様で
  `"{"` が補間開始と解釈されるため、 `"\{"` で escape する必要あり
  (json.mere / writer.mere の demo は workaround 済)
- **C codegen で `case` という名前は予約語と衝突** (libc/C keyword) — 本 lib では
  自前 test helper を `run_case` に rename。 reserved name の全 list は
  [docs/reserved-names.md](../../docs/reserved-names.md) 参照

## 位置付け

stage 2 contrib (incubation)。 [contrib/README.md](../README.md) の lifecycle 参照。
公開 + pkg manager 完成後、 graduation 候補として別 repo `mere-json` に切り出す
計画 (internal design notes §3.1)。
