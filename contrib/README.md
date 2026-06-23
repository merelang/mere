# contrib/ — incubating libraries

このディレクトリには **`examples/` より一段「lib」 寄り** の Mere コードを置く。
すなわち、 「単体で挙動を見る demo」 ではなく **「他の Mere program に組み込んで
使う前提の機能」**。

## 位置付け (3 段 lifecycle)

| stage | 場所 | 性質 |
|---|---|---|
| 1. example | `examples/foo.mere` | 単体実行で挙動を見る demo |
| **2. contrib (incubation)** | `contrib/foo/` | **lib 候補。 main repo に同居して core 改修と atomic に refactor 可能** |
| 3. 別 repo | `github.com/284km/mere-foo` | 独立 version / issues / PRs |

stage 2 → 3 の graduation 条件:
- Mere 本体に **pkg manager** が実装され、 `mere fetch` 経由で外部 dep を解決できる
- API が daily breaking でなくなる (= 1 ヶ月以上 signature 安定)
- 外部 consumer (Mere 以外で書かれた user code) が 1 つ以上存在する

## 使い方 (pkg manager 完成前)

Mere は **`module M { ... }` + `import "path";` を実装済**。 Phase 41 で
qualified pattern match (`match v with | Json.JNull -> ...`) を 4 backend
codegen で動かせるようになったので、 contrib lib は **module wrap して名前
空間化** することを推奨する (`contrib/json/json.mere` が見本)。

```mere
import "contrib/json/json.mere";
let v = Json.parse_json "[1, 2]" in
match v with
| Json.JArr xs -> "array"
| _ -> "other"
```

copy-paste でも構わない:

```sh
cp contrib/json/json.mere my_project/
```

旧 `examples/` 由来の top-level lib (現在 `contrib/json/writer.mere` /
`contrib/markdown/*`) は引き続き使えるが、 名前空間化したい場合は順次
`module Foo { ... }` 形に書き直していく。

```sh
# 例: JSON を使いたい
cp contrib/json/json.mere my_project/
# my_project/main.mere の先頭で type json と parse_json が available になる
```

ファイル単位で「先頭に concat する」 と prelude 同様に top-level let / type が
inject される。 名前衝突を避けるため、 contrib の lib は **prefix 付き命名規約**
(`json_parse / json_show / md_to_html / md_to_text`) を採用する。

## 現在の contrib lib

| lib | path | 機能 | module 化 |
|---|---|---|---|
| **json** | `contrib/json/` | JSON parse (`Json.parse_json`) + write (compact / pretty) | parser のみ |
| **markdown** | `contrib/markdown/` | Markdown 部分集合 → HTML / 平文 / TOC | (top-level、 module 化は将来) |
| **csv** | `contrib/csv/` | CSV parse (`Csv.parse_csv`、 RFC 4180 縮小) + writer (`CsvWriter.render` Person bound) | ✓ both |
| **argparse** | `contrib/argparse/` | CLI 引数 parser (`Argparse.parse` flag/opt/positional) | ✓ module |
| **regex** | `contrib/regex/` | minimal regex (`Regex.parse_re` + `Regex.match_re`、 `. ^ $ * + ?` + concat) | ✓ module |
| **test** | `contrib/test/` | unit test framework (`Test.assert_eq` + `Test.summary` + `Test.exit_status`) | ✓ module |
| **time** | `contrib/time/` | 経過秒 format helpers (`Time.format_elapsed` 等)。 Wasm 当面 unsupported | ✓ module (3 backend) |
| **option** | `contrib/option/` | prelude 補完 helpers (`Option.zip` / `filter` / `or_else` / `is_none` / `unwrap_or_fail`) | ✓ module |

将来追加候補は `internal design notes` §3 参照。

## 設計判断の根拠

なぜ `examples/` から分けるかの詳細は internal design notes §3 を参照。
