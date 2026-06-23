# contrib/regex — minimal regex matcher (Mere 実装)

正規表現 AST + backtracking matcher を Mere で書いた MVP。 `module Regex { ... }`
で名前空間化。 NFA 構築や Thompson 法は使わず素直な再帰でマッチング。

## ファイル

| file | export | 行数 |
|---|---|---|
| `regex.mere` | `type regex` + `module Regex { parse_re: str -> regex; match_re: regex -> str -> bool }` | 約 230 行 |
| `engine.mere` | より詳細な engine 試作 (top-level、 module 化は将来) | 約 110 行 |

## 使い方

```mere
import "contrib/regex/regex.mere";

let re = Regex.parse_re "^a.+z$" in
if Regex.match_re re "anything-then-z"
then print "matched"
else print "no match"
```

## サポート構文 (MVP)

| 構文 | 意味 |
|---|---|
| `c` | 1 文字リテラル (ASCII 1 byte) |
| `.` | 任意 1 文字 |
| `^` | 行頭アンカー |
| `$` | 行末アンカー |
| `c*` | 0 回以上 (greedy) |
| `c+` | 1 回以上 (greedy) |
| `c?` | 0 or 1 回 |
| `ab` | 連結 |

## 非対応 (将来 issue 駆動)

- グループ `(...)`
- 文字クラス `[a-z]`
- 選択 `|`
- 量子化子 `{n,m}`
- 後方参照 `\1`
- Unicode

## 位置付け

stage 2 contrib (incubation)。 [contrib/README.md](../README.md) 参照。
graduation 先は `mere-regex` (別 repo、 pkg manager 完成後)。 PCRE / RE2 互換は
最初から狙わず、 「常用に耐える subset」 として育てる方針。
